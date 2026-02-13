use std::io::{self, IoSlice, Write};

/// Max IoSlice entries per write_vectored batch.
/// Linux UIO_MAXIOV is 1024; we use that as our batch limit.
const MAX_IOV: usize = 1024;

/// Flush a batch of IoSlice entries using write_vectored.
/// Falls back to individual write_all for each slice if write_vectored
/// doesn't write everything (handles partial writes).
#[inline]
fn flush_iov(out: &mut impl Write, slices: &[IoSlice]) -> io::Result<()> {
    if slices.is_empty() {
        return Ok(());
    }
    // Try write_vectored first for the whole batch
    let total: usize = slices.iter().map(|s| s.len()).sum();

    // Fast path: single writev call often writes everything
    let written = match out.write_vectored(slices) {
        Ok(n) if n >= total => return Ok(()),
        Ok(n) => n,
        Err(e) => return Err(e),
    };

    // Slow path: partial write — fall back to write_all per remaining slice
    let mut skip = written;
    for slice in slices {
        let slen = slice.len();
        if skip >= slen {
            skip -= slen;
            continue;
        }
        if skip > 0 {
            out.write_all(&slice[skip..])?;
            skip = 0;
        } else {
            out.write_all(slice)?;
        }
    }
    Ok(())
}

/// Reverse records separated by a single byte.
/// Uses backward SIMD scan (memrchr) — zero Vec allocation, single pass.
/// Output uses write_vectored (writev) for zero-copy from mmap'd data.
pub fn tac_bytes(data: &[u8], separator: u8, before: bool, out: &mut impl Write) -> io::Result<()> {
    if data.is_empty() {
        return Ok(());
    }
    if !before {
        tac_bytes_backward_after(data, separator, out)
    } else {
        tac_bytes_backward_before(data, separator, out)
    }
}

/// After-separator mode: backward scan with memrchr.
/// Each record includes its trailing separator byte.
/// Uses IoSlice batching for zero-copy output directly from mmap'd data.
///
/// Pre-counts separators with SIMD-accelerated memchr_iter to right-size
/// the IoSlice Vec, avoiding reallocations for files with many lines.
fn tac_bytes_backward_after(data: &[u8], sep: u8, out: &mut impl Write) -> io::Result<()> {
    // Pre-count separators with SIMD (memchr at 30+ GB/s) to right-size IoSlice Vec.
    // For a 100MB file with 10M lines, this avoids many Vec reallocations.
    let sep_count = memchr::memchr_iter(sep, data).count();
    if sep_count == 0 {
        return out.write_all(data);
    }

    // +1 for the first record (before first separator), +1 for possible trailing content
    let mut iov: Vec<IoSlice> = Vec::with_capacity((sep_count + 2).min(MAX_IOV));

    let mut end = data.len();

    let Some(mut pos) = memchr::memrchr(sep, data) else {
        // Should not happen since sep_count > 0, but handle gracefully
        return out.write_all(data);
    };

    // Trailing content after last separator
    if pos + 1 < end {
        iov.push(IoSlice::new(&data[pos + 1..end]));
    }
    end = pos + 1;

    // Scan backward for remaining separators
    while pos > 0 {
        match memchr::memrchr(sep, &data[..pos]) {
            Some(prev) => {
                iov.push(IoSlice::new(&data[prev + 1..end]));
                if iov.len() >= MAX_IOV {
                    flush_iov(out, &iov)?;
                    iov.clear();
                }
                end = prev + 1;
                pos = prev;
            }
            None => break,
        }
    }

    // First record (from start of data)
    iov.push(IoSlice::new(&data[0..end]));
    flush_iov(out, &iov)?;

    Ok(())
}

/// Before-separator mode: backward scan with memrchr.
/// Each record starts with its separator byte.
/// Uses IoSlice batching for zero-copy output.
///
/// Pre-counts separators with SIMD-accelerated memchr_iter to right-size
/// the IoSlice Vec.
fn tac_bytes_backward_before(data: &[u8], sep: u8, out: &mut impl Write) -> io::Result<()> {
    // Pre-count separators with SIMD to right-size IoSlice Vec.
    let sep_count = memchr::memchr_iter(sep, data).count();
    if sep_count == 0 {
        return out.write_all(data);
    }

    // +1 for possible leading content before first separator
    let mut iov: Vec<IoSlice> = Vec::with_capacity((sep_count + 1).min(MAX_IOV));

    let mut end = data.len();

    let Some(pos) = memchr::memrchr(sep, data) else {
        // Should not happen since sep_count > 0, but handle gracefully
        return out.write_all(data);
    };

    // Last record: from last separator to end
    iov.push(IoSlice::new(&data[pos..end]));
    end = pos;

    // Scan backward
    while end > 0 {
        match memchr::memrchr(sep, &data[..end]) {
            Some(prev) => {
                iov.push(IoSlice::new(&data[prev..end]));
                if iov.len() >= MAX_IOV {
                    flush_iov(out, &iov)?;
                    iov.clear();
                }
                end = prev;
            }
            None => break,
        }
    }

    // Leading content before first separator
    if end > 0 {
        iov.push(IoSlice::new(&data[0..end]));
    }

    flush_iov(out, &iov)?;
    Ok(())
}

/// Reverse records using a multi-byte string separator.
/// Uses backward SIMD-accelerated memmem (FinderRev) + IoSlice zero-copy output.
///
/// For single-byte separators, delegates to tac_bytes which uses memchr (faster).
/// Pre-counts separators to right-size the IoSlice Vec.
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

    let sep_len = separator.len();
    let finder = memchr::memmem::FinderRev::new(separator);

    // Pre-count separators for right-sized IoSlice Vec.
    // Use forward Finder for counting (more cache-friendly than backward scan).
    let sep_count = memchr::memmem::find_iter(data, separator).count();
    if sep_count == 0 {
        return out.write_all(data);
    }

    let mut iov: Vec<IoSlice> = Vec::with_capacity((sep_count + 2).min(MAX_IOV));

    if !before {
        let mut end = data.len();

        let Some(mut pos) = finder.rfind(data) else {
            // Should not happen since sep_count > 0
            return out.write_all(data);
        };

        // Trailing content after last separator
        if pos + sep_len < end {
            iov.push(IoSlice::new(&data[pos + sep_len..end]));
        }
        end = pos + sep_len;

        // Scan backward
        while pos > 0 {
            match finder.rfind(&data[..pos]) {
                Some(prev) => {
                    iov.push(IoSlice::new(&data[prev + sep_len..end]));
                    if iov.len() >= MAX_IOV {
                        flush_iov(out, &iov)?;
                        iov.clear();
                    }
                    end = prev + sep_len;
                    pos = prev;
                }
                None => break,
            }
        }

        // First record
        iov.push(IoSlice::new(&data[0..end]));
    } else {
        let mut end = data.len();

        let Some(pos) = finder.rfind(data) else {
            // Should not happen since sep_count > 0
            return out.write_all(data);
        };

        // Last record: from last separator to end
        iov.push(IoSlice::new(&data[pos..end]));
        end = pos;

        // Scan backward
        while end > 0 {
            match finder.rfind(&data[..end]) {
                Some(prev) => {
                    iov.push(IoSlice::new(&data[prev..end]));
                    if iov.len() >= MAX_IOV {
                        flush_iov(out, &iov)?;
                        iov.clear();
                    }
                    end = prev;
                }
                None => break,
            }
        }

        // Leading content before first separator
        if end > 0 {
            iov.push(IoSlice::new(&data[0..end]));
        }
    }

    flush_iov(out, &iov)?;
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

    let mut iov: Vec<IoSlice> = Vec::with_capacity(matches.len().min(MAX_IOV) + 2);

    if !before {
        let last_end = matches.last().unwrap().1;

        if last_end < data.len() {
            iov.push(IoSlice::new(&data[last_end..]));
        }

        let mut i = matches.len();
        while i > 0 {
            i -= 1;
            let rec_start = if i == 0 { 0 } else { matches[i - 1].1 };
            iov.push(IoSlice::new(&data[rec_start..matches[i].1]));
            if iov.len() >= MAX_IOV {
                flush_iov(out, &iov)?;
                iov.clear();
            }
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
            iov.push(IoSlice::new(&data[start..end]));
            if iov.len() >= MAX_IOV {
                flush_iov(out, &iov)?;
                iov.clear();
            }
        }

        if matches[0].0 > 0 {
            iov.push(IoSlice::new(&data[..matches[0].0]));
        }
    }

    flush_iov(out, &iov)?;
    Ok(())
}
