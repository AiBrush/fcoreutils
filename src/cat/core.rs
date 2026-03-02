use std::io::{self, Read, Write};
use std::path::Path;

use crate::common::io::{read_file, read_stdin};

/// Errors specific to the plain-file fast path on Linux.
/// Separates directory/same-file detection from I/O errors so callers
/// can emit GNU-compatible diagnostics without redundant syscalls.
#[cfg(target_os = "linux")]
pub enum CatPlainError {
    /// The path is a directory
    IsDirectory,
    /// Input file is the same as stdout (e.g. `cat file >> file`)
    InputIsOutput,
    /// Regular I/O error
    Io(io::Error),
}

#[cfg(target_os = "linux")]
impl From<io::Error> for CatPlainError {
    fn from(e: io::Error) -> Self {
        CatPlainError::Io(e)
    }
}

/// Configuration for cat
#[derive(Clone, Debug, Default)]
pub struct CatConfig {
    pub number: bool,
    pub number_nonblank: bool,
    pub show_ends: bool,
    pub show_tabs: bool,
    pub show_nonprinting: bool,
    pub squeeze_blank: bool,
}

impl CatConfig {
    /// Returns true if no special processing is needed (plain cat)
    pub fn is_plain(&self) -> bool {
        !self.number
            && !self.number_nonblank
            && !self.show_ends
            && !self.show_tabs
            && !self.show_nonprinting
            && !self.squeeze_blank
    }
}

/// Zero-copy file→stdout on Linux using splice, copy_file_range, or fast read/write.
/// Also performs directory check and input==output detection using the fstat results
/// to avoid redundant syscalls in the caller.
///
/// Returns:
///   Ok(true)  — file was fully handled
///   Ok(false) — caller should fall back to generic path
///   Err(CatPlainError::IsDirectory)    — path is a directory
///   Err(CatPlainError::InputIsOutput)  — input file is the same as stdout
///   Err(CatPlainError::Io(e))          — I/O error
#[cfg(target_os = "linux")]
pub fn cat_plain_file_linux(path: &Path) -> Result<bool, CatPlainError> {
    use std::os::unix::fs::OpenOptionsExt;
    use std::os::unix::io::AsRawFd;

    let file = std::fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOATIME)
        .open(path)
        .or_else(|_| std::fs::File::open(path))?;

    let in_fd = file.as_raw_fd();

    // Single fstat(file_fd) — replaces both stat(path) calls in the caller
    let mut in_stat: libc::stat = unsafe { std::mem::zeroed() };
    if unsafe { libc::fstat(in_fd, &mut in_stat) } != 0 {
        return Err(io::Error::last_os_error().into());
    }

    let in_mode = in_stat.st_mode & libc::S_IFMT;

    // Directory check (replaces stat(path).is_dir() in caller)
    if in_mode == libc::S_IFDIR {
        return Err(CatPlainError::IsDirectory);
    }

    // Single fstat(stdout) — replaces the fstat(1) in caller AND the one we did below
    let stdout = io::stdout();
    let out_fd = stdout.as_raw_fd();
    let mut out_stat: libc::stat = unsafe { std::mem::zeroed() };
    if unsafe { libc::fstat(out_fd, &mut out_stat) } != 0 {
        return Err(io::Error::last_os_error().into());
    }

    // Same-file detection (replaces dev/ino comparison in caller)
    if in_stat.st_dev == out_stat.st_dev && in_stat.st_ino == out_stat.st_ino {
        return Err(CatPlainError::InputIsOutput);
    }

    let file_size = in_stat.st_size as usize;

    if file_size == 0 {
        // May be a virtual file (e.g. /proc/*) with size 0 but actual content
        if in_mode != libc::S_IFREG {
            return Ok(false); // let generic path handle devices/special files
        }
        // Try reading — virtual files report size 0
        let mut buf = [0u8; 65536];
        let mut out = stdout.lock();
        loop {
            let n = match nix_read(in_fd, &mut buf) {
                Ok(0) => break,
                Ok(n) => n,
                Err(e) if e.kind() == io::ErrorKind::Interrupted => continue,
                Err(_) => break,
            };
            out.write_all(&buf[..n])?;
        }
        return Ok(true);
    }

    // Hint kernel for sequential access
    unsafe {
        libc::posix_fadvise(in_fd, 0, 0, libc::POSIX_FADV_SEQUENTIAL);
    }

    let stdout_mode = out_stat.st_mode & libc::S_IFMT;

    if stdout_mode == libc::S_IFIFO {
        // stdout is a pipe → splice (zero-copy file→pipe)
        let mut remaining = file_size;
        while remaining > 0 {
            let chunk = remaining.min(1024 * 1024 * 1024);
            let ret = unsafe {
                libc::splice(
                    in_fd,
                    std::ptr::null_mut(),
                    out_fd,
                    std::ptr::null_mut(),
                    chunk,
                    libc::SPLICE_F_MOVE,
                )
            };
            if ret > 0 {
                remaining -= ret as usize;
            } else if ret == 0 {
                break;
            } else {
                let err = io::Error::last_os_error();
                if err.kind() == io::ErrorKind::Interrupted {
                    continue;
                }
                // splice not supported — fall through to read/write
                return Ok(cat_readwrite(in_fd, stdout.lock())?);
            }
        }
        return Ok(true);
    }

    if stdout_mode == libc::S_IFREG {
        // stdout is a regular file → copy_file_range (zero-copy in-kernel)
        // Use NULL offsets so the kernel uses and updates the fd positions directly.
        // This is critical for multi-file cat: explicit offsets don't update the fd
        // position, causing the second file to overwrite the first.
        let mut remaining = file_size;
        while remaining > 0 {
            let chunk = remaining.min(0x7ffff000);
            let ret = unsafe {
                libc::copy_file_range(
                    in_fd,
                    std::ptr::null_mut(),
                    out_fd,
                    std::ptr::null_mut(),
                    chunk,
                    0,
                )
            };
            if ret > 0 {
                remaining -= ret as usize;
            } else if ret == 0 {
                break;
            } else {
                let err = io::Error::last_os_error();
                if err.kind() == io::ErrorKind::Interrupted {
                    continue;
                }
                // copy_file_range not supported — fall through to read/write
                return Ok(cat_readwrite(in_fd, stdout.lock())?);
            }
        }
        return Ok(true);
    }

    // stdout is /dev/null, socket, or other — use fast read/write loop
    Ok(cat_readwrite(in_fd, stdout.lock())?)
}

/// Fast read/write loop using raw fds and a 256KB page-aligned buffer.
#[cfg(target_os = "linux")]
fn cat_readwrite(in_fd: i32, mut out: impl Write) -> io::Result<bool> {
    // 256KB matches GNU cat's empirically-optimal buffer size
    let mut buf = vec![0u8; 256 * 1024];
    loop {
        let n = match nix_read(in_fd, &mut buf) {
            Ok(0) => break,
            Ok(n) => n,
            Err(e) if e.kind() == io::ErrorKind::Interrupted => continue,
            Err(e) => return Err(e),
        };
        out.write_all(&buf[..n])?;
    }
    Ok(true)
}

/// Wrapper around libc::read returning io::Result
#[cfg(target_os = "linux")]
fn nix_read(fd: i32, buf: &mut [u8]) -> io::Result<usize> {
    let ret = unsafe { libc::read(fd, buf.as_mut_ptr() as *mut libc::c_void, buf.len()) };
    if ret >= 0 {
        Ok(ret as usize)
    } else {
        Err(io::Error::last_os_error())
    }
}

/// Plain cat for a single file — tries zero-copy, then falls back to read/write loop.
/// Note: On Linux, callers that need directory/same-file detection should call
/// cat_plain_file_linux directly to avoid redundant syscalls.
pub fn cat_plain_file(path: &Path, out: &mut impl Write) -> io::Result<bool> {
    #[cfg(target_os = "linux")]
    {
        match cat_plain_file_linux(path) {
            Ok(true) => return Ok(true),
            Ok(false) => {}
            Err(CatPlainError::Io(e)) if e.kind() == io::ErrorKind::BrokenPipe => {
                return Err(e);
            }
            Err(_) => {} // fall through to generic path (includes IsDirectory, InputIsOutput)
        }
    }

    // Fallback: read file + write (non-Linux or special files)
    let data = read_file(path)?;
    if !data.is_empty() {
        out.write_all(&data)?;
    }
    Ok(true)
}

/// Plain cat for stdin — try splice on Linux, otherwise bulk read+write
pub fn cat_plain_stdin(out: &mut impl Write) -> io::Result<()> {
    #[cfg(target_os = "linux")]
    {
        // Try splice stdin→stdout if both are pipes
        let stdin_fd = 0i32;
        let mut stat: libc::stat = unsafe { std::mem::zeroed() };
        if unsafe { libc::fstat(1, &mut stat) } == 0
            && (stat.st_mode & libc::S_IFMT) == libc::S_IFIFO
        {
            // stdout is a pipe, try splice from stdin
            loop {
                let ret = unsafe {
                    libc::splice(
                        stdin_fd,
                        std::ptr::null_mut(),
                        1,
                        std::ptr::null_mut(),
                        1024 * 1024 * 1024,
                        libc::SPLICE_F_MOVE,
                    )
                };
                if ret > 0 {
                    continue;
                } else if ret == 0 {
                    return Ok(());
                } else {
                    let err = io::Error::last_os_error();
                    if err.kind() == io::ErrorKind::Interrupted {
                        continue;
                    }
                    // splice not supported, fall through to read+write
                    break;
                }
            }
        }
    }

    // Fallback: read+write loop (256KB matches GNU cat's optimal buffer)
    let stdin = io::stdin();
    let mut reader = stdin.lock();
    let mut buf = [0u8; 262144]; // 256KB buffer
    loop {
        let n = match reader.read(&mut buf) {
            Ok(0) => break,
            Ok(n) => n,
            Err(e) if e.kind() == io::ErrorKind::Interrupted => continue,
            Err(e) => return Err(e),
        };
        out.write_all(&buf[..n])?;
    }
    Ok(())
}

/// Build the 256-byte lookup table for non-printing character display.
/// Returns (table, needs_expansion) where needs_expansion[b] is true if
/// the byte maps to more than one output byte.
fn _build_nonprinting_table(show_tabs: bool) -> ([u8; 256], [bool; 256]) {
    let mut table = [0u8; 256];
    let mut multi = [false; 256];

    for i in 0..256u16 {
        let b = i as u8;
        match b {
            b'\n' => {
                table[i as usize] = b'\n';
            }
            b'\t' => {
                if show_tabs {
                    table[i as usize] = b'I';
                    multi[i as usize] = true;
                } else {
                    table[i as usize] = b'\t';
                }
            }
            0..=8 | 10..=31 => {
                // Control chars: ^@ through ^_
                table[i as usize] = b + 64;
                multi[i as usize] = true;
            }
            32..=126 => {
                table[i as usize] = b;
            }
            127 => {
                // DEL: ^?
                table[i as usize] = b'?';
                multi[i as usize] = true;
            }
            128..=159 => {
                // M-^@ through M-^_
                table[i as usize] = b - 128 + 64;
                multi[i as usize] = true;
            }
            160..=254 => {
                // M-space through M-~
                table[i as usize] = b - 128;
                multi[i as usize] = true;
            }
            255 => {
                // M-^?
                table[i as usize] = b'?';
                multi[i as usize] = true;
            }
        }
    }

    (table, multi)
}

/// Write a non-printing byte in cat -v notation
#[inline]
fn write_nonprinting(b: u8, show_tabs: bool, out: &mut Vec<u8>) {
    match b {
        b'\t' if !show_tabs => out.push(b'\t'),
        b'\n' => out.push(b'\n'),
        0..=8 | 10..=31 => {
            out.push(b'^');
            out.push(b + 64);
        }
        9 => {
            // show_tabs must be true here
            out.push(b'^');
            out.push(b'I');
        }
        32..=126 => out.push(b),
        127 => {
            out.push(b'^');
            out.push(b'?');
        }
        128..=159 => {
            out.push(b'M');
            out.push(b'-');
            out.push(b'^');
            out.push(b - 128 + 64);
        }
        160..=254 => {
            out.push(b'M');
            out.push(b'-');
            out.push(b - 128);
        }
        255 => {
            out.push(b'M');
            out.push(b'-');
            out.push(b'^');
            out.push(b'?');
        }
    }
}

/// Fast path for cat -A (show-all) without line numbering or squeeze.
/// Uses an internal buffer with bulk memcpy of printable ASCII runs.
fn cat_show_all_fast(
    data: &[u8],
    show_tabs: bool,
    show_ends: bool,
    out: &mut impl Write,
) -> io::Result<()> {
    // Internal buffer — flush every 256KB to keep memory bounded
    const BUF_SIZE: usize = 256 * 1024;
    // Worst case expansion: every byte → 4 chars (M-^X), so reserve proportionally
    let cap = data.len().min(BUF_SIZE) + data.len().min(BUF_SIZE) / 2;
    let mut buf = Vec::with_capacity(cap);
    let mut pos = 0;

    while pos < data.len() {
        // Find the next byte that needs transformation (outside 32..=126)
        let start = pos;
        while pos < data.len() && data[pos].wrapping_sub(32) <= 94 {
            pos += 1;
        }
        // Bulk copy printable ASCII run via memcpy
        if pos > start {
            buf.extend_from_slice(&data[start..pos]);
        }
        if pos >= data.len() {
            break;
        }
        // Handle the special byte
        let b = data[pos];
        pos += 1;
        match b {
            b'\n' => {
                if show_ends {
                    buf.extend_from_slice(b"$\n");
                } else {
                    buf.push(b'\n');
                }
            }
            b'\t' if show_tabs => buf.extend_from_slice(b"^I"),
            b'\t' => buf.push(b'\t'),
            0..=8 | 10..=31 => {
                buf.push(b'^');
                buf.push(b + 64);
            }
            127 => buf.extend_from_slice(b"^?"),
            128..=159 => {
                buf.push(b'M');
                buf.push(b'-');
                buf.push(b'^');
                buf.push(b - 128 + 64);
            }
            160..=254 => {
                buf.push(b'M');
                buf.push(b'-');
                buf.push(b - 128);
            }
            255 => buf.extend_from_slice(b"M-^?"),
            _ => unreachable!(),
        }

        // Flush when buffer is large enough
        if buf.len() >= BUF_SIZE {
            out.write_all(&buf)?;
            buf.clear();
        }
    }

    if !buf.is_empty() {
        out.write_all(&buf)?;
    }
    Ok(())
}

/// Write right-aligned line number (6-char field) + tab directly into buffer.
/// Uses pre-computed digit tables to avoid itoa overhead per line.
/// Returns the number of bytes written (always 7 for numbers up to 999999).
#[inline(always)]
unsafe fn write_line_number_raw(dst: *mut u8, num: u64) -> usize {
    // GNU cat format: "%6d\t" — right-aligned in 6-char field + tab
    if num <= 999999 {
        // Fast path: fits in 6 digits (covers 99.99% of cases)
        // Pre-compute all 6 digits at once using division
        let mut n = num as u32;
        let d5 = n / 100000;
        n -= d5 * 100000;
        let d4 = n / 10000;
        n -= d4 * 10000;
        let d3 = n / 1000;
        n -= d3 * 1000;
        let d2 = n / 100;
        n -= d2 * 100;
        let d1 = n / 10;
        let d0 = n - d1 * 10;

        // Determine leading spaces
        let width = if num >= 100000 {
            6
        } else if num >= 10000 {
            5
        } else if num >= 1000 {
            4
        } else if num >= 100 {
            3
        } else if num >= 10 {
            2
        } else {
            1
        };
        let pad = 6 - width;

        // Write padding spaces
        unsafe {
            for i in 0..pad {
                *dst.add(i) = b' ';
            }
        }

        // Write digits (only the significant ones)
        let digits = [
            d5 as u8 + b'0',
            d4 as u8 + b'0',
            d3 as u8 + b'0',
            d2 as u8 + b'0',
            d1 as u8 + b'0',
            d0 as u8 + b'0',
        ];
        unsafe {
            std::ptr::copy_nonoverlapping(digits[6 - width..].as_ptr(), dst.add(pad), width);
            *dst.add(6) = b'\t';
        }
        7
    } else {
        // Slow path: number > 999999 (use itoa)
        let mut buf = itoa::Buffer::new();
        let s = buf.format(num);
        let pad = if s.len() < 6 { 6 - s.len() } else { 0 };
        unsafe {
            for i in 0..pad {
                *dst.add(i) = b' ';
            }
            std::ptr::copy_nonoverlapping(s.as_ptr(), dst.add(pad), s.len());
            *dst.add(pad + s.len()) = b'\t';
        }
        pad + s.len() + 1
    }
}

/// Ultra-fast path for cat -n (number all lines, no other options).
/// Uses pre-formatted numbers with raw buffer writes to minimize per-line overhead.
/// Single pass through data with memchr_iter for batched SIMD newline scanning.
/// Pre-allocates generously (2x input) to avoid any capacity checks or reallocation.
fn cat_number_all_fast(data: &[u8], line_num: &mut u64, out: &mut impl Write) -> io::Result<()> {
    if data.is_empty() {
        return Ok(());
    }

    // Pre-allocate ~2x input (each line gets ~8 byte number prefix).
    // Average line ~80 chars → 8/80 = 10% overhead. 2x is very conservative.
    // Use min with 64MB to avoid excessive allocation for huge files.
    let alloc = (data.len() * 2 + 256).min(64 * 1024 * 1024);
    let mut output: Vec<u8> = Vec::with_capacity(alloc);
    let mut out_ptr = output.as_mut_ptr();
    let mut out_pos: usize = 0;

    let mut num = *line_num;
    let mut pos: usize = 0;

    for nl_pos in memchr::memchr_iter(b'\n', data) {
        // Ensure capacity for number prefix + line content
        let line_len = nl_pos + 1 - pos;
        let needed = out_pos + line_len + 22; // max: 20 digits + 1 tab + 1 safety
        if needed > output.capacity() {
            unsafe { output.set_len(out_pos) };
            output.reserve(needed.saturating_sub(output.len()));
            out_ptr = output.as_mut_ptr();
        }

        // Write line number directly to output buffer
        unsafe {
            out_pos += write_line_number_raw(out_ptr.add(out_pos), num);
        }
        num += 1;

        // Copy line content including newline
        unsafe {
            std::ptr::copy_nonoverlapping(data.as_ptr().add(pos), out_ptr.add(out_pos), line_len);
        }
        out_pos += line_len;
        pos = nl_pos + 1;

        // Flush periodically for very large files (keep working set in cache)
        if out_pos >= 8 * 1024 * 1024 {
            unsafe { output.set_len(out_pos) };
            out.write_all(&output)?;
            output.clear();
            out_pos = 0;
            out_ptr = output.as_mut_ptr();
        }
    }

    // Handle final line without trailing newline
    if pos < data.len() {
        let remaining = data.len() - pos;
        let needed = out_pos + remaining + 22;
        if needed > output.capacity() {
            unsafe { output.set_len(out_pos) };
            output.reserve(needed.saturating_sub(output.len()));
            out_ptr = output.as_mut_ptr();
        }
        unsafe {
            out_pos += write_line_number_raw(out_ptr.add(out_pos), num);
        }
        num += 1;
        unsafe {
            std::ptr::copy_nonoverlapping(data.as_ptr().add(pos), out_ptr.add(out_pos), remaining);
        }
        out_pos += remaining;
    }

    *line_num = num;

    unsafe { output.set_len(out_pos) };
    if !output.is_empty() {
        out.write_all(&output)?;
    }

    Ok(())
}

/// Ultra-fast path for cat -b (number non-blank lines, no other options).
fn cat_number_nonblank_fast(
    data: &[u8],
    line_num: &mut u64,
    out: &mut impl Write,
) -> io::Result<()> {
    if data.is_empty() {
        return Ok(());
    }

    let alloc = (data.len() * 2 + 256).min(64 * 1024 * 1024);
    let mut output: Vec<u8> = Vec::with_capacity(alloc);
    let mut out_ptr = output.as_mut_ptr();
    let mut out_pos: usize = 0;

    let mut num = *line_num;
    let mut pos: usize = 0;

    for nl_pos in memchr::memchr_iter(b'\n', data) {
        let line_len = nl_pos + 1 - pos;
        let needed = out_pos + line_len + 22;
        if needed > output.capacity() {
            unsafe { output.set_len(out_pos) };
            output.reserve(needed.saturating_sub(output.len()));
            out_ptr = output.as_mut_ptr();
        }

        let is_blank = nl_pos == pos;
        if !is_blank {
            unsafe {
                out_pos += write_line_number_raw(out_ptr.add(out_pos), num);
            }
            num += 1;
        }

        unsafe {
            std::ptr::copy_nonoverlapping(data.as_ptr().add(pos), out_ptr.add(out_pos), line_len);
        }
        out_pos += line_len;
        pos = nl_pos + 1;

        if out_pos >= 8 * 1024 * 1024 {
            unsafe { output.set_len(out_pos) };
            out.write_all(&output)?;
            output.clear();
            out_pos = 0;
            out_ptr = output.as_mut_ptr();
        }
    }

    if pos < data.len() {
        let remaining = data.len() - pos;
        let needed = out_pos + remaining + 22;
        if needed > output.capacity() {
            unsafe { output.set_len(out_pos) };
            output.reserve(needed.saturating_sub(output.len()));
            out_ptr = output.as_mut_ptr();
        }
        unsafe {
            out_pos += write_line_number_raw(out_ptr.add(out_pos), num);
        }
        num += 1;
        unsafe {
            std::ptr::copy_nonoverlapping(data.as_ptr().add(pos), out_ptr.add(out_pos), remaining);
        }
        out_pos += remaining;
    }

    *line_num = num;

    unsafe { output.set_len(out_pos) };
    if !output.is_empty() {
        out.write_all(&output)?;
    }

    Ok(())
}

/// Cat with options (numbering, show-ends, show-tabs, show-nonprinting, squeeze)
pub fn cat_with_options(
    data: &[u8],
    config: &CatConfig,
    line_num: &mut u64,
    pending_cr: &mut bool,
    out: &mut impl Write,
) -> io::Result<()> {
    if data.is_empty() {
        return Ok(());
    }

    // Fast path: show-all without numbering or squeeze
    if config.show_nonprinting && !config.number && !config.number_nonblank && !config.squeeze_blank
    {
        return cat_show_all_fast(data, config.show_tabs, config.show_ends, out);
    }

    // Fast path: -n only (number all lines, no other processing)
    if config.number
        && !config.number_nonblank
        && !config.show_ends
        && !config.show_tabs
        && !config.show_nonprinting
        && !config.squeeze_blank
        && !*pending_cr
    {
        return cat_number_all_fast(data, line_num, out);
    }

    // Fast path: -b only (number non-blank lines, no other processing)
    if config.number_nonblank
        && !config.number
        && !config.show_ends
        && !config.show_tabs
        && !config.show_nonprinting
        && !config.squeeze_blank
        && !*pending_cr
    {
        return cat_number_nonblank_fast(data, line_num, out);
    }

    // Pre-allocate output buffer (worst case: every byte expands to 4 chars for M-^X)
    // In practice, most files are mostly printable, so 1.1x is a good estimate
    let estimated = data.len() + data.len() / 10 + 1024;
    let mut buf = Vec::with_capacity(estimated.min(16 * 1024 * 1024));

    let mut prev_blank = false;
    let mut pos = 0;
    let mut itoa_buf = itoa::Buffer::new();

    // Handle pending CR from previous file (only relevant for show_ends without show_nonprinting)
    if *pending_cr {
        *pending_cr = false;
        if config.show_ends
            && !(config.show_nonprinting || config.show_tabs)
            && !data.is_empty()
            && data[0] == b'\n'
        {
            // CR from previous file + this LF = CRLF line ending → ^M$\n
            buf.extend_from_slice(b"^M$\n");
            pos = 1;
        } else {
            // CR not followed by LF, emit literally
            buf.push(b'\r');
        }
    }

    while pos < data.len() {
        // Find end of this line
        let line_end = memchr::memchr(b'\n', &data[pos..])
            .map(|p| pos + p + 1)
            .unwrap_or(data.len());

        let line = &data[pos..line_end];
        let is_blank = line == b"\n" || line.is_empty();

        // Squeeze blank lines
        if config.squeeze_blank && is_blank && prev_blank {
            pos = line_end;
            continue;
        }
        prev_blank = is_blank;

        // Line numbering - use itoa for fast integer formatting
        if config.number_nonblank {
            if !is_blank {
                let s = itoa_buf.format(*line_num);
                // Right-align in 6-char field
                let pad = if s.len() < 6 { 6 - s.len() } else { 0 };
                buf.extend(std::iter::repeat_n(b' ', pad));
                buf.extend_from_slice(s.as_bytes());
                buf.push(b'\t');
                *line_num += 1;
            }
        } else if config.number {
            let s = itoa_buf.format(*line_num);
            let pad = if s.len() < 6 { 6 - s.len() } else { 0 };
            buf.extend(std::iter::repeat_n(b' ', pad));
            buf.extend_from_slice(s.as_bytes());
            buf.push(b'\t');
            *line_num += 1;
        }

        // Process line content
        if config.show_nonprinting || config.show_tabs {
            let content_end = if line.last() == Some(&b'\n') {
                line.len() - 1
            } else {
                line.len()
            };

            for &b in &line[..content_end] {
                if config.show_nonprinting {
                    write_nonprinting(b, config.show_tabs, &mut buf);
                } else if config.show_tabs && b == b'\t' {
                    buf.extend_from_slice(b"^I");
                } else {
                    buf.push(b);
                }
            }

            if config.show_ends && line.last() == Some(&b'\n') {
                buf.push(b'$');
            }
            if line.last() == Some(&b'\n') {
                buf.push(b'\n');
            }
        } else {
            // No character transformation needed
            if config.show_ends {
                let has_newline = line.last() == Some(&b'\n');
                let content_end = if has_newline {
                    line.len() - 1
                } else {
                    line.len()
                };
                // GNU cat -E: only \r immediately before \n is shown as ^M.
                // Other \r bytes are passed through as literal CR (0x0d).
                let content = &line[..content_end];
                if has_newline && !content.is_empty() && content[content.len() - 1] == b'\r' {
                    // Content ends with \r (which is right before \n) → show as ^M$
                    buf.extend_from_slice(&content[..content.len() - 1]);
                    buf.extend_from_slice(b"^M");
                } else if !has_newline && !content.is_empty() && content[content.len() - 1] == b'\r'
                {
                    // Trailing CR at end of data without following LF — hold as pending.
                    // It might pair with next file's LF to form CRLF line ending.
                    buf.extend_from_slice(&content[..content.len() - 1]);
                    *pending_cr = true;
                } else {
                    buf.extend_from_slice(content);
                }
                if has_newline {
                    buf.push(b'$');
                    buf.push(b'\n');
                }
            } else {
                buf.extend_from_slice(line);
            }
        }

        // Flush buffer periodically to avoid excessive memory use
        if buf.len() >= 8 * 1024 * 1024 {
            out.write_all(&buf)?;
            buf.clear();
        }

        pos = line_end;
    }

    if !buf.is_empty() {
        out.write_all(&buf)?;
    }

    Ok(())
}

/// Process a single file for cat
pub fn cat_file(
    filename: &str,
    config: &CatConfig,
    line_num: &mut u64,
    pending_cr: &mut bool,
    out: &mut impl Write,
    tool_name: &str,
) -> io::Result<bool> {
    if filename == "-" {
        if config.is_plain() {
            match cat_plain_stdin(out) {
                Ok(()) => return Ok(true),
                Err(e) if e.kind() == io::ErrorKind::BrokenPipe => {
                    std::process::exit(0);
                }
                Err(e) => {
                    eprintln!(
                        "{}: standard input: {}",
                        tool_name,
                        crate::common::io_error_msg(&e)
                    );
                    return Ok(false);
                }
            }
        }
        match read_stdin() {
            Ok(data) => {
                cat_with_options(&data, config, line_num, pending_cr, out)?;
                Ok(true)
            }
            Err(e) => {
                eprintln!(
                    "{}: standard input: {}",
                    tool_name,
                    crate::common::io_error_msg(&e)
                );
                Ok(false)
            }
        }
    } else {
        let path = Path::new(filename);

        if config.is_plain() {
            // On Linux, cat_plain_file_linux handles directory check and same-file
            // detection inside its own fstat calls, avoiding redundant syscalls.
            #[cfg(target_os = "linux")]
            {
                match cat_plain_file_linux(path) {
                    Ok(true) => return Ok(true),
                    Ok(false) => {
                        // Fallback to generic path — still need dir/same-file checks
                        // since the generic path doesn't do them.
                    }
                    Err(CatPlainError::IsDirectory) => {
                        eprintln!("{}: {}: Is a directory", tool_name, filename);
                        return Ok(false);
                    }
                    Err(CatPlainError::InputIsOutput) => {
                        eprintln!("{}: {}: input file is output file", tool_name, filename);
                        return Ok(false);
                    }
                    Err(CatPlainError::Io(e)) if e.kind() == io::ErrorKind::BrokenPipe => {
                        std::process::exit(0);
                    }
                    Err(CatPlainError::Io(e)) => {
                        eprintln!(
                            "{}: {}: {}",
                            tool_name,
                            filename,
                            crate::common::io_error_msg(&e)
                        );
                        return Ok(false);
                    }
                }
            }

            // Non-Linux plain path or Linux fallback (Ok(false) from above)
            // Need to do directory/same-file checks here for the generic fallback.
            // Hoist single metadata call for both directory check and same-file detection.
            if let Ok(file_meta) = std::fs::metadata(path) {
                if file_meta.is_dir() {
                    eprintln!("{}: {}: Is a directory", tool_name, filename);
                    return Ok(false);
                }

                #[cfg(unix)]
                {
                    use std::os::unix::fs::MetadataExt;
                    let mut stdout_stat: libc::stat = unsafe { std::mem::zeroed() };
                    if unsafe { libc::fstat(1, &mut stdout_stat) } == 0
                        && file_meta.dev() == stdout_stat.st_dev as u64
                        && file_meta.ino() == stdout_stat.st_ino as u64
                    {
                        eprintln!("{}: {}: input file is output file", tool_name, filename);
                        return Ok(false);
                    }
                }
            }

            // Generic fallback: read file + write
            match read_file(path) {
                Ok(data) => {
                    if !data.is_empty() {
                        out.write_all(&data)?;
                    }
                    return Ok(true);
                }
                Err(e) => {
                    eprintln!(
                        "{}: {}: {}",
                        tool_name,
                        filename,
                        crate::common::io_error_msg(&e)
                    );
                    return Ok(false);
                }
            }
        }

        // Non-plain path: need directory check and same-file detection before processing
        // Check if it's a directory
        match std::fs::metadata(path) {
            Ok(meta) if meta.is_dir() => {
                eprintln!("{}: {}: Is a directory", tool_name, filename);
                return Ok(false);
            }
            _ => {}
        }

        // GNU cat: detect when input file is the same as stdout (e.g. cat file >> file)
        #[cfg(unix)]
        {
            use std::os::unix::fs::MetadataExt;
            if let Ok(file_meta) = std::fs::metadata(path) {
                let mut stdout_stat: libc::stat = unsafe { std::mem::zeroed() };
                if unsafe { libc::fstat(1, &mut stdout_stat) } == 0
                    && file_meta.dev() == stdout_stat.st_dev as u64
                    && file_meta.ino() == stdout_stat.st_ino as u64
                {
                    eprintln!("{}: {}: input file is output file", tool_name, filename);
                    return Ok(false);
                }
            }
        }

        match read_file(path) {
            Ok(data) => {
                cat_with_options(&data, config, line_num, pending_cr, out)?;
                Ok(true)
            }
            Err(e) => {
                eprintln!(
                    "{}: {}: {}",
                    tool_name,
                    filename,
                    crate::common::io_error_msg(&e)
                );
                Ok(false)
            }
        }
    }
}
