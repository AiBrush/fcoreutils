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

/// Precomputed division tables to avoid expensive integer division in the DP inner loop.
/// div40k[len] = 40000 / (len + 2), div22k[len] = 22500 / (len + 2).
/// Word lengths above 126 are clamped (extremely rare, cost difference negligible).
const LUT_SIZE: usize = 128;

static DIV40K: [i64; LUT_SIZE] = {
    let mut t = [0i64; LUT_SIZE];
    let mut k = 0;
    while k < LUT_SIZE {
        t[k] = 40000 / (k as i64 + 2);
        k += 1;
    }
    t
};

static DIV22K: [i64; LUT_SIZE] = {
    let mut t = [0i64; LUT_SIZE];
    let mut k = 0;
    while k < LUT_SIZE {
        t[k] = 22500 / (k as i64 + 2);
        k += 1;
    }
    t
};

/// Reusable buffers for the entire formatting session.
/// All data is offset-based (no borrowed references), enabling reuse across paragraphs.
struct FmtCtx {
    /// Word byte offsets into the source text. One u32 per word.
    word_off: Vec<u32>,
    /// Packed word info: bits 0-15 = length, bits 16-19 = flags.
    /// Parallel to word_off. Built once during word collection, used directly in DP.
    winfo: Vec<u32>,
}

impl FmtCtx {
    fn new() -> Self {
        Self {
            word_off: Vec::with_capacity(256),
            winfo: Vec::with_capacity(256),
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
    // Work directly on bytes — no UTF-8 validation needed.
    // The formatter only examines ASCII whitespace and punctuation characters.
    // Non-ASCII bytes are passed through verbatim (zero-copy).
    fmt_bytes(data, output, config)
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

/// Format raw bytes, processing paragraph by paragraph with zero-copy word extraction.
/// Operates entirely on &[u8] — no UTF-8 conversion or validation at any point.
/// Uses memchr_iter for SIMD-accelerated newline scanning across the entire input.
fn fmt_bytes(data: &[u8], output: &mut impl Write, config: &FmtConfig) -> io::Result<()> {
    let prefix_bytes = config.prefix.as_deref().map(|s| s.as_bytes());
    let mut para_start = 0;
    let blen = data.len();
    let mut ctx = FmtCtx::new();
    let mut line_start = 0;

    // Use memchr_iter for SIMD-accelerated bulk newline scanning.
    // This finds all newlines in one pass, avoiding repeated memchr calls
    // that each re-scan overlapping regions.
    for nl_pos in memchr::memchr_iter(b'\n', data) {
        let line_end = nl_pos;

        // Effective line end (strip \r)
        let le = if line_end > line_start && data[line_end - 1] == b'\r' {
            line_end - 1
        } else {
            line_end
        };

        // Handle prefix filter
        if let Some(pfx) = prefix_bytes {
            if !data[line_start..le].starts_with(pfx) {
                // Flush current paragraph
                if para_start < line_start {
                    format_paragraph(data, para_start, line_start, config, output, &mut ctx)?;
                }
                para_start = nl_pos + 1;
                // Emit verbatim
                output.write_all(&data[line_start..le])?;
                output.write_all(b"\n")?;
                line_start = nl_pos + 1;
                continue;
            }
        }

        // Fast blank-line check using WS lookup table (no allocation)
        if is_blank_bytes(&data[line_start..le]) {
            // Blank line = paragraph boundary
            if para_start < line_start {
                format_paragraph(data, para_start, line_start, config, output, &mut ctx)?;
            }
            output.write_all(b"\n")?;
            para_start = nl_pos + 1;
        }

        line_start = nl_pos + 1;
    }

    // Handle last line (no trailing newline) and flush remaining paragraph
    if line_start < blen {
        // There's content after the last newline (no trailing newline)
        // It's part of the current paragraph
    }

    if para_start < blen {
        // Check if remaining content is non-empty (ignoring trailing newlines)
        let mut end = blen;
        while end > para_start && data[end - 1] == b'\n' {
            end -= 1;
        }
        if end > para_start {
            format_paragraph(data, para_start, blen, config, output, &mut ctx)?;
        }
    }

    Ok(())
}

/// Format a paragraph from a region of the source bytes [start..end).
/// Uses single-pass word extraction with offset-based storage.
/// All flags are computed once during word collection, eliminating double punctuation analysis.
fn format_paragraph(
    bytes: &[u8],
    start: usize,
    end: usize,
    config: &FmtConfig,
    output: &mut impl Write,
    ctx: &mut FmtCtx,
) -> io::Result<()> {
    let region = &bytes[start..end];
    let prefix_bytes = config.prefix.as_deref().map(|s| s.as_bytes());

    // Single-pass line extraction using memchr for indentation analysis.
    // We need the first two non-empty lines for indent detection.
    let mut first_line: Option<(usize, usize)> = None; // (start_offset, end_offset) relative to `bytes`
    let mut second_line: Option<(usize, usize)> = None;
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
                let line_range = (start + pos, start + le);
                if first_line.is_none() {
                    first_line = Some(line_range);
                } else if second_line.is_none() {
                    second_line = Some(line_range);
                    break; // Only need first two lines for indent analysis
                }
            }
            pos = nl + 1;
        }
    }

    let (fl_start, fl_end) = match first_line {
        Some(r) => r,
        None => return Ok(()),
    };

    // Strip prefix from first line for indent analysis
    let stripped_first_start = match prefix_bytes {
        Some(pfx) if bytes[fl_start..fl_end].starts_with(pfx) => fl_start + pfx.len(),
        _ => fl_start,
    };

    // Strip prefix from second line for indent analysis
    let (stripped_second_start, stripped_second_end) = match second_line {
        Some((s, e)) => match prefix_bytes {
            Some(pfx) if bytes[s..e].starts_with(pfx) => (s + pfx.len(), e),
            _ => (s, e),
        },
        None => (stripped_first_start, fl_end),
    };

    let first_indent_len = leading_ws_len(&bytes[stripped_first_start..fl_end]);
    let rest_indent_len = leading_ws_len(&bytes[stripped_second_start..stripped_second_end]);

    // Extract indent bytes (zero-copy slices from source)
    let first_indent = &bytes[stripped_first_start..stripped_first_start + first_indent_len];
    let rest_indent = &bytes[stripped_second_start..stripped_second_start + rest_indent_len];

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
                let line_start = start + pos;
                let line_end = start + le;
                split_line_optimal(
                    bytes,
                    line_start,
                    line_end,
                    config,
                    prefix_bytes,
                    output,
                    ctx,
                )?;
            }
            pos = nl + 1;
        }
        return Ok(());
    }

    let pfx = prefix_bytes.unwrap_or(b"");

    // GNU fmt's MAXWORDS is 1,000,000 — process the entire paragraph in one shot.
    const MAXWORDS: usize = 1_000_000;

    // Streaming word collection + chunked DP: collect words in MAXWORDS-sized
    // batches and process each chunk immediately. This avoids allocating a
    // Vec of 1.5M+ words for huge single-paragraph files.
    collect_and_reflow_chunked(
        bytes,
        region,
        start,
        prefix_bytes,
        pfx,
        first_line_indent,
        cont_indent,
        config,
        output,
        ctx,
        MAXWORDS,
    )
}

/// Determine the length of leading ASCII whitespace in a byte slice.
/// Replaces the old `leading_indent(&str) -> &str` — works on raw bytes,
/// no UTF-8 requirement.
#[inline(always)]
fn leading_ws_len(bytes: &[u8]) -> usize {
    let mut i = 0;
    while i < bytes.len() && is_ws(bytes[i]) && bytes[i] != b'\n' {
        i += 1;
    }
    i
}

/// Collect words from a single line [ls..le) in the source bytes.
/// Computes all flags (SENT, PERIOD, PUNCT, PAREN) during collection.
/// Uses a simple byte loop for word boundary detection — for typical line
/// lengths (< 200 bytes), this is faster than memchr2's SIMD setup overhead
/// which dominates for short slices.
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

        // Find end of word using direct byte scan.
        // For typical line lengths (< 200 bytes), the byte loop is faster than
        // memchr2 which has per-call SIMD setup overhead (~15ns).
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

/// Collect words from a paragraph and reflow in MAXWORDS-sized chunks.
/// Combines word collection with chunked DP processing to avoid allocating
/// a Vec of millions of words for huge single-paragraph files.
#[allow(clippy::too_many_arguments)]
fn collect_and_reflow_chunked(
    bytes: &[u8],
    region: &[u8],
    start: usize,
    prefix_filter: Option<&[u8]>,
    prefix_out: &[u8],
    first_indent: &[u8],
    cont_indent: &[u8],
    config: &FmtConfig,
    output: &mut impl Write,
    ctx: &mut FmtCtx,
    max_words: usize,
) -> io::Result<()> {
    let rlen = region.len();
    let pfx_len = prefix_filter.map_or(0, |p| p.len());
    let mut pos = 0;
    let mut is_first_chunk = true;

    // DP buffers — lazily grown to actual word count, not pre-allocated to MAXWORDS.
    let mut dp = DpBufs::new();

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
                let pfx_bytes = prefix_filter.unwrap();
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

/// DP buffers — lazily grown to actual word count.
/// Avoids the previous ~16MB upfront allocation for MAXWORDS=1,000,000.
/// Also owns the output buffer for batched writes (avoids borrow conflicts
/// when word_off/winfo are borrowed from FmtCtx while building output).
struct DpBufs {
    dp_cost: Vec<i64>,
    best: Vec<u32>,
    line_len: Vec<i32>,
    out_buf: Vec<u8>,
}

impl DpBufs {
    fn new() -> Self {
        // Pre-allocate for typical paragraph sizes (256 words covers most paragraphs).
        // This avoids repeated small reallocations for the first few paragraphs.
        Self {
            dp_cost: Vec::with_capacity(257),
            best: Vec::with_capacity(256),
            line_len: Vec::with_capacity(257),
            out_buf: Vec::with_capacity(8192),
        }
    }

    /// Ensure buffers are large enough for n words.
    /// Uses unsafe set_len after reserve to avoid zeroing memory — the DP loop
    /// always writes every element before reading it.
    #[inline]
    fn ensure_capacity(&mut self, n: usize) {
        let needed = n + 1;
        if self.dp_cost.len() < needed {
            self.dp_cost.reserve(needed - self.dp_cost.len());
            self.best.reserve(n.saturating_sub(self.best.len()));
            self.line_len.reserve(needed - self.line_len.len());
            // SAFETY: run_dp always writes dp_cost[0..=n], best[0..n-1], line_len[0..=n]
            // before reading them. The values are all primitive types with no Drop.
            unsafe {
                self.dp_cost.set_len(needed);
                self.best.set_len(n);
                self.line_len.set_len(needed);
            }
        }
    }
}

/// Reflow a chunk of words, outputting all lines EXCEPT the last one.
/// Returns the index (within the chunk) of the first word of the last line.
/// This allows the caller to keep those words as overlap for the next chunk,
/// ensuring natural line breaks at chunk boundaries (matching GNU fmt behavior).
///
/// Avoids allocating a Vec<usize> for line_starts by walking the DP solution twice:
/// first to find the last line start, then to output all lines before it.
#[allow(clippy::too_many_arguments)]
fn reflow_chunk_partial<W: Write>(
    bytes: &[u8],
    prefix: &[u8],
    first_indent: &[u8],
    cont_indent: &[u8],
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

    // First pass: count lines and find the last line start
    let mut line_count = 0usize;
    let mut last_line_start = 0usize;
    {
        let mut i = 0;
        while i < n {
            line_count += 1;
            last_line_start = i;
            let j = dp.best[i] as usize;
            i = j + 1;
        }
    }

    if line_count <= 1 {
        // Only one line in the chunk — output nothing, keep all words
        return Ok(0);
    }

    // Second pass: output all lines except the last one
    let out_buf = &mut dp.out_buf;
    out_buf.clear();

    let mut i = 0;
    let mut li = 0;
    while i < n {
        let j = dp.best[i] as usize;
        if i == last_line_start {
            break; // Don't output the last line
        }

        out_buf.extend_from_slice(prefix);
        if li == 0 {
            out_buf.extend_from_slice(first_indent);
        } else {
            out_buf.extend_from_slice(cont_indent);
        }

        let off = word_off[i] as usize;
        let wlen = (winfo[i] & 0xFFFF) as usize;
        out_buf.extend_from_slice(&bytes[off..off + wlen]);

        for k in (i + 1)..=j {
            if winfo[k - 1] & SENT_FLAG != 0 {
                out_buf.extend_from_slice(b"  ");
            } else {
                out_buf.push(b' ');
            }
            let off = word_off[k] as usize;
            let wlen = (winfo[k] & 0xFFFF) as usize;
            out_buf.extend_from_slice(&bytes[off..off + wlen]);
        }
        out_buf.push(b'\n');

        li += 1;
        i = j + 1;
    }

    // Single write for all output lines
    output.write_all(out_buf)?;

    // Return the index of the first word of the last line (for overlap)
    Ok(last_line_start)
}

/// Run the backward DP pass on n words, filling dp.dp_cost, dp.best, dp.line_len.
#[allow(clippy::too_many_arguments)]
fn run_dp(
    n: usize,
    prefix: &[u8],
    first_indent: &[u8],
    cont_indent: &[u8],
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

    dp.ensure_capacity(n);
    // Use ptr::write_bytes for hardware memset (rep stosb) — 3-4x faster than
    // fill() for i64::MAX which requires 8-byte stores since 0x7F != any repeated byte.
    // We use -1 (all 0xFF bytes) as sentinel, then check cost >= 0 to detect valid entries.
    // All valid DP costs are non-negative, so -1 works as "uninitialized".
    unsafe {
        std::ptr::write_bytes(dp.dp_cost.as_mut_ptr(), 0xFF, n + 1);
    }
    dp.dp_cost[n] = 0;

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
                                cost += DIV40K[wl];
                            }
                        }

                        if wj1 & PAREN_FLAG != 0 {
                            cost -= PAREN_BONUS;
                        } else if wj1 & SENT_FLAG != 0 {
                            let wl = ((wj1 & 0xFFFF) as usize).min(LUT_SIZE - 1);
                            cost += DIV22K[wl];
                        }

                        cost
                    };

                    let cj1 = unsafe { *dp_cost_ptr.add(j + 1) };
                    if cj1 >= 0 {
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
/// Builds each line in a reusable buffer, writes once per line.
/// The downstream BufWriter handles batching of small writes into large syscalls.
#[allow(clippy::too_many_arguments)]
fn reflow_chunk<W: Write>(
    bytes: &[u8],
    prefix: &[u8],
    first_indent: &[u8],
    cont_indent: &[u8],
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

    let line_buf = &mut dp.out_buf;
    let mut i = 0;
    let mut is_first_line = true;
    while i < n {
        let j = dp.best[i] as usize;
        line_buf.clear();
        line_buf.extend_from_slice(prefix);
        if is_first_line {
            line_buf.extend_from_slice(first_indent);
        } else {
            line_buf.extend_from_slice(cont_indent);
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
/// Works entirely on &[u8] — no UTF-8 conversion.
#[allow(clippy::too_many_arguments)]
fn split_line_optimal<W: Write>(
    bytes: &[u8],
    line_start: usize,
    line_end: usize,
    config: &FmtConfig,
    prefix: Option<&[u8]>,
    output: &mut W,
    ctx: &mut FmtCtx,
) -> io::Result<()> {
    let line_len = line_end - line_start;
    let pfx = prefix.unwrap_or(b"");

    // Short line: output as-is (no splitting needed).
    if line_len < config.width {
        output.write_all(&bytes[line_start..line_end])?;
        output.write_all(b"\n")?;
        return Ok(());
    }

    // Strip prefix for word collection
    let content_start = match prefix {
        Some(pfx_bytes) if bytes[line_start..line_end].starts_with(pfx_bytes) => {
            line_start + pfx_bytes.len()
        }
        _ => line_start,
    };

    let indent_len = leading_ws_len(&bytes[content_start..line_end]);
    let indent = &bytes[content_start..content_start + indent_len];

    ctx.clear_words();
    collect_words_line(bytes, content_start, line_end, ctx);

    if ctx.word_off.is_empty() {
        output.write_all(&bytes[line_start..line_end])?;
        output.write_all(b"\n")?;
        return Ok(());
    }

    // Mark last word as sentence-final
    let last = ctx.winfo.len() - 1;
    ctx.winfo[last] |= SENT_FLAG | PERIOD_FLAG;

    // Use shared DP infrastructure instead of duplicated reflow_paragraph
    let n = ctx.word_off.len();
    let mut dp = DpBufs::new();

    run_dp(n, pfx, indent, indent, config, &ctx.winfo, &mut dp);

    // Build and write output line by line
    let line_buf = &mut dp.out_buf;
    let mut i = 0;
    while i < n {
        let j = dp.best[i] as usize;
        line_buf.clear();
        line_buf.extend_from_slice(pfx);
        line_buf.extend_from_slice(indent);
        let off = ctx.word_off[i] as usize;
        let wlen = (ctx.winfo[i] & 0xFFFF) as usize;
        line_buf.extend_from_slice(&bytes[off..off + wlen]);
        for k in (i + 1)..=j {
            if ctx.winfo[k - 1] & SENT_FLAG != 0 {
                line_buf.extend_from_slice(b"  ");
            } else {
                line_buf.push(b' ');
            }
            let off = ctx.word_off[k] as usize;
            let wlen = (ctx.winfo[k] & 0xFFFF) as usize;
            line_buf.extend_from_slice(&bytes[off..off + wlen]);
        }
        line_buf.push(b'\n');
        output.write_all(line_buf)?;
        i = j + 1;
    }

    Ok(())
}
