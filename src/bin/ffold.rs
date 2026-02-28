use std::io::{self, BufWriter, Write};
#[cfg(unix)]
use std::mem::ManuallyDrop;
#[cfg(unix)]
use std::os::unix::io::FromRawFd;
use std::path::Path;
use std::process;

use coreutils_rs::common::io::{read_file, read_stdin};
use coreutils_rs::common::io_error_msg;
use coreutils_rs::fold;

struct Cli {
    bytes: bool,
    spaces: bool,
    width: usize,
    files: Vec<String>,
}

fn parse_args() -> Cli {
    let mut cli = Cli {
        bytes: false,
        spaces: false,
        width: 80,
        files: Vec::new(),
    };

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
            if bytes.starts_with(b"--width=") {
                let val = arg.to_string_lossy();
                match val[8..].parse::<usize>() {
                    Ok(w) => cli.width = w,
                    Err(_) => {
                        eprintln!("fold: invalid number of columns: '{}'", &val[8..]);
                        process::exit(1);
                    }
                }
                continue;
            }
            match bytes {
                b"--bytes" => cli.bytes = true,
                b"--spaces" => cli.spaces = true,
                b"--width" => {
                    let val = args
                        .next()
                        .unwrap_or_else(|| {
                            eprintln!("fold: option '--width' requires an argument");
                            process::exit(1);
                        })
                        .to_string_lossy()
                        .into_owned();
                    match val.parse::<usize>() {
                        Ok(w) => cli.width = w,
                        Err(_) => {
                            eprintln!("fold: invalid number of columns: '{}'", val);
                            process::exit(1);
                        }
                    }
                }
                b"--help" => {
                    print!(
                        "Usage: fold [OPTION]... [FILE]...\n\
                         Wrap input lines in each FILE, writing to standard output.\n\n\
                         With no FILE, or when FILE is -, read standard input.\n\n\
                         Mandatory arguments to long options are mandatory for short options too.\n\
                         \x20 -b, --bytes         count bytes rather than columns\n\
                         \x20 -s, --spaces        break at spaces\n\
                         \x20 -w, --width=WIDTH   use WIDTH columns instead of 80\n\
                         \x20     --help          display this help and exit\n\
                         \x20     --version       output version information and exit\n"
                    );
                    process::exit(0);
                }
                b"--version" => {
                    println!("fold (fcoreutils) {}", env!("CARGO_PKG_VERSION"));
                    process::exit(0);
                }
                _ => {
                    eprintln!("fold: unrecognized option '{}'", arg.to_string_lossy());
                    eprintln!("Try 'fold --help' for more information.");
                    process::exit(1);
                }
            }
        } else if bytes.len() > 1 && bytes[0] == b'-' {
            let mut i = 1;
            while i < bytes.len() {
                match bytes[i] {
                    b'b' => cli.bytes = true,
                    b's' => cli.spaces = true,
                    b'w' => {
                        // -w takes a value
                        if i + 1 < bytes.len() {
                            let val = arg.to_string_lossy();
                            match val[i + 1..].parse::<usize>() {
                                Ok(w) => cli.width = w,
                                Err(_) => {
                                    eprintln!(
                                        "fold: invalid number of columns: '{}'",
                                        &val[i + 1..]
                                    );
                                    process::exit(1);
                                }
                            }
                        } else {
                            let val = args
                                .next()
                                .unwrap_or_else(|| {
                                    eprintln!("fold: option requires an argument -- 'w'");
                                    process::exit(1);
                                })
                                .to_string_lossy()
                                .into_owned();
                            match val.parse::<usize>() {
                                Ok(w) => cli.width = w,
                                Err(_) => {
                                    eprintln!("fold: invalid number of columns: '{}'", val);
                                    process::exit(1);
                                }
                            }
                        }
                        break;
                    }
                    _ => {
                        eprintln!("fold: invalid option -- '{}'", bytes[i] as char);
                        eprintln!("Try 'fold --help' for more information.");
                        process::exit(1);
                    }
                }
                i += 1;
            }
        } else {
            cli.files.push(arg.to_string_lossy().into_owned());
        }
    }

    cli
}

/// Enlarge pipe buffers on Linux.
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
                    eprintln!("fold: standard input: {}", io_error_msg(&e));
                    had_error = true;
                    continue;
                }
            }
        } else {
            match read_file(Path::new(filename)) {
                Ok(d) => d,
                Err(e) => {
                    eprintln!("fold: {}: {}", filename, io_error_msg(&e));
                    had_error = true;
                    continue;
                }
            }
        };

        if let Err(e) = fold::fold_bytes(&data, cli.width, cli.bytes, cli.spaces, &mut out) {
            if e.kind() == io::ErrorKind::BrokenPipe {
                process::exit(0);
            }
            eprintln!("fold: write error: {}", io_error_msg(&e));
            had_error = true;
        }
    }

    if let Err(e) = out.flush()
        && e.kind() != io::ErrorKind::BrokenPipe
    {
        eprintln!("fold: write error: {}", io_error_msg(&e));
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
        path.push("ffold");
        Command::new(path)
    }
    #[test]
    fn test_fold_default_width() {
        use std::io::Write;
        use std::process::Stdio;
        // Default fold width is 80
        let line = "x".repeat(100);
        let mut child = cmd()
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .spawn()
            .unwrap();
        child
            .stdin
            .take()
            .unwrap()
            .write_all(format!("{}\n", line).as_bytes())
            .unwrap();
        let output = child.wait_with_output().unwrap();
        assert!(output.status.success());
        let stdout = String::from_utf8_lossy(&output.stdout);
        let lines: Vec<&str> = stdout.lines().collect();
        assert_eq!(lines.len(), 2);
        assert_eq!(lines[0].len(), 80);
        assert_eq!(lines[1].len(), 20);
    }

    #[test]
    fn test_fold_custom_width() {
        use std::io::Write;
        use std::process::Stdio;
        let line = "abcdefghij";
        let mut child = cmd()
            .args(["-w", "5"])
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .spawn()
            .unwrap();
        child
            .stdin
            .take()
            .unwrap()
            .write_all(format!("{}\n", line).as_bytes())
            .unwrap();
        let output = child.wait_with_output().unwrap();
        assert!(output.status.success());
        let stdout = String::from_utf8_lossy(&output.stdout);
        let lines: Vec<&str> = stdout.lines().collect();
        assert_eq!(lines, vec!["abcde", "fghij"]);
    }

    #[test]
    fn test_fold_short_line() {
        use std::io::Write;
        use std::process::Stdio;
        let mut child = cmd()
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .spawn()
            .unwrap();
        child.stdin.take().unwrap().write_all(b"short\n").unwrap();
        let output = child.wait_with_output().unwrap();
        assert!(output.status.success());
        assert_eq!(output.stdout, b"short\n");
    }

    #[test]
    fn test_fold_empty_input() {
        use std::io::Write;
        use std::process::Stdio;
        let mut child = cmd()
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .spawn()
            .unwrap();
        child.stdin.take().unwrap().write_all(b"").unwrap();
        let output = child.wait_with_output().unwrap();
        assert!(output.status.success());
        assert!(output.stdout.is_empty());
    }

    #[test]
    fn test_fold_bytes_mode() {
        use std::io::Write;
        use std::process::Stdio;
        let mut child = cmd()
            .args(["-b", "-w", "3"])
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .spawn()
            .unwrap();
        child.stdin.take().unwrap().write_all(b"abcdef\n").unwrap();
        let output = child.wait_with_output().unwrap();
        assert!(output.status.success());
        let stdout = String::from_utf8_lossy(&output.stdout);
        let lines: Vec<&str> = stdout.lines().collect();
        assert_eq!(lines[0], "abc");
        assert_eq!(lines[1], "def");
    }

    #[test]
    fn test_fold_spaces() {
        use std::io::Write;
        use std::process::Stdio;
        let mut child = cmd()
            .args(["-s", "-w", "10"])
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .spawn()
            .unwrap();
        child
            .stdin
            .take()
            .unwrap()
            .write_all(b"hello world foo bar\n")
            .unwrap();
        let output = child.wait_with_output().unwrap();
        assert!(output.status.success());
        let stdout = String::from_utf8_lossy(&output.stdout);
        // With -s, fold should break at spaces
        for line in stdout.lines() {
            assert!(line.len() <= 10, "line too long: {}", line);
        }
    }

    #[test]
    fn test_fold_file() {
        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join("test.txt");
        std::fs::write(&file, "a".repeat(200) + "\n").unwrap();
        let output = cmd()
            .args(["-w", "50", file.to_str().unwrap()])
            .output()
            .unwrap();
        assert!(output.status.success());
        let stdout = String::from_utf8_lossy(&output.stdout);
        assert_eq!(stdout.lines().count(), 4);
    }

    #[test]
    fn test_fold_multiple_lines() {
        use std::io::Write;
        use std::process::Stdio;
        let mut child = cmd()
            .args(["-w", "5"])
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .spawn()
            .unwrap();
        child
            .stdin
            .take()
            .unwrap()
            .write_all(b"abcdefgh\n12345678\n")
            .unwrap();
        let output = child.wait_with_output().unwrap();
        assert!(output.status.success());
        let stdout = String::from_utf8_lossy(&output.stdout);
        let lines: Vec<&str> = stdout.lines().collect();
        assert_eq!(lines.len(), 4);
    }

    #[test]
    fn test_fold_nonexistent_file() {
        let output = cmd().arg("/nonexistent/file.txt").output().unwrap();
        assert!(!output.status.success());
    }
}
