use std::fs::File;
use std::io::{self, BufWriter, Write};
#[cfg(unix)]
use std::mem::ManuallyDrop;
#[cfg(unix)]
use std::os::unix::io::FromRawFd;
use std::process;

use memmap2::MmapOptions;

#[cfg(unix)]
use coreutils_rs::common::io::try_mmap_stdin;
use coreutils_rs::common::{enlarge_stdout_pipe, io_error_msg};
use coreutils_rs::uniq::{
    AllRepeatedMethod, GroupMethod, OutputMode, UniqConfig, process_uniq_bytes,
};

struct Cli {
    count: bool,
    repeated: bool,
    all_duplicates: bool,
    all_repeated: Option<String>,
    skip_fields: usize,
    group: Option<String>,
    ignore_case: bool,
    skip_chars: usize,
    unique: bool,
    check_chars: Option<usize>,
    zero_terminated: bool,
    input: Option<String>,
    output: Option<String>,
}

/// Hand-rolled argument parser — eliminates clap's ~100-200us initialization.
fn parse_args() -> Cli {
    let mut cli = Cli {
        count: false,
        repeated: false,
        all_duplicates: false,
        all_repeated: None,
        skip_fields: 0,
        group: None,
        ignore_case: false,
        skip_chars: 0,
        unique: false,
        check_chars: None,
        zero_terminated: false,
        input: None,
        output: None,
    };

    let mut positionals: Vec<String> = Vec::new();
    let mut args = std::env::args_os().skip(1);
    #[allow(clippy::while_let_on_iterator)]
    while let Some(arg) = args.next() {
        let bytes = arg.as_encoded_bytes();
        if bytes == b"--" {
            // Everything after -- is positional
            for a in args {
                positionals.push(a.to_string_lossy().into_owned());
            }
            break;
        }
        if bytes.starts_with(b"--") {
            // Long options
            // --all-repeated, --all-repeated=METHOD
            if bytes == b"--all-repeated" {
                // GNU uniq: --all-repeated without = defaults to "none"
                cli.all_repeated = Some("none".to_string());
            } else if bytes.starts_with(b"--all-repeated=") {
                let val = std::str::from_utf8(&bytes[15..]).unwrap_or("").to_string();
                cli.all_repeated = Some(val);
            // --group, --group=METHOD
            } else if bytes == b"--group" {
                // GNU uniq: --group without = defaults to "separate"
                cli.group = Some("separate".to_string());
            } else if bytes.starts_with(b"--group=") {
                let val = std::str::from_utf8(&bytes[8..]).unwrap_or("").to_string();
                cli.group = Some(val);
            // --skip-fields, --skip-fields=N
            } else if bytes.starts_with(b"--skip-fields=") {
                let val = std::str::from_utf8(&bytes[14..]).unwrap_or("");
                cli.skip_fields = parse_usize_arg("--skip-fields", val);
            } else if bytes == b"--skip-fields" {
                if let Some(v) = args.next() {
                    let s = v.to_string_lossy();
                    cli.skip_fields = parse_usize_arg("--skip-fields", &s);
                } else {
                    eprintln!("uniq: option '--skip-fields' requires an argument");
                    eprintln!("Try 'uniq --help' for more information.");
                    process::exit(1);
                }
            // --skip-chars, --skip-chars=N
            } else if bytes.starts_with(b"--skip-chars=") {
                let val = std::str::from_utf8(&bytes[13..]).unwrap_or("");
                cli.skip_chars = parse_usize_arg("--skip-chars", val);
            } else if bytes == b"--skip-chars" {
                if let Some(v) = args.next() {
                    let s = v.to_string_lossy();
                    cli.skip_chars = parse_usize_arg("--skip-chars", &s);
                } else {
                    eprintln!("uniq: option '--skip-chars' requires an argument");
                    eprintln!("Try 'uniq --help' for more information.");
                    process::exit(1);
                }
            // --check-chars, --check-chars=N
            } else if bytes.starts_with(b"--check-chars=") {
                let val = std::str::from_utf8(&bytes[14..]).unwrap_or("");
                cli.check_chars = Some(parse_usize_arg("--check-chars", val));
            } else if bytes == b"--check-chars" {
                if let Some(v) = args.next() {
                    let s = v.to_string_lossy();
                    cli.check_chars = Some(parse_usize_arg("--check-chars", &s));
                } else {
                    eprintln!("uniq: option '--check-chars' requires an argument");
                    eprintln!("Try 'uniq --help' for more information.");
                    process::exit(1);
                }
            } else {
                match bytes {
                    b"--count" => cli.count = true,
                    b"--repeated" => cli.repeated = true,
                    b"--ignore-case" => cli.ignore_case = true,
                    b"--unique" => cli.unique = true,
                    b"--zero-terminated" => cli.zero_terminated = true,
                    b"--help" => {
                        print!(
                            "Usage: uniq [OPTION]... [INPUT [OUTPUT]]\n\
                            Filter adjacent matching lines from INPUT (or standard input),\n\
                            writing to OUTPUT (or standard output).\n\n\
                            With no options, matching lines are merged to the first occurrence.\n\n\
                            Mandatory arguments to long options are mandatory for short options too.\n\
                            \x20 -c, --count           prefix lines by the number of occurrences\n\
                            \x20 -d, --repeated        only print duplicate lines, one for each group\n\
                            \x20 -D                    print all duplicate lines\n\
                            \x20     --all-repeated[=METHOD]  like -D, but allow separating groups\n\
                            \x20                                with an empty line;\n\
                            \x20                                METHOD={{none(default),prepend,separate}}\n\
                            \x20 -f, --skip-fields=N   avoid comparing the first N fields\n\
                            \x20     --group[=METHOD]   show all items, outputting an empty line before\n\
                            \x20                                each group;\n\
                            \x20                                METHOD={{separate(default),prepend,append,both}}\n\
                            \x20 -i, --ignore-case     ignore differences in case when comparing\n\
                            \x20 -s, --skip-chars=N    avoid comparing the first N characters\n\
                            \x20 -u, --unique          only print unique lines\n\
                            \x20 -w, --check-chars=N   compare no more than N characters in lines\n\
                            \x20 -z, --zero-terminated  line delimiter is NUL, not newline\n\
                            \x20     --help             display this help and exit\n\
                            \x20     --version          output version information and exit\n\n\
                            A field is a run of blanks (usually spaces and/or TABs), then non-blank \
                            characters. Fields are skipped before chars.\n\n\
                            Note: 'uniq' does not detect repeated lines unless they are adjacent.\n\
                            You may want to sort the input first, or use 'sort -u' without 'uniq'.\n"
                        );
                        process::exit(0);
                    }
                    b"--version" => {
                        println!("uniq (fcoreutils) {}", env!("CARGO_PKG_VERSION"));
                        process::exit(0);
                    }
                    _ => {
                        eprintln!("uniq: unrecognized option '{}'", arg.to_string_lossy());
                        eprintln!("Try 'uniq --help' for more information.");
                        process::exit(1);
                    }
                }
            }
        } else if bytes.len() > 1 && bytes[0] == b'-' {
            // Short options: can be combined (-ci means -c -i)
            let mut i = 1;
            while i < bytes.len() {
                match bytes[i] {
                    b'c' => cli.count = true,
                    b'd' => cli.repeated = true,
                    b'D' => cli.all_duplicates = true,
                    b'i' => cli.ignore_case = true,
                    b'u' => cli.unique = true,
                    b'z' => cli.zero_terminated = true,
                    b'f' | b's' | b'w' => {
                        // These take a numeric value: rest of arg or next arg
                        let flag = bytes[i];
                        let val_str = if i + 1 < bytes.len() {
                            // Value attached: -f1, -s2, -w3
                            std::str::from_utf8(&bytes[i + 1..])
                                .unwrap_or("")
                                .to_string()
                        } else if let Some(v) = args.next() {
                            v.to_string_lossy().into_owned()
                        } else {
                            eprintln!("uniq: option requires an argument -- '{}'", flag as char);
                            eprintln!("Try 'uniq --help' for more information.");
                            process::exit(1);
                        };
                        let flag_name = match flag {
                            b'f' => "-f",
                            b's' => "-s",
                            b'w' => "-w",
                            _ => unreachable!(),
                        };
                        let val = parse_usize_arg(flag_name, &val_str);
                        match flag {
                            b'f' => cli.skip_fields = val,
                            b's' => cli.skip_chars = val,
                            b'w' => cli.check_chars = Some(val),
                            _ => unreachable!(),
                        }
                        // Rest of bytes consumed as value
                        i = bytes.len();
                        continue;
                    }
                    _ => {
                        eprintln!("uniq: invalid option -- '{}'", bytes[i] as char);
                        eprintln!("Try 'uniq --help' for more information.");
                        process::exit(1);
                    }
                }
                i += 1;
            }
        } else {
            positionals.push(arg.to_string_lossy().into_owned());
        }
    }

    // Assign positional arguments: [INPUT [OUTPUT]]
    if positionals.len() > 2 {
        eprintln!("uniq: extra operand '{}'", positionals[2]);
        eprintln!("Try 'uniq --help' for more information.");
        process::exit(1);
    }
    if !positionals.is_empty() {
        cli.input = Some(positionals[0].clone());
    }
    if positionals.len() > 1 {
        cli.output = Some(positionals[1].clone());
    }

    cli
}

/// Parse a numeric argument, exiting with an error message on failure.
fn parse_usize_arg(flag: &str, val: &str) -> usize {
    match val.parse::<usize>() {
        Ok(n) => n,
        Err(_) => {
            eprintln!(
                "uniq: invalid number of {} to skip: '{}'",
                match flag {
                    "-f" | "--skip-fields" => "fields",
                    "-s" | "--skip-chars" => "characters",
                    "-w" | "--check-chars" => "characters",
                    _ => "bytes",
                },
                val
            );
            process::exit(1);
        }
    }
}

fn main() {
    coreutils_rs::common::reset_sigpipe();

    enlarge_stdout_pipe();

    let cli = parse_args();

    // Determine output mode
    let mode = if let Some(ref method_str) = cli.group {
        let method = match method_str.as_str() {
            "separate" => GroupMethod::Separate,
            "prepend" => GroupMethod::Prepend,
            "append" => GroupMethod::Append,
            "both" => GroupMethod::Both,
            other => {
                eprintln!("uniq: invalid argument '{}' for '--group'", other);
                eprintln!(
                    "Valid arguments are:\n  - 'separate'\n  - 'prepend'\n  - 'append'\n  - 'both'"
                );
                eprintln!("Try 'uniq --help' for more information.");
                process::exit(1);
            }
        };
        // --group is incompatible with -c, -d, -D, -u
        if cli.count
            || cli.repeated
            || cli.all_duplicates
            || cli.all_repeated.is_some()
            || cli.unique
        {
            eprintln!("uniq: --group is mutually exclusive with -c/-d/-D/-u");
            eprintln!("Try 'uniq --help' for more information.");
            process::exit(1);
        }
        OutputMode::Group(method)
    } else if cli.all_duplicates || cli.all_repeated.is_some() {
        let method = if let Some(ref method_str) = cli.all_repeated {
            match method_str.as_str() {
                "none" => AllRepeatedMethod::None,
                "prepend" => AllRepeatedMethod::Prepend,
                "separate" => AllRepeatedMethod::Separate,
                other => {
                    eprintln!("uniq: invalid argument '{}' for '--all-repeated'", other);
                    eprintln!("Valid arguments are:\n  - 'none'\n  - 'prepend'\n  - 'separate'");
                    eprintln!("Try 'uniq --help' for more information.");
                    process::exit(1);
                }
            }
        } else {
            AllRepeatedMethod::None
        };
        OutputMode::AllRepeated(method)
    } else if cli.repeated && cli.unique {
        // -d -u together: nothing satisfies both conditions, output nothing
        return;
    } else if cli.repeated {
        OutputMode::RepeatedOnly
    } else if cli.unique {
        OutputMode::UniqueOnly
    } else {
        OutputMode::Default
    };

    // -c is incompatible with -D/--all-repeated and --group
    if cli.count && matches!(mode, OutputMode::AllRepeated(_) | OutputMode::Group(_)) {
        eprintln!("uniq: printing all duplicated lines and repeat counts is meaningless");
        eprintln!("Try 'uniq --help' for more information.");
        process::exit(1);
    }

    let config = UniqConfig {
        mode,
        count: cli.count,
        ignore_case: cli.ignore_case,
        skip_fields: cli.skip_fields,
        skip_chars: cli.skip_chars,
        check_chars: cli.check_chars,
        zero_terminated: cli.zero_terminated,
    };

    // Dispatch to output file or stdout, avoiding Box<dyn Write> for stdout (common case)
    if let Some(ref path) = cli.output
        && path != "-"
    {
        let output = match File::create(path) {
            Ok(f) => BufWriter::new(f),
            Err(e) => {
                eprintln!("uniq: {}: {}", path, io_error_msg(&e));
                process::exit(1);
            }
        };
        run_uniq(&cli, &config, output);
        return;
    }

    // Use raw fd write — NOT vmsplice. The fast path (process_default_sequential)
    // writes IoSlices directly from data slices referencing the read_stdin() Vec.
    // vmsplice would reference those heap pages in the pipe buffer, but the Vec is
    // freed before the pipe consumer reads, causing use-after-free (zeroed output).
    // Regular writev() copies data into kernel pipe pages, avoiding the issue.
    #[cfg(unix)]
    {
        let mut raw = unsafe { ManuallyDrop::new(std::fs::File::from_raw_fd(1)) };
        run_uniq(&cli, &config, &mut *raw);
    }
    #[cfg(not(unix))]
    {
        let stdout = io::stdout();
        run_uniq(&cli, &config, stdout.lock());
    }
}

fn run_uniq(cli: &Cli, config: &UniqConfig, output: impl Write) {
    let result = match cli.input.as_deref() {
        Some("-") | None => {
            // Stdin: try mmap first (zero-copy for file redirects).
            // For piped stdin: buffer ALL input then use the fast mmap path
            // (process_uniq_bytes) which is ~3.5x faster than the streaming path.
            // The streaming path reads line-by-line through BufReader; the buffer
            // path uses memchr SIMD scanning, zero-copy output, and parallel dedup.
            #[cfg(unix)]
            {
                match try_mmap_stdin(0) {
                    Some(mmap) => process_uniq_bytes(&mmap, output, config),
                    None => {
                        // Use raw libc::read() via read_stdin() for piped stdin.
                        // Bypasses StdinLock/BufReader overhead, pre-allocates 64MB.
                        match coreutils_rs::common::io::read_stdin() {
                            Ok(buf) => process_uniq_bytes(&buf, output, config),
                            Err(e) => {
                                if e.kind() != io::ErrorKind::BrokenPipe {
                                    eprintln!("uniq: {}", io_error_msg(&e));
                                    process::exit(1);
                                }
                                return;
                            }
                        }
                    }
                }
            }
            #[cfg(not(unix))]
            {
                match coreutils_rs::common::io::read_stdin() {
                    Ok(buf) => process_uniq_bytes(&buf, output, config),
                    Err(e) => {
                        if e.kind() != io::ErrorKind::BrokenPipe {
                            eprintln!("uniq: {}", io_error_msg(&e));
                            process::exit(1);
                        }
                        return;
                    }
                }
            }
        }
        Some(path) => {
            // File: use mmap for zero-copy performance
            let file = match File::open(path) {
                Ok(f) => f,
                Err(e) => {
                    eprintln!("uniq: {}: {}", path, io_error_msg(&e));
                    process::exit(1);
                }
            };
            let metadata = match file.metadata() {
                Ok(m) => m,
                Err(e) => {
                    eprintln!("uniq: {}: {}", path, io_error_msg(&e));
                    process::exit(1);
                }
            };

            if metadata.len() == 0 {
                // Empty file, nothing to do
                return;
            }

            // Use mmap for files — MADV_SEQUENTIAL + WILLNEED + HUGEPAGE
            let mmap = match unsafe { MmapOptions::new().map(&file) } {
                Ok(m) => {
                    #[cfg(target_os = "linux")]
                    {
                        let _ = m.advise(memmap2::Advice::Sequential);
                        unsafe {
                            libc::madvise(
                                m.as_ptr() as *mut libc::c_void,
                                m.len(),
                                libc::MADV_WILLNEED,
                            );
                            if m.len() >= 2 * 1024 * 1024 {
                                libc::madvise(
                                    m.as_ptr() as *mut libc::c_void,
                                    m.len(),
                                    libc::MADV_HUGEPAGE,
                                );
                            }
                        }
                    }
                    m
                }
                Err(e) => {
                    eprintln!("uniq: {}: {}", path, io_error_msg(&e));
                    process::exit(1);
                }
            };

            process_uniq_bytes(&mmap, output, config)
        }
    };

    if let Err(e) = result {
        // Ignore broken pipe
        if e.kind() != io::ErrorKind::BrokenPipe {
            eprintln!("uniq: {}", io_error_msg(&e));
            process::exit(1);
        }
    }
}

#[cfg(test)]
mod tests {
    use std::io::Write;
    use std::process::Command;
    use std::process::Stdio;

    fn cmd() -> Command {
        let mut path = std::env::current_exe().unwrap();
        path.pop();
        path.pop();
        path.push("funiq");
        Command::new(path)
    }
    #[test]
    fn test_uniq_basic() {
        let mut child = cmd()
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .spawn()
            .unwrap();
        child
            .stdin
            .take()
            .unwrap()
            .write_all(b"a\na\nb\nc\nc\n")
            .unwrap();
        let output = child.wait_with_output().unwrap();
        assert!(output.status.success());
        assert_eq!(String::from_utf8_lossy(&output.stdout), "a\nb\nc\n");
    }

    #[test]
    fn test_uniq_count() {
        let mut child = cmd()
            .arg("-c")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .spawn()
            .unwrap();
        child.stdin.take().unwrap().write_all(b"a\na\nb\n").unwrap();
        let output = child.wait_with_output().unwrap();
        assert!(output.status.success());
        let stdout = String::from_utf8_lossy(&output.stdout);
        assert!(stdout.contains("2 a"));
        assert!(stdout.contains("1 b"));
    }

    #[test]
    fn test_uniq_repeated() {
        let mut child = cmd()
            .arg("-d")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .spawn()
            .unwrap();
        child
            .stdin
            .take()
            .unwrap()
            .write_all(b"a\na\nb\nc\nc\n")
            .unwrap();
        let output = child.wait_with_output().unwrap();
        assert!(output.status.success());
        assert_eq!(String::from_utf8_lossy(&output.stdout), "a\nc\n");
    }

    #[test]
    fn test_uniq_unique_only() {
        let mut child = cmd()
            .arg("-u")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .spawn()
            .unwrap();
        child
            .stdin
            .take()
            .unwrap()
            .write_all(b"a\na\nb\nc\nc\n")
            .unwrap();
        let output = child.wait_with_output().unwrap();
        assert!(output.status.success());
        assert_eq!(String::from_utf8_lossy(&output.stdout), "b\n");
    }

    #[test]
    fn test_uniq_empty_input() {
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
    fn test_uniq_single_line() {
        let mut child = cmd()
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .spawn()
            .unwrap();
        child.stdin.take().unwrap().write_all(b"hello\n").unwrap();
        let output = child.wait_with_output().unwrap();
        assert!(output.status.success());
        assert_eq!(String::from_utf8_lossy(&output.stdout), "hello\n");
    }

    #[test]
    fn test_uniq_all_same() {
        let mut child = cmd()
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .spawn()
            .unwrap();
        child
            .stdin
            .take()
            .unwrap()
            .write_all(b"a\na\na\na\n")
            .unwrap();
        let output = child.wait_with_output().unwrap();
        assert!(output.status.success());
        assert_eq!(String::from_utf8_lossy(&output.stdout), "a\n");
    }

    #[test]
    fn test_uniq_case_insensitive() {
        let mut child = cmd()
            .arg("-i")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .spawn()
            .unwrap();
        child
            .stdin
            .take()
            .unwrap()
            .write_all(b"Hello\nhello\nHELLO\nworld\n")
            .unwrap();
        let output = child.wait_with_output().unwrap();
        assert!(output.status.success());
        assert_eq!(String::from_utf8_lossy(&output.stdout), "Hello\nworld\n");
    }

    #[test]
    fn test_uniq_skip_fields() {
        let mut child = cmd()
            .args(["-f", "1"])
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .spawn()
            .unwrap();
        child
            .stdin
            .take()
            .unwrap()
            .write_all(b"1 apple\n2 apple\n3 banana\n")
            .unwrap();
        let output = child.wait_with_output().unwrap();
        assert!(output.status.success());
        assert_eq!(
            String::from_utf8_lossy(&output.stdout),
            "1 apple\n3 banana\n"
        );
    }

    #[test]
    fn test_uniq_skip_chars() {
        let mut child = cmd()
            .args(["-s", "2"])
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .spawn()
            .unwrap();
        child
            .stdin
            .take()
            .unwrap()
            .write_all(b"aaXYZ\nbbXYZ\nccABC\n")
            .unwrap();
        let output = child.wait_with_output().unwrap();
        assert!(output.status.success());
        assert_eq!(String::from_utf8_lossy(&output.stdout), "aaXYZ\nccABC\n");
    }

    #[test]
    fn test_uniq_count_format() {
        let mut child = cmd()
            .arg("-c")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .spawn()
            .unwrap();
        child
            .stdin
            .take()
            .unwrap()
            .write_all(b"a\na\na\nb\nb\nc\n")
            .unwrap();
        let output = child.wait_with_output().unwrap();
        assert!(output.status.success());
        let stdout = String::from_utf8_lossy(&output.stdout);
        assert!(stdout.contains("3 a"));
        assert!(stdout.contains("2 b"));
        assert!(stdout.contains("1 c"));
    }

    #[test]
    fn test_uniq_file_input() {
        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join("test.txt");
        std::fs::write(&file, "a\na\nb\nb\nc\n").unwrap();
        let output = cmd().arg(file.to_str().unwrap()).output().unwrap();
        assert!(output.status.success());
        assert_eq!(String::from_utf8_lossy(&output.stdout), "a\nb\nc\n");
    }

    #[test]
    fn test_uniq_output_file() {
        let dir = tempfile::tempdir().unwrap();
        let input = dir.path().join("input.txt");
        let output_file = dir.path().join("output.txt");
        std::fs::write(&input, "a\na\nb\n").unwrap();
        let output = cmd()
            .args([input.to_str().unwrap(), output_file.to_str().unwrap()])
            .output()
            .unwrap();
        assert!(output.status.success());
        let result = std::fs::read_to_string(&output_file).unwrap();
        assert_eq!(result, "a\nb\n");
    }

    #[test]
    fn test_uniq_check_chars() {
        let mut child = cmd()
            .args(["-w", "3"])
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .spawn()
            .unwrap();
        child
            .stdin
            .take()
            .unwrap()
            .write_all(b"abcXXX\nabcYYY\ndefZZZ\n")
            .unwrap();
        let output = child.wait_with_output().unwrap();
        assert!(output.status.success());
        assert_eq!(String::from_utf8_lossy(&output.stdout), "abcXXX\ndefZZZ\n");
    }
}
