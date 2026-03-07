use std::io::{self, Write};
#[cfg(any(target_os = "linux", unix))]
use std::mem::ManuallyDrop;
#[cfg(any(target_os = "linux", unix))]
use std::os::unix::io::FromRawFd;
use std::process;

#[cfg(unix)]
use coreutils_rs::common::io::try_mmap_stdin;
use coreutils_rs::common::io_error_msg;
use coreutils_rs::tr;

/// Raw stdin reader for zero-overhead pipe reads on Linux.
/// Bypasses Rust's StdinLock (mutex + 8KB BufReader) for direct libc::read(0).
///
/// SAFETY: Caller must ensure no other code reads from fd 0 (stdin) while
/// this struct is alive. Do not mix with `io::stdin()` on the same code path.
/// This is the exclusive reader of fd 0 for its lifetime.
#[cfg(target_os = "linux")]
struct RawStdin;

/// Create a stdin reader and execute body with it.
/// On Linux, uses RawStdin for zero-overhead reads.
/// On other platforms, uses Rust's StdinLock.
/// Uses a macro because tr functions take `impl Read` (requires Sized),
/// which is incompatible with `dyn Read`.
macro_rules! with_stdin_reader {
    ($reader:ident => $body:expr) => {{
        #[cfg(target_os = "linux")]
        {
            let mut $reader = RawStdin;
            $body
        }
        #[cfg(not(target_os = "linux"))]
        {
            let stdin = io::stdin();
            let mut $reader = stdin.lock();
            $body
        }
    }};
}

#[cfg(target_os = "linux")]
impl io::Read for RawStdin {
    #[inline]
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        loop {
            let ret = unsafe { libc::read(0, buf.as_mut_ptr() as *mut libc::c_void, buf.len()) };
            if ret >= 0 {
                return Ok(ret as usize);
            }
            let err = io::Error::last_os_error();
            if err.kind() != io::ErrorKind::Interrupted {
                return Err(err);
            }
        }
    }
}

struct Cli {
    complement: bool,
    delete: bool,
    squeeze: bool,
    truncate: bool,
    sets: Vec<String>,
}

/// Hand-rolled argument parser — eliminates clap's ~100-200µs initialization.
/// tr's args are simple: -c/-C, -d, -s, -t flags + 1-2 positional SET args.
fn parse_args() -> Cli {
    let mut cli = Cli {
        complement: false,
        delete: false,
        squeeze: false,
        truncate: false,
        sets: Vec::with_capacity(2),
    };

    let mut args = std::env::args_os().skip(1);
    #[allow(clippy::while_let_on_iterator)]
    while let Some(arg) = args.next() {
        let bytes = arg.as_encoded_bytes();
        if bytes == b"--" {
            // Everything after -- is positional
            for a in args {
                cli.sets.push(a.to_string_lossy().into_owned());
            }
            break;
        }
        if bytes.starts_with(b"--") {
            match bytes {
                b"--complement" => cli.complement = true,
                b"--delete" => cli.delete = true,
                b"--squeeze-repeats" => cli.squeeze = true,
                b"--truncate-set1" => cli.truncate = true,
                b"--help" => {
                    print!(
                        "Usage: tr [OPTION]... SET1 [SET2]\n\
                        Translate, squeeze, and/or delete characters from standard input,\n\
                        writing to standard output.\n\n\
                        \x20 -c, -C, --complement    use the complement of SET1\n\
                        \x20 -d, --delete            delete characters in SET1, do not translate\n\
                        \x20 -s, --squeeze-repeats   replace each sequence of a repeated character\n\
                        \x20                         that is listed in the last specified SET,\n\
                        \x20                         with a single occurrence of that character\n\
                        \x20 -t, --truncate-set1     first truncate SET1 to length of SET2\n\
                        \x20     --help              display this help and exit\n\
                        \x20     --version           output version information and exit\n"
                    );
                    process::exit(0);
                }
                b"--version" => {
                    println!("tr (fcoreutils) {}", env!("CARGO_PKG_VERSION"));
                    process::exit(0);
                }
                _ => {
                    eprintln!("tr: unrecognized option '{}'", arg.to_string_lossy());
                    eprintln!("Try 'tr --help' for more information.");
                    process::exit(1);
                }
            }
        } else if bytes.len() > 1 && bytes[0] == b'-' {
            // Short options: -c, -d, -s, -t (can be combined: -ds, -cd, etc.)
            for &b in &bytes[1..] {
                match b {
                    b'c' | b'C' => cli.complement = true,
                    b'd' => cli.delete = true,
                    b's' => cli.squeeze = true,
                    b't' => cli.truncate = true,
                    _ => {
                        eprintln!("tr: invalid option -- '{}'", b as char);
                        eprintln!("Try 'tr --help' for more information.");
                        process::exit(1);
                    }
                }
            }
        } else {
            cli.sets.push(arg.to_string_lossy().into_owned());
        }
    }

    if cli.sets.is_empty() {
        eprintln!("tr: missing operand");
        eprintln!("Try 'tr --help' for more information.");
        process::exit(1);
    }

    cli
}

/// Raw fd stdout for zero-overhead writes on non-Linux Unix.
#[cfg(all(unix, not(target_os = "linux")))]
#[inline]
fn raw_stdout() -> ManuallyDrop<std::fs::File> {
    unsafe { ManuallyDrop::new(std::fs::File::from_raw_fd(1)) }
}

/// Enlarge pipe buffers on Linux for higher throughput.
/// Skips /proc read — directly tries decreasing sizes via fcntl.
/// Saves ~50µs startup vs reading /proc/sys/fs/pipe-max-size.
#[cfg(target_os = "linux")]
fn enlarge_pipe_bufs() {
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
    enlarge_pipe_bufs();

    let cli = parse_args();

    let set1_str = &cli.sets[0];

    #[cfg(all(unix, not(target_os = "linux")))]
    let mut raw = raw_stdout();

    // Pure translate mode: streaming with 8MB buffer for L2/L3 cache locality.
    // Faster than mmap: avoids full-file allocation + page fault overhead.
    let is_pure_translate = !cli.delete && !cli.squeeze && cli.sets.len() >= 2;

    if is_pure_translate {
        let set2_str = &cli.sets[1];
        let (mut set1, set1_classes) = tr::parse_set_with_classes(set1_str);
        if cli.complement {
            set1 = tr::complement(&set1);
            // Complement mode replaces the set entirely — class positions are meaningless.
            // Skip case class validation (GNU tr also skips it for -c).
        } else {
            // Validate case class alignment before expanding SET2
            let (set2_raw, set2_classes) = tr::parse_set_with_classes(set2_str);
            if let Err(msg) = tr::validate_case_classes(&set1_classes, &set2_classes) {
                eprintln!("tr: {}", msg);
                process::exit(1);
            }
            // Validate SET2 doesn't end with a case class when SET1 is longer
            if let Err(msg) =
                tr::validate_set2_class_at_end(set1.len(), set2_raw.len(), &set2_classes)
            {
                eprintln!("tr: {}", msg);
                process::exit(1);
            }
        }
        let set2 = if cli.truncate {
            let raw_set = tr::parse_set(set2_str);
            set1.truncate(raw_set.len());
            raw_set
        } else {
            tr::expand_set2(set2_str, set1.len())
        };

        // Try mmap for regular file stdin (redirect): uses translate_mmap which
        // processes data zero-copy from page cache, avoiding 2MB buffer allocation.
        // Falls back to streaming translate for pipes/terminals.
        #[cfg(unix)]
        let stdin_mmap = try_mmap_stdin(2 * 1024 * 1024);

        let result = {
            #[cfg(unix)]
            {
                if let Some(ref data) = stdin_mmap {
                    let mut raw_out = unsafe { ManuallyDrop::new(std::fs::File::from_raw_fd(1)) };
                    tr::translate_mmap(&set1, &set2, data, &mut *raw_out)
                } else {
                    #[cfg(target_os = "linux")]
                    {
                        let mut reader = RawStdin;
                        let mut raw_out =
                            unsafe { ManuallyDrop::new(std::fs::File::from_raw_fd(1)) };
                        tr::translate(&set1, &set2, &mut reader, &mut *raw_out)
                    }
                    #[cfg(not(target_os = "linux"))]
                    {
                        let stdin = io::stdin();
                        let mut reader = stdin.lock();
                        tr::translate(&set1, &set2, &mut reader, &mut *raw)
                    }
                }
            }
            #[cfg(not(unix))]
            {
                let stdin = io::stdin();
                let mut reader = stdin.lock();
                let stdout = io::stdout();
                let mut lock = stdout.lock();
                tr::translate(&set1, &set2, &mut reader, &mut lock)
            }
        };
        if let Err(e) = result
            && e.kind() != io::ErrorKind::BrokenPipe
        {
            eprintln!("tr: {}", io_error_msg(&e));
            process::exit(1);
        }
        return;
    }

    // Non-translate modes (delete, squeeze, etc.).
    // Try mmap for regular file stdin; fall back to streaming for pipes/terminals.
    // Parse sets and validate args first (shared between mmap and streaming paths).
    let parsed = parse_non_translate_args(&cli, set1_str);

    // Try mmap on Unix — any regular file benefits (threshold 0).
    #[cfg(unix)]
    let stdin_mmap = try_mmap_stdin(0);

    #[cfg(unix)]
    let mmap_result = if let Some(ref data) = stdin_mmap {
        let mut raw_out = unsafe { ManuallyDrop::new(std::fs::File::from_raw_fd(1)) };
        Some(run_mmap_mode(&parsed, data, &mut *raw_out))
    } else {
        None
    };
    #[cfg(not(unix))]
    let mmap_result: Option<io::Result<()>> = None;

    let result = if let Some(r) = mmap_result {
        r
    } else {
        #[cfg(target_os = "linux")]
        {
            let mut raw_out = unsafe { ManuallyDrop::new(std::fs::File::from_raw_fd(1)) };
            run_streaming_mode_parsed(&parsed, &mut *raw_out)
        }
        #[cfg(all(unix, not(target_os = "linux")))]
        {
            run_streaming_mode_parsed(&parsed, &mut *raw)
        }
        #[cfg(not(unix))]
        {
            let stdout = io::stdout();
            let mut lock = stdout.lock();
            run_streaming_mode_parsed(&parsed, &mut lock)
        }
    };
    if let Err(e) = result
        && e.kind() != io::ErrorKind::BrokenPipe
    {
        eprintln!("tr: {}", io_error_msg(&e));
        process::exit(1);
    }
}

/// Parsed and validated non-translate mode arguments.
/// Separates argument parsing/validation from I/O dispatch so both mmap and
/// streaming paths can share the same parsed sets.
enum ParsedMode {
    /// -d -s: delete chars in set1, then squeeze chars in set2
    DeleteSqueeze {
        delete_set: Vec<u8>,
        squeeze_set: Vec<u8>,
    },
    /// -d: delete chars in set1
    Delete { delete_set: Vec<u8> },
    /// -s (single set): squeeze repeats of chars in set1
    Squeeze { squeeze_set: Vec<u8> },
    /// -s with translate: translate set1→set2, then squeeze set2
    TranslateSqueeze { set1: Vec<u8>, set2: Vec<u8> },
}

/// Parse and validate arguments for non-translate modes.
/// Performs all error checking and set expansion, then returns a ParsedMode
/// that can be dispatched to either mmap or streaming.
fn parse_non_translate_args(cli: &Cli, set1_str: &str) -> ParsedMode {
    if cli.delete && cli.squeeze {
        if cli.sets.len() < 2 {
            eprintln!("tr: missing operand after '{}'", set1_str);
            eprintln!("Two strings must be given when both deleting and squeezing repeats.");
            eprintln!("Try 'tr --help' for more information.");
            process::exit(1);
        }
        let set2_str = &cli.sets[1];
        let set1 = tr::parse_set(set1_str);
        let set2 = tr::parse_set(set2_str);
        let delete_set = if cli.complement {
            tr::complement(&set1)
        } else {
            set1
        };
        ParsedMode::DeleteSqueeze {
            delete_set,
            squeeze_set: set2,
        }
    } else if cli.delete {
        if cli.sets.len() > 1 {
            eprintln!("tr: extra operand '{}'", cli.sets[1]);
            eprintln!("Only one string may be given when deleting without squeezing.");
            eprintln!("Try 'tr --help' for more information.");
            process::exit(1);
        }
        let set1 = tr::parse_set(set1_str);
        let delete_set = if cli.complement {
            tr::complement(&set1)
        } else {
            set1
        };
        ParsedMode::Delete { delete_set }
    } else if cli.squeeze && cli.sets.len() < 2 {
        let set1 = tr::parse_set(set1_str);
        let squeeze_set = if cli.complement {
            tr::complement(&set1)
        } else {
            set1
        };
        ParsedMode::Squeeze { squeeze_set }
    } else if cli.squeeze {
        let set2_str = &cli.sets[1];
        let (mut set1, set1_classes) = tr::parse_set_with_classes(set1_str);
        if cli.complement {
            set1 = tr::complement(&set1);
        } else {
            let (set2_raw, set2_classes) = tr::parse_set_with_classes(set2_str);
            if let Err(msg) = tr::validate_case_classes(&set1_classes, &set2_classes) {
                eprintln!("tr: {}", msg);
                process::exit(1);
            }
            if let Err(msg) =
                tr::validate_set2_class_at_end(set1.len(), set2_raw.len(), &set2_classes)
            {
                eprintln!("tr: {}", msg);
                process::exit(1);
            }
        }
        let set2 = if cli.truncate {
            let raw_set = tr::parse_set(set2_str);
            set1.truncate(raw_set.len());
            raw_set
        } else {
            tr::expand_set2(set2_str, set1.len())
        };
        ParsedMode::TranslateSqueeze { set1, set2 }
    } else {
        eprintln!("tr: missing operand after '{}'", set1_str);
        eprintln!("Two strings must be given when translating.");
        eprintln!("Try 'tr --help' for more information.");
        process::exit(1);
    }
}

/// Dispatch mmap-backed non-translate modes.
/// Called when stdin is a regular file and mmap succeeded.
fn run_mmap_mode(parsed: &ParsedMode, data: &[u8], writer: &mut impl Write) -> io::Result<()> {
    match parsed {
        ParsedMode::DeleteSqueeze {
            delete_set,
            squeeze_set,
        } => tr::delete_squeeze_mmap(delete_set, squeeze_set, data, writer),
        ParsedMode::Delete { delete_set } => tr::delete_mmap(delete_set, data, writer),
        ParsedMode::Squeeze { squeeze_set } => tr::squeeze_mmap(squeeze_set, data, writer),
        ParsedMode::TranslateSqueeze { set1, set2 } => {
            tr::translate_squeeze_mmap(set1, set2, data, writer)
        }
    }
}

/// Dispatch streaming non-translate modes using pre-parsed sets.
/// Called when stdin is a pipe/terminal (mmap not available).
fn run_streaming_mode_parsed(parsed: &ParsedMode, writer: &mut impl Write) -> io::Result<()> {
    match parsed {
        ParsedMode::DeleteSqueeze {
            delete_set,
            squeeze_set,
        } => {
            with_stdin_reader!(reader => tr::delete_squeeze(delete_set, squeeze_set, &mut reader, writer))
        }
        ParsedMode::Delete { delete_set } => {
            with_stdin_reader!(reader => tr::delete(delete_set, &mut reader, writer))
        }
        ParsedMode::Squeeze { squeeze_set } => {
            with_stdin_reader!(reader => tr::squeeze(squeeze_set, &mut reader, writer))
        }
        ParsedMode::TranslateSqueeze { set1, set2 } => {
            with_stdin_reader!(reader => tr::translate_squeeze(set1, set2, &mut reader, writer))
        }
    }
}

#[cfg(test)]
mod tests {
    use std::process::Command;

    fn cmd() -> Command {
        let mut path = std::env::current_exe().unwrap();
        path.pop();
        path.pop();
        path.push("ftr");
        Command::new(path)
    }
    #[test]
    fn test_tr_basic_translate() {
        use std::io::Write;
        use std::process::Stdio;
        let mut child = cmd()
            .args(["a", "b"])
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .spawn()
            .unwrap();
        child.stdin.take().unwrap().write_all(b"apple\n").unwrap();
        let output = child.wait_with_output().unwrap();
        assert!(output.status.success());
        assert_eq!(String::from_utf8_lossy(&output.stdout), "bpple\n");
    }

    #[test]
    fn test_tr_lowercase_to_uppercase() {
        use std::io::Write;
        use std::process::Stdio;
        let mut child = cmd()
            .args(["[:lower:]", "[:upper:]"])
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
        assert_eq!(String::from_utf8_lossy(&output.stdout), "HELLO WORLD\n");
    }

    #[test]
    fn test_tr_delete() {
        use std::io::Write;
        use std::process::Stdio;
        let mut child = cmd()
            .args(["-d", "aeiou"])
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
        assert_eq!(String::from_utf8_lossy(&output.stdout), "hll wrld\n");
    }

    #[test]
    fn test_tr_squeeze() {
        use std::io::Write;
        use std::process::Stdio;
        let mut child = cmd()
            .args(["-s", " "])
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .spawn()
            .unwrap();
        child
            .stdin
            .take()
            .unwrap()
            .write_all(b"hello   world   foo\n")
            .unwrap();
        let output = child.wait_with_output().unwrap();
        assert!(output.status.success());
        assert_eq!(String::from_utf8_lossy(&output.stdout), "hello world foo\n");
    }

    #[test]
    fn test_tr_complement_delete() {
        use std::io::Write;
        use std::process::Stdio;
        let mut child = cmd()
            .args(["-cd", "[:digit:]\n"])
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .spawn()
            .unwrap();
        child
            .stdin
            .take()
            .unwrap()
            .write_all(b"abc123def456\n")
            .unwrap();
        let output = child.wait_with_output().unwrap();
        assert!(output.status.success());
        assert_eq!(String::from_utf8_lossy(&output.stdout), "123456\n");
    }

    #[test]
    fn test_tr_range() {
        use std::io::Write;
        use std::process::Stdio;
        let mut child = cmd()
            .args(["a-z", "A-Z"])
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .spawn()
            .unwrap();
        child.stdin.take().unwrap().write_all(b"hello\n").unwrap();
        let output = child.wait_with_output().unwrap();
        assert!(output.status.success());
        assert_eq!(String::from_utf8_lossy(&output.stdout), "HELLO\n");
    }

    #[test]
    fn test_tr_empty_input() {
        use std::process::Stdio;
        let mut child = cmd()
            .args(["a", "b"])
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
    fn test_tr_delete_newlines() {
        use std::io::Write;
        use std::process::Stdio;
        let mut child = cmd()
            .args(["-d", "\n"])
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
        assert_eq!(String::from_utf8_lossy(&output.stdout), "helloworld");
    }

    #[test]
    fn test_tr_squeeze_repeated() {
        use std::io::Write;
        use std::process::Stdio;
        let mut child = cmd()
            .args(["-s", "aeiou"])
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .spawn()
            .unwrap();
        child.stdin.take().unwrap().write_all(b"beeeeef\n").unwrap();
        let output = child.wait_with_output().unwrap();
        assert!(output.status.success());
        assert_eq!(String::from_utf8_lossy(&output.stdout), "bef\n");
    }

    #[test]
    fn test_tr_no_args() {
        let output = cmd().output().unwrap();
        assert!(!output.status.success());
    }

    #[test]
    fn test_tr_translate_digits() {
        use std::io::Write;
        use std::process::Stdio;
        let mut child = cmd()
            .args(["0123456789", "abcdefghij"])
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .spawn()
            .unwrap();
        child.stdin.take().unwrap().write_all(b"12345\n").unwrap();
        let output = child.wait_with_output().unwrap();
        assert!(output.status.success());
        assert_eq!(String::from_utf8_lossy(&output.stdout), "bcdef\n");
    }

    #[test]
    fn test_tr_truncate_set2() {
        use std::io::Write;
        use std::process::Stdio;
        let mut child = cmd()
            .args(["-t", "abc", "xy"])
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .spawn()
            .unwrap();
        child.stdin.take().unwrap().write_all(b"abcabc\n").unwrap();
        let output = child.wait_with_output().unwrap();
        assert!(output.status.success());
        // -t truncates set1 to match set2 length; only a→x, b→y; c unchanged
        assert_eq!(String::from_utf8_lossy(&output.stdout), "xycxyc\n");
    }
}
