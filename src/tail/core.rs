use std::io::{self, Write};
use std::path::Path;

use memchr::{memchr_iter, memrchr_iter};

use crate::common::io::{read_file, read_stdin, FileData};

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
pub fn tail_lines_from(
    data: &[u8],
    n: u64,
    delimiter: u8,
    out: &mut impl Write,
) -> io::Result<()> {
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
    use std::os::unix::fs::OpenOptionsExt;

    let file = std::fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOATIME)
        .open(path)
        .or_else(|_| std::fs::File::open(path))?;

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
    let mut remaining = n as usize;

    while remaining > 0 {
        let chunk = remaining.min(0x7ffff000);
        let ret = unsafe { libc::sendfile(out_fd, in_fd, &mut offset, chunk) };
        if ret > 0 {
            remaining -= ret as usize;
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

/// Process a single file/stdin for tail
pub fn tail_file(
    filename: &str,
    config: &TailConfig,
    out: &mut impl Write,
    tool_name: &str,
) -> io::Result<bool> {
    let delimiter = if config.zero_terminated {
        b'\0'
    } else {
        b'\n'
    };

    // For byte-count modes on files, try sendfile
    #[cfg(target_os = "linux")]
    if filename != "-" {
        match &config.mode {
            TailMode::Bytes(n) => {
                use std::os::unix::io::AsRawFd;
                let stdout = io::stdout();
                let out_fd = stdout.as_raw_fd();
                if let Ok(true) = sendfile_tail_bytes(Path::new(filename), *n, out_fd) {
                    return Ok(true);
                }
            }
            TailMode::BytesFrom(n) => {
                use std::os::unix::io::AsRawFd;
                let stdout = io::stdout();
                let out_fd = stdout.as_raw_fd();
                if let Ok(true) = sendfile_tail_bytes_from(Path::new(filename), *n, out_fd) {
                    return Ok(true);
                }
            }
            _ => {}
        }
    }

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
    use std::os::unix::fs::OpenOptionsExt;

    let file = std::fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOATIME)
        .open(path)
        .or_else(|_| std::fs::File::open(path))?;

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
    let mut remaining = (file_size - start) as usize;

    while remaining > 0 {
        let chunk = remaining.min(0x7ffff000);
        let ret = unsafe { libc::sendfile(out_fd, in_fd, &mut offset, chunk) };
        if ret > 0 {
            remaining -= ret as usize;
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
pub fn follow_file(
    filename: &str,
    config: &TailConfig,
    out: &mut impl Write,
) -> io::Result<()> {
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
            let mut remaining = (current_size - last_size) as usize;

            while remaining > 0 {
                let chunk = remaining.min(0x7ffff000);
                let ret = unsafe { libc::sendfile(out_fd, in_fd, &mut offset, chunk) };
                if ret > 0 {
                    remaining -= ret as usize;
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
pub fn follow_file(
    filename: &str,
    config: &TailConfig,
    out: &mut impl Write,
) -> io::Result<()> {
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
