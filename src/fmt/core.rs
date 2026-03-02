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

/// Format in-memory data. Works on byte slices directly — no UTF-8 validation pass.
/// The formatter only inspects ASCII whitespace/punctuation, so raw bytes are fine.
pub fn fmt_data(data: &[u8], output: &mut impl Write, config: &FmtConfig) -> io::Result<()> {
    // Treat as UTF-8 without validation — formatting only uses ASCII byte values.
    // For invalid UTF-8, use lossy conversion to handle edge cases.
    let text = match std::str::from_utf8(data) {
        Ok(s) => std::borrow::Cow::Borrowed(s),
        Err(_) => String::from_utf8_lossy(data),
    };
    fmt_str(&text, output, config)
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

    let pfx = prefix_str.unwrap_or("");

    // GNU fmt limits paragraphs to MAXWORDS (~1000) words per DP chunk.
    // This keeps the DP working set in L1 cache instead of thrashing main memory.
    const MAXWORDS: usize = 1000;

    // Streaming word collection + chunked DP: collect words in MAXWORDS-sized
    // batches and process each chunk immediately. This avoids allocating a
    // Vec of 1.5M+ words for huge single-paragraph files.
    collect_and_reflow_chunked(
        bytes,
        region,
        start,
        prefix_str,
        pfx,
        first_line_indent,
        cont_indent,
        config,
        output,
        ctx,
        MAXWORDS,
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
/// Uses SIMD memchr for space scanning when possible, falling back to
/// lookup-table for other whitespace types.
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

        // Find end of word: scan for space (covers 99%+ of cases)
        // Using memchr for SIMD-accelerated space detection
        let line_slice = unsafe { std::slice::from_raw_parts(ptr.add(i), le - i) };
        match memchr::memchr(b' ', line_slice) {
            Some(offset) => {
                i += offset;
            }
            None => {
                // No space found — word extends to end of line
                // But check for other whitespace (tab, etc.) byte-at-a-time
                while i < le && unsafe { !is_ws(*ptr.add(i)) } {
                    i += 1;
                }
            }
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

        let in_sent_ctx = i >= le || space_count >= 2;
        flags |= classify_word_punct(wb, in_sent_ctx);
        if wlen > 0 && matches!(wb[0], b'(' | b'[' | b'{') {
            flags |= PAREN_FLAG;
        }

        ctx.word_off.push(word_start as u32);
        ctx.winfo.push((wlen as u32) | flags);
    }
}

/// Classify a word's trailing punctuation in a single backward scan.
/// Combines what was previously two separate functions (analyze_word_punct +
/// is_sentence_end_contextual) into one pass, avoiding redundant byte scanning.
/// Returns the appropriate flag bits (PERIOD_FLAG, SENT_FLAG, PUNCT_FLAG).
#[inline(always)]
fn classify_word_punct(bytes: &[u8], in_sentence_context: bool) -> u32 {
    let mut i = bytes.len();
    // Strip trailing quotes/parens
    while i > 0 && matches!(bytes[i - 1], b'"' | b'\'' | b')' | b']') {
        i -= 1;
    }
    if i == 0 {
        return 0;
    }
    let c = bytes[i - 1];
    if c == b'.' || c == b'!' || c == b'?' {
        let mut flags = PERIOD_FLAG;
        if in_sentence_context {
            // Strip sentence-ending punctuation to find core word
            let mut end = i;
            while end > 0 && matches!(bytes[end - 1], b'.' | b'!' | b'?') {
                end -= 1;
            }
            // Single uppercase letter = abbreviation, not sentence end
            if !(end == 1 && bytes[0].is_ascii_uppercase()) && end > 0 {
                flags |= SENT_FLAG;
            }
        }
        flags
    } else if c == b',' || c == b';' || c == b':' {
        PUNCT_FLAG
    } else {
        0
    }
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

    // Precomputed division tables to avoid expensive integer division in the inner loop.
    // div40k[len] = 40000 / (len + 2), div22k[len] = 22500 / (len + 2).
    // Word lengths above 126 are clamped (extremely rare, cost difference negligible).
    const LUT_SIZE: usize = 128;
    let div40k: [i64; LUT_SIZE] = {
        let mut t = [0i64; LUT_SIZE];
        let mut k = 0;
        while k < LUT_SIZE {
            t[k] = 40000 / (k as i64 + 2);
            k += 1;
        }
        t
    };
    let div22k: [i64; LUT_SIZE] = {
        let mut t = [0i64; LUT_SIZE];
        let mut k = 0;
        while k < LUT_SIZE {
            t[k] = 22500 / (k as i64 + 2);
            k += 1;
        }
        t
    };

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
                                let wl = ((wj & 0xFFFF) as usize).min(LUT_SIZE - 1);
                                cost += div40k[wl];
                            }
                        }

                        if wj1 & PAREN_FLAG != 0 {
                            cost -= PAREN_BONUS;
                        } else if wj1 & SENT_FLAG != 0 {
                            let wl = ((wj1 & 0xFFFF) as usize).min(LUT_SIZE - 1);
                            cost += div22k[wl];
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

/// Collect words from a paragraph and reflow in MAXWORDS-sized chunks.
/// Combines word collection with chunked DP processing to avoid allocating
/// a Vec of millions of words for huge single-paragraph files.
#[allow(clippy::too_many_arguments)]
fn collect_and_reflow_chunked(
    bytes: &[u8],
    region: &[u8],
    start: usize,
    prefix_filter: Option<&str>,
    prefix_out: &str,
    first_indent: &str,
    cont_indent: &str,
    config: &FmtConfig,
    output: &mut impl Write,
    ctx: &mut FmtCtx,
    max_words: usize,
) -> io::Result<()> {
    let rlen = region.len();
    let pfx_len = prefix_filter.map_or(0, |p| p.len());
    let mut pos = 0;
    let mut is_first_chunk = true;

    // Pre-allocate DP buffers once — reused across all chunks (no per-chunk alloc)
    let mut dp = DpBufs::new(max_words);

    ctx.clear_words();

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

            let ls = if pfx_len > 0 && le - pos >= pfx_len {
                let pfx_bytes = prefix_filter.unwrap().as_bytes();
                if &bytes[line_start..line_start + pfx_len] == pfx_bytes {
                    line_start + pfx_len
                } else {
                    line_start
                }
            } else {
                line_start
            };

            collect_words_line(bytes, ls, line_end, ctx);

            // Flush chunks when we've accumulated enough words.
            // Match GNU's approach: run DP, output all lines except the last
            // partial line, keep the last line's words as overlap for the
            // next chunk. This ensures natural line breaks at chunk boundaries.
            while ctx.word_off.len() >= max_words {
                // Mark last word of chunk as sentence-final
                ctx.winfo[max_words - 1] |= SENT_FLAG | PERIOD_FLAG;

                let fi = if is_first_chunk {
                    first_indent
                } else {
                    cont_indent
                };

                // Run DP and output all lines except the last, return
                // the index of the first word of the last line (kept for overlap).
                let keep_from = reflow_chunk_partial(
                    bytes,
                    prefix_out,
                    fi,
                    cont_indent,
                    config,
                    output,
                    &ctx.word_off[..max_words],
                    &ctx.winfo[..max_words],
                    &mut dp,
                )?;

                // Remove processed words, keep overlap from last line
                let total = ctx.word_off.len();
                let new_start = keep_from; // index within the chunk
                let remaining_after_chunk = total - max_words;
                let keep_count = max_words - new_start + remaining_after_chunk;

                if keep_count > 0 && keep_count < total {
                    // Shift: keep overlap words (new_start..max_words) + remaining (max_words..total)
                    ctx.word_off.copy_within(new_start.., 0);
                    ctx.winfo.copy_within(new_start.., 0);
                    ctx.word_off.truncate(keep_count);
                    ctx.winfo.truncate(keep_count);
                    // Clear the sentence-final flag from what was the chunk boundary
                    // (it's no longer the last word)
                    let old_last = max_words - 1 - new_start;
                    if old_last < ctx.winfo.len() {
                        ctx.winfo[old_last] &= !(SENT_FLAG | PERIOD_FLAG);
                    }
                } else if keep_count == 0 {
                    ctx.word_off.clear();
                    ctx.winfo.clear();
                }

                is_first_chunk = false;
            }
        }
        pos = nl + 1;
    }

    // Flush remaining words
    let remaining = ctx.word_off.len();
    if remaining > 0 {
        // Mark last word as sentence-final
        ctx.winfo[remaining - 1] |= SENT_FLAG | PERIOD_FLAG;

        let fi = if is_first_chunk {
            first_indent
        } else {
            cont_indent
        };

        reflow_chunk(
            bytes,
            prefix_out,
            fi,
            cont_indent,
            config,
            output,
            &ctx.word_off[..remaining],
            &ctx.winfo[..remaining],
            &mut dp,
        )?;
    } else if is_first_chunk {
        // No words collected at all
        output.write_all(b"\n")?;
    }

    Ok(())
}

/// DP buffers pre-allocated to MAXWORDS size, reused across chunks.
struct DpBufs {
    dp_cost: Vec<i64>,
    best: Vec<u32>,
    line_len: Vec<i32>,
    line_buf: Vec<u8>,
}

impl DpBufs {
    fn new(max_words: usize) -> Self {
        Self {
            dp_cost: vec![0i64; max_words + 1],
            best: vec![0u32; max_words],
            line_len: vec![0i32; max_words + 1],
            line_buf: Vec::with_capacity(256),
        }
    }
}

/// Reflow a chunk of words, outputting all lines EXCEPT the last one.
/// Returns the index (within the chunk) of the first word of the last line.
/// This allows the caller to keep those words as overlap for the next chunk,
/// ensuring natural line breaks at chunk boundaries (matching GNU fmt behavior).
#[allow(clippy::too_many_arguments)]
fn reflow_chunk_partial<W: Write>(
    bytes: &[u8],
    prefix: &str,
    first_indent: &str,
    cont_indent: &str,
    config: &FmtConfig,
    output: &mut W,
    word_off: &[u32],
    winfo: &[u32],
    dp: &mut DpBufs,
) -> io::Result<usize> {
    let n = word_off.len();
    if n == 0 {
        return Ok(0);
    }

    // Run the full DP
    run_dp(n, prefix, first_indent, cont_indent, config, winfo, dp);

    // Trace the DP solution to find line breaks
    // Collect all line start indices
    let mut line_starts = Vec::new();
    let mut i = 0;
    while i < n {
        line_starts.push(i);
        let j = dp.best[i] as usize;
        i = j + 1;
    }

    // Output all lines except the last one
    let last_line_idx = if line_starts.len() > 1 {
        line_starts.len() - 1
    } else {
        // Only one line in the chunk — output nothing, keep all words
        return Ok(0);
    };

    let line_buf = &mut dp.line_buf;
    for (li, &start_word) in line_starts[..last_line_idx].iter().enumerate() {
        let j = dp.best[start_word] as usize;

        line_buf.clear();
        line_buf.extend_from_slice(prefix.as_bytes());
        if li == 0 {
            line_buf.extend_from_slice(first_indent.as_bytes());
        } else {
            line_buf.extend_from_slice(cont_indent.as_bytes());
        }

        let off = word_off[start_word] as usize;
        let wlen = (winfo[start_word] & 0xFFFF) as usize;
        line_buf.extend_from_slice(&bytes[off..off + wlen]);

        for k in (start_word + 1)..=j {
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
    }

    // Return the index of the first word of the last line (for overlap)
    Ok(line_starts[last_line_idx])
}

/// Run the backward DP pass on n words, filling dp.dp_cost, dp.best, dp.line_len.
#[allow(clippy::too_many_arguments)]
fn run_dp(
    n: usize,
    prefix: &str,
    first_indent: &str,
    cont_indent: &str,
    config: &FmtConfig,
    winfo: &[u32],
    dp: &mut DpBufs,
) {
    let first_base = prefix.len() + first_indent.len();
    let cont_base = prefix.len() + cont_indent.len();
    let goal = config.goal as i64;
    let width = config.width;

    const SHORT_FACTOR: i64 = 100;
    const RAGGED_FACTOR: i64 = 50;
    const LINE_COST: i64 = 70 * 70;
    const SENTENCE_BONUS: i64 = 50 * 50;
    const NOBREAK_COST: i64 = 600 * 600;
    const PUNCT_BONUS: i64 = 40 * 40;
    const PAREN_BONUS: i64 = 40 * 40;

    for i in 0..=n {
        dp.dp_cost[i] = i64::MAX;
    }
    dp.dp_cost[n] = 0;

    const LUT_SIZE: usize = 128;
    let div40k: [i64; LUT_SIZE] = {
        let mut t = [0i64; LUT_SIZE];
        let mut k = 0;
        while k < LUT_SIZE {
            t[k] = 40000 / (k as i64 + 2);
            k += 1;
        }
        t
    };
    let div22k: [i64; LUT_SIZE] = {
        let mut t = [0i64; LUT_SIZE];
        let mut k = 0;
        while k < LUT_SIZE {
            t[k] = 22500 / (k as i64 + 2);
            k += 1;
        }
        t
    };

    let winfo_ptr = winfo.as_ptr();
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
                                let wl = ((wj & 0xFFFF) as usize).min(LUT_SIZE - 1);
                                cost += div40k[wl];
                            }
                        }

                        if wj1 & PAREN_FLAG != 0 {
                            cost -= PAREN_BONUS;
                        } else if wj1 & SENT_FLAG != 0 {
                            let wl = ((wj1 & 0xFFFF) as usize).min(LUT_SIZE - 1);
                            cost += div22k[wl];
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
}

/// Reflow a chunk of words using pre-allocated DP buffers (outputs all lines).
#[allow(clippy::too_many_arguments)]
fn reflow_chunk<W: Write>(
    bytes: &[u8],
    prefix: &str,
    first_indent: &str,
    cont_indent: &str,
    config: &FmtConfig,
    output: &mut W,
    word_off: &[u32],
    winfo: &[u32],
    dp: &mut DpBufs,
) -> io::Result<()> {
    let n = word_off.len();
    if n == 0 {
        return Ok(());
    }

    run_dp(n, prefix, first_indent, cont_indent, config, winfo, dp);

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
        let off = word_off[i] as usize;
        let wlen = (winfo[i] & 0xFFFF) as usize;
        line_buf.extend_from_slice(&bytes[off..off + wlen]);
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
