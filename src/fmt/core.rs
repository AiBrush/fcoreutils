use std::io::{self, Read, Write};

/// Configuration for the fmt command.
pub struct FmtConfig {
    /// Maximum line width (default 75).
    pub width: usize,
    /// Goal width for line filling (default 93% of width).
    pub goal: usize,
    /// Only split long lines, do not refill short lines.
    pub split_only: bool,
    /// Crown margin mode: preserve the indentation of the first two lines.
    pub crown_margin: bool,
    /// Tagged paragraph mode: first line indentation differs from subsequent lines.
    pub tagged: bool,
    /// Uniform spacing: one space between words, two after sentence-ending punctuation.
    pub uniform_spacing: bool,
    /// Only reformat lines beginning with this prefix.
    pub prefix: Option<String>,
}

impl Default for FmtConfig {
    fn default() -> Self {
        let width = 75;
        Self {
            width,
            goal: (width * 187) / 200,
            split_only: false,
            crown_margin: false,
            tagged: false,
            uniform_spacing: false,
            prefix: None,
        }
    }
}

/// 256-byte lookup table: 1 = ASCII whitespace (\t \n \x0B \x0C \r \x20), 0 = non-whitespace.
/// Using a lookup table avoids branch-heavy `is_ascii_whitespace()` per byte.
static WS_TABLE: [u8; 256] = {
    let mut t = [0u8; 256];
    t[b'\t' as usize] = 1;
    t[b'\n' as usize] = 1;
    t[0x0B] = 1; // vertical tab
    t[0x0C] = 1; // form feed
    t[b'\r' as usize] = 1;
    t[b' ' as usize] = 1;
    t
};

/// Fast whitespace check using lookup table.
#[inline(always)]
fn is_ws(b: u8) -> bool {
    // SAFETY: b as usize is always in 0..256
    unsafe { *WS_TABLE.get_unchecked(b as usize) != 0 }
}

/// Reusable DP and output buffers (no borrowed data, safe to carry across paragraphs).
struct DpBufs {
    winfo: Vec<u32>,
    dp_cost: Vec<i64>,
    best: Vec<u32>,
    line_len: Vec<i32>,
    line_buf: Vec<u8>,
}

impl DpBufs {
    fn new() -> Self {
        Self {
            winfo: Vec::with_capacity(256),
            dp_cost: Vec::with_capacity(257),
            best: Vec::with_capacity(256),
            line_len: Vec::with_capacity(257),
            line_buf: Vec::with_capacity(256),
        }
    }
}

/// Reformat text from `input` and write the result to `output`.
///
/// Text is processed paragraph by paragraph in a streaming fashion.
/// Each paragraph is formatted and written immediately, avoiding holding
/// the entire file in memory.
pub fn fmt_file<R: Read, W: Write>(
    mut input: R,
    output: &mut W,
    config: &FmtConfig,
) -> io::Result<()> {
    // Read entire input into a contiguous buffer to avoid per-line String allocation.
    let mut data = Vec::new();
    input.read_to_end(&mut data)?;
    fmt_data(&data, output, config)
}

/// Format in-memory data. Works on byte slices to avoid String allocation.
pub fn fmt_data(data: &[u8], output: &mut impl Write, config: &FmtConfig) -> io::Result<()> {
    // Convert to str once (fmt processes text, so UTF-8 is expected)
    let text = match std::str::from_utf8(data) {
        Ok(s) => s,
        Err(_) => {
            // Fallback: lossy conversion
            let owned = String::from_utf8_lossy(data);
            return fmt_str_owned(&owned, output, config);
        }
    };
    fmt_str(text, output, config)
}

/// Format a string slice, processing paragraph by paragraph with zero-copy word extraction.
fn fmt_str(text: &str, output: &mut impl Write, config: &FmtConfig) -> io::Result<()> {
    let prefix_str = config.prefix.as_deref();
    let mut para_start = 0;
    let bytes = text.as_bytes();
    let mut dp = DpBufs::new();

    // Scan through the text finding paragraph boundaries
    let mut i = 0;

    while i < bytes.len() {
        // Find end of current line using memchr for SIMD-accelerated newline search
        let line_end = memchr::memchr(b'\n', &bytes[i..])
            .map(|p| i + p)
            .unwrap_or(bytes.len());

        let line = &text[i..line_end];

        // Strip \r if present
        let line = line.strip_suffix('\r').unwrap_or(line);

        // Handle prefix filter
        if let Some(pfx) = prefix_str {
            if !line.starts_with(pfx) {
                // Flush current paragraph
                if para_start < i {
                    format_paragraph_str(text, para_start, i, config, output, &mut dp)?;
                }
                para_start = if line_end < bytes.len() {
                    line_end + 1
                } else {
                    bytes.len()
                };
                // Emit verbatim
                output.write_all(line.as_bytes())?;
                output.write_all(b"\n")?;
                i = para_start;
                continue;
            }
        }

        if line.trim().is_empty() {
            // Blank line = paragraph boundary
            if para_start < i {
                format_paragraph_str(text, para_start, i, config, output, &mut dp)?;
            }
            output.write_all(b"\n")?;
            para_start = if line_end < bytes.len() {
                line_end + 1
            } else {
                bytes.len()
            };
        }

        i = if line_end < bytes.len() {
            line_end + 1
        } else {
            bytes.len()
        };
    }

    // Flush remaining paragraph
    if para_start < bytes.len() {
        let remaining = text[para_start..].trim_end_matches('\n');
        if !remaining.is_empty() {
            format_paragraph_str(text, para_start, bytes.len(), config, output, &mut dp)?;
        }
    }

    Ok(())
}

/// Fallback for non-UTF8 data (owned String from lossy conversion)
fn fmt_str_owned(text: &str, output: &mut impl Write, config: &FmtConfig) -> io::Result<()> {
    fmt_str(text, output, config)
}

/// Format a paragraph from a region of the source text [start..end).
/// Extracts lines and words directly from the source text -- zero String allocation.
/// Uses single-pass memchr-based line extraction instead of split/map/filter/collect.
fn format_paragraph_str(
    text: &str,
    start: usize,
    end: usize,
    config: &FmtConfig,
    output: &mut impl Write,
    dp: &mut DpBufs,
) -> io::Result<()> {
    let region_bytes = &text.as_bytes()[start..end];

    // Single-pass line extraction using memchr
    let mut lines: Vec<&str> = Vec::with_capacity(16);
    {
        let mut pos = 0;
        let rlen = region_bytes.len();
        while pos < rlen {
            let nl = memchr::memchr(b'\n', &region_bytes[pos..])
                .map(|p| pos + p)
                .unwrap_or(rlen);
            let mut line_end = nl;
            // Strip \r
            if line_end > pos && region_bytes[line_end - 1] == b'\r' {
                line_end -= 1;
            }
            if line_end > pos {
                // SAFETY: start..end is a valid UTF-8 range (from text), and pos/line_end
                // are within that range, split only on ASCII boundaries (\n, \r).
                lines.push(&text[start + pos..start + line_end]);
            }
            pos = nl + 1;
        }
    }

    if lines.is_empty() {
        return Ok(());
    }

    let prefix_str = config.prefix.as_deref();

    // Strip the prefix from lines for indentation analysis.
    let stripped_first = match prefix_str {
        Some(pfx) => lines[0].strip_prefix(pfx).unwrap_or(lines[0]),
        None => lines[0],
    };

    let stripped_second: &str = if lines.len() > 1 {
        match prefix_str {
            Some(pfx) => lines[1].strip_prefix(pfx).unwrap_or(lines[1]),
            None => lines[1],
        }
    } else {
        stripped_first
    };

    let first_indent = leading_indent(stripped_first);
    let rest_indent = leading_indent(stripped_second);

    let (first_line_indent, cont_indent) = if config.tagged || config.crown_margin {
        (first_indent, rest_indent)
    } else {
        (first_indent, first_indent)
    };

    if config.split_only {
        for line in &lines {
            split_line_optimal(line, config, prefix_str, output)?;
        }
        return Ok(());
    }

    // Collect words directly from source text -- zero-copy &str references.
    let total_chars: usize = lines.iter().map(|l| l.len()).sum();
    let mut all_words: Vec<&str> = Vec::with_capacity(total_chars / 5 + 16);
    let mut sentence_ends: Vec<bool> = Vec::with_capacity(total_chars / 5 + 16);

    for line in &lines {
        let s = match prefix_str {
            Some(pfx) => line.strip_prefix(pfx).unwrap_or(line),
            None => line,
        };
        collect_words_with_sentence_info(s, &mut all_words, &mut sentence_ends);
    }

    if all_words.is_empty() {
        output.write_all(b"\n")?;
        return Ok(());
    }

    let pfx = prefix_str.unwrap_or("");
    reflow_paragraph(
        &all_words,
        &sentence_ends,
        pfx,
        first_line_indent,
        cont_indent,
        config,
        output,
        dp,
    )
}

/// Determine the leading whitespace (indentation) of a line.
fn leading_indent(line: &str) -> &str {
    let trimmed = line.trim_start();
    &line[..line.len() - trimmed.len()]
}

/// Analyze the trailing punctuation of a word in a single pass.
/// Returns (has_sentence_punct, has_non_period_punct) where:
/// - has_sentence_punct: word ends with .!? (after stripping closing quotes/brackets)
/// - has_non_period_punct: word ends with ,;: (after stripping closing quotes/brackets)
/// This replaces separate `has_sentence_ending_punct()` and `has_non_period_punct()` calls.
#[inline(always)]
fn analyze_word_punct(bytes: &[u8]) -> (bool, bool) {
    let mut i = bytes.len();
    // Walk backwards past closing quotes/brackets
    while i > 0 && matches!(bytes[i - 1], b'"' | b'\'' | b')' | b']') {
        i -= 1;
    }
    if i == 0 {
        return (false, false);
    }
    let c = bytes[i - 1];
    (
        c == b'.' || c == b'!' || c == b'?',
        c == b',' || c == b';' || c == b':',
    )
}

/// Check if a word ends a sentence, considering original input context.
/// GNU fmt rules: a word ending in .?! is a sentence end if:
/// 1. It was followed by 2+ spaces in the original input, OR
/// 2. It was at the end of a line
/// Additionally, single uppercase letters (like "E.") are abbreviations, not sentence ends.
#[inline(always)]
fn is_sentence_end_contextual(
    word_bytes: &[u8],
    has_sent_punct: bool,
    followed_by_double_space_or_eol: bool,
) -> bool {
    if !has_sent_punct || !followed_by_double_space_or_eol {
        return false;
    }
    // Strip trailing punctuation to find the "core" word
    let mut end = word_bytes.len();
    while end > 0
        && matches!(
            word_bytes[end - 1],
            b'.' | b'!' | b'?' | b'"' | b'\'' | b')' | b']'
        )
    {
        end -= 1;
    }
    // A single uppercase letter followed by '.' is an abbreviation, not a sentence end
    if end == 1 && word_bytes[0].is_ascii_uppercase() {
        return false;
    }
    // Empty core (e.g., just "." or "...") is not a sentence end
    end > 0
}

/// Word flags for GNU fmt cost model.
/// Packed into the upper bits of the winfo u32 array for cache efficiency.
const SENT_FLAG: u32 = 1 << 16; // sentence-final (period + double-space/eol context)
const PERIOD_FLAG: u32 = 1 << 17; // has sentence-ending punct (.!?) regardless of context
const PUNCT_FLAG: u32 = 1 << 18; // ends with non-period punctuation (,;:)
const PAREN_FLAG: u32 = 1 << 19; // starts with opening paren/bracket

/// Collect words from a line, tracking sentence endings and word properties
/// for the GNU fmt cost model. Uses lookup-table whitespace scanning.
fn collect_words_with_sentence_info<'a>(
    line: &'a str,
    words: &mut Vec<&'a str>,
    sentence_ends: &mut Vec<bool>,
) {
    let bytes = line.as_bytes();
    let len = bytes.len();
    let mut i = 0;

    // Skip leading whitespace using lookup table
    while i < len && is_ws(bytes[i]) {
        i += 1;
    }

    while i < len {
        // Find end of word using lookup table
        let word_start = i;
        while i < len && !is_ws(bytes[i]) {
            i += 1;
        }
        let word = &line[word_start..i];
        let word_bytes = &bytes[word_start..i];

        // Count spaces after this word using lookup table
        let space_start = i;
        while i < len && is_ws(bytes[i]) {
            i += 1;
        }
        let space_count = i - space_start;

        // Analyze punctuation in one pass
        let (has_sent_punct, _) = analyze_word_punct(word_bytes);
        let is_sent_end =
            is_sentence_end_contextual(word_bytes, has_sent_punct, i >= len || space_count >= 2);

        words.push(word);
        sentence_ends.push(is_sent_end);
    }
}

/// Reflow words into lines that fit within the configured width.
///
/// Uses optimal line breaking with a cost function matching GNU fmt.
/// Builds each output line in a buffer and writes once, avoiding multiple
/// small write_all() calls per line. Reuses DP buffers across paragraphs.
#[allow(clippy::too_many_arguments)]
fn reflow_paragraph<W: Write>(
    words: &[&str],
    sentence_ends: &[bool],
    prefix: &str,
    first_indent: &str,
    cont_indent: &str,
    config: &FmtConfig,
    output: &mut W,
    dp: &mut DpBufs,
) -> io::Result<()> {
    if words.is_empty() {
        return Ok(());
    }

    let n = words.len();
    let first_base = prefix.len() + first_indent.len();
    let cont_base = prefix.len() + cont_indent.len();
    let goal = config.goal as i64;
    let width = config.width;
    debug_assert_eq!(sentence_ends.len(), words.len());

    // GNU fmt cost model constants
    const SHORT_FACTOR: i64 = 100;
    const RAGGED_FACTOR: i64 = 50;
    const LINE_COST: i64 = 70 * 70;
    const SENTENCE_BONUS: i64 = 50 * 50;
    const NOBREAK_COST: i64 = 600 * 600;
    const PUNCT_BONUS: i64 = 40 * 40;
    const PAREN_BONUS: i64 = 40 * 40;

    // Reuse winfo buffer
    dp.winfo.clear();
    if dp.winfo.capacity() < n {
        dp.winfo.reserve(n - dp.winfo.capacity());
    }
    for (i, w) in words.iter().enumerate() {
        debug_assert!(w.len() <= 0xFFFF, "word too long for winfo packing");
        let len = w.len() as u32;
        let wb = w.as_bytes();
        let mut flags = 0u32;

        if sentence_ends[i] {
            flags |= SENT_FLAG;
        }

        let (has_sent_punct, has_np_punct) = analyze_word_punct(wb);
        if has_sent_punct {
            flags |= PERIOD_FLAG;
        }
        if has_np_punct {
            flags |= PUNCT_FLAG;
        }
        if !wb.is_empty() && matches!(wb[0], b'(' | b'[' | b'{') {
            flags |= PAREN_FLAG;
        }
        if i == n - 1 {
            flags |= SENT_FLAG | PERIOD_FLAG;
        }
        dp.winfo.push(len | flags);
    }

    // Reuse DP buffers
    dp.dp_cost.clear();
    dp.dp_cost.resize(n + 1, i64::MAX);
    dp.dp_cost[n] = 0;

    dp.best.clear();
    dp.best.resize(n, 0);

    dp.line_len.clear();
    dp.line_len.resize(n + 1, 0);

    // SAFETY: All array indices are provably in-bounds (see original proof).
    let winfo_ptr = dp.winfo.as_ptr();
    let dp_cost_ptr = dp.dp_cost.as_mut_ptr();
    let best_ptr = dp.best.as_mut_ptr();
    let line_len_ptr = dp.line_len.as_mut_ptr();

    for i in (0..n).rev() {
        let base = if i == 0 { first_base } else { cont_base };
        let mut len = base + unsafe { (*winfo_ptr.add(i) & 0xFFFF) as usize };
        let mut best_total = i64::MAX;
        let mut best_j = i as u32;
        let mut best_len = len as i32;

        for j in i..n {
            if j > i {
                let sep = if unsafe { *winfo_ptr.add(j - 1) & SENT_FLAG != 0 } {
                    2
                } else {
                    1
                };
                len += sep + unsafe { (*winfo_ptr.add(j) & 0xFFFF) as usize };
            }

            macro_rules! try_candidate {
                () => {
                    let lc = if j == n - 1 {
                        0i64
                    } else {
                        let short_n = goal - len as i64;
                        let short_cost = short_n * short_n * SHORT_FACTOR;
                        let ragged_cost = if unsafe { *best_ptr.add(j + 1) as usize + 1 < n } {
                            let ragged_n = len as i64 - unsafe { *line_len_ptr.add(j + 1) } as i64;
                            ragged_n * ragged_n * RAGGED_FACTOR
                        } else {
                            0
                        };
                        short_cost + ragged_cost
                    };

                    let bc = if j == n - 1 {
                        0i64
                    } else {
                        let wj = unsafe { *winfo_ptr.add(j) };
                        let wj1 = unsafe { *winfo_ptr.add(j + 1) };
                        let mut cost = LINE_COST;

                        if wj & PERIOD_FLAG != 0 {
                            if wj & SENT_FLAG != 0 {
                                cost -= SENTENCE_BONUS;
                            } else {
                                cost += NOBREAK_COST;
                            }
                        } else if wj & PUNCT_FLAG != 0 {
                            cost -= PUNCT_BONUS;
                        } else if j > 0 {
                            let wjm1 = unsafe { *winfo_ptr.add(j - 1) };
                            if wjm1 & SENT_FLAG != 0 {
                                let word_len = (wj & 0xFFFF) as i64;
                                cost += 40000 / (word_len + 2);
                            }
                        }

                        if wj1 & PAREN_FLAG != 0 {
                            cost -= PAREN_BONUS;
                        } else if wj1 & SENT_FLAG != 0 {
                            let word_len = (wj1 & 0xFFFF) as i64;
                            cost += 22500 / (word_len + 2);
                        }

                        cost
                    };

                    let cj1 = unsafe { *dp_cost_ptr.add(j + 1) };
                    if cj1 != i64::MAX {
                        let total = lc + bc + cj1;
                        if total < best_total {
                            best_total = total;
                            best_j = j as u32;
                            best_len = len as i32;
                        }
                    }
                };
            }

            if len >= width {
                if j == i {
                    try_candidate!();
                }
                break;
            }

            try_candidate!();
        }

        if best_total < i64::MAX {
            unsafe {
                *dp_cost_ptr.add(i) = best_total;
                *best_ptr.add(i) = best_j;
                *line_len_ptr.add(i) = best_len;
            }
        }
    }

    // Reconstruct lines from DP solution.
    // Build each line in a buffer and write once.
    let mut i = 0;
    let mut is_first_line = true;
    let line_buf = &mut dp.line_buf;

    while i < n {
        let j = dp.best[i] as usize;

        line_buf.clear();

        line_buf.extend_from_slice(prefix.as_bytes());
        if is_first_line {
            line_buf.extend_from_slice(first_indent.as_bytes());
        } else {
            line_buf.extend_from_slice(cont_indent.as_bytes());
        }
        line_buf.extend_from_slice(words[i].as_bytes());

        for k in (i + 1)..=j {
            if dp.winfo[k - 1] & SENT_FLAG != 0 {
                line_buf.extend_from_slice(b"  ");
            } else {
                line_buf.push(b' ');
            }
            line_buf.extend_from_slice(words[k].as_bytes());
        }
        line_buf.push(b'\n');

        output.write_all(line_buf)?;

        is_first_line = false;
        i = j + 1;
    }

    Ok(())
}

/// Split a single input line using the optimal paragraph algorithm.
/// Used in split-only mode (-s): short lines are preserved as-is,
/// long lines are broken optimally (same algorithm as normal reflow).
fn split_line_optimal<W: Write>(
    line: &str,
    config: &FmtConfig,
    prefix: Option<&str>,
    output: &mut W,
) -> io::Result<()> {
    let stripped = match prefix {
        Some(pfx) => line.strip_prefix(pfx).unwrap_or(line),
        None => line,
    };
    let indent = leading_indent(stripped);
    let pfx = prefix.unwrap_or("");

    // Short line: output as-is (no splitting needed).
    if line.len() < config.width {
        output.write_all(line.as_bytes())?;
        output.write_all(b"\n")?;
        return Ok(());
    }

    let s = match prefix {
        Some(pfx) => line.strip_prefix(pfx).unwrap_or(line),
        None => line,
    };

    let mut words: Vec<&str> = Vec::new();
    let mut sentence_ends: Vec<bool> = Vec::new();
    collect_words_with_sentence_info(s, &mut words, &mut sentence_ends);

    if words.is_empty() {
        output.write_all(line.as_bytes())?;
        output.write_all(b"\n")?;
        return Ok(());
    }

    let mut dp = DpBufs::new();
    reflow_paragraph(
        &words,
        &sentence_ends,
        pfx,
        indent,
        indent,
        config,
        output,
        &mut dp,
    )
}
