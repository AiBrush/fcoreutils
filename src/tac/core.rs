use std::io::{self, Write};

/// Reverse the records in `data` separated by a single byte `separator` and write to `out`.
/// If `before` is true, the separator is attached before the record instead of after.
/// Uses forward memchr scan for SIMD-accelerated separator finding with optimal prefetch.
pub fn tac_bytes(data: &[u8], separator: u8, before: bool, out: &mut impl Write) -> io::Result<()> {
    if data.is_empty() {
        return Ok(());
    }

    // Forward SIMD scan to collect all separator positions — better prefetch than backward scanning
    let positions: Vec<usize> = memchr::memchr_iter(separator, data).collect();

    if positions.is_empty() {
        out.write_all(data)?;
        return Ok(());
    }

    let mut buf = io::BufWriter::with_capacity(1024 * 1024, out);

    if !before {
        // Default mode: separator is AFTER the record (like newline at end of line)
        let has_trailing_sep = *positions.last().unwrap() == data.len() - 1;

        // Trailing content without separator — GNU tac does NOT add separator
        if !has_trailing_sep {
            let last_sep = *positions.last().unwrap();
            buf.write_all(&data[last_sep + 1..])?;
        }

        // Records in reverse order
        let mut i = positions.len();
        while i > 0 {
            i -= 1;
            let end = positions[i] + 1; // include separator
            let start = if i == 0 { 0 } else { positions[i - 1] + 1 };
            buf.write_all(&data[start..end])?;
        }
    } else {
        // Before mode: separator is BEFORE the record
        // Write records in reverse
        let mut i = positions.len();
        while i > 0 {
            i -= 1;
            let start = positions[i];
            let end = if i + 1 < positions.len() {
                positions[i + 1]
            } else {
                data.len()
            };
            buf.write_all(&data[start..end])?;
        }

        // Leading content before first separator
        if positions[0] > 0 {
            buf.write_all(&data[..positions[0]])?;
        }
    }

    buf.flush()?;
    Ok(())
}

/// Reverse records using a multi-byte string separator.
/// Uses SIMD-accelerated memmem for substring search.
pub fn tac_string_separator(
    data: &[u8],
    separator: &[u8],
    before: bool,
    out: &mut impl Write,
) -> io::Result<()> {
    if data.is_empty() {
        return Ok(());
    }

    if separator.len() == 1 {
        return tac_bytes(data, separator[0], before, out);
    }

    // Find all occurrences of the separator using SIMD-accelerated memmem
    let positions: Vec<usize> = memchr::memmem::find_iter(data, separator).collect();

    if positions.is_empty() {
        out.write_all(data)?;
        return Ok(());
    }

    let sep_len = separator.len();
    let mut buf = io::BufWriter::with_capacity(1024 * 1024, out);

    if !before {
        // Default: separator after record
        let last_end = positions.last().unwrap() + sep_len;
        let has_trailing_sep = last_end == data.len();

        // Trailing chunk without separator — GNU tac does NOT add separator
        if !has_trailing_sep {
            buf.write_all(&data[last_end..])?;
        }

        // Records in reverse
        let mut i = positions.len();
        while i > 0 {
            i -= 1;
            let sep_start = positions[i];
            let rec_start = if i == 0 {
                0
            } else {
                positions[i - 1] + sep_len
            };
            buf.write_all(&data[rec_start..sep_start + sep_len])?;
        }
    } else {
        // Before mode: separator before record
        let mut i = positions.len();
        while i > 0 {
            i -= 1;
            let start = positions[i];
            let end = if i + 1 < positions.len() {
                positions[i + 1]
            } else {
                data.len()
            };
            buf.write_all(&data[start..end])?;
        }

        if positions[0] > 0 {
            buf.write_all(&data[..positions[0]])?;
        }
    }

    buf.flush()?;
    Ok(())
}

/// Convert a POSIX Basic Regular Expression (BRE) pattern to an Extended Regular Expression (ERE)
/// compatible with Rust's regex crate.
///
/// In BRE: `+`, `?`, `{`, `}`, `(`, `)`, `|` are literal characters.
/// Their escaped forms `\+`, `\?`, `\{`, `\}`, `\(`, `\)`, `\|` are special.
/// In ERE/Rust regex: the unescaped forms are special.
fn bre_to_ere(pattern: &str) -> String {
    let bytes = pattern.as_bytes();
    let mut result = Vec::with_capacity(bytes.len() + 16);
    let mut i = 0;

    while i < bytes.len() {
        if bytes[i] == b'\\' && i + 1 < bytes.len() {
            match bytes[i + 1] {
                // BRE escaped specials → ERE unescaped specials
                b'+' | b'?' | b'{' | b'}' | b'(' | b')' | b'|' => {
                    result.push(bytes[i + 1]);
                    i += 2;
                }
                // BRE \1-\9 backreferences → same in ERE
                b'1'..=b'9' => {
                    result.push(b'\\');
                    result.push(bytes[i + 1]);
                    i += 2;
                }
                // Other escaped chars pass through
                _ => {
                    result.push(b'\\');
                    result.push(bytes[i + 1]);
                    i += 2;
                }
            }
        } else {
            match bytes[i] {
                // BRE literal chars that are special in ERE → escape them
                b'+' | b'?' | b'{' | b'}' | b'(' | b')' | b'|' => {
                    result.push(b'\\');
                    result.push(bytes[i]);
                    i += 1;
                }
                _ => {
                    result.push(bytes[i]);
                    i += 1;
                }
            }
        }
    }

    // SAFETY: We only manipulate ASCII bytes and pass through non-ASCII unchanged
    String::from_utf8(result).unwrap_or_else(|_| pattern.to_string())
}

/// Find regex matches using backward scanning, matching GNU tac's re_search behavior.
/// GNU tac scans backward from the end, finding the rightmost starting position first.
/// This produces different matches than forward scanning for patterns like [0-9]+.
/// The matches are returned in left-to-right order.
fn find_regex_matches_backward(data: &[u8], re: &regex::bytes::Regex) -> Vec<(usize, usize)> {
    let mut matches = Vec::new();
    let mut past_end = data.len();

    while past_end > 0 {
        let buf = &data[..past_end];
        let mut found = false;

        // Scan backward: try positions from past_end-1 down to 0
        let mut pos = past_end;
        while pos > 0 {
            pos -= 1;
            if let Some(m) = re.find_at(buf, pos) {
                if m.start() == pos {
                    // Match starts at exactly this position
                    matches.push((m.start(), m.end()));
                    past_end = m.start();
                    found = true;
                    break;
                }
                // Match starts later than pos — no match at this position, try earlier
            } else {
                // No match at or after pos in this buffer — no matches remain
                break;
            }
        }

        if !found {
            break;
        }
    }

    matches.reverse(); // Convert from backward order to left-to-right order
    matches
}

/// Reverse records using a regex separator.
/// Uses regex::bytes for direct byte-level matching (no UTF-8 conversion needed).
/// NOTE: GNU tac uses POSIX Basic Regular Expressions (BRE), so we convert to ERE first.
/// Uses backward scanning to match GNU tac's re_search behavior.
pub fn tac_regex_separator(
    data: &[u8],
    pattern: &str,
    before: bool,
    out: &mut impl Write,
) -> io::Result<()> {
    if data.is_empty() {
        return Ok(());
    }

    let ere_pattern = bre_to_ere(pattern);
    let re = match regex::bytes::Regex::new(&ere_pattern) {
        Ok(r) => r,
        Err(e) => {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                format!("invalid regex '{}': {}", pattern, e),
            ));
        }
    };

    // Use backward scanning to match GNU tac's re_search behavior
    let matches = find_regex_matches_backward(data, &re);

    if matches.is_empty() {
        out.write_all(data)?;
        return Ok(());
    }

    let mut buf = io::BufWriter::with_capacity(1024 * 1024, out);

    if !before {
        let last_end = matches.last().unwrap().1;
        let has_trailing_sep = last_end == data.len();

        // Trailing content after last separator — GNU tac does NOT add separator
        if !has_trailing_sep {
            buf.write_all(&data[last_end..])?;
        }

        // Records in reverse: each record = text + separator
        let mut i = matches.len();
        while i > 0 {
            i -= 1;
            let rec_start = if i == 0 { 0 } else { matches[i - 1].1 };
            let rec_end = matches[i].1;
            buf.write_all(&data[rec_start..rec_end])?;
        }
    } else {
        // Before mode: separator before record
        let mut i = matches.len();
        while i > 0 {
            i -= 1;
            let start = matches[i].0;
            let end = if i + 1 < matches.len() {
                matches[i + 1].0
            } else {
                data.len()
            };
            buf.write_all(&data[start..end])?;
        }

        if matches[0].0 > 0 {
            buf.write_all(&data[..matches[0].0])?;
        }
    }

    buf.flush()?;
    Ok(())
}
