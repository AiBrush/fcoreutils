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

/// Word flags for GNU fmt cost model.
/// Packed into the upper bits of the winfo u32 array for cache efficiency.
const SENT_FLAG: u32 = 1 << 16; // sentence-final (period + double-space/eol context)
const PERIOD_FLAG: u32 = 1 << 17; // has sentence-ending punct (.!?) regardless of context
const PUNCT_FLAG: u32 = 1 << 18; // ends with non-period punctuation (,;:)
const PAREN_FLAG: u32 = 1 << 19; // starts with opening paren/bracket

/// Reusable buffers for the entire formatting session.
/// All data is offset-based (no borrowed references), enabling reuse across paragraphs.
struct FmtCtx {
    /// Word byte offsets into the source text. One u32 per word.
    word_off: Vec<u32>,
    /// Packed word info: bits 0-15 = length, bits 16-19 = flags.
    /// Parallel to word_off. Built once during word collection, used directly in DP.
    winfo: Vec<u32>,
    /// DP cost array (n+1 elements).
    dp_cost: Vec<i64>,
    /// Best break-point for word i (n elements).
    best: Vec<u32>,
    /// Line length at break-point i (n+1 elements).
    line_len: Vec<i32>,
    /// Output line buffer for batched writes.
    line_buf: Vec<u8>,
}

impl FmtCtx {
    fn new() -> Self {
        Self {
            word_off: Vec::with_capacity(256),
            winfo: Vec::with_capacity(256),
            dp_cost: Vec::with_capacity(257),
            best: Vec::with_capacity(256),
            line_len: Vec::with_capacity(257),
            line_buf: Vec::with_capacity(256),
        }
    }

    #[inline(always)]
    fn clear_words(&mut self) {
        self.word_off.clear();
        self.winfo.clear();
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
    let mut data = Vec::new();
    input.read_to_end(&mut data)?;
    fmt_data(&data, output, config)
}

/// Format in-memory data. Works on byte slices to avoid String allocation.
pub fn fmt_data(data: &[u8], output: &mut impl Write, config: &FmtConfig) -> io::Result<()> {
    let text = match std::str::from_utf8(data) {
        Ok(s) => s,
        Err(_) => {
            let owned = String::from_utf8_lossy(data);
            return fmt_str(&owned, output, config);
        }
    };
    fmt_str(text, output, config)
}

/// Check if a byte range is all whitespace using our fast lookup table.
#[inline(always)]
fn is_blank_bytes(bytes: &[u8]) -> bool {
    for &b in bytes {
        if !is_ws(b) {
            return false;
        }
    }
    true
}

/// Format a string slice, processing paragraph by paragraph with zero-copy word extraction.
fn fmt_str(text: &str, output: &mut impl Write, config: &FmtConfig) -> io::Result<()> {
    let prefix_str = config.prefix.as_deref();
    let mut para_start = 0;
    let bytes = text.as_bytes();
    let blen = bytes.len();
    let mut ctx = FmtCtx::new();

    let mut i = 0;

    while i < blen {
        // Find end of current line using memchr for SIMD-accelerated newline search
        let line_end = memchr::memchr(b'\n', &bytes[i..])
            .map(|p| i + p)
            .unwrap_or(blen);

        // Effective line end (strip \r)
        let le = if line_end > i && bytes[line_end - 1] == b'\r' {
            line_end - 1
        } else {
            line_end
        };

        // Handle prefix filter
        if let Some(pfx) = prefix_str {
            let line = &text[i..le];
            if !line.starts_with(pfx) {
                // Flush current paragraph
                if para_start < i {
                    format_paragraph(text, bytes, para_start, i, config, output, &mut ctx)?;
                }
                let next = if line_end < blen { line_end + 1 } else { blen };
                para_start = next;
                // Emit verbatim
                output.write_all(&bytes[i..le])?;
                output.write_all(b"\n")?;
                i = next;
                continue;
            }
        }

        // Fast blank-line check using WS lookup table (no allocation)
        if is_blank_bytes(&bytes[i..le]) {
            // Blank line = paragraph boundary
            if para_start < i {
                format_paragraph(text, bytes, para_start, i, config, output, &mut ctx)?;
            }
            output.write_all(b"\n")?;
            let next = if line_end < blen { line_end + 1 } else { blen };
            para_start = next;
        }

        i = if line_end < blen { line_end + 1 } else { blen };
    }

    // Flush remaining paragraph
    if para_start < blen {
        let remaining = text[para_start..].trim_end_matches('\n');
        if !remaining.is_empty() {
            format_paragraph(text, bytes, para_start, blen, config, output, &mut ctx)?;
        }
    }

    Ok(())
}

/// Format a paragraph from a region of the source text [start..end).
/// Uses single-pass word extraction with offset-based storage.
/// All flags are computed once during word collection, eliminating double punctuation analysis.
fn format_paragraph(
    text: &str,
    bytes: &[u8],
    start: usize,
    end: usize,
    config: &FmtConfig,
    output: &mut impl Write,
    ctx: &mut FmtCtx,
) -> io::Result<()> {
    let region = &bytes[start..end];
    let prefix_str = config.prefix.as_deref();

    // Single-pass line extraction using memchr for indentation analysis.
    // We need the first two non-empty lines for indent detection.
    let mut first_line: Option<&str> = None;
    let mut second_line: Option<&str> = None;
    {
        let rlen = region.len();
        let mut pos = 0;
        while pos < rlen {
            let nl = memchr::memchr(b'\n', &region[pos..])
                .map(|p| pos + p)
                .unwrap_or(rlen);
            let mut le = nl;
            if le > pos && region[le - 1] == b'\r' {
                le -= 1;
            }
            if le > pos {
                let line = &text[start + pos..start + le];
                if first_line.is_none() {
                    first_line = Some(line);
                } else if second_line.is_none() {
                    second_line = Some(line);
                    break; // Only need first two lines for indent analysis
                }
            }
            pos = nl + 1;
        }
    }

    let fl = match first_line {
        Some(l) => l,
        None => return Ok(()),
    };

    let stripped_first = match prefix_str {
        Some(pfx) => fl.strip_prefix(pfx).unwrap_or(fl),
        None => fl,
    };

    let stripped_second = match second_line {
        Some(l) => match prefix_str {
            Some(pfx) => l.strip_prefix(pfx).unwrap_or(l),
            None => l,
        },
        None => stripped_first,
    };

    let first_indent = leading_indent(stripped_first);
    let rest_indent = leading_indent(stripped_second);

    let (first_line_indent, cont_indent) = if config.tagged || config.crown_margin {
        (first_indent, rest_indent)
    } else {
        (first_indent, first_indent)
    };

    if config.split_only {
        // Split-only mode: process each line independently.
        let rlen = region.len();
        let mut pos = 0;
        while pos < rlen {
            let nl = memchr::memchr(b'\n', &region[pos..])
                .map(|p| pos + p)
                .unwrap_or(rlen);
            let mut le = nl;
            if le > pos && region[le - 1] == b'\r' {
                le -= 1;
            }
            if le > pos {
                let line = &text[start + pos..start + le];
                split_line_optimal(line, config, prefix_str, output)?;
            }
            pos = nl + 1;
        }
        return Ok(());
    }

    // Collect words with full flag computation in a single pass.
    // Words are stored as byte offsets (word_off) + packed winfo, avoiding Vec<&str>.
    ctx.clear_words();
    collect_words_from_region(bytes, region, start, prefix_str, ctx);

    let n = ctx.word_off.len();
    if n == 0 {
        output.write_all(b"\n")?;
        return Ok(());
    }

    // Mark last word as sentence-final (GNU fmt convention).
    let last_idx = n - 1;
    ctx.winfo[last_idx] |= SENT_FLAG | PERIOD_FLAG;

    let pfx = prefix_str.unwrap_or("");
    reflow_paragraph(
        bytes,
        pfx,
        first_line_indent,
        cont_indent,
        config,
        output,
        ctx,
    )
}

/// Determine the leading whitespace (indentation) of a line.
fn leading_indent(line: &str) -> &str {
    let trimmed = line.trim_start();
    &line[..line.len() - trimmed.len()]
}

/// Collect words from all lines in a paragraph region, computing all flags in one pass.
/// Stores byte offsets + packed winfo in ctx. No intermediate Vec<&str> or Vec<bool>.
fn collect_words_from_region(
    bytes: &[u8],
    region: &[u8],
    start: usize,
    prefix: Option<&str>,
    ctx: &mut FmtCtx,
) {
    let rlen = region.len();
    let mut pos = 0;
    let pfx_len = prefix.map_or(0, |p| p.len());

    while pos < rlen {
        let nl = memchr::memchr(b'\n', &region[pos..])
            .map(|p| pos + p)
            .unwrap_or(rlen);
        let mut le = nl;
        if le > pos && region[le - 1] == b'\r' {
            le -= 1;
        }
        if le > pos {
            let line_start = start + pos;
            let line_end = start + le;

            // Strip prefix
            let ls = if pfx_len > 0 && le - pos >= pfx_len {
                let pfx_bytes = prefix.unwrap().as_bytes();
                if &bytes[line_start..line_start + pfx_len] == pfx_bytes {
                    line_start + pfx_len
                } else {
                    line_start
                }
            } else {
                line_start
            };

            collect_words_line(bytes, ls, line_end, ctx);
        }
        pos = nl + 1;
    }
}

/// Collect words from a single line [ls..le) in the source bytes.
/// Computes all flags (SENT, PERIOD, PUNCT, PAREN) during collection.
/// Uses lookup-table whitespace scanning and unsafe ptr for bounds-check elision.
#[inline(always)]
fn collect_words_line(bytes: &[u8], ls: usize, le: usize, ctx: &mut FmtCtx) {
    let ptr = bytes.as_ptr();
    let mut i = ls;

    // Skip leading whitespace
    while i < le && unsafe { is_ws(*ptr.add(i)) } {
        i += 1;
    }

    while i < le {
        let word_start = i;
        while i < le && unsafe { !is_ws(*ptr.add(i)) } {
            i += 1;
        }
        let wlen = i - word_start;

        // Count trailing spaces
        let space_start = i;
        while i < le && unsafe { is_ws(*ptr.add(i)) } {
            i += 1;
        }
        let space_count = i - space_start;

        // Compute all flags in one pass
        let wb = unsafe { std::slice::from_raw_parts(ptr.add(word_start), wlen) };
        let mut flags = 0u32;

        let (has_sent_punct, has_np_punct) = analyze_word_punct(wb);
        if has_sent_punct {
            flags |= PERIOD_FLAG;
            // Check sentence-end context: at end of line or followed by 2+ spaces
            if (i >= le || space_count >= 2) && is_sentence_end_contextual(wb) {
                flags |= SENT_FLAG;
            }
        } else if has_np_punct {
            flags |= PUNCT_FLAG;
        }
        if wlen > 0 && matches!(wb[0], b'(' | b'[' | b'{') {
            flags |= PAREN_FLAG;
        }

        ctx.word_off.push(word_start as u32);
        ctx.winfo.push((wlen as u32) | flags);
    }
}

/// Analyze the trailing punctuation of a word in a single pass.
/// Returns (has_sentence_punct, has_non_period_punct).
#[inline(always)]
fn analyze_word_punct(bytes: &[u8]) -> (bool, bool) {
    let mut i = bytes.len();
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

/// Check if a word ends a sentence (assuming it has sentence-ending punctuation).
/// Strips trailing punctuation to find the core word; single uppercase letters
/// are treated as abbreviations, not sentence ends.
#[inline(always)]
fn is_sentence_end_contextual(word_bytes: &[u8]) -> bool {
    let mut end = word_bytes.len();
    while end > 0
        && matches!(
            word_bytes[end - 1],
            b'.' | b'!' | b'?' | b'"' | b'\'' | b')' | b']'
        )
    {
        end -= 1;
    }
    // Single uppercase letter followed by '.' is abbreviation
    if end == 1 && word_bytes[0].is_ascii_uppercase() {
        return false;
    }
    end > 0
}

/// Reflow words into lines that fit within the configured width.
///
/// Uses optimal line breaking with a cost function matching GNU fmt.
/// Words are referenced by offset (ctx.word_off + ctx.winfo), not by &str slices.
/// Builds each output line in a buffer and writes once.
#[allow(clippy::too_many_arguments)]
fn reflow_paragraph<W: Write>(
    bytes: &[u8],
    prefix: &str,
    first_indent: &str,
    cont_indent: &str,
    config: &FmtConfig,
    output: &mut W,
    ctx: &mut FmtCtx,
) -> io::Result<()> {
    let n = ctx.word_off.len();
    if n == 0 {
        return Ok(());
    }

    let first_base = prefix.len() + first_indent.len();
    let cont_base = prefix.len() + cont_indent.len();
    let goal = config.goal as i64;
    let width = config.width;

    // GNU fmt cost model constants
    const SHORT_FACTOR: i64 = 100;
    const RAGGED_FACTOR: i64 = 50;
    const LINE_COST: i64 = 70 * 70;
    const SENTENCE_BONUS: i64 = 50 * 50;
    const NOBREAK_COST: i64 = 600 * 600;
    const PUNCT_BONUS: i64 = 40 * 40;
    const PAREN_BONUS: i64 = 40 * 40;

    // Reuse DP buffers
    ctx.dp_cost.clear();
    ctx.dp_cost.resize(n + 1, i64::MAX);
    ctx.dp_cost[n] = 0;

    ctx.best.clear();
    ctx.best.resize(n, 0);

    ctx.line_len.clear();
    ctx.line_len.resize(n + 1, 0);

    // SAFETY: All array indices are provably in-bounds:
    // - winfo has exactly n elements (one per word)
    // - dp_cost has n+1 elements, accessed with indices 0..=n
    // - best has n elements, accessed with indices 0..n-1
    // - line_len has n+1 elements, accessed with indices 0..=n
    let winfo_ptr = ctx.winfo.as_ptr();
    let dp_cost_ptr = ctx.dp_cost.as_mut_ptr();
    let best_ptr = ctx.best.as_mut_ptr();
    let line_len_ptr = ctx.line_len.as_mut_ptr();

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
    // Reference words by byte offset into source, build each line in buffer.
    let mut i = 0;
    let mut is_first_line = true;
    let line_buf = &mut ctx.line_buf;
    let word_off = &ctx.word_off;
    let winfo = &ctx.winfo;
    let best = &ctx.best;

    while i < n {
        let j = best[i] as usize;

        line_buf.clear();

        line_buf.extend_from_slice(prefix.as_bytes());
        if is_first_line {
            line_buf.extend_from_slice(first_indent.as_bytes());
        } else {
            line_buf.extend_from_slice(cont_indent.as_bytes());
        }

        // First word on line
        let off = word_off[i] as usize;
        let wlen = (winfo[i] & 0xFFFF) as usize;
        line_buf.extend_from_slice(&bytes[off..off + wlen]);

        // Subsequent words on line
        for k in (i + 1)..=j {
            if winfo[k - 1] & SENT_FLAG != 0 {
                line_buf.extend_from_slice(b"  ");
            } else {
                line_buf.push(b' ');
            }
            let off = word_off[k] as usize;
            let wlen = (winfo[k] & 0xFFFF) as usize;
            line_buf.extend_from_slice(&bytes[off..off + wlen]);
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

    let bytes = line.as_bytes();
    let mut ctx = FmtCtx::new();

    // Find the offset of s within line
    let s_start = s.as_ptr() as usize - line.as_ptr() as usize;
    let s_end = s_start + s.len();
    collect_words_line(bytes, s_start, s_end, &mut ctx);

    if ctx.word_off.is_empty() {
        output.write_all(line.as_bytes())?;
        output.write_all(b"\n")?;
        return Ok(());
    }

    // Mark last word as sentence-final
    let last = ctx.winfo.len() - 1;
    ctx.winfo[last] |= SENT_FLAG | PERIOD_FLAG;

    reflow_paragraph(bytes, pfx, indent, indent, config, output, &mut ctx)
}
