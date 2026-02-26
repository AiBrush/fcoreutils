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
    /// Text before the keyword (left context) - for roff/tex.
    left_context: String,
    /// Text after the keyword (right context) - for roff/tex.
    right_context: String,
    /// Sort key (lowercase keyword for case-insensitive sorting).
    sort_key: String,
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

            let word_end = word_start + word.len();

            // Left context: text before the keyword
            let left = line[..word_start].trim_end();

            // Right context: text after the keyword
            let right = line[word_end..].trim_start();

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
                left_context: left.to_string(),
                right_context: right.to_string(),
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

/// Format a KWIC entry for plain text output.
///
/// Follows the GNU ptx algorithm from coreutils. The output has four fields:
///
/// Left half (half_line_width chars):
///   [tail][tail_trunc] ... padding ... [before_trunc][before]
/// Gap (gap_size spaces)
/// Right half (half_line_width chars):
///   [keyafter][keyafter_trunc] ... padding ... [head_trunc][head]
///
/// Where:
///   keyafter = keyword + right context (up to keyafter_max_width)
///   before   = left context nearest to keyword (up to before_max_width)
///   tail     = overflow from keyafter that wraps to left half
///   head     = overflow from before that wraps to right half
fn format_plain(
    entry: &KwicEntry,
    config: &PtxConfig,
    max_word_length: usize,
    ref_max_width: usize,
) -> String {
    let ref_str = if config.auto_reference || config.references {
        &entry.reference
    } else {
        ""
    };

    let total_width = config.width;
    let gap = config.gap_size;
    let trunc_str = "/";
    let trunc_len = trunc_str.len(); // 1

    // Calculate available line width (subtract reference if on the left)
    // GNU ptx uses reference_max_width (max across all entries) + gap_size
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
    let line_len = sentence.len();

    // ========== Step 1: Compute keyafter ==========
    // keyafter starts at keyword and extends right, word-by-word, up to keyafter_max_width chars.
    let keyafter_start = word_start;
    let mut keyafter_end = word_start + entry.keyword.len();
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
    // Remove trailing whitespace from keyafter
    keyafter_end = skip_white_backwards(sentence, keyafter_end, keyafter_start);

    // ========== Compute left_field_start ==========
    // When the left context is very wide, GNU ptx jumps back from the keyword
    // by half_line_width + max_word_length, then advances past one word/separator.
    // This avoids scanning from the very beginning of the line.
    let left_context_start: usize = 0; // start of line
    let left_field_start = if word_start > half_line_width + max_word_length {
        let mut lfs = word_start - (half_line_width + max_word_length);
        lfs = skip_something(sentence, lfs);
        lfs
    } else {
        left_context_start
    };

    // ========== Step 2: Compute before ==========
    // before is the left context immediately before the keyword, up to before_max_width.
    // It's truncated from the LEFT (start advances forward).
    let mut before_start: usize = left_field_start;
    let mut before_end = keyafter_start;
    // Remove trailing whitespace from before
    before_end = skip_white_backwards(sentence, before_end, before_start);

    // Advance before_start word-by-word until it fits in before_max_width
    while before_start + before_max_width < before_end {
        before_start = skip_something(sentence, before_start);
    }

    // Check if before was truncated (text exists before before_start)
    let mut before_truncation = {
        let cursor = skip_white_backwards(sentence, before_start, 0);
        cursor > left_context_start
    };

    // Skip leading whitespace from before
    before_start = skip_white(sentence, before_start);
    let before_len = if before_end > before_start {
        before_end - before_start
    } else {
        0
    };

    // ========== Step 3: Compute tail ==========
    // tail is the overflow from keyafter that wraps to the left half.
    // tail_max_width = before_max_width - before_len - gap_size
    let tail_max_width_raw: isize =
        before_max_width as isize - before_len as isize - gap as isize;
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
            keyafter_truncation = false; // tail takes over truncation from keyafter
            tail_truncation = tail_end < line_len;
        } else {
            tail_truncation = false;
        }

        // Remove trailing whitespace from tail
        tail_end = skip_white_backwards(sentence, tail_end, tail_start);
    }

    // ========== Step 4: Compute head ==========
    // head is the overflow from before that wraps to the right half.
    // head_max_width = keyafter_max_width - keyafter_len - gap_size
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
        // head.end = before.start (before leading whitespace was skipped)
        // We need the position before SKIP_WHITE was applied to before_start.
        // head covers text from start-of-line to just before before_start.
        head_end = skip_white_backwards(sentence, before_start, 0);

        head_start = left_field_start;
        while head_start + head_max_width < head_end {
            head_start = skip_something(sentence, head_start);
        }

        if head_end > head_start {
            has_head = true;
            before_truncation = false; // head takes over truncation from before
            head_truncation = {
                // Check if there's text before head_start
                let cursor = skip_white_backwards(sentence, head_start, 0);
                cursor > left_context_start
            };
        } else {
            head_truncation = false;
        }

        // Skip leading whitespace from head
        if head_end > head_start {
            head_start = skip_white(sentence, head_start);
        }
    }

    // ========== Step 5: Format output ==========
    // Extract the text for each field
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

    let before_trunc_len = if before_truncation { trunc_len } else { 0 };
    let keyafter_trunc_len = if keyafter_truncation { trunc_len } else { 0 };
    let tail_trunc_len = if tail_truncation { trunc_len } else { 0 };
    let head_trunc_len = if head_truncation { trunc_len } else { 0 };

    let mut result = String::with_capacity(total_width + 10);

    // Reference prefix (if not right_reference).
    // GNU ptx always outputs reference_max_width + gap_size chars here,
    // even when there's no reference (reference_max_width = 0, so gap_size spaces).
    if !config.right_reference {
        if !ref_str.is_empty() && config.auto_reference {
            // GNU emacs style: reference followed by colon, then padding
            result.push_str(ref_str);
            result.push(':');
            let ref_total = ref_str.len() + 1; // +1 for colon
            let ref_pad_total = ref_max_width + gap; // reference_max_width + gap_size
            let padding = ref_pad_total.saturating_sub(ref_total);
            for _ in 0..padding {
                result.push(' ');
            }
        } else if !ref_str.is_empty() {
            // Output reference and padding to reference_max_width + gap_size
            result.push_str(ref_str);
            let ref_pad_total = ref_max_width + gap;
            let padding = ref_pad_total.saturating_sub(ref_str.len());
            for _ in 0..padding {
                result.push(' ');
            }
        } else {
            // No reference: GNU ptx still outputs gap_size spaces
            // (reference_max_width=0, so padding = 0 + gap_size - 0 = gap_size)
            for _ in 0..gap {
                result.push(' ');
            }
        }
    }

    // Left half: [tail][tail_trunc] ... padding ... [before_trunc][before]
    if !tail_text.is_empty() {
        // Has tail field
        result.push_str(tail_text);
        if tail_truncation {
            result.push_str(trunc_str);
        }
        // Padding between tail and before
        let tail_used = tail_text.len() + tail_trunc_len;
        let before_used = before_text.len() + before_trunc_len;
        let padding = half_line_width
            .saturating_sub(gap)
            .saturating_sub(tail_used)
            .saturating_sub(before_used);
        for _ in 0..padding {
            result.push(' ');
        }
    } else {
        // No tail: padding before the [before_trunc][before] block
        let before_used = before_text.len() + before_trunc_len;
        let padding = half_line_width
            .saturating_sub(gap)
            .saturating_sub(before_used);
        for _ in 0..padding {
            result.push(' ');
        }
    }

    // before field (right side of left half)
    if before_truncation {
        result.push_str(trunc_str);
    }
    result.push_str(before_text);

    // Gap
    for _ in 0..gap {
        result.push(' ');
    }

    // Right half: [keyafter][keyafter_trunc] ... padding ... [head_trunc][head]
    result.push_str(keyafter_text);
    if keyafter_truncation {
        result.push_str(trunc_str);
    }

    if has_head && !head_text.is_empty() {
        // Padding between keyafter and head
        let keyafter_used = keyafter_text.len() + keyafter_trunc_len;
        let head_used = head_text.len() + head_trunc_len;
        let padding = half_line_width
            .saturating_sub(keyafter_used)
            .saturating_sub(head_used);
        for _ in 0..padding {
            result.push(' ');
        }
        if head_truncation {
            result.push_str(trunc_str);
        }
        result.push_str(head_text);
    } else if !ref_str.is_empty() && config.right_reference {
        // Pad to full half_line_width for right reference alignment
        let keyafter_used = keyafter_text.len() + keyafter_trunc_len;
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

/// Format a KWIC entry for roff output.
fn format_roff(entry: &KwicEntry, config: &PtxConfig) -> String {
    let ref_str = if config.auto_reference || config.references {
        &entry.reference
    } else {
        ""
    };

    // Escape backslashes and quotes for roff
    let left = entry
        .left_context
        .replace('\\', "\\\\")
        .replace('"', "\\\"");
    let keyword = entry.keyword.replace('\\', "\\\\").replace('"', "\\\"");
    let right = entry
        .right_context
        .replace('\\', "\\\\")
        .replace('"', "\\\"");
    let reference = ref_str.replace('\\', "\\\\").replace('"', "\\\"");

    format!(
        ".xx \"{}\" \"{}\" \"{}\" \"{}\"",
        left, keyword, right, reference
    )
}

/// Format a KWIC entry for TeX output.
fn format_tex(entry: &KwicEntry, config: &PtxConfig) -> String {
    let ref_str = if config.auto_reference || config.references {
        &entry.reference
    } else {
        ""
    };

    // Escape TeX special characters
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

    format!(
        "\\xx {{{}}}{{{}}}{{{}}}{{{}}}",
        escape_tex(&entry.left_context),
        escape_tex(&entry.keyword),
        escape_tex(&entry.right_context),
        escape_tex(ref_str),
    )
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
    let ref_max_width = if config.auto_reference {
        // GNU ptx adds 1 for ":" and computes max across all references
        entries
            .iter()
            .map(|e| e.reference.len())
            .max()
            .unwrap_or(0)
            + 1 // +1 for ":"
    } else {
        entries
            .iter()
            .map(|e| e.reference.len())
            .max()
            .unwrap_or(0)
    };

    // Format and output
    for entry in &entries {
        let formatted = match config.format {
            OutputFormat::Plain => format_plain(entry, config, max_word_length, ref_max_width),
            OutputFormat::Roff => format_roff(entry, config),
            OutputFormat::Tex => format_tex(entry, config),
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
