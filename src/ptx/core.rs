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

/// A single KWIC (Key Word In Context) entry.
#[derive(Clone, Debug)]
struct KwicEntry {
    /// Reference (filename:line or line number).
    reference: String,
    /// The full input line.
    full_line: String,
    /// Byte offset of the keyword within the full line.
    word_start: usize,
    /// The keyword itself.
    keyword: String,
    /// Sort key (lowercase keyword for case-insensitive sorting).
    sort_key: String,
}

/// Computed layout fields for a KWIC entry.
///
/// These correspond to the four display regions in GNU ptx output:
///   Left half:  [tail] ... [before]
///   Gap
///   Right half: [keyafter] ... [head]
///
/// For roff:  .xx "tail" "before" "keyafter" "head" ["reference"]
/// For TeX:   \xx {tail}{before}{keyword}{after}{head} [{reference}]
struct LayoutFields {
    tail: String,
    before: String,
    keyafter: String,
    keyword: String,
    after: String,
    head: String,
    tail_truncated: bool,
    before_truncated: bool,
    keyafter_truncated: bool,
    head_truncated: bool,
}

/// Extract words from a line of text.
///
/// GNU ptx's default word regex is effectively `[a-zA-Z][a-zA-Z0-9]*`:
/// a word must start with a letter and may continue with letters or digits.
/// Underscores and other non-alphanumeric characters are word separators.
/// Pure-digit tokens are not considered words.
fn extract_words(line: &str) -> Vec<(usize, &str)> {
    let mut words = Vec::new();
    let bytes = line.as_bytes();
    let len = bytes.len();
    let mut i = 0;

    while i < len {
        // A word must start with an ASCII letter
        if bytes[i].is_ascii_alphabetic() {
            let start = i;
            i += 1;
            // Continue with letters or digits
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

/// Check if a word should be indexed.
fn should_index(word: &str, config: &PtxConfig) -> bool {
    let check_word = if config.ignore_case {
        word.to_lowercase()
    } else {
        word.to_string()
    };

    // If only_words is set, the word must be in that set
    if let Some(ref only) = config.only_words {
        if config.ignore_case {
            return only.iter().any(|w| w.to_lowercase() == check_word);
        }
        return only.contains(&check_word);
    }

    // Otherwise, word must not be in ignore list
    if config.ignore_case {
        !config
            .ignore_words
            .iter()
            .any(|w| w.to_lowercase() == check_word)
    } else {
        !config.ignore_words.contains(&check_word)
    }
}

/// Generate KWIC entries from input lines.
fn generate_entries(lines: &[(String, String)], config: &PtxConfig) -> Vec<KwicEntry> {
    let mut entries = Vec::new();

    for (reference, line) in lines {
        let words = extract_words(line);

        for &(word_start, word) in &words {
            if !should_index(word, config) {
                continue;
            }

            let sort_key = if config.ignore_case {
                word.to_lowercase()
            } else {
                word.to_string()
            };

            entries.push(KwicEntry {
                reference: reference.clone(),
                full_line: line.clone(),
                word_start,
                keyword: word.to_string(),
                sort_key,
            });
        }
    }

    // Sort by keyword (case-insensitive if requested), then by reference
    entries.sort_by(|a, b| {
        a.sort_key
            .cmp(&b.sort_key)
            .then_with(|| a.reference.cmp(&b.reference))
    });

    entries
}

/// Advance past one "word" (consecutive word chars) or one non-word char.
/// Returns the new position after skipping.
///
/// A "word" here matches the default GNU ptx word definition: starts with
/// a letter, continues with letters or digits.
fn skip_something(s: &str, pos: usize) -> usize {
    if pos >= s.len() {
        return pos;
    }
    let bytes = s.as_bytes();
    if bytes[pos].is_ascii_alphabetic() {
        // Skip a word: letter followed by alphanumeric chars
        let mut p = pos + 1;
        while p < s.len() && bytes[p].is_ascii_alphanumeric() {
            p += 1;
        }
        p
    } else {
        // Skip one non-word character (digit, underscore, punctuation, etc.)
        pos + 1
    }
}

/// Skip whitespace forward from position.
fn skip_white(s: &str, pos: usize) -> usize {
    let bytes = s.as_bytes();
    let mut p = pos;
    while p < s.len() && bytes[p].is_ascii_whitespace() {
        p += 1;
    }
    p
}

/// Skip whitespace backward from position (exclusive end).
fn skip_white_backwards(s: &str, pos: usize, start: usize) -> usize {
    let bytes = s.as_bytes();
    let mut p = pos;
    while p > start && bytes[p - 1].is_ascii_whitespace() {
        p -= 1;
    }
    p
}

/// Compute the layout fields for a KWIC entry using the GNU ptx algorithm.
///
/// This computes the four display regions (tail, before, keyafter, head)
/// that are used by all three output formats (plain, roff, TeX).
fn compute_layout(
    entry: &KwicEntry,
    config: &PtxConfig,
    max_word_length: usize,
    ref_max_width: usize,
) -> LayoutFields {
    let ref_str = if config.auto_reference || config.references {
        &entry.reference
    } else {
        ""
    };

    let total_width = config.width;
    let gap = config.gap_size;
    let trunc_len = 1; // "/" is 1 char

    // Calculate available line width (subtract reference if on the left)
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

    // GNU ptx: before_max_width = half_line_width - gap_size - 2 * trunc_len
    // keyafter_max_width = half_line_width - 2 * trunc_len
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

    let sentence = &entry.full_line;
    let word_start = entry.word_start;
    let keyword_len = entry.keyword.len();
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
        let mut lfs = word_start - (half_line_width + max_word_length);
        lfs = skip_something(sentence, lfs);
        lfs
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

    // ========== Extract text fields ==========
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

    // Extract keyword and after separately (for TeX format)
    let keyword_text = &entry.keyword;
    let after_start = keyafter_start + keyword_len;
    let after_text = if keyafter_end > after_start {
        &sentence[after_start..keyafter_end]
    } else {
        ""
    };

    LayoutFields {
        tail: tail_text.to_string(),
        before: before_text.to_string(),
        keyafter: keyafter_text.to_string(),
        keyword: keyword_text.to_string(),
        after: after_text.to_string(),
        head: head_text.to_string(),
        tail_truncated: tail_truncation,
        before_truncated: before_truncation,
        keyafter_truncated: keyafter_truncation,
        head_truncated: head_truncation,
    }
}

/// Format a KWIC entry for plain text output.
fn format_plain(
    entry: &KwicEntry,
    config: &PtxConfig,
    layout: &LayoutFields,
    ref_max_width: usize,
) -> String {
    let ref_str = if config.auto_reference || config.references {
        &entry.reference
    } else {
        ""
    };

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

    let mut result = String::with_capacity(total_width + 10);

    // Reference prefix (if not right_reference)
    if !config.right_reference {
        if !ref_str.is_empty() && config.auto_reference {
            result.push_str(ref_str);
            result.push(':');
            let ref_total = ref_str.len() + 1;
            let ref_pad_total = ref_max_width + gap;
            let padding = ref_pad_total.saturating_sub(ref_total);
            for _ in 0..padding {
                result.push(' ');
            }
        } else if !ref_str.is_empty() {
            result.push_str(ref_str);
            let ref_pad_total = ref_max_width + gap;
            let padding = ref_pad_total.saturating_sub(ref_str.len());
            for _ in 0..padding {
                result.push(' ');
            }
        } else {
            for _ in 0..gap {
                result.push(' ');
            }
        }
    }

    // Left half: [tail][tail_trunc] ... padding ... [before_trunc][before]
    if !layout.tail.is_empty() {
        result.push_str(&layout.tail);
        if layout.tail_truncated {
            result.push_str(trunc_str);
        }
        let tail_used = layout.tail.len() + tail_trunc_len;
        let before_used = layout.before.len() + before_trunc_len;
        let padding = half_line_width
            .saturating_sub(gap)
            .saturating_sub(tail_used)
            .saturating_sub(before_used);
        for _ in 0..padding {
            result.push(' ');
        }
    } else {
        let before_used = layout.before.len() + before_trunc_len;
        let padding = half_line_width
            .saturating_sub(gap)
            .saturating_sub(before_used);
        for _ in 0..padding {
            result.push(' ');
        }
    }

    if layout.before_truncated {
        result.push_str(trunc_str);
    }
    result.push_str(&layout.before);

    // Gap
    for _ in 0..gap {
        result.push(' ');
    }

    // Right half: [keyafter][keyafter_trunc] ... padding ... [head_trunc][head]
    result.push_str(&layout.keyafter);
    if layout.keyafter_truncated {
        result.push_str(trunc_str);
    }

    if !layout.head.is_empty() {
        let keyafter_used = layout.keyafter.len() + keyafter_trunc_len;
        let head_used = layout.head.len() + head_trunc_len;
        let padding = half_line_width
            .saturating_sub(keyafter_used)
            .saturating_sub(head_used);
        for _ in 0..padding {
            result.push(' ');
        }
        if layout.head_truncated {
            result.push_str(trunc_str);
        }
        result.push_str(&layout.head);
    } else if !ref_str.is_empty() && config.right_reference {
        let keyafter_used = layout.keyafter.len() + keyafter_trunc_len;
        let padding = half_line_width.saturating_sub(keyafter_used);
        for _ in 0..padding {
            result.push(' ');
        }
    }

    // Reference on the right (if right_reference)
    if !ref_str.is_empty() && config.right_reference {
        for _ in 0..gap {
            result.push(' ');
        }
        result.push_str(ref_str);
    }

    result
}

/// Escape a string for roff output (backslashes and quotes).
fn escape_roff(s: &str) -> String {
    s.replace('\\', "\\\\").replace('"', "\\\"")
}

/// Format a KWIC entry for roff output.
///
/// GNU ptx roff format: .xx "tail" "before" "keyafter" "head" ["reference"]
/// Truncation flags are embedded in the field text.
fn format_roff(entry: &KwicEntry, config: &PtxConfig, layout: &LayoutFields) -> String {
    let ref_str = if config.auto_reference || config.references {
        &entry.reference
    } else {
        ""
    };

    let trunc_flag = config.flag_truncation.as_deref().unwrap_or("/");

    let macro_name = config.macro_name.as_deref().unwrap_or("xx");

    // Build fields with truncation flags embedded
    let tail = if layout.tail_truncated {
        format!("{}{}", layout.tail, trunc_flag)
    } else {
        layout.tail.clone()
    };

    let before = if layout.before_truncated {
        format!("{}{}", trunc_flag, layout.before)
    } else {
        layout.before.clone()
    };

    let keyafter = if layout.keyafter_truncated {
        format!("{}{}", layout.keyafter, trunc_flag)
    } else {
        layout.keyafter.clone()
    };

    let head = if layout.head_truncated {
        format!("{}{}", trunc_flag, layout.head)
    } else {
        layout.head.clone()
    };

    if ref_str.is_empty() {
        format!(
            ".{} \"{}\" \"{}\" \"{}\" \"{}\"",
            macro_name,
            escape_roff(&tail),
            escape_roff(&before),
            escape_roff(&keyafter),
            escape_roff(&head),
        )
    } else {
        format!(
            ".{} \"{}\" \"{}\" \"{}\" \"{}\" \"{}\"",
            macro_name,
            escape_roff(&tail),
            escape_roff(&before),
            escape_roff(&keyafter),
            escape_roff(&head),
            escape_roff(ref_str),
        )
    }
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

/// Format a KWIC entry for TeX output.
///
/// GNU ptx TeX format: \xx {tail}{before}{keyword}{after}{head} [{reference}]
/// No truncation flags are used in TeX output.
fn format_tex(entry: &KwicEntry, config: &PtxConfig, layout: &LayoutFields) -> String {
    let ref_str = if config.auto_reference || config.references {
        &entry.reference
    } else {
        ""
    };

    let macro_name = config.macro_name.as_deref().unwrap_or("xx");

    if ref_str.is_empty() {
        format!(
            "\\{} {{{}}}{{{}}}{{{}}}{{{}}}{{{}}}",
            macro_name,
            escape_tex(&layout.tail),
            escape_tex(&layout.before),
            escape_tex(&layout.keyword),
            escape_tex(&layout.after),
            escape_tex(&layout.head),
        )
    } else {
        format!(
            "\\{} {{{}}}{{{}}}{{{}}}{{{}}}{{{}}}{{{}}}",
            macro_name,
            escape_tex(&layout.tail),
            escape_tex(&layout.before),
            escape_tex(&layout.keyword),
            escape_tex(&layout.after),
            escape_tex(&layout.head),
            escape_tex(ref_str),
        )
    }
}

/// Process lines from a single source, grouping them into sentence contexts.
///
/// GNU ptx joins consecutive lines within a single file into one context
/// unless a line ends with a sentence terminator (`.`, `?`, `!`).
/// File boundaries always break sentences.
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

        // Check if line ends with a sentence terminator
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

    // Don't forget any remaining context (lines without terminators at end of file)
    if !current_text.trim().is_empty() {
        lines_out.push((context_ref.clone(), current_text.clone()));
    }
}

fn format_and_write<W: Write>(
    lines: &[(String, String)],
    output: &mut W,
    config: &PtxConfig,
) -> io::Result<()> {
    // Generate KWIC entries
    let entries = generate_entries(lines, config);

    // Compute maximum word length across all input (needed for left_field_start)
    let max_word_length = lines
        .iter()
        .flat_map(|(_, line)| extract_words(line))
        .map(|(_, word)| word.len())
        .max()
        .unwrap_or(0);

    // Compute maximum reference width (for consistent left-alignment)
    // Note: do NOT add +1 for auto_reference here; the ":" is handled
    // in the display formatting (ref_total = ref_str.len() + 1).
    let ref_max_width = entries.iter().map(|e| e.reference.len()).max().unwrap_or(0);

    // Format and output
    for entry in &entries {
        let layout = compute_layout(entry, config, max_word_length, ref_max_width);
        let formatted = match config.format {
            OutputFormat::Plain => format_plain(entry, config, &layout, ref_max_width),
            OutputFormat::Roff => format_roff(entry, config, &layout),
            OutputFormat::Tex => format_tex(entry, config, &layout),
        };
        writeln!(output, "{}", formatted)?;
    }

    Ok(())
}

/// Generate a permuted index from input.
///
/// Reads lines from `input`, generates KWIC entries for each indexable word,
/// sorts them, and writes the formatted output to `output`.
pub fn generate_ptx<R: BufRead, W: Write>(
    input: R,
    output: &mut W,
    config: &PtxConfig,
) -> io::Result<()> {
    let mut content = String::new();
    for line_result in input.lines() {
        let line = line_result?;
        content.push_str(&line);
        content.push('\n');
    }

    let mut lines: Vec<(String, String)> = Vec::new();
    let mut global_line_num = 0usize;
    process_lines_into_contexts(&content, None, config, &mut lines, &mut global_line_num);

    format_and_write(&lines, output, config)
}

/// Generate a permuted index from multiple named file contents.
///
/// Each file's lines are processed independently for sentence grouping
/// (file boundaries always break sentences), matching GNU ptx behavior.
/// When auto_reference is enabled, references include the filename.
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
