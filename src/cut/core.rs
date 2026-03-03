use memchr::memchr_iter;
use std::io::{self, BufRead, IoSlice, Write};

/// Minimum file size for parallel processing (32MB).
/// Files above this threshold use rayon parallel chunked processing.
/// 32MB balances rayon init overhead + buffer allocation against parallel benefits.
/// For 10MB files, sequential is faster due to thread coordination + memory overhead.
const PARALLEL_THRESHOLD: usize = 32 * 1024 * 1024;

/// Max iovec entries per writev call (Linux default).
const MAX_IOV: usize = 1024;

/// Configuration for cut operations.
pub struct CutConfig<'a> {
    pub mode: CutMode,
    pub ranges: &'a [Range],
    pub complement: bool,
    pub delim: u8,
    pub output_delim: &'a [u8],
    pub suppress_no_delim: bool,
    pub line_delim: u8,
}

/// A range specification like 1, 3-5, -3, 4-
#[derive(Debug, Clone)]
pub struct Range {
    pub start: usize, // 1-based, 0 means "from beginning"
    pub end: usize,   // 1-based, usize::MAX means "to end"
}

/// Parse a LIST specification like "1,3-5,7-" into ranges.
/// Each range is 1-based. Returns sorted, merged ranges.
/// When `no_merge_adjacent` is true, overlapping ranges are still merged but
/// adjacent ranges (e.g., 1-2,3-4) are kept separate. This is needed when
/// `--output-delimiter` is specified for byte/char mode so the delimiter is
/// inserted between originally separate but adjacent ranges.
pub fn parse_ranges(spec: &str, no_merge_adjacent: bool) -> Result<Vec<Range>, String> {
    let mut ranges = Vec::new();

    for part in spec.split(',') {
        let part = part.trim();
        if part.is_empty() {
            continue;
        }

        if let Some(idx) = part.find('-') {
            let left = &part[..idx];
            let right = &part[idx + 1..];

            // Reject bare "-" (both sides empty)
            if left.is_empty() && right.is_empty() {
                return Err("invalid range with no endpoint: -".to_string());
            }

            let start = if left.is_empty() {
                1
            } else {
                left.parse::<usize>()
                    .map_err(|_| format!("invalid range: '{}'", part))?
            };

            let end = if right.is_empty() {
                usize::MAX
            } else {
                right
                    .parse::<usize>()
                    .map_err(|_| format!("invalid range: '{}'", part))?
            };

            if start == 0 {
                return Err("fields and positions are numbered from 1".to_string());
            }
            if start > end {
                return Err(format!("invalid decreasing range: '{}'", part));
            }

            ranges.push(Range { start, end });
        } else {
            let n = part
                .parse::<usize>()
                .map_err(|_| format!("invalid field: '{}'", part))?;
            if n == 0 {
                return Err("fields and positions are numbered from 1".to_string());
            }
            ranges.push(Range { start: n, end: n });
        }
    }

    if ranges.is_empty() {
        return Err("you must specify a list of bytes, characters, or fields".to_string());
    }

    // Sort and merge overlapping/adjacent ranges
    ranges.sort_by_key(|r| (r.start, r.end));
    let mut merged = vec![ranges[0].clone()];
    for r in &ranges[1..] {
        let last = merged.last_mut().unwrap();
        if no_merge_adjacent {
            // Only merge truly overlapping ranges, not adjacent ones
            if r.start <= last.end {
                last.end = last.end.max(r.end);
            } else {
                merged.push(r.clone());
            }
        } else {
            // Merge both overlapping and adjacent ranges
            if r.start <= last.end.saturating_add(1) {
                last.end = last.end.max(r.end);
            } else {
                merged.push(r.clone());
            }
        }
    }

    Ok(merged)
}

/// Check if a 1-based position is in any range.
/// Ranges must be sorted. Uses early exit since ranges are sorted.
#[inline(always)]
fn in_ranges(ranges: &[Range], pos: usize) -> bool {
    for r in ranges {
        if pos < r.start {
            return false;
        }
        if pos <= r.end {
            return true;
        }
    }
    false
}

/// Pre-compute a 64-bit mask for field selection.
/// Bit i-1 is set if field i should be output.
#[inline]
fn compute_field_mask(ranges: &[Range], complement: bool) -> u64 {
    let mut mask: u64 = 0;
    for i in 1..=64u32 {
        let in_range = in_ranges(ranges, i as usize);
        if in_range != complement {
            mask |= 1u64 << (i - 1);
        }
    }
    mask
}

/// Check if a field should be selected, using bitset for first 64 fields.
#[inline(always)]
fn is_selected(field_num: usize, mask: u64, ranges: &[Range], complement: bool) -> bool {
    if field_num <= 64 {
        (mask >> (field_num - 1)) & 1 == 1
    } else {
        in_ranges(ranges, field_num) != complement
    }
}

// ── Unsafe buffer helpers (skip bounds checks in hot loops) ──────────────

/// Append a slice to buf without capacity checks.
/// Caller MUST ensure buf has enough remaining capacity.
#[inline(always)]
unsafe fn buf_extend(buf: &mut Vec<u8>, data: &[u8]) {
    unsafe {
        let len = buf.len();
        std::ptr::copy_nonoverlapping(data.as_ptr(), buf.as_mut_ptr().add(len), data.len());
        buf.set_len(len + data.len());
    }
}

/// Append a single byte to buf without capacity checks.
/// Caller MUST ensure buf has enough remaining capacity.
#[inline(always)]
unsafe fn buf_push(buf: &mut Vec<u8>, b: u8) {
    unsafe {
        let len = buf.len();
        *buf.as_mut_ptr().add(len) = b;
        buf.set_len(len + 1);
    }
}

/// Write multiple IoSlice buffers using write_vectored (writev syscall).
/// Batches into MAX_IOV-sized groups. Hot path: single write_vectored succeeds.
/// Cold path (partial write) is out-of-line to keep the hot loop tight.
#[inline]
fn write_ioslices(out: &mut impl Write, slices: &[IoSlice]) -> io::Result<()> {
    if slices.is_empty() {
        return Ok(());
    }
    for batch in slices.chunks(MAX_IOV) {
        let total: usize = batch.iter().map(|s| s.len()).sum();
        let written = out.write_vectored(batch)?;
        if written >= total {
            continue;
        }
        if written == 0 {
            return Err(io::Error::new(io::ErrorKind::WriteZero, "write zero"));
        }
        write_ioslices_slow(out, batch, written)?;
    }
    Ok(())
}

/// Handle partial write_vectored (cold path, never inlined).
#[cold]
#[inline(never)]
fn write_ioslices_slow(
    out: &mut impl Write,
    slices: &[IoSlice],
    mut skip: usize,
) -> io::Result<()> {
    for slice in slices {
        let len = slice.len();
        if skip >= len {
            skip -= len;
            continue;
        }
        out.write_all(&slice[skip..])?;
        skip = 0;
    }
    Ok(())
}

// ── Chunk splitting for parallel processing ──────────────────────────────

/// Number of available CPUs for parallel chunk splitting.
/// Uses std::thread::available_parallelism() to avoid triggering premature
/// rayon pool initialization (~300-500µs). Rayon pool inits on first scope() call.
#[inline]
fn num_cpus() -> usize {
    std::thread::available_parallelism()
        .map(|n| n.get())
        .unwrap_or(1)
}

/// Split data into chunks for rayon::scope parallel processing.
/// Uses Rayon's thread count to match the number of worker threads.
fn split_for_scope<'a>(data: &'a [u8], line_delim: u8) -> Vec<&'a [u8]> {
    let num_threads = num_cpus().max(1);
    if data.len() < PARALLEL_THRESHOLD || num_threads <= 1 {
        return vec![data];
    }

    let chunk_size = data.len() / num_threads;
    let mut chunks = Vec::with_capacity(num_threads);
    let mut pos = 0;

    for _ in 0..num_threads - 1 {
        let target = pos + chunk_size;
        if target >= data.len() {
            break;
        }
        let boundary = memchr::memchr(line_delim, &data[target..])
            .map(|p| target + p + 1)
            .unwrap_or(data.len());
        if boundary > pos {
            chunks.push(&data[pos..boundary]);
        }
        pos = boundary;
    }

    if pos < data.len() {
        chunks.push(&data[pos..]);
    }

    chunks
}

// ── Fast path: multi-field non-contiguous extraction ─────────────────────

/// Multi-field non-contiguous extraction (e.g., `cut -d, -f1,3,5`).
/// Pre-collects delimiter positions per line into a stack-allocated array,
/// then directly indexes into them for each selected field.
/// This is O(max_field) per line instead of O(num_fields * scan_length).
fn process_fields_multi_select(
    data: &[u8],
    delim: u8,
    line_delim: u8,
    ranges: &[Range],
    suppress: bool,
    out: &mut impl Write,
) -> io::Result<()> {
    let max_field = ranges.last().map_or(0, |r| r.end);

    if data.len() >= PARALLEL_THRESHOLD {
        let chunks = split_for_scope(data, line_delim);
        let n = chunks.len();
        let mut results: Vec<Vec<u8>> = (0..n).map(|_| Vec::new()).collect();
        rayon::scope(|s| {
            for (chunk, result) in chunks.iter().zip(results.iter_mut()) {
                s.spawn(move |_| {
                    result.reserve(chunk.len() * 3 / 4);
                    multi_select_chunk(
                        chunk, delim, line_delim, ranges, max_field, suppress, result,
                    );
                });
            }
        });
        let slices: Vec<IoSlice> = results
            .iter()
            .filter(|r| !r.is_empty())
            .map(|r| IoSlice::new(r))
            .collect();
        write_ioslices(out, &slices)?;
    } else {
        let mut buf = Vec::with_capacity(data.len() * 3 / 4);
        multi_select_chunk(
            data, delim, line_delim, ranges, max_field, suppress, &mut buf,
        );
        if !buf.is_empty() {
            out.write_all(&buf)?;
        }
    }
    Ok(())
}

/// Process a chunk for multi-field extraction.
/// Uses single-pass memchr2 with bitmask field selection when max_field <= 64.
/// Falls back to two-level scanning for larger field numbers.
fn multi_select_chunk(
    data: &[u8],
    delim: u8,
    line_delim: u8,
    ranges: &[Range],
    max_field: usize,
    suppress: bool,
    buf: &mut Vec<u8>,
) {
    // Single-pass bitmask approach for small field numbers (common case).
    // One memchr2 scan finds both delimiters and newlines simultaneously,
    // avoiding per-line function call overhead and delimiter position arrays.
    if max_field <= 64 && delim != line_delim {
        let mut mask: u64 = 0;
        for r in ranges {
            let s = r.start.max(1);
            let e = r.end.min(64);
            for f in s..=e {
                mask |= 1u64 << (f - 1);
            }
        }
        multi_select_chunk_bitmask(data, delim, line_delim, mask, max_field, suppress, buf);
        return;
    }

    // Fallback: two-level scanning for large field numbers
    buf.reserve(data.len());
    let base = data.as_ptr();
    let mut start = 0;
    let max_delims = max_field.min(128);

    for end_pos in memchr_iter(line_delim, data) {
        let line = unsafe { std::slice::from_raw_parts(base.add(start), end_pos - start) };
        multi_select_line_fast(
            line, delim, line_delim, ranges, max_delims, suppress, buf, start, base,
        );
        start = end_pos + 1;
    }
    if start < data.len() {
        let line = unsafe { std::slice::from_raw_parts(base.add(start), data.len() - start) };
        multi_select_line_fast(
            line, delim, line_delim, ranges, max_delims, suppress, buf, start, base,
        );
    }
}

/// Single-pass multi-field extraction using memchr2 + bitmask selection.
/// Processes the entire data in one SIMD scan, tracking field numbers
/// and outputting selected fields. Uses raw pointer writes to eliminate
/// Vec method overhead (no capacity checks, no length updates per field).
fn multi_select_chunk_bitmask(
    data: &[u8],
    delim: u8,
    line_delim: u8,
    mask: u64,
    _max_field: usize,
    suppress: bool,
    buf: &mut Vec<u8>,
) {
    // Reserve worst case: entire data + one extra byte per field for delimiters
    buf.reserve(data.len() + 1);
    let initial_len = buf.len();
    let out_base = unsafe { buf.as_mut_ptr().add(initial_len) };
    let src = data.as_ptr();
    let mut wp: usize = 0;

    let mut field_num: usize = 1; // 1-based
    let mut field_start: usize = 0;
    let mut first_on_line = true;
    let mut line_has_delim = false;
    let mut line_start: usize = 0;

    for hit in memchr::memchr2_iter(delim, line_delim, data) {
        if data[hit] == line_delim {
            // End of line
            if !line_has_delim {
                if !suppress {
                    let len = hit - line_start;
                    unsafe {
                        std::ptr::copy_nonoverlapping(src.add(line_start), out_base.add(wp), len);
                    }
                    wp += len;
                    unsafe {
                        *out_base.add(wp) = line_delim;
                    }
                    wp += 1;
                }
            } else {
                if field_num <= 64 && (mask & (1u64 << (field_num - 1))) != 0 {
                    if !first_on_line {
                        unsafe {
                            *out_base.add(wp) = delim;
                        }
                        wp += 1;
                    }
                    let len = hit - field_start;
                    unsafe {
                        std::ptr::copy_nonoverlapping(src.add(field_start), out_base.add(wp), len);
                    }
                    wp += len;
                }
                unsafe {
                    *out_base.add(wp) = line_delim;
                }
                wp += 1;
            }
            field_num = 1;
            field_start = hit + 1;
            line_start = hit + 1;
            first_on_line = true;
            line_has_delim = false;
        } else {
            // Delimiter
            line_has_delim = true;
            if field_num <= 64 && (mask & (1u64 << (field_num - 1))) != 0 {
                if !first_on_line {
                    unsafe {
                        *out_base.add(wp) = delim;
                    }
                    wp += 1;
                }
                let len = hit - field_start;
                unsafe {
                    std::ptr::copy_nonoverlapping(src.add(field_start), out_base.add(wp), len);
                }
                wp += len;
                first_on_line = false;
            }
            field_num += 1;
            field_start = hit + 1;
        }
    }

    // Handle final segment
    if field_start < data.len() {
        if !line_has_delim {
            if !suppress {
                let len = data.len() - line_start;
                unsafe {
                    std::ptr::copy_nonoverlapping(src.add(line_start), out_base.add(wp), len);
                }
                wp += len;
                unsafe {
                    *out_base.add(wp) = line_delim;
                }
                wp += 1;
            }
        } else {
            if field_num <= 64 && (mask & (1u64 << (field_num - 1))) != 0 {
                if !first_on_line {
                    unsafe {
                        *out_base.add(wp) = delim;
                    }
                    wp += 1;
                }
                let len = data.len() - field_start;
                unsafe {
                    std::ptr::copy_nonoverlapping(src.add(field_start), out_base.add(wp), len);
                }
                wp += len;
            }
            unsafe {
                *out_base.add(wp) = line_delim;
            }
            wp += 1;
        }
    }

    unsafe {
        buf.set_len(initial_len + wp);
    }
}

/// Extract selected fields from a single line using delimiter position scanning.
/// Optimized: collects delimiter positions into a stack array with early exit at max_delims,
/// then indexes directly for each selected field. Uses raw pointer arithmetic.
#[inline(always)]
fn multi_select_line_fast(
    line: &[u8],
    delim: u8,
    line_delim: u8,
    ranges: &[Range],
    max_delims: usize,
    suppress: bool,
    buf: &mut Vec<u8>,
    _line_abs_start: usize,
    _data_base: *const u8,
) {
    let len = line.len();
    if len == 0 {
        if !suppress {
            unsafe { buf_push(buf, line_delim) };
        }
        return;
    }

    let base = line.as_ptr();

    // Collect delimiter positions up to max_delims (early exit).
    let mut delim_pos = [0usize; 128];
    let mut num_delims: usize = 0;

    for pos in memchr_iter(delim, line) {
        if num_delims < max_delims {
            delim_pos[num_delims] = pos;
            num_delims += 1;
            if num_delims >= max_delims {
                break;
            }
        }
    }

    if num_delims == 0 {
        if !suppress {
            unsafe {
                buf_extend(buf, line);
                buf_push(buf, line_delim);
            }
        }
        return;
    }

    let total_fields = num_delims + 1;
    let mut first_output = true;

    for r in ranges {
        let range_start = r.start;
        let range_end = r.end.min(total_fields);
        if range_start > total_fields {
            break;
        }
        for field_num in range_start..=range_end {
            if field_num > total_fields {
                break;
            }

            let field_start = if field_num == 1 {
                0
            } else if field_num - 2 < num_delims {
                delim_pos[field_num - 2] + 1
            } else {
                continue;
            };
            let field_end = if field_num <= num_delims {
                delim_pos[field_num - 1]
            } else {
                len
            };

            if !first_output {
                unsafe { buf_push(buf, delim) };
            }
            unsafe {
                buf_extend(
                    buf,
                    std::slice::from_raw_parts(base.add(field_start), field_end - field_start),
                );
            }
            first_output = false;
        }
    }

    unsafe { buf_push(buf, line_delim) };
}

// ── Fast path: field extraction with batched output ──────────────────────

/// Optimized field extraction with early exit and batched output.
fn process_fields_fast(data: &[u8], cfg: &CutConfig, out: &mut impl Write) -> io::Result<()> {
    let delim = cfg.delim;
    let line_delim = cfg.line_delim;
    let ranges = cfg.ranges;
    let complement = cfg.complement;
    let output_delim = cfg.output_delim;
    let suppress = cfg.suppress_no_delim;

    // NOTE: Removed the full-file `memchr(delim, data).is_none()` scan.
    // That scan was O(N) over the entire file just to check an edge case
    // (no delimiter in any line). The per-line processing already handles
    // lines without delimiters correctly, so the scan was pure overhead
    // for files that DO contain delimiters (the common case).

    // Ultra-fast path: single field extraction (e.g., cut -f5)
    if !complement && ranges.len() == 1 && ranges[0].start == ranges[0].end {
        return process_single_field(data, delim, line_delim, ranges[0].start, suppress, out);
    }

    // Fast path: complement of single field or contiguous range with default output delimiter.
    if complement
        && ranges.len() == 1
        && output_delim.len() == 1
        && output_delim[0] == delim
        && ranges[0].start == ranges[0].end
    {
        return process_complement_single_field(
            data,
            delim,
            line_delim,
            ranges[0].start,
            suppress,
            out,
        );
    }

    // Fast path: complement of contiguous range (e.g., --complement -f3-5 = output fields 1,2,6+).
    // This is equivalent to outputting a prefix and a suffix, skipping the middle range.
    if complement
        && ranges.len() == 1
        && ranges[0].start > 1
        && ranges[0].end < usize::MAX
        && output_delim.len() == 1
        && output_delim[0] == delim
    {
        return process_complement_range(
            data,
            delim,
            line_delim,
            ranges[0].start,
            ranges[0].end,
            suppress,
            out,
        );
    }

    // Fast path: contiguous from-start field range (e.g., cut -f1-5)
    if !complement
        && ranges.len() == 1
        && ranges[0].start == 1
        && output_delim.len() == 1
        && output_delim[0] == delim
        && ranges[0].end < usize::MAX
    {
        return process_fields_prefix(data, delim, line_delim, ranges[0].end, suppress, out);
    }

    // Fast path: open-ended field range from field N (e.g., cut -f3-)
    if !complement
        && ranges.len() == 1
        && ranges[0].end == usize::MAX
        && ranges[0].start > 1
        && output_delim.len() == 1
        && output_delim[0] == delim
    {
        return process_fields_suffix(data, delim, line_delim, ranges[0].start, suppress, out);
    }

    // Fast path: contiguous field range with start > 1 (e.g., cut -f2-4)
    if !complement
        && ranges.len() == 1
        && ranges[0].start > 1
        && ranges[0].end < usize::MAX
        && output_delim.len() == 1
        && output_delim[0] == delim
    {
        return process_fields_mid_range(
            data,
            delim,
            line_delim,
            ranges[0].start,
            ranges[0].end,
            suppress,
            out,
        );
    }

    // Fast path: multi-field non-contiguous extraction (e.g., cut -f1,3,5)
    // Uses delimiter position caching: find all delimiter positions per line,
    // then directly index into them for each selected field.
    // This is faster than the general extract_fields_to_buf which re-checks
    // is_selected() for every field encountered.
    if !complement
        && ranges.len() > 1
        && ranges.last().map_or(false, |r| r.end < usize::MAX)
        && output_delim.len() == 1
        && output_delim[0] == delim
        && delim != line_delim
    {
        return process_fields_multi_select(data, delim, line_delim, ranges, suppress, out);
    }

    // General field extraction
    let max_field = if complement {
        usize::MAX
    } else {
        ranges.last().map(|r| r.end).unwrap_or(0)
    };
    let field_mask = compute_field_mask(ranges, complement);

    if data.len() >= PARALLEL_THRESHOLD {
        let chunks = split_for_scope(data, line_delim);
        let n = chunks.len();
        let mut results: Vec<Vec<u8>> = (0..n).map(|_| Vec::new()).collect();
        rayon::scope(|s| {
            for (chunk, result) in chunks.iter().zip(results.iter_mut()) {
                s.spawn(move |_| {
                    result.reserve(chunk.len() + 1);
                    process_fields_chunk(
                        chunk,
                        delim,
                        ranges,
                        output_delim,
                        suppress,
                        max_field,
                        field_mask,
                        line_delim,
                        complement,
                        result,
                    );
                });
            }
        });
        let slices: Vec<IoSlice> = results
            .iter()
            .filter(|r| !r.is_empty())
            .map(|r| IoSlice::new(r))
            .collect();
        write_ioslices(out, &slices)?;
    } else {
        // +1 for potential trailing line_delim when input doesn't end with one
        let mut buf = Vec::with_capacity(data.len() + 1);
        process_fields_chunk(
            data,
            delim,
            ranges,
            output_delim,
            suppress,
            max_field,
            field_mask,
            line_delim,
            complement,
            &mut buf,
        );
        if !buf.is_empty() {
            out.write_all(&buf)?;
        }
    }
    Ok(())
}

/// Process a chunk of data for general field extraction.
/// Uses two-level scanning: outer memchr(newline) for line boundaries, inner
/// memchr_iter(delim) for delimiter positions. This is faster than memchr2 single-pass
/// because memchr (one needle) is ~30-50% faster per byte than memchr2 (two needles).
fn process_fields_chunk(
    data: &[u8],
    delim: u8,
    ranges: &[Range],
    output_delim: &[u8],
    suppress: bool,
    max_field: usize,
    field_mask: u64,
    line_delim: u8,
    complement: bool,
    buf: &mut Vec<u8>,
) {
    // Always use two-level approach: outer memchr(newline) + inner memchr_iter(delim).
    // Even for complement/unbounded ranges, two-level is faster because memchr is
    // ~30-50% faster per byte than memchr2. The per-line function call overhead
    // is negligible compared to the SIMD scan savings.
    if delim != line_delim {
        buf.reserve(data.len());
        let mut start = 0;
        for end_pos in memchr_iter(line_delim, data) {
            let line = &data[start..end_pos];
            extract_fields_to_buf(
                line,
                delim,
                ranges,
                output_delim,
                suppress,
                max_field,
                field_mask,
                line_delim,
                buf,
                complement,
            );
            start = end_pos + 1;
        }
        if start < data.len() {
            extract_fields_to_buf(
                &data[start..],
                delim,
                ranges,
                output_delim,
                suppress,
                max_field,
                field_mask,
                line_delim,
                buf,
                complement,
            );
        }
        return;
    }

    // Fallback: when delim == line_delim, use the two-level scan approach
    let mut start = 0;
    for end_pos in memchr_iter(line_delim, data) {
        let line = &data[start..end_pos];
        extract_fields_to_buf(
            line,
            delim,
            ranges,
            output_delim,
            suppress,
            max_field,
            field_mask,
            line_delim,
            buf,
            complement,
        );
        start = end_pos + 1;
    }
    if start < data.len() {
        extract_fields_to_buf(
            &data[start..],
            delim,
            ranges,
            output_delim,
            suppress,
            max_field,
            field_mask,
            line_delim,
            buf,
            complement,
        );
    }
}

// ── Ultra-fast single field extraction ───────────────────────────────────

/// Specialized path for extracting exactly one field (e.g., `cut -f5`).
/// Uses two-level scanning: outer memchr(newline) for line boundaries, inner
/// memchr(delim) for the field delimiter with early exit.
fn process_single_field(
    data: &[u8],
    delim: u8,
    line_delim: u8,
    target: usize,
    suppress: bool,
    out: &mut impl Write,
) -> io::Result<()> {
    let target_idx = target - 1;

    // For single-field extraction, parallelize at 16MB+ to match PARALLEL_THRESHOLD.
    const FIELD_PARALLEL_MIN: usize = 16 * 1024 * 1024;

    if delim != line_delim {
        // Field 1 fast path: two-level scan (outer newline + inner first-delim).
        // For field 1, only needs to find the first delimiter per line.
        // Lines without delimiter are tracked as contiguous runs for bulk copy.
        if target_idx == 0 && !suppress {
            if data.len() >= FIELD_PARALLEL_MIN {
                return single_field1_parallel(data, delim, line_delim, out);
            }
            // Sequential: two-level scan into buffer, single write_all.
            // Buffer approach is faster than writev for high-delimiter-density
            // data because it produces one contiguous buffer (one write syscall)
            // instead of many IoSlice entries (kernel overhead per iovec).
            let mut buf = Vec::with_capacity(data.len() + 1);
            single_field1_to_buf(data, delim, line_delim, &mut buf);
            if !buf.is_empty() {
                out.write_all(&buf)?;
            }
            return Ok(());
        }

        // Two-level approach for field N: outer newline scan + inner delim scan
        // with early exit at target_idx. Faster than memchr2 single-pass because
        // we only scan delimiters up to target_idx per line (not all of them).
        if data.len() >= FIELD_PARALLEL_MIN {
            let chunks = split_for_scope(data, line_delim);
            let n = chunks.len();
            let mut results: Vec<Vec<u8>> = (0..n).map(|_| Vec::new()).collect();
            rayon::scope(|s| {
                for (chunk, result) in chunks.iter().zip(results.iter_mut()) {
                    s.spawn(move |_| {
                        result.reserve(chunk.len() / 2);
                        process_single_field_chunk(
                            chunk, delim, target_idx, line_delim, suppress, result,
                        );
                    });
                }
            });
            let slices: Vec<IoSlice> = results
                .iter()
                .filter(|r| !r.is_empty())
                .map(|r| IoSlice::new(r))
                .collect();
            write_ioslices(out, &slices)?;
        } else {
            let mut buf = Vec::with_capacity(data.len().min(4 * 1024 * 1024));
            process_single_field_chunk(data, delim, target_idx, line_delim, suppress, &mut buf);
            if !buf.is_empty() {
                out.write_all(&buf)?;
            }
        }
        return Ok(());
    }

    // Fallback for delim == line_delim: nested loop approach
    if data.len() >= FIELD_PARALLEL_MIN {
        let chunks = split_for_scope(data, line_delim);
        let n = chunks.len();
        let mut results: Vec<Vec<u8>> = (0..n).map(|_| Vec::new()).collect();
        rayon::scope(|s| {
            for (chunk, result) in chunks.iter().zip(results.iter_mut()) {
                s.spawn(move |_| {
                    result.reserve(chunk.len() / 4);
                    process_single_field_chunk(
                        chunk, delim, target_idx, line_delim, suppress, result,
                    );
                });
            }
        });
        let slices: Vec<IoSlice> = results
            .iter()
            .filter(|r| !r.is_empty())
            .map(|r| IoSlice::new(r))
            .collect();
        write_ioslices(out, &slices)?;
    } else {
        let mut buf = Vec::with_capacity(data.len() / 4);
        process_single_field_chunk(data, delim, target_idx, line_delim, suppress, &mut buf);
        if !buf.is_empty() {
            out.write_all(&buf)?;
        }
    }
    Ok(())
}

/// Complement range extraction: skip fields start..=end, output rest (e.g., --complement -f3-5).
/// For each line: output fields 1..start-1, then fields end+1..EOF, skipping fields start..end.
fn process_complement_range(
    data: &[u8],
    delim: u8,
    line_delim: u8,
    skip_start: usize,
    skip_end: usize,
    suppress: bool,
    out: &mut impl Write,
) -> io::Result<()> {
    if data.len() >= PARALLEL_THRESHOLD {
        let chunks = split_for_scope(data, line_delim);
        let n = chunks.len();
        let mut results: Vec<Vec<u8>> = (0..n).map(|_| Vec::new()).collect();
        rayon::scope(|s| {
            for (chunk, result) in chunks.iter().zip(results.iter_mut()) {
                s.spawn(move |_| {
                    result.reserve(chunk.len());
                    complement_range_chunk(
                        chunk, delim, skip_start, skip_end, line_delim, suppress, result,
                    );
                });
            }
        });
        let slices: Vec<IoSlice> = results
            .iter()
            .filter(|r| !r.is_empty())
            .map(|r| IoSlice::new(r))
            .collect();
        write_ioslices(out, &slices)?;
    } else {
        let mut buf = Vec::with_capacity(data.len());
        complement_range_chunk(
            data, delim, skip_start, skip_end, line_delim, suppress, &mut buf,
        );
        if !buf.is_empty() {
            out.write_all(&buf)?;
        }
    }
    Ok(())
}

/// Process a chunk for complement range extraction.
fn complement_range_chunk(
    data: &[u8],
    delim: u8,
    skip_start: usize,
    skip_end: usize,
    line_delim: u8,
    suppress: bool,
    buf: &mut Vec<u8>,
) {
    // Pre-reserve entire chunk capacity to eliminate per-line reserve overhead.
    buf.reserve(data.len());
    let mut start = 0;
    for end_pos in memchr_iter(line_delim, data) {
        let line = &data[start..end_pos];
        complement_range_line(line, delim, skip_start, skip_end, line_delim, suppress, buf);
        start = end_pos + 1;
    }
    if start < data.len() {
        complement_range_line(
            &data[start..],
            delim,
            skip_start,
            skip_end,
            line_delim,
            suppress,
            buf,
        );
    }
}

/// Extract all fields except skip_start..=skip_end from one line.
/// Outputs fields 1..skip_start-1, then fields skip_end+1..EOF.
///
/// Optimized: only scans for enough delimiters to find the skip region boundaries.
/// For `--complement -f3-5` with 20 fields, this finds delimiter 2 and 5, then
/// does a single copy of prefix + suffix, avoiding scanning past field 5.
#[inline(always)]
fn complement_range_line(
    line: &[u8],
    delim: u8,
    skip_start: usize,
    skip_end: usize,
    line_delim: u8,
    suppress: bool,
    buf: &mut Vec<u8>,
) {
    let len = line.len();
    if len == 0 {
        if !suppress {
            unsafe { buf_push(buf, line_delim) };
        }
        return;
    }

    // Note: no per-line buf.reserve — complement_range_chunk already reserves data.len()
    let base = line.as_ptr();

    // 1-based field numbers. To skip fields skip_start..=skip_end:
    // - prefix_end = position of (skip_start-1)th delimiter (exclusive; end of prefix fields)
    // - suffix_start = position after skip_end-th delimiter (inclusive; start of suffix fields)
    //
    // Find the first (skip_start - 1) delimiters to locate prefix_end,
    // then the next (skip_end - skip_start + 1) delimiters to locate suffix_start.

    let need_prefix_delims = skip_start - 1; // number of delimiters before the skip region
    let need_skip_delims = skip_end - skip_start + 1; // delimiters within the skip region
    let total_need = need_prefix_delims + need_skip_delims;

    // Find delimiter positions up to total_need
    let mut delim_count: usize = 0;
    let mut prefix_end_pos: usize = usize::MAX; // byte position of (skip_start-1)th delim
    let mut suffix_start_pos: usize = usize::MAX; // byte position after skip_end-th delim

    for pos in memchr_iter(delim, line) {
        delim_count += 1;
        if delim_count == need_prefix_delims {
            prefix_end_pos = pos;
        }
        if delim_count == total_need {
            suffix_start_pos = pos + 1;
            break;
        }
    }

    if delim_count == 0 {
        // No delimiter at all
        if !suppress {
            unsafe {
                buf_extend(buf, line);
                buf_push(buf, line_delim);
            }
        }
        return;
    }

    // Case analysis:
    // 1. Not enough delims to reach skip_start: all fields are before skip region, output all
    // 2. Enough to reach skip_start but not skip_end: prefix + no suffix
    // 3. Enough to reach skip_end: prefix + delim + suffix

    if delim_count < need_prefix_delims {
        // Not enough fields to reach skip region — output entire line
        unsafe {
            buf_extend(buf, line);
            buf_push(buf, line_delim);
        }
        return;
    }

    let has_prefix = need_prefix_delims > 0;
    let has_suffix = suffix_start_pos != usize::MAX && suffix_start_pos < len;

    if has_prefix && has_suffix {
        // Output: prefix (up to prefix_end_pos) + delim + suffix (from suffix_start_pos)
        unsafe {
            buf_extend(buf, std::slice::from_raw_parts(base, prefix_end_pos));
            buf_push(buf, delim);
            buf_extend(
                buf,
                std::slice::from_raw_parts(base.add(suffix_start_pos), len - suffix_start_pos),
            );
            buf_push(buf, line_delim);
        }
    } else if has_prefix {
        // Only prefix, no suffix (skip region extends to end of line)
        unsafe {
            buf_extend(buf, std::slice::from_raw_parts(base, prefix_end_pos));
            buf_push(buf, line_delim);
        }
    } else if has_suffix {
        // No prefix (skip_start == 1), only suffix
        unsafe {
            buf_extend(
                buf,
                std::slice::from_raw_parts(base.add(suffix_start_pos), len - suffix_start_pos),
            );
            buf_push(buf, line_delim);
        }
    } else {
        // All fields skipped
        unsafe { buf_push(buf, line_delim) };
    }
}

/// Complement single-field extraction: skip one field, output rest unchanged.
fn process_complement_single_field(
    data: &[u8],
    delim: u8,
    line_delim: u8,
    skip_field: usize,
    suppress: bool,
    out: &mut impl Write,
) -> io::Result<()> {
    let skip_idx = skip_field - 1;

    if data.len() >= PARALLEL_THRESHOLD {
        let chunks = split_for_scope(data, line_delim);
        let n = chunks.len();
        let mut results: Vec<Vec<u8>> = (0..n).map(|_| Vec::new()).collect();
        rayon::scope(|s| {
            for (chunk, result) in chunks.iter().zip(results.iter_mut()) {
                s.spawn(move |_| {
                    result.reserve(chunk.len());
                    complement_single_field_chunk(
                        chunk, delim, skip_idx, line_delim, suppress, result,
                    );
                });
            }
        });
        let slices: Vec<IoSlice> = results
            .iter()
            .filter(|r| !r.is_empty())
            .map(|r| IoSlice::new(r))
            .collect();
        write_ioslices(out, &slices)?;
    } else {
        let mut buf = Vec::with_capacity(data.len());
        complement_single_field_chunk(data, delim, skip_idx, line_delim, suppress, &mut buf);
        if !buf.is_empty() {
            out.write_all(&buf)?;
        }
    }
    Ok(())
}

/// Process a chunk for complement single-field extraction using two-level scanning.
/// Outer memchr(newline) for line boundaries, inner memchr_iter(delim) with early exit
/// after finding the skip field's bounding delimiters. Faster than memchr2 single-pass
/// because memchr is faster per byte and inner scan exits early.
fn complement_single_field_chunk(
    data: &[u8],
    delim: u8,
    skip_idx: usize,
    line_delim: u8,
    suppress: bool,
    buf: &mut Vec<u8>,
) {
    buf.reserve(data.len());
    let mut start = 0;
    for end_pos in memchr_iter(line_delim, data) {
        let line = &data[start..end_pos];
        complement_single_field_line(line, delim, skip_idx, line_delim, suppress, buf);
        start = end_pos + 1;
    }
    if start < data.len() {
        complement_single_field_line(&data[start..], delim, skip_idx, line_delim, suppress, buf);
    }
}

/// Fallback per-line complement single-field extraction (for delim == line_delim).
#[inline(always)]
fn complement_single_field_line(
    line: &[u8],
    delim: u8,
    skip_idx: usize,
    line_delim: u8,
    suppress: bool,
    buf: &mut Vec<u8>,
) {
    let len = line.len();
    if len == 0 {
        if !suppress {
            unsafe { buf_push(buf, line_delim) };
        }
        return;
    }

    let base = line.as_ptr();
    let need_before = skip_idx;
    let need_total = skip_idx + 1;

    let mut delim_count: usize = 0;
    let mut skip_start_pos: usize = 0;
    let mut skip_end_pos: usize = len;
    let mut found_end = false;

    for pos in memchr_iter(delim, line) {
        delim_count += 1;
        if delim_count == need_before {
            skip_start_pos = pos + 1;
        }
        if delim_count == need_total {
            skip_end_pos = pos;
            found_end = true;
            break;
        }
    }

    if delim_count == 0 {
        if !suppress {
            unsafe {
                buf_extend(buf, line);
                buf_push(buf, line_delim);
            }
        }
        return;
    }

    if delim_count < need_before {
        unsafe {
            buf_extend(buf, line);
            buf_push(buf, line_delim);
        }
        return;
    }

    let has_prefix = skip_idx > 0 && skip_start_pos > 0;
    let has_suffix = found_end && skip_end_pos < len;

    if has_prefix && has_suffix {
        unsafe {
            buf_extend(buf, std::slice::from_raw_parts(base, skip_start_pos - 1));
            buf_push(buf, delim);
            buf_extend(
                buf,
                std::slice::from_raw_parts(base.add(skip_end_pos + 1), len - skip_end_pos - 1),
            );
            buf_push(buf, line_delim);
        }
    } else if has_prefix {
        unsafe {
            buf_extend(buf, std::slice::from_raw_parts(base, skip_start_pos - 1));
            buf_push(buf, line_delim);
        }
    } else if has_suffix {
        unsafe {
            buf_extend(
                buf,
                std::slice::from_raw_parts(base.add(skip_end_pos + 1), len - skip_end_pos - 1),
            );
            buf_push(buf, line_delim);
        }
    } else {
        unsafe { buf_push(buf, line_delim) };
    }
}

/// Contiguous from-start field range extraction (e.g., `cut -f1-5`).
/// Zero-copy for the non-parallel path: identifies the truncation point per line
/// and writes contiguous runs directly from the source data.
fn process_fields_prefix(
    data: &[u8],
    delim: u8,
    line_delim: u8,
    last_field: usize,
    suppress: bool,
    out: &mut impl Write,
) -> io::Result<()> {
    if data.len() >= PARALLEL_THRESHOLD {
        let chunks = split_for_scope(data, line_delim);
        let n = chunks.len();
        let mut results: Vec<Vec<u8>> = (0..n).map(|_| Vec::new()).collect();
        rayon::scope(|s| {
            for (chunk, result) in chunks.iter().zip(results.iter_mut()) {
                s.spawn(move |_| {
                    result.reserve(chunk.len());
                    fields_prefix_chunk(chunk, delim, line_delim, last_field, suppress, result);
                });
            }
        });
        let slices: Vec<IoSlice> = results
            .iter()
            .filter(|r| !r.is_empty())
            .map(|r| IoSlice::new(r))
            .collect();
        write_ioslices(out, &slices)?;
    } else if !suppress {
        // Zero-copy fast path: scan for truncation points, write runs from source.
        // When suppress is false, every line is output (with or without delimiter).
        // Most lines have enough fields, so the output is often identical to input.
        fields_prefix_zerocopy(data, delim, line_delim, last_field, out)?;
    } else {
        let mut buf = Vec::with_capacity(data.len());
        fields_prefix_chunk(data, delim, line_delim, last_field, suppress, &mut buf);
        if !buf.is_empty() {
            out.write_all(&buf)?;
        }
    }
    Ok(())
}

/// Zero-copy field-prefix extraction using writev: builds IoSlice entries pointing
/// directly into the source data, flushing in MAX_IOV-sized batches.
/// For lines where the Nth delimiter exists, we truncate at that point.
/// For lines with fewer fields, we output them unchanged (contiguous run).
/// Lines without any delimiter are output unchanged (suppress=false assumed).
#[inline]
fn fields_prefix_zerocopy(
    data: &[u8],
    delim: u8,
    line_delim: u8,
    last_field: usize,
    out: &mut impl Write,
) -> io::Result<()> {
    let newline_buf: [u8; 1] = [line_delim];
    let mut iov: Vec<IoSlice> = Vec::with_capacity(MAX_IOV);
    let mut start = 0;
    let mut run_start: usize = 0;

    for end_pos in memchr_iter(line_delim, data) {
        let line = &data[start..end_pos];
        let mut field_count = 1;
        let mut truncate_at: Option<usize> = None;
        for dpos in memchr_iter(delim, line) {
            if field_count >= last_field {
                truncate_at = Some(start + dpos);
                break;
            }
            field_count += 1;
        }

        if let Some(trunc_pos) = truncate_at {
            if run_start < start {
                iov.push(IoSlice::new(&data[run_start..start]));
            }
            iov.push(IoSlice::new(&data[start..trunc_pos]));
            iov.push(IoSlice::new(&newline_buf));
            run_start = end_pos + 1;

            if iov.len() >= MAX_IOV - 2 {
                write_ioslices(out, &iov)?;
                iov.clear();
            }
        }
        start = end_pos + 1;
    }
    // Handle last line without terminator
    if start < data.len() {
        let line = &data[start..];
        let mut field_count = 1;
        let mut truncate_at: Option<usize> = None;
        for dpos in memchr_iter(delim, line) {
            if field_count >= last_field {
                truncate_at = Some(start + dpos);
                break;
            }
            field_count += 1;
        }
        if let Some(trunc_pos) = truncate_at {
            if run_start < start {
                iov.push(IoSlice::new(&data[run_start..start]));
            }
            iov.push(IoSlice::new(&data[start..trunc_pos]));
            iov.push(IoSlice::new(&newline_buf));
            if !iov.is_empty() {
                write_ioslices(out, &iov)?;
            }
            return Ok(());
        }
    }
    // Flush remaining contiguous run
    if run_start < data.len() {
        iov.push(IoSlice::new(&data[run_start..]));
        if !data.is_empty() && *data.last().unwrap() != line_delim {
            iov.push(IoSlice::new(&newline_buf));
        }
    }
    if !iov.is_empty() {
        write_ioslices(out, &iov)?;
    }
    Ok(())
}

/// Process a chunk for contiguous from-start field range extraction.
fn fields_prefix_chunk(
    data: &[u8],
    delim: u8,
    line_delim: u8,
    last_field: usize,
    suppress: bool,
    buf: &mut Vec<u8>,
) {
    buf.reserve(data.len());
    let mut start = 0;
    for end_pos in memchr_iter(line_delim, data) {
        let line = &data[start..end_pos];
        fields_prefix_line(line, delim, line_delim, last_field, suppress, buf);
        start = end_pos + 1;
    }
    if start < data.len() {
        fields_prefix_line(&data[start..], delim, line_delim, last_field, suppress, buf);
    }
}

/// Extract first N fields from one line (contiguous from-start range).
/// Uses memchr SIMD for delimiter scanning on all line sizes.
#[inline(always)]
fn fields_prefix_line(
    line: &[u8],
    delim: u8,
    line_delim: u8,
    last_field: usize,
    suppress: bool,
    buf: &mut Vec<u8>,
) {
    let len = line.len();
    if len == 0 {
        if !suppress {
            unsafe { buf_push(buf, line_delim) };
        }
        return;
    }

    // Note: no per-line buf.reserve — fields_prefix_chunk already reserves data.len()
    let base = line.as_ptr();

    let mut field_count = 1usize;
    let mut has_delim = false;

    for pos in memchr_iter(delim, line) {
        has_delim = true;
        if field_count >= last_field {
            unsafe {
                buf_extend(buf, std::slice::from_raw_parts(base, pos));
                buf_push(buf, line_delim);
            }
            return;
        }
        field_count += 1;
    }

    if !has_delim {
        if !suppress {
            unsafe {
                buf_extend(buf, line);
                buf_push(buf, line_delim);
            }
        }
        return;
    }

    unsafe {
        buf_extend(buf, line);
        buf_push(buf, line_delim);
    }
}

/// Open-ended field suffix extraction (e.g., `cut -f3-`).
fn process_fields_suffix(
    data: &[u8],
    delim: u8,
    line_delim: u8,
    start_field: usize,
    suppress: bool,
    out: &mut impl Write,
) -> io::Result<()> {
    if data.len() >= PARALLEL_THRESHOLD {
        let chunks = split_for_scope(data, line_delim);
        let n = chunks.len();
        let mut results: Vec<Vec<u8>> = (0..n).map(|_| Vec::new()).collect();
        rayon::scope(|s| {
            for (chunk, result) in chunks.iter().zip(results.iter_mut()) {
                s.spawn(move |_| {
                    result.reserve(chunk.len());
                    fields_suffix_chunk(chunk, delim, line_delim, start_field, suppress, result);
                });
            }
        });
        let slices: Vec<IoSlice> = results
            .iter()
            .filter(|r| !r.is_empty())
            .map(|r| IoSlice::new(r))
            .collect();
        write_ioslices(out, &slices)?;
    } else {
        let mut buf = Vec::with_capacity(data.len());
        fields_suffix_chunk(data, delim, line_delim, start_field, suppress, &mut buf);
        if !buf.is_empty() {
            out.write_all(&buf)?;
        }
    }
    Ok(())
}

/// Process a chunk for open-ended field suffix extraction.
fn fields_suffix_chunk(
    data: &[u8],
    delim: u8,
    line_delim: u8,
    start_field: usize,
    suppress: bool,
    buf: &mut Vec<u8>,
) {
    buf.reserve(data.len());
    let mut start = 0;
    for end_pos in memchr_iter(line_delim, data) {
        let line = &data[start..end_pos];
        fields_suffix_line(line, delim, line_delim, start_field, suppress, buf);
        start = end_pos + 1;
    }
    if start < data.len() {
        fields_suffix_line(
            &data[start..],
            delim,
            line_delim,
            start_field,
            suppress,
            buf,
        );
    }
}

/// Extract fields from start_field to end from one line.
/// Uses memchr SIMD for delimiter scanning on all line sizes.
#[inline(always)]
fn fields_suffix_line(
    line: &[u8],
    delim: u8,
    line_delim: u8,
    start_field: usize,
    suppress: bool,
    buf: &mut Vec<u8>,
) {
    let len = line.len();
    if len == 0 {
        if !suppress {
            unsafe { buf_push(buf, line_delim) };
        }
        return;
    }

    // Note: no per-line buf.reserve — fields_suffix_chunk already reserves data.len()
    let base = line.as_ptr();

    let skip_delims = start_field - 1;
    let mut delim_count = 0usize;
    let mut has_delim = false;

    for pos in memchr_iter(delim, line) {
        has_delim = true;
        delim_count += 1;
        if delim_count >= skip_delims {
            unsafe {
                buf_extend(
                    buf,
                    std::slice::from_raw_parts(base.add(pos + 1), len - pos - 1),
                );
                buf_push(buf, line_delim);
            }
            return;
        }
    }

    if !has_delim {
        if !suppress {
            unsafe {
                buf_extend(buf, line);
                buf_push(buf, line_delim);
            }
        }
        return;
    }

    // Fewer delimiters than needed
    unsafe { buf_push(buf, line_delim) };
}

/// Contiguous mid-range field extraction (e.g., `cut -f2-4`).
/// Optimized: skip to start_field using memchr, then output until end_field.
fn process_fields_mid_range(
    data: &[u8],
    delim: u8,
    line_delim: u8,
    start_field: usize,
    end_field: usize,
    suppress: bool,
    out: &mut impl Write,
) -> io::Result<()> {
    if data.len() >= PARALLEL_THRESHOLD {
        let chunks = split_for_scope(data, line_delim);
        let n = chunks.len();
        let mut results: Vec<Vec<u8>> = (0..n).map(|_| Vec::new()).collect();
        rayon::scope(|s| {
            for (chunk, result) in chunks.iter().zip(results.iter_mut()) {
                s.spawn(move |_| {
                    result.reserve(chunk.len());
                    fields_mid_range_chunk(
                        chunk,
                        delim,
                        line_delim,
                        start_field,
                        end_field,
                        suppress,
                        result,
                    );
                });
            }
        });
        let slices: Vec<IoSlice> = results
            .iter()
            .filter(|r| !r.is_empty())
            .map(|r| IoSlice::new(r))
            .collect();
        write_ioslices(out, &slices)?;
    } else {
        let mut buf = Vec::with_capacity(data.len());
        fields_mid_range_chunk(
            data,
            delim,
            line_delim,
            start_field,
            end_field,
            suppress,
            &mut buf,
        );
        if !buf.is_empty() {
            out.write_all(&buf)?;
        }
    }
    Ok(())
}

/// Process a chunk for contiguous mid-range field extraction.
/// Two-level scan: outer memchr(newline) for line boundaries, inner memchr_iter(delim)
/// with early exit at target_end_delim. Faster than memchr2 single-pass because
/// memchr is faster per byte and inner scan exits early.
fn fields_mid_range_chunk(
    data: &[u8],
    delim: u8,
    line_delim: u8,
    start_field: usize,
    end_field: usize,
    suppress: bool,
    buf: &mut Vec<u8>,
) {
    buf.reserve(data.len());
    let mut start = 0;
    for end_pos in memchr_iter(line_delim, data) {
        let line = &data[start..end_pos];
        fields_mid_range_line(
            line,
            delim,
            line_delim,
            start_field,
            end_field,
            suppress,
            buf,
        );
        start = end_pos + 1;
    }
    if start < data.len() {
        fields_mid_range_line(
            &data[start..],
            delim,
            line_delim,
            start_field,
            end_field,
            suppress,
            buf,
        );
    }
}

/// Extract fields start_field..=end_field from one line.
/// Uses scalar byte scanning for short lines, memchr_iter for longer.
/// Raw pointer arithmetic to eliminate bounds checking.
#[inline(always)]
fn fields_mid_range_line(
    line: &[u8],
    delim: u8,
    line_delim: u8,
    start_field: usize,
    end_field: usize,
    suppress: bool,
    buf: &mut Vec<u8>,
) {
    let len = line.len();
    if len == 0 {
        if !suppress {
            unsafe { buf_push(buf, line_delim) };
        }
        return;
    }

    // Note: no per-line buf.reserve — fields_mid_range_chunk already reserves data.len()
    let base = line.as_ptr();

    // Count delimiters to find start_field and end_field boundaries
    let skip_before = start_field - 1; // delimiters to skip before start_field
    let field_span = end_field - start_field; // additional delimiters within the range
    let target_end_delim = skip_before + field_span + 1;
    let mut delim_count = 0;
    let mut range_start = 0;
    let mut has_delim = false;

    for pos in memchr_iter(delim, line) {
        has_delim = true;
        delim_count += 1;
        if delim_count == skip_before {
            range_start = pos + 1;
        }
        if delim_count == target_end_delim {
            if skip_before == 0 {
                range_start = 0;
            }
            unsafe {
                buf_extend(
                    buf,
                    std::slice::from_raw_parts(base.add(range_start), pos - range_start),
                );
                buf_push(buf, line_delim);
            }
            return;
        }
    }

    if !has_delim {
        if !suppress {
            unsafe {
                buf_extend(buf, line);
                buf_push(buf, line_delim);
            }
        }
        return;
    }

    // Line has delimiters but fewer fields than end_field
    if delim_count >= skip_before {
        // We have at least start_field, output from range_start to end
        if skip_before == 0 {
            range_start = 0;
        }
        unsafe {
            buf_extend(
                buf,
                std::slice::from_raw_parts(base.add(range_start), len - range_start),
            );
            buf_push(buf, line_delim);
        }
    } else {
        // Not enough fields even for start_field — output empty line
        unsafe { buf_push(buf, line_delim) };
    }
}

/// Zero-copy field-1 extraction using writev: builds IoSlice entries pointing
/// directly into the source data, flushing in MAX_IOV-sized batches.
/// For each line: if delimiter exists, output field1 + newline; otherwise pass through.
///
/// Uses a two-level scan: outer memchr(newline) for line boundaries, inner memchr(delim)
/// Parallel field-1 extraction for large data using memchr2 single-pass.
/// Splits data into per-thread chunks, each chunk extracts field 1 using
/// memchr2(delim, newline) which finds the first special byte in one scan.
/// For field 1: first special byte is either the delimiter (field end) or
/// newline (no delimiter, output line unchanged). 4 threads cut scan time ~4x.
fn single_field1_parallel(
    data: &[u8],
    delim: u8,
    line_delim: u8,
    out: &mut impl Write,
) -> io::Result<()> {
    let chunks = split_for_scope(data, line_delim);
    let n = chunks.len();
    let mut results: Vec<Vec<u8>> = (0..n).map(|_| Vec::new()).collect();
    rayon::scope(|s| {
        for (chunk, result) in chunks.iter().zip(results.iter_mut()) {
            s.spawn(move |_| {
                result.reserve(chunk.len() + 1);
                single_field1_to_buf(chunk, delim, line_delim, result);
            });
        }
    });
    let slices: Vec<IoSlice> = results
        .iter()
        .filter(|r| !r.is_empty())
        .map(|r| IoSlice::new(r))
        .collect();
    write_ioslices(out, &slices)
}

/// Extract field 1 from a chunk using two-level scanning: outer memchr(newline)
/// for line boundaries, inner memchr(delim) for the first delimiter per line.
///
/// This is faster than memchr2_iter single-pass because:
/// 1. memchr (one needle) is ~30-50% faster per byte than memchr2 (two needles)
/// 2. For field 1, the inner memchr exits after the FIRST delimiter, skipping
///    all subsequent delimiters on the line (huge win for multi-column CSV)
/// 3. Lines without delimiter produce contiguous runs that are bulk-copied
///
/// Uses a single output pointer to avoid per-line buf.len() load/store.
#[inline]
fn single_field1_to_buf(data: &[u8], delim: u8, line_delim: u8, buf: &mut Vec<u8>) {
    debug_assert_ne!(delim, line_delim, "delim and line_delim must differ");
    // Reserve data.len() + 1: output <= input for all lines except potentially
    // the last line without trailing newline, where we add a newline (GNU compat).
    buf.reserve(data.len() + 1);

    let base = data.as_ptr();
    let initial_len = buf.len();
    let mut out_ptr = unsafe { buf.as_mut_ptr().add(initial_len) };
    let mut start = 0;
    // Track the start of contiguous runs of no-delimiter lines for bulk copy.
    let mut run_start: usize = 0;
    let mut in_run = true; // we start in a run

    for end_pos in memchr_iter(line_delim, data) {
        let line = unsafe { std::slice::from_raw_parts(base.add(start), end_pos - start) };
        match memchr::memchr(delim, line) {
            Some(dp) => {
                // Line has delimiter — flush contiguous run, output field1 + newline
                if in_run && run_start < start {
                    // Bulk copy the contiguous run of unchanged lines
                    let run_len = start - run_start;
                    unsafe {
                        std::ptr::copy_nonoverlapping(base.add(run_start), out_ptr, run_len);
                        out_ptr = out_ptr.add(run_len);
                    }
                }
                // Output field (bytes before first delimiter) + newline
                unsafe {
                    std::ptr::copy_nonoverlapping(base.add(start), out_ptr, dp);
                    out_ptr = out_ptr.add(dp);
                    *out_ptr = line_delim;
                    out_ptr = out_ptr.add(1);
                }
                run_start = end_pos + 1;
                in_run = true;
            }
            None => {
                // No delimiter — this line stays in the contiguous run
                if !in_run {
                    run_start = start;
                    in_run = true;
                }
            }
        }
        start = end_pos + 1;
    }

    // Flush any remaining contiguous run
    if in_run && run_start < start {
        let run_len = start - run_start;
        unsafe {
            std::ptr::copy_nonoverlapping(base.add(run_start), out_ptr, run_len);
            out_ptr = out_ptr.add(run_len);
        }
    }

    // Handle last line without trailing newline
    if start < data.len() {
        let line = unsafe { std::slice::from_raw_parts(base.add(start), data.len() - start) };
        match memchr::memchr(delim, line) {
            Some(dp) => {
                // Field + trailing newline
                unsafe {
                    std::ptr::copy_nonoverlapping(base.add(start), out_ptr, dp);
                    out_ptr = out_ptr.add(dp);
                    *out_ptr = line_delim;
                    out_ptr = out_ptr.add(1);
                }
            }
            None => {
                // No delimiter — output remaining data + newline (GNU compat)
                let len = data.len() - start;
                unsafe {
                    std::ptr::copy_nonoverlapping(base.add(start), out_ptr, len);
                    out_ptr = out_ptr.add(len);
                    *out_ptr = line_delim;
                    out_ptr = out_ptr.add(1);
                }
            }
        }
    }

    unsafe {
        let new_len = out_ptr as usize - buf.as_ptr() as usize;
        debug_assert!(new_len >= initial_len && new_len <= buf.capacity());
        buf.set_len(new_len);
    }
}

/// Zero-copy field 1 extraction using writev: builds IoSlice entries pointing
/// directly into the source data. Uses two-level scan: outer memchr(newline)
/// for the first delimiter. This is faster than memchr2 for SMALL data because
/// the inner scan exits after the FIRST delimiter, skipping all
/// subsequent delimiters on the line.
///
/// Lines without delimiter stay in contiguous runs (zero-copy pass-through).
/// Lines with delimiter produce two IoSlices (truncated field + newline byte).
#[inline]
#[allow(dead_code)]
fn single_field1_zerocopy(
    data: &[u8],
    delim: u8,
    line_delim: u8,
    out: &mut impl Write,
) -> io::Result<()> {
    let newline_buf: [u8; 1] = [line_delim];

    let mut iov: Vec<IoSlice> = Vec::with_capacity(MAX_IOV);
    let mut run_start: usize = 0;
    let mut start = 0;

    for end_pos in memchr_iter(line_delim, data) {
        let line = &data[start..end_pos];
        if let Some(dp) = memchr::memchr(delim, line) {
            // Line has delimiter — truncate at first delimiter.
            // Flush current contiguous run, then add truncated field + newline.
            if run_start < start {
                iov.push(IoSlice::new(&data[run_start..start]));
            }
            iov.push(IoSlice::new(&data[start..start + dp]));
            iov.push(IoSlice::new(&newline_buf));
            run_start = end_pos + 1;

            if iov.len() >= MAX_IOV - 2 {
                write_ioslices(out, &iov)?;
                iov.clear();
            }
        }
        // else: no delimiter in line, output unchanged (stays in contiguous run)
        start = end_pos + 1;
    }

    // Handle last line (no trailing newline)
    if start < data.len() {
        let line = &data[start..];
        if let Some(dp) = memchr::memchr(delim, line) {
            if run_start < start {
                iov.push(IoSlice::new(&data[run_start..start]));
            }
            iov.push(IoSlice::new(&data[start..start + dp]));
            iov.push(IoSlice::new(&newline_buf));
            if !iov.is_empty() {
                write_ioslices(out, &iov)?;
            }
            return Ok(());
        }
    }

    // Flush remaining contiguous run
    if run_start < data.len() {
        iov.push(IoSlice::new(&data[run_start..]));
        if !data.is_empty() && *data.last().unwrap() != line_delim {
            iov.push(IoSlice::new(&newline_buf));
        }
    }
    if !iov.is_empty() {
        write_ioslices(out, &iov)?;
    }
    Ok(())
}

/// Process a chunk of data for single-field extraction using write-pointer pattern.
/// Two-level scan: outer memchr(newline), inner memchr_iter(delim) with early exit.
/// Uses contiguous run tracking for lines that pass through unchanged.
fn process_single_field_chunk(
    data: &[u8],
    delim: u8,
    target_idx: usize,
    line_delim: u8,
    suppress: bool,
    buf: &mut Vec<u8>,
) {
    // Pre-reserve chunk capacity to eliminate per-line reserve overhead.
    buf.reserve(data.len() + 1);

    let base = data.as_ptr();
    let initial_len = buf.len();
    let mut out_ptr = unsafe { buf.as_mut_ptr().add(initial_len) };
    let mut start = 0;
    // Track contiguous runs of lines that output unchanged
    let mut run_start: usize = 0;
    let mut in_run = !suppress; // if suppress, no line passes through without delimiter

    for end_pos in memchr_iter(line_delim, data) {
        let line = unsafe { std::slice::from_raw_parts(base.add(start), end_pos - start) };
        let line_len = end_pos - start;

        if line_len == 0 {
            if !suppress {
                // Empty line passes through in the run
                if !in_run {
                    run_start = start;
                    in_run = true;
                }
            }
            start = end_pos + 1;
            continue;
        }

        // Count delimiters up to target_idx to find the target field
        let mut field_start_offset = 0;
        let mut field_idx = 0;
        let mut found = false;
        let mut has_delim = false;

        for pos in memchr_iter(delim, line) {
            has_delim = true;
            if field_idx == target_idx {
                // Found the target field: line[field_start_offset..pos]
                // Flush run, output field + newline
                if in_run && run_start < start {
                    let run_len = start - run_start;
                    unsafe {
                        std::ptr::copy_nonoverlapping(base.add(run_start), out_ptr, run_len);
                        out_ptr = out_ptr.add(run_len);
                    }
                }
                let field_len = pos - field_start_offset;
                unsafe {
                    std::ptr::copy_nonoverlapping(
                        base.add(start + field_start_offset),
                        out_ptr,
                        field_len,
                    );
                    out_ptr = out_ptr.add(field_len);
                    *out_ptr = line_delim;
                    out_ptr = out_ptr.add(1);
                }
                run_start = end_pos + 1;
                in_run = true;
                found = true;
                break;
            }
            field_idx += 1;
            field_start_offset = pos + 1;
        }

        if !found {
            if !has_delim {
                // No delimiter in line
                if !suppress {
                    // Line passes through unchanged — stays in run
                    if !in_run {
                        run_start = start;
                        in_run = true;
                    }
                } else {
                    // Suppress: flush run, skip this line
                    if in_run && run_start < start {
                        let run_len = start - run_start;
                        unsafe {
                            std::ptr::copy_nonoverlapping(base.add(run_start), out_ptr, run_len);
                            out_ptr = out_ptr.add(run_len);
                        }
                    }
                    in_run = false;
                    run_start = end_pos + 1;
                }
            } else if field_idx == target_idx {
                // Last field is the target: line[field_start_offset..]
                if in_run && run_start < start {
                    let run_len = start - run_start;
                    unsafe {
                        std::ptr::copy_nonoverlapping(base.add(run_start), out_ptr, run_len);
                        out_ptr = out_ptr.add(run_len);
                    }
                }
                let field_len = line_len - field_start_offset;
                unsafe {
                    std::ptr::copy_nonoverlapping(
                        base.add(start + field_start_offset),
                        out_ptr,
                        field_len,
                    );
                    out_ptr = out_ptr.add(field_len);
                    *out_ptr = line_delim;
                    out_ptr = out_ptr.add(1);
                }
                run_start = end_pos + 1;
                in_run = true;
            } else {
                // Not enough fields for target — output empty line
                if in_run && run_start < start {
                    let run_len = start - run_start;
                    unsafe {
                        std::ptr::copy_nonoverlapping(base.add(run_start), out_ptr, run_len);
                        out_ptr = out_ptr.add(run_len);
                    }
                }
                unsafe {
                    *out_ptr = line_delim;
                    out_ptr = out_ptr.add(1);
                }
                run_start = end_pos + 1;
                in_run = true;
            }
        }

        start = end_pos + 1;
    }

    // Flush remaining contiguous run
    if in_run && run_start < start {
        let run_len = start - run_start;
        unsafe {
            std::ptr::copy_nonoverlapping(base.add(run_start), out_ptr, run_len);
            out_ptr = out_ptr.add(run_len);
        }
    }

    // Handle last line without trailing newline
    if start < data.len() {
        let line = unsafe { std::slice::from_raw_parts(base.add(start), data.len() - start) };
        let line_len = data.len() - start;

        if line_len == 0 {
            if !suppress {
                unsafe {
                    *out_ptr = line_delim;
                    out_ptr = out_ptr.add(1);
                }
            }
        } else {
            let mut field_start_offset = 0;
            let mut field_idx = 0;
            let mut found = false;
            let mut has_delim = false;

            for pos in memchr_iter(delim, line) {
                has_delim = true;
                if field_idx == target_idx {
                    let field_len = pos - field_start_offset;
                    unsafe {
                        std::ptr::copy_nonoverlapping(
                            base.add(start + field_start_offset),
                            out_ptr,
                            field_len,
                        );
                        out_ptr = out_ptr.add(field_len);
                        *out_ptr = line_delim;
                        out_ptr = out_ptr.add(1);
                    }
                    found = true;
                    break;
                }
                field_idx += 1;
                field_start_offset = pos + 1;
            }

            if !found {
                if !has_delim {
                    if !suppress {
                        unsafe {
                            std::ptr::copy_nonoverlapping(base.add(start), out_ptr, line_len);
                            out_ptr = out_ptr.add(line_len);
                            *out_ptr = line_delim;
                            out_ptr = out_ptr.add(1);
                        }
                    }
                } else if field_idx == target_idx {
                    let field_len = line_len - field_start_offset;
                    unsafe {
                        std::ptr::copy_nonoverlapping(
                            base.add(start + field_start_offset),
                            out_ptr,
                            field_len,
                        );
                        out_ptr = out_ptr.add(field_len);
                        *out_ptr = line_delim;
                        out_ptr = out_ptr.add(1);
                    }
                } else {
                    unsafe {
                        *out_ptr = line_delim;
                        out_ptr = out_ptr.add(1);
                    }
                }
            }
        }
    }

    unsafe {
        let new_len = out_ptr as usize - buf.as_ptr() as usize;
        debug_assert!(new_len >= initial_len && new_len <= buf.capacity());
        buf.set_len(new_len);
    }
}

/// Extract fields from a single line into the output buffer.
/// Uses unsafe buf helpers with pre-reserved capacity for zero bounds-check overhead.
/// Raw pointer arithmetic eliminates per-field bounds checking.
#[inline(always)]
fn extract_fields_to_buf(
    line: &[u8],
    delim: u8,
    ranges: &[Range],
    output_delim: &[u8],
    suppress: bool,
    max_field: usize,
    field_mask: u64,
    line_delim: u8,
    buf: &mut Vec<u8>,
    complement: bool,
) {
    let len = line.len();

    if len == 0 {
        if !suppress {
            buf.push(line_delim);
        }
        return;
    }

    // Only reserve if remaining capacity is insufficient. The caller pre-sizes the
    // buffer to data.len(), so this check avoids redundant reserve() calls per line.
    let needed = len + output_delim.len() * 16 + 1;
    if buf.capacity() - buf.len() < needed {
        buf.reserve(needed);
    }

    let base = line.as_ptr();
    let mut field_num: usize = 1;
    let mut field_start: usize = 0;
    let mut first_output = true;
    let mut has_delim = false;

    // Use memchr SIMD for all line sizes
    for delim_pos in memchr_iter(delim, line) {
        has_delim = true;

        if is_selected(field_num, field_mask, ranges, complement) {
            if !first_output {
                unsafe { buf_extend(buf, output_delim) };
            }
            unsafe {
                buf_extend(
                    buf,
                    std::slice::from_raw_parts(base.add(field_start), delim_pos - field_start),
                )
            };
            first_output = false;
        }

        field_num += 1;
        field_start = delim_pos + 1;

        if field_num > max_field {
            break;
        }
    }

    // Last field
    if (field_num <= max_field || complement)
        && has_delim
        && is_selected(field_num, field_mask, ranges, complement)
    {
        if !first_output {
            unsafe { buf_extend(buf, output_delim) };
        }
        unsafe {
            buf_extend(
                buf,
                std::slice::from_raw_parts(base.add(field_start), len - field_start),
            )
        };
        first_output = false;
    }

    if !first_output {
        unsafe { buf_push(buf, line_delim) };
    } else if !has_delim {
        if !suppress {
            unsafe {
                buf_extend(buf, line);
                buf_push(buf, line_delim);
            }
        }
    } else {
        unsafe { buf_push(buf, line_delim) };
    }
}

// ── Fast path: byte/char extraction with batched output ──────────────────

/// Ultra-fast path for `cut -b1-N`: single from-start byte range.
/// Zero-copy: writes directly from the source data using output runs.
/// For lines shorter than max_bytes, the output is identical to the input,
/// so we emit contiguous runs directly. Only lines exceeding max_bytes need truncation.
fn process_bytes_from_start(
    data: &[u8],
    max_bytes: usize,
    line_delim: u8,
    out: &mut impl Write,
) -> io::Result<()> {
    // For small data (< PARALLEL_THRESHOLD): check if all lines fit for zero-copy passthrough.
    // The sequential scan + write_all is competitive with per-line processing for small data.
    //
    // For large data (>= PARALLEL_THRESHOLD): skip the all_fit scan entirely.
    // The scan is sequential (~1.7ms for 10MB at memchr speed) while parallel per-line
    // processing is much faster (~0.5ms for 10MB with 4 threads). Even when all lines fit,
    // the parallel copy + write is faster than sequential scan + zero-copy write.
    if data.len() < PARALLEL_THRESHOLD && max_bytes > 0 && max_bytes < usize::MAX {
        let mut start = 0;
        let mut all_fit = true;
        for pos in memchr_iter(line_delim, data) {
            if pos - start > max_bytes {
                all_fit = false;
                break;
            }
            start = pos + 1;
        }
        // Check last line (no trailing delimiter)
        if all_fit && start < data.len() && data.len() - start > max_bytes {
            all_fit = false;
        }
        if all_fit {
            // All lines fit: output = input. Handle missing trailing delimiter.
            if !data.is_empty() && data[data.len() - 1] == line_delim {
                return out.write_all(data);
            } else if !data.is_empty() {
                out.write_all(data)?;
                return out.write_all(&[line_delim]);
            }
            return Ok(());
        }
    }

    if data.len() >= PARALLEL_THRESHOLD {
        let chunks = split_for_scope(data, line_delim);
        let n = chunks.len();
        let mut results: Vec<Vec<u8>> = (0..n).map(|_| Vec::new()).collect();
        rayon::scope(|s| {
            for (chunk, result) in chunks.iter().zip(results.iter_mut()) {
                s.spawn(move |_| {
                    // Output can be up to input size (when all lines fit).
                    // Reserve full chunk size to avoid reallocation.
                    result.reserve(chunk.len());
                    bytes_from_start_chunk(chunk, max_bytes, line_delim, result);
                });
            }
        });
        // Use write_vectored (writev) to batch N writes into fewer syscalls
        let slices: Vec<IoSlice> = results
            .iter()
            .filter(|r| !r.is_empty())
            .map(|r| IoSlice::new(r))
            .collect();
        write_ioslices(out, &slices)?;
    } else {
        // For moderate max_bytes, the buffer path is faster than writev zero-copy
        // because every line gets truncated, creating 3 IoSlice entries per line.
        // Copying max_bytes+1 bytes into a contiguous buffer is cheaper than
        // managing millions of IoSlice entries through the kernel.
        // Threshold at 512 covers common byte-range benchmarks like -b1-100.
        if max_bytes <= 512 {
            // Estimate output size without scanning: output <= data.len(),
            // typically ~data.len()/4 for short max_bytes on longer lines.
            let est_out = (data.len() / 4).max(max_bytes + 2);
            let mut buf = Vec::with_capacity(est_out.min(data.len()));
            bytes_from_start_chunk(data, max_bytes, line_delim, &mut buf);
            if !buf.is_empty() {
                out.write_all(&buf)?;
            }
        } else {
            // Zero-copy path: track contiguous output runs and write directly from source.
            // For lines <= max_bytes, we include them as-is (no copy needed).
            // For lines > max_bytes, we flush the run, write the truncated line, start new run.
            bytes_from_start_zerocopy(data, max_bytes, line_delim, out)?;
        }
    }
    Ok(())
}

/// Zero-copy byte-prefix extraction using writev: builds IoSlice entries pointing
/// directly into the source data, flushing in MAX_IOV-sized batches.
/// Lines shorter than max_bytes stay in contiguous runs. Lines needing truncation
/// produce two IoSlices (truncated data + newline).
#[inline]
fn bytes_from_start_zerocopy(
    data: &[u8],
    max_bytes: usize,
    line_delim: u8,
    out: &mut impl Write,
) -> io::Result<()> {
    let newline_buf: [u8; 1] = [line_delim];
    let mut iov: Vec<IoSlice> = Vec::with_capacity(MAX_IOV);
    let mut start = 0;
    let mut run_start: usize = 0;

    for pos in memchr_iter(line_delim, data) {
        let line_len = pos - start;
        if line_len > max_bytes {
            // This line needs truncation
            if run_start < start {
                iov.push(IoSlice::new(&data[run_start..start]));
            }
            iov.push(IoSlice::new(&data[start..start + max_bytes]));
            iov.push(IoSlice::new(&newline_buf));
            run_start = pos + 1;

            if iov.len() >= MAX_IOV - 2 {
                write_ioslices(out, &iov)?;
                iov.clear();
            }
        }
        start = pos + 1;
    }
    // Handle last line without terminator
    if start < data.len() {
        let line_len = data.len() - start;
        if line_len > max_bytes {
            if run_start < start {
                iov.push(IoSlice::new(&data[run_start..start]));
            }
            iov.push(IoSlice::new(&data[start..start + max_bytes]));
            iov.push(IoSlice::new(&newline_buf));
            if !iov.is_empty() {
                write_ioslices(out, &iov)?;
            }
            return Ok(());
        }
    }
    // Flush remaining contiguous run
    if run_start < data.len() {
        iov.push(IoSlice::new(&data[run_start..]));
        if !data.is_empty() && *data.last().unwrap() != line_delim {
            iov.push(IoSlice::new(&newline_buf));
        }
    }
    if !iov.is_empty() {
        write_ioslices(out, &iov)?;
    }
    Ok(())
}

/// Process a chunk for from-start byte range extraction (parallel path).
/// Uses unsafe appends to eliminate bounds checking in the hot loop.
/// Pre-reserves data.len() (output never exceeds input), then uses a single
/// write pointer with deferred set_len — no per-line capacity checks.
#[inline]
fn bytes_from_start_chunk(data: &[u8], max_bytes: usize, line_delim: u8, buf: &mut Vec<u8>) {
    // Output is always <= input size (we only truncate, never expand).
    // Single reserve eliminates ALL per-line capacity checks.
    buf.reserve(data.len());

    let src = data.as_ptr();
    let dst_base = buf.as_mut_ptr();
    let mut wp = buf.len();
    let mut start = 0;

    for pos in memchr_iter(line_delim, data) {
        let line_len = pos - start;
        let take = line_len.min(max_bytes);
        unsafe {
            std::ptr::copy_nonoverlapping(src.add(start), dst_base.add(wp), take);
            *dst_base.add(wp + take) = line_delim;
        }
        wp += take + 1;
        start = pos + 1;
    }
    // Handle last line without terminator
    if start < data.len() {
        let line_len = data.len() - start;
        let take = line_len.min(max_bytes);
        unsafe {
            std::ptr::copy_nonoverlapping(src.add(start), dst_base.add(wp), take);
            *dst_base.add(wp + take) = line_delim;
        }
        wp += take + 1;
    }
    unsafe { buf.set_len(wp) };
}

/// Fast path for `cut -bN-`: skip first N-1 bytes per line.
fn process_bytes_from_offset(
    data: &[u8],
    skip_bytes: usize,
    line_delim: u8,
    out: &mut impl Write,
) -> io::Result<()> {
    if data.len() >= PARALLEL_THRESHOLD {
        let chunks = split_for_scope(data, line_delim);
        let n = chunks.len();
        let mut results: Vec<Vec<u8>> = (0..n).map(|_| Vec::new()).collect();
        rayon::scope(|s| {
            for (chunk, result) in chunks.iter().zip(results.iter_mut()) {
                s.spawn(move |_| {
                    result.reserve(chunk.len());
                    bytes_from_offset_chunk(chunk, skip_bytes, line_delim, result);
                });
            }
        });
        // Use write_vectored (writev) to batch N writes into fewer syscalls
        let slices: Vec<IoSlice> = results
            .iter()
            .filter(|r| !r.is_empty())
            .map(|r| IoSlice::new(r))
            .collect();
        write_ioslices(out, &slices)?;
    } else {
        // Zero-copy: write suffix of each line directly from source
        bytes_from_offset_zerocopy(data, skip_bytes, line_delim, out)?;
    }
    Ok(())
}

/// Zero-copy byte-offset extraction: writes suffix of each line directly from source data.
/// Collects IoSlice pairs (data + delimiter) and flushes with write_vectored in batches,
/// reducing syscall overhead from 2 write_all calls per line to batched writev.
#[inline]
fn bytes_from_offset_zerocopy(
    data: &[u8],
    skip_bytes: usize,
    line_delim: u8,
    out: &mut impl Write,
) -> io::Result<()> {
    let delim_buf = [line_delim];
    let mut iov: Vec<IoSlice> = Vec::with_capacity(256);

    let mut start = 0;
    for pos in memchr_iter(line_delim, data) {
        let line_len = pos - start;
        if line_len > skip_bytes {
            iov.push(IoSlice::new(&data[start + skip_bytes..pos]));
        }
        iov.push(IoSlice::new(&delim_buf));
        // Flush when approaching MAX_IOV to avoid oversized writev
        if iov.len() >= MAX_IOV - 1 {
            write_ioslices(out, &iov)?;
            iov.clear();
        }
        start = pos + 1;
    }
    if start < data.len() {
        let line_len = data.len() - start;
        if line_len > skip_bytes {
            iov.push(IoSlice::new(&data[start + skip_bytes..data.len()]));
        }
        iov.push(IoSlice::new(&delim_buf));
    }
    if !iov.is_empty() {
        write_ioslices(out, &iov)?;
    }
    Ok(())
}

/// Process a chunk for from-offset byte range extraction.
/// Single reserve + deferred set_len for zero per-line overhead.
#[inline]
fn bytes_from_offset_chunk(data: &[u8], skip_bytes: usize, line_delim: u8, buf: &mut Vec<u8>) {
    buf.reserve(data.len());

    let src = data.as_ptr();
    let dst_base = buf.as_mut_ptr();
    let mut wp = buf.len();
    let mut start = 0;

    for pos in memchr_iter(line_delim, data) {
        let line_len = pos - start;
        if line_len > skip_bytes {
            let take = line_len - skip_bytes;
            unsafe {
                std::ptr::copy_nonoverlapping(src.add(start + skip_bytes), dst_base.add(wp), take);
            }
            wp += take;
        }
        unsafe {
            *dst_base.add(wp) = line_delim;
        }
        wp += 1;
        start = pos + 1;
    }
    if start < data.len() {
        let line_len = data.len() - start;
        if line_len > skip_bytes {
            let take = line_len - skip_bytes;
            unsafe {
                std::ptr::copy_nonoverlapping(src.add(start + skip_bytes), dst_base.add(wp), take);
            }
            wp += take;
        }
        unsafe {
            *dst_base.add(wp) = line_delim;
        }
        wp += 1;
    }
    unsafe { buf.set_len(wp) };
}

/// Fast path for `cut -bN-M` where N > 1 and M < MAX: extract bytes N through M per line.
fn process_bytes_mid_range(
    data: &[u8],
    start_byte: usize,
    end_byte: usize,
    line_delim: u8,
    out: &mut impl Write,
) -> io::Result<()> {
    let skip = start_byte.saturating_sub(1);

    if data.len() >= PARALLEL_THRESHOLD {
        let chunks = split_for_scope(data, line_delim);
        let n = chunks.len();
        let mut results: Vec<Vec<u8>> = (0..n).map(|_| Vec::new()).collect();
        rayon::scope(|s| {
            for (chunk, result) in chunks.iter().zip(results.iter_mut()) {
                s.spawn(move |_| {
                    result.reserve(chunk.len());
                    bytes_mid_range_chunk(chunk, skip, end_byte, line_delim, result);
                });
            }
        });
        let slices: Vec<IoSlice> = results
            .iter()
            .filter(|r| !r.is_empty())
            .map(|r| IoSlice::new(r))
            .collect();
        write_ioslices(out, &slices)?;
    } else {
        let mut buf = Vec::with_capacity(data.len());
        bytes_mid_range_chunk(data, skip, end_byte, line_delim, &mut buf);
        if !buf.is_empty() {
            out.write_all(&buf)?;
        }
    }
    Ok(())
}

/// Process a chunk for mid-range byte extraction.
/// For each line, output bytes skip..min(line_len, end_byte).
/// Single reserve + deferred set_len.
#[inline]
fn bytes_mid_range_chunk(
    data: &[u8],
    skip: usize,
    end_byte: usize,
    line_delim: u8,
    buf: &mut Vec<u8>,
) {
    buf.reserve(data.len());

    let src = data.as_ptr();
    let dst_base = buf.as_mut_ptr();
    let mut wp = buf.len();
    let mut start = 0;

    for pos in memchr_iter(line_delim, data) {
        let line_len = pos - start;
        if line_len > skip {
            let take_end = line_len.min(end_byte);
            let take = take_end - skip;
            unsafe {
                std::ptr::copy_nonoverlapping(src.add(start + skip), dst_base.add(wp), take);
            }
            wp += take;
        }
        unsafe {
            *dst_base.add(wp) = line_delim;
        }
        wp += 1;
        start = pos + 1;
    }
    if start < data.len() {
        let line_len = data.len() - start;
        if line_len > skip {
            let take_end = line_len.min(end_byte);
            let take = take_end - skip;
            unsafe {
                std::ptr::copy_nonoverlapping(src.add(start + skip), dst_base.add(wp), take);
            }
            wp += take;
        }
        unsafe {
            *dst_base.add(wp) = line_delim;
        }
        wp += 1;
    }
    unsafe { buf.set_len(wp) };
}

/// Fast path for `--complement -bN-M`: output bytes 1..N-1 and M+1..end per line.
fn process_bytes_complement_mid(
    data: &[u8],
    skip_start: usize,
    skip_end: usize,
    line_delim: u8,
    out: &mut impl Write,
) -> io::Result<()> {
    let prefix_bytes = skip_start - 1; // bytes before the skip region
    if data.len() >= PARALLEL_THRESHOLD {
        let chunks = split_for_scope(data, line_delim);
        let n = chunks.len();
        let mut results: Vec<Vec<u8>> = (0..n).map(|_| Vec::new()).collect();
        rayon::scope(|s| {
            for (chunk, result) in chunks.iter().zip(results.iter_mut()) {
                s.spawn(move |_| {
                    result.reserve(chunk.len());
                    bytes_complement_mid_chunk(chunk, prefix_bytes, skip_end, line_delim, result);
                });
            }
        });
        let slices: Vec<IoSlice> = results
            .iter()
            .filter(|r| !r.is_empty())
            .map(|r| IoSlice::new(r))
            .collect();
        write_ioslices(out, &slices)?;
    } else {
        let mut buf = Vec::with_capacity(data.len());
        bytes_complement_mid_chunk(data, prefix_bytes, skip_end, line_delim, &mut buf);
        if !buf.is_empty() {
            out.write_all(&buf)?;
        }
    }
    Ok(())
}

/// Process a chunk for complement mid-range byte extraction.
/// For each line: output bytes 0..prefix_bytes, then bytes skip_end..line_len.
#[inline]
fn bytes_complement_mid_chunk(
    data: &[u8],
    prefix_bytes: usize,
    skip_end: usize,
    line_delim: u8,
    buf: &mut Vec<u8>,
) {
    buf.reserve(data.len());

    let src = data.as_ptr();
    let dst_base = buf.as_mut_ptr();
    let mut wp = buf.len();
    let mut start = 0;

    for pos in memchr_iter(line_delim, data) {
        let line_len = pos - start;
        // Copy prefix (bytes before skip region)
        let take_prefix = prefix_bytes.min(line_len);
        if take_prefix > 0 {
            unsafe {
                std::ptr::copy_nonoverlapping(src.add(start), dst_base.add(wp), take_prefix);
            }
            wp += take_prefix;
        }
        // Copy suffix (bytes after skip region)
        if line_len > skip_end {
            let suffix_len = line_len - skip_end;
            unsafe {
                std::ptr::copy_nonoverlapping(
                    src.add(start + skip_end),
                    dst_base.add(wp),
                    suffix_len,
                );
            }
            wp += suffix_len;
        }
        unsafe {
            *dst_base.add(wp) = line_delim;
        }
        wp += 1;
        start = pos + 1;
    }
    if start < data.len() {
        let line_len = data.len() - start;
        let take_prefix = prefix_bytes.min(line_len);
        if take_prefix > 0 {
            unsafe {
                std::ptr::copy_nonoverlapping(src.add(start), dst_base.add(wp), take_prefix);
            }
            wp += take_prefix;
        }
        if line_len > skip_end {
            let suffix_len = line_len - skip_end;
            unsafe {
                std::ptr::copy_nonoverlapping(
                    src.add(start + skip_end),
                    dst_base.add(wp),
                    suffix_len,
                );
            }
            wp += suffix_len;
        }
        unsafe {
            *dst_base.add(wp) = line_delim;
        }
        wp += 1;
    }
    unsafe { buf.set_len(wp) };
}

/// Optimized byte/char extraction with batched output and parallel processing.
fn process_bytes_fast(data: &[u8], cfg: &CutConfig, out: &mut impl Write) -> io::Result<()> {
    let line_delim = cfg.line_delim;
    let ranges = cfg.ranges;
    let complement = cfg.complement;
    let output_delim = cfg.output_delim;

    // Ultra-fast path: single range from byte 1 (e.g., cut -b1-10, cut -b-20)
    if !complement && ranges.len() == 1 && ranges[0].start == 1 && output_delim.is_empty() {
        let max_bytes = ranges[0].end;
        if max_bytes < usize::MAX {
            return process_bytes_from_start(data, max_bytes, line_delim, out);
        }
    }

    // Fast path: single open-ended range from byte N (e.g., cut -b5-)
    if !complement && ranges.len() == 1 && ranges[0].end == usize::MAX && output_delim.is_empty() {
        let skip_bytes = ranges[0].start.saturating_sub(1);
        if skip_bytes > 0 {
            return process_bytes_from_offset(data, skip_bytes, line_delim, out);
        }
    }

    // Fast path: single mid-range (e.g., cut -b5-100)
    if !complement
        && ranges.len() == 1
        && ranges[0].start > 1
        && ranges[0].end < usize::MAX
        && output_delim.is_empty()
    {
        return process_bytes_mid_range(data, ranges[0].start, ranges[0].end, line_delim, out);
    }

    // Fast path: complement of single from-start range (e.g., --complement -b1-100 = output bytes 101+)
    if complement
        && ranges.len() == 1
        && ranges[0].start == 1
        && ranges[0].end < usize::MAX
        && output_delim.is_empty()
    {
        return process_bytes_from_offset(data, ranges[0].end, line_delim, out);
    }

    // Fast path: complement of single from-offset range (e.g., --complement -b5- = output bytes 1-4)
    if complement
        && ranges.len() == 1
        && ranges[0].end == usize::MAX
        && ranges[0].start > 1
        && output_delim.is_empty()
    {
        let max_bytes = ranges[0].start - 1;
        return process_bytes_from_start(data, max_bytes, line_delim, out);
    }

    // Fast path: complement of single mid-range (e.g., --complement -b5-100 = bytes 1-4,101+)
    if complement
        && ranges.len() == 1
        && ranges[0].start > 1
        && ranges[0].end < usize::MAX
        && output_delim.is_empty()
    {
        return process_bytes_complement_mid(data, ranges[0].start, ranges[0].end, line_delim, out);
    }

    if data.len() >= PARALLEL_THRESHOLD {
        let chunks = split_for_scope(data, line_delim);
        let n = chunks.len();
        let mut results: Vec<Vec<u8>> = (0..n).map(|_| Vec::new()).collect();
        rayon::scope(|s| {
            for (chunk, result) in chunks.iter().zip(results.iter_mut()) {
                s.spawn(move |_| {
                    result.reserve(chunk.len() + 1);
                    process_bytes_chunk(
                        chunk,
                        ranges,
                        complement,
                        output_delim,
                        line_delim,
                        result,
                    );
                });
            }
        });
        let slices: Vec<IoSlice> = results
            .iter()
            .filter(|r| !r.is_empty())
            .map(|r| IoSlice::new(r))
            .collect();
        write_ioslices(out, &slices)?;
    } else {
        // +1 for potential trailing line_delim when input doesn't end with one
        let mut buf = Vec::with_capacity(data.len() + 1);
        process_bytes_chunk(data, ranges, complement, output_delim, line_delim, &mut buf);
        if !buf.is_empty() {
            out.write_all(&buf)?;
        }
    }
    Ok(())
}

/// Process a chunk of data for byte/char extraction.
/// Uses raw pointer arithmetic for the newline scan.
/// Complement single-range fast path: compute complement ranges once, then use
/// the non-complement multi-range path which is more cache-friendly.
fn process_bytes_chunk(
    data: &[u8],
    ranges: &[Range],
    complement: bool,
    output_delim: &[u8],
    line_delim: u8,
    buf: &mut Vec<u8>,
) {
    buf.reserve(data.len());
    let base = data.as_ptr();
    let mut start = 0;
    for end_pos in memchr_iter(line_delim, data) {
        let line = unsafe { std::slice::from_raw_parts(base.add(start), end_pos - start) };
        cut_bytes_to_buf(line, ranges, complement, output_delim, buf);
        unsafe { buf_push(buf, line_delim) };
        start = end_pos + 1;
    }
    if start < data.len() {
        let line = unsafe { std::slice::from_raw_parts(base.add(start), data.len() - start) };
        cut_bytes_to_buf(line, ranges, complement, output_delim, buf);
        unsafe { buf_push(buf, line_delim) };
    }
}

/// Extract byte ranges from a line into the output buffer.
/// Uses unsafe buf helpers for zero bounds-check overhead in hot loops.
/// Raw pointer arithmetic eliminates per-range bounds checking.
#[inline(always)]
fn cut_bytes_to_buf(
    line: &[u8],
    ranges: &[Range],
    complement: bool,
    output_delim: &[u8],
    buf: &mut Vec<u8>,
) {
    let len = line.len();
    let base = line.as_ptr();
    let mut first_range = true;

    // Reserve worst case: full line + delimiters between ranges
    let needed = len + output_delim.len() * ranges.len() + 1;
    if buf.capacity() - buf.len() < needed {
        buf.reserve(needed);
    }

    if complement {
        let mut pos: usize = 1;
        for r in ranges {
            let rs = r.start;
            let re = r.end.min(len);
            if pos < rs {
                if !first_range && !output_delim.is_empty() {
                    unsafe { buf_extend(buf, output_delim) };
                }
                unsafe { buf_extend(buf, std::slice::from_raw_parts(base.add(pos - 1), rs - pos)) };
                first_range = false;
            }
            pos = re + 1;
            if pos > len {
                break;
            }
        }
        if pos <= len {
            if !first_range && !output_delim.is_empty() {
                unsafe { buf_extend(buf, output_delim) };
            }
            unsafe {
                buf_extend(
                    buf,
                    std::slice::from_raw_parts(base.add(pos - 1), len - pos + 1),
                )
            };
        }
    } else if output_delim.is_empty() && ranges.len() == 1 {
        // Ultra-fast path: single range, no output delimiter
        let start = ranges[0].start.saturating_sub(1);
        let end = ranges[0].end.min(len);
        if start < len {
            unsafe {
                buf_extend(
                    buf,
                    std::slice::from_raw_parts(base.add(start), end - start),
                )
            };
        }
    } else {
        for r in ranges {
            let start = r.start.saturating_sub(1);
            let end = r.end.min(len);
            if start >= len {
                break;
            }
            if !first_range && !output_delim.is_empty() {
                unsafe { buf_extend(buf, output_delim) };
            }
            unsafe {
                buf_extend(
                    buf,
                    std::slice::from_raw_parts(base.add(start), end - start),
                )
            };
            first_range = false;
        }
    }
}

// ── Public API ───────────────────────────────────────────────────────────

/// Cut fields from a line using a delimiter. Writes to `out`.
#[inline]
pub fn cut_fields(
    line: &[u8],
    delim: u8,
    ranges: &[Range],
    complement: bool,
    output_delim: &[u8],
    suppress_no_delim: bool,
    out: &mut impl Write,
) -> io::Result<bool> {
    if memchr::memchr(delim, line).is_none() {
        if !suppress_no_delim {
            out.write_all(line)?;
            return Ok(true);
        }
        return Ok(false);
    }

    let mut field_num: usize = 1;
    let mut field_start: usize = 0;
    let mut first_output = true;

    for delim_pos in memchr_iter(delim, line) {
        let selected = in_ranges(ranges, field_num) != complement;
        if selected {
            if !first_output {
                out.write_all(output_delim)?;
            }
            out.write_all(&line[field_start..delim_pos])?;
            first_output = false;
        }
        field_start = delim_pos + 1;
        field_num += 1;
    }

    let selected = in_ranges(ranges, field_num) != complement;
    if selected {
        if !first_output {
            out.write_all(output_delim)?;
        }
        out.write_all(&line[field_start..])?;
    }

    Ok(true)
}

/// Cut bytes/chars from a line. Writes selected bytes to `out`.
#[inline]
pub fn cut_bytes(
    line: &[u8],
    ranges: &[Range],
    complement: bool,
    output_delim: &[u8],
    out: &mut impl Write,
) -> io::Result<bool> {
    let mut first_range = true;

    if complement {
        let len = line.len();
        let mut comp_ranges = Vec::new();
        let mut pos: usize = 1;
        for r in ranges {
            let rs = r.start;
            let re = r.end.min(len);
            if pos < rs {
                comp_ranges.push((pos, rs - 1));
            }
            pos = re + 1;
            if pos > len {
                break;
            }
        }
        if pos <= len {
            comp_ranges.push((pos, len));
        }
        for &(s, e) in &comp_ranges {
            if !first_range && !output_delim.is_empty() {
                out.write_all(output_delim)?;
            }
            out.write_all(&line[s - 1..e])?;
            first_range = false;
        }
    } else {
        for r in ranges {
            let start = r.start.saturating_sub(1);
            let end = r.end.min(line.len());
            if start >= line.len() {
                break;
            }
            if !first_range && !output_delim.is_empty() {
                out.write_all(output_delim)?;
            }
            out.write_all(&line[start..end])?;
            first_range = false;
        }
    }
    Ok(true)
}

/// In-place field 1 extraction: modifies `data` buffer directly, returns new length.
/// Output is always <= input (we remove everything after first delimiter per line).
/// Avoids intermediate Vec allocation + BufWriter copy, saving ~10MB of memory
/// bandwidth for 10MB input. Requires owned mutable data (not mmap).
///
/// Lines without delimiter pass through unchanged (unless suppress=true).
/// Lines with delimiter: keep bytes before delimiter + newline.
pub fn cut_field1_inplace(data: &mut [u8], delim: u8, line_delim: u8, suppress: bool) -> usize {
    let len = data.len();
    let mut wp: usize = 0;
    let mut rp: usize = 0;

    while rp < len {
        match memchr::memchr2(delim, line_delim, &data[rp..]) {
            None => {
                // Rest is partial line, no delimiter
                if suppress {
                    // suppress: skip lines without delimiter
                    break;
                }
                let remaining = len - rp;
                if wp != rp {
                    data.copy_within(rp..len, wp);
                }
                wp += remaining;
                break;
            }
            Some(offset) => {
                let actual = rp + offset;
                if data[actual] == line_delim {
                    // No delimiter on this line
                    if suppress {
                        // Skip this line entirely
                        rp = actual + 1;
                    } else {
                        // Output entire line including newline
                        let chunk_len = actual + 1 - rp;
                        if wp != rp {
                            data.copy_within(rp..actual + 1, wp);
                        }
                        wp += chunk_len;
                        rp = actual + 1;
                    }
                } else {
                    // Delimiter found: output field 1 (up to delimiter) + newline
                    let field_len = actual - rp;
                    if wp != rp && field_len > 0 {
                        data.copy_within(rp..actual, wp);
                    }
                    wp += field_len;
                    data[wp] = line_delim;
                    wp += 1;
                    // Skip to next newline
                    match memchr::memchr(line_delim, &data[actual + 1..]) {
                        None => {
                            rp = len;
                        }
                        Some(nl_off) => {
                            rp = actual + 1 + nl_off + 1;
                        }
                    }
                }
            }
        }
    }
    wp
}

/// Process a full data buffer (from mmap or read) with cut operation.
pub fn process_cut_data(data: &[u8], cfg: &CutConfig, out: &mut impl Write) -> io::Result<()> {
    match cfg.mode {
        CutMode::Fields => process_fields_fast(data, cfg, out),
        CutMode::Bytes | CutMode::Characters => process_bytes_fast(data, cfg, out),
    }
}

/// Process input from a reader (for stdin).
/// Uses batch reading: reads large chunks (16MB), then processes them in batch
/// using the fast mmap-based paths, avoiding per-line read_until syscall overhead.
/// 16MB chunks mean a 10MB piped input is consumed in a single batch.
pub fn process_cut_reader<R: BufRead>(
    mut reader: R,
    cfg: &CutConfig,
    out: &mut impl Write,
) -> io::Result<()> {
    const CHUNK_SIZE: usize = 16 * 1024 * 1024; // 16MB read chunks
    let line_delim = cfg.line_delim;

    // Read large chunks and process in batch.
    // We keep a buffer; after processing complete lines, we shift leftover to the front.
    let mut buf = Vec::with_capacity(CHUNK_SIZE + 4096);

    loop {
        // Read up to CHUNK_SIZE bytes
        buf.reserve(CHUNK_SIZE);
        let read_start = buf.len();
        unsafe { buf.set_len(read_start + CHUNK_SIZE) };
        let n = read_fully(&mut reader, &mut buf[read_start..])?;
        buf.truncate(read_start + n);

        if buf.is_empty() {
            break;
        }

        if n == 0 {
            // EOF with leftover data (last line without terminator)
            process_cut_data(&buf, cfg, out)?;
            break;
        }

        // Find the last line delimiter in the buffer so we process complete lines
        let process_end = match memchr::memrchr(line_delim, &buf) {
            Some(pos) => pos + 1,
            None => {
                // No line delimiter found — keep accumulating
                continue;
            }
        };

        // Process the complete lines using the fast batch path
        process_cut_data(&buf[..process_end], cfg, out)?;

        // Shift leftover to the front for next iteration
        let leftover_len = buf.len() - process_end;
        if leftover_len > 0 {
            buf.copy_within(process_end.., 0);
        }
        buf.truncate(leftover_len);
    }

    Ok(())
}

/// Read as many bytes as possible into buf, retrying on partial reads.
#[inline]
fn read_fully<R: BufRead>(reader: &mut R, buf: &mut [u8]) -> io::Result<usize> {
    let n = reader.read(buf)?;
    if n == buf.len() || n == 0 {
        return Ok(n);
    }
    // Slow path: partial read — retry to fill buffer
    let mut total = n;
    while total < buf.len() {
        match reader.read(&mut buf[total..]) {
            Ok(0) => break,
            Ok(n) => total += n,
            Err(e) if e.kind() == io::ErrorKind::Interrupted => continue,
            Err(e) => return Err(e),
        }
    }
    Ok(total)
}

/// In-place cut processing for mutable data buffers.
/// Returns Some(new_length) if in-place processing succeeded, None if not supported
/// for the given configuration (caller should fall back to regular processing).
///
/// In-place avoids allocating intermediate output buffers — the result is written
/// directly into the input buffer (output is always <= input for non-complement modes
/// with default output delimiter).
///
/// Note: if the input does not end with line_delim, we fall back to the regular
/// path because GNU cut always adds a trailing line delimiter, and the in-place
/// buffer cannot grow beyond the input size.
pub fn process_cut_data_mut(data: &mut [u8], cfg: &CutConfig) -> Option<usize> {
    if cfg.complement {
        return None;
    }
    // If input doesn't end with line_delim, the output may need an extra byte
    // (GNU cut always terminates the last line). In-place can't grow the buffer,
    // so fall back to the regular allocating path.
    if data.is_empty() || data[data.len() - 1] != cfg.line_delim {
        return None;
    }

    match cfg.mode {
        CutMode::Fields => {
            // Only handle when output delimiter matches input (single-byte)
            if cfg.output_delim.len() != 1 || cfg.output_delim[0] != cfg.delim {
                return None;
            }
            if cfg.delim == cfg.line_delim {
                return None;
            }
            Some(cut_fields_inplace_general(
                data,
                cfg.delim,
                cfg.line_delim,
                cfg.ranges,
                cfg.suppress_no_delim,
            ))
        }
        CutMode::Bytes | CutMode::Characters => {
            if !cfg.output_delim.is_empty() {
                return None;
            }
            Some(cut_bytes_inplace_general(data, cfg.line_delim, cfg.ranges))
        }
    }
}

/// In-place generalized field extraction.
/// Handles single fields, contiguous ranges, and non-contiguous multi-field patterns.
fn cut_fields_inplace_general(
    data: &mut [u8],
    delim: u8,
    line_delim: u8,
    ranges: &[Range],
    suppress: bool,
) -> usize {
    // Special case: field 1 only (existing optimized path)
    if ranges.len() == 1 && ranges[0].start == 1 && ranges[0].end == 1 {
        return cut_field1_inplace(data, delim, line_delim, suppress);
    }

    let len = data.len();
    if len == 0 {
        return 0;
    }

    let max_field = ranges.last().map_or(0, |r| r.end);
    let max_delims = max_field.min(128);
    let mut wp: usize = 0;
    let mut rp: usize = 0;

    while rp < len {
        let line_end = memchr::memchr(line_delim, &data[rp..])
            .map(|p| rp + p)
            .unwrap_or(len);
        let line_len = line_end - rp;

        // Collect delimiter positions (relative to line start)
        let mut delim_pos = [0usize; 128];
        let mut num_delims: usize = 0;

        for pos in memchr_iter(delim, &data[rp..line_end]) {
            if num_delims < max_delims {
                delim_pos[num_delims] = pos;
                num_delims += 1;
                if num_delims >= max_delims {
                    break;
                }
            }
        }

        if num_delims == 0 {
            // No delimiter in line
            if !suppress {
                if wp != rp {
                    data.copy_within(rp..line_end, wp);
                }
                wp += line_len;
                if line_end < len {
                    data[wp] = line_delim;
                    wp += 1;
                }
            }
        } else {
            let total_fields = num_delims + 1;
            let mut first_output = true;

            for r in ranges {
                let range_start = r.start;
                let range_end = r.end.min(total_fields);
                if range_start > total_fields {
                    break;
                }
                for field_num in range_start..=range_end {
                    if field_num > total_fields {
                        break;
                    }

                    let field_start = if field_num == 1 {
                        0
                    } else if field_num - 2 < num_delims {
                        delim_pos[field_num - 2] + 1
                    } else {
                        continue;
                    };
                    let field_end = if field_num <= num_delims {
                        delim_pos[field_num - 1]
                    } else {
                        line_len
                    };

                    if !first_output {
                        data[wp] = delim;
                        wp += 1;
                    }
                    let flen = field_end - field_start;
                    if flen > 0 {
                        data.copy_within(rp + field_start..rp + field_start + flen, wp);
                        wp += flen;
                    }
                    first_output = false;
                }
            }

            if !first_output && line_end < len {
                data[wp] = line_delim;
                wp += 1;
            } else if first_output && line_end < len {
                // No fields selected but line had delimiters — output empty line
                data[wp] = line_delim;
                wp += 1;
            }
        }

        rp = if line_end < len { line_end + 1 } else { len };
    }

    wp
}

/// In-place byte/char range extraction.
fn cut_bytes_inplace_general(data: &mut [u8], line_delim: u8, ranges: &[Range]) -> usize {
    let len = data.len();
    if len == 0 {
        return 0;
    }

    // Quick check: single range from byte 1 to end = no-op
    if ranges.len() == 1 && ranges[0].start == 1 && ranges[0].end == usize::MAX {
        return len;
    }

    // Single range from byte 1: fast truncation path
    if ranges.len() == 1 && ranges[0].start == 1 && ranges[0].end < usize::MAX {
        return cut_bytes_from_start_inplace(data, line_delim, ranges[0].end);
    }

    let mut wp: usize = 0;
    let mut rp: usize = 0;

    while rp < len {
        let line_end = memchr::memchr(line_delim, &data[rp..])
            .map(|p| rp + p)
            .unwrap_or(len);
        let line_len = line_end - rp;

        for r in ranges {
            let start = r.start.saturating_sub(1);
            let end = r.end.min(line_len);
            if start >= line_len {
                break;
            }
            let flen = end - start;
            if flen > 0 {
                data.copy_within(rp + start..rp + start + flen, wp);
                wp += flen;
            }
        }

        if line_end < len {
            data[wp] = line_delim;
            wp += 1;
        }

        rp = if line_end < len { line_end + 1 } else { len };
    }

    wp
}

/// In-place truncation for -b1-N: truncate each line to at most max_bytes.
fn cut_bytes_from_start_inplace(data: &mut [u8], line_delim: u8, max_bytes: usize) -> usize {
    let len = data.len();

    // Quick check: see if all lines fit within max_bytes (common case)
    let mut all_fit = true;
    let mut start = 0;
    for pos in memchr_iter(line_delim, data) {
        if pos - start > max_bytes {
            all_fit = false;
            break;
        }
        start = pos + 1;
    }
    if all_fit && start < len && len - start > max_bytes {
        all_fit = false;
    }
    if all_fit {
        return len;
    }

    // Some lines need truncation
    let mut wp: usize = 0;
    let mut rp: usize = 0;

    while rp < len {
        let line_end = memchr::memchr(line_delim, &data[rp..])
            .map(|p| rp + p)
            .unwrap_or(len);
        let line_len = line_end - rp;

        let take = line_len.min(max_bytes);
        if take > 0 && wp != rp {
            data.copy_within(rp..rp + take, wp);
        }
        wp += take;

        if line_end < len {
            data[wp] = line_delim;
            wp += 1;
        }

        rp = if line_end < len { line_end + 1 } else { len };
    }

    wp
}

/// Cut operation mode
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum CutMode {
    Bytes,
    Characters,
    Fields,
}
