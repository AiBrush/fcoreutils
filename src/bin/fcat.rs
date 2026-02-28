use std::io::{self, BufWriter, Write};
use std::process;

use coreutils_rs::cat::{self, CatConfig};
use coreutils_rs::common::{io_error_msg, reset_sigpipe};

struct Cli {
    config: CatConfig,
    files: Vec<String>,
}

fn parse_args() -> Cli {
    let mut cli = Cli {
        config: CatConfig::default(),
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
            match bytes {
                b"--show-all" => {
                    cli.config.show_nonprinting = true;
                    cli.config.show_ends = true;
                    cli.config.show_tabs = true;
                }
                b"--number-nonblank" => {
                    cli.config.number_nonblank = true;
                }
                b"--show-ends" => {
                    cli.config.show_ends = true;
                }
                b"--number" => {
                    cli.config.number = true;
                }
                b"--squeeze-blank" => {
                    cli.config.squeeze_blank = true;
                }
                b"--show-tabs" => {
                    cli.config.show_tabs = true;
                }
                b"--show-nonprinting" => {
                    cli.config.show_nonprinting = true;
                }
                b"--help" => {
                    print_help();
                    process::exit(0);
                }
                b"--version" => {
                    println!("cat (fcoreutils) {}", env!("CARGO_PKG_VERSION"));
                    process::exit(0);
                }
                _ => {
                    let s = arg.to_string_lossy();
                    eprintln!("cat: unrecognized option '{}'", s);
                    eprintln!("Try 'cat --help' for more information.");
                    process::exit(1);
                }
            }
        } else if bytes.len() > 1 && bytes[0] == b'-' {
            for &b in &bytes[1..] {
                match b {
                    b'A' => {
                        cli.config.show_nonprinting = true;
                        cli.config.show_ends = true;
                        cli.config.show_tabs = true;
                    }
                    b'b' => {
                        cli.config.number_nonblank = true;
                    }
                    b'e' => {
                        cli.config.show_nonprinting = true;
                        cli.config.show_ends = true;
                    }
                    b'E' => {
                        cli.config.show_ends = true;
                    }
                    b'n' => {
                        cli.config.number = true;
                    }
                    b's' => {
                        cli.config.squeeze_blank = true;
                    }
                    b't' => {
                        cli.config.show_nonprinting = true;
                        cli.config.show_tabs = true;
                    }
                    b'T' => {
                        cli.config.show_tabs = true;
                    }
                    b'v' => {
                        cli.config.show_nonprinting = true;
                    }
                    b'u' => {
                        // -u is ignored (POSIX requires it, GNU ignores it)
                    }
                    _ => {
                        eprintln!("cat: invalid option -- '{}'", b as char);
                        eprintln!("Try 'cat --help' for more information.");
                        process::exit(1);
                    }
                }
            }
        } else {
            cli.files.push(arg.to_string_lossy().into_owned());
        }
    }

    // -b overrides -n
    if cli.config.number_nonblank {
        cli.config.number = false;
    }

    cli
}

fn print_help() {
    print!(
        "Usage: cat [OPTION]... [FILE]...\n\
         Concatenate FILE(s) to standard output.\n\n\
         With no FILE, or when FILE is -, read standard input.\n\n\
         \x20 -A, --show-all           equivalent to -vET\n\
         \x20 -b, --number-nonblank    number nonempty output lines, overrides -n\n\
         \x20 -e                       equivalent to -vE\n\
         \x20 -E, --show-ends          display $ at end of each line\n\
         \x20 -n, --number             number all output lines\n\
         \x20 -s, --squeeze-blank      suppress repeated empty output lines\n\
         \x20 -t                       equivalent to -vT\n\
         \x20 -T, --show-tabs          display TAB characters as ^I\n\
         \x20 -u                       (ignored)\n\
         \x20 -v, --show-nonprinting   use ^ and M- notation, except for LFD and TAB\n\
         \x20     --help               display this help and exit\n\
         \x20     --version            output version information and exit\n"
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

    let tool_name = "cat";

    // For plain cat, use raw fd output to avoid BufWriter overhead
    if cli.config.is_plain() {
        #[cfg(unix)]
        {
            use std::mem::ManuallyDrop;
            use std::os::unix::io::FromRawFd;
            let mut raw_out = unsafe { ManuallyDrop::new(std::fs::File::from_raw_fd(1)) };
            let mut had_error = false;
            for filename in &files {
                match cat::cat_file(filename, &cli.config, &mut 1u64, &mut *raw_out, tool_name) {
                    Ok(true) => {}
                    Ok(false) => had_error = true,
                    Err(e) => {
                        if e.kind() == io::ErrorKind::BrokenPipe {
                            process::exit(0);
                        }
                        eprintln!("{}: write error: {}", tool_name, io_error_msg(&e));
                        had_error = true;
                    }
                }
            }
            if had_error {
                process::exit(1);
            }
            return;
        }
        #[cfg(not(unix))]
        {
            let stdout = io::stdout();
            let mut out = stdout.lock();
            let mut had_error = false;
            for filename in &files {
                match cat::cat_file(filename, &cli.config, &mut 1u64, &mut out, tool_name) {
                    Ok(true) => {}
                    Ok(false) => had_error = true,
                    Err(e) => {
                        if e.kind() == io::ErrorKind::BrokenPipe {
                            process::exit(0);
                        }
                        eprintln!("{}: write error: {}", tool_name, io_error_msg(&e));
                        had_error = true;
                    }
                }
            }
            if had_error {
                process::exit(1);
            }
            return;
        }
    }

    // With options, use BufWriter
    let stdout = io::stdout();
    let mut out = BufWriter::with_capacity(256 * 1024, stdout.lock());
    let mut had_error = false;
    let mut line_num = 1u64;

    for filename in &files {
        match cat::cat_file(filename, &cli.config, &mut line_num, &mut out, tool_name) {
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
        path.push("fcat");
        Command::new(path)
    }
    #[test]
    fn test_cat_stdin() {
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
            .write_all(b"hello world\n")
            .unwrap();
        let output = child.wait_with_output().unwrap();
        assert!(output.status.success());
        assert_eq!(output.stdout, b"hello world\n");
    }

    #[test]
    fn test_cat_file() {
        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join("test.txt");
        std::fs::write(&file, "line1\nline2\n").unwrap();
        let output = cmd().arg(file.to_str().unwrap()).output().unwrap();
        assert!(output.status.success());
        assert_eq!(output.stdout, b"line1\nline2\n");
    }

    #[test]
    fn test_cat_multiple_files() {
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
        assert_eq!(output.stdout, b"aaa\nbbb\n");
    }

    #[test]
    fn test_cat_number_lines() {
        use std::io::Write;
        use std::process::Stdio;
        let mut child = cmd()
            .arg("-n")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .spawn()
            .unwrap();
        child.stdin.take().unwrap().write_all(b"a\nb\nc\n").unwrap();
        let output = child.wait_with_output().unwrap();
        assert!(output.status.success());
        let stdout = String::from_utf8_lossy(&output.stdout);
        assert!(stdout.contains("1\ta") || stdout.contains("1\t"));
        assert!(stdout.contains("2\t"));
        assert!(stdout.contains("3\t"));
    }

    #[test]
    fn test_cat_number_nonblank() {
        use std::io::Write;
        use std::process::Stdio;
        let mut child = cmd()
            .arg("-b")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .spawn()
            .unwrap();
        child.stdin.take().unwrap().write_all(b"a\n\nb\n").unwrap();
        let output = child.wait_with_output().unwrap();
        assert!(output.status.success());
        let stdout = String::from_utf8_lossy(&output.stdout);
        let lines: Vec<&str> = stdout.lines().collect();
        // Blank line should NOT be numbered
        assert!(lines[1].trim().is_empty());
    }

    #[test]
    fn test_cat_show_ends() {
        use std::io::Write;
        use std::process::Stdio;
        let mut child = cmd()
            .arg("-E")
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
        let stdout = String::from_utf8_lossy(&output.stdout);
        assert!(stdout.contains("hello$"));
    }

    #[test]
    fn test_cat_show_tabs() {
        use std::io::Write;
        use std::process::Stdio;
        let mut child = cmd()
            .arg("-T")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .spawn()
            .unwrap();
        child.stdin.take().unwrap().write_all(b"a\tb\n").unwrap();
        let output = child.wait_with_output().unwrap();
        assert!(output.status.success());
        let stdout = String::from_utf8_lossy(&output.stdout);
        assert!(stdout.contains("^I"));
    }

    #[test]
    fn test_cat_squeeze_blank() {
        use std::io::Write;
        use std::process::Stdio;
        let mut child = cmd()
            .arg("-s")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .spawn()
            .unwrap();
        child
            .stdin
            .take()
            .unwrap()
            .write_all(b"a\n\n\n\nb\n")
            .unwrap();
        let output = child.wait_with_output().unwrap();
        assert!(output.status.success());
        // Multiple blanks squeezed to single blank
        assert_eq!(output.stdout, b"a\n\nb\n");
    }

    #[test]
    fn test_cat_empty_file() {
        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join("empty.txt");
        std::fs::write(&file, "").unwrap();
        let output = cmd().arg(file.to_str().unwrap()).output().unwrap();
        assert!(output.status.success());
        assert!(output.stdout.is_empty());
    }

    #[test]
    fn test_cat_nonexistent_file() {
        let output = cmd().arg("/nonexistent/file.txt").output().unwrap();
        assert!(!output.status.success());
        let stderr = String::from_utf8_lossy(&output.stderr);
        assert!(stderr.contains("No such file"));
    }

    #[test]
    fn test_cat_binary_data() {
        use std::io::Write;
        use std::process::Stdio;
        let data: Vec<u8> = (0..=255).collect();
        let mut child = cmd()
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .spawn()
            .unwrap();
        child.stdin.take().unwrap().write_all(&data).unwrap();
        let output = child.wait_with_output().unwrap();
        assert!(output.status.success());
        assert_eq!(output.stdout, data);
    }

    #[test]
    fn test_cat_show_nonprinting() {
        use std::io::Write;
        use std::process::Stdio;
        let mut child = cmd()
            .arg("-v")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .spawn()
            .unwrap();
        child
            .stdin
            .take()
            .unwrap()
            .write_all(&[0x01, 0x7f, b'\n'])
            .unwrap();
        let output = child.wait_with_output().unwrap();
        assert!(output.status.success());
        let stdout = String::from_utf8_lossy(&output.stdout);
        assert!(stdout.contains("^A"));
        assert!(stdout.contains("^?"));
    }

    #[test]
    fn test_cat_no_final_newline() {
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
            .write_all(b"no newline")
            .unwrap();
        let output = child.wait_with_output().unwrap();
        assert!(output.status.success());
        assert_eq!(output.stdout, b"no newline");
    }

    #[test]
    fn test_cat_show_all() {
        use std::io::Write;
        use std::process::Stdio;
        let mut child = cmd()
            .arg("-A")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .spawn()
            .unwrap();
        child.stdin.take().unwrap().write_all(b"a\tb\n").unwrap();
        let output = child.wait_with_output().unwrap();
        assert!(output.status.success());
        let stdout = String::from_utf8_lossy(&output.stdout);
        // -A = -vET: show tabs as ^I, ends as $
        assert!(stdout.contains("^I"));
        assert!(stdout.contains("$"));
    }

    #[test]
    fn test_cat_invalid_option() {
        let output = cmd().arg("--invalid").output().unwrap();
        assert!(!output.status.success());
    }

    #[test]
    fn test_cat_dash_is_stdin() {
        use std::io::Write;
        use std::process::Stdio;
        let mut child = cmd()
            .arg("-")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .spawn()
            .unwrap();
        child
            .stdin
            .take()
            .unwrap()
            .write_all(b"from stdin\n")
            .unwrap();
        let output = child.wait_with_output().unwrap();
        assert!(output.status.success());
        assert_eq!(output.stdout, b"from stdin\n");
    }
}
