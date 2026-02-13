use std::io::{self, Write};

/// Output buffer for buffered record assembly.
/// 16MB minimizes write() syscall count: ~6 calls for 100MB input,
/// vs ~1000 writev() calls with scattered IoSlices.
const OUT_BUF: usize = 16 * 1024 * 1024;

/// Copy a slice into the output buffer, flushing to the writer when full.
/// Common path (fits in buffer) uses copy_nonoverlapping for zero overhead.
#[inline]
fn emit_slice(out: &mut impl Write, buf: &mut [u8], wp: &mut usize, s: &[u8]) -> io::Result<()> {
    let cap = buf.len();
    if *wp + s.len() <= cap {
        // Fast path: fits in remaining buffer
        unsafe {
            std::ptr::copy_nonoverlapping(s.as_ptr(), buf.as_mut_ptr().add(*wp), s.len());
        }
        *wp += s.len();
        Ok(())
    } else if s.len() > cap {
        // Oversized slice: flush buffer then write directly
        if *wp > 0 {
            out.write_all(&buf[..*wp])?;
            *wp = 0;
        }
        out.write_all(s)
    } else {
        // Buffer full: flush then copy to beginning
        out.write_all(&buf[..*wp])?;
        unsafe {
            std::ptr::copy_nonoverlapping(s.as_ptr(), buf.as_mut_ptr(), s.len());
        }
        *wp = s.len();
        Ok(())
    }
}

/// Reverse records separated by a single byte.
/// Uses backward SIMD scan (memrchr) to find separators from end to start,
/// writing records directly in reverse order without collecting positions.
pub fn tac_bytes(data: &[u8], separator: u8, before: bool, out: &mut impl Write) -> io::Result<()> {
    if data.is_empty() {
        return Ok(());
    }

    if memchr::memchr(separator, data).is_none() {
        return out.write_all(data);
    }

    let buf_size = data.len().min(OUT_BUF);
    let mut buf = vec![0u8; buf_size];
    let mut wp = 0;

    if !before {
        tac_bytes_after(data, separator, out, &mut buf, &mut wp)?;
    } else {
        tac_bytes_before(data, separator, out, &mut buf, &mut wp)?;
    }

    if wp > 0 {
        out.write_all(&buf[..wp])?;
    }
    Ok(())
}

/// Separator-after mode with backward scanning.
/// Each record ends with the separator. Scans from end using memrchr.
fn tac_bytes_after(
    data: &[u8],
    separator: u8,
    out: &mut impl Write,
    buf: &mut [u8],
    wp: &mut usize,
) -> io::Result<()> {
    let mut end = data.len();

    // Handle trailing content (data doesn't end with separator)
    if data[end - 1] != separator {
        // Find last separator — output trailing content first
        match memchr::memrchr(separator, data) {
            Some(pos) => {
                emit_slice(out, buf, wp, &data[pos + 1..end])?;
                end = pos + 1;
            }
            None => unreachable!(), // We verified separator exists above
        }
    }

    // Process records backward. data[end-1] is always a separator.
    while end > 0 {
        if end >= 2 {
            match memchr::memrchr(separator, &data[..end - 1]) {
                Some(pos) => {
                    emit_slice(out, buf, wp, &data[pos + 1..end])?;
                    end = pos + 1;
                }
                None => {
                    // First record: everything from start to current end
                    emit_slice(out, buf, wp, &data[..end])?;
                    end = 0;
                }
            }
        } else {
            // Single byte (a separator)
            emit_slice(out, buf, wp, &data[..end])?;
            end = 0;
        }
    }

    Ok(())
}

/// Separator-before mode with backward scanning.
/// Each record starts with the separator. Scans from end using memrchr.
fn tac_bytes_before(
    data: &[u8],
    separator: u8,
    out: &mut impl Write,
    buf: &mut [u8],
    wp: &mut usize,
) -> io::Result<()> {
    let mut end = data.len();

    while end > 0 {
        match memchr::memrchr(separator, &data[..end]) {
            Some(pos) => {
                emit_slice(out, buf, wp, &data[pos..end])?;
                end = pos;
            }
            None => {
                // Leading content before first separator
                emit_slice(out, buf, wp, &data[..end])?;
                end = 0;
            }
        }
    }

    Ok(())
}

/// Reverse records using a multi-byte string separator.
/// Uses backward SIMD-accelerated memmem for substring search + buffered output.
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

    let rfinder = memchr::memmem::rfind;
    let sep_len = separator.len();

    // Check if separator exists at all
    if memchr::memmem::find(data, separator).is_none() {
        return out.write_all(data);
    }

    let buf_size = data.len().min(OUT_BUF);
    let mut buf = vec![0u8; buf_size];
    let mut wp = 0;

    if !before {
        tac_string_after(data, separator, sep_len, out, &mut buf, &mut wp, rfinder)?;
    } else {
        tac_string_before(data, separator, out, &mut buf, &mut wp, rfinder)?;
    }

    if wp > 0 {
        out.write_all(&buf[..wp])?;
    }
    Ok(())
}

/// String separator after mode with backward scanning.
fn tac_string_after(
    data: &[u8],
    separator: &[u8],
    sep_len: usize,
    out: &mut impl Write,
    buf: &mut [u8],
    wp: &mut usize,
    rfinder: fn(&[u8], &[u8]) -> Option<usize>,
) -> io::Result<()> {
    let mut end = data.len();

    // Handle trailing content (data doesn't end with separator)
    if end < sep_len || &data[end - sep_len..end] != separator {
        match rfinder(data, separator) {
            Some(pos) => {
                let sep_end = pos + sep_len;
                emit_slice(out, buf, wp, &data[sep_end..end])?;
                end = sep_end;
            }
            None => unreachable!(),
        }
    }

    // Process records backward
    while end > 0 {
        if end > sep_len {
            match rfinder(&data[..end - sep_len], separator) {
                Some(pos) => {
                    let rec_start = pos + sep_len;
                    emit_slice(out, buf, wp, &data[rec_start..end])?;
                    end = rec_start;
                }
                None => {
                    emit_slice(out, buf, wp, &data[..end])?;
                    end = 0;
                }
            }
        } else {
            emit_slice(out, buf, wp, &data[..end])?;
            end = 0;
        }
    }

    Ok(())
}

/// String separator before mode with backward scanning.
fn tac_string_before(
    data: &[u8],
    separator: &[u8],
    out: &mut impl Write,
    buf: &mut [u8],
    wp: &mut usize,
    rfinder: fn(&[u8], &[u8]) -> Option<usize>,
) -> io::Result<()> {
    let mut end = data.len();

    while end > 0 {
        match rfinder(&data[..end], separator) {
            Some(pos) => {
                emit_slice(out, buf, wp, &data[pos..end])?;
                end = pos;
            }
            None => {
                emit_slice(out, buf, wp, &data[..end])?;
                end = 0;
            }
        }
    }

    Ok(())
}

/// Find regex matches using backward scanning, matching GNU tac's re_search behavior.
fn find_regex_matches_backward(data: &[u8], re: &regex::bytes::Regex) -> Vec<(usize, usize)> {
    let mut matches = Vec::new();
    let mut past_end = data.len();

    while past_end > 0 {
        let buf = &data[..past_end];
        let mut found = false;

        let mut pos = past_end;
        while pos > 0 {
            pos -= 1;
            if let Some(m) = re.find_at(buf, pos) {
                if m.start() == pos {
                    matches.push((m.start(), m.end()));
                    past_end = m.start();
                    found = true;
                    break;
                }
            }
        }

        if !found {
            break;
        }
    }

    matches.reverse();
    matches
}

/// Reverse records using a regex separator.
pub fn tac_regex_separator(
    data: &[u8],
    pattern: &str,
    before: bool,
    out: &mut impl Write,
) -> io::Result<()> {
    if data.is_empty() {
        return Ok(());
    }

    let re = match regex::bytes::Regex::new(pattern) {
        Ok(r) => r,
        Err(e) => {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                format!("invalid regex '{}': {}", pattern, e),
            ));
        }
    };

    let matches = find_regex_matches_backward(data, &re);

    if matches.is_empty() {
        out.write_all(data)?;
        return Ok(());
    }

    let buf_size = data.len().min(OUT_BUF);
    let mut buf = vec![0u8; buf_size];
    let mut wp = 0;

    if !before {
        let last_end = matches.last().unwrap().1;

        if last_end < data.len() {
            emit_slice(out, &mut buf, &mut wp, &data[last_end..])?;
        }

        let mut i = matches.len();
        while i > 0 {
            i -= 1;
            let rec_start = if i == 0 { 0 } else { matches[i - 1].1 };
            emit_slice(out, &mut buf, &mut wp, &data[rec_start..matches[i].1])?;
        }
    } else {
        let mut i = matches.len();
        while i > 0 {
            i -= 1;
            let start = matches[i].0;
            let end = if i + 1 < matches.len() {
                matches[i + 1].0
            } else {
                data.len()
            };
            emit_slice(out, &mut buf, &mut wp, &data[start..end])?;
        }

        if matches[0].0 > 0 {
            emit_slice(out, &mut buf, &mut wp, &data[..matches[0].0])?;
        }
    }

    if wp > 0 {
        out.write_all(&buf[..wp])?;
    }
    Ok(())
}
