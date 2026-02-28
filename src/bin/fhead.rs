use std::io::{self, BufWriter, Write};
use std::process;

use coreutils_rs::common::{io_error_msg, reset_sigpipe};
use coreutils_rs::head::{self, HeadConfig, HeadMode};

struct Cli {
    config: HeadConfig,
    quiet: bool,
    verbose: bool,
    files: Vec<String>,
}

fn parse_args() -> Cli {
    let mut cli = Cli {
        config: HeadConfig::default(),
        quiet: false,
        verbose: false,
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
            let s = arg.to_string_lossy();
            if let Some(val) = s.strip_prefix("--lines=") {
                parse_lines_value(val, &mut cli.config);
                // mode set
            } else if let Some(val) = s.strip_prefix("--bytes=") {
                parse_bytes_value(val, &mut cli.config);
                // mode set
            } else {
                match bytes {
                    b"--lines" => {
                        let val = args.next().unwrap_or_else(|| {
                            eprintln!("head: option '--lines' requires an argument");
                            process::exit(1);
                        });
                        parse_lines_value(&val.to_string_lossy(), &mut cli.config);
                        // mode set
                    }
                    b"--bytes" => {
                        let val = args.next().unwrap_or_else(|| {
                            eprintln!("head: option '--bytes' requires an argument");
                            process::exit(1);
                        });
                        parse_bytes_value(&val.to_string_lossy(), &mut cli.config);
                        // mode set
                    }
                    b"--quiet" | b"--silent" => cli.quiet = true,
                    b"--verbose" => cli.verbose = true,
                    b"--zero-terminated" => cli.config.zero_terminated = true,
                    b"--help" => {
                        print_help();
                        process::exit(0);
                    }
                    b"--version" => {
                        println!("head (fcoreutils) {}", env!("CARGO_PKG_VERSION"));
                        process::exit(0);
                    }
                    _ => {
                        eprintln!("head: unrecognized option '{}'", s);
                        eprintln!("Try 'head --help' for more information.");
                        process::exit(1);
                    }
                }
            }
        } else if bytes.len() > 1 && bytes[0] == b'-' {
            // Short options
            let s = arg.to_string_lossy();
            let chars: Vec<char> = s[1..].chars().collect();
            let mut i = 0;
            while i < chars.len() {
                match chars[i] {
                    'n' => {
                        let val = if i + 1 < chars.len() {
                            s[1 + i + 1..].to_string()
                        } else {
                            args.next()
                                .unwrap_or_else(|| {
                                    eprintln!("head: option requires an argument -- 'n'");
                                    process::exit(1);
                                })
                                .to_string_lossy()
                                .into_owned()
                        };
                        parse_lines_value(&val, &mut cli.config);
                        // mode set
                        break; // consumed rest of arg
                    }
                    'c' => {
                        let val = if i + 1 < chars.len() {
                            s[1 + i + 1..].to_string()
                        } else {
                            args.next()
                                .unwrap_or_else(|| {
                                    eprintln!("head: option requires an argument -- 'c'");
                                    process::exit(1);
                                })
                                .to_string_lossy()
                                .into_owned()
                        };
                        parse_bytes_value(&val, &mut cli.config);
                        // mode set
                        break;
                    }
                    'q' => cli.quiet = true,
                    'v' => cli.verbose = true,
                    'z' => cli.config.zero_terminated = true,
                    '0'..='9' => {
                        // Legacy: head -N means head -n N
                        let num_str: String = chars[i..].iter().collect();
                        parse_lines_value(&num_str, &mut cli.config);
                        // mode set
                        break;
                    }
                    _ => {
                        eprintln!("head: invalid option -- '{}'", chars[i]);
                        eprintln!("Try 'head --help' for more information.");
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

fn parse_lines_value(val: &str, config: &mut HeadConfig) {
    if let Some(stripped) = val.strip_prefix('-') {
        match head::parse_size(stripped) {
            Ok(n) => config.mode = HeadMode::LinesFromEnd(n),
            Err(_) => {
                eprintln!("head: invalid number of lines: '{}'", val);
                process::exit(1);
            }
        }
    } else {
        match head::parse_size(val) {
            Ok(n) => config.mode = HeadMode::Lines(n),
            Err(_) => {
                eprintln!("head: invalid number of lines: '{}'", val);
                process::exit(1);
            }
        }
    }
}

fn parse_bytes_value(val: &str, config: &mut HeadConfig) {
    if let Some(stripped) = val.strip_prefix('-') {
        match head::parse_size(stripped) {
            Ok(n) => config.mode = HeadMode::BytesFromEnd(n),
            Err(_) => {
                eprintln!("head: invalid number of bytes: '{}'", val);
                process::exit(1);
            }
        }
    } else {
        match head::parse_size(val) {
            Ok(n) => config.mode = HeadMode::Bytes(n),
            Err(_) => {
                eprintln!("head: invalid number of bytes: '{}'", val);
                process::exit(1);
            }
        }
    }
}

fn print_help() {
    print!(
        "Usage: head [OPTION]... [FILE]...\n\
         Print the first 10 lines of each FILE to standard output.\n\
         With more than one FILE, precede each with a header giving the file name.\n\n\
         With no FILE, or when FILE is -, read standard input.\n\n\
         Mandatory arguments to long options are mandatory for short options too.\n\
         \x20 -c, --bytes=[-]NUM       print the first NUM bytes of each file;\n\
         \x20                          with the leading '-', print all but the last\n\
         \x20                          NUM bytes of each file\n\
         \x20 -n, --lines=[-]NUM       print the first NUM lines instead of the first 10;\n\
         \x20                          with the leading '-', print all but the last\n\
         \x20                          NUM lines of each file\n\
         \x20 -q, --quiet, --silent    never print headers giving file names\n\
         \x20 -v, --verbose            always print headers giving file names\n\
         \x20 -z, --zero-terminated    line delimiter is NUL, not newline\n\
         \x20     --help               display this help and exit\n\
         \x20     --version            output version information and exit\n\n\
         NUM may have a multiplier suffix:\n\
         b 512, kB 1000, K 1024, MB 1000*1000, M 1024*1024,\n\
         GB 1000*1000*1000, G 1024*1024*1024, and so on for T, P, E, Z, Y.\n\
         Binary prefixes can be used, too: KiB=K, MiB=M, and so on.\n"
    );
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
    reset_sigpipe();

    #[cfg(target_os = "linux")]
    enlarge_pipes();

    let cli = parse_args();

    let files: Vec<String> = if cli.files.is_empty() {
        vec!["-".to_string()]
    } else {
        cli.files
    };

    let tool_name = "head";
    let show_headers = if cli.quiet {
        false
    } else if cli.verbose {
        true
    } else {
        files.len() > 1
    };

    let stdout = io::stdout();
    let mut out = BufWriter::with_capacity(256 * 1024, stdout.lock());
    let mut had_error = false;
    let mut first = true;

    for filename in &files {
        if show_headers {
            if !first {
                let _ = out.write_all(b"\n");
            }
            let display_name = if filename == "-" {
                "standard input"
            } else {
                filename.as_str()
            };
            let _ = writeln!(out, "==> {} <==", display_name);
        }
        first = false;

        match head::head_file(filename, &cli.config, &mut out, tool_name) {
            Ok(true) => {}
            Ok(false) => had_error = true,
            Err(e) => {
                if e.kind() == io::ErrorKind::BrokenPipe {
                    let _ = out.flush();
                    process::exit(0);
                }
                eprintln!("{}: write error: {}", tool_name, io_error_msg(&e));
                had_error = true;
            }
        }
    }

    let _ = out.flush();

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
        path.push("fhead");
        Command::new(path)
    }

    #[test]
    fn test_head_help() {
        let output = cmd().arg("--help").output().unwrap();
        assert!(output.status.success());
        assert!(String::from_utf8_lossy(&output.stdout).contains("Usage"));
    }

    #[test]
    fn test_head_version() {
        let output = cmd().arg("--version").output().unwrap();
        assert!(output.status.success());
        assert!(String::from_utf8_lossy(&output.stdout).contains("fcoreutils"));
    }

    #[test]
    fn test_head_default_10_lines() {
        use std::io::Write;
        use std::process::Stdio;
        let input: String = (1..=20).map(|i| format!("line{}\n", i)).collect();
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
        let stdout = String::from_utf8_lossy(&output.stdout);
        assert_eq!(stdout.lines().count(), 10);
        assert!(stdout.starts_with("line1\n"));
        assert!(stdout.ends_with("line10\n"));
    }

    #[test]
    fn test_head_n5() {
        use std::io::Write;
        use std::process::Stdio;
        let input: String = (1..=20).map(|i| format!("line{}\n", i)).collect();
        let mut child = cmd()
            .args(["-n", "5"])
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
        let stdout = String::from_utf8_lossy(&output.stdout);
        assert_eq!(stdout.lines().count(), 5);
    }

    #[test]
    fn test_head_n0() {
        use std::io::Write;
        use std::process::Stdio;
        let mut child = cmd()
            .args(["-n", "0"])
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .spawn()
            .unwrap();
        child
            .stdin
            .take()
            .unwrap()
            .write_all(b"line1\nline2\n")
            .unwrap();
        let output = child.wait_with_output().unwrap();
        assert!(output.status.success());
        assert!(output.stdout.is_empty());
    }

    #[test]
    fn test_head_bytes() {
        use std::io::Write;
        use std::process::Stdio;
        let mut child = cmd()
            .args(["-c", "5"])
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .spawn()
            .unwrap();
        child
            .stdin
            .take()
            .unwrap()
            .write_all(b"hello world\n")
            .unwrap();
        let output = child.wait_with_output().unwrap();
        assert!(output.status.success());
        assert_eq!(output.stdout, b"hello");
    }

    #[test]
    fn test_head_empty_input() {
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
    fn test_head_fewer_lines_than_requested() {
        use std::io::Write;
        use std::process::Stdio;
        let mut child = cmd()
            .args(["-n", "100"])
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .spawn()
            .unwrap();
        child
            .stdin
            .take()
            .unwrap()
            .write_all(b"only two\nlines\n")
            .unwrap();
        let output = child.wait_with_output().unwrap();
        assert!(output.status.success());
        assert_eq!(output.stdout, b"only two\nlines\n");
    }

    #[test]
    fn test_head_file() {
        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join("test.txt");
        let content: String = (1..=20).map(|i| format!("line{}\n", i)).collect();
        std::fs::write(&file, &content).unwrap();
        let output = cmd()
            .args(["-n", "3", file.to_str().unwrap()])
            .output()
            .unwrap();
        assert!(output.status.success());
        assert_eq!(
            String::from_utf8_lossy(&output.stdout),
            "line1\nline2\nline3\n"
        );
    }

    #[test]
    fn test_head_multiple_files() {
        let dir = tempfile::tempdir().unwrap();
        let f1 = dir.path().join("a.txt");
        let f2 = dir.path().join("b.txt");
        std::fs::write(&f1, "aaa\n").unwrap();
        std::fs::write(&f2, "bbb\n").unwrap();
        let output = cmd()
            .args([f1.to_str().unwrap(), f2.to_str().unwrap()])
            .output()
            .unwrap();
        assert!(output.status.success());
        let stdout = String::from_utf8_lossy(&output.stdout);
        // Multiple files get headers
        assert!(stdout.contains("==>"));
        assert!(stdout.contains("aaa"));
        assert!(stdout.contains("bbb"));
    }

    #[test]
    fn test_head_negative_n() {
        use std::io::Write;
        use std::process::Stdio;
        // -n -2 means "all but last 2 lines"
        let mut child = cmd()
            .args(["-n", "-2"])
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .spawn()
            .unwrap();
        child
            .stdin
            .take()
            .unwrap()
            .write_all(b"line1\nline2\nline3\nline4\nline5\n")
            .unwrap();
        let output = child.wait_with_output().unwrap();
        assert!(output.status.success());
        let stdout = String::from_utf8_lossy(&output.stdout);
        assert_eq!(stdout.lines().count(), 3);
        assert_eq!(stdout, "line1\nline2\nline3\n");
    }

    #[test]
    fn test_head_nonexistent_file() {
        let output = cmd().arg("/nonexistent/file.txt").output().unwrap();
        assert!(!output.status.success());
    }

    #[test]
    fn test_head_quiet_flag() {
        let dir = tempfile::tempdir().unwrap();
        let f1 = dir.path().join("a.txt");
        let f2 = dir.path().join("b.txt");
        std::fs::write(&f1, "aaa\n").unwrap();
        std::fs::write(&f2, "bbb\n").unwrap();
        let output = cmd()
            .args(["-q", f1.to_str().unwrap(), f2.to_str().unwrap()])
            .output()
            .unwrap();
        assert!(output.status.success());
        let stdout = String::from_utf8_lossy(&output.stdout);
        // -q suppresses headers
        assert!(!stdout.contains("==>"));
    }

    #[test]
    fn test_head_no_final_newline() {
        use std::io::Write;
        use std::process::Stdio;
        let mut child = cmd()
            .args(["-n", "1"])
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .spawn()
            .unwrap();
        child
            .stdin
            .take()
            .unwrap()
            .write_all(b"no newline")
            .unwrap();
        let output = child.wait_with_output().unwrap();
        assert!(output.status.success());
        assert_eq!(output.stdout, b"no newline");
    }
}
