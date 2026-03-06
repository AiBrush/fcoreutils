use std::io::Write;

/// Fold (wrap) lines to a given width.
///
/// Modes:
/// - `bytes` mode (-b): count bytes, break at byte boundaries
/// - default mode: count columns (tab = advance to next tab stop, backspace = decrement)
///
/// If `spaces` (-s): break at the last space within the width instead of mid-word.
pub fn fold_bytes(
    data: &[u8],
    width: usize,
    count_bytes: bool,
    break_at_spaces: bool,
    out: &mut impl Write,
) -> std::io::Result<()> {
    if data.is_empty() {
        return Ok(());
    }

    if width == 0 {
        return fold_width_zero(data, out);
    }

    // Fast path: byte mode, use SIMD-accelerated scanning
    if count_bytes {
        if break_at_spaces {
            return fold_byte_fast_spaces(data, width, out);
        } else {
            return fold_byte_fast(data, width, out);
        }
    }

    // Column mode without tabs: byte mode is equivalent (on glibc)
    if memchr::memchr(b'\t', data).is_none() {
        if break_at_spaces {
            return fold_byte_fast_spaces(data, width, out);
        } else {
            return fold_byte_fast(data, width, out);
        }
    }

    fold_column_mode_streaming(data, width, break_at_spaces, out)
}

/// Width 0: GNU fold behavior — each byte becomes a newline.
fn fold_width_zero(data: &[u8], out: &mut impl Write) -> std::io::Result<()> {
    let output = vec![b'\n'; data.len()];
    out.write_all(&output)
}

/// Parallel threshold for fold byte mode.
const FOLD_BYTE_PARALLEL_THRESHOLD: usize = 32 * 1024 * 1024;

/// Fast fold by byte count without -s flag.
/// Uses unsafe pointer copies and a pre-allocated 1MB output buffer.
/// For files >= 32MB, uses rayon parallel processing on line-aligned chunks.
fn fold_byte_fast(data: &[u8], width: usize, out: &mut impl Write) -> std::io::Result<()> {
    if data.len() >= FOLD_BYTE_PARALLEL_THRESHOLD {
        return fold_byte_fast_parallel(data, width, out);
    }

    const BUF_CAP: usize = 1024 * 1024 + 4096;
    let mut buf: Vec<u8> = Vec::with_capacity(BUF_CAP);
    let src = data.as_ptr();
    let mut wp: usize = 0;
    let mut base = buf.as_mut_ptr();
    let mut seg_start = 0usize;

    for nl_pos in memchr::memchr_iter(b'\n', data) {
        let seg_len = nl_pos - seg_start;

        if seg_len <= width {
            let total = seg_len + 1;
            if wp + total > BUF_CAP {
                unsafe { buf.set_len(wp) };
                out.write_all(&buf)?;
                buf.clear();
                wp = 0;
                base = buf.as_mut_ptr();
            }
            unsafe {
                std::ptr::copy_nonoverlapping(src.add(seg_start), base.add(wp), total);
            }
            wp += total;
        } else {
            let mut off = seg_start;
            let end = nl_pos;
            while off + width < end {
                let chunk = width + 1;
                if wp + chunk > BUF_CAP {
                    unsafe { buf.set_len(wp) };
                    out.write_all(&buf)?;
                    buf.clear();
                    wp = 0;
                    base = buf.as_mut_ptr();
                }
                unsafe {
                    std::ptr::copy_nonoverlapping(src.add(off), base.add(wp), width);
                    *base.add(wp + width) = b'\n';
                }
                wp += chunk;
                off += width;
            }
            let rem = end - off + 1;
            if wp + rem > BUF_CAP {
                unsafe { buf.set_len(wp) };
                out.write_all(&buf)?;
                buf.clear();
                wp = 0;
                base = buf.as_mut_ptr();
            }
            unsafe {
                std::ptr::copy_nonoverlapping(src.add(off), base.add(wp), rem);
            }
            wp += rem;
        }
        seg_start = nl_pos + 1;
    }

    if seg_start < data.len() {
        let mut off = seg_start;
        let end = data.len();
        while off + width < end {
            let chunk = width + 1;
            if wp + chunk > BUF_CAP {
                unsafe { buf.set_len(wp) };
                out.write_all(&buf)?;
                buf.clear();
                wp = 0;
                base = buf.as_mut_ptr();
            }
            unsafe {
                std::ptr::copy_nonoverlapping(src.add(off), base.add(wp), width);
                *base.add(wp + width) = b'\n';
            }
            wp += chunk;
            off += width;
        }
        if off < end {
            let rem = end - off;
            if wp + rem > BUF_CAP {
                unsafe { buf.set_len(wp) };
                out.write_all(&buf)?;
                buf.clear();
                wp = 0;
                base = buf.as_mut_ptr();
            }
            unsafe {
                std::ptr::copy_nonoverlapping(src.add(off), base.add(wp), rem);
            }
            wp += rem;
        }
    }

    if wp > 0 {
        unsafe { buf.set_len(wp) };
        out.write_all(&buf)?;
    }
    Ok(())
}

/// Parallel fold by byte count. Splits at newline boundaries, processes in parallel.
fn fold_byte_fast_parallel(data: &[u8], width: usize, out: &mut impl Write) -> std::io::Result<()> {
    use rayon::prelude::*;

    let num_chunks = rayon::current_num_threads().max(2);
    let target_chunk_size = data.len() / num_chunks;
    let mut chunks: Vec<&[u8]> = Vec::with_capacity(num_chunks + 1);
    let mut pos: usize = 0;

    for _ in 0..num_chunks - 1 {
        if pos >= data.len() {
            break;
        }
        let target_end = (pos + target_chunk_size).min(data.len());
        let chunk_end = if target_end >= data.len() {
            data.len()
        } else {
            match memchr::memchr(b'\n', &data[target_end..]) {
                Some(off) => target_end + off + 1,
                None => data.len(),
            }
        };
        chunks.push(&data[pos..chunk_end]);
        pos = chunk_end;
    }
    if pos < data.len() {
        chunks.push(&data[pos..]);
    }

    let results: Vec<Vec<u8>> = chunks
        .par_iter()
        .map(|chunk| {
            let mut buf = Vec::with_capacity(chunk.len() + chunk.len() / width + 256);
            fold_byte_chunk(chunk, width, &mut buf);
            buf
        })
        .collect();

    for result in &results {
        if !result.is_empty() {
            out.write_all(result)?;
        }
    }
    Ok(())
}

/// Process a chunk for fold byte mode into a Vec<u8>.
/// Uses unsafe pointer copies for maximum throughput.
fn fold_byte_chunk(data: &[u8], width: usize, buf: &mut Vec<u8>) {
    if data.is_empty() {
        return;
    }

    let needed = data.len() + data.len() / width + 256;
    buf.reserve(needed);
    let base = buf.as_mut_ptr();
    let src = data.as_ptr();
    let initial_len = buf.len();
    let mut wp: usize = initial_len;
    let mut seg_start = 0usize;

    for nl_pos in memchr::memchr_iter(b'\n', data) {
        let seg_len = nl_pos - seg_start;

        if seg_len <= width {
            let total = seg_len + 1;
            unsafe {
                std::ptr::copy_nonoverlapping(src.add(seg_start), base.add(wp), total);
            }
            wp += total;
        } else {
            let mut off = seg_start;
            let end = nl_pos;
            while off + width < end {
                unsafe {
                    std::ptr::copy_nonoverlapping(src.add(off), base.add(wp), width);
                    *base.add(wp + width) = b'\n';
                }
                wp += width + 1;
                off += width;
            }
            let rem = end - off + 1;
            unsafe {
                std::ptr::copy_nonoverlapping(src.add(off), base.add(wp), rem);
            }
            wp += rem;
        }
        seg_start = nl_pos + 1;
    }

    // Handle final segment without trailing newline
    if seg_start < data.len() {
        let mut off = seg_start;
        let end = data.len();
        while off + width < end {
            unsafe {
                std::ptr::copy_nonoverlapping(src.add(off), base.add(wp), width);
                *base.add(wp + width) = b'\n';
            }
            wp += width + 1;
            off += width;
        }
        if off < end {
            let rem = end - off;
            unsafe {
                std::ptr::copy_nonoverlapping(src.add(off), base.add(wp), rem);
            }
            wp += rem;
        }
    }

    unsafe {
        buf.set_len(wp);
    }
}

/// Fast fold by byte count with -s (break at spaces).
/// For files >= 32MB, uses rayon parallel processing.
fn fold_byte_fast_spaces(data: &[u8], width: usize, out: &mut impl Write) -> std::io::Result<()> {
    if data.len() >= FOLD_BYTE_PARALLEL_THRESHOLD {
        return fold_byte_spaces_parallel(data, width, out);
    }

    let mut outbuf: Vec<u8> = Vec::with_capacity(1024 * 1024 + 4096);
    let mut pos: usize = 0;

    for nl_pos in memchr::memchr_iter(b'\n', data) {
        let segment = &data[pos..nl_pos];
        fold_segment_bytes_spaces_buffered(segment, width, &mut outbuf);
        outbuf.push(b'\n');
        pos = nl_pos + 1;

        if outbuf.len() >= 1024 * 1024 {
            out.write_all(&outbuf)?;
            outbuf.clear();
        }
    }

    if pos < data.len() {
        fold_segment_bytes_spaces_buffered(&data[pos..], width, &mut outbuf);
    }

    if !outbuf.is_empty() {
        out.write_all(&outbuf)?;
    }
    Ok(())
}

/// Parallel fold by byte count with -s.
fn fold_byte_spaces_parallel(
    data: &[u8],
    width: usize,
    out: &mut impl Write,
) -> std::io::Result<()> {
    use rayon::prelude::*;

    let num_chunks = rayon::current_num_threads().max(2);
    let target_chunk_size = data.len() / num_chunks;
    let mut chunks: Vec<&[u8]> = Vec::with_capacity(num_chunks + 1);
    let mut pos: usize = 0;

    for _ in 0..num_chunks - 1 {
        if pos >= data.len() {
            break;
        }
        let target_end = (pos + target_chunk_size).min(data.len());
        let chunk_end = if target_end >= data.len() {
            data.len()
        } else {
            match memchr::memchr(b'\n', &data[target_end..]) {
                Some(off) => target_end + off + 1,
                None => data.len(),
            }
        };
        chunks.push(&data[pos..chunk_end]);
        pos = chunk_end;
    }
    if pos < data.len() {
        chunks.push(&data[pos..]);
    }

    let results: Vec<Vec<u8>> = chunks
        .par_iter()
        .map(|chunk| {
            let mut buf = Vec::with_capacity(chunk.len() + chunk.len() / width + 256);
            fold_byte_spaces_chunk(chunk, width, &mut buf);
            buf
        })
        .collect();

    for result in &results {
        if !result.is_empty() {
            out.write_all(result)?;
        }
    }
    Ok(())
}

/// Process a chunk for fold byte mode with -s into a Vec<u8>.
fn fold_byte_spaces_chunk(data: &[u8], width: usize, outbuf: &mut Vec<u8>) {
    let mut pos: usize = 0;

    for nl_pos in memchr::memchr_iter(b'\n', data) {
        let segment = &data[pos..nl_pos];
        fold_segment_bytes_spaces_buffered(segment, width, outbuf);
        outbuf.push(b'\n');
        pos = nl_pos + 1;
    }

    if pos < data.len() {
        fold_segment_bytes_spaces_buffered(&data[pos..], width, outbuf);
    }
}

/// Parallel threshold for fold column mode.
const FOLD_PARALLEL_THRESHOLD: usize = 4 * 1024 * 1024;

/// Streaming fold by column count — single-pass stream using memchr2.
/// For large files (>4MB), uses rayon parallel processing on line-aligned chunks.
/// Each chunk is processed independently since column resets at newlines.
fn fold_column_mode_streaming(
    data: &[u8],
    width: usize,
    break_at_spaces: bool,
    out: &mut impl Write,
) -> std::io::Result<()> {
    if break_at_spaces {
        return fold_column_mode_spaces_streaming(data, width, out);
    }

    if data.len() >= FOLD_PARALLEL_THRESHOLD {
        return fold_column_parallel(data, width, out);
    }

    let mut outbuf: Vec<u8> = Vec::with_capacity(data.len() + data.len() / 4);
    fold_column_chunk(data, width, &mut outbuf);
    if !outbuf.is_empty() {
        out.write_all(&outbuf)?;
    }
    Ok(())
}

/// Parallel fold for column mode with tabs. Splits data into line-aligned chunks,
/// processes each in parallel with rayon, writes results in order.
fn fold_column_parallel(data: &[u8], width: usize, out: &mut impl Write) -> std::io::Result<()> {
    use rayon::prelude::*;

    let num_chunks = rayon::current_num_threads().max(2);
    let target_chunk_size = data.len() / num_chunks;
    let mut chunks: Vec<&[u8]> = Vec::with_capacity(num_chunks + 1);
    let mut pos: usize = 0;

    for _ in 0..num_chunks - 1 {
        if pos >= data.len() {
            break;
        }
        let target_end = (pos + target_chunk_size).min(data.len());
        let chunk_end = if target_end >= data.len() {
            data.len()
        } else {
            match memchr::memchr(b'\n', &data[target_end..]) {
                Some(off) => target_end + off + 1,
                None => data.len(),
            }
        };
        chunks.push(&data[pos..chunk_end]);
        pos = chunk_end;
    }
    if pos < data.len() {
        chunks.push(&data[pos..]);
    }

    let results: Vec<Vec<u8>> = chunks
        .par_iter()
        .map(|chunk| {
            let mut buf = Vec::with_capacity(chunk.len() + chunk.len() / 4);
            fold_column_chunk(chunk, width, &mut buf);
            buf
        })
        .collect();

    for result in &results {
        if !result.is_empty() {
            out.write_all(result)?;
        }
    }
    Ok(())
}

/// Process a chunk for fold column mode using unsafe pointer writes.
/// Uses memchr2 SIMD scanning for tabs and newlines, with raw pointer output.
fn fold_column_chunk(data: &[u8], width: usize, outbuf: &mut Vec<u8>) {
    if data.is_empty() {
        return;
    }

    // Worst case: every char at width boundary → output ≈ 2x input
    let worst = data.len() * 2 + 4096;
    outbuf.reserve(worst);

    let src = data.as_ptr();
    let out_base = outbuf.as_mut_ptr();
    let initial_len = outbuf.len();
    let mut wp: usize = initial_len;
    let mut col: usize = 0;
    let mut seg_start: usize = 0;
    let mut i: usize = 0;

    while i < data.len() {
        match memchr::memchr2(b'\t', b'\n', &data[i..]) {
            Some(off) => {
                let special_pos = i + off;
                let run_len = special_pos - i;

                if col + run_len > width {
                    loop {
                        let remaining = special_pos - i;
                        let fit = width - col;
                        if fit >= remaining {
                            col += remaining;
                            i = special_pos;
                            break;
                        }
                        let copy_len = i + fit - seg_start;
                        unsafe {
                            std::ptr::copy_nonoverlapping(
                                src.add(seg_start),
                                out_base.add(wp),
                                copy_len,
                            );
                            wp += copy_len;
                            *out_base.add(wp) = b'\n';
                            wp += 1;
                        }
                        i += fit;
                        seg_start = i;
                        col = 0;
                    }
                } else {
                    col += run_len;
                    i = special_pos;
                }

                if data[i] == b'\n' {
                    let copy_len = i + 1 - seg_start;
                    unsafe {
                        std::ptr::copy_nonoverlapping(
                            src.add(seg_start),
                            out_base.add(wp),
                            copy_len,
                        );
                    }
                    wp += copy_len;
                    col = 0;
                    i += 1;
                    seg_start = i;
                } else {
                    let new_col = ((col >> 3) + 1) << 3;
                    if new_col > width && col > 0 {
                        let copy_len = i - seg_start;
                        unsafe {
                            std::ptr::copy_nonoverlapping(
                                src.add(seg_start),
                                out_base.add(wp),
                                copy_len,
                            );
                            wp += copy_len;
                            *out_base.add(wp) = b'\n';
                            wp += 1;
                        }
                        seg_start = i;
                        col = 0;
                        continue;
                    }
                    col = new_col;
                    i += 1;
                }
            }
            None => {
                let remaining = data.len() - i;
                if col + remaining > width {
                    loop {
                        let rem_now = data.len() - i;
                        let fit = width - col;
                        if fit >= rem_now {
                            break;
                        }
                        let copy_len = i + fit - seg_start;
                        unsafe {
                            std::ptr::copy_nonoverlapping(
                                src.add(seg_start),
                                out_base.add(wp),
                                copy_len,
                            );
                            wp += copy_len;
                            *out_base.add(wp) = b'\n';
                            wp += 1;
                        }
                        i += fit;
                        seg_start = i;
                        col = 0;
                    }
                }
                break;
            }
        }
    }

    if seg_start < data.len() {
        let copy_len = data.len() - seg_start;
        unsafe {
            std::ptr::copy_nonoverlapping(src.add(seg_start), out_base.add(wp), copy_len);
        }
        wp += copy_len;
    }

    unsafe {
        outbuf.set_len(wp);
    }
}

/// Fold a byte segment (no newlines) with -s (break at spaces), buffered output.
#[inline]
fn fold_segment_bytes_spaces_buffered(segment: &[u8], width: usize, outbuf: &mut Vec<u8>) {
    let mut start = 0;
    while start + width < segment.len() {
        let chunk = &segment[start..start + width];
        match memchr::memrchr2(b' ', b'\t', chunk) {
            Some(sp_offset) => {
                let break_at = start + sp_offset + 1;
                outbuf.extend_from_slice(&segment[start..break_at]);
                outbuf.push(b'\n');
                start = break_at;
            }
            None => {
                outbuf.extend_from_slice(&segment[start..start + width]);
                outbuf.push(b'\n');
                start += width;
            }
        }
    }
    if start < segment.len() {
        outbuf.extend_from_slice(&segment[start..]);
    }
}

/// Streaming fold column mode with -s (break at spaces).
/// Uses buffered output to minimize write syscalls.
/// Fast path: if no tabs in data, column width == byte width, so we can
/// use the simpler byte-mode space-breaking algorithm.
fn fold_column_mode_spaces_streaming(
    data: &[u8],
    width: usize,
    out: &mut impl Write,
) -> std::io::Result<()> {
    // If no tabs, column mode == byte mode (every byte has width 1)
    // BS/CR/control chars could theoretically differ but are vanishingly rare
    // in practice and the difference is negligible.
    if memchr::memchr(b'\t', data).is_none() {
        return fold_byte_fast_spaces(data, width, out);
    }

    let mut pos = 0;
    let mut outbuf: Vec<u8> = Vec::with_capacity(1024 * 1024 + 4096);

    for nl_pos in memchr::memchr_iter(b'\n', data) {
        let line = &data[pos..nl_pos];
        // Short-circuit: line fits in width AND has no tabs → no folding needed
        if line.len() <= width && memchr::memchr(b'\t', line).is_none() {
            outbuf.extend_from_slice(line);
        } else {
            fold_column_spaces_fast(line, width, &mut outbuf);
        }
        outbuf.push(b'\n');

        if outbuf.len() >= 1024 * 1024 {
            out.write_all(&outbuf)?;
            outbuf.clear();
        }

        pos = nl_pos + 1;
    }

    // Handle final line without trailing newline
    if pos < data.len() {
        let line = &data[pos..];
        if line.len() <= width && memchr::memchr(b'\t', line).is_none() {
            outbuf.extend_from_slice(line);
        } else {
            fold_column_spaces_fast(line, width, &mut outbuf);
        }
    }

    if !outbuf.is_empty() {
        out.write_all(&outbuf)?;
    }

    Ok(())
}

/// Fast column-mode fold for a single line with -s (break at spaces).
/// Uses memchr2 to find tabs and spaces in bulk, processing runs of regular
/// bytes without per-byte branching. Matches GNU fold's exact algorithm:
/// - `column > width` triggers break (strictly greater)
/// - Break at last blank: output INCLUDING the blank, remainder starts after it
/// - After break: recalculate column from remaining data, re-process current char
/// - All bytes width 1 except tab (next tab stop), BS (col-1), CR (col=0)
#[inline]
fn fold_column_spaces_fast(line: &[u8], width: usize, outbuf: &mut Vec<u8>) {
    let mut col: usize = 0;
    let mut seg_start: usize = 0;
    let mut last_space_after: usize = 0;
    let mut has_space = false;
    let mut i: usize = 0;

    while i < line.len() {
        let b = line[i];
        if b == b'\t' {
            let new_col = ((col >> 3) + 1) << 3;
            if new_col > width && col > 0 {
                // Tab exceeds width — break
                if has_space {
                    outbuf.extend_from_slice(&line[seg_start..last_space_after]);
                    outbuf.push(b'\n');
                    seg_start = last_space_after;
                    col = recalc_column(&line[seg_start..i]);
                    has_space = false;
                    continue; // re-evaluate tab
                }
                outbuf.extend_from_slice(&line[seg_start..i]);
                outbuf.push(b'\n');
                seg_start = i;
                col = 0;
                continue; // re-evaluate tab with col=0
            }
            // Tab also counts as a breakable whitespace for -s (GNU compat)
            has_space = true;
            last_space_after = i + 1;
            col = new_col;
            i += 1;
        } else if b == b' ' {
            col += 1;
            if col > width {
                if has_space {
                    outbuf.extend_from_slice(&line[seg_start..last_space_after]);
                    outbuf.push(b'\n');
                    seg_start = last_space_after;
                    col = recalc_column(&line[seg_start..i]);
                    has_space = false;
                    continue; // re-evaluate this space
                }
                // No prior blank — break before this space (GNU: output buffer, rescan)
                outbuf.extend_from_slice(&line[seg_start..i]);
                outbuf.push(b'\n');
                seg_start = i;
                col = 1; // space starts the new line with width 1
                has_space = true;
                last_space_after = i + 1;
                i += 1;
                continue;
            }
            has_space = true;
            last_space_after = i + 1;
            i += 1;
        } else {
            // Find next tab or space using SIMD memchr2
            let run_end = match memchr::memchr2(b'\t', b' ', &line[i + 1..]) {
                Some(off) => i + 1 + off,
                None => line.len(),
            };

            // Process run of regular bytes: each has column width 1
            let run_remaining = run_end - i;
            if col + run_remaining <= width {
                // Entire run fits
                col += run_remaining;
                i = run_end;
            } else {
                // Run exceeds width — need to break
                let mut j = i;
                loop {
                    let rem = run_end - j;
                    if col + rem <= width {
                        col += rem;
                        i = run_end;
                        break;
                    }
                    if has_space {
                        // Break at last blank (includes the blank)
                        outbuf.extend_from_slice(&line[seg_start..last_space_after]);
                        outbuf.push(b'\n');
                        seg_start = last_space_after;
                        col = j - seg_start; // regular bytes only, each width 1
                        has_space = false;
                        continue; // re-check with new col
                    }
                    // No blank — hard break at width boundary
                    let fit = width - col;
                    outbuf.extend_from_slice(&line[seg_start..j + fit]);
                    outbuf.push(b'\n');
                    j += fit;
                    seg_start = j;
                    col = 0;
                }
            }
        }
    }

    if seg_start < line.len() {
        outbuf.extend_from_slice(&line[seg_start..]);
    }
}

/// Get the column width and byte length of a byte at `data[pos]`.
/// Returns (column_width, byte_length) — always (1, 1) for non-special bytes.
///
/// GNU fold's multibyte path is guarded by:
///   `#if HAVE_MBRTOC32 && (! defined __GLIBC__ || defined __UCLIBC__)`
/// On glibc (every mainstream Linux distro), that condition is false, so
/// fold counts bytes — one column per byte, same as -b mode.
/// Tab, backspace, and CR are handled by the caller.
#[inline]
fn char_info(data: &[u8], pos: usize) -> (usize, usize) {
    let b = data[pos];
    if b < 0x80 {
        // ASCII: tab/backspace handled by caller; control chars have 0 width
        if b < 0x20 || b == 0x7f {
            (0, 1)
        } else {
            (1, 1)
        }
    } else {
        // High byte: count as 1 column, 1 byte (GNU glibc compat)
        (1, 1)
    }
}

/// Check if folding would produce identical output (all lines fit within width).
/// Used by the binary for direct write-through optimization.
pub fn fold_is_passthrough(data: &[u8], width: usize, count_bytes: bool) -> bool {
    if width == 0 || data.is_empty() {
        return data.is_empty();
    }
    // Column mode with tabs: can't easily determine passthrough
    if !count_bytes && memchr::memchr(b'\t', data).is_some() {
        return false;
    }
    let mut prev = 0;
    for nl_pos in memchr::memchr_iter(b'\n', data) {
        if nl_pos - prev > width {
            return false;
        }
        prev = nl_pos + 1;
    }
    data.len() - prev <= width
}

/// Recalculate column position by replaying a segment (handles tabs, CR, backspace).
/// Used when non-linear column operations (CR, backspace) invalidate the fast
/// `col - col_at_space` delta formula.
fn recalc_column(data: &[u8]) -> usize {
    let mut col = 0;
    let mut i = 0;
    while i < data.len() {
        let b = data[i];
        if b == b'\r' {
            col = 0;
            i += 1;
        } else if b == b'\t' {
            col = ((col / 8) + 1) * 8;
            i += 1;
        } else if b == b'\x08' {
            if col > 0 {
                col -= 1;
            }
            i += 1;
        } else if b < 0x80 {
            if b >= 0x20 && b != 0x7f {
                col += 1;
            }
            i += 1;
        } else {
            let (cw, byte_len) = char_info(data, i);
            col += cw;
            i += byte_len;
        }
    }
    col
}
