use regex::Regex;
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

/// Write lines to a file, returning the number of bytes written.
fn write_chunk(lines: &[String], filename: &str, config: &CsplitConfig) -> Result<u64, String> {
    if config.elide_empty && lines.is_empty() {
        return Ok(0);
    }

    let mut content = String::new();
    for line in lines {
        content.push_str(line);
        content.push('\n');
    }
    let bytes = content.len() as u64;

    if config.elide_empty && bytes == 0 {
        return Ok(0);
    }

    fs::write(filename, &content).map_err(|e| format!("cannot write '{}': {}", filename, e))?;

    Ok(bytes)
}

/// Find the first line matching a regex starting from `start`, returning its index.
fn find_match(lines: &[String], regex: &Regex, start: usize) -> Option<usize> {
    for (idx, line) in lines.iter().enumerate().skip(start) {
        if regex.is_match(line) {
            return Some(idx);
        }
    }
    None
}

/// Apply a single regex or skip-to pattern. Returns Ok(true) if matched,
/// Ok(false) if no match (only used for repeat-forever graceful stop).
/// For non-repeat patterns, no match is always an error.
fn apply_regex_pattern(
    lines: &[String],
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
    let re = Regex::new(regex).map_err(|e| format!("invalid regex: {}", e))?;

    // When skip_current is set, the line at current_line was the match boundary
    // from a previous regex split — skip it to find the NEXT occurrence.
    let search_start =
        if *skip_current && *current_line < total_lines && re.is_match(&lines[*current_line]) {
            *current_line + 1
        } else {
            *current_line
        };

    let match_idx = match find_match(lines, &re, search_start) {
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
        let chunk_lines = &lines[*current_line..split_at];
        let filename = output_filename(config, *file_index);
        let bytes = write_chunk(chunk_lines, &filename, config)?;

        if !(config.elide_empty && chunk_lines.is_empty()) {
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
    let lines: Vec<String> = input.lines().map(|l| l.to_string()).collect();
    let total_lines = lines.len();

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

                let chunk_lines = &lines[current_line..end];
                let filename = output_filename(config, file_index);

                let bytes = write_chunk(chunk_lines, &filename, config).inspect_err(|_| {
                    do_cleanup(&created_files, config);
                })?;

                if !(config.elide_empty && chunk_lines.is_empty()) {
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
                    &lines,
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
                    &lines,
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
                            // For repeated line numbers, this doesn't make much sense
                            // but follow the same logic
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
                            let chunk_lines = &lines[current_line..end];
                            let filename = output_filename(config, file_index);
                            let bytes =
                                write_chunk(chunk_lines, &filename, config).inspect_err(|_| {
                                    do_cleanup(&created_files, config);
                                })?;
                            if !(config.elide_empty && chunk_lines.is_empty()) {
                                created_files.push(filename);
                                sizes.push(bytes);
                                file_index += 1;
                            }
                            current_line = end;
                            skip_current = false;
                        }
                        Pattern::Regex { regex, offset } => {
                            if let Err(e) = apply_regex_pattern(
                                &lines,
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
                                &lines,
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
                                &lines,
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
                                &lines,
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
        let chunk_lines = &lines[current_line..total_lines];
        let filename = output_filename(config, file_index);

        let bytes = write_chunk(chunk_lines, &filename, config).inspect_err(|_| {
            do_cleanup(&created_files, config);
        })?;

        if !(config.elide_empty && chunk_lines.is_empty()) {
            created_files.push(filename);
            sizes.push(bytes);
        }
    } else if !config.elide_empty {
        // Write an empty final file
        let filename = output_filename(config, file_index);
        let bytes = write_chunk(&[], &filename, config).inspect_err(|_| {
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
        io::stdin()
            .read_line(&mut buf)
            .map_err(|e| format!("read error: {}", e))?;
        // Read all remaining
        let mut all = buf;
        let mut line = String::new();
        while io::stdin()
            .read_line(&mut line)
            .map_err(|e| format!("read error: {}", e))?
            > 0
        {
            all.push_str(&line);
            line.clear();
        }
        all
    } else {
        fs::read_to_string(path).map_err(|e| format!("cannot open '{}': {}", path, e))?
    };

    csplit_file(&input, patterns, config)
}

/// Print the sizes of created files to stdout.
pub fn print_sizes(sizes: &[u64]) {
    for size in sizes {
        println!("{}", size);
    }
}
