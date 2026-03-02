// fyes — output a string repeatedly until killed
//
// Usage: yes [STRING]...
// Repeatedly output a line with all specified STRING(s), or 'y'.

use std::process;
#[cfg(unix)]
use std::sync::atomic::{AtomicBool, Ordering};

const TOOL_NAME: &str = "yes";
const VERSION: &str = env!("CARGO_PKG_VERSION");

/// Buffer size for bulk writes. 128KB is 2x the default Linux pipe buffer
/// (64KB) and large enough to amortize syscall overhead while staying in
/// L2 cache. Outperforms GNU yes's 8KB BUFSIZ for both pipe and /dev/null.
const BUF_SIZE: usize = 128 * 1024;

/// True if the inherited SIGPIPE handler (before Rust's runtime overwrites it)
/// was SIG_IGN. Captured by a pre-main() constructor.
#[cfg(unix)]
static INHERITED_SIGPIPE_IGN: AtomicBool = AtomicBool::new(false);

/// Pre-main() constructor that captures the inherited SIGPIPE handler before
/// Rust's runtime sets it to SIG_IGN in `reset_sigpipe()`.
///
/// .init_array / __mod_init_func constructors run after the dynamic linker
/// but before `main()` (and thus before Rust's `lang_start()` → `init()` →
/// `reset_sigpipe()`), so the handler at this point is whatever the parent
/// process (usually bash) set up via exec().
///
/// GNU yes (a C binary) inherits its SIGPIPE handler directly. In normal
/// shells, bash passes SIG_DFL → SIGPIPE kills silently. Under Node.js CI
/// runners, bash inherits and preserves SIG_IGN (POSIX requirement for
/// terminating signals) → write() returns EPIPE → error message printed.
#[cfg(unix)]
unsafe extern "C" fn sigpipe_check_init() {
    unsafe {
        let mut old: libc::sigaction = std::mem::zeroed();
        if libc::sigaction(libc::SIGPIPE, std::ptr::null(), &mut old) == 0
            && old.sa_sigaction == libc::SIG_IGN
        {
            INHERITED_SIGPIPE_IGN.store(true, Ordering::Relaxed);
        }
    }
}

#[cfg(target_os = "linux")]
#[used]
#[unsafe(link_section = ".init_array")]
static SIGPIPE_INIT: unsafe extern "C" fn() = sigpipe_check_init;

#[cfg(target_os = "macos")]
#[used]
#[unsafe(link_section = "__DATA,__mod_init_func")]
static SIGPIPE_INIT: unsafe extern "C" fn() = sigpipe_check_init;

fn main() {
    // Match GNU yes's SIGPIPE behavior exactly. The pre-main() constructor
    // captured the inherited SIGPIPE handler before Rust changed it.
    //
    // If inherited SIG_DFL: restore it so SIGPIPE kills us silently.
    // If inherited SIG_IGN: keep Rust's SIG_IGN, write() returns EPIPE,
    // and our error handler prints the message (matching GNU yes).
    #[cfg(unix)]
    unsafe {
        if !INHERITED_SIGPIPE_IGN.load(Ordering::Relaxed) {
            let mut sa: libc::sigaction = std::mem::zeroed();
            sa.sa_sigaction = libc::SIG_DFL;
            sa.sa_flags = 0;
            libc::sigemptyset(&mut sa.sa_mask);
            libc::sigaction(libc::SIGPIPE, &sa, std::ptr::null_mut());
        }
    }

    let raw_args: Vec<String> = std::env::args().skip(1).collect();

    // GNU yes: scan args BEFORE "--" for --help / --version (GNU permutation behavior)
    // Once "--" is seen, --help/--version are literal strings, not options.
    // Unknown long options (--anything) and short options (-x) are rejected.
    // Bare "-" is treated as a literal string.
    for arg in &raw_args {
        if arg == "--" {
            break; // stop scanning for options
        }
        match arg.as_str() {
            "--help" => {
                println!("Usage: {} [STRING]...", TOOL_NAME);
                println!("  or:  {} OPTION", TOOL_NAME);
                println!("Repeatedly output a line with all specified STRING(s), or 'y'.");
                println!();
                println!("      --help     display this help and exit");
                println!("      --version  output version information and exit");
                process::exit(0);
            }
            "--version" => {
                println!("{} (fcoreutils) {}", TOOL_NAME, VERSION);
                process::exit(0);
            }
            s if s.starts_with("--") => {
                eprintln!(
                    "{}: unrecognized option '{}'\nTry '{} --help' for more information.",
                    TOOL_NAME, s, TOOL_NAME
                );
                process::exit(1);
            }
            s if s.starts_with('-') && s.len() > 1 => {
                let first_char = s.as_bytes()[1] as char;
                eprintln!(
                    "{}: invalid option -- '{}'\nTry '{} --help' for more information.",
                    TOOL_NAME, first_char, TOOL_NAME
                );
                process::exit(1);
            }
            _ => {}
        }
    }

    // Build output from remaining args (unknown options already rejected above).
    // The first "--" terminates option scanning; subsequent args are literal.
    // Bare "-" is treated as a literal string (not an option).
    let mut end_of_opts = false;
    let mut output_args: Vec<&str> = Vec::new();

    for arg in &raw_args {
        if end_of_opts {
            output_args.push(arg.as_str());
            continue;
        }

        if arg == "--" {
            end_of_opts = true;
            continue;
        }

        output_args.push(arg.as_str());
    }

    let line = if output_args.is_empty() {
        "y\n".to_string()
    } else {
        let mut s = output_args.join(" ");
        s.push('\n');
        s
    };

    let line_bytes = line.as_bytes();
    let line_len = line_bytes.len();

    // Try to increase stdout pipe buffer to 1MB for fewer context switches.
    // Best-effort — fails silently on non-pipes or restricted environments.
    // Read back actual pipe size to clamp write buffer accordingly.
    #[cfg(target_os = "linux")]
    let actual_pipe_sz = unsafe {
        libc::fcntl(1, libc::F_SETPIPE_SZ, 1024 * 1024);
        let sz = libc::fcntl(1, libc::F_GETPIPE_SZ);
        if sz > 0 { sz as usize } else { BUF_SIZE }
    };
    #[cfg(not(target_os = "linux"))]
    let actual_pipe_sz = BUF_SIZE;

    // Clamp write buffer to actual pipe size to avoid stalling on smaller pipes.
    // On default 64KB pipes (when F_SETPIPE_SZ fails), this uses 64KB instead of 128KB.
    let buf_target = BUF_SIZE.min(actual_pipe_sz);

    // Build a buffer filled with repeated copies of the line.
    // The buffer length is always an exact multiple of line_len so that
    // every write boundary falls between complete lines. This prevents
    // partial lines from appearing when downstream consumers (e.g.,
    // `head -n 2 | uniq`) read at write boundaries.
    //
    // When a single line is already >= buf_target, use exactly one copy
    // to avoid allocating a needlessly huge buffer.
    let buf = if line_len >= buf_target {
        line_bytes.to_vec()
    } else {
        // Number of copies that fills at least buf_target bytes,
        // rounded up to a full line.
        let copies = buf_target.div_ceil(line_len);
        let mut v = Vec::with_capacity(copies * line_len);
        for _ in 0..copies {
            v.extend_from_slice(line_bytes);
        }
        v
    };
    let total = buf.len();

    // Raw write(2) loop — with SIGPIPE=SIG_DFL, a write to a closed pipe
    // delivers SIGPIPE which kills the process (matching GNU yes behavior).
    //
    // Hot loop optimized: the fast path (full write) is a tight
    // syscall-compare-jump loop. Error handling is in a cold #[inline(never)]
    // function to keep the hot path's instruction footprint small.
    let ptr = buf.as_ptr();
    write_loop(ptr, total);
}

/// Hot write loop — separated from main() so the compiler can optimize it
/// independently. Uses inline syscall on x86_64 Linux to bypass libc's
/// PLT indirection and errno-setting overhead.
#[inline(never)]
fn write_loop(ptr: *const u8, total: usize) -> ! {
    let total_isize = total as isize;

    #[cfg(all(target_os = "linux", target_arch = "x86_64"))]
    loop {
        // Inline syscall: write(1, ptr, total)
        let ret: isize;
        unsafe {
            std::arch::asm!(
                "syscall",
                in("rax") 1_u64,       // SYS_write
                in("rdi") 1_u64,       // fd = stdout
                in("rsi") ptr,         // buf
                in("rdx") total,       // count
                lateout("rax") ret,
                lateout("rcx") _,      // clobbered by syscall
                lateout("r11") _,      // clobbered by syscall
                options(nostack),
            );
        }
        if ret == total_isize {
            continue; // fast path: full write
        }
        if ret > 0 {
            // Partial write — drain remainder via libc (rare path)
            drain_partial(ptr, total, ret as usize);
            continue;
        }
        if ret == 0 {
            // write(2) returned 0 for non-zero count — exit to avoid spin.
            process::exit(1);
        }
        // Negative return = -errno
        let errno = (-ret) as i32;
        if errno == libc::EINTR {
            continue;
        }
        let err = std::io::Error::from_raw_os_error(errno);
        write_error_and_exit(&err);
    }

    #[cfg(not(all(target_os = "linux", target_arch = "x86_64")))]
    loop {
        let ret = unsafe { libc::write(1, ptr as *const libc::c_void, total as _) };
        if ret as isize == total_isize {
            continue;
        }
        if ret > 0 {
            drain_partial(ptr, total, ret as usize);
            continue;
        }
        if ret == 0 {
            process::exit(1);
        }
        let err = std::io::Error::last_os_error();
        if err.kind() == std::io::ErrorKind::Interrupted {
            continue;
        }
        write_error_and_exit(&err);
    }
}

/// Drain remaining bytes after a partial write. Rare path — kept out of
/// the hot loop to reduce instruction cache pressure.
#[cold]
#[inline(never)]
fn drain_partial(ptr: *const u8, total: usize, initial: usize) {
    let mut written = initial;
    while written < total {
        let r = unsafe {
            libc::write(
                1,
                ptr.add(written) as *const libc::c_void,
                (total - written) as _,
            )
        };
        if r > 0 {
            written += r as usize;
        } else if r == 0 {
            process::exit(1);
        } else {
            let e = std::io::Error::last_os_error();
            if e.kind() == std::io::ErrorKind::Interrupted {
                continue;
            }
            write_error_and_exit(&e);
        }
    }
}

/// Write error diagnostic to stderr and exit. Cold path — never inlined
/// to keep the hot loop's instruction footprint minimal.
#[cold]
#[inline(never)]
fn write_error_and_exit(err: &std::io::Error) -> ! {
    let msg = coreutils_rs::common::io_error_msg(err);
    let error_line = format!("{}: standard output: {}\n", TOOL_NAME, msg);
    let _ = unsafe {
        libc::write(
            2,
            error_line.as_ptr() as *const libc::c_void,
            error_line.len() as _,
        )
    };
    #[cfg(unix)]
    unsafe {
        libc::_exit(1)
    };
    #[cfg(not(unix))]
    process::exit(1);
}

#[cfg(test)]
mod tests {
    use std::io::Read;
    use std::process::{Command, Stdio};

    fn cmd() -> Command {
        let mut path = std::env::current_exe().unwrap();
        path.pop();
        path.pop();
        path.push("fyes");
        Command::new(path)
    }

    #[test]
    fn test_yes_default_y() {
        let mut child = cmd().stdout(Stdio::piped()).spawn().unwrap();

        let mut stdout = child.stdout.take().unwrap();
        let mut buf = Vec::new();
        let mut tmp = [0u8; 4096];
        while buf.len() < 10 {
            let n = stdout.read(&mut tmp).unwrap();
            if n == 0 {
                break;
            }
            buf.extend_from_slice(&tmp[..n]);
        }
        drop(stdout);
        let _ = child.kill();
        let _ = child.wait();

        let text = String::from_utf8_lossy(&buf);
        let lines: Vec<&str> = text.lines().collect();
        assert!(
            lines.len() >= 5,
            "Expected at least 5 lines, got {}",
            lines.len()
        );
        for line in &lines[..5] {
            assert_eq!(*line, "y");
        }
    }

    #[test]
    fn test_yes_custom_string() {
        let mut child = cmd().arg("hello").stdout(Stdio::piped()).spawn().unwrap();

        let mut stdout = child.stdout.take().unwrap();
        let mut buf = Vec::new();
        let mut tmp = [0u8; 4096];
        while buf.len() < 20 {
            let n = stdout.read(&mut tmp).unwrap();
            if n == 0 {
                break;
            }
            buf.extend_from_slice(&tmp[..n]);
        }
        drop(stdout);
        let _ = child.kill();
        let _ = child.wait();

        let text = String::from_utf8_lossy(&buf);
        let lines: Vec<&str> = text.lines().collect();
        assert!(
            lines.len() >= 3,
            "Expected at least 3 lines, got {}",
            lines.len()
        );
        for line in &lines[..3] {
            assert_eq!(*line, "hello");
        }
    }

    #[test]
    fn test_yes_multiple_args() {
        let mut child = cmd()
            .args(["a", "b"])
            .stdout(Stdio::piped())
            .spawn()
            .unwrap();

        let mut stdout = child.stdout.take().unwrap();
        let mut buf = Vec::new();
        let mut tmp = [0u8; 4096];
        while buf.len() < 20 {
            let n = stdout.read(&mut tmp).unwrap();
            if n == 0 {
                break;
            }
            buf.extend_from_slice(&tmp[..n]);
        }
        drop(stdout);
        let _ = child.kill();
        let _ = child.wait();

        let text = String::from_utf8_lossy(&buf);
        let lines: Vec<&str> = text.lines().collect();
        assert!(
            lines.len() >= 2,
            "Expected at least 2 lines, got {}",
            lines.len()
        );
        for line in &lines[..2] {
            assert_eq!(*line, "a b");
        }
    }

    #[test]
    fn test_yes_dash_dash_strips_separator() {
        // yes -- foo should output "foo", not "-- foo"
        let mut child = cmd()
            .args(["--", "foo"])
            .stdout(Stdio::piped())
            .spawn()
            .unwrap();

        let mut stdout = child.stdout.take().unwrap();
        let mut buf = Vec::new();
        let mut tmp = [0u8; 4096];
        while buf.len() < 20 {
            let n = stdout.read(&mut tmp).unwrap();
            if n == 0 {
                break;
            }
            buf.extend_from_slice(&tmp[..n]);
        }
        drop(stdout);
        let _ = child.kill();
        let _ = child.wait();

        let text = String::from_utf8_lossy(&buf);
        let lines: Vec<&str> = text.lines().collect();
        assert!(lines.len() >= 2);
        for line in &lines[..2] {
            assert_eq!(*line, "foo");
        }
    }

    #[test]
    fn test_yes_dash_dash_alone_gives_y() {
        // yes -- should output "y", not "--"
        let mut child = cmd().arg("--").stdout(Stdio::piped()).spawn().unwrap();

        let mut stdout = child.stdout.take().unwrap();
        let mut buf = Vec::new();
        let mut tmp = [0u8; 4096];
        while buf.len() < 20 {
            let n = stdout.read(&mut tmp).unwrap();
            if n == 0 {
                break;
            }
            buf.extend_from_slice(&tmp[..n]);
        }
        drop(stdout);
        let _ = child.kill();
        let _ = child.wait();

        let text = String::from_utf8_lossy(&buf);
        let lines: Vec<&str> = text.lines().collect();
        assert!(lines.len() >= 2);
        for line in &lines[..2] {
            assert_eq!(*line, "y");
        }
    }

    #[test]
    fn test_yes_pipe_closes() {
        // yes piped to head should terminate (killed by SIGPIPE)
        let mut child = cmd()
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .unwrap();
        let child_stdout = child.stdout.take().unwrap();

        let head = Command::new("head")
            .arg("-n")
            .arg("1")
            .stdin(child_stdout)
            .stdout(Stdio::piped())
            .output()
            .unwrap();

        // Wait for the child process
        let status = child.wait().unwrap();

        assert_eq!(head.status.code(), Some(0));
        let text = String::from_utf8_lossy(&head.stdout);
        assert_eq!(text.trim(), "y");

        // With SIGPIPE unblocked: killed by SIGPIPE. With SIGPIPE blocked: EPIPE fallback exits 1.
        #[cfg(unix)]
        {
            use std::os::unix::process::ExitStatusExt;
            assert!(
                status.signal() == Some(13) || status.code() == Some(1),
                "yes should be killed by SIGPIPE or exit 1, got status: {:?}",
                status
            );
        }
    }

    #[test]
    #[cfg(unix)]
    fn test_yes_broken_pipe_terminates() {
        // When stdout is closed, yes should be killed by SIGPIPE.
        let mut child = cmd()
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .unwrap();

        // Read a few bytes then close stdout to trigger SIGPIPE
        let mut stdout = child.stdout.take().unwrap();
        let mut buf = [0u8; 4];
        let _ = std::io::Read::read(&mut stdout, &mut buf);
        drop(stdout);

        let status = child.wait().unwrap();

        use std::os::unix::process::ExitStatusExt;
        assert!(
            status.signal() == Some(13) || status.code() == Some(1),
            "yes should be killed by SIGPIPE or exit 0/1, got status: {:?}",
            status
        );
    }

    #[test]
    #[cfg(unix)]
    fn test_yes_matches_gnu() {
        // Compare first 1000 lines with GNU yes
        let gnu = Command::new("sh")
            .args(["-c", "yes | head -n 1000"])
            .output();
        if let Ok(gnu) = gnu {
            let ours = Command::new("sh")
                .args([
                    "-c",
                    &format!("{} | head -n 1000", cmd().get_program().to_str().unwrap()),
                ])
                .output()
                .unwrap();
            assert_eq!(
                String::from_utf8_lossy(&ours.stdout),
                String::from_utf8_lossy(&gnu.stdout),
                "Output mismatch with GNU yes"
            );
        }
    }

    /// Helper: run `fyes <padded_arg> | head -n 2` and verify both lines are identical.
    /// This catches buffer-boundary splits that produce partial lines.
    #[cfg(unix)]
    fn assert_padded_string_unique(pad_len: usize) {
        let padded: String = " ".repeat(pad_len);
        let mut child = cmd().arg(&padded).stdout(Stdio::piped()).spawn().unwrap();

        let child_stdout = child.stdout.take().unwrap();

        let head = Command::new("head")
            .args(["-n", "2"])
            .stdin(child_stdout)
            .stdout(Stdio::piped())
            .output()
            .unwrap();

        let _ = child.kill();
        let _ = child.wait();

        let text = String::from_utf8_lossy(&head.stdout);
        let lines: Vec<&str> = text.lines().collect();
        assert_eq!(
            lines.len(),
            2,
            "pad_len={}: expected 2 lines from head, got {}",
            pad_len,
            lines.len()
        );
        assert_eq!(
            lines[0],
            lines[1],
            "pad_len={}: the two lines differ (buffer split mid-line)\n  line0 len={}\n  line1 len={}",
            pad_len,
            lines[0].len(),
            lines[1].len()
        );
        assert_eq!(
            lines[0].len(),
            pad_len,
            "pad_len={}: line length mismatch",
            pad_len
        );
    }

    #[test]
    #[cfg(unix)]
    fn test_yes_1999_char_padded_string() {
        assert_padded_string_unique(1999);
    }

    #[test]
    #[cfg(unix)]
    fn test_yes_4095_char_padded_string() {
        assert_padded_string_unique(4095);
    }

    #[test]
    #[cfg(unix)]
    fn test_yes_4096_char_padded_string() {
        assert_padded_string_unique(4096);
    }

    #[test]
    #[cfg(unix)]
    fn test_yes_8191_char_padded_string() {
        assert_padded_string_unique(8191);
    }

    #[test]
    #[cfg(unix)]
    fn test_yes_8192_char_padded_string() {
        assert_padded_string_unique(8192);
    }

    /// Verify that yes terminates cleanly when piped through head.
    #[test]
    #[cfg(unix)]
    fn test_yes_pipeline_terminates() {
        let mut child = cmd()
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .unwrap();

        let child_stdout = child.stdout.take().unwrap();

        // Pipe through head -n 5 to trigger SIGPIPE
        let head = Command::new("head")
            .args(["-n", "5"])
            .stdin(child_stdout)
            .stdout(Stdio::piped())
            .output()
            .unwrap();

        let status = child.wait().unwrap();

        assert_eq!(head.status.code(), Some(0));

        use std::os::unix::process::ExitStatusExt;
        assert!(
            status.signal() == Some(13) || status.code() == Some(1),
            "yes should be killed by SIGPIPE or exit 0/1, got status: {:?}",
            status
        );
    }

    #[test]
    fn test_yes_unknown_long_option() {
        let output = cmd()
            .arg("--badopt")
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .output()
            .unwrap();

        assert_eq!(output.status.code(), Some(1));
        let stderr = String::from_utf8_lossy(&output.stderr);
        assert!(
            stderr.contains("yes: unrecognized option '--badopt'"),
            "stderr should contain unrecognized option message, got: {}",
            stderr
        );
        assert!(
            stderr.contains("Try 'yes --help' for more information."),
            "stderr should contain help hint, got: {}",
            stderr
        );
    }

    #[test]
    fn test_yes_unknown_short_option() {
        let output = cmd()
            .arg("-z")
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .output()
            .unwrap();

        assert_eq!(output.status.code(), Some(1));
        let stderr = String::from_utf8_lossy(&output.stderr);
        assert!(
            stderr.contains("yes: invalid option -- 'z'"),
            "stderr should contain invalid option message, got: {}",
            stderr
        );
        assert!(
            stderr.contains("Try 'yes --help' for more information."),
            "stderr should contain help hint, got: {}",
            stderr
        );
    }

    #[test]
    fn test_yes_bare_dash_is_literal() {
        // Bare "-" should be treated as literal string, not an option
        let mut child = cmd().arg("-").stdout(Stdio::piped()).spawn().unwrap();

        let mut stdout = child.stdout.take().unwrap();
        let mut buf = Vec::new();
        let mut tmp = [0u8; 4096];
        while buf.len() < 10 {
            let n = stdout.read(&mut tmp).unwrap();
            if n == 0 {
                break;
            }
            buf.extend_from_slice(&tmp[..n]);
        }
        drop(stdout);
        let _ = child.kill();
        let _ = child.wait();

        let text = String::from_utf8_lossy(&buf);
        let lines: Vec<&str> = text.lines().collect();
        assert!(lines.len() >= 2);
        for line in &lines[..2] {
            assert_eq!(*line, "-");
        }
    }

    #[test]
    fn test_yes_option_after_dashdash_is_literal() {
        // yes -- --badopt should output "--badopt" as a literal string
        let mut child = cmd()
            .args(["--", "--badopt"])
            .stdout(Stdio::piped())
            .spawn()
            .unwrap();

        let mut stdout = child.stdout.take().unwrap();
        let mut buf = Vec::new();
        let mut tmp = [0u8; 4096];
        while buf.len() < 20 {
            let n = stdout.read(&mut tmp).unwrap();
            if n == 0 {
                break;
            }
            buf.extend_from_slice(&tmp[..n]);
        }
        drop(stdout);
        let _ = child.kill();
        let _ = child.wait();

        let text = String::from_utf8_lossy(&buf);
        let lines: Vec<&str> = text.lines().collect();
        assert!(lines.len() >= 2);
        for line in &lines[..2] {
            assert_eq!(*line, "--badopt");
        }
    }
}
