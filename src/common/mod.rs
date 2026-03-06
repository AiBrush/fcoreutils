pub mod io;

/// Get the GNU-compatible tool name by stripping the 'f' prefix.
/// e.g., "fmd5sum" -> "md5sum", "fcut" -> "cut"
#[inline]
pub fn gnu_name(binary_name: &str) -> &str {
    binary_name.strip_prefix('f').unwrap_or(binary_name)
}

/// Reset SIGPIPE to default behavior (SIG_DFL) for GNU coreutils compatibility.
/// Rust sets SIGPIPE to SIG_IGN by default, but GNU tools are killed by SIGPIPE
/// (exit code 141 = 128 + 13). This must be called at the start of main().
#[inline]
pub fn reset_sigpipe() {
    #[cfg(unix)]
    unsafe {
        libc::signal(libc::SIGPIPE, libc::SIG_DFL);
    }
}

/// Enlarge stdout pipe buffer on Linux for higher throughput.
/// Only enlarges stdout (fd 1) when it is actually a pipe.
/// Tries 8MB first (best for large data), falls back to 1MB then 256KB.
/// Silently no-ops on non-pipes, non-Linux, or restricted environments.
#[cfg(target_os = "linux")]
pub fn enlarge_stdout_pipe() {
    let mut stat: libc::stat = unsafe { std::mem::zeroed() };
    if unsafe { libc::fstat(1, &mut stat) } != 0 {
        return;
    }
    if (stat.st_mode & libc::S_IFMT) != libc::S_IFIFO {
        return;
    }
    for &size in &[8 * 1024 * 1024i32, 1024 * 1024, 256 * 1024] {
        if unsafe { libc::fcntl(1, libc::F_SETPIPE_SZ, size) } > 0 {
            break;
        }
    }
}

#[cfg(not(target_os = "linux"))]
pub fn enlarge_stdout_pipe() {}

/// Enlarge stdin pipe buffer on Linux for higher throughput on piped input.
/// Only enlarges stdin (fd 0) when it is actually a pipe.
/// Tries 8MB first (best for large data), falls back to 1MB then 256KB.
/// Silently no-ops on non-pipes, non-Linux, or restricted environments.
#[cfg(target_os = "linux")]
pub fn enlarge_stdin_pipe() {
    let mut stat: libc::stat = unsafe { std::mem::zeroed() };
    if unsafe { libc::fstat(0, &mut stat) } != 0 {
        return;
    }
    if (stat.st_mode & libc::S_IFMT) != libc::S_IFIFO {
        return;
    }
    for &size in &[8 * 1024 * 1024i32, 1024 * 1024, 256 * 1024] {
        if unsafe { libc::fcntl(0, libc::F_SETPIPE_SZ, size) } > 0 {
            break;
        }
    }
}

#[cfg(not(target_os = "linux"))]
pub fn enlarge_stdin_pipe() {}

/// Format an IO error message without the "(os error N)" suffix.
/// GNU coreutils prints e.g. "No such file or directory" while Rust's
/// Display impl adds " (os error 2)". This strips the suffix for compat.
#[cold]
#[inline(never)]
pub fn io_error_msg(e: &std::io::Error) -> String {
    if let Some(raw) = e.raw_os_error() {
        let os_err = std::io::Error::from_raw_os_error(raw);
        let msg = format!("{}", os_err);
        msg.replace(&format!(" (os error {})", raw), "")
    } else {
        format!("{}", e)
    }
}
