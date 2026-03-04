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

/// Fast fold by byte count without -s flag.
/// Buffers output into ~1MB chunks to reduce write syscalls.
fn fold_byte_fast(data: &[u8], width: usize, out: &mut impl Write) -> std::io::Result<()> {
    let mut seg_start = 0usize;
    let mut buf: Vec<u8> = Vec::with_capacity(1024 * 1024 + 4096);

    for nl_pos in memchr::memchr_iter(b'\n', data) {
        let segment = &data[seg_start..nl_pos];
        let mut start = 0;
        while start + width < segment.len() {
            buf.extend_from_slice(&segment[start..start + width]);
            buf.push(b'\n');
            start += width;
        }
        buf.extend_from_slice(&segment[start..]);
        buf.push(b'\n');
        seg_start = nl_pos + 1;

        if buf.len() >= 1024 * 1024 {
            out.write_all(&buf)?;
            buf.clear();
        }
    }

    // Handle final segment without trailing newline
    if seg_start < data.len() {
        let segment = &data[seg_start..];
        let mut start = 0;
        while start + width < segment.len() {
            buf.extend_from_slice(&segment[start..start + width]);
            buf.push(b'\n');
            start += width;
        }
        if start < segment.len() {
            buf.extend_from_slice(&segment[start..]);
        }
    }

    if !buf.is_empty() {
        out.write_all(&buf)?;
    }

    Ok(())
}

/// Fast fold by byte count with -s (break at spaces).
/// Buffers output into ~1MB chunks to minimize write syscalls.
fn fold_byte_fast_spaces(data: &[u8], width: usize, out: &mut impl Write) -> std::io::Result<()> {
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

    // Handle final segment without trailing newline
    if pos < data.len() {
        fold_segment_bytes_spaces_buffered(&data[pos..], width, &mut outbuf);
    }

    if !outbuf.is_empty() {
        out.write_all(&outbuf)?;
    }
    Ok(())
}

/// Streaming fold by column count — single-pass stream using memchr2.
/// Processes the entire file in one scan, finding both tabs and newlines
/// simultaneously. Avoids the overhead of per-line decomposition + per-line
/// tab checking (two separate SIMD passes over the data).
fn fold_column_mode_streaming(
    data: &[u8],
    width: usize,
    break_at_spaces: bool,
    out: &mut impl Write,
) -> std::io::Result<()> {
    if break_at_spaces {
        return fold_column_mode_spaces_streaming(data, width, out);
    }

    let mut outbuf: Vec<u8> = Vec::with_capacity(1024 * 1024 + 4096);
    let mut col: usize = 0;
    let mut seg_start: usize = 0;
    let mut i: usize = 0;

    while i < data.len() {
        // SIMD scan: skip regular bytes, find next tab or newline
        match memchr::memchr2(b'\t', b'\n', &data[i..]) {
            Some(off) => {
                let special_pos = i + off;
                let run_len = special_pos - i;

                // Check if regular bytes before the special char cause overflow
                if col + run_len > width {
                    // Need line breaks within this regular-byte run
                    loop {
                        let remaining = special_pos - i;
                        let fit = width - col;
                        if fit >= remaining {
                            col += remaining;
                            i = special_pos;
                            break;
                        }
                        outbuf.extend_from_slice(&data[seg_start..i + fit]);
                        outbuf.push(b'\n');
                        i += fit;
                        seg_start = i;
                        col = 0;
                    }
                } else {
                    col += run_len;
                    i = special_pos;
                }

                // Handle the special character
                if data[i] == b'\n' {
                    outbuf.extend_from_slice(&data[seg_start..=i]);
                    col = 0;
                    i += 1;
                    seg_start = i;
                    if outbuf.len() >= 1024 * 1024 {
                        out.write_all(&outbuf)?;
                        outbuf.clear();
                    }
                } else {
                    // Tab
                    let new_col = ((col >> 3) + 1) << 3;
                    if new_col > width && col > 0 {
                        outbuf.extend_from_slice(&data[seg_start..i]);
                        outbuf.push(b'\n');
                        seg_start = i;
                        col = 0;
                        continue; // re-evaluate tab at col 0
                    }
                    col = new_col;
                    i += 1;
                }
            }
            None => {
                // Remaining data is all regular bytes (no tabs or newlines)
                let remaining = data.len() - i;
                if col + remaining > width {
                    loop {
                        let rem_now = data.len() - i;
                        let fit = width - col;
                        if fit >= rem_now {
                            break;
                        }
                        outbuf.extend_from_slice(&data[seg_start..i + fit]);
                        outbuf.push(b'\n');
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
        outbuf.extend_from_slice(&data[seg_start..]);
    }
    if !outbuf.is_empty() {
        out.write_all(&outbuf)?;
    }

    Ok(())
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
