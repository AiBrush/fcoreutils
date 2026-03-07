use std::io::{self, IoSlice, Write};

/// Maximum number of IoSlice entries per write_vectored call.
const IOV_MAX: usize = 1024;

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

/// Stream reversed byte-separated records directly to an fd using contiguous
/// 2MB output buffer. Uses u32 positions for files ≤4GB to halve cache pressure
/// during reverse iteration; falls back to usize for larger files.
#[cfg(unix)]
pub fn tac_bytes_to_fd(data: &[u8], separator: u8, before: bool, fd: i32) -> io::Result<()> {
    if data.is_empty() {
        return Ok(());
    }
    // u32 positions for ≤4GB (halves position array cache footprint)
    if data.len() <= u32::MAX as usize {
        return tac_bytes_to_fd_generic::<u32>(data, separator, before, fd);
    }
    // >4GB fallback
    tac_bytes_to_fd_generic::<usize>(data, separator, before, fd)
}

/// Trait for position types used in tac reverse iteration.
/// Allows `u32` (for ≤4GB, halves cache pressure) and `usize` (for >4GB).
trait TacPos: Copy {
    fn from_usize(v: usize) -> Self;
    fn as_usize(self) -> usize;
}
impl TacPos for u32 {
    #[inline(always)]
    fn from_usize(v: usize) -> Self {
        v as u32
    }
    #[inline(always)]
    fn as_usize(self) -> usize {
        self as usize
    }
}
impl TacPos for usize {
    #[inline(always)]
    fn from_usize(v: usize) -> Self {
        v
    }
    #[inline(always)]
    fn as_usize(self) -> usize {
        self
    }
}

/// Generic contiguous-buffer reverse implementation. Parameterized over the
/// position type (`u32` for ≤4GB to halve cache pressure, `usize` for >4GB).
/// SIMD memchr scan → position vec → reverse iterate → extend_from_slice into
/// 2MB buffer → write_all_fd. For a 10MB file with ~250K lines this produces
/// ~5 write() syscalls vs ~244 writev() calls in the old approach.
#[cfg(unix)]
fn tac_bytes_to_fd_generic<P: TacPos>(
    data: &[u8],
    sep: u8,
    before: bool,
    fd: i32,
) -> io::Result<()> {
    let mut positions: Vec<P> = Vec::with_capacity(data.len() / 40 + 64);
    for pos in memchr::memchr_iter(sep, data) {
        positions.push(P::from_usize(pos));
    }
    if positions.is_empty() {
        return write_all_fd(fd, data);
    }

    const FLUSH_SIZE: usize = 2 * 1024 * 1024;
    let buf_cap = data.len().min(FLUSH_SIZE + 256 * 1024);
    let mut buf: Vec<u8> = Vec::with_capacity(buf_cap);
    let mut end_pos = data.len();

    if !before {
        for &pos in positions.iter().rev() {
            let rec_start = pos.as_usize() + 1;
            if rec_start < end_pos {
                buf.extend_from_slice(&data[rec_start..end_pos]);
                if buf.len() >= FLUSH_SIZE {
                    write_all_fd(fd, &buf)?;
                    buf.clear();
                }
            }
            end_pos = rec_start;
        }
    } else {
        for &pos in positions.iter().rev() {
            let p = pos.as_usize();
            if p < end_pos {
                buf.extend_from_slice(&data[p..end_pos]);
                if buf.len() >= FLUSH_SIZE {
                    write_all_fd(fd, &buf)?;
                    buf.clear();
                }
            }
            end_pos = p;
        }
    }
    if end_pos > 0 {
        buf.extend_from_slice(&data[..end_pos]);
    }
    if !buf.is_empty() {
        write_all_fd(fd, &buf)?;
    }
    Ok(())
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

/// After-separator mode: forward SIMD scan + streaming output.
/// For small data (<256KB), collects all records into a single Vec and does one
/// write_all call, eliminating multiple write() syscalls.
/// For large data, streams in 2MB chunks.
fn tac_bytes_after(data: &[u8], sep: u8, out: &mut impl Write) -> io::Result<()> {
    let mut positions: Vec<usize> = Vec::with_capacity(data.len() / 40 + 64);
    for pos in memchr::memchr_iter(sep, data) {
        positions.push(pos);
    }
    if positions.is_empty() {
        return out.write_all(data);
    }

    // Small data: single allocation + single write_all avoids multiple syscalls
    const SMALL_THRESHOLD: usize = 256 * 1024;
    if data.len() <= SMALL_THRESHOLD {
        let mut buf: Vec<u8> = Vec::with_capacity(data.len());
        let mut end_pos = data.len();
        for &pos in positions.iter().rev() {
            let rec_start = pos + 1;
            if rec_start < end_pos {
                buf.extend_from_slice(&data[rec_start..end_pos]);
            }
            end_pos = rec_start;
        }
        if end_pos > 0 {
            buf.extend_from_slice(&data[..end_pos]);
        }
        return out.write_all(&buf);
    }

    const BUF_SIZE: usize = 2 * 1024 * 1024;
    let mut buf: Vec<u8> = Vec::with_capacity(BUF_SIZE);
    let mut end_pos = data.len();
    for &pos in positions.iter().rev() {
        let rec_start = pos + 1;
        if rec_start < end_pos {
            let record = &data[rec_start..end_pos];
            if buf.len() + record.len() > BUF_SIZE && !buf.is_empty() {
                out.write_all(&buf)?;
                buf.clear();
            }
            if record.len() > BUF_SIZE {
                out.write_all(record)?;
            } else {
                buf.extend_from_slice(record);
            }
        }
        end_pos = rec_start;
    }
    if end_pos > 0 {
        let record = &data[..end_pos];
        if buf.len() + record.len() > BUF_SIZE && !buf.is_empty() {
            out.write_all(&buf)?;
            buf.clear();
        }
        if record.len() > BUF_SIZE {
            out.write_all(record)?;
        } else {
            buf.extend_from_slice(record);
        }
    }
    if !buf.is_empty() {
        out.write_all(&buf)?;
    }
    Ok(())
}

/// Before-separator mode: forward SIMD scan + streaming output.
/// For small data (<256KB), collects all records into a single Vec and does one
/// write_all call, eliminating multiple write() syscalls.
/// For large data, streams in 2MB chunks.
fn tac_bytes_before(data: &[u8], sep: u8, out: &mut impl Write) -> io::Result<()> {
    let mut positions: Vec<usize> = Vec::with_capacity(data.len() / 40 + 64);
    for pos in memchr::memchr_iter(sep, data) {
        positions.push(pos);
    }
    if positions.is_empty() {
        return out.write_all(data);
    }

    // Small data: single allocation + single write_all avoids multiple syscalls
    const SMALL_THRESHOLD: usize = 256 * 1024;
    if data.len() <= SMALL_THRESHOLD {
        let mut buf: Vec<u8> = Vec::with_capacity(data.len());
        let mut end_pos = data.len();
        for &pos in positions.iter().rev() {
            if pos < end_pos {
                buf.extend_from_slice(&data[pos..end_pos]);
            }
            end_pos = pos;
        }
        if end_pos > 0 {
            buf.extend_from_slice(&data[..end_pos]);
        }
        return out.write_all(&buf);
    }

    const BUF_SIZE: usize = 2 * 1024 * 1024;
    let mut buf: Vec<u8> = Vec::with_capacity(BUF_SIZE);
    let mut end_pos = data.len();
    for &pos in positions.iter().rev() {
        if pos < end_pos {
            let record = &data[pos..end_pos];
            if buf.len() + record.len() > BUF_SIZE && !buf.is_empty() {
                out.write_all(&buf)?;
                buf.clear();
            }
            if record.len() > BUF_SIZE {
                out.write_all(record)?;
            } else {
                buf.extend_from_slice(record);
            }
        }
        end_pos = pos;
    }
    if end_pos > 0 {
        let record = &data[..end_pos];
        if buf.len() + record.len() > BUF_SIZE && !buf.is_empty() {
            out.write_all(&buf)?;
            buf.clear();
        }
        if record.len() > BUF_SIZE {
            out.write_all(record)?;
        } else {
            buf.extend_from_slice(record);
        }
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
    let mut slices: Vec<IoSlice<'_>> = Vec::with_capacity(IOV_MAX);
    let mut end = data.len();
    for &pos in positions.iter().rev() {
        let rec_start = pos + sep_len;
        if rec_start < end {
            slices.push(IoSlice::new(&data[rec_start..end]));
            if slices.len() >= IOV_MAX {
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
    let mut slices: Vec<IoSlice<'_>> = Vec::with_capacity(IOV_MAX);
    let mut end = data.len();
    for &pos in positions.iter().rev() {
        if pos < end {
            slices.push(IoSlice::new(&data[pos..end]));
            if slices.len() >= IOV_MAX {
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
    // Prepend (?m) so ^ and $ match at line boundaries, replicating GNU tac's
    // POSIX regex behavior (re_search uses REG_NEWLINE which implies this).
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
