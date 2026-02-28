use std::path::Path;
use std::process;

use coreutils_rs::common::io::{read_file, read_stdin};
use coreutils_rs::common::io_error_msg;
use coreutils_rs::nl::{self, NlConfig};

struct Cli {
    config: NlConfig,
    files: Vec<String>,
}

fn parse_args() -> Cli {
    let mut cli = Cli {
        config: NlConfig::default(),
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
            if let Some(val) = s.strip_prefix("--body-numbering=") {
                match nl::parse_numbering_style(val) {
                    Ok(style) => cli.config.body_style = style,
                    Err(e) => {
                        eprintln!("nl: {}", e);
                        process::exit(1);
                    }
                }
            } else if let Some(val) = s.strip_prefix("--header-numbering=") {
                match nl::parse_numbering_style(val) {
                    Ok(style) => cli.config.header_style = style,
                    Err(e) => {
                        eprintln!("nl: {}", e);
                        process::exit(1);
                    }
                }
            } else if let Some(val) = s.strip_prefix("--footer-numbering=") {
                match nl::parse_numbering_style(val) {
                    Ok(style) => cli.config.footer_style = style,
                    Err(e) => {
                        eprintln!("nl: {}", e);
                        process::exit(1);
                    }
                }
            } else if let Some(val) = s.strip_prefix("--section-delimiter=") {
                let mut bytes = val.as_bytes().to_vec();
                if bytes.len() == 1 {
                    bytes.push(b':');
                }
                cli.config.section_delimiter = bytes;
            } else if let Some(val) = s.strip_prefix("--line-increment=") {
                match val.parse::<i64>() {
                    Ok(n) => cli.config.line_increment = n,
                    Err(_) => {
                        eprintln!("nl: invalid line increment: '{}'", val);
                        process::exit(1);
                    }
                }
            } else if let Some(val) = s.strip_prefix("--join-blank-lines=") {
                match val.parse::<usize>() {
                    Ok(n) if n > 0 => cli.config.join_blank_lines = n,
                    _ => {
                        eprintln!("nl: invalid line number of blank lines: '{}'", val);
                        process::exit(1);
                    }
                }
            } else if let Some(val) = s.strip_prefix("--number-format=") {
                match nl::parse_number_format(val) {
                    Ok(fmt) => cli.config.number_format = fmt,
                    Err(e) => {
                        eprintln!("nl: {}", e);
                        process::exit(1);
                    }
                }
            } else if let Some(val) = s.strip_prefix("--number-separator=") {
                cli.config.number_separator = val.as_bytes().to_vec();
            } else if let Some(val) = s.strip_prefix("--starting-line-number=") {
                match val.parse::<i64>() {
                    Ok(n) => cli.config.starting_line_number = n,
                    Err(_) => {
                        eprintln!("nl: invalid starting line number: '{}'", val);
                        process::exit(1);
                    }
                }
            } else if let Some(val) = s.strip_prefix("--number-width=") {
                match val.parse::<usize>() {
                    Ok(n) if n > 0 => cli.config.number_width = n,
                    _ => {
                        eprintln!("nl: invalid line number field width: '{}'", val);
                        process::exit(1);
                    }
                }
            } else {
                match bytes {
                    b"--body-numbering" => {
                        let val = require_arg(&mut args, "--body-numbering");
                        match nl::parse_numbering_style(&val) {
                            Ok(style) => cli.config.body_style = style,
                            Err(e) => {
                                eprintln!("nl: {}", e);
                                process::exit(1);
                            }
                        }
                    }
                    b"--header-numbering" => {
                        let val = require_arg(&mut args, "--header-numbering");
                        match nl::parse_numbering_style(&val) {
                            Ok(style) => cli.config.header_style = style,
                            Err(e) => {
                                eprintln!("nl: {}", e);
                                process::exit(1);
                            }
                        }
                    }
                    b"--footer-numbering" => {
                        let val = require_arg(&mut args, "--footer-numbering");
                        match nl::parse_numbering_style(&val) {
                            Ok(style) => cli.config.footer_style = style,
                            Err(e) => {
                                eprintln!("nl: {}", e);
                                process::exit(1);
                            }
                        }
                    }
                    b"--section-delimiter" => {
                        let val = require_arg(&mut args, "--section-delimiter");
                        let mut bytes = val.into_bytes();
                        if bytes.len() == 1 {
                            bytes.push(b':');
                        }
                        cli.config.section_delimiter = bytes;
                    }
                    b"--line-increment" => {
                        let val = require_arg(&mut args, "--line-increment");
                        match val.parse::<i64>() {
                            Ok(n) => cli.config.line_increment = n,
                            Err(_) => {
                                eprintln!("nl: invalid line increment: '{}'", val);
                                process::exit(1);
                            }
                        }
                    }
                    b"--join-blank-lines" => {
                        let val = require_arg(&mut args, "--join-blank-lines");
                        match val.parse::<usize>() {
                            Ok(n) if n > 0 => cli.config.join_blank_lines = n,
                            _ => {
                                eprintln!("nl: invalid line number of blank lines: '{}'", val);
                                process::exit(1);
                            }
                        }
                    }
                    b"--number-format" => {
                        let val = require_arg(&mut args, "--number-format");
                        match nl::parse_number_format(&val) {
                            Ok(fmt) => cli.config.number_format = fmt,
                            Err(e) => {
                                eprintln!("nl: {}", e);
                                process::exit(1);
                            }
                        }
                    }
                    b"--no-renumber" => cli.config.no_renumber = true,
                    b"--number-separator" => {
                        let val = require_arg(&mut args, "--number-separator");
                        cli.config.number_separator = val.into_bytes();
                    }
                    b"--starting-line-number" => {
                        let val = require_arg(&mut args, "--starting-line-number");
                        match val.parse::<i64>() {
                            Ok(n) => cli.config.starting_line_number = n,
                            Err(_) => {
                                eprintln!("nl: invalid starting line number: '{}'", val);
                                process::exit(1);
                            }
                        }
                    }
                    b"--number-width" => {
                        let val = require_arg(&mut args, "--number-width");
                        match val.parse::<usize>() {
                            Ok(n) if n > 0 => cli.config.number_width = n,
                            _ => {
                                eprintln!("nl: invalid line number field width: '{}'", val);
                                process::exit(1);
                            }
                        }
                    }
                    b"--help" => {
                        print_help();
                        process::exit(0);
                    }
                    b"--version" => {
                        println!("nl (fcoreutils) {}", env!("CARGO_PKG_VERSION"));
                        process::exit(0);
                    }
                    _ => {
                        eprintln!("nl: unrecognized option '{}'", s);
                        eprintln!("Try 'nl --help' for more information.");
                        process::exit(1);
                    }
                }
            }
        } else if bytes.len() > 1 && bytes[0] == b'-' && bytes != b"-" {
            // Short options
            let s = arg.to_string_lossy();
            let chars: Vec<char> = s[1..].chars().collect();
            let mut i = 0;
            while i < chars.len() {
                match chars[i] {
                    'b' => {
                        let val = short_opt_value(&s, &chars, i, &mut args, 'b');
                        match nl::parse_numbering_style(&val) {
                            Ok(style) => cli.config.body_style = style,
                            Err(e) => {
                                eprintln!("nl: {}", e);
                                process::exit(1);
                            }
                        }
                        break;
                    }
                    'h' => {
                        let val = short_opt_value(&s, &chars, i, &mut args, 'h');
                        match nl::parse_numbering_style(&val) {
                            Ok(style) => cli.config.header_style = style,
                            Err(e) => {
                                eprintln!("nl: {}", e);
                                process::exit(1);
                            }
                        }
                        break;
                    }
                    'f' => {
                        let val = short_opt_value(&s, &chars, i, &mut args, 'f');
                        match nl::parse_numbering_style(&val) {
                            Ok(style) => cli.config.footer_style = style,
                            Err(e) => {
                                eprintln!("nl: {}", e);
                                process::exit(1);
                            }
                        }
                        break;
                    }
                    'd' => {
                        let val = short_opt_value(&s, &chars, i, &mut args, 'd');
                        let mut bytes = val.into_bytes();
                        // POSIX: single char delimiter implies colon as second char
                        if bytes.len() == 1 {
                            bytes.push(b':');
                        }
                        cli.config.section_delimiter = bytes;
                        break;
                    }
                    'i' => {
                        let val = short_opt_value(&s, &chars, i, &mut args, 'i');
                        match val.parse::<i64>() {
                            Ok(n) => cli.config.line_increment = n,
                            Err(_) => {
                                eprintln!("nl: invalid line increment: '{}'", val);
                                process::exit(1);
                            }
                        }
                        break;
                    }
                    'l' => {
                        let val = short_opt_value(&s, &chars, i, &mut args, 'l');
                        match val.parse::<usize>() {
                            Ok(n) if n > 0 => cli.config.join_blank_lines = n,
                            _ => {
                                eprintln!("nl: invalid line number of blank lines: '{}'", val);
                                process::exit(1);
                            }
                        }
                        break;
                    }
                    'n' => {
                        let val = short_opt_value(&s, &chars, i, &mut args, 'n');
                        match nl::parse_number_format(&val) {
                            Ok(fmt) => cli.config.number_format = fmt,
                            Err(e) => {
                                eprintln!("nl: {}", e);
                                process::exit(1);
                            }
                        }
                        break;
                    }
                    'p' => cli.config.no_renumber = true,
                    's' => {
                        let val = short_opt_value(&s, &chars, i, &mut args, 's');
                        cli.config.number_separator = val.into_bytes();
                        break;
                    }
                    'v' => {
                        let val = short_opt_value(&s, &chars, i, &mut args, 'v');
                        match val.parse::<i64>() {
                            Ok(n) => cli.config.starting_line_number = n,
                            Err(_) => {
                                eprintln!("nl: invalid starting line number: '{}'", val);
                                process::exit(1);
                            }
                        }
                        break;
                    }
                    'w' => {
                        let val = short_opt_value(&s, &chars, i, &mut args, 'w');
                        match val.parse::<usize>() {
                            Ok(n) if n > 0 => cli.config.number_width = n,
                            _ => {
                                eprintln!("nl: invalid line number field width: '{}'", val);
                                process::exit(1);
                            }
                        }
                        break;
                    }
                    _ => {
                        eprintln!("nl: invalid option -- '{}'", chars[i]);
                        eprintln!("Try 'nl --help' for more information.");
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

/// Get value for a short option that takes an argument.
fn short_opt_value(
    s: &str,
    chars: &[char],
    i: usize,
    args: &mut impl Iterator<Item = std::ffi::OsString>,
    opt: char,
) -> String {
    if i + 1 < chars.len() {
        s[1 + i + 1..].to_string()
    } else {
        args.next()
            .unwrap_or_else(|| {
                eprintln!("nl: option requires an argument -- '{}'", opt);
                process::exit(1);
            })
            .to_string_lossy()
            .into_owned()
    }
}

/// Require an argument for a long option.
fn require_arg(args: &mut impl Iterator<Item = std::ffi::OsString>, opt: &str) -> String {
    args.next()
        .unwrap_or_else(|| {
            eprintln!("nl: option '{}' requires an argument", opt);
            process::exit(1);
        })
        .to_string_lossy()
        .into_owned()
}

fn print_help() {
    print!(
        "Usage: nl [OPTION]... [FILE]...\n\
         Write each FILE to standard output, with line numbers added.\n\n\
         With no FILE, or when FILE is -, read standard input.\n\n\
         Mandatory arguments to long options are mandatory for short options too.\n\
         \x20 -b, --body-numbering=STYLE      use STYLE for numbering body lines\n\
         \x20 -d, --section-delimiter=CC       use CC for logical page delimiters\n\
         \x20 -f, --footer-numbering=STYLE     use STYLE for numbering footer lines\n\
         \x20 -h, --header-numbering=STYLE     use STYLE for numbering header lines\n\
         \x20 -i, --line-increment=NUMBER      line number increment at each line\n\
         \x20 -l, --join-blank-lines=NUMBER    group of NUMBER empty lines counted as one\n\
         \x20 -n, --number-format=FORMAT       insert line numbers according to FORMAT\n\
         \x20 -p, --no-renumber                do not reset line numbers for each section\n\
         \x20 -s, --number-separator=STRING    add STRING after (possible) line number\n\
         \x20 -v, --starting-line-number=NUMBER  first line number for each section\n\
         \x20 -w, --number-width=NUMBER        use NUMBER columns for line numbers\n\
         \x20     --help                       display this help and exit\n\
         \x20     --version                    output version information and exit\n\n\
         By default, selects -v1 -i1 -l1 -sTAB -w6 -nrn -hn -bt -fn.\n\
         CC are two delimiter characters used to construct logical page delimiters;\n\
         a missing second character implies :.\n\n\
         STYLE is one of:\n\
         \x20 a   number all lines\n\
         \x20 t   number only nonempty lines\n\
         \x20 n   number no lines\n\
         \x20 pBRE  number only lines that contain a match for the basic regular\n\
         \x20       expression, BRE\n\n\
         FORMAT is one of:\n\
         \x20 ln   left justified, no leading zeros\n\
         \x20 rn   right justified, no leading zeros\n\
         \x20 rz   right justified, leading zeros\n"
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
    coreutils_rs::common::reset_sigpipe();

    #[cfg(target_os = "linux")]
    enlarge_pipes();

    let cli = parse_args();

    let files: Vec<String> = if cli.files.is_empty() {
        vec!["-".to_string()]
    } else {
        cli.files
    };

    let mut had_error = false;
    let mut line_number = cli.config.starting_line_number;

    for filename in &files {
        let data = if filename == "-" {
            match read_stdin() {
                Ok(d) => coreutils_rs::common::io::FileData::Owned(d),
                Err(e) => {
                    eprintln!("nl: standard input: {}", io_error_msg(&e));
                    had_error = true;
                    continue;
                }
            }
        } else {
            match read_file(Path::new(filename)) {
                Ok(d) => d,
                Err(e) => {
                    eprintln!("nl: {}: {}", filename, io_error_msg(&e));
                    had_error = true;
                    continue;
                }
            }
        };

        let output = nl::nl_to_vec_with_state(&data, &cli.config, &mut line_number);
        if let Err(e) = write_all_raw(&output) {
            if e.kind() == std::io::ErrorKind::BrokenPipe {
                process::exit(0);
            }
            eprintln!("nl: write error: {}", io_error_msg(&e));
            had_error = true;
        }
    }

    if had_error {
        process::exit(1);
    }
}

/// Write the full buffer to stdout, retrying on partial/interrupted writes.
#[cfg(unix)]
fn write_all_raw(data: &[u8]) -> std::io::Result<()> {
    let mut written = 0;
    while written < data.len() {
        let ret = unsafe {
            libc::write(
                1,
                data[written..].as_ptr() as *const libc::c_void,
                (data.len() - written) as _,
            )
        };
        if ret > 0 {
            written += ret as usize;
        } else if ret == 0 {
            return Err(std::io::Error::new(
                std::io::ErrorKind::WriteZero,
                "write returned 0",
            ));
        } else {
            let err = std::io::Error::last_os_error();
            if err.kind() == std::io::ErrorKind::Interrupted {
                continue;
            }
            return Err(err);
        }
    }
    Ok(())
}

#[cfg(not(unix))]
fn write_all_raw(data: &[u8]) -> std::io::Result<()> {
    use std::io::Write;
    let stdout = std::io::stdout();
    let mut out = std::io::BufWriter::with_capacity(256 * 1024, stdout.lock());
    out.write_all(data)?;
    out.flush()
}

#[cfg(test)]
mod tests {
    use std::process::Command;

    fn cmd() -> Command {
        let mut path = std::env::current_exe().unwrap();
        path.pop();
        path.pop();
        path.push("fnl");
        Command::new(path)
    }
    #[test]
    fn test_nl_basic_numbering() {
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
        let stdout = String::from_utf8_lossy(&output.stdout);
        assert!(stdout.contains("1") && stdout.contains("hello"));
        assert!(stdout.contains("2") && stdout.contains("world"));
    }

    #[test]
    fn test_nl_number_all_lines() {
        use std::io::Write;
        use std::process::Stdio;
        let mut child = cmd()
            .args(["-b", "a"])
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .spawn()
            .unwrap();
        child
            .stdin
            .take()
            .unwrap()
            .write_all(b"hello\n\nworld\n")
            .unwrap();
        let output = child.wait_with_output().unwrap();
        assert!(output.status.success());
        let stdout = String::from_utf8_lossy(&output.stdout);
        // With -b a, all lines including blank should be numbered
        assert!(stdout.contains("1"));
        assert!(stdout.contains("2"));
        assert!(stdout.contains("3"));
    }

    #[test]
    fn test_nl_no_numbering() {
        use std::io::Write;
        use std::process::Stdio;
        let mut child = cmd()
            .args(["-b", "n"])
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
        // -b n means no numbering; lines should have blank number fields
        assert!(stdout.contains("hello"));
        assert!(stdout.contains("world"));
    }

    #[test]
    fn test_nl_empty_input() {
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
    fn test_nl_starting_line_number() {
        use std::io::Write;
        use std::process::Stdio;
        let mut child = cmd()
            .args(["-v", "10"])
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .spawn()
            .unwrap();
        child.stdin.take().unwrap().write_all(b"a\nb\nc\n").unwrap();
        let output = child.wait_with_output().unwrap();
        assert!(output.status.success());
        let stdout = String::from_utf8_lossy(&output.stdout);
        assert!(stdout.contains("10"));
        assert!(stdout.contains("11"));
        assert!(stdout.contains("12"));
    }

    #[test]
    fn test_nl_line_increment() {
        use std::io::Write;
        use std::process::Stdio;
        let mut child = cmd()
            .args(["-i", "5"])
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .spawn()
            .unwrap();
        child.stdin.take().unwrap().write_all(b"a\nb\nc\n").unwrap();
        let output = child.wait_with_output().unwrap();
        assert!(output.status.success());
        let stdout = String::from_utf8_lossy(&output.stdout);
        assert!(stdout.contains("1"));
        assert!(stdout.contains("6"));
        assert!(stdout.contains("11"));
    }

    #[test]
    fn test_nl_number_width() {
        use std::io::Write;
        use std::process::Stdio;
        let mut child = cmd()
            .args(["-w", "3"])
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .spawn()
            .unwrap();
        child.stdin.take().unwrap().write_all(b"a\n").unwrap();
        let output = child.wait_with_output().unwrap();
        assert!(output.status.success());
        let stdout = String::from_utf8_lossy(&output.stdout);
        // Width 3 should produce "  1" prefix
        assert!(stdout.contains("  1"));
    }

    #[test]
    fn test_nl_left_justified() {
        use std::io::Write;
        use std::process::Stdio;
        let mut child = cmd()
            .args(["-n", "ln"])
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .spawn()
            .unwrap();
        child.stdin.take().unwrap().write_all(b"a\n").unwrap();
        let output = child.wait_with_output().unwrap();
        assert!(output.status.success());
        let stdout = String::from_utf8_lossy(&output.stdout);
        // ln format: left-justified
        assert!(stdout.starts_with("1"));
    }

    #[test]
    fn test_nl_zero_filled() {
        use std::io::Write;
        use std::process::Stdio;
        let mut child = cmd()
            .args(["-n", "rz"])
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .spawn()
            .unwrap();
        child.stdin.take().unwrap().write_all(b"a\n").unwrap();
        let output = child.wait_with_output().unwrap();
        assert!(output.status.success());
        let stdout = String::from_utf8_lossy(&output.stdout);
        // rz format: right-justified with leading zeros
        assert!(stdout.contains("000001"));
    }

    #[test]
    fn test_nl_custom_separator() {
        use std::io::Write;
        use std::process::Stdio;
        let mut child = cmd()
            .args(["-s", ": "])
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .spawn()
            .unwrap();
        child.stdin.take().unwrap().write_all(b"hello\n").unwrap();
        let output = child.wait_with_output().unwrap();
        assert!(output.status.success());
        let stdout = String::from_utf8_lossy(&output.stdout);
        assert!(stdout.contains(": hello"));
    }

    #[test]
    fn test_nl_file() {
        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join("test.txt");
        std::fs::write(&file, "line1\nline2\n").unwrap();
        let output = cmd().arg(file.to_str().unwrap()).output().unwrap();
        assert!(output.status.success());
        let stdout = String::from_utf8_lossy(&output.stdout);
        assert!(stdout.contains("1") && stdout.contains("line1"));
        assert!(stdout.contains("2") && stdout.contains("line2"));
    }

    #[test]
    fn test_nl_nonexistent_file() {
        let output = cmd().arg("/nonexistent_xyz_nl").output().unwrap();
        assert!(!output.status.success());
    }

    #[test]
    fn test_nl_default_skips_blank() {
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
            .write_all(b"hello\n\nworld\n")
            .unwrap();
        let output = child.wait_with_output().unwrap();
        assert!(output.status.success());
        let stdout = String::from_utf8_lossy(&output.stdout);
        // Default -b t: blank lines not numbered
        let lines: Vec<&str> = stdout.lines().collect();
        assert!(lines.len() == 3);
    }

    #[test]
    fn test_nl_invalid_numbering_style() {
        let output = cmd().args(["-b", "invalid"]).output().unwrap();
        assert!(!output.status.success());
    }

    #[test]
    fn test_nl_single_char_delimiter_implies_colon() {
        // GNU nl: -d with single char 'x' implies delimiter is 'x:'
        // So section delimiter lines are "x:x:x:" (header), "x:x:" (body), "x:" (footer)
        use std::io::Write;
        use std::process::Stdio;
        let mut child = cmd()
            .args(["-d", "x"])
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .spawn()
            .unwrap();
        // Input: "a\nx:x:\nc\n" — "x:x:" is body delimiter when delim is "x:"
        child
            .stdin
            .take()
            .unwrap()
            .write_all(b"a\nx:x:\nc\n")
            .unwrap();
        let output = child.wait_with_output().unwrap();
        assert!(output.status.success());
        let stdout = String::from_utf8_lossy(&output.stdout);
        // "x:x:" should be treated as body section delimiter (replaced with blank line)
        // "a" should be numbered as 1, then after section reset, "c" should be numbered as 1
        assert!(
            stdout.contains("1") && stdout.contains("a"),
            "stdout: {}",
            stdout
        );
        // The section delimiter line should appear as a blank line
        let lines: Vec<&str> = stdout.lines().collect();
        assert_eq!(
            lines.len(),
            3,
            "Should have 3 output lines, got: {:?}",
            lines
        );
    }

    #[test]
    fn test_nl_multiple_files_continue_numbering() {
        // GNU nl: line numbering continues across multiple files
        let dir = tempfile::tempdir().unwrap();
        let f1 = dir.path().join("f1.txt");
        let f2 = dir.path().join("f2.txt");
        std::fs::write(&f1, "a\n").unwrap();
        std::fs::write(&f2, "b\n").unwrap();
        let output = cmd()
            .args([f1.to_str().unwrap(), f2.to_str().unwrap()])
            .output()
            .unwrap();
        assert!(output.status.success());
        let stdout = String::from_utf8_lossy(&output.stdout);
        // First file: line 1 = "a", second file: line 2 = "b"
        let lines: Vec<&str> = stdout.lines().collect();
        assert_eq!(lines.len(), 2, "Should have 2 lines: {:?}", lines);
        assert!(
            lines[0].contains("1"),
            "First line should be numbered 1: {}",
            lines[0]
        );
        assert!(
            lines[1].contains("2"),
            "Second line should be numbered 2: {}",
            lines[1]
        );
    }
}
