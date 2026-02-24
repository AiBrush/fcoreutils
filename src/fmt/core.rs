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

    // Scan through the text finding paragraph boundaries
    let mut i = 0;
    let _para_lines_start = 0; // byte offset where current paragraph starts

    while i < bytes.len() {
        // Find end of current line
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
                    format_paragraph_str(text, para_start, i, config, output)?;
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
                format_paragraph_str(text, para_start, i, config, output)?;
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
            format_paragraph_str(text, para_start, bytes.len(), config, output)?;
        }
    }

    Ok(())
}

/// Fallback for non-UTF8 data (owned String from lossy conversion)
fn fmt_str_owned(text: &str, output: &mut impl Write, config: &FmtConfig) -> io::Result<()> {
    fmt_str(text, output, config)
}

/// Format a paragraph from a region of the source text [start..end).
/// Extracts lines and words directly from the source text — zero String allocation.
fn format_paragraph_str(
    text: &str,
    start: usize,
    end: usize,
    config: &FmtConfig,
    output: &mut impl Write,
) -> io::Result<()> {
    let region = &text[start..end];
    // Collect lines (without trailing newlines)
    let lines: Vec<&str> = region
        .split('\n')
        .map(|l| l.strip_suffix('\r').unwrap_or(l))
        .filter(|l| !l.is_empty())
        .collect();

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
            split_long_line(line, config, prefix_str, output)?;
        }
        return Ok(());
    }

    // Collect words directly from source text — zero-copy &str references.
    // Also track which words are sentence endings based on original spacing:
    // A word ending in .?! is a sentence end if followed by 2+ spaces or end of line.
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
    )
}

/// Determine the leading whitespace (indentation) of a line.
fn leading_indent(line: &str) -> &str {
    let trimmed = line.trim_start();
    &line[..line.len() - trimmed.len()]
}

/// Check if a word has sentence-ending punctuation (ends with '.', '!', or '?',
/// possibly followed by closing quotes/brackets).
fn has_sentence_ending_punct(word: &str) -> bool {
    let bytes = word.as_bytes();
    // Walk backwards past closing punctuation
    let mut i = bytes.len();
    while i > 0 && matches!(bytes[i - 1], b'"' | b'\'' | b')' | b']') {
        i -= 1;
    }
    i > 0 && matches!(bytes[i - 1], b'.' | b'!' | b'?')
}

/// Check if a word ends a sentence, considering original input context.
/// GNU fmt rules: a word ending in .?! is a sentence end if:
/// 1. It was followed by 2+ spaces in the original input, OR
/// 2. It was at the end of a line
/// Additionally, single uppercase letters (like "E.") are abbreviations, not sentence ends.
fn is_sentence_end_contextual(word: &str, followed_by_double_space_or_eol: bool) -> bool {
    if !has_sentence_ending_punct(word) {
        return false;
    }
    if !followed_by_double_space_or_eol {
        return false;
    }
    // Strip trailing punctuation to find the "core" word
    let bytes = word.as_bytes();
    let mut end = bytes.len();
    while end > 0
        && matches!(
            bytes[end - 1],
            b'.' | b'!' | b'?' | b'"' | b'\'' | b')' | b']'
        )
    {
        end -= 1;
    }
    // A single uppercase letter followed by '.' is an abbreviation, not a sentence end
    if end == 1 && bytes[0].is_ascii_uppercase() {
        return false;
    }
    // Empty core (e.g., just "." or "...") is not a sentence end
    end > 0
}

/// Collect words from a line, tracking which words are sentence endings
/// based on the original spacing context.
fn collect_words_with_sentence_info<'a>(
    line: &'a str,
    words: &mut Vec<&'a str>,
    sentence_ends: &mut Vec<bool>,
) {
    let bytes = line.as_bytes();
    let len = bytes.len();
    let mut i = 0;

    // Skip leading whitespace
    while i < len && bytes[i].is_ascii_whitespace() {
        i += 1;
    }

    while i < len {
        // Find end of word
        let word_start = i;
        while i < len && !bytes[i].is_ascii_whitespace() {
            i += 1;
        }
        let word = &line[word_start..i];

        // Count spaces after this word
        let space_start = i;
        while i < len && bytes[i].is_ascii_whitespace() {
            i += 1;
        }
        let space_count = i - space_start;

        // Sentence end: at end of line (i >= len) or followed by 2+ spaces
        let at_eol = i >= len;
        let double_space = space_count >= 2;

        // If there was a previous word, mark it
        // (the sentence_ends entry corresponds to the PREVIOUS word)
        // But we need to record for THIS word
        let is_sent_end = is_sentence_end_contextual(word, at_eol || double_space);

        words.push(word);
        sentence_ends.push(is_sent_end);
    }
}


/// Reflow words into lines that fit within the configured width.
///
/// Uses optimal line breaking with a cost function matching GNU fmt.
/// Writes directly to the output writer, avoiding intermediate String allocation.
/// Eliminates pre-computed arrays: sep_widths, word_lens, break_cost, has_more_lines
/// are all computed inline to reduce memory footprint and improve cache performance.
fn reflow_paragraph<W: Write>(
    words: &[&str],
    sentence_ends: &[bool],
    prefix: &str,
    first_indent: &str,
    cont_indent: &str,
    config: &FmtConfig,
    output: &mut W,
) -> io::Result<()> {
    if words.is_empty() {
        return Ok(());
    }

    let n = words.len();
    let first_base = prefix.len() + first_indent.len();
    let cont_base = prefix.len() + cont_indent.len();
    let goal = config.goal as i64;
    let width = config.width;
    let _uniform = config.uniform_spacing;

    // GNU fmt cost model: SHORT_COST(n) = EQUIV(n*10) = (n*10)^2 = n^2 * 100
    // RAGGED_COST(n) = SHORT_COST(n) / 2 = n^2 * 50
    // LINE_COST = EQUIV(70) = 4900, SENTENCE_BONUS = EQUIV(50) = 2500
    const SHORT_FACTOR: i64 = 100;
    const RAGGED_FACTOR: i64 = 50;
    const LINE_COST: i64 = 70 * 70;
    const SENTENCE_BONUS: i64 = 50 * 50;
    const SENT_FLAG: u32 = 1 << 16;

    // Pack word length + sentence-end flag into compact u32 array.
    // bits 0-15: word length, bit 16: sentence-end flag.
    // This is 4 bytes/word vs 16 bytes/word for fat pointers — much better cache usage.
    let winfo: Vec<u32> = words
        .iter()
        .enumerate()
        .map(|(i, w)| {
            let len = w.len() as u32;
            let sent = if sentence_ends.get(i).copied().unwrap_or(false) {
                SENT_FLAG
            } else {
                0
            };
            len | sent
        })
        .collect();

    // 3 DP arrays: cost, best break point, line length
    let mut dp_cost = vec![i64::MAX; n + 1];
    let mut best = vec![0u32; n];
    let mut line_len = vec![0i32; n + 1];
    dp_cost[n] = 0;

    // SAFETY: All array indices are provably in-bounds:
    // - i ∈ [0, n-1] for winfo[i], best[i], dp_cost[i], line_len[i]
    // - j ∈ [i, n-1] for winfo[j], j-1 ∈ [0, n-2] for winfo[j-1]
    // - j+1 ∈ [1, n] for dp_cost[j+1] (n+1 elements), best[j+1] (n elements, only when j<n-1)
    // - line_len has n+1 elements, accessed at i and j+1
    let winfo_ptr = winfo.as_ptr();
    let dp_cost_ptr = dp_cost.as_mut_ptr();
    let best_ptr = best.as_mut_ptr();
    let line_len_ptr = line_len.as_mut_ptr();

    for i in (0..n).rev() {
        let base = if i == 0 { first_base } else { cont_base };
        let mut len = base + unsafe { (*winfo_ptr.add(i) & 0xFFFF) as usize };
        let mut best_total = i64::MAX;
        let mut best_j = i as u32;
        let mut best_len = len as i32;

        for j in i..n {
            if j > i {
                // GNU fmt always uses 2 spaces after sentence-ending punctuation
                let sep = if unsafe { *winfo_ptr.add(j - 1) & SENT_FLAG != 0 } {
                    2
                } else {
                    1
                };
                len += sep + unsafe { (*winfo_ptr.add(j) & 0xFFFF) as usize };
            }

            // Compute line cost for placing words i..=j on one line.
            // Extracted to avoid duplication between the overflow and normal branches.
            macro_rules! try_candidate {
                () => {
                    let lc = if j == n - 1 {
                        0i64
                    } else {
                        let bc = if unsafe { *winfo_ptr.add(j) & SENT_FLAG != 0 } {
                            LINE_COST - SENTENCE_BONUS
                        } else {
                            LINE_COST
                        };
                        let short_n = goal - len as i64;
                        let short_cost = short_n * short_n * SHORT_FACTOR;
                        let ragged_cost = if unsafe { *best_ptr.add(j + 1) as usize + 1 < n } {
                            let ragged_n = len as i64 - unsafe { *line_len_ptr.add(j + 1) } as i64;
                            ragged_n * ragged_n * RAGGED_FACTOR
                        } else {
                            0
                        };
                        bc + short_cost + ragged_cost
                    };
                    let cj1 = unsafe { *dp_cost_ptr.add(j + 1) };
                    if cj1 != i64::MAX {
                        let total = lc + cj1;
                        if total < best_total {
                            best_total = total;
                            best_j = j as u32;
                            best_len = len as i32;
                        }
                    }
                };
            }

            if len > width {
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

    // Reconstruct the lines from the DP solution, writing directly to output.
    let mut i = 0;
    let mut is_first_line = true;

    while i < n {
        let j = best[i] as usize;

        output.write_all(prefix.as_bytes())?;
        if is_first_line {
            output.write_all(first_indent.as_bytes())?;
        } else {
            output.write_all(cont_indent.as_bytes())?;
        }
        output.write_all(words[i].as_bytes())?;

        for k in (i + 1)..=j {
            // GNU fmt uses 2 spaces after sentence-ending punctuation
            // (only when the original input had 2+ spaces or end-of-line after it)
            if sentence_ends.get(k - 1).copied().unwrap_or(false) {
                output.write_all(b"  ")?;
            } else {
                output.write_all(b" ")?;
            }
            output.write_all(words[k].as_bytes())?;
        }
        output.write_all(b"\n")?;

        is_first_line = false;
        i = j + 1;
    }

    Ok(())
}

/// Split a single long line at the width boundary without reflowing.
/// Used in split-only mode (-s).
fn split_long_line<W: Write>(
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

    if line.len() <= config.width {
        output.write_all(line.as_bytes())?;
        output.write_all(b"\n")?;
        return Ok(());
    }

    let s = match prefix {
        Some(pfx) => line.strip_prefix(pfx).unwrap_or(line),
        None => line,
    };

    let pfx_indent_len = pfx.len() + indent.len();
    let mut cur_len = pfx_indent_len;
    let mut first_word_on_line = true;

    // Write initial prefix+indent
    output.write_all(pfx.as_bytes())?;
    output.write_all(indent.as_bytes())?;

    // GNU fmt -s uses the goal width for soft-breaking, and width as hard limit.
    // Break preferentially at goal, but always break before exceeding width.
    for word in s.split_whitespace() {
        if !first_word_on_line {
            let new_len = cur_len + 1 + word.len();
            if new_len > config.width || (new_len > config.goal && cur_len > pfx_indent_len) {
                output.write_all(b"\n")?;
                output.write_all(pfx.as_bytes())?;
                output.write_all(indent.as_bytes())?;
                cur_len = pfx_indent_len;
                first_word_on_line = true;
            }
        }

        if !first_word_on_line {
            output.write_all(b" ")?;
            cur_len += 1;
        }
        output.write_all(word.as_bytes())?;
        cur_len += word.len();
        first_word_on_line = false;
    }

    if !first_word_on_line {
        output.write_all(b"\n")?;
    }

    Ok(())
}
