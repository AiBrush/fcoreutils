use std::io::Write;
use unicode_width::UnicodeWidthChar;

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

    // Fast path: byte mode without -s, use SIMD-accelerated scanning
    if count_bytes && !break_at_spaces {
        return fold_byte_fast(data, width, out);
    }

    let mut output = Vec::with_capacity(data.len() + data.len() / width);

    if count_bytes {
        fold_byte_mode(data, width, break_at_spaces, &mut output);
    } else {
        fold_column_mode(data, width, break_at_spaces, &mut output);
    }

    out.write_all(&output)
}

/// Width 0: GNU fold behavior — each byte becomes a newline.
fn fold_width_zero(data: &[u8], out: &mut impl Write) -> std::io::Result<()> {
    let output = vec![b'\n'; data.len()];
    out.write_all(&output)
}

/// Fast fold by byte count without -s flag.
/// Uses memchr to find newlines, bulk-copies runs, inserts breaks at exact positions.
fn fold_byte_fast(data: &[u8], width: usize, out: &mut impl Write) -> std::io::Result<()> {
    // Each line can have at most one extra newline inserted
    let mut output = Vec::with_capacity(data.len() + data.len() / width + 1);
    let mut pos: usize = 0;

    while pos < data.len() {
        // Find the next newline within the remaining data
        let remaining = &data[pos..];

        match memchr::memchr(b'\n', remaining) {
            Some(nl_offset) => {
                // Process the segment up to (and including) the newline
                let segment = &data[pos..pos + nl_offset + 1];
                fold_segment_bytes(&mut output, segment, width);
                pos += nl_offset + 1;
            }
            None => {
                // No more newlines: process the rest
                fold_segment_bytes(&mut output, &data[pos..], width);
                break;
            }
        }
    }

    out.write_all(&output)
}

/// Fold a single line segment (no internal newlines except possibly trailing) by bytes.
#[inline]
fn fold_segment_bytes(output: &mut Vec<u8>, segment: &[u8], width: usize) {
    let mut start = 0;
    while start + width < segment.len() {
        // Check if the character at start+width is a newline (end of line)
        if segment[start + width] == b'\n' {
            output.extend_from_slice(&segment[start..start + width + 1]);
            return;
        }
        output.extend_from_slice(&segment[start..start + width]);
        output.push(b'\n');
        start += width;
    }
    // Remaining bytes
    if start < segment.len() {
        output.extend_from_slice(&segment[start..]);
    }
}

/// Fold by byte count with -s (break at spaces).
/// When breaking at a space, uses copy_within instead of allocating a temporary Vec.
fn fold_byte_mode(data: &[u8], width: usize, break_at_spaces: bool, output: &mut Vec<u8>) {
    let mut col: usize = 0;
    let mut last_space_out_pos: Option<usize> = None;

    for &byte in data {
        if byte == b'\n' {
            output.push(b'\n');
            col = 0;
            last_space_out_pos = None;
            continue;
        }

        if col >= width {
            if break_at_spaces {
                if let Some(sp_pos) = last_space_out_pos {
                    // Insert newline after the space and shift trailing bytes forward
                    let tail_start = sp_pos + 1;
                    let tail_end = output.len();
                    let after_len = tail_end - tail_start;
                    output.push(0); // make room for the newline
                    output.copy_within(tail_start..tail_end, tail_start + 1);
                    output[tail_start] = b'\n';
                    col = after_len;
                    last_space_out_pos = None;
                } else {
                    output.push(b'\n');
                    col = 0;
                }
            } else {
                output.push(b'\n');
                col = 0;
            }
        }

        if break_at_spaces && (byte == b' ' || byte == b'\t') {
            last_space_out_pos = Some(output.len());
        }

        output.push(byte);
        col += 1;
    }
}

/// Fold by column count (default mode, handles tabs, backspaces, and UTF-8).
fn fold_column_mode(data: &[u8], width: usize, break_at_spaces: bool, output: &mut Vec<u8>) {
    let mut pos = 0;

    while pos < data.len() {
        // Find the next newline using SIMD
        let remaining = &data[pos..];
        let line_end = memchr::memchr(b'\n', remaining).map(|p| pos + p);
        let line_data = match line_end {
            Some(nl) => &data[pos..nl],
            None => &data[pos..],
        };

        // Fast path: pure ASCII, no tabs/backspaces, and byte count <= width
        if line_data.len() <= width && is_ascii_simple(line_data) {
            output.extend_from_slice(line_data);
            if let Some(nl) = line_end {
                output.push(b'\n');
                pos = nl + 1;
            } else {
                break;
            }
            continue;
        }

        // Slow path: process character by character for this line
        fold_one_line_column(line_data, width, break_at_spaces, output);
        if let Some(nl) = line_end {
            output.push(b'\n');
            pos = nl + 1;
        } else {
            break;
        }
    }
}

/// Check if a line is pure ASCII with no tabs or backspaces.
#[inline]
fn is_ascii_simple(data: &[u8]) -> bool {
    // All bytes must be ASCII printable (0x20..=0x7E) or space
    data.iter().all(|&b| b >= 0x20 && b <= 0x7E)
}

/// Get the display width and byte length of the UTF-8 character starting at `data[pos]`.
/// Returns (display_width, byte_length).
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
        // UTF-8 multi-byte: decode the character
        let (ch, len) = decode_utf8_at(data, pos);
        match ch {
            Some(c) => (UnicodeWidthChar::width(c).unwrap_or(0), len),
            None => (1, 1), // Invalid UTF-8 byte: treat as 1 column (GNU compat)
        }
    }
}

/// Decode a UTF-8 character starting at data[pos].
/// Returns (Some(char), byte_length) or (None, 1) for invalid sequences.
#[inline]
fn decode_utf8_at(data: &[u8], pos: usize) -> (Option<char>, usize) {
    let b = data[pos];
    let (expected_len, mut code_point) = if b < 0xC2 {
        return (None, 1); // continuation byte, invalid, or overlong (0xC0/0xC1)
    } else if b < 0xE0 {
        (2, (b as u32) & 0x1F)
    } else if b < 0xF0 {
        (3, (b as u32) & 0x0F)
    } else if b < 0xF8 {
        (4, (b as u32) & 0x07)
    } else {
        return (None, 1);
    };

    if pos + expected_len > data.len() {
        return (None, 1);
    }

    for i in 1..expected_len {
        let cb = data[pos + i];
        if cb & 0xC0 != 0x80 {
            return (None, 1);
        }
        code_point = (code_point << 6) | ((cb as u32) & 0x3F);
    }

    match char::from_u32(code_point) {
        Some(c) => (Some(c), expected_len),
        None => (None, 1),
    }
}

/// Insert a line break, preferring the last space position when -s is active.
/// Returns the new column position after the break.
#[inline]
fn insert_line_break(
    output: &mut Vec<u8>,
    last_space_out_pos: &mut Option<usize>,
    break_at_spaces: bool,
) -> usize {
    if break_at_spaces {
        if let Some(sp_pos) = *last_space_out_pos {
            let tail_start = sp_pos + 1;
            let tail_end = output.len();
            output.push(0);
            output.copy_within(tail_start..tail_end, tail_start + 1);
            output[tail_start] = b'\n';
            *last_space_out_pos = None;
            return recalc_column(&output[tail_start + 1..]);
        }
    }
    output.push(b'\n');
    *last_space_out_pos = None;
    0
}

/// Process a single line (no newlines) in column mode, writing to output.
/// Handles UTF-8 characters with proper display width.
fn fold_one_line_column(line: &[u8], width: usize, break_at_spaces: bool, output: &mut Vec<u8>) {
    let mut col: usize = 0;
    let mut last_space_out_pos: Option<usize> = None;
    let mut i = 0;

    while i < line.len() {
        let byte = line[i];

        // Handle tab specially
        if byte == b'\t' {
            let tab_width = ((col / 8) + 1) * 8 - col;

            if col + tab_width > width && tab_width > 0 {
                col = insert_line_break(output, &mut last_space_out_pos, break_at_spaces);
            }

            if break_at_spaces {
                last_space_out_pos = Some(output.len());
            }
            output.push(byte);
            // Recompute tab_width: col may have changed after space-break insertion
            col += ((col / 8) + 1) * 8 - col;
            i += 1;
            continue;
        }

        // Handle backspace
        if byte == b'\x08' {
            output.push(byte);
            if col > 0 {
                col -= 1;
            }
            i += 1;
            continue;
        }

        // Get character info (display width + byte length)
        let (cw, byte_len) = char_info(line, i);

        // Check if adding this character would exceed width
        if col + cw > width && cw > 0 {
            col = insert_line_break(output, &mut last_space_out_pos, break_at_spaces);
        }

        if break_at_spaces && byte == b' ' {
            last_space_out_pos = Some(output.len());
        }

        output.extend_from_slice(&line[i..i + byte_len]);
        col += cw;
        i += byte_len;
    }
}

/// Recalculate column position for a segment of output (UTF-8 aware).
fn recalc_column(data: &[u8]) -> usize {
    let mut col = 0;
    let mut i = 0;
    while i < data.len() {
        let b = data[i];
        if b == b'\t' {
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
