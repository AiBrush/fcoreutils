// fyes — output a string repeatedly until killed
//
// Usage: yes [STRING]...
// Repeatedly output a line with all specified STRING(s), or 'y'.

use std::process;

const TOOL_NAME: &str = "yes";
const VERSION: &str = env!("CARGO_PKG_VERSION");

/// Buffer size for bulk writes (1MB matches F_SETPIPE_SZ for minimal syscalls).
const BUF_SIZE: usize = 1024 * 1024;

/// Handle write error: print message to stderr and exit with code 1.
/// GNU yes prints "yes: standard output: Broken pipe" on EPIPE and exits 1.
fn write_error_exit(err: std::io::Error) -> ! {
    let msg = coreutils_rs::common::io_error_msg(&err);
    eprintln!("{}: standard output: {}", TOOL_NAME, msg);
    process::exit(1);
}

fn main() {
    // Keep Rust's default SIGPIPE=SIG_IGN so write() returns EPIPE instead
    // of killing us. This lets us always print "yes: standard output: Broken pipe"
    // matching GNU yes behavior (which prints this via error() on write failure).

    let raw_args: Vec<String> = std::env::args().skip(1).collect();

    // GNU yes: scan args BEFORE "--" for --help / --version (GNU permutation behavior)
    // Once "--" is seen, --help/--version are literal strings, not options.
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
            _ => {}
        }
    }

    // GNU yes argument processing:
    // - The first "--" terminates option scanning; remaining args are literal strings
    // - ALL other arguments (including --unknown, -x) are treated as literal output strings
    // - Bare "-" is treated as a literal string (not an option)
    let mut end_of_opts = false;
    let mut output_args: Vec<&str> = Vec::new();

    for arg in &raw_args {
        if end_of_opts {
            output_args.push(arg.as_str());
            continue;
        }

        if arg == "--" {
            // First "--" is consumed; subsequent args are literal
            end_of_opts = true;
            continue;
        }

        // Regular argument (including bare "-", --unknown, -x)
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

    // Build a buffer filled with repeated copies of the line.
    // The buffer length is always an exact multiple of line_len so that
    // every write boundary falls between complete lines. This prevents
    // partial lines from appearing when downstream consumers (e.g.,
    // `head -n 2 | uniq`) read at write boundaries.
    //
    // When a single line is already >= BUF_SIZE, use exactly one copy
    // to avoid allocating a needlessly huge buffer.
    let buf = if line_len >= BUF_SIZE {
        line_bytes.to_vec()
    } else {
        // Number of copies that fills at least BUF_SIZE bytes,
        // rounded up to a full line.
        let copies = BUF_SIZE.div_ceil(line_len);
        let mut v = Vec::with_capacity(copies * line_len);
        for _ in 0..copies {
            v.extend_from_slice(line_bytes);
        }
        v
    };
    let total = buf.len();

    // Enlarge pipe buffer to match our write size for minimal syscalls
    #[cfg(target_os = "linux")]
    unsafe {
        libc::fcntl(1, libc::F_SETPIPE_SZ, total as libc::c_int);
    }

    // Raw write(2) loop — simpler and faster than vmsplice (which without
    // SPLICE_F_GIFT copies into pipe buffers anyway, with extra overhead)
    let ptr = buf.as_ptr();
    loop {
        let mut written = 0usize;
        while written < total {
            let ret = unsafe {
                libc::write(
                    1,
                    ptr.add(written) as *const libc::c_void,
                    (total - written) as _,
                )
            };
            if ret > 0 {
                written += ret as usize;
            } else if ret == 0 {
                break;
            } else {
                let err = std::io::Error::last_os_error();
                if err.kind() == std::io::ErrorKind::Interrupted {
                    continue;
                }
                write_error_exit(err);
            }
        }
    }
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
        // yes piped to head should terminate
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

        // Collect stderr
        let mut stderr = child.stderr.take().unwrap();
        let mut stderr_output = String::new();
        let _ = std::io::Read::read_to_string(&mut stderr, &mut stderr_output);

        // Wait for the child process to avoid zombie
        let status = child.wait().unwrap();

        assert_eq!(head.status.code(), Some(0));
        let text = String::from_utf8_lossy(&head.stdout);
        assert_eq!(text.trim(), "y");

        // yes handles EPIPE: prints error to stderr and exits 1
        assert_eq!(status.code(), Some(1), "yes should exit 1 on pipe close");
        assert!(
            stderr_output.contains("standard output"),
            "stderr should contain broken pipe message, got: {}",
            stderr_output
        );
    }

    #[test]
    #[cfg(unix)]
    fn test_yes_broken_pipe_terminates() {
        // When stdout is closed, yes should terminate with EPIPE handling.
        let mut child = cmd()
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .unwrap();

        // Read a few bytes then close stdout to trigger broken pipe
        let mut stdout = child.stdout.take().unwrap();
        let mut buf = [0u8; 4];
        let _ = std::io::Read::read(&mut stdout, &mut buf);
        drop(stdout);

        let mut stderr = child.stderr.take().unwrap();
        let mut stderr_output = String::new();
        let _ = std::io::Read::read_to_string(&mut stderr, &mut stderr_output);

        let status = child.wait().unwrap();

        // SIGPIPE is ignored, so EPIPE is always caught → error printed, exit 1
        assert_eq!(status.code(), Some(1), "yes should exit 1 on broken pipe");
        assert!(
            stderr_output.contains("standard output"),
            "stderr should contain broken pipe message, got: {}",
            stderr_output
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

        // Pipe through head -n 5 to trigger EPIPE
        let head = Command::new("head")
            .args(["-n", "5"])
            .stdin(child_stdout)
            .stdout(Stdio::piped())
            .output()
            .unwrap();

        // Collect stderr from yes
        let mut stderr = child.stderr.take().unwrap();
        let mut stderr_output = String::new();
        let _ = std::io::Read::read_to_string(&mut stderr, &mut stderr_output);

        let status = child.wait().unwrap();

        assert_eq!(head.status.code(), Some(0));
        // EPIPE always caught: error printed, exit 1
        assert_eq!(status.code(), Some(1));
        assert!(stderr_output.contains("standard output"));
    }
}
