use std::io::{self, Read, Seek, Write};
use std::path::Path;

use memchr::{memchr_iter, memrchr_iter};

use crate::common::io::{FileData, read_file, read_stdin};

/// Open a file with O_NOATIME on Linux, falling back if not permitted.
#[cfg(target_os = "linux")]
fn open_noatime(path: &Path) -> io::Result<std::fs::File> {
    use std::os::unix::fs::OpenOptionsExt;
    std::fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOATIME)
        .open(path)
        .or_else(|_| std::fs::File::open(path))
}

/// Scan backward from EOF to find the byte offset where the last N delimited
/// lines begin. Returns 0 when the file has fewer than N lines (output all).
/// Platform-agnostic — tested on all CI targets.
fn find_tail_start_byte(
    reader: &mut (impl Read + Seek),
    file_size: u64,
    n: u64,
    delimiter: u8,
) -> io::Result<u64> {
    const CHUNK: u64 = 262144;
    let mut pos = file_size;
    let mut count = 0u64;
    let mut buf = vec![0u8; CHUNK as usize];

    while pos > 0 {
        let read_start = if pos > CHUNK { pos - CHUNK } else { 0 };
        let read_len = (pos - read_start) as usize;

        reader.seek(io::SeekFrom::Start(read_start))?;
        reader.read_exact(&mut buf[..read_len])?;

        // Skip trailing delimiter (don't count the file's final newline)
        let search_end = if pos == file_size && read_len > 0 && buf[read_len - 1] == delimiter {
            read_len - 1
        } else {
            read_len
        };

        for rpos in memrchr_iter(delimiter, &buf[..search_end]) {
            count += 1;
            if count == n {
                return Ok(read_start + rpos as u64 + 1);
            }
        }

        pos = read_start;
    }

    Ok(0)
}

/// Mode for tail operation
#[derive(Clone, Debug)]
pub enum TailMode {
    /// Last N lines (default: 10)
    Lines(u64),
    /// Starting from line N (1-indexed)
    LinesFrom(u64),
    /// Last N bytes
    Bytes(u64),
    /// Starting from byte N (1-indexed)
    BytesFrom(u64),
}

/// Follow mode
#[derive(Clone, Debug, PartialEq)]
pub enum FollowMode {
    None,
    Descriptor,
    Name,
}

/// Configuration for tail
#[derive(Clone, Debug)]
pub struct TailConfig {
    pub mode: TailMode,
    pub follow: FollowMode,
    pub retry: bool,
    pub pid: Option<u32>,
    pub sleep_interval: f64,
    pub max_unchanged_stats: u64,
    pub zero_terminated: bool,
}

impl Default for TailConfig {
    fn default() -> Self {
        Self {
            mode: TailMode::Lines(10),
            follow: FollowMode::None,
            retry: false,
            pid: None,
            sleep_interval: 1.0,
            max_unchanged_stats: 5,
            zero_terminated: false,
        }
    }
}

/// Parse a numeric argument with optional suffix, same as head
pub fn parse_size(s: &str) -> Result<u64, String> {
    crate::head::parse_size(s)
}

/// Output last N lines from data using backward SIMD scanning
pub fn tail_lines(data: &[u8], n: u64, delimiter: u8, out: &mut impl Write) -> io::Result<()> {
    if n == 0 || data.is_empty() {
        return Ok(());
    }

    // Use memrchr for backward scanning - SIMD accelerated
    let mut count = 0u64;

    // Check if data ends with delimiter - if so, skip the trailing one
    let search_end = if !data.is_empty() && data[data.len() - 1] == delimiter {
        data.len() - 1
    } else {
        data.len()
    };

    for pos in memrchr_iter(delimiter, &data[..search_end]) {
        count += 1;
        if count == n {
            return out.write_all(&data[pos + 1..]);
        }
    }

    // Fewer than N lines — output everything
    out.write_all(data)
}

/// Output from line N onward (1-indexed)
pub fn tail_lines_from(data: &[u8], n: u64, delimiter: u8, out: &mut impl Write) -> io::Result<()> {
    if data.is_empty() {
        return Ok(());
    }

    if n <= 1 {
        return out.write_all(data);
    }

    // Skip first (n-1) lines
    let skip = n - 1;
    let mut count = 0u64;

    for pos in memchr_iter(delimiter, data) {
        count += 1;
        if count == skip {
            let start = pos + 1;
            if start < data.len() {
                return out.write_all(&data[start..]);
            }
            return Ok(());
        }
    }

    // Fewer than N lines — output nothing
    Ok(())
}

/// Output last N bytes from data
pub fn tail_bytes(data: &[u8], n: u64, out: &mut impl Write) -> io::Result<()> {
    if n == 0 || data.is_empty() {
        return Ok(());
    }

    let n = n.min(data.len() as u64) as usize;
    out.write_all(&data[data.len() - n..])
}

/// Output from byte N onward (1-indexed)
pub fn tail_bytes_from(data: &[u8], n: u64, out: &mut impl Write) -> io::Result<()> {
    if data.is_empty() {
        return Ok(());
    }

    if n <= 1 {
        return out.write_all(data);
    }

    let start = ((n - 1) as usize).min(data.len());
    if start < data.len() {
        out.write_all(&data[start..])
    } else {
        Ok(())
    }
}

/// Use sendfile for zero-copy byte output on Linux (last N bytes)
#[cfg(target_os = "linux")]
pub fn sendfile_tail_bytes(path: &Path, n: u64, out_fd: i32) -> io::Result<bool> {
    let file = open_noatime(path)?;

    let metadata = file.metadata()?;
    let file_size = metadata.len();

    if file_size == 0 {
        return Ok(true);
    }

    let n = n.min(file_size);
    let start = file_size - n;

    use std::os::unix::io::AsRawFd;
    let in_fd = file.as_raw_fd();
    let mut offset: libc::off_t = start as libc::off_t;
    let mut remaining = n;

    while remaining > 0 {
        let chunk = remaining.min(0x7fff_f000) as usize;
        let ret = unsafe { libc::sendfile(out_fd, in_fd, &mut offset, chunk) };
        if ret > 0 {
            remaining -= ret as u64;
        } else if ret == 0 {
            break;
        } else {
            let err = io::Error::last_os_error();
            if err.kind() == io::ErrorKind::Interrupted {
                continue;
            }
            return Err(err);
        }
    }

    Ok(true)
}

/// Streaming tail -n N via sendfile on Linux. Caller opens the file so that
/// open errors can be reported as "cannot open" and I/O errors as "error reading".
#[cfg(target_os = "linux")]
fn sendfile_tail_lines(
    file: std::fs::File,
    file_size: u64,
    n: u64,
    delimiter: u8,
    out_fd: i32,
) -> io::Result<bool> {
    use std::os::unix::io::AsRawFd;

    if n == 0 || file_size == 0 {
        return Ok(true);
    }

    let in_fd = file.as_raw_fd();

    // Disable forward readahead — we scan backward from EOF
    let _ = unsafe { libc::posix_fadvise(in_fd, 0, 0, libc::POSIX_FADV_RANDOM) };

    let mut reader = file;
    let start_byte = find_tail_start_byte(&mut reader, file_size, n, delimiter)?;

    // Enable forward readahead from the output start point
    let remaining = file_size - start_byte;
    let _ = unsafe {
        libc::posix_fadvise(
            in_fd,
            start_byte as libc::off_t,
            remaining as libc::off_t,
            libc::POSIX_FADV_SEQUENTIAL,
        )
    };

    // Zero-copy output via sendfile
    let mut offset = start_byte as libc::off_t;
    let mut left = remaining;
    while left > 0 {
        let chunk = left.min(0x7fff_f000) as usize;
        let ret = unsafe { libc::sendfile(out_fd, in_fd, &mut offset, chunk) };
        if ret > 0 {
            left -= ret as u64;
        } else if ret == 0 {
            break;
        } else {
            let err = io::Error::last_os_error();
            if err.kind() == io::ErrorKind::Interrupted {
                continue;
            }
            return Err(err);
        }
    }

    Ok(true)
}

/// Streaming tail -n N for regular files: read backward from EOF, then
/// seek forward and copy. Caller opens the file. Used on non-Linux platforms.
#[cfg(not(target_os = "linux"))]
fn tail_lines_streaming_file(
    mut file: std::fs::File,
    file_size: u64,
    n: u64,
    delimiter: u8,
    out: &mut impl Write,
) -> io::Result<bool> {
    if n == 0 || file_size == 0 {
        return Ok(true);
    }

    let start_byte = find_tail_start_byte(&mut file, file_size, n, delimiter)?;
    file.seek(io::SeekFrom::Start(start_byte))?;
    io::copy(&mut file, out)?;

    Ok(true)
}

/// Streaming tail -n +N for regular files: skip N-1 lines from start.
/// Caller opens the file.
///
/// **Precondition**: On Linux, the `n <= 1` path uses `sendfile` which writes
/// directly to stdout (bypassing `out`). The caller MUST `out.flush()` before
/// calling this function to avoid interleaved output.
fn tail_lines_from_streaming_file(
    file: std::fs::File,
    n: u64,
    delimiter: u8,
    out: &mut impl Write,
) -> io::Result<bool> {
    if n <= 1 {
        // Output entire file via sendfile
        #[cfg(target_os = "linux")]
        {
            use std::os::unix::io::AsRawFd;
            let in_fd = file.as_raw_fd();
            let stdout = io::stdout();
            let out_fd = stdout.as_raw_fd();
            let file_size = file.metadata()?.len();
            return sendfile_to_stdout_raw(in_fd, file_size, out_fd);
        }
        #[cfg(not(target_os = "linux"))]
        {
            let mut reader = io::BufReader::with_capacity(1024 * 1024, file);
            let mut buf = [0u8; 262144];
            loop {
                let n = match reader.read(&mut buf) {
                    Ok(0) => break,
                    Ok(n) => n,
                    Err(e) if e.kind() == io::ErrorKind::Interrupted => continue,
                    Err(e) => return Err(e),
                };
                out.write_all(&buf[..n])?;
            }
            return Ok(true);
        }
    }

    let skip = n - 1;
    let mut reader = io::BufReader::with_capacity(1024 * 1024, file);
    let mut buf = [0u8; 262144];
    let mut count = 0u64;
    let mut skipping = true;

    loop {
        let bytes_read = match reader.read(&mut buf) {
            Ok(0) => break,
            Ok(n) => n,
            Err(e) if e.kind() == io::ErrorKind::Interrupted => continue,
            Err(e) => return Err(e),
        };

        let chunk = &buf[..bytes_read];

        if skipping {
            for pos in memchr_iter(delimiter, chunk) {
                count += 1;
                if count == skip {
                    // Found the start — output rest of this chunk and stop skipping
                    let start = pos + 1;
                    if start < chunk.len() {
                        out.write_all(&chunk[start..])?;
                    }
                    skipping = false;
                    break;
                }
            }
        } else {
            out.write_all(chunk)?;
        }
    }

    Ok(true)
}

/// Raw sendfile helper
#[cfg(target_os = "linux")]
fn sendfile_to_stdout_raw(in_fd: i32, file_size: u64, out_fd: i32) -> io::Result<bool> {
    let mut offset: libc::off_t = 0;
    let mut remaining = file_size;
    while remaining > 0 {
        let chunk = remaining.min(0x7fff_f000) as usize;
        let ret = unsafe { libc::sendfile(out_fd, in_fd, &mut offset, chunk) };
        if ret > 0 {
            remaining -= ret as u64;
        } else if ret == 0 {
            break;
        } else {
            let err = io::Error::last_os_error();
            if err.kind() == io::ErrorKind::Interrupted {
                continue;
            }
            return Err(err);
        }
    }
    Ok(true)
}

/// Process a single file/stdin for tail.
///
/// On Linux, the sendfile fast paths bypass `out` and write directly to stdout
/// (fd 1). Callers MUST ensure `out` wraps stdout when these paths are active.
/// The `out.flush()` call drains any buffered data before sendfile takes over.
pub fn tail_file(
    filename: &str,
    config: &TailConfig,
    out: &mut impl Write,
    tool_name: &str,
) -> io::Result<bool> {
    let delimiter = if config.zero_terminated { b'\0' } else { b'\n' };

    if filename != "-" {
        let path = Path::new(filename);

        match &config.mode {
            TailMode::Lines(n) => {
                // Open the file first so open errors get the right message
                #[cfg(target_os = "linux")]
                let file = match open_noatime(path) {
                    Ok(f) => f,
                    Err(e) => {
                        eprintln!(
                            "{}: cannot open '{}' for reading: {}",
                            tool_name,
                            filename,
                            crate::common::io_error_msg(&e)
                        );
                        return Ok(false);
                    }
                };
                #[cfg(not(target_os = "linux"))]
                let file = match std::fs::File::open(path) {
                    Ok(f) => f,
                    Err(e) => {
                        eprintln!(
                            "{}: cannot open '{}' for reading: {}",
                            tool_name,
                            filename,
                            crate::common::io_error_msg(&e)
                        );
                        return Ok(false);
                    }
                };
                let file_size = match file.metadata() {
                    Ok(m) => m.len(),
                    Err(e) => {
                        eprintln!(
                            "{}: error reading '{}': {}",
                            tool_name,
                            filename,
                            crate::common::io_error_msg(&e)
                        );
                        return Ok(false);
                    }
                };
                #[cfg(target_os = "linux")]
                {
                    use std::os::unix::io::AsRawFd;
                    out.flush()?;
                    let stdout = io::stdout();
                    let out_fd = stdout.as_raw_fd();
                    match sendfile_tail_lines(file, file_size, *n, delimiter, out_fd) {
                        Ok(_) => return Ok(true),
                        Err(e) => {
                            eprintln!(
                                "{}: error reading '{}': {}",
                                tool_name,
                                filename,
                                crate::common::io_error_msg(&e)
                            );
                            return Ok(false);
                        }
                    }
                }
                #[cfg(not(target_os = "linux"))]
                {
                    match tail_lines_streaming_file(file, file_size, *n, delimiter, out) {
                        Ok(_) => return Ok(true),
                        Err(e) => {
                            eprintln!(
                                "{}: error reading '{}': {}",
                                tool_name,
                                filename,
                                crate::common::io_error_msg(&e)
                            );
                            return Ok(false);
                        }
                    }
                }
            }
            TailMode::LinesFrom(n) => {
                out.flush()?;
                #[cfg(target_os = "linux")]
                let file = match open_noatime(path) {
                    Ok(f) => f,
                    Err(e) => {
                        eprintln!(
                            "{}: cannot open '{}' for reading: {}",
                            tool_name,
                            filename,
                            crate::common::io_error_msg(&e)
                        );
                        return Ok(false);
                    }
                };
                #[cfg(not(target_os = "linux"))]
                let file = match std::fs::File::open(path) {
                    Ok(f) => f,
                    Err(e) => {
                        eprintln!(
                            "{}: cannot open '{}' for reading: {}",
                            tool_name,
                            filename,
                            crate::common::io_error_msg(&e)
                        );
                        return Ok(false);
                    }
                };
                match tail_lines_from_streaming_file(file, *n, delimiter, out) {
                    Ok(_) => return Ok(true),
                    Err(e) => {
                        eprintln!(
                            "{}: error reading '{}': {}",
                            tool_name,
                            filename,
                            crate::common::io_error_msg(&e)
                        );
                        return Ok(false);
                    }
                }
            }
            TailMode::Bytes(_n) => {
                #[cfg(target_os = "linux")]
                {
                    use std::os::unix::io::AsRawFd;
                    out.flush()?; // drain BufWriter before bypassing with sendfile
                    let stdout = io::stdout();
                    let out_fd = stdout.as_raw_fd();
                    if let Ok(true) = sendfile_tail_bytes(path, *_n, out_fd) {
                        return Ok(true);
                    }
                }
            }
            TailMode::BytesFrom(_n) => {
                #[cfg(target_os = "linux")]
                {
                    use std::os::unix::io::AsRawFd;
                    out.flush()?; // drain BufWriter before bypassing with sendfile
                    let stdout = io::stdout();
                    let out_fd = stdout.as_raw_fd();
                    if let Ok(true) = sendfile_tail_bytes_from(path, *_n, out_fd) {
                        return Ok(true);
                    }
                }
            }
        }
    }

    // Slow path: read entire input (stdin or fallback)
    let data: FileData = if filename == "-" {
        match read_stdin() {
            Ok(d) => FileData::Owned(d),
            Err(e) => {
                eprintln!(
                    "{}: standard input: {}",
                    tool_name,
                    crate::common::io_error_msg(&e)
                );
                return Ok(false);
            }
        }
    } else {
        match read_file(Path::new(filename)) {
            Ok(d) => d,
            Err(e) => {
                eprintln!(
                    "{}: cannot open '{}' for reading: {}",
                    tool_name,
                    filename,
                    crate::common::io_error_msg(&e)
                );
                return Ok(false);
            }
        }
    };

    match &config.mode {
        TailMode::Lines(n) => tail_lines(&data, *n, delimiter, out)?,
        TailMode::LinesFrom(n) => tail_lines_from(&data, *n, delimiter, out)?,
        TailMode::Bytes(n) => tail_bytes(&data, *n, out)?,
        TailMode::BytesFrom(n) => tail_bytes_from(&data, *n, out)?,
    }

    Ok(true)
}

/// sendfile from byte N onward (1-indexed)
#[cfg(target_os = "linux")]
fn sendfile_tail_bytes_from(path: &Path, n: u64, out_fd: i32) -> io::Result<bool> {
    let file = open_noatime(path)?;

    let metadata = file.metadata()?;
    let file_size = metadata.len();

    if file_size == 0 {
        return Ok(true);
    }

    let start = if n <= 1 { 0 } else { (n - 1).min(file_size) };

    if start >= file_size {
        return Ok(true);
    }

    use std::os::unix::io::AsRawFd;
    let in_fd = file.as_raw_fd();
    let mut offset: libc::off_t = start as libc::off_t;
    let mut remaining = file_size - start;

    while remaining > 0 {
        let chunk = remaining.min(0x7fff_f000) as usize;
        let ret = unsafe { libc::sendfile(out_fd, in_fd, &mut offset, chunk) };
        if ret > 0 {
            remaining -= ret as u64;
        } else if ret == 0 {
            break;
        } else {
            let err = io::Error::last_os_error();
            if err.kind() == io::ErrorKind::Interrupted {
                continue;
            }
            return Err(err);
        }
    }

    Ok(true)
}

/// Follow a file for new data (basic implementation)
#[cfg(target_os = "linux")]
pub fn follow_file(filename: &str, config: &TailConfig, out: &mut impl Write) -> io::Result<()> {
    use std::thread;
    use std::time::Duration;

    let sleep_duration = Duration::from_secs_f64(config.sleep_interval);
    let path = Path::new(filename);

    let mut last_size = match std::fs::metadata(path) {
        Ok(m) => m.len(),
        Err(_) => 0,
    };

    loop {
        // Check PID if set
        if let Some(pid) = config.pid {
            if unsafe { libc::kill(pid as i32, 0) } != 0 {
                break;
            }
        }

        thread::sleep(sleep_duration);

        let current_size = match std::fs::metadata(path) {
            Ok(m) => m.len(),
            Err(_) => {
                if config.retry {
                    continue;
                }
                break;
            }
        };

        if current_size > last_size {
            // Read new data
            let file = std::fs::File::open(path)?;
            use std::os::unix::io::AsRawFd;
            let in_fd = file.as_raw_fd();
            let stdout = io::stdout();
            let out_fd = stdout.as_raw_fd();
            let mut offset = last_size as libc::off_t;
            let mut remaining = current_size - last_size; // u64, safe on 32-bit

            while remaining > 0 {
                let chunk = remaining.min(0x7fff_f000) as usize;
                let ret = unsafe { libc::sendfile(out_fd, in_fd, &mut offset, chunk) };
                if ret > 0 {
                    remaining -= ret as u64;
                } else if ret == 0 {
                    break;
                } else {
                    let err = io::Error::last_os_error();
                    if err.kind() == io::ErrorKind::Interrupted {
                        continue;
                    }
                    return Err(err);
                }
            }
            let _ = out.flush();
            last_size = current_size;
        } else if current_size < last_size {
            // File was truncated
            last_size = current_size;
        }
    }

    Ok(())
}

#[cfg(not(target_os = "linux"))]
pub fn follow_file(filename: &str, config: &TailConfig, out: &mut impl Write) -> io::Result<()> {
    use std::io::{Read, Seek};
    use std::thread;
    use std::time::Duration;

    let sleep_duration = Duration::from_secs_f64(config.sleep_interval);
    let path = Path::new(filename);

    let mut last_size = match std::fs::metadata(path) {
        Ok(m) => m.len(),
        Err(_) => 0,
    };

    loop {
        thread::sleep(sleep_duration);

        let current_size = match std::fs::metadata(path) {
            Ok(m) => m.len(),
            Err(_) => {
                if config.retry {
                    continue;
                }
                break;
            }
        };

        if current_size > last_size {
            let mut file = std::fs::File::open(path)?;
            file.seek(io::SeekFrom::Start(last_size))?;
            let mut buf = vec![0u8; (current_size - last_size) as usize];
            file.read_exact(&mut buf)?;
            out.write_all(&buf)?;
            out.flush()?;
            last_size = current_size;
        } else if current_size < last_size {
            last_size = current_size;
        }
    }

    Ok(())
}
