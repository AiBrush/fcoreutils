use std::io::{self, IoSlice, Write};

const IOSLICE_BATCH_SIZE: usize = 1024;

/// Reverse records separated by a single byte.
/// Uses forward SIMD memchr scan + streaming output.
pub fn tac_bytes(data: &[u8], separator: u8, before: bool, out: &mut impl Write) -> io::Result<()> {
    if data.is_empty() {
        return Ok(());
    }
    if !before {
        tac_bytes_after(data, separator, out)
    } else {
        tac_bytes_before(data, separator, out)
    }
}

/// Stream reversed byte-separated records directly to an fd using writev zero-copy.
/// Processes data in ~1MB chunks to keep positions Vec in L2 cache and reduce
/// page faults. Records are written directly from the source buffer without copying.
#[cfg(unix)]
pub fn tac_bytes_to_fd(data: &[u8], separator: u8, before: bool, fd: i32) -> io::Result<()> {
    if data.is_empty() {
        return Ok(());
    }
    if !before {
        tac_bytes_after_fd(data, separator, fd)
    } else {
        tac_bytes_before_fd(data, separator, fd)
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
    let mut positions = Vec::with_capacity(data.len() / 40 + 64);
    for pos in memchr::memmem::find_iter(data, separator) {
        positions.push(pos);
    }
    positions
}

/// After-separator mode: forward SIMD scan + streaming 2MB output buffer.
fn tac_bytes_after(data: &[u8], sep: u8, out: &mut impl Write) -> io::Result<()> {
    let mut positions: Vec<usize> = Vec::with_capacity(data.len() / 40 + 64);
    for pos in memchr::memchr_iter(sep, data) {
        positions.push(pos);
    }
    if positions.is_empty() {
        return out.write_all(data);
    }
    const BUF_SIZE: usize = 2 * 1024 * 1024;
    let mut buf: Vec<u8> = Vec::with_capacity(BUF_SIZE);
    let mut end_pos = data.len();
    for &pos in positions.iter().rev() {
        let rec_start = pos + 1;
        if rec_start < end_pos {
            let record = &data[rec_start..end_pos];
            if buf.len() + record.len() > BUF_SIZE {
                out.write_all(&buf)?;
                buf.clear();
            }
            buf.extend_from_slice(record);
        }
        end_pos = rec_start;
    }
    if end_pos > 0 {
        let record = &data[..end_pos];
        if buf.len() + record.len() > BUF_SIZE {
            out.write_all(&buf)?;
            buf.clear();
        }
        buf.extend_from_slice(record);
    }
    if !buf.is_empty() {
        out.write_all(&buf)?;
    }
    Ok(())
}

/// Before-separator mode: forward SIMD scan + streaming 2MB output buffer.
fn tac_bytes_before(data: &[u8], sep: u8, out: &mut impl Write) -> io::Result<()> {
    let mut positions: Vec<usize> = Vec::with_capacity(data.len() / 40 + 64);
    for pos in memchr::memchr_iter(sep, data) {
        positions.push(pos);
    }
    if positions.is_empty() {
        return out.write_all(data);
    }
    const BUF_SIZE: usize = 2 * 1024 * 1024;
    let mut buf: Vec<u8> = Vec::with_capacity(BUF_SIZE);
    let mut end_pos = data.len();
    for &pos in positions.iter().rev() {
        if pos < end_pos {
            let record = &data[pos..end_pos];
            if buf.len() + record.len() > BUF_SIZE {
                out.write_all(&buf)?;
                buf.clear();
            }
            buf.extend_from_slice(record);
        }
        end_pos = pos;
    }
    if end_pos > 0 {
        let record = &data[..end_pos];
        if buf.len() + record.len() > BUF_SIZE {
            out.write_all(&buf)?;
            buf.clear();
        }
        buf.extend_from_slice(record);
    }
    if !buf.is_empty() {
        out.write_all(&buf)?;
    }
    Ok(())
}

/// Write buffer to a file descriptor, retrying on partial/interrupted writes.
#[cfg(unix)]
#[inline]
fn write_all_fd(fd: i32, data: &[u8]) -> io::Result<()> {
    let mut written = 0;
    while written < data.len() {
        let ret = unsafe {
            libc::write(
                fd,
                data[written..].as_ptr() as *const libc::c_void,
                (data.len() - written) as _,
            )
        };
        if ret > 0 {
            written += ret as usize;
        } else if ret == 0 {
            return Err(io::Error::new(io::ErrorKind::WriteZero, "write returned 0"));
        } else {
            let err = io::Error::last_os_error();
            if err.kind() == io::ErrorKind::Interrupted {
                continue;
            }
            return Err(err);
        }
    }
    Ok(())
}

/// Write iovec batch to fd via writev, then clear the vec for reuse.
#[cfg(unix)]
#[inline]
fn writev_all_fd(fd: i32, iovecs: &mut Vec<libc::iovec>) -> io::Result<()> {
    if iovecs.is_empty() {
        return Ok(());
    }
    let mut idx: usize = 0;
    let mut partial_off: usize = 0;
    while idx < iovecs.len() {
        if partial_off > 0 {
            iovecs[idx].iov_base =
                unsafe { (iovecs[idx].iov_base as *const u8).add(partial_off) } as *mut _;
            iovecs[idx].iov_len -= partial_off;
            partial_off = 0;
        }
        let cnt = (iovecs.len() - idx).min(1024) as i32;
        let ret = unsafe { libc::writev(fd, iovecs[idx..].as_ptr(), cnt) };
        if ret > 0 {
            let mut n = ret as usize;
            while n > 0 && idx < iovecs.len() {
                if n >= iovecs[idx].iov_len {
                    n -= iovecs[idx].iov_len;
                    idx += 1;
                } else {
                    partial_off = n;
                    n = 0;
                }
            }
        } else if ret == 0 {
            iovecs.clear();
            return Err(io::Error::new(
                io::ErrorKind::WriteZero,
                "writev returned 0",
            ));
        } else {
            let err = io::Error::last_os_error();
            if err.kind() == io::ErrorKind::Interrupted {
                continue;
            }
            iovecs.clear();
            return Err(err);
        }
    }
    iovecs.clear();
    Ok(())
}

/// After-separator: chunked forward SIMD scan + writev zero-copy from source buffer.
///
/// Processes data in ~1MB chunks (aligned to separator boundaries) to keep the
/// positions Vec in L2 cache. Records are written directly from the source buffer
/// via writev, eliminating all data copying. Reuses positions and iovecs Vecs
/// across chunks.
#[cfg(unix)]
fn tac_bytes_after_fd(data: &[u8], sep: u8, fd: i32) -> io::Result<()> {
    const CHUNK_SIZE: usize = 1024 * 1024;
    const BATCH: usize = 1024;

    // For small data, single-pass is optimal
    if data.len() <= CHUNK_SIZE {
        let mut positions: Vec<u32> = Vec::with_capacity(data.len() / 40 + 64);
        for pos in memchr::memchr_iter(sep, data) {
            positions.push(pos as u32);
        }
        if positions.is_empty() {
            return write_all_fd(fd, data);
        }
        let mut iovecs: Vec<libc::iovec> = Vec::with_capacity(BATCH);
        let mut end_pos = data.len();
        for &pos in positions.iter().rev() {
            let rec_start = pos as usize + 1;
            if rec_start < end_pos {
                iovecs.push(libc::iovec {
                    iov_base: data[rec_start..].as_ptr() as *mut libc::c_void,
                    iov_len: end_pos - rec_start,
                });
                if iovecs.len() >= BATCH {
                    writev_all_fd(fd, &mut iovecs)?;
                }
            }
            end_pos = rec_start;
        }
        if end_pos > 0 {
            iovecs.push(libc::iovec {
                iov_base: data.as_ptr() as *mut libc::c_void,
                iov_len: end_pos,
            });
        }
        if !iovecs.is_empty() {
            writev_all_fd(fd, &mut iovecs)?;
        }
        return Ok(());
    }

    // Large data: find chunk boundaries at separator positions
    let mut chunk_bounds: Vec<usize> = Vec::new();
    chunk_bounds.push(data.len());
    let mut target = data.len().saturating_sub(CHUNK_SIZE);
    while target > 0 {
        if let Some(offset) = memchr::memchr(sep, &data[target..]) {
            let boundary = target + offset + 1;
            if boundary < *chunk_bounds.last().unwrap() {
                chunk_bounds.push(boundary);
            }
        }
        target = target.saturating_sub(CHUNK_SIZE);
    }
    chunk_bounds.push(0);
    chunk_bounds.reverse();

    // Reusable buffers across chunks
    let mut positions: Vec<u32> = Vec::with_capacity(CHUNK_SIZE / 40 + 64);
    let mut iovecs: Vec<libc::iovec> = Vec::with_capacity(BATCH);

    for ci in (0..chunk_bounds.len() - 1).rev() {
        let chunk_start = chunk_bounds[ci];
        let chunk_end = chunk_bounds[ci + 1];
        let chunk = &data[chunk_start..chunk_end];
        if chunk.is_empty() {
            continue;
        }
        positions.clear();
        for pos in memchr::memchr_iter(sep, chunk) {
            positions.push(pos as u32);
        }
        let mut end_pos = chunk.len();
        for &pos in positions.iter().rev() {
            let rec_start = pos as usize + 1;
            if rec_start < end_pos {
                iovecs.push(libc::iovec {
                    iov_base: chunk[rec_start..].as_ptr() as *mut libc::c_void,
                    iov_len: end_pos - rec_start,
                });
                if iovecs.len() >= BATCH {
                    writev_all_fd(fd, &mut iovecs)?;
                }
            }
            end_pos = rec_start;
        }
        if end_pos > 0 {
            iovecs.push(libc::iovec {
                iov_base: chunk.as_ptr() as *mut libc::c_void,
                iov_len: end_pos,
            });
        }
        if !iovecs.is_empty() {
            writev_all_fd(fd, &mut iovecs)?;
        }
    }
    Ok(())
}

/// Before-separator: chunked forward SIMD scan + writev zero-copy from source buffer.
#[cfg(unix)]
fn tac_bytes_before_fd(data: &[u8], sep: u8, fd: i32) -> io::Result<()> {
    const CHUNK_SIZE: usize = 1024 * 1024;
    const BATCH: usize = 1024;

    if data.len() <= CHUNK_SIZE {
        let mut positions: Vec<u32> = Vec::with_capacity(data.len() / 40 + 64);
        for pos in memchr::memchr_iter(sep, data) {
            positions.push(pos as u32);
        }
        if positions.is_empty() {
            return write_all_fd(fd, data);
        }
        let mut iovecs: Vec<libc::iovec> = Vec::with_capacity(BATCH);
        let mut end_pos = data.len();
        for &pos in positions.iter().rev() {
            let p = pos as usize;
            if p < end_pos {
                iovecs.push(libc::iovec {
                    iov_base: data[p..].as_ptr() as *mut libc::c_void,
                    iov_len: end_pos - p,
                });
                if iovecs.len() >= BATCH {
                    writev_all_fd(fd, &mut iovecs)?;
                }
            }
            end_pos = p;
        }
        if end_pos > 0 {
            iovecs.push(libc::iovec {
                iov_base: data.as_ptr() as *mut libc::c_void,
                iov_len: end_pos,
            });
        }
        if !iovecs.is_empty() {
            writev_all_fd(fd, &mut iovecs)?;
        }
        return Ok(());
    }

    let mut chunk_bounds: Vec<usize> = Vec::new();
    chunk_bounds.push(data.len());
    let mut target = data.len().saturating_sub(CHUNK_SIZE);
    while target > 0 {
        if let Some(offset) = memchr::memchr(sep, &data[target..]) {
            let boundary = target + offset;
            if boundary > 0 && boundary < *chunk_bounds.last().unwrap() {
                chunk_bounds.push(boundary);
            }
        }
        target = target.saturating_sub(CHUNK_SIZE);
    }
    chunk_bounds.push(0);
    chunk_bounds.reverse();

    let mut positions: Vec<u32> = Vec::with_capacity(CHUNK_SIZE / 40 + 64);
    let mut iovecs: Vec<libc::iovec> = Vec::with_capacity(BATCH);

    for ci in (0..chunk_bounds.len() - 1).rev() {
        let chunk_start = chunk_bounds[ci];
        let chunk_end = chunk_bounds[ci + 1];
        let chunk = &data[chunk_start..chunk_end];
        if chunk.is_empty() {
            continue;
        }
        positions.clear();
        for pos in memchr::memchr_iter(sep, chunk) {
            positions.push(pos as u32);
        }
        let mut end_pos = chunk.len();
        for &pos in positions.iter().rev() {
            let p = pos as usize;
            if p < end_pos {
                iovecs.push(libc::iovec {
                    iov_base: chunk[p..].as_ptr() as *mut libc::c_void,
                    iov_len: end_pos - p,
                });
                if iovecs.len() >= BATCH {
                    writev_all_fd(fd, &mut iovecs)?;
                }
            }
            end_pos = p;
        }
        if end_pos > 0 {
            iovecs.push(libc::iovec {
                iov_base: chunk.as_ptr() as *mut libc::c_void,
                iov_len: end_pos,
            });
        }
        if !iovecs.is_empty() {
            writev_all_fd(fd, &mut iovecs)?;
        }
    }
    Ok(())
}

/// Reverse records using a multi-byte string separator.
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
    let mut slices: Vec<IoSlice<'_>> = Vec::with_capacity(IOSLICE_BATCH_SIZE);
    let mut end = data.len();
    for &pos in positions.iter().rev() {
        let rec_start = pos + sep_len;
        if rec_start < end {
            slices.push(IoSlice::new(&data[rec_start..end]));
            if slices.len() >= IOSLICE_BATCH_SIZE {
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
    let mut slices: Vec<IoSlice<'_>> = Vec::with_capacity(IOSLICE_BATCH_SIZE);
    let mut end = data.len();
    for &pos in positions.iter().rev() {
        if pos < end {
            slices.push(IoSlice::new(&data[pos..end]));
            if slices.len() >= IOSLICE_BATCH_SIZE {
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

/// Find regex matches using backward scanning, replicating GNU tac's re_search behavior.
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
                    past_end = if m.start() == m.end() { pos } else { m.start() };
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
    let ml_pattern = format!("(?m){}", pattern);
    let re = match regex::bytes::Regex::new(&ml_pattern) {
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

#[inline(always)]
fn write_all_vectored(out: &mut impl Write, slices: &[IoSlice<'_>]) -> io::Result<()> {
    let total: usize = slices.iter().map(|s| s.len()).sum();
    let written = out.write_vectored(slices)?;
    if written >= total {
        return Ok(());
    }
    if written == 0 {
        return Err(io::Error::new(io::ErrorKind::WriteZero, "write zero"));
    }
    flush_vectored_slow(out, slices, written)
}

#[cold]
#[inline(never)]
fn flush_vectored_slow(
    out: &mut impl Write,
    slices: &[IoSlice<'_>],
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
