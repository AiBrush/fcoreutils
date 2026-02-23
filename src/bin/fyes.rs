// fyes — output a string repeatedly until killed
//
// Usage: yes [STRING]...
// Repeatedly output a line with all specified STRING(s), or 'y'.

use std::process;

const TOOL_NAME: &str = "yes";
const VERSION: &str = env!("CARGO_PKG_VERSION");

/// Buffer size for bulk writes.
const BUF_SIZE: usize = 128 * 1024;

fn main() {
    coreutils_rs::common::reset_sigpipe();

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
    // - Unrecognized long options (--foo) → error to stderr, exit 1
    // - Invalid short options (-x) → error to stderr, exit 1
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

        if arg.starts_with("--") && arg.len() > 2 {
            // Unrecognized long option
            eprintln!("{}: unrecognized option '{}'", TOOL_NAME, arg);
            eprintln!("Try '{} --help' for more information.", TOOL_NAME);
            process::exit(1);
        }

        if arg.starts_with('-') && arg.len() > 1 {
            // Invalid short option — report first char after '-'
            let c = arg.chars().nth(1).unwrap_or('?');
            eprintln!("{}: invalid option -- '{}'", TOOL_NAME, c);
            eprintln!("Try '{} --help' for more information.", TOOL_NAME);
            process::exit(1);
        }

        // Regular argument (including bare "-")
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

    // Build a large buffer filled with repeated copies of the line.
    let mut buf = Vec::with_capacity(BUF_SIZE + line_bytes.len());
    while buf.len() < BUF_SIZE {
        buf.extend_from_slice(line_bytes);
    }

    // Try to enlarge pipe buffer for higher throughput
    #[cfg(target_os = "linux")]
    unsafe {
        libc::fcntl(1, libc::F_SETPIPE_SZ, 1024 * 1024);
    }

    // Try vmsplice for zero-copy pipe output on Linux
    #[cfg(target_os = "linux")]
    {
        let iov = libc::iovec {
            iov_base: buf.as_ptr() as *mut libc::c_void,
            iov_len: buf.len(),
        };
        // Test if stdout is a pipe that supports vmsplice
        let ret = unsafe { libc::vmsplice(1, &iov, 1, 0) };
        if ret > 0 {
            // vmsplice works - use it for maximum throughput
            loop {
                let ret = unsafe { libc::vmsplice(1, &iov, 1, 0) };
                if ret <= 0 {
                    let err = std::io::Error::last_os_error();
                    if err.kind() == std::io::ErrorKind::Interrupted {
                        continue;
                    }
                    break;
                }
            }
            process::exit(0);
        }
    }

    // Fallback: raw write(2) to fd 1
    loop {
        let ret = unsafe { libc::write(1, buf.as_ptr() as *const libc::c_void, buf.len() as _) };
        if ret <= 0 {
            let err = std::io::Error::last_os_error();
            if err.kind() == std::io::ErrorKind::Interrupted {
                continue;
            }
            break;
        }
    }
    process::exit(0);
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
    fn test_yes_unknown_long_option_errors() {
        let out = cmd().arg("--badopt").output().unwrap();
        assert_ne!(
            out.status.code(),
            Some(0),
            "Should exit non-zero for --badopt"
        );
        let stderr = String::from_utf8_lossy(&out.stderr);
        assert!(
            stderr.contains("unrecognized option"),
            "Should print error: {}",
            stderr
        );
    }

    #[test]
    fn test_yes_unknown_short_option_errors() {
        let out = cmd().arg("-z").output().unwrap();
        assert_ne!(out.status.code(), Some(0), "Should exit non-zero for -z");
        let stderr = String::from_utf8_lossy(&out.stderr);
        assert!(
            stderr.contains("invalid option"),
            "Should print error: {}",
            stderr
        );
    }

    #[test]
    fn test_yes_pipe_closes() {
        // yes piped to head should terminate
        let mut child = cmd().stdout(Stdio::piped()).spawn().unwrap();
        let child_stdout = child.stdout.take().unwrap();

        let head = Command::new("head")
            .arg("-n")
            .arg("1")
            .stdin(child_stdout)
            .stdout(Stdio::piped())
            .output()
            .unwrap();

        // Wait for the child process to avoid zombie
        let _ = child.wait();

        assert_eq!(head.status.code(), Some(0));
        let text = String::from_utf8_lossy(&head.stdout);
        assert_eq!(text.trim(), "y");
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
}
