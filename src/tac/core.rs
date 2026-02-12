use rayon::prelude::*;
use std::io::{self, IoSlice, Write};

/// Maximum number of iovecs per writev() call (Linux IOV_MAX is 1024).
const IOV_BATCH: usize = 1024;

/// Minimum data size for parallel processing.
const PAR_THRESHOLD: usize = 2 * 1024 * 1024;

/// Write all IoSlices to the writer, handling partial writes.
/// For large numbers of slices, batches into IOV_BATCH-sized groups.
fn write_all_slices(out: &mut impl Write, slices: &[IoSlice<'_>]) -> io::Result<()> {
    // Small number of slices: use simple write_all for each
    if slices.len() <= 4 {
        for s in slices {
            out.write_all(s)?;
        }
        return Ok(());
    }

    let mut offset = 0;
    while offset < slices.len() {
        let end = (offset + IOV_BATCH).min(slices.len());
        let n = out.write_vectored(&slices[offset..end])?;
        if n == 0 {
            return Err(io::Error::new(
                io::ErrorKind::WriteZero,
                "failed to write any data",
            ));
        }
        let mut remaining = n;
        while offset < end && remaining >= slices[offset].len() {
            remaining -= slices[offset].len();
            offset += 1;
        }
        if remaining > 0 && offset < end {
            out.write_all(&slices[offset][remaining..])?;
            offset += 1;
        }
    }
    Ok(())
}

/// Reverse records separated by a single byte.
/// Uses forward SIMD scan (memchr_iter) to collect all separator positions,
/// then fills output buffer in reverse order with parallel copy for large data.
/// Single write_all at the end for minimum syscall overhead.
pub fn tac_bytes(data: &[u8], separator: u8, before: bool, out: &mut impl Write) -> io::Result<()> {
    if data.is_empty() {
        return Ok(());
    }

    // Forward SIMD scan: collect all separator positions in one pass.
    // This is faster than memrchr_iter for building the complete positions list
    // because forward scanning has better hardware prefetch behavior.
    let positions: Vec<usize> = memchr::memchr_iter(separator, data).collect();

    if positions.is_empty() {
        return out.write_all(data);
    }

    // Build list of (src_start, src_end) record ranges in reversed output order.
    // This allows us to compute exact output positions for parallel copy.
    let mut records: Vec<(usize, usize)> = Vec::with_capacity(positions.len() + 2);

    if !before {
        // separator-after mode: records end with separator
        let last_sep = *positions.last().unwrap();

        // Trailing content without separator — output first
        if last_sep + 1 < data.len() {
            records.push((last_sep + 1, data.len()));
        }

        // Records in reverse: each record is from (prev_sep+1) to (cur_sep+1)
        for i in (0..positions.len()).rev() {
            let start = if i == 0 { 0 } else { positions[i - 1] + 1 };
            let end = positions[i] + 1;
            records.push((start, end));
        }
    } else {
        // separator-before mode: records start with separator
        for i in (0..positions.len()).rev() {
            let start = positions[i];
            let end = if i + 1 < positions.len() {
                positions[i + 1]
            } else {
                data.len()
            };
            records.push((start, end));
        }

        // Leading content before first separator
        if positions[0] > 0 {
            records.push((0, positions[0]));
        }
    }

    // Compute output offsets (prefix sum of record lengths)
    let mut out_offsets: Vec<usize> = Vec::with_capacity(records.len());
    let mut total = 0usize;
    for &(start, end) in &records {
        out_offsets.push(total);
        total += end - start;
    }

    // Allocate output buffer (no zero-init needed since we'll fill it completely)
    let mut outbuf: Vec<u8> = Vec::with_capacity(total);
    unsafe {
        outbuf.set_len(total);
    }

    // For large data: parallel copy using rayon
    if data.len() >= PAR_THRESHOLD && records.len() > 64 {
        // Use usize to pass addresses across threads (raw ptrs aren't Send)
        let out_base = outbuf.as_mut_ptr() as usize;
        let data_base = data.as_ptr() as usize;
        // SAFETY: Each record writes to a non-overlapping region of outbuf.
        // out_offsets are monotonically increasing and non-overlapping.
        records.par_iter().zip(out_offsets.par_iter()).for_each(
            |(&(src_start, src_end), &dst_offset)| {
                let len = src_end - src_start;
                unsafe {
                    std::ptr::copy_nonoverlapping(
                        (data_base as *const u8).add(src_start),
                        (out_base as *mut u8).add(dst_offset),
                        len,
                    );
                }
            },
        );
    } else {
        // Small data: sequential copy using ptr::copy_nonoverlapping
        let out_ptr: *mut u8 = outbuf.as_mut_ptr();
        let data_ptr: *const u8 = data.as_ptr();
        for (i, &(src_start, src_end)) in records.iter().enumerate() {
            let len = src_end - src_start;
            unsafe {
                std::ptr::copy_nonoverlapping(
                    data_ptr.add(src_start),
                    out_ptr.add(out_offsets[i]),
                    len,
                );
            }
        }
    }

    out.write_all(&outbuf)
}

/// Reverse records using a multi-byte string separator.
/// Uses SIMD-accelerated memmem for substring search + parallel reverse copy.
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
        return out.write_all(data);
    }

    let sep_len = separator.len();

    // Build record ranges in reversed output order
    let mut records: Vec<(usize, usize)> = Vec::with_capacity(positions.len() + 2);

    if !before {
        let last_end = positions.last().unwrap() + sep_len;
        if last_end < data.len() {
            records.push((last_end, data.len()));
        }
        for i in (0..positions.len()).rev() {
            let rec_start = if i == 0 {
                0
            } else {
                positions[i - 1] + sep_len
            };
            records.push((rec_start, positions[i] + sep_len));
        }
    } else {
        for i in (0..positions.len()).rev() {
            let start = positions[i];
            let end = if i + 1 < positions.len() {
                positions[i + 1]
            } else {
                data.len()
            };
            records.push((start, end));
        }
        if positions[0] > 0 {
            records.push((0, positions[0]));
        }
    }

    // Compute output offsets
    let mut out_offsets: Vec<usize> = Vec::with_capacity(records.len());
    let mut total = 0usize;
    for &(start, end) in &records {
        out_offsets.push(total);
        total += end - start;
    }

    // Allocate and fill output buffer
    let mut outbuf: Vec<u8> = Vec::with_capacity(total);
    unsafe {
        outbuf.set_len(total);
    }

    if data.len() >= PAR_THRESHOLD && records.len() > 64 {
        let out_base = outbuf.as_mut_ptr() as usize;
        let data_base = data.as_ptr() as usize;
        records.par_iter().zip(out_offsets.par_iter()).for_each(
            |(&(src_start, src_end), &dst_offset)| {
                let len = src_end - src_start;
                unsafe {
                    std::ptr::copy_nonoverlapping(
                        (data_base as *const u8).add(src_start),
                        (out_base as *mut u8).add(dst_offset),
                        len,
                    );
                }
            },
        );
    } else {
        let out_ptr: *mut u8 = outbuf.as_mut_ptr();
        let data_ptr: *const u8 = data.as_ptr();
        for (i, &(src_start, src_end)) in records.iter().enumerate() {
            let len = src_end - src_start;
            unsafe {
                std::ptr::copy_nonoverlapping(
                    data_ptr.add(src_start),
                    out_ptr.add(out_offsets[i]),
                    len,
                );
            }
        }
    }

    out.write_all(&outbuf)
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
        // We need the LAST match starting position in buf, so we try from the end
        let mut pos = past_end;
        while pos > 0 {
            pos -= 1;
            if let Some(m) = re.find_at(buf, pos) {
                if m.start() == pos {
                    // Match starts at exactly this position — this is the rightmost match start
                    matches.push((m.start(), m.end()));
                    past_end = m.start();
                    found = true;
                    break;
                }
                // Match starts later than pos — skip to before that match
                // No point checking positions between pos and m.start() since
                // find_at already told us the leftmost match from pos starts at m.start()
                // But we need matches that START before m.start(), so continue decrementing
            }
            // If None, there's no match at pos or later, but there might be one earlier
            // (find_at only searches forward from pos)
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

    let re = match regex::bytes::Regex::new(pattern) {
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

    // Small data: contiguous buffer + single write (avoids IoSlice/writev overhead)
    if data.len() < 16 * 1024 * 1024 {
        let mut outbuf = Vec::with_capacity(data.len());

        if !before {
            let last_end = matches.last().unwrap().1;

            if last_end < data.len() {
                outbuf.extend_from_slice(&data[last_end..]);
            }

            let mut i = matches.len();
            while i > 0 {
                i -= 1;
                let rec_start = if i == 0 { 0 } else { matches[i - 1].1 };
                outbuf.extend_from_slice(&data[rec_start..matches[i].1]);
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
                outbuf.extend_from_slice(&data[start..end]);
            }
            if matches[0].0 > 0 {
                outbuf.extend_from_slice(&data[..matches[0].0]);
            }
        }
        return out.write_all(&outbuf);
    }

    // Large data: batched IoSlice/writev for zero-copy output
    let mut batch: Vec<IoSlice<'_>> = Vec::with_capacity(IOV_BATCH);

    if !before {
        let last_end = matches.last().unwrap().1;
        let has_trailing_sep = last_end == data.len();

        if !has_trailing_sep {
            batch.push(IoSlice::new(&data[last_end..]));
        }

        let mut i = matches.len();
        while i > 0 {
            i -= 1;
            let rec_start = if i == 0 { 0 } else { matches[i - 1].1 };
            let rec_end = matches[i].1;
            batch.push(IoSlice::new(&data[rec_start..rec_end]));
            if batch.len() == IOV_BATCH {
                write_all_slices(out, &batch)?;
                batch.clear();
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
            batch.push(IoSlice::new(&data[start..end]));
            if batch.len() == IOV_BATCH {
                write_all_slices(out, &batch)?;
                batch.clear();
            }
        }

        if matches[0].0 > 0 {
            batch.push(IoSlice::new(&data[..matches[0].0]));
        }
    }

    if !batch.is_empty() {
        write_all_slices(out, &batch)?;
    }

    Ok(())
}
