use memchr::memchr_iter;
use regex::{Regex, RegexBuilder};
use std::fs;
use std::io;

/// A parsed csplit pattern.
#[derive(Clone, Debug)]
pub enum Pattern {
    /// Split before the first line matching the regex, with optional offset.
    Regex { regex: String, offset: i64 },
    /// Skip to (but don't include) a line matching the regex, with optional offset.
    /// Lines skipped are not written to any output file.
    SkipTo { regex: String, offset: i64 },
    /// Split at a specific line number.
    LineNumber(usize),
    /// Repeat the previous pattern N times.
    Repeat(usize),
    /// Repeat the previous pattern as many times as possible.
    RepeatForever,
}

/// Configuration for the csplit command.
#[derive(Clone, Debug)]
pub struct CsplitConfig {
    pub prefix: String,
    pub suffix_format: String,
    pub digits: usize,
    pub keep_files: bool,
    pub quiet: bool,
    pub elide_empty: bool,
}

impl Default for CsplitConfig {
    fn default() -> Self {
        Self {
            prefix: "xx".to_string(),
            suffix_format: String::new(),
            digits: 2,
            keep_files: false,
            quiet: false,
            elide_empty: false,
        }
    }
}

/// Parse a pattern string into a Pattern enum.
pub fn parse_pattern(s: &str) -> Result<Pattern, String> {
    let s = s.trim();

    // {*} - repeat forever
    if s == "{*}" {
        return Ok(Pattern::RepeatForever);
    }

    // {N} - repeat N times
    if s.starts_with('{') && s.ends_with('}') {
        let inner = &s[1..s.len() - 1];
        let n: usize = inner
            .parse()
            .map_err(|_| format!("invalid repeat count: '{}'", s))?;
        return Ok(Pattern::Repeat(n));
    }

    // /REGEX/[OFFSET] - split before matching line
    if s.starts_with('/') {
        let rest = &s[1..];
        if let Some(end_pos) = rest.rfind('/') {
            let regex_str = &rest[..end_pos];
            let after = rest[end_pos + 1..].trim();
            let offset = if after.is_empty() {
                0
            } else {
                after
                    .parse::<i64>()
                    .map_err(|_| format!("invalid offset: '{}'", after))?
            };
            // Validate regex
            Regex::new(regex_str).map_err(|e| format!("invalid regex '{}': {}", regex_str, e))?;
            return Ok(Pattern::Regex {
                regex: regex_str.to_string(),
                offset,
            });
        }
        return Err(format!("unmatched '/' in pattern: '{}'", s));
    }

    // %REGEX%[OFFSET] - skip to matching line
    if s.starts_with('%') {
        let rest = &s[1..];
        if let Some(end_pos) = rest.rfind('%') {
            let regex_str = &rest[..end_pos];
            let after = rest[end_pos + 1..].trim();
            let offset = if after.is_empty() {
                0
            } else {
                after
                    .parse::<i64>()
                    .map_err(|_| format!("invalid offset: '{}'", after))?
            };
            // Validate regex
            Regex::new(regex_str).map_err(|e| format!("invalid regex '{}': {}", regex_str, e))?;
            return Ok(Pattern::SkipTo {
                regex: regex_str.to_string(),
                offset,
            });
        }
        return Err(format!("unmatched '%' in pattern: '{}'", s));
    }

    // LINE_NUMBER - split at line number
    let n: usize = s.parse().map_err(|_| format!("invalid pattern: '{}'", s))?;
    if n == 0 {
        return Err("line number must be positive".to_string());
    }
    Ok(Pattern::LineNumber(n))
}

/// Generate the output filename for a given file index.
pub fn output_filename(config: &CsplitConfig, index: usize) -> String {
    if config.suffix_format.is_empty() {
        format!("{}{:0>width$}", config.prefix, index, width = config.digits)
    } else {
        // Simple sprintf-like formatting: support %02d, %03d, etc.
        let suffix = format_suffix(&config.suffix_format, index);
        format!("{}{}", config.prefix, suffix)
    }
}

/// Simple sprintf-like formatter for suffix format strings.
/// Supports %d, %02d, %03d, etc.
pub fn format_suffix(fmt: &str, value: usize) -> String {
    let mut result = String::new();
    let mut chars = fmt.chars().peekable();

    while let Some(ch) = chars.next() {
        if ch == '%' {
            // Parse width specifier
            let mut width_str = String::new();
            let mut zero_pad = false;

            if chars.peek() == Some(&'0') {
                zero_pad = true;
                chars.next();
            }

            while let Some(&c) = chars.peek() {
                if c.is_ascii_digit() {
                    width_str.push(c);
                    chars.next();
                } else {
                    break;
                }
            }

            // Expect 'd'
            if chars.peek() == Some(&'d') {
                chars.next();
                let width: usize = width_str.parse().unwrap_or(0);
                if zero_pad && width > 0 {
                    result.push_str(&format!("{:0>width$}", value, width = width));
                } else if width > 0 {
                    result.push_str(&format!("{:>width$}", value, width = width));
                } else {
                    result.push_str(&format!("{}", value));
                }
            } else if chars.peek() == Some(&'%') {
                chars.next();
                result.push('%');
            } else {
                // Unknown format, just pass through
                result.push('%');
                result.push_str(&width_str);
            }
        } else {
            result.push(ch);
        }
    }

    result
}

/// Build a line offset table from input bytes using SIMD-accelerated newline scan.
/// Returns offsets where offsets[i] is the byte position of the start of line i,
/// and offsets[total_lines] is the byte position past the end of line total_lines-1.
fn build_line_offsets(data: &[u8]) -> Vec<usize> {
    let mut offsets = Vec::with_capacity(data.len() / 40 + 2);
    offsets.push(0);
    for pos in memchr_iter(b'\n', data) {
        offsets.push(pos + 1);
    }
    // If data doesn't end with \n, add end sentinel
    if !data.is_empty() && *data.last().unwrap() != b'\n' {
        offsets.push(data.len());
    }
    offsets
}

/// Get the content of line `idx` (without trailing newline) as a &str.
#[inline]
fn line_content<'a>(data: &'a [u8], offsets: &[usize], idx: usize) -> &'a str {
    let start = offsets[idx];
    let mut end = offsets[idx + 1];
    if end > start && data[end - 1] == b'\n' {
        end -= 1;
    }
    // SAFETY: data originated from &str, so all bytes are valid UTF-8
    unsafe { std::str::from_utf8_unchecked(&data[start..end]) }
}

/// Write the byte range for lines [start_line..end_line) to a file.
/// Returns the number of bytes written.
fn write_chunk_range(
    data: &[u8],
    offsets: &[usize],
    start_line: usize,
    end_line: usize,
    filename: &str,
    config: &CsplitConfig,
) -> Result<u64, String> {
    let is_empty = start_line >= end_line;
    if config.elide_empty && is_empty {
        return Ok(0);
    }

    if is_empty {
        fs::write(filename, b"").map_err(|e| format!("cannot write '{}': {}", filename, e))?;
        return Ok(0);
    }

    let byte_start = offsets[start_line];
    let byte_end = offsets[end_line];
    let chunk = &data[byte_start..byte_end];
    let bytes = chunk.len() as u64;

    fs::write(filename, chunk).map_err(|e| format!("cannot write '{}': {}", filename, e))?;
    Ok(bytes)
}

/// Find the first line matching a regex starting from `start`, returning its index.
/// Uses bulk SIMD search on the raw data instead of per-line matching.
fn find_match(
    data: &[u8],
    offsets: &[usize],
    total_lines: usize,
    regex: &Regex,
    start: usize,
) -> Option<usize> {
    if start >= total_lines {
        return None;
    }
    let byte_start = offsets[start];
    // SAFETY: data originated from &str, so all bytes are valid UTF-8
    let search_str = unsafe { std::str::from_utf8_unchecked(&data[byte_start..]) };
    let mat = regex.find(search_str)?;
    // Convert byte position of match to line number using binary search
    let abs_pos = byte_start + mat.start();
    let line = match offsets[..total_lines + 1].binary_search(&abs_pos) {
        Ok(exact) => exact,  // match starts exactly at a line boundary
        Err(idx) => idx - 1, // match is within this line
    };
    Some(line)
}

/// Apply a single regex or skip-to pattern. Returns Ok(true) if matched,
/// Ok(false) if no match (only used for repeat-forever graceful stop).
fn apply_regex_pattern(
    data: &[u8],
    offsets: &[usize],
    total_lines: usize,
    regex: &str,
    offset: i64,
    is_skip: bool,
    current_line: &mut usize,
    skip_current: &mut bool,
    sizes: &mut Vec<u64>,
    created_files: &mut Vec<String>,
    file_index: &mut usize,
    config: &CsplitConfig,
    graceful_no_match: bool,
) -> Result<bool, String> {
    let re = RegexBuilder::new(regex)
        .multi_line(true)
        .build()
        .map_err(|e| format!("invalid regex: {}", e))?;

    // When skip_current is set, the line at current_line was the match boundary
    // from a previous regex split — skip it to find the NEXT occurrence.
    let search_start = if *skip_current
        && *current_line < total_lines
        && re.is_match(line_content(data, offsets, *current_line))
    {
        *current_line + 1
    } else {
        *current_line
    };

    let match_idx = match find_match(data, offsets, total_lines, &re, search_start) {
        Some(idx) => idx,
        None => {
            if graceful_no_match {
                return Ok(false);
            }
            return Err(format!("{}: no match", regex));
        }
    };

    let target = match_idx as i64 + offset;
    let split_at = if target < *current_line as i64 {
        *current_line
    } else if target as usize > total_lines {
        total_lines
    } else {
        target as usize
    };

    if is_skip {
        // SkipTo: discard lines from current_line to split_at
        *current_line = split_at;
        *skip_current = false;
    } else {
        // Regex: write chunk from current_line to split_at
        let is_empty = *current_line >= split_at;
        let filename = output_filename(config, *file_index);
        let bytes = write_chunk_range(data, offsets, *current_line, split_at, &filename, config)?;

        if !(config.elide_empty && is_empty) {
            created_files.push(filename);
            sizes.push(bytes);
            *file_index += 1;
        }

        *current_line = split_at;
        // After a regex match with offset 0, current_line is AT the match line
        *skip_current = offset == 0;
    }

    Ok(true)
}

/// Split a file based on patterns.
///
/// Returns the sizes (in bytes) of each created output file.
pub fn csplit_file(
    input: &str,
    patterns: &[Pattern],
    config: &CsplitConfig,
) -> Result<Vec<u64>, String> {
    let data = input.as_bytes();
    let offsets = build_line_offsets(data);
    // total_lines = number of lines (offsets has total_lines + 1 entries)
    let total_lines = if offsets.len() <= 1 {
        0
    } else {
        offsets.len() - 1
    };

    let mut sizes: Vec<u64> = Vec::new();
    let mut created_files: Vec<String> = Vec::new();
    let mut file_index: usize = 0;
    let mut current_line: usize = 0; // 0-based index into lines
    let mut skip_current = false; // true when current_line is a regex match boundary

    let do_cleanup = |files: &[String], config: &CsplitConfig| {
        if !config.keep_files {
            for f in files {
                let _ = fs::remove_file(f);
            }
        }
    };

    let mut pat_idx = 0;
    while pat_idx < patterns.len() {
        match &patterns[pat_idx] {
            Pattern::LineNumber(n) => {
                // Split at line number n (1-based).
                let split_at = *n;
                if split_at <= current_line {
                    let msg = format!("{}: line number out of range", split_at);
                    do_cleanup(&created_files, config);
                    return Err(msg);
                }

                let end = if split_at > total_lines {
                    total_lines
                } else {
                    split_at - 1
                };

                let is_empty = current_line >= end;
                let filename = output_filename(config, file_index);

                let bytes = write_chunk_range(data, &offsets, current_line, end, &filename, config)
                    .inspect_err(|_| {
                        do_cleanup(&created_files, config);
                    })?;

                if !(config.elide_empty && is_empty) {
                    created_files.push(filename);
                    sizes.push(bytes);
                    file_index += 1;
                }

                current_line = end;
                skip_current = false;
                pat_idx += 1;
            }
            Pattern::Regex { regex, offset } => {
                let regex = regex.clone();
                let offset = *offset;
                if let Err(e) = apply_regex_pattern(
                    data,
                    &offsets,
                    total_lines,
                    &regex,
                    offset,
                    false,
                    &mut current_line,
                    &mut skip_current,
                    &mut sizes,
                    &mut created_files,
                    &mut file_index,
                    config,
                    false,
                ) {
                    do_cleanup(&created_files, config);
                    return Err(e);
                }
                pat_idx += 1;
            }
            Pattern::SkipTo { regex, offset } => {
                let regex = regex.clone();
                let offset = *offset;
                if let Err(e) = apply_regex_pattern(
                    data,
                    &offsets,
                    total_lines,
                    &regex,
                    offset,
                    true,
                    &mut current_line,
                    &mut skip_current,
                    &mut sizes,
                    &mut created_files,
                    &mut file_index,
                    config,
                    false,
                ) {
                    do_cleanup(&created_files, config);
                    return Err(e);
                }
                pat_idx += 1;
            }
            Pattern::Repeat(n) => {
                let n = *n;
                if pat_idx == 0 {
                    do_cleanup(&created_files, config);
                    return Err("{N}: no preceding pattern to repeat".to_string());
                }
                // Find the preceding non-repeat pattern
                let prev_pat = find_prev_pattern(patterns, pat_idx);
                let prev_pat = match prev_pat {
                    Some(p) => p.clone(),
                    None => {
                        do_cleanup(&created_files, config);
                        return Err("{N}: no preceding pattern to repeat".to_string());
                    }
                };
                for _ in 0..n {
                    match &prev_pat {
                        Pattern::LineNumber(ln) => {
                            let end = if *ln > total_lines {
                                total_lines
                            } else {
                                *ln - 1
                            };
                            if end <= current_line {
                                let msg = format!("{}: line number out of range", ln);
                                do_cleanup(&created_files, config);
                                return Err(msg);
                            }
                            let is_empty = current_line >= end;
                            let filename = output_filename(config, file_index);
                            let bytes = write_chunk_range(
                                data,
                                &offsets,
                                current_line,
                                end,
                                &filename,
                                config,
                            )
                            .inspect_err(|_| {
                                do_cleanup(&created_files, config);
                            })?;
                            if !(config.elide_empty && is_empty) {
                                created_files.push(filename);
                                sizes.push(bytes);
                                file_index += 1;
                            }
                            current_line = end;
                            skip_current = false;
                        }
                        Pattern::Regex { regex, offset } => {
                            if let Err(e) = apply_regex_pattern(
                                data,
                                &offsets,
                                total_lines,
                                regex,
                                *offset,
                                false,
                                &mut current_line,
                                &mut skip_current,
                                &mut sizes,
                                &mut created_files,
                                &mut file_index,
                                config,
                                false,
                            ) {
                                do_cleanup(&created_files, config);
                                return Err(e);
                            }
                        }
                        Pattern::SkipTo { regex, offset } => {
                            if let Err(e) = apply_regex_pattern(
                                data,
                                &offsets,
                                total_lines,
                                regex,
                                *offset,
                                true,
                                &mut current_line,
                                &mut skip_current,
                                &mut sizes,
                                &mut created_files,
                                &mut file_index,
                                config,
                                false,
                            ) {
                                do_cleanup(&created_files, config);
                                return Err(e);
                            }
                        }
                        _ => {}
                    }
                }
                pat_idx += 1;
            }
            Pattern::RepeatForever => {
                if pat_idx == 0 {
                    do_cleanup(&created_files, config);
                    return Err("{*}: no preceding pattern to repeat".to_string());
                }
                let prev_pat = find_prev_pattern(patterns, pat_idx);
                let prev_pat = match prev_pat {
                    Some(p) => p.clone(),
                    None => {
                        do_cleanup(&created_files, config);
                        return Err("{*}: no preceding pattern to repeat".to_string());
                    }
                };
                // Repeat until the pattern fails to match (graceful stop)
                loop {
                    match &prev_pat {
                        Pattern::Regex { regex, offset } => {
                            match apply_regex_pattern(
                                data,
                                &offsets,
                                total_lines,
                                regex,
                                *offset,
                                false,
                                &mut current_line,
                                &mut skip_current,
                                &mut sizes,
                                &mut created_files,
                                &mut file_index,
                                config,
                                true, // graceful no-match
                            ) {
                                Ok(true) => continue,
                                Ok(false) => break,
                                Err(e) => {
                                    do_cleanup(&created_files, config);
                                    return Err(e);
                                }
                            }
                        }
                        Pattern::SkipTo { regex, offset } => {
                            match apply_regex_pattern(
                                data,
                                &offsets,
                                total_lines,
                                regex,
                                *offset,
                                true,
                                &mut current_line,
                                &mut skip_current,
                                &mut sizes,
                                &mut created_files,
                                &mut file_index,
                                config,
                                true,
                            ) {
                                Ok(true) => continue,
                                Ok(false) => break,
                                Err(e) => {
                                    do_cleanup(&created_files, config);
                                    return Err(e);
                                }
                            }
                        }
                        _ => break,
                    }
                }
                pat_idx += 1;
            }
        }
    }

    // Write remaining lines as the final chunk
    if current_line < total_lines {
        let filename = output_filename(config, file_index);

        let bytes = write_chunk_range(data, &offsets, current_line, total_lines, &filename, config)
            .inspect_err(|_| {
                do_cleanup(&created_files, config);
            })?;

        if !(config.elide_empty && current_line >= total_lines) {
            created_files.push(filename);
            sizes.push(bytes);
        }
    } else if !config.elide_empty {
        // Write an empty final file
        let filename = output_filename(config, file_index);
        let bytes =
            write_chunk_range(data, &offsets, 0, 0, &filename, config).inspect_err(|_| {
                do_cleanup(&created_files, config);
            })?;
        created_files.push(filename);
        sizes.push(bytes);
    }

    Ok(sizes)
}

/// Find the preceding non-repeat pattern.
fn find_prev_pattern(patterns: &[Pattern], idx: usize) -> Option<&Pattern> {
    let mut i = idx;
    while i > 0 {
        i -= 1;
        match &patterns[i] {
            Pattern::Repeat(_) | Pattern::RepeatForever => continue,
            other => return Some(other),
        }
    }
    None
}

/// Split a file by reading from a path or stdin ("-").
pub fn csplit_from_path(
    path: &str,
    patterns: &[Pattern],
    config: &CsplitConfig,
) -> Result<Vec<u64>, String> {
    let input = if path == "-" {
        let mut buf = String::new();
        io::Read::read_to_string(&mut io::stdin().lock(), &mut buf)
            .map_err(|e| format!("read error: {}", e))?;
        buf
    } else {
        std::fs::read_to_string(path).map_err(|e| format!("cannot open '{}': {}", path, e))?
    };

    csplit_file(&input, patterns, config)
}

/// Print the sizes of created files to stdout.
pub fn print_sizes(sizes: &[u64]) {
    for size in sizes {
        println!("{}", size);
    }
}
