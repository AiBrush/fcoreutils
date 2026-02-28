use std::fs::File;
use std::io::{self, BufWriter, Write};
#[cfg(unix)]
use std::mem::ManuallyDrop;
#[cfg(unix)]
use std::os::unix::io::FromRawFd;
use std::process;

use clap::Parser;
use memmap2::MmapOptions;

use coreutils_rs::common::io_error_msg;
use coreutils_rs::uniq::{
    AllRepeatedMethod, GroupMethod, OutputMode, UniqConfig, process_uniq_bytes,
};

#[derive(Parser)]
#[command(
    name = "uniq",
    about = "Report or omit repeated lines",
    after_help = "A field is a run of blanks (usually spaces and/or TABs), then non-blank \
                  characters. Fields are skipped before chars.\n\n\
                  Note: 'uniq' does not detect repeated lines unless they are adjacent.\n\
                  You may want to sort the input first, or use 'sort -u' without 'uniq'."
)]
struct Cli {
    /// Prefix lines by the number of occurrences
    #[arg(short = 'c', long = "count")]
    count: bool,

    /// Only print duplicate lines, one for each group
    #[arg(short = 'd', long = "repeated")]
    repeated: bool,

    /// Print all duplicate lines
    #[arg(short = 'D', overrides_with = "all_repeated")]
    all_duplicates: bool,

    /// Print all duplicate lines, delimited with METHOD (none, prepend, separate)
    #[arg(
        long = "all-repeated",
        value_name = "METHOD",
        num_args = 0..=1,
        default_missing_value = "none",
        require_equals = true
    )]
    all_repeated: Option<String>,

    /// Avoid comparing the first N fields
    #[arg(
        short = 'f',
        long = "skip-fields",
        value_name = "N",
        default_value = "0"
    )]
    skip_fields: usize,

    /// Show all items, delimited by empty line (separate, prepend, append, both)
    #[arg(
        long = "group",
        value_name = "METHOD",
        num_args = 0..=1,
        default_missing_value = "separate",
        require_equals = true
    )]
    group: Option<String>,

    /// Ignore differences in case when comparing
    #[arg(short = 'i', long = "ignore-case")]
    ignore_case: bool,

    /// Avoid comparing the first N characters
    #[arg(
        short = 's',
        long = "skip-chars",
        value_name = "N",
        default_value = "0"
    )]
    skip_chars: usize,

    /// Only print unique lines
    #[arg(short = 'u', long = "unique")]
    unique: bool,

    /// Compare no more than N characters in lines
    #[arg(short = 'w', long = "check-chars", value_name = "N")]
    check_chars: Option<usize>,

    /// Line delimiter is NUL, not newline
    #[arg(short = 'z', long = "zero-terminated")]
    zero_terminated: bool,

    /// Input file (default: stdin)
    input: Option<String>,

    /// Output file (default: stdout)
    output: Option<String>,
}

/// Enlarge pipe buffers on Linux for higher throughput.
/// 8MB matches other tools (ftac, fbase64, ftr, fcut) for consistent syscall reduction.
#[cfg(target_os = "linux")]
fn enlarge_pipes() {
    const PIPE_SIZE: i32 = 8 * 1024 * 1024;
    unsafe {
        libc::fcntl(0, libc::F_SETPIPE_SZ, PIPE_SIZE); // stdin
        libc::fcntl(1, libc::F_SETPIPE_SZ, PIPE_SIZE); // stdout
    }
}

fn main() {
    coreutils_rs::common::reset_sigpipe();

    #[cfg(target_os = "linux")]
    enlarge_pipes();

    let cli = Cli::parse();

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

/// Try to mmap stdin if it's a regular file (e.g., shell redirect `< file`).
/// Returns None if stdin is a pipe/terminal.
#[cfg(unix)]
fn try_mmap_stdin() -> Option<memmap2::Mmap> {
    use std::os::unix::io::{AsRawFd, FromRawFd};
    let stdin = io::stdin();
    let fd = stdin.as_raw_fd();

    let mut stat: libc::stat = unsafe { std::mem::zeroed() };
    if unsafe { libc::fstat(fd, &mut stat) } != 0 {
        return None;
    }
    if (stat.st_mode & libc::S_IFMT) != libc::S_IFREG || stat.st_size <= 0 {
        return None;
    }

    let file = unsafe { std::fs::File::from_raw_fd(fd) };
    let mmap = unsafe { MmapOptions::new().map(&file) }.ok();
    std::mem::forget(file); // Don't close stdin
    #[cfg(target_os = "linux")]
    if let Some(ref m) = mmap {
        unsafe {
            libc::madvise(
                m.as_ptr() as *mut libc::c_void,
                m.len(),
                libc::MADV_SEQUENTIAL,
            );
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
    mmap
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
                match try_mmap_stdin() {
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
