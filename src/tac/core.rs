use std::io::{self, IoSlice, Write};

/// Threshold for parallel position finding (4MB).
/// Thread spawn overhead (~50μs) and position Vec allocation hurt for small files.
/// For 1MB with ~25K lines, sequential memrchr_iter takes ~0.1ms; parallel
/// overhead adds ~100μs for no benefit. Parallel pays off at 4MB+.
const PARALLEL_THRESHOLD: usize = 4 * 1024 * 1024;

/// Reverse records separated by a single byte.
/// Uses zero-copy writev output: IoSlice entries point directly into
/// the input buffer, eliminating output buffer allocation and memcpy.
/// For large data (>= 512KB), uses parallel memchr via std::thread::scope
/// (avoids rayon's ~300µs thread pool init overhead per process).
pub fn tac_bytes(data: &[u8], separator: u8, before: bool, out: &mut impl Write) -> io::Result<()> {
    if data.is_empty() {
        return Ok(());
    }
    if data.len() >= PARALLEL_THRESHOLD {
        if !before {
            tac_bytes_after_parallel(data, separator, out)
        } else {
            tac_bytes_before_parallel(data, separator, out)
        }
    } else if !before {
        tac_bytes_after(data, separator, out)
    } else {
        tac_bytes_before(data, separator, out)
    }
}

/// Reverse records of an owned Vec. Delegates to tac_bytes.
pub fn tac_bytes_owned(
    data: &mut [u8],
    separator: u8,
    before: bool,
    out: &mut impl Write,
) -> io::Result<()> {
    tac_bytes(data, separator, before, out)
}

/// Collect multi-byte separator positions with pre-allocated Vec.
#[inline]
fn collect_positions_str(data: &[u8], separator: &[u8]) -> Vec<usize> {
    let estimated = data.len() / 40 + 64;
    let mut positions = Vec::with_capacity(estimated);
    for pos in memchr::memmem::find_iter(data, separator) {
        positions.push(pos);
    }
    positions
}

/// Find separator positions in parallel using std::thread::scope.
/// Returns per-chunk position arrays in forward order (chunk 0, 1, ..., N-1).
/// Each chunk's positions are globally indexed (not chunk-relative).
/// Uses lightweight OS threads instead of rayon to avoid ~300µs thread pool init.
/// Parallel position finding using memrchr_iter (reverse scan).
/// Positions within each chunk are stored in reverse order (end-of-chunk first).
/// This way the output phase can iterate forward (cache-friendly sequential access)
/// instead of backward through the position Vecs.
/// For 100MB with ~2.5M positions (~20MB of position data), forward iteration
/// enables L2 hardware prefetching, reducing access latency from ~35ns to ~5ns.
fn parallel_find_positions(data: &[u8], sep: u8) -> Vec<Vec<usize>> {
    let num_threads = std::thread::available_parallelism()
        .map(|n| n.get())
        .unwrap_or(4)
        .min(data.len() / (256 * 1024)) // At least 256KB per thread
        .max(2); // Always at least 2 for parallel benefit

    let chunk_size = data.len() / num_threads;

    std::thread::scope(|s| {
        let handles: Vec<_> = (0..num_threads)
            .map(|i| {
                let start = i * chunk_size;
                let end = if i + 1 == num_threads {
                    data.len()
                } else {
                    (i + 1) * chunk_size
                };
                s.spawn(move || {
                    let chunk = &data[start..end];
                    let estimated = chunk.len() / 40 + 64;
                    let mut positions = Vec::with_capacity(estimated);
                    // memrchr_iter scans backward, so positions are stored in
                    // reverse order (last separator in chunk first). This matches
                    // the output order (end of file first) for forward iteration.
                    for p in memchr::memrchr_iter(sep, chunk) {
                        positions.push(start + p);
                    }
                    positions
                })
            })
            .collect();

        handles.into_iter().map(|h| h.join().unwrap()).collect()
    })
}

/// After-separator mode for small data: backward memrchr scan + writev.
/// Uses memrchr_iter to scan positions right-to-left, building IoSlice
/// entries on-the-fly without an intermediate position Vec.
/// Zero-copy: all output points directly into the input buffer.
fn tac_bytes_after(data: &[u8], sep: u8, out: &mut impl Write) -> io::Result<()> {
    const BATCH: usize = 1024;
    let mut slices: Vec<IoSlice<'_>> = Vec::with_capacity(BATCH);
    let mut end = data.len();
    let mut found_any = false;

    for pos in memchr::memrchr_iter(sep, data) {
        found_any = true;
        let rec_start = pos + 1;
        if rec_start < end {
            slices.push(IoSlice::new(&data[rec_start..end]));
            if slices.len() >= BATCH {
                write_all_vectored(out, &slices)?;
                slices.clear();
            }
        }
        end = rec_start;
    }

    if !found_any {
        return out.write_all(data);
    }

    // Remaining prefix before the first separator
    if end > 0 {
        slices.push(IoSlice::new(&data[..end]));
    }
    if !slices.is_empty() {
        write_all_vectored(out, &slices)?;
    }

    Ok(())
}

/// Before-separator mode for small data: backward memrchr scan + writev.
fn tac_bytes_before(data: &[u8], sep: u8, out: &mut impl Write) -> io::Result<()> {
    const BATCH: usize = 1024;
    let mut slices: Vec<IoSlice<'_>> = Vec::with_capacity(BATCH);
    let mut end = data.len();
    let mut found_any = false;

    for pos in memchr::memrchr_iter(sep, data) {
        found_any = true;
        if pos < end {
            slices.push(IoSlice::new(&data[pos..end]));
            if slices.len() >= BATCH {
                write_all_vectored(out, &slices)?;
                slices.clear();
            }
        }
        end = pos;
    }

    if !found_any {
        return out.write_all(data);
    }

    if end > 0 {
        slices.push(IoSlice::new(&data[..end]));
    }
    if !slices.is_empty() {
        write_all_vectored(out, &slices)?;
    }

    Ok(())
}

/// Parallel after-separator mode: parallel forward memchr + zero-copy writev.
/// Phase 1: Find separator positions in parallel via thread::scope.
/// Phase 2: Iterate positions from last chunk to first, building IoSlice
/// entries pointing directly into the input buffer. No output buffer needed.
///
/// vs previous contiguous buffer approach:
/// - Eliminates N-byte output buffer allocation (10MB → 0 for 10MB file)
/// - Eliminates N-byte memcpy for reverse-copy (saves ~1ms per 10MB)
/// - Uses std::thread::scope instead of rayon (saves ~300µs thread pool init)
fn tac_bytes_after_parallel(data: &[u8], sep: u8, out: &mut impl Write) -> io::Result<()> {
    let chunk_positions = parallel_find_positions(data, sep);

    // Check if no separators found in any chunk
    if chunk_positions.iter().all(|v| v.is_empty()) {
        return out.write_all(data);
    }

    const BATCH: usize = 1024;
    let mut slices: Vec<IoSlice<'_>> = Vec::with_capacity(BATCH);
    let mut end = data.len();

    // Process chunks from last to first. Within each chunk, positions are already
    // in reverse order (from memrchr_iter), so iterate forward for cache-friendly access.
    for positions in chunk_positions.iter().rev() {
        for &pos in positions.iter() {
            let rec_start = pos + 1;
            if rec_start < end {
                slices.push(IoSlice::new(&data[rec_start..end]));
                if slices.len() >= BATCH {
                    write_all_vectored(out, &slices)?;
                    slices.clear();
                }
            }
            end = rec_start;
        }
    }

    // Remaining prefix before the first separator
    if end > 0 {
        slices.push(IoSlice::new(&data[..end]));
    }
    if !slices.is_empty() {
        write_all_vectored(out, &slices)?;
    }

    Ok(())
}

/// Parallel before-separator mode: parallel forward memchr + zero-copy writev.
fn tac_bytes_before_parallel(data: &[u8], sep: u8, out: &mut impl Write) -> io::Result<()> {
    let chunk_positions = parallel_find_positions(data, sep);

    if chunk_positions.iter().all(|v| v.is_empty()) {
        return out.write_all(data);
    }

    const BATCH: usize = 1024;
    let mut slices: Vec<IoSlice<'_>> = Vec::with_capacity(BATCH);
    let mut end = data.len();

    for positions in chunk_positions.iter().rev() {
        for &pos in positions.iter() {
            if pos < end {
                slices.push(IoSlice::new(&data[pos..end]));
                if slices.len() >= BATCH {
                    write_all_vectored(out, &slices)?;
                    slices.clear();
                }
            }
            end = pos;
        }
    }

    if end > 0 {
        slices.push(IoSlice::new(&data[..end]));
    }
    if !slices.is_empty() {
        write_all_vectored(out, &slices)?;
    }

    Ok(())
}

/// Reverse records using a multi-byte string separator.
/// Uses SIMD-accelerated memmem + write_all output.
///
/// For single-byte separators, delegates to tac_bytes which uses memchr (faster).
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

    if !before {
        tac_string_after(data, separator, sep_len, out)
    } else {
        tac_string_before(data, separator, sep_len, out)
    }
}

/// Multi-byte string separator, after mode. Uses writev batching.
fn tac_string_after(
    data: &[u8],
    separator: &[u8],
    sep_len: usize,
    out: &mut impl Write,
) -> io::Result<()> {
    let positions = collect_positions_str(data, separator);

    if positions.is_empty() {
        return out.write_all(data);
    }

    const BATCH: usize = 1024;
    let mut slices: Vec<IoSlice<'_>> = Vec::with_capacity(BATCH);
    let mut end = data.len();

    for &pos in positions.iter().rev() {
        let rec_start = pos + sep_len;
        if rec_start < end {
            slices.push(IoSlice::new(&data[rec_start..end]));
            if slices.len() >= BATCH {
                write_all_vectored(out, &slices)?;
                slices.clear();
            }
        }
        end = rec_start;
    }
    if end > 0 {
        slices.push(IoSlice::new(&data[..end]));
    }
    if !slices.is_empty() {
        write_all_vectored(out, &slices)?;
    }
    Ok(())
}

/// Multi-byte string separator, before mode. Uses writev batching.
fn tac_string_before(
    data: &[u8],
    separator: &[u8],
    _sep_len: usize,
    out: &mut impl Write,
) -> io::Result<()> {
    let positions = collect_positions_str(data, separator);

    if positions.is_empty() {
        return out.write_all(data);
    }

    const BATCH: usize = 1024;
    let mut slices: Vec<IoSlice<'_>> = Vec::with_capacity(BATCH);
    let mut end = data.len();

    for &pos in positions.iter().rev() {
        if pos < end {
            slices.push(IoSlice::new(&data[pos..end]));
            if slices.len() >= BATCH {
                write_all_vectored(out, &slices)?;
                slices.clear();
            }
        }
        end = pos;
    }
    if end > 0 {
        slices.push(IoSlice::new(&data[..end]));
    }
    if !slices.is_empty() {
        write_all_vectored(out, &slices)?;
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
/// Uses write_vectored for regex path (typically few large records).
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

    // For regex separators, use write_vectored since there are typically
    // few large records. Build all IoSlices at once and flush.
    let mut slices: Vec<IoSlice<'_>> = Vec::with_capacity(matches.len() + 2);

    if !before {
        let last_end = matches.last().unwrap().1;

        if last_end < data.len() {
            slices.push(IoSlice::new(&data[last_end..]));
        }

        let mut i = matches.len();
        while i > 0 {
            i -= 1;
            let rec_start = if i == 0 { 0 } else { matches[i - 1].1 };
            slices.push(IoSlice::new(&data[rec_start..matches[i].1]));
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
            slices.push(IoSlice::new(&data[start..end]));
        }

        if matches[0].0 > 0 {
            slices.push(IoSlice::new(&data[..matches[0].0]));
        }
    }

    write_all_vectored(out, &slices)
}

/// Write all IoSlices, handling partial writes.
#[inline]
fn write_all_vectored(out: &mut impl Write, slices: &[IoSlice<'_>]) -> io::Result<()> {
    if slices.is_empty() {
        return Ok(());
    }

    let written = out.write_vectored(slices)?;
    if written == 0 && slices.iter().any(|s| !s.is_empty()) {
        return Err(io::Error::new(io::ErrorKind::WriteZero, "write zero"));
    }

    let total: usize = slices.iter().map(|s| s.len()).sum();
    if written >= total {
        return Ok(());
    }

    // Partial write: skip past fully-written slices, then write_all the rest
    let mut skip = written;
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
