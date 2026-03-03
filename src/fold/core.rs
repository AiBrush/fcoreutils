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
    let mut col = 0usize;
    let mut buf: Vec<u8> = Vec::with_capacity(1024 * 1024 + 4096);

    for nl_pos in memchr::memchr_iter(b'\n', data) {
        let segment = &data[seg_start..nl_pos];
        let mut start = 0;
        while start + width - col < segment.len() {
            let chunk = width - col;
            buf.extend_from_slice(&segment[start..start + chunk]);
            buf.push(b'\n');
            start += chunk;
            col = 0;
        }
        buf.extend_from_slice(&segment[start..]);
        buf.push(b'\n');
        col = 0;
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
        while start + width - col < segment.len() {
            let chunk = width - col;
            buf.extend_from_slice(&segment[start..start + chunk]);
            buf.push(b'\n');
            start += chunk;
            col = 0;
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
/// Streaming: writes folded output directly to the writer.
fn fold_byte_fast_spaces(data: &[u8], width: usize, out: &mut impl Write) -> std::io::Result<()> {
    let mut pos: usize = 0;

    while pos < data.len() {
        let remaining = &data[pos..];

        match memchr::memchr(b'\n', remaining) {
            Some(nl_offset) => {
                let segment = &data[pos..pos + nl_offset + 1];
                fold_segment_bytes_spaces_streaming(out, segment, width)?;
                pos += nl_offset + 1;
            }
            None => {
                fold_segment_bytes_spaces_streaming(out, &data[pos..], width)?;
                break;
            }
        }
    }

    Ok(())
}

/// Streaming fold by column count — buffers output into ~1MB chunks.
/// Reuses a single buffer for non-ASCII line processing.
fn fold_column_mode_streaming(
    data: &[u8],
    width: usize,
    break_at_spaces: bool,
    out: &mut impl Write,
) -> std::io::Result<()> {
    if break_at_spaces {
        return fold_column_mode_spaces_streaming(data, width, out);
    }

    let mut pos = 0;
    let mut outbuf: Vec<u8> = Vec::with_capacity(1024 * 1024 + 4096);
    let mut line_buf: Vec<u8> = Vec::with_capacity(4096);

    for nl_pos in memchr::memchr_iter(b'\n', data) {
        let line_data = &data[pos..nl_pos];

        if line_data.len() <= width {
            outbuf.extend_from_slice(line_data);
        } else if is_ascii_simple(line_data) {
            fold_segment_bytes_to_buf(line_data, width, &mut outbuf);
        } else {
            line_buf.clear();
            fold_one_line_column(line_data, width, false, &mut line_buf);
            outbuf.extend_from_slice(&line_buf);
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
        let line_data = &data[pos..];
        if line_data.len() <= width {
            outbuf.extend_from_slice(line_data);
        } else if is_ascii_simple(line_data) {
            fold_segment_bytes_to_buf(line_data, width, &mut outbuf);
        } else {
            line_buf.clear();
            fold_one_line_column(line_data, width, false, &mut line_buf);
            outbuf.extend_from_slice(&line_buf);
        }
    }

    if !outbuf.is_empty() {
        out.write_all(&outbuf)?;
    }

    Ok(())
}

/// Fold a byte segment into a buffer (no streaming writes).
#[inline]
fn fold_segment_bytes_to_buf(segment: &[u8], width: usize, buf: &mut Vec<u8>) {
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

/// Streaming fold of a byte segment with -s (break at spaces).
#[inline]
fn fold_segment_bytes_spaces_streaming(
    out: &mut impl Write,
    segment: &[u8],
    width: usize,
) -> std::io::Result<()> {
    let mut start = 0;
    while start + width < segment.len() {
        if segment[start + width] == b'\n' {
            out.write_all(&segment[start..start + width + 1])?;
            return Ok(());
        }
        let chunk = &segment[start..start + width];
        match memchr::memrchr2(b' ', b'\t', chunk) {
            Some(sp_offset) => {
                let break_at = start + sp_offset + 1;
                out.write_all(&segment[start..break_at])?;
                out.write_all(b"\n")?;
                start = break_at;
            }
            None => {
                out.write_all(&segment[start..start + width])?;
                out.write_all(b"\n")?;
                start += width;
            }
        }
    }
    if start < segment.len() {
        out.write_all(&segment[start..])?;
    }
    Ok(())
}

/// Streaming fold column mode with -s (break at spaces).
fn fold_column_mode_spaces_streaming(
    data: &[u8],
    width: usize,
    out: &mut impl Write,
) -> std::io::Result<()> {
    let mut pos = 0;

    while pos < data.len() {
        let remaining = &data[pos..];
        let line_end = memchr::memchr(b'\n', remaining).map(|p| pos + p);
        let line_data = match line_end {
            Some(nl) => &data[pos..nl],
            None => &data[pos..],
        };

        if line_data.len() <= width {
            if is_ascii_simple(line_data) {
                out.write_all(line_data)?;
            } else {
                let mut buf = Vec::new();
                fold_one_line_column(line_data, width, true, &mut buf);
                out.write_all(&buf)?;
            }
        } else {
            fold_line_spaces_checked_streaming(line_data, width, out)?;
        }

        if let Some(nl) = line_end {
            out.write_all(b"\n")?;
            pos = nl + 1;
        } else {
            break;
        }
    }

    Ok(())
}

/// Streaming fold with -s, checking each chunk for non-simple bytes.
fn fold_line_spaces_checked_streaming(
    line: &[u8],
    width: usize,
    out: &mut impl Write,
) -> std::io::Result<()> {
    let mut start = 0;
    while start + width < line.len() {
        let chunk = &line[start..start + width];
        if !is_ascii_simple(chunk) {
            let mut buf = Vec::new();
            fold_one_line_column(&line[start..], width, true, &mut buf);
            out.write_all(&buf)?;
            return Ok(());
        }
        match memchr::memrchr(b' ', chunk) {
            Some(sp_offset) => {
                let break_at = start + sp_offset + 1;
                out.write_all(&line[start..break_at])?;
                out.write_all(b"\n")?;
                start = break_at;
            }
            None => {
                out.write_all(&line[start..start + width])?;
                out.write_all(b"\n")?;
                start += width;
            }
        }
    }
    if start < line.len() {
        let tail = &line[start..];
        if is_ascii_simple(tail) {
            out.write_all(tail)?;
        } else {
            let mut buf = Vec::new();
            fold_one_line_column(tail, width, true, &mut buf);
            out.write_all(&buf)?;
        }
    }
    Ok(())
}

/// Check if data is pure ASCII with no tabs, backspaces, CR, or control chars.
/// Uses SWAR (SIMD Within A Register) to process 8 bytes at a time.
#[inline]
fn is_ascii_simple(data: &[u8]) -> bool {
    let mut i = 0;
    // Process 8 bytes at a time using u64 word operations
    while i + 8 <= data.len() {
        let word = u64::from_ne_bytes(data[i..i + 8].try_into().unwrap());
        if !word_is_ascii_simple(word) {
            return false;
        }
        i += 8;
    }
    // Handle remaining bytes
    for &b in &data[i..] {
        if b < 0x20 || b > 0x7E {
            return false;
        }
    }
    true
}

/// Check if all 8 bytes in a u64 word are in the ASCII printable range [0x20, 0x7E].
/// Uses SWAR bit tricks to check all bytes in parallel.
#[inline(always)]
fn word_is_ascii_simple(word: u64) -> bool {
    // Check 1: no byte has high bit set (all < 0x80)
    if word & 0x8080808080808080 != 0 {
        return false;
    }
    // Check 2: all bytes >= 0x20
    // Since all bytes < 0x80 (check 1), adding 0x60 cannot carry between bytes.
    // byte + 0x60: [0x00..0x1F] -> [0x60..0x7F] (high bit clear = bad)
    //              [0x20..=0x7F] -> [0x80..0xDF] (high bit set = good)
    // Note: 0x7F (DEL) passes here; check 3 rejects it.
    let added = word.wrapping_add(0x6060606060606060);
    if added & 0x8080808080808080 != 0x8080808080808080 {
        return false;
    }
    // Check 3: no byte == 0x7F (DEL)
    // XOR with 0x7F turns 0x7F bytes into 0x00; we then detect zero bytes via
    // the standard (x - 0x01) & !x & 0x80 trick.
    // When no 0x7F is present, all xored bytes are in [0x01..0x5F] — none
    // underflow on -0x01 — so no inter-byte borrow occurs and has_zero == 0.
    // When a 0x7F IS present, the zero byte flags correctly; adjacent bytes
    // may show false positives in has_zero but the overall != 0 is still correct.
    let xored = word ^ 0x7F7F7F7F7F7F7F7F;
    let has_zero = xored.wrapping_sub(0x0101010101010101) & !xored & 0x8080808080808080;
    has_zero == 0
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

/// Process a single line (no newlines) in column mode, writing to output.
///
/// Uses a scan-and-flush approach: tracks break points in the INPUT data,
/// then writes complete segments. Avoids copy_within for -s mode.
fn fold_one_line_column(line: &[u8], width: usize, break_at_spaces: bool, output: &mut Vec<u8>) {
    let mut col: usize = 0;
    // For -s mode: track last space in input, not output
    let mut last_space_in: Option<usize> = None; // byte index in `line` AFTER the space
    let mut col_at_space: usize = 0;
    // CR/backspace change col non-linearly, invalidating `col - col_at_space`.
    // When set, we must use recalc_column() to replay from the space marker.
    let mut needs_recalc = false;
    let mut seg_start: usize = 0; // start of current unflushed segment in `line`
    let mut i = 0;

    while i < line.len() {
        let byte = line[i];

        // Handle tab specially
        if byte == b'\t' {
            let tab_width = ((col / 8) + 1) * 8 - col;

            if col > 0 && col + tab_width > width {
                // Need to break before this tab (skip when col==0: can't break before first char)
                if break_at_spaces {
                    if let Some(sp_after) = last_space_in {
                        // Flush up to and including the space, then newline
                        output.extend_from_slice(&line[seg_start..sp_after]);
                        output.push(b'\n');
                        seg_start = sp_after;
                        col = if needs_recalc {
                            recalc_column(&line[sp_after..i])
                        } else {
                            col - col_at_space
                        };
                        last_space_in = None;
                        needs_recalc = false;
                        // Re-evaluate this tab with the new col — it may
                        // still exceed width after the space break.
                        continue;
                    } else {
                        output.extend_from_slice(&line[seg_start..i]);
                        output.push(b'\n');
                        seg_start = i;
                        col = 0;
                    }
                } else {
                    output.extend_from_slice(&line[seg_start..i]);
                    output.push(b'\n');
                    seg_start = i;
                    col = 0;
                }
            }

            if break_at_spaces {
                last_space_in = Some(i + 1);
                col_at_space = col + ((col / 8) + 1) * 8 - col;
                needs_recalc = false;
            }
            col += ((col / 8) + 1) * 8 - col;
            i += 1;
            continue;
        }

        // Handle carriage return: resets column to 0 (GNU adjust_column compat).
        // Invalidates `col - col_at_space` but keeps the space marker —
        // GNU fold still breaks at the last space even after CR.
        if byte == b'\r' {
            col = 0;
            if last_space_in.is_some() {
                needs_recalc = true;
            }
            i += 1;
            continue;
        }

        // Handle backspace: decrements column non-linearly.
        // Invalidates `col - col_at_space` but keeps the space marker.
        if byte == b'\x08' {
            if col > 0 {
                col -= 1;
            }
            if last_space_in.is_some() {
                needs_recalc = true;
            }
            i += 1;
            continue;
        }

        // Get character info (display width + byte length)
        let (cw, byte_len) = char_info(line, i);

        // Check if adding this character would exceed width
        if col + cw > width && cw > 0 {
            if break_at_spaces {
                if let Some(sp_after) = last_space_in {
                    output.extend_from_slice(&line[seg_start..sp_after]);
                    output.push(b'\n');
                    seg_start = sp_after;
                    col = if needs_recalc {
                        recalc_column(&line[sp_after..i])
                    } else {
                        col - col_at_space
                    };
                    last_space_in = None;
                    needs_recalc = false;
                    // Re-evaluate this character with the new col — it may
                    // still exceed width after the space break.
                    continue;
                } else {
                    output.extend_from_slice(&line[seg_start..i]);
                    output.push(b'\n');
                    seg_start = i;
                    col = 0;
                }
            } else {
                output.extend_from_slice(&line[seg_start..i]);
                output.push(b'\n');
                seg_start = i;
                col = 0;
            }
        }

        if break_at_spaces && byte == b' ' {
            last_space_in = Some(i + 1);
            col_at_space = col + cw;
            needs_recalc = false;
        }

        col += cw;
        i += byte_len;
    }

    // Flush remaining segment
    if seg_start < line.len() {
        output.extend_from_slice(&line[seg_start..]);
    }
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
