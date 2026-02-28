use std::io::{self, BufWriter, Write};
#[cfg(unix)]
use std::mem::ManuallyDrop;
#[cfg(unix)]
use std::os::unix::io::FromRawFd;
use std::path::Path;
use std::process;

use coreutils_rs::common::io::{read_file, read_stdin};
use coreutils_rs::common::io_error_msg;
use coreutils_rs::rev;

struct Cli {
    files: Vec<String>,
}

fn parse_args() -> Cli {
    let mut cli = Cli { files: Vec::new() };

    let mut args = std::env::args_os().skip(1);
    #[allow(clippy::while_let_on_iterator)]
    while let Some(arg) = args.next() {
        let bytes = arg.as_encoded_bytes();
        if bytes == b"--" {
            for a in args {
                cli.files.push(a.to_string_lossy().into_owned());
            }
            break;
        }
        if bytes.starts_with(b"--") {
            match bytes {
                b"--help" => {
                    print!(
                        "Usage: rev [OPTION]... [FILE]...\n\
                         Reverse lines characterwise.\n\n\
                         With no FILE, or when FILE is -, read standard input.\n\n\
                         \x20     --help     display this help and exit\n\
                         \x20     --version  output version information and exit\n"
                    );
                    process::exit(0);
                }
                b"--version" => {
                    println!("rev (fcoreutils) {}", env!("CARGO_PKG_VERSION"));
                    process::exit(0);
                }
                _ => {
                    eprintln!("rev: unrecognized option '{}'", arg.to_string_lossy());
                    process::exit(1);
                }
            }
        } else if bytes.len() > 1 && bytes[0] == b'-' {
            // rev doesn't have short options, treat as file
            cli.files.push(arg.to_string_lossy().into_owned());
        } else {
            cli.files.push(arg.to_string_lossy().into_owned());
        }
    }

    cli
}

/// Enlarge pipe buffers on Linux for higher throughput.
#[cfg(target_os = "linux")]
fn enlarge_pipes() {
    for &fd in &[0i32, 1] {
        for &size in &[8 * 1024 * 1024i32, 1024 * 1024, 256 * 1024] {
            if unsafe { libc::fcntl(fd, libc::F_SETPIPE_SZ, size) } > 0 {
                break;
            }
        }
    }
}

fn main() {
    coreutils_rs::common::reset_sigpipe();

    #[cfg(target_os = "linux")]
    enlarge_pipes();

    let cli = parse_args();

    let files: Vec<String> = if cli.files.is_empty() {
        vec!["-".to_string()]
    } else {
        cli.files
    };

    // Use BufWriter for output
    #[cfg(unix)]
    let stdout_raw = unsafe { ManuallyDrop::new(std::fs::File::from_raw_fd(1)) };
    #[cfg(unix)]
    let mut out = BufWriter::with_capacity(256 * 1024, &*stdout_raw);
    #[cfg(not(unix))]
    let stdout = io::stdout();
    #[cfg(not(unix))]
    let mut out = BufWriter::with_capacity(256 * 1024, stdout.lock());

    let mut had_error = false;

    for filename in &files {
        let data = if filename == "-" {
            match read_stdin() {
                Ok(d) => coreutils_rs::common::io::FileData::Owned(d),
                Err(e) => {
                    eprintln!("rev: standard input: {}", io_error_msg(&e));
                    had_error = true;
                    continue;
                }
            }
        } else {
            match read_file(Path::new(filename)) {
                Ok(d) => d,
                Err(e) => {
                    eprintln!("rev: {}: {}", filename, io_error_msg(&e));
                    had_error = true;
                    continue;
                }
            }
        };

        if let Err(e) = rev::rev_bytes(&data, &mut out) {
            if e.kind() == io::ErrorKind::BrokenPipe {
                process::exit(0);
            }
            eprintln!("rev: write error: {}", io_error_msg(&e));
            had_error = true;
        }
    }

    if let Err(e) = out.flush()
        && e.kind() != io::ErrorKind::BrokenPipe
    {
        eprintln!("rev: write error: {}", io_error_msg(&e));
        had_error = true;
    }

    if had_error {
        process::exit(1);
    }
}

#[cfg(test)]
mod tests {
    use std::process::Command;

    fn cmd() -> Command {
        let mut path = std::env::current_exe().unwrap();
        path.pop();
        path.pop();
        path.push("frev");
        Command::new(path)
    }
    #[test]
    fn test_rev_basic_stdin() {
        use std::io::Write;
        use std::process::Stdio;
        let mut child = cmd()
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .spawn()
            .unwrap();
        child
            .stdin
            .take()
            .unwrap()
            .write_all(b"hello\nworld\n")
            .unwrap();
        let output = child.wait_with_output().unwrap();
        assert!(output.status.success());
        assert_eq!(String::from_utf8_lossy(&output.stdout), "olleh\ndlrow\n");
    }

    #[test]
    fn test_rev_empty_input() {
        use std::process::Stdio;
        let mut child = cmd()
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .spawn()
            .unwrap();
        drop(child.stdin.take().unwrap());
        let output = child.wait_with_output().unwrap();
        assert!(output.status.success());
        assert_eq!(output.stdout, b"");
    }

    #[test]
    fn test_rev_empty_line() {
        use std::io::Write;
        use std::process::Stdio;
        let mut child = cmd()
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .spawn()
            .unwrap();
        child.stdin.take().unwrap().write_all(b"\n").unwrap();
        let output = child.wait_with_output().unwrap();
        assert!(output.status.success());
        assert_eq!(String::from_utf8_lossy(&output.stdout), "\n");
    }

    #[test]
    fn test_rev_single_char() {
        use std::io::Write;
        use std::process::Stdio;
        let mut child = cmd()
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .spawn()
            .unwrap();
        child.stdin.take().unwrap().write_all(b"x\n").unwrap();
        let output = child.wait_with_output().unwrap();
        assert!(output.status.success());
        assert_eq!(String::from_utf8_lossy(&output.stdout), "x\n");
    }

    #[test]
    fn test_rev_no_trailing_newline() {
        use std::io::Write;
        use std::process::Stdio;
        let mut child = cmd()
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .spawn()
            .unwrap();
        child.stdin.take().unwrap().write_all(b"abc").unwrap();
        let output = child.wait_with_output().unwrap();
        assert!(output.status.success());
        // rev doesn't add newline if input has none
        assert_eq!(String::from_utf8_lossy(&output.stdout), "cba");
    }

    #[test]
    fn test_rev_multiple_empty_lines() {
        use std::io::Write;
        use std::process::Stdio;
        let mut child = cmd()
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .spawn()
            .unwrap();
        child.stdin.take().unwrap().write_all(b"\n\n\n").unwrap();
        let output = child.wait_with_output().unwrap();
        assert!(output.status.success());
        assert_eq!(String::from_utf8_lossy(&output.stdout), "\n\n\n");
    }

    #[test]
    fn test_rev_file() {
        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join("test.txt");
        std::fs::write(&file, "abcd\nefgh\n").unwrap();
        let output = cmd().arg(file.to_str().unwrap()).output().unwrap();
        assert!(output.status.success());
        assert_eq!(String::from_utf8_lossy(&output.stdout), "dcba\nhgfe\n");
    }

    #[cfg(unix)]
    #[test]
    fn test_rev_nonexistent_file() {
        let output = cmd().arg("/nonexistent_xyz_rev").output().unwrap();
        assert!(!output.status.success());
        let stderr = String::from_utf8_lossy(&output.stderr);
        assert!(stderr.contains("No such file"));
    }

    #[test]
    fn test_rev_multiple_files() {
        let dir = tempfile::tempdir().unwrap();
        let f1 = dir.path().join("a.txt");
        let f2 = dir.path().join("b.txt");
        std::fs::write(&f1, "abc\n").unwrap();
        std::fs::write(&f2, "xyz\n").unwrap();
        let output = cmd()
            .args([f1.to_str().unwrap(), f2.to_str().unwrap()])
            .output()
            .unwrap();
        assert!(output.status.success());
        assert_eq!(String::from_utf8_lossy(&output.stdout), "cba\nzyx\n");
    }

    #[test]
    fn test_rev_tabs_and_spaces() {
        use std::io::Write;
        use std::process::Stdio;
        let mut child = cmd()
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .spawn()
            .unwrap();
        child.stdin.take().unwrap().write_all(b"a\tb c\n").unwrap();
        let output = child.wait_with_output().unwrap();
        assert!(output.status.success());
        assert_eq!(String::from_utf8_lossy(&output.stdout), "c b\ta\n");
    }

    #[test]
    fn test_rev_binary_data() {
        use std::io::Write;
        use std::process::Stdio;
        let mut child = cmd()
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .spawn()
            .unwrap();
        child
            .stdin
            .take()
            .unwrap()
            .write_all(b"\x01\x02\x03\n")
            .unwrap();
        let output = child.wait_with_output().unwrap();
        assert!(output.status.success());
        assert_eq!(output.stdout, b"\x03\x02\x01\n");
    }

    #[test]
    fn test_rev_long_line() {
        use std::io::Write;
        use std::process::Stdio;
        let line: String = (0..10000)
            .map(|i| (b'a' + (i % 26) as u8) as char)
            .collect();
        let input = format!("{}\n", line);
        let mut child = cmd()
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .spawn()
            .unwrap();
        child
            .stdin
            .take()
            .unwrap()
            .write_all(input.as_bytes())
            .unwrap();
        let output = child.wait_with_output().unwrap();
        assert!(output.status.success());
        let expected: String = line.chars().rev().collect();
        let expected = format!("{}\n", expected);
        assert_eq!(String::from_utf8_lossy(&output.stdout), expected);
    }
}
