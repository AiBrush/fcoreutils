use std::io::{self, BufWriter, Write};
use std::process;

use coreutils_rs::common::{io_error_msg, reset_sigpipe};
use coreutils_rs::tail::{self, FollowMode, TailConfig, TailMode};

struct Cli {
    config: TailConfig,
    quiet: bool,
    verbose: bool,
    files: Vec<String>,
}

fn parse_args() -> Cli {
    let mut cli = Cli {
        config: TailConfig::default(),
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
            } else if let Some(val) = s.strip_prefix("--bytes=") {
                parse_bytes_value(val, &mut cli.config);
            } else if let Some(val) = s.strip_prefix("--pid=") {
                cli.config.pid = Some(val.parse().unwrap_or_else(|_| {
                    eprintln!("tail: invalid PID: '{}'", val);
                    process::exit(1);
                }));
            } else if let Some(val) = s.strip_prefix("--sleep-interval=") {
                cli.config.sleep_interval = val.parse().unwrap_or_else(|_| {
                    eprintln!("tail: invalid number of seconds: '{}'", val);
                    process::exit(1);
                });
            } else if let Some(val) = s.strip_prefix("--max-unchanged-stats=") {
                cli.config.max_unchanged_stats = val.parse().unwrap_or_else(|_| {
                    eprintln!("tail: invalid number: '{}'", val);
                    process::exit(1);
                });
            } else if let Some(val) = s.strip_prefix("--follow=") {
                match val {
                    "name" => cli.config.follow = FollowMode::Name,
                    "descriptor" => cli.config.follow = FollowMode::Descriptor,
                    _ => {
                        eprintln!("tail: invalid argument '{}' for '--follow'", val);
                        process::exit(1);
                    }
                }
            } else {
                match bytes {
                    b"--lines" => {
                        let val = args.next().unwrap_or_else(|| {
                            eprintln!("tail: option '--lines' requires an argument");
                            process::exit(1);
                        });
                        parse_lines_value(&val.to_string_lossy(), &mut cli.config);
                    }
                    b"--bytes" => {
                        let val = args.next().unwrap_or_else(|| {
                            eprintln!("tail: option '--bytes' requires an argument");
                            process::exit(1);
                        });
                        parse_bytes_value(&val.to_string_lossy(), &mut cli.config);
                    }
                    b"--follow" => cli.config.follow = FollowMode::Descriptor,
                    b"--retry" => cli.config.retry = true,
                    b"--quiet" | b"--silent" => cli.quiet = true,
                    b"--verbose" => cli.verbose = true,
                    b"--zero-terminated" => cli.config.zero_terminated = true,
                    b"--pid" => {
                        let val = args.next().unwrap_or_else(|| {
                            eprintln!("tail: option '--pid' requires an argument");
                            process::exit(1);
                        });
                        cli.config.pid = Some(val.to_string_lossy().parse().unwrap_or_else(|_| {
                            eprintln!("tail: invalid PID: '{}'", val.to_string_lossy());
                            process::exit(1);
                        }));
                    }
                    b"--sleep-interval" => {
                        let val = args.next().unwrap_or_else(|| {
                            eprintln!("tail: option '--sleep-interval' requires an argument");
                            process::exit(1);
                        });
                        cli.config.sleep_interval =
                            val.to_string_lossy().parse().unwrap_or_else(|_| {
                                eprintln!(
                                    "tail: invalid number of seconds: '{}'",
                                    val.to_string_lossy()
                                );
                                process::exit(1);
                            });
                    }
                    b"--max-unchanged-stats" => {
                        let val = args.next().unwrap_or_else(|| {
                            eprintln!("tail: option '--max-unchanged-stats' requires an argument");
                            process::exit(1);
                        });
                        cli.config.max_unchanged_stats =
                            val.to_string_lossy().parse().unwrap_or_else(|_| {
                                eprintln!("tail: invalid number: '{}'", val.to_string_lossy());
                                process::exit(1);
                            });
                    }
                    b"--help" => {
                        print_help();
                        process::exit(0);
                    }
                    b"--version" => {
                        println!("tail (fcoreutils) {}", env!("CARGO_PKG_VERSION"));
                        process::exit(0);
                    }
                    _ => {
                        eprintln!("tail: unrecognized option '{}'", s);
                        eprintln!("Try 'tail --help' for more information.");
                        process::exit(1);
                    }
                }
            }
        } else if bytes.len() > 1 && bytes[0] == b'-' {
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
                                    eprintln!("tail: option requires an argument -- 'n'");
                                    process::exit(1);
                                })
                                .to_string_lossy()
                                .into_owned()
                        };
                        parse_lines_value(&val, &mut cli.config);
                        break;
                    }
                    'c' => {
                        let val = if i + 1 < chars.len() {
                            s[1 + i + 1..].to_string()
                        } else {
                            args.next()
                                .unwrap_or_else(|| {
                                    eprintln!("tail: option requires an argument -- 'c'");
                                    process::exit(1);
                                })
                                .to_string_lossy()
                                .into_owned()
                        };
                        parse_bytes_value(&val, &mut cli.config);
                        break;
                    }
                    'f' => cli.config.follow = FollowMode::Descriptor,
                    'F' => {
                        cli.config.follow = FollowMode::Name;
                        cli.config.retry = true;
                    }
                    'q' => cli.quiet = true,
                    'v' => cli.verbose = true,
                    'z' => cli.config.zero_terminated = true,
                    's' => {
                        let val = if i + 1 < chars.len() {
                            s[1 + i + 1..].to_string()
                        } else {
                            args.next()
                                .unwrap_or_else(|| {
                                    eprintln!("tail: option requires an argument -- 's'");
                                    process::exit(1);
                                })
                                .to_string_lossy()
                                .into_owned()
                        };
                        cli.config.sleep_interval = val.parse().unwrap_or_else(|_| {
                            eprintln!("tail: invalid number of seconds: '{}'", val);
                            process::exit(1);
                        });
                        break;
                    }
                    '0'..='9' | '+' => {
                        // Legacy: tail -N means tail -n N, tail +N means tail -n +N
                        let num_str: String = chars[i..].iter().collect();
                        parse_lines_value(&num_str, &mut cli.config);
                        break;
                    }
                    _ => {
                        eprintln!("tail: invalid option -- '{}'", chars[i]);
                        eprintln!("Try 'tail --help' for more information.");
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

fn parse_lines_value(val: &str, config: &mut TailConfig) {
    if check_numeric_overflow(val) {
        eprintln!(
            "tail: invalid number of lines: \u{2018}{}\u{2019}: Value too large for defined data type",
            val
        );
        process::exit(1);
    }
    if let Some(stripped) = val.strip_prefix('+') {
        match tail::parse_size(stripped) {
            Ok(n) => config.mode = TailMode::LinesFrom(n),
            Err(_) => {
                eprintln!("tail: invalid number of lines: '{}'", val);
                process::exit(1);
            }
        }
    } else {
        let clean = val.strip_prefix('-').unwrap_or(val);
        match tail::parse_size(clean) {
            Ok(n) => config.mode = TailMode::Lines(n),
            Err(_) => {
                eprintln!("tail: invalid number of lines: '{}'", val);
                process::exit(1);
            }
        }
    }
}

fn check_numeric_overflow(val: &str) -> bool {
    let clean = val
        .strip_prefix('+')
        .or_else(|| val.strip_prefix('-'))
        .unwrap_or(val);
    let num_end = clean.bytes().take_while(u8::is_ascii_digit).count();
    let num_part = &clean[..num_end];
    !num_part.is_empty() && num_part.parse::<u64>().is_err()
}

fn parse_bytes_value(val: &str, config: &mut TailConfig) {
    if check_numeric_overflow(val) {
        eprintln!(
            "tail: invalid number of bytes: \u{2018}{}\u{2019}: Value too large for defined data type",
            val
        );
        process::exit(1);
    }
    if let Some(stripped) = val.strip_prefix('+') {
        match tail::parse_size(stripped) {
            Ok(n) => config.mode = TailMode::BytesFrom(n),
            Err(_) => {
                eprintln!("tail: invalid number of bytes: '{}'", val);
                process::exit(1);
            }
        }
    } else {
        let clean = val.strip_prefix('-').unwrap_or(val);
        match tail::parse_size(clean) {
            Ok(n) => config.mode = TailMode::Bytes(n),
            Err(_) => {
                eprintln!("tail: invalid number of bytes: '{}'", val);
                process::exit(1);
            }
        }
    }
}

fn print_help() {
    print!(
        "Usage: tail [OPTION]... [FILE]...\n\
         Print the last 10 lines of each FILE to standard output.\n\
         With more than one FILE, precede each with a header giving the file name.\n\n\
         With no FILE, or when FILE is -, read standard input.\n\n\
         Mandatory arguments to long options are mandatory for short options too.\n\
         \x20 -c, --bytes=[+]NUM       output the last NUM bytes; or use -c +NUM to\n\
         \x20                          output starting with byte NUM of each file\n\
         \x20 -f, --follow[={{name|descriptor}}]\n\
         \x20                          output appended data as the file grows;\n\
         \x20                          an absent option argument means 'descriptor'\n\
         \x20 -F                       same as --follow=name --retry\n\
         \x20 -n, --lines=[+]NUM       output the last NUM lines, instead of the last 10;\n\
         \x20                          or use -n +NUM to output starting with line NUM\n\
         \x20     --max-unchanged-stats=N\n\
         \x20                          with --follow=name, reopen a FILE which has not\n\
         \x20                          changed size after N (default 5) iterations\n\
         \x20     --pid=PID            with -f, terminate after process ID, PID dies\n\
         \x20 -q, --quiet, --silent    never output headers giving file names\n\
         \x20     --retry              keep trying to open a file if it is inaccessible\n\
         \x20 -s, --sleep-interval=N   with -f, sleep for approximately N seconds\n\
         \x20                          (default 1.0) between iterations\n\
         \x20 -v, --verbose            always output headers giving file names\n\
         \x20 -z, --zero-terminated    line delimiter is NUL, not newline\n\
         \x20     --help               display this help and exit\n\
         \x20     --version            output version information and exit\n\n\
         NUM may have a multiplier suffix:\n\
         b 512, kB 1000, K 1024, MB 1000*1000, M 1024*1024,\n\
         GB 1000*1000*1000, G 1024*1024*1024, and so on for T, P, E, Z, Y.\n\
         Binary prefixes can be used, too: KiB=K, MiB=M, and so on.\n"
    );
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
    reset_sigpipe();

    #[cfg(target_os = "linux")]
    enlarge_pipes();

    let cli = parse_args();

    let files: Vec<String> = if cli.files.is_empty() {
        vec!["-".to_string()]
    } else {
        cli.files
    };

    let tool_name = "tail";
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

        match tail::tail_file(filename, &cli.config, &mut out, tool_name) {
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

    // Follow mode
    if cli.config.follow != FollowMode::None {
        for filename in &files {
            if filename != "-" {
                let _ = tail::follow_file(filename, &cli.config, &mut out);
            }
        }
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
        path.push("ftail");
        Command::new(path)
    }
    #[test]
    fn test_tail_basic() {
        use std::io::Write;
        use std::process::Stdio;
        let input: String = (1..=20).map(|i| format!("{}\n", i)).collect();
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
        let lines: Vec<&str> = stdout.lines().collect();
        // Default: last 10 lines
        assert_eq!(lines.len(), 10);
        assert_eq!(lines[0], "11");
        assert_eq!(lines[9], "20");
    }

    #[test]
    fn test_tail_n_lines() {
        use std::io::Write;
        use std::process::Stdio;
        let input: String = (1..=20).map(|i| format!("{}\n", i)).collect();
        let mut child = cmd()
            .args(["-n", "3"])
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
        assert_eq!(stdout, "18\n19\n20\n");
    }

    #[test]
    fn test_tail_from_line() {
        use std::io::Write;
        use std::process::Stdio;
        let mut child = cmd()
            .args(["-n", "+3"])
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .spawn()
            .unwrap();
        child
            .stdin
            .take()
            .unwrap()
            .write_all(b"1\n2\n3\n4\n5\n")
            .unwrap();
        let output = child.wait_with_output().unwrap();
        assert!(output.status.success());
        let stdout = String::from_utf8_lossy(&output.stdout);
        assert_eq!(stdout, "3\n4\n5\n");
    }

    #[test]
    fn test_tail_bytes() {
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
            .write_all(b"hello world")
            .unwrap();
        let output = child.wait_with_output().unwrap();
        assert!(output.status.success());
        assert_eq!(String::from_utf8_lossy(&output.stdout), "world");
    }

    #[test]
    fn test_tail_empty_input() {
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
    fn test_tail_file() {
        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join("test.txt");
        std::fs::write(&file, "a\nb\nc\nd\ne\n").unwrap();
        let output = cmd()
            .args(["-n", "2", file.to_str().unwrap()])
            .output()
            .unwrap();
        assert!(output.status.success());
        assert_eq!(String::from_utf8_lossy(&output.stdout), "d\ne\n");
    }

    #[test]
    fn test_tail_multiple_files() {
        let dir = tempfile::tempdir().unwrap();
        let f1 = dir.path().join("a.txt");
        let f2 = dir.path().join("b.txt");
        std::fs::write(&f1, "1\n2\n3\n").unwrap();
        std::fs::write(&f2, "4\n5\n6\n").unwrap();
        let output = cmd()
            .args(["-n", "1", f1.to_str().unwrap(), f2.to_str().unwrap()])
            .output()
            .unwrap();
        assert!(output.status.success());
        let stdout = String::from_utf8_lossy(&output.stdout);
        // Should have headers
        assert!(stdout.contains("==>"));
    }

    #[test]
    fn test_tail_nonexistent_file() {
        let output = cmd().arg("/nonexistent_xyz_tail").output().unwrap();
        assert!(!output.status.success());
    }

    #[test]
    fn test_tail_quiet() {
        let dir = tempfile::tempdir().unwrap();
        let f1 = dir.path().join("a.txt");
        let f2 = dir.path().join("b.txt");
        std::fs::write(&f1, "1\n2\n3\n").unwrap();
        std::fs::write(&f2, "4\n5\n6\n").unwrap();
        let output = cmd()
            .args(["-q", f1.to_str().unwrap(), f2.to_str().unwrap()])
            .output()
            .unwrap();
        assert!(output.status.success());
        let stdout = String::from_utf8_lossy(&output.stdout);
        // Quiet mode: no headers
        assert!(!stdout.contains("==>"));
    }

    #[test]
    fn test_tail_fewer_lines_than_requested() {
        use std::io::Write;
        use std::process::Stdio;
        let mut child = cmd()
            .args(["-n", "100"])
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .spawn()
            .unwrap();
        child.stdin.take().unwrap().write_all(b"a\nb\nc\n").unwrap();
        let output = child.wait_with_output().unwrap();
        assert!(output.status.success());
        assert_eq!(String::from_utf8_lossy(&output.stdout), "a\nb\nc\n");
    }

    #[test]
    fn test_tail_n_zero() {
        use std::io::Write;
        use std::process::Stdio;
        let mut child = cmd()
            .args(["-n", "0"])
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .spawn()
            .unwrap();
        child.stdin.take().unwrap().write_all(b"a\nb\nc\n").unwrap();
        let output = child.wait_with_output().unwrap();
        assert!(output.status.success());
        assert_eq!(output.stdout, b"");
    }

    #[test]
    fn test_tail_c_huge_number_overflow() {
        // GNU compat: tail -c with number > u64::MAX should fail with overflow error
        use std::process::Stdio;
        let mut child = cmd()
            .args(["-c", "99999999999999999999"])
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .unwrap();
        drop(child.stdin.take().unwrap());
        let output = child.wait_with_output().unwrap();
        assert!(
            !output.status.success(),
            "tail -c huge should fail with overflow error"
        );
        let stderr = String::from_utf8_lossy(&output.stderr);
        assert!(
            stderr.contains("Value too large"),
            "Expected overflow error, got: {}",
            stderr
        );
    }
}
