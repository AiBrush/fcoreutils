use std::collections::HashSet;
use std::io::{self, BufRead, Write};

/// Output format for ptx.
#[derive(Clone, Debug, PartialEq)]
pub enum OutputFormat {
    /// Default GNU ptx output format (roff-like).
    Roff,
    /// TeX output format.
    Tex,
    /// Dumb terminal / plain text format.
    Plain,
}

/// Configuration for the ptx command.
#[derive(Clone, Debug)]
pub struct PtxConfig {
    pub width: usize,
    pub ignore_case: bool,
    pub auto_reference: bool,
    pub traditional: bool,
    pub format: OutputFormat,
    pub ignore_words: HashSet<String>,
    pub only_words: Option<HashSet<String>>,
    pub references: bool,
    pub gap_size: usize,
    pub right_reference: bool,
    pub sentence_regexp: Option<String>,
    pub word_regexp: Option<String>,
    pub flag_truncation: Option<String>,
    pub macro_name: Option<String>,
}

impl Default for PtxConfig {
    fn default() -> Self {
        Self {
            width: 72,
            ignore_case: false,
            auto_reference: false,
            traditional: false,
            format: OutputFormat::Plain,
            ignore_words: HashSet::new(),
            only_words: None,
            references: false,
            gap_size: 3,
            right_reference: false,
            sentence_regexp: None,
            word_regexp: None,
            flag_truncation: None,
            macro_name: None,
        }
    }
}

/// Pre-normalized word sets for O(1) case-insensitive lookup.
struct NormalizedSets {
    ignore_lower: HashSet<String>,
    only_lower: Option<HashSet<String>>,
}

impl NormalizedSets {
    fn new(config: &PtxConfig) -> Self {
        if config.ignore_case {
            let ignore_lower = config
                .ignore_words
                .iter()
                .map(|w| w.to_lowercase())
                .collect();
            let only_lower = config
                .only_words
                .as_ref()
                .map(|s| s.iter().map(|w| w.to_lowercase()).collect());
            Self {
                ignore_lower,
                only_lower,
            }
        } else {
            // No normalization needed - we'll use the original sets directly
            Self {
                ignore_lower: HashSet::new(),
                only_lower: None,
            }
        }
    }
}

/// Compact KWIC entry — no owned strings, just indices.
struct KwicEntry {
    line_idx: u32,
    word_start: u32,
    word_len: u16,
}

/// Computed layout fields for a KWIC entry — all borrowed slices.
struct LayoutFields<'a> {
    tail: &'a str,
    before: &'a str,
    keyafter: &'a str,
    keyword: &'a str,
    after: &'a str,
    head: &'a str,
    tail_truncated: bool,
    before_truncated: bool,
    keyafter_truncated: bool,
    head_truncated: bool,
}

// Static padding buffer for fast space-filling
const SPACES: &[u8; 256] = b"                                                                                                                                                                                                                                                                ";

/// Write `n` spaces to the writer.
#[inline]
fn write_spaces<W: Write>(out: &mut W, n: usize) -> io::Result<()> {
    let mut remaining = n;
    while remaining > 0 {
        let chunk = remaining.min(SPACES.len());
        out.write_all(&SPACES[..chunk])?;
        remaining -= chunk;
    }
    Ok(())
}

/// Extract words from a line of text.
///
/// GNU ptx's default word regex is effectively `[a-zA-Z][a-zA-Z0-9]*`.
fn extract_words(line: &str) -> Vec<(usize, &str)> {
    let mut words = Vec::new();
    let bytes = line.as_bytes();
    let len = bytes.len();
    let mut i = 0;

    while i < len {
        if bytes[i].is_ascii_alphabetic() {
            let start = i;
            i += 1;
            while i < len && bytes[i].is_ascii_alphanumeric() {
                i += 1;
            }
            words.push((start, &line[start..i]));
        } else {
            i += 1;
        }
    }

    words
}

/// Check if a word should be indexed, using pre-normalized sets.
#[inline]
fn should_index(word: &str, config: &PtxConfig, norm: &NormalizedSets) -> bool {
    if config.ignore_case {
        // Use pre-normalized lowercase sets for O(1) lookup
        if let Some(ref only) = norm.only_lower {
            // Must be in only-set
            let lower = word.to_ascii_lowercase();
            return only.contains(lower.as_str());
        }
        let lower = word.to_ascii_lowercase();
        !norm.ignore_lower.contains(lower.as_str())
    } else {
        if let Some(ref only) = config.only_words {
            return only.contains(word);
        }
        !config.ignore_words.contains(word)
    }
}

/// Generate KWIC entries and compute max_word_length in a single pass.
fn generate_entries(
    lines: &[(String, String)],
    config: &PtxConfig,
    norm: &NormalizedSets,
) -> (Vec<KwicEntry>, usize) {
    let mut entries = Vec::new();
    let mut max_word_length: usize = 0;

    for (line_idx, (_reference, line)) in lines.iter().enumerate() {
        let words = extract_words(line);

        for &(word_start, word) in &words {
            let wlen = word.len();
            if wlen > max_word_length {
                max_word_length = wlen;
            }

            if !should_index(word, config, norm) {
                continue;
            }

            entries.push(KwicEntry {
                line_idx: line_idx as u32,
                word_start: word_start as u32,
                word_len: wlen as u16,
            });
        }
    }

    // Sort by keyword (case-insensitive if requested), then by reference
    if config.ignore_case {
        entries.sort_unstable_by(|a, b| {
            let a_line = &lines[a.line_idx as usize].1;
            let b_line = &lines[b.line_idx as usize].1;
            let a_kw = &a_line[a.word_start as usize..a.word_start as usize + a.word_len as usize];
            let b_kw = &b_line[b.word_start as usize..b.word_start as usize + b.word_len as usize];
            a_kw.bytes()
                .map(|c| c.to_ascii_lowercase())
                .cmp(b_kw.bytes().map(|c| c.to_ascii_lowercase()))
                .then_with(|| {
                    lines[a.line_idx as usize]
                        .0
                        .cmp(&lines[b.line_idx as usize].0)
                })
        });
    } else {
        entries.sort_unstable_by(|a, b| {
            let a_line = &lines[a.line_idx as usize].1;
            let b_line = &lines[b.line_idx as usize].1;
            let a_kw = &a_line[a.word_start as usize..a.word_start as usize + a.word_len as usize];
            let b_kw = &b_line[b.word_start as usize..b.word_start as usize + b.word_len as usize];
            a_kw.cmp(b_kw).then_with(|| {
                lines[a.line_idx as usize]
                    .0
                    .cmp(&lines[b.line_idx as usize].0)
            })
        });
    }

    (entries, max_word_length)
}

/// Advance past one "word" or one non-word char.
#[inline]
fn skip_something(s: &str, pos: usize) -> usize {
    if pos >= s.len() {
        return pos;
    }
    let bytes = s.as_bytes();
    if bytes[pos].is_ascii_alphabetic() {
        let mut p = pos + 1;
        while p < s.len() && bytes[p].is_ascii_alphanumeric() {
            p += 1;
        }
        p
    } else {
        pos + 1
    }
}

/// Skip whitespace forward from position.
#[inline]
fn skip_white(s: &str, pos: usize) -> usize {
    let bytes = s.as_bytes();
    let mut p = pos;
    while p < s.len() && bytes[p].is_ascii_whitespace() {
        p += 1;
    }
    p
}

/// Skip whitespace backward from position (exclusive end).
#[inline]
fn skip_white_backwards(s: &str, pos: usize, start: usize) -> usize {
    let bytes = s.as_bytes();
    let mut p = pos;
    while p > start && bytes[p - 1].is_ascii_whitespace() {
        p -= 1;
    }
    p
}

/// Compute the layout fields for a KWIC entry.
fn compute_layout<'a>(
    sentence: &'a str,
    word_start: usize,
    keyword_len: usize,
    ref_str: &str,
    config: &PtxConfig,
    max_word_length: usize,
    ref_max_width: usize,
) -> LayoutFields<'a> {
    let total_width = config.width;
    let gap = config.gap_size;
    let trunc_len = 1; // "/" is 1 char

    let ref_width = if ref_str.is_empty() || config.right_reference {
        0
    } else {
        ref_max_width + gap
    };

    let line_width = if total_width > ref_width {
        total_width - ref_width
    } else {
        total_width
    };

    let half_line_width = line_width / 2;

    let before_max_width = if half_line_width > gap + 2 * trunc_len {
        half_line_width - gap - 2 * trunc_len
    } else {
        0
    };
    let keyafter_max_width = if half_line_width > 2 * trunc_len {
        half_line_width - 2 * trunc_len
    } else {
        0
    };

    let line_len = sentence.len();

    // ========== Step 1: Compute keyafter ==========
    let keyafter_start = word_start;
    let mut keyafter_end = word_start + keyword_len;
    {
        let mut cursor = keyafter_end;
        while cursor < line_len && cursor <= keyafter_start + keyafter_max_width {
            keyafter_end = cursor;
            cursor = skip_something(sentence, cursor);
        }
        if cursor <= keyafter_start + keyafter_max_width {
            keyafter_end = cursor;
        }
    }
    let mut keyafter_truncation = keyafter_end < line_len;
    keyafter_end = skip_white_backwards(sentence, keyafter_end, keyafter_start);

    // ========== Compute left_field_start ==========
    let left_context_start: usize = 0;
    let left_field_start = if word_start > half_line_width + max_word_length {
        let lfs = word_start - (half_line_width + max_word_length);
        skip_something(sentence, lfs)
    } else {
        left_context_start
    };

    // ========== Step 2: Compute before ==========
    let mut before_start: usize = left_field_start;
    let mut before_end = keyafter_start;
    before_end = skip_white_backwards(sentence, before_end, before_start);

    while before_start + before_max_width < before_end {
        before_start = skip_something(sentence, before_start);
    }

    let mut before_truncation = {
        let cursor = skip_white_backwards(sentence, before_start, 0);
        cursor > left_context_start
    };

    before_start = skip_white(sentence, before_start);
    let before_len = if before_end > before_start {
        before_end - before_start
    } else {
        0
    };

    // ========== Step 3: Compute tail ==========
    let tail_max_width_raw: isize = before_max_width as isize - before_len as isize - gap as isize;
    let mut tail_start: usize = 0;
    let mut tail_end: usize = 0;
    let mut tail_truncation = false;
    let mut has_tail = false;

    if tail_max_width_raw > 0 {
        let tail_max_width = tail_max_width_raw as usize;
        tail_start = skip_white(sentence, keyafter_end);
        tail_end = tail_start;
        let mut cursor = tail_end;
        while cursor < line_len && cursor < tail_start + tail_max_width {
            tail_end = cursor;
            cursor = skip_something(sentence, cursor);
        }
        if cursor < tail_start + tail_max_width {
            tail_end = cursor;
        }

        if tail_end > tail_start {
            has_tail = true;
            keyafter_truncation = false;
            tail_truncation = tail_end < line_len;
        } else {
            tail_truncation = false;
        }

        tail_end = skip_white_backwards(sentence, tail_end, tail_start);
    }

    // ========== Step 4: Compute head ==========
    let keyafter_len = if keyafter_end > keyafter_start {
        keyafter_end - keyafter_start
    } else {
        0
    };
    let head_max_width_raw: isize =
        keyafter_max_width as isize - keyafter_len as isize - gap as isize;
    let mut head_start: usize = 0;
    let mut head_end: usize = 0;
    let mut head_truncation = false;
    let mut has_head = false;

    if head_max_width_raw > 0 {
        let head_max_width = head_max_width_raw as usize;
        head_end = skip_white_backwards(sentence, before_start, 0);

        head_start = left_field_start;
        while head_start + head_max_width < head_end {
            head_start = skip_something(sentence, head_start);
        }

        if head_end > head_start {
            has_head = true;
            before_truncation = false;
            head_truncation = {
                let cursor = skip_white_backwards(sentence, head_start, 0);
                cursor > left_context_start
            };
        } else {
            head_truncation = false;
        }

        if head_end > head_start {
            head_start = skip_white(sentence, head_start);
        }
    }

    // ========== Extract text fields as slices ==========
    let before_text = if before_len > 0 {
        &sentence[before_start..before_end]
    } else {
        ""
    };
    let keyafter_text = if keyafter_end > keyafter_start {
        &sentence[keyafter_start..keyafter_end]
    } else {
        ""
    };
    let tail_text = if has_tail && tail_end > tail_start {
        &sentence[tail_start..tail_end]
    } else {
        ""
    };
    let head_text = if has_head && head_end > head_start {
        &sentence[head_start..head_end]
    } else {
        ""
    };

    let keyword_text = &sentence[word_start..word_start + keyword_len];
    let after_start = word_start + keyword_len;
    let after_text = if keyafter_end > after_start {
        &sentence[after_start..keyafter_end]
    } else {
        ""
    };

    LayoutFields {
        tail: tail_text,
        before: before_text,
        keyafter: keyafter_text,
        keyword: keyword_text,
        after: after_text,
        head: head_text,
        tail_truncated: tail_truncation,
        before_truncated: before_truncation,
        keyafter_truncated: keyafter_truncation,
        head_truncated: head_truncation,
    }
}

/// Write a KWIC entry in plain text format directly to the output.
fn write_plain<W: Write>(
    out: &mut W,
    ref_str: &str,
    config: &PtxConfig,
    layout: &LayoutFields<'_>,
    ref_max_width: usize,
) -> io::Result<()> {
    let total_width = config.width;
    let gap = config.gap_size;
    let trunc_str = config.flag_truncation.as_deref().unwrap_or("/");
    let trunc_len = trunc_str.len();

    let ref_width = if ref_str.is_empty() || config.right_reference {
        0
    } else {
        ref_max_width + gap
    };

    let line_width = if total_width > ref_width {
        total_width - ref_width
    } else {
        total_width
    };

    let half_line_width = line_width / 2;

    let before_trunc_len = if layout.before_truncated {
        trunc_len
    } else {
        0
    };
    let keyafter_trunc_len = if layout.keyafter_truncated {
        trunc_len
    } else {
        0
    };
    let tail_trunc_len = if layout.tail_truncated { trunc_len } else { 0 };
    let head_trunc_len = if layout.head_truncated { trunc_len } else { 0 };

    // Reference prefix (if not right_reference)
    if !config.right_reference {
        if !ref_str.is_empty() && config.auto_reference {
            out.write_all(ref_str.as_bytes())?;
            out.write_all(b":")?;
            let ref_total = ref_str.len() + 1;
            let ref_pad_total = ref_max_width + gap;
            write_spaces(out, ref_pad_total.saturating_sub(ref_total))?;
        } else if !ref_str.is_empty() {
            out.write_all(ref_str.as_bytes())?;
            let ref_pad_total = ref_max_width + gap;
            write_spaces(out, ref_pad_total.saturating_sub(ref_str.len()))?;
        } else {
            write_spaces(out, gap)?;
        }
    }

    // Left half: [tail][tail_trunc] ... padding ... [before_trunc][before]
    if !layout.tail.is_empty() {
        out.write_all(layout.tail.as_bytes())?;
        if layout.tail_truncated {
            out.write_all(trunc_str.as_bytes())?;
        }
        let tail_used = layout.tail.len() + tail_trunc_len;
        let before_used = layout.before.len() + before_trunc_len;
        let padding = half_line_width
            .saturating_sub(gap)
            .saturating_sub(tail_used)
            .saturating_sub(before_used);
        write_spaces(out, padding)?;
    } else {
        let before_used = layout.before.len() + before_trunc_len;
        let padding = half_line_width
            .saturating_sub(gap)
            .saturating_sub(before_used);
        write_spaces(out, padding)?;
    }

    if layout.before_truncated {
        out.write_all(trunc_str.as_bytes())?;
    }
    out.write_all(layout.before.as_bytes())?;

    // Gap
    write_spaces(out, gap)?;

    // Right half: [keyafter][keyafter_trunc] ... padding ... [head_trunc][head]
    out.write_all(layout.keyafter.as_bytes())?;
    if layout.keyafter_truncated {
        out.write_all(trunc_str.as_bytes())?;
    }

    if !layout.head.is_empty() {
        let keyafter_used = layout.keyafter.len() + keyafter_trunc_len;
        let head_used = layout.head.len() + head_trunc_len;
        let padding = half_line_width
            .saturating_sub(keyafter_used)
            .saturating_sub(head_used);
        write_spaces(out, padding)?;
        if layout.head_truncated {
            out.write_all(trunc_str.as_bytes())?;
        }
        out.write_all(layout.head.as_bytes())?;
    } else if !ref_str.is_empty() && config.right_reference {
        let keyafter_used = layout.keyafter.len() + keyafter_trunc_len;
        let padding = half_line_width.saturating_sub(keyafter_used);
        write_spaces(out, padding)?;
    }

    // Reference on the right (if right_reference)
    if !ref_str.is_empty() && config.right_reference {
        write_spaces(out, gap)?;
        out.write_all(ref_str.as_bytes())?;
    }

    out.write_all(b"\n")
}

/// Escape a string for roff output (backslashes and quotes).
fn escape_roff(s: &str) -> String {
    s.replace('\\', "\\\\").replace('"', "\\\"")
}

/// Write a KWIC entry in roff format directly to output.
fn write_roff<W: Write>(
    out: &mut W,
    ref_str: &str,
    config: &PtxConfig,
    layout: &LayoutFields<'_>,
) -> io::Result<()> {
    let trunc_flag = config.flag_truncation.as_deref().unwrap_or("/");
    let macro_name = config.macro_name.as_deref().unwrap_or("xx");

    out.write_all(b".")?;
    out.write_all(macro_name.as_bytes())?;

    // tail
    out.write_all(b" \"")?;
    out.write_all(escape_roff(layout.tail).as_bytes())?;
    if layout.tail_truncated {
        out.write_all(escape_roff(trunc_flag).as_bytes())?;
    }

    // before
    out.write_all(b"\" \"")?;
    if layout.before_truncated {
        out.write_all(escape_roff(trunc_flag).as_bytes())?;
    }
    out.write_all(escape_roff(layout.before).as_bytes())?;

    // keyafter
    out.write_all(b"\" \"")?;
    out.write_all(escape_roff(layout.keyafter).as_bytes())?;
    if layout.keyafter_truncated {
        out.write_all(escape_roff(trunc_flag).as_bytes())?;
    }

    // head
    out.write_all(b"\" \"")?;
    if layout.head_truncated {
        out.write_all(escape_roff(trunc_flag).as_bytes())?;
    }
    out.write_all(escape_roff(layout.head).as_bytes())?;
    out.write_all(b"\"")?;

    // reference
    if !ref_str.is_empty() {
        out.write_all(b" \"")?;
        out.write_all(escape_roff(ref_str).as_bytes())?;
        out.write_all(b"\"")?;
    }

    out.write_all(b"\n")
}

/// Escape a string for TeX output.
fn escape_tex(s: &str) -> String {
    let mut result = String::with_capacity(s.len());
    for ch in s.chars() {
        match ch {
            '\\' => result.push_str("\\backslash "),
            '{' => result.push_str("\\{"),
            '}' => result.push_str("\\}"),
            '$' => result.push_str("\\$"),
            '&' => result.push_str("\\&"),
            '#' => result.push_str("\\#"),
            '_' => result.push_str("\\_"),
            '^' => result.push_str("\\^{}"),
            '~' => result.push_str("\\~{}"),
            '%' => result.push_str("\\%"),
            _ => result.push(ch),
        }
    }
    result
}

/// Write a KWIC entry in TeX format directly to output.
fn write_tex<W: Write>(
    out: &mut W,
    ref_str: &str,
    config: &PtxConfig,
    layout: &LayoutFields<'_>,
) -> io::Result<()> {
    let macro_name = config.macro_name.as_deref().unwrap_or("xx");

    out.write_all(b"\\")?;
    out.write_all(macro_name.as_bytes())?;
    out.write_all(b" {")?;
    out.write_all(escape_tex(layout.tail).as_bytes())?;
    out.write_all(b"}{")?;
    out.write_all(escape_tex(layout.before).as_bytes())?;
    out.write_all(b"}{")?;
    out.write_all(escape_tex(layout.keyword).as_bytes())?;
    out.write_all(b"}{")?;
    out.write_all(escape_tex(layout.after).as_bytes())?;
    out.write_all(b"}{")?;
    out.write_all(escape_tex(layout.head).as_bytes())?;
    out.write_all(b"}")?;

    if !ref_str.is_empty() {
        out.write_all(b"{")?;
        out.write_all(escape_tex(ref_str).as_bytes())?;
        out.write_all(b"}")?;
    }

    out.write_all(b"\n")
}

/// Process lines from a single source, grouping them into sentence contexts.
fn process_lines_into_contexts(
    content: &str,
    filename: Option<&str>,
    config: &PtxConfig,
    lines_out: &mut Vec<(String, String)>,
    global_line_num: &mut usize,
) {
    let mut current_text = String::new();
    let mut context_ref = String::new();
    let mut first_line_of_context = true;

    for line in content.lines() {
        *global_line_num += 1;

        let reference = if config.auto_reference {
            match filename {
                Some(name) => format!("{}:{}", name, global_line_num),
                None => format!("{}", global_line_num),
            }
        } else {
            String::new()
        };

        if first_line_of_context {
            context_ref = reference;
            first_line_of_context = false;
        }

        if !current_text.is_empty() {
            current_text.push(' ');
        }
        current_text.push_str(line);

        let trimmed = line.trim_end();
        let ends_with_terminator =
            trimmed.ends_with('.') || trimmed.ends_with('?') || trimmed.ends_with('!');

        if ends_with_terminator || line.is_empty() {
            if !current_text.trim().is_empty() {
                lines_out.push((context_ref.clone(), current_text.clone()));
            }
            current_text.clear();
            first_line_of_context = true;
        }
    }

    if !current_text.trim().is_empty() {
        lines_out.push((context_ref.clone(), current_text.clone()));
    }
}

fn format_and_write<W: Write>(
    lines: &[(String, String)],
    output: &mut W,
    config: &PtxConfig,
) -> io::Result<()> {
    let norm = NormalizedSets::new(config);
    let (entries, max_word_length) = generate_entries(lines, config, &norm);

    // Compute maximum reference width
    let ref_max_width = if config.auto_reference || config.references {
        entries
            .iter()
            .map(|e| lines[e.line_idx as usize].0.len())
            .max()
            .unwrap_or(0)
    } else {
        0
    };

    for entry in &entries {
        let line_data = &lines[entry.line_idx as usize];
        let ref_str = if config.auto_reference || config.references {
            &line_data.0
        } else {
            ""
        };
        let sentence = &line_data.1;
        let word_start = entry.word_start as usize;
        let keyword_len = entry.word_len as usize;

        let layout = compute_layout(
            sentence,
            word_start,
            keyword_len,
            ref_str,
            config,
            max_word_length,
            ref_max_width,
        );

        match config.format {
            OutputFormat::Plain => write_plain(output, ref_str, config, &layout, ref_max_width)?,
            OutputFormat::Roff => write_roff(output, ref_str, config, &layout)?,
            OutputFormat::Tex => write_tex(output, ref_str, config, &layout)?,
        }
    }

    Ok(())
}

/// Generate a permuted index from input.
pub fn generate_ptx<R: BufRead, W: Write>(
    mut input: R,
    output: &mut W,
    config: &PtxConfig,
) -> io::Result<()> {
    let mut content = String::new();
    input.read_to_string(&mut content)?;

    let mut lines: Vec<(String, String)> = Vec::new();
    let mut global_line_num = 0usize;
    process_lines_into_contexts(&content, None, config, &mut lines, &mut global_line_num);

    format_and_write(&lines, output, config)
}

/// Generate a permuted index from multiple named file contents.
pub fn generate_ptx_multi<W: Write>(
    file_contents: &[(Option<String>, String)],
    output: &mut W,
    config: &PtxConfig,
) -> io::Result<()> {
    let mut lines: Vec<(String, String)> = Vec::new();
    let mut global_line_num = 0usize;

    for (filename, content) in file_contents {
        process_lines_into_contexts(
            content,
            filename.as_deref(),
            config,
            &mut lines,
            &mut global_line_num,
        );
    }

    format_and_write(&lines, output, config)
}

/// Read a word list file (one word per line) into a HashSet.
pub fn read_word_file(path: &str) -> io::Result<HashSet<String>> {
    let content = std::fs::read_to_string(path)?;
    Ok(content
        .lines()
        .map(|l| l.trim().to_string())
        .filter(|l| !l.is_empty())
        .collect())
}
