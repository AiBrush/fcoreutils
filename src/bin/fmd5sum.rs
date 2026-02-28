use std::io::{self, BufReader, BufWriter, Write};
#[cfg(unix)]
use std::mem::ManuallyDrop;
#[cfg(unix)]
use std::os::unix::io::FromRawFd;
use std::path::Path;
use std::process;

use coreutils_rs::common::io_error_msg;
use coreutils_rs::hash::{self, HashAlgorithm};

const TOOL_NAME: &str = "md5sum";

struct Cli {
    binary: bool,
    check: bool,
    tag: bool,
    text: bool,
    ignore_missing: bool,
    quiet: bool,
    status: bool,
    strict: bool,
    warn: bool,
    zero: bool,
    files: Vec<String>,
}

/// Hand-rolled argument parser — eliminates clap's ~100-200µs initialization.
fn parse_args() -> Cli {
    let mut cli = Cli {
        binary: false,
        check: false,
        tag: false,
        text: false,
        ignore_missing: false,
        quiet: false,
        status: false,
        strict: false,
        warn: false,
        zero: false,
        files: Vec::new(),
    };

    let args = std::env::args_os().skip(1);
    let mut saw_dashdash = false;
    for arg in args {
        let bytes = arg.as_encoded_bytes();
        if saw_dashdash {
            cli.files.push(arg.to_string_lossy().into_owned());
            continue;
        }
        if bytes == b"--" {
            saw_dashdash = true;
            continue;
        }
        if bytes.starts_with(b"--") {
            match bytes {
                b"--binary" => cli.binary = true,
                b"--check" => cli.check = true,
                b"--tag" => cli.tag = true,
                b"--text" => cli.text = true,
                b"--ignore-missing" => cli.ignore_missing = true,
                b"--quiet" => cli.quiet = true,
                b"--status" => cli.status = true,
                b"--strict" => cli.strict = true,
                b"--warn" => cli.warn = true,
                b"--zero" => cli.zero = true,
                b"--help" => {
                    print!(
                        "Usage: {} [OPTION]... [FILE]...\n\
                        Print or check MD5 (128-bit) checksums.\n\n\
                        With no FILE, or when FILE is -, read standard input.\n\n\
                        \x20 -b, --binary         read in binary mode\n\
                        \x20 -c, --check          read checksums from the FILEs and check them\n\
                        \x20     --tag             create a BSD-style checksum\n\
                        \x20 -t, --text           read in text mode (default)\n\
                        \x20 -z, --zero           end each output line with NUL, not newline\n\n\
                        The following five options are useful only when verifying checksums:\n\
                        \x20     --ignore-missing  don't fail or report status for missing files\n\
                        \x20     --quiet           don't print OK for each successfully verified file\n\
                        \x20     --status          don't output anything, status code shows success\n\
                        \x20     --strict          exit non-zero for improperly formatted checksum lines\n\
                        \x20 -w, --warn           warn about improperly formatted checksum lines\n\n\
                        \x20     --help            display this help and exit\n\
                        \x20     --version         output version information and exit\n",
                        TOOL_NAME
                    );
                    process::exit(0);
                }
                b"--version" => {
                    println!("{} (fcoreutils) {}", TOOL_NAME, env!("CARGO_PKG_VERSION"));
                    process::exit(0);
                }
                _ => {
                    eprintln!(
                        "{}: unrecognized option '{}'",
                        TOOL_NAME,
                        arg.to_string_lossy()
                    );
                    eprintln!("Try '{} --help' for more information.", TOOL_NAME);
                    process::exit(1);
                }
            }
        } else if bytes.len() > 1 && bytes[0] == b'-' {
            for &b in &bytes[1..] {
                match b {
                    b'b' => cli.binary = true,
                    b'c' => cli.check = true,
                    b't' => cli.text = true,
                    b'w' => cli.warn = true,
                    b'z' => cli.zero = true,
                    _ => {
                        eprintln!("{}: invalid option -- '{}'", TOOL_NAME, b as char);
                        eprintln!("Try '{} --help' for more information.", TOOL_NAME);
                        process::exit(1);
                    }
                }
            }
        } else {
            cli.files.push(arg.to_string_lossy().into_owned());
        }
    }

    cli
}

/// Check if a filename needs escaping (contains backslash or newline).
#[inline]
fn needs_escape(name: &str) -> bool {
    name.bytes().any(|b| b == b'\\' || b == b'\n')
}

/// Escape a filename: replace `\` with `\\` and newline with `\n` (literal).
fn escape_filename(name: &str) -> String {
    let mut out = String::with_capacity(name.len() + 8);
    for b in name.bytes() {
        match b {
            b'\\' => out.push_str("\\\\"),
            b'\n' => out.push_str("\\n"),
            _ => out.push(b as char),
        }
    }
    out
}

/// Enlarge pipe buffers on Linux for higher throughput.
#[cfg(target_os = "linux")]
fn enlarge_pipes() {
    const PIPE_SIZE: i32 = 8 * 1024 * 1024;
    unsafe {
        libc::fcntl(0, libc::F_SETPIPE_SZ, PIPE_SIZE);
        libc::fcntl(1, libc::F_SETPIPE_SZ, PIPE_SIZE);
    }
}

/// Ultra-fast path for `fmd5sum <single_file>` — raw syscalls, zero allocation.
/// Bypasses: enlarge_pipes (2 syscalls), parse_args, BufWriter, thread-local LINE_BUF.
/// Total overhead: reset_sigpipe + raw open + fstat + read + hash + write + close.
#[cfg(target_os = "linux")]
fn single_file_fast(path: &Path) -> ! {
    // Stack buffer for output: 32 hex chars + "  " + filename + "\n"
    // Max 4096 bytes covers any reasonable filename.
    let mut out_buf = [0u8; 4096];

    match hash::hash_file_raw_to_buf(HashAlgorithm::Md5, path, &mut out_buf) {
        Ok(hex_len) => {
            // Build output line in-place: "<hash>  <filename>\n"
            let filename = path.as_os_str();
            let name_bytes = {
                use std::os::unix::ffi::OsStrExt;
                filename.as_bytes()
            };
            let mut pos = hex_len;
            out_buf[pos] = b' ';
            pos += 1;
            out_buf[pos] = b' '; // text mode (space, not *)
            pos += 1;
            // Check if filename fits in remaining buffer
            if pos + name_bytes.len() < out_buf.len() {
                out_buf[pos..pos + name_bytes.len()].copy_from_slice(name_bytes);
                pos += name_bytes.len();
                out_buf[pos] = b'\n';
                pos += 1;
                // Single write syscall for entire output
                unsafe {
                    libc::write(1, out_buf.as_ptr() as *const libc::c_void, pos as _);
                }
            } else {
                // Filename too long for stack buffer — fallback to heap
                let mut v = Vec::with_capacity(pos + name_bytes.len() + 1);
                v.extend_from_slice(&out_buf[..pos]);
                v.extend_from_slice(name_bytes);
                v.push(b'\n');
                unsafe {
                    libc::write(1, v.as_ptr() as *const libc::c_void, v.len() as _);
                }
            }
            process::exit(0);
        }
        Err(e) => {
            let name = path.to_string_lossy();
            eprintln!("{}: {}: {}", TOOL_NAME, name, io_error_msg(&e));
            process::exit(1);
        }
    }
}

fn main() {
    coreutils_rs::common::reset_sigpipe();

    // Ultra-fast single-file detection: fmd5sum <single_file> (no flags)
    // Check argc == 2 and argv[1] doesn't start with '-'.
    // This fires before parse_args, enlarge_pipes, or BufWriter creation.
    #[cfg(target_os = "linux")]
    {
        let mut args = std::env::args_os();
        let _ = args.next(); // skip argv[0]
        if let Some(arg) = args.next()
            && args.next().is_none()
        {
            // Exactly 1 argument
            let bytes = arg.as_encoded_bytes();
            if !bytes.is_empty() && bytes[0] != b'-' {
                single_file_fast(Path::new(&arg));
            }
        }
    }

    let cli = parse_args();
    let algo = HashAlgorithm::Md5;

    // Validate flag combinations
    if cli.tag && cli.check {
        eprintln!(
            "{}: the --tag option is meaningless when verifying checksums",
            TOOL_NAME
        );
        eprintln!("Try '{} --help' for more information.", TOOL_NAME);
        process::exit(1);
    }

    let files = if cli.files.is_empty() {
        vec!["-".to_string()]
    } else {
        cli.files.clone()
    };

    // Only enlarge pipes when stdin is involved — saves 2 fcntl syscalls (~2µs)
    // for the common case of hashing regular files.
    #[cfg(target_os = "linux")]
    if files.iter().any(|f| f == "-") {
        enlarge_pipes();
    }

    // Raw fd stdout on Unix for zero-overhead writes
    #[cfg(unix)]
    let mut raw = unsafe { ManuallyDrop::new(std::fs::File::from_raw_fd(1)) };
    #[cfg(unix)]
    let mut out = BufWriter::with_capacity(8 * 1024, &mut *raw);
    #[cfg(not(unix))]
    let stdout = io::stdout();
    #[cfg(not(unix))]
    let mut out = BufWriter::with_capacity(8 * 1024, stdout.lock());
    let mut had_error = false;

    if cli.check {
        // Check mode - sequential (reads from check files/stdin)
        let mut total_ok = 0usize;
        let mut total_mismatches = 0usize;
        let mut total_format_errors = 0usize;
        let mut total_read_errors = 0usize;

        for filename in &files {
            let reader: Box<dyn io::BufRead> = if filename == "-" {
                Box::new(BufReader::new(io::stdin().lock()))
            } else {
                match std::fs::File::open(filename) {
                    Ok(f) => Box::new(BufReader::new(f)),
                    Err(e) => {
                        eprintln!("{}: {}: {}", TOOL_NAME, filename, io_error_msg(&e));
                        had_error = true;
                        continue;
                    }
                }
            };
            let mut err_out = io::stderr();
            let display_name = if filename == "-" {
                "standard input".to_string()
            } else {
                filename.clone()
            };
            let opts = hash::CheckOptions {
                quiet: cli.quiet,
                status_only: cli.status,
                strict: cli.strict,
                warn: cli.warn,
                ignore_missing: cli.ignore_missing,
                warn_prefix: format!("{}: {}", TOOL_NAME, display_name),
            };
            match hash::check_file(algo, reader, &opts, &mut out, &mut err_out) {
                Ok(r) => {
                    total_ok += r.ok;
                    total_mismatches += r.mismatches;
                    total_format_errors += r.format_errors;
                    total_read_errors += r.read_errors;
                    if r.mismatches > 0 || r.read_errors > 0 {
                        had_error = true;
                    }
                    if cli.strict && r.format_errors > 0 {
                        had_error = true;
                    }

                    // GNU compat: when --ignore-missing is used and no file was verified
                    // for this checkfile, print warning and set error
                    if cli.ignore_missing && r.ok == 0 && r.mismatches == 0 && r.ignored_missing > 0
                    {
                        if !cli.status {
                            let _ = out.flush();
                            eprintln!("{}: {}: no file was verified", TOOL_NAME, display_name);
                        }
                        had_error = true;
                    }
                }
                Err(e) => {
                    eprintln!("{}: {}: {}", TOOL_NAME, filename, io_error_msg(&e));
                    had_error = true;
                }
            }
        }

        // Flush stdout before printing stderr warnings (ordering matters)
        let _ = out.flush();

        // "no properly formatted checksum lines found" — always set error,
        // even with --status (GNU compat: exit 1 when no valid lines)
        let checked = total_ok + total_mismatches + total_read_errors;
        if checked == 0 && total_format_errors > 0 {
            if !cli.status {
                let name = if files.len() == 1 && files[0] == "-" {
                    "standard input"
                } else {
                    &files[0]
                };
                eprintln!(
                    "{}: {}: no properly formatted MD5 checksum lines found",
                    TOOL_NAME, name
                );
            }
            had_error = true;
        }

        // Print GNU-compatible warning summaries to stderr
        if !cli.status {
            if total_mismatches > 0 {
                let word = if total_mismatches == 1 {
                    "computed checksum did NOT match"
                } else {
                    "computed checksums did NOT match"
                };
                eprintln!("{}: WARNING: {} {}", TOOL_NAME, total_mismatches, word);
            }
            if total_read_errors > 0 {
                let word = if total_read_errors == 1 {
                    "listed file could not be read"
                } else {
                    "listed files could not be read"
                };
                eprintln!("{}: WARNING: {} {}", TOOL_NAME, total_read_errors, word);
            }
            if total_format_errors > 0 {
                let line_word = if total_format_errors == 1 {
                    "line is"
                } else {
                    "lines are"
                };
                eprintln!(
                    "{}: WARNING: {} {} improperly formatted",
                    TOOL_NAME, total_format_errors, line_word
                );
            }
        }
    } else {
        // Hash mode
        let has_stdin = files.iter().any(|f| f == "-");

        if has_stdin || files.len() <= 1 {
            // Sequential for stdin or single file.
            // Uses hash_file (with fstat) for optimal mmap/bulk-read path.
            for filename in &files {
                let hash_result = if filename == "-" {
                    hash::hash_stdin(algo)
                } else {
                    hash::hash_file(algo, Path::new(filename))
                };
                match hash_result {
                    Ok(h) => {
                        let name = if filename == "-" {
                            "-"
                        } else {
                            filename.as_str()
                        };
                        write_output(&mut out, &cli, algo, &h, name);
                    }
                    Err(e) => {
                        let _ = out.flush();
                        eprintln!("{}: {}: {}", TOOL_NAME, filename, io_error_msg(&e));
                        had_error = true;
                    }
                }
            }
        } else {
            // Multi-file (2+): choose strategy based on file count.
            let paths: Vec<_> = files.iter().map(|f| Path::new(f.as_str())).collect();

            let results = hash::hash_files_auto(&paths, algo);

            // Batch output: build all output lines into one buffer, write once.
            // Reduces per-file write() overhead from ~100 syscalls to 1.
            let binary = cli.binary || (!cli.text && cfg!(windows));
            let mut output_buf = Vec::with_capacity(files.len() * 80);
            for (filename, result) in files.iter().zip(results) {
                match result {
                    Ok(h) => {
                        if cli.tag {
                            let term = if cli.zero { b'\0' } else { b'\n' };
                            output_buf.extend_from_slice(algo.name().as_bytes());
                            output_buf.extend_from_slice(b" (");
                            output_buf.extend_from_slice(filename.as_bytes());
                            output_buf.extend_from_slice(b") = ");
                            output_buf.extend_from_slice(h.as_bytes());
                            output_buf.push(term);
                        } else {
                            let mode = if binary { b'*' } else { b' ' };
                            let term = if cli.zero { b'\0' } else { b'\n' };
                            if !cli.zero && needs_escape(filename) {
                                let escaped = escape_filename(filename);
                                output_buf.push(b'\\');
                                output_buf.extend_from_slice(h.as_bytes());
                                output_buf.push(b' ');
                                output_buf.push(mode);
                                output_buf.extend_from_slice(escaped.as_bytes());
                                output_buf.push(term);
                            } else {
                                output_buf.extend_from_slice(h.as_bytes());
                                output_buf.push(b' ');
                                output_buf.push(mode);
                                output_buf.extend_from_slice(filename.as_bytes());
                                output_buf.push(term);
                            }
                        }
                    }
                    Err(e) => {
                        // Bypass BufWriter — output_buf is already a batch buffer.
                        if !output_buf.is_empty() {
                            debug_assert_eq!(
                                out.buffer().len(),
                                0,
                                "BufWriter had buffered data before bypass write"
                            );
                            let _ = out.get_mut().write_all(&output_buf);
                            output_buf.clear();
                        }
                        eprintln!("{}: {}: {}", TOOL_NAME, filename, io_error_msg(&e));
                        had_error = true;
                    }
                }
            }
            if !output_buf.is_empty() {
                // Bypass BufWriter — output_buf is already a batch buffer.
                debug_assert_eq!(
                    out.buffer().len(),
                    0,
                    "BufWriter had buffered data before bypass write"
                );
                let _ = out.get_mut().write_all(&output_buf);
            }
        }
    }

    let _ = out.flush();
    if had_error {
        process::exit(1);
    }
}

/// Write hash output using single-write batched buffer for minimum overhead.
#[inline]
fn write_output(out: &mut impl Write, cli: &Cli, algo: HashAlgorithm, hash: &str, filename: &str) {
    let binary = cli.binary || (!cli.text && cfg!(windows));
    if cli.tag {
        let _ = hash::write_hash_tag_line(out, algo.name(), hash, filename, cli.zero);
    } else if !cli.zero && needs_escape(filename) {
        let escaped = escape_filename(filename);
        let _ = hash::write_hash_line(out, hash, &escaped, binary, cli.zero, true);
    } else {
        let _ = hash::write_hash_line(out, hash, filename, binary, cli.zero, false);
    }
}

#[cfg(test)]
mod tests {
    use std::process::Command;

    fn cmd() -> Command {
        let mut path = std::env::current_exe().unwrap();
        path.pop();
        path.pop();
        path.push("fmd5sum");
        Command::new(path)
    }
    #[cfg(unix)]
    #[test]
    fn test_hash_stdin() {
        use std::io::Write;
        use std::process::Stdio;
        let mut child = cmd()
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .spawn()
            .unwrap();
        child.stdin.take().unwrap().write_all(b"hello\n").unwrap();
        let output = child.wait_with_output().unwrap();
        assert!(output.status.success());
        let stdout = String::from_utf8_lossy(&output.stdout);
        let stdout = stdout.trim();
        assert!(stdout.contains("  -"), "Should contain filename marker");
    }

    #[test]
    fn test_hash_file() {
        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join("test.txt");
        std::fs::write(&file, "hello\n").unwrap();
        let output = cmd().arg(file.to_str().unwrap()).output().unwrap();
        assert!(output.status.success());
        let stdout = String::from_utf8_lossy(&output.stdout);
        assert!(stdout.contains("test.txt"));
    }

    #[test]
    fn test_check_mode() {
        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join("test.txt");
        std::fs::write(&file, "hello\n").unwrap();
        let output = cmd().arg(file.to_str().unwrap()).output().unwrap();
        let checksum_line = String::from_utf8_lossy(&output.stdout);
        let checksums = dir.path().join("checksums.txt");
        std::fs::write(&checksums, checksum_line.as_ref()).unwrap();
        let output = cmd()
            .args(["--check", checksums.to_str().unwrap()])
            .output()
            .unwrap();
        assert!(output.status.success());
        let stdout = String::from_utf8_lossy(&output.stdout);
        assert!(stdout.contains("OK"));
    }

    #[test]
    fn test_known_empty_hash() {
        use std::process::Stdio;
        let mut child = cmd()
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .spawn()
            .unwrap();
        // Write empty input
        drop(child.stdin.take().unwrap());
        let output = child.wait_with_output().unwrap();
        assert!(output.status.success());
        let stdout = String::from_utf8_lossy(&output.stdout);
        assert!(
            stdout.contains("d41d8cd98f00b204e9800998ecf8427e"),
            "MD5 of empty input should be d41d8cd98f00b204e9800998ecf8427e"
        );
    }

    #[test]
    fn test_tag_format() {
        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join("test.txt");
        std::fs::write(&file, "hello\n").unwrap();
        let output = cmd()
            .args(["--tag", file.to_str().unwrap()])
            .output()
            .unwrap();
        assert!(output.status.success());
        let stdout = String::from_utf8_lossy(&output.stdout);
        assert!(stdout.contains("MD5"));
    }

    #[test]
    fn test_known_hello_hash() {
        use std::io::Write;
        use std::process::Stdio;
        let mut child = cmd()
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .spawn()
            .unwrap();
        child.stdin.take().unwrap().write_all(b"hello\n").unwrap();
        let output = child.wait_with_output().unwrap();
        assert!(output.status.success());
        let stdout = String::from_utf8_lossy(&output.stdout);
        // MD5("hello\n") = b1946ac92492d2347c6235b4d2611184
        assert!(stdout.contains("b1946ac92492d2347c6235b4d2611184"));
    }

    #[test]
    fn test_multiple_files() {
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
        assert!(stdout.contains("a.txt"));
        assert!(stdout.contains("b.txt"));
        // Two lines of output
        assert_eq!(stdout.lines().count(), 2);
    }

    #[cfg(unix)]
    #[test]
    fn test_nonexistent_file() {
        let output = cmd().arg("/nonexistent_xyz_md5").output().unwrap();
        assert!(!output.status.success());
        let stderr = String::from_utf8_lossy(&output.stderr);
        assert!(stderr.contains("No such file"));
    }

    #[test]
    fn test_check_tampered() {
        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join("test.txt");
        std::fs::write(&file, "original\n").unwrap();
        let output = cmd().arg(file.to_str().unwrap()).output().unwrap();
        let checksum_line = String::from_utf8_lossy(&output.stdout);
        let checksums = dir.path().join("checksums.txt");
        std::fs::write(&checksums, checksum_line.as_ref()).unwrap();
        // Now tamper with the file
        std::fs::write(&file, "tampered\n").unwrap();
        let output = cmd()
            .args(["--check", checksums.to_str().unwrap()])
            .output()
            .unwrap();
        assert!(!output.status.success());
        let stdout = String::from_utf8_lossy(&output.stdout);
        assert!(stdout.contains("FAILED"));
    }

    #[test]
    fn test_check_missing_file() {
        let dir = tempfile::tempdir().unwrap();
        let checksums = dir.path().join("sums.txt");
        std::fs::write(
            &checksums,
            "d41d8cd98f00b204e9800998ecf8427e  nonexistent_file\n",
        )
        .unwrap();
        let output = cmd()
            .args(["--check", checksums.to_str().unwrap()])
            .output()
            .unwrap();
        assert!(!output.status.success());
    }

    #[test]
    fn test_check_malformed_line() {
        use std::io::Write;
        use std::process::Stdio;
        let mut child = cmd()
            .args(["--check", "--warn"])
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .unwrap();
        child
            .stdin
            .take()
            .unwrap()
            .write_all(b"this is not a valid checksum line\n")
            .unwrap();
        let output = child.wait_with_output().unwrap();
        assert!(!output.status.success());
        let stderr = String::from_utf8_lossy(&output.stderr);
        assert!(
            stderr.contains("improperly formatted") || stderr.contains("no properly formatted")
        );
    }

    #[test]
    fn test_binary_mode_flag() {
        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join("test.txt");
        std::fs::write(&file, "test\n").unwrap();
        let output = cmd().args(["-b", file.to_str().unwrap()]).output().unwrap();
        assert!(output.status.success());
        let stdout = String::from_utf8_lossy(&output.stdout);
        // Binary mode uses * before filename in GNU md5sum
        assert!(
            stdout.contains(" *"),
            "binary mode should use * prefix, got: {}",
            stdout
        );
    }

    #[test]
    fn test_invalid_option() {
        let output = cmd().arg("--invalid-xyz").output().unwrap();
        assert!(!output.status.success());
        let stderr = String::from_utf8_lossy(&output.stderr);
        assert!(stderr.contains("unrecognized option"));
    }

    #[test]
    fn test_tag_and_check_conflict() {
        let output = cmd().args(["--tag", "--check", "-"]).output().unwrap();
        assert!(!output.status.success());
        let stderr = String::from_utf8_lossy(&output.stderr);
        assert!(stderr.contains("tag"));
    }

    #[test]
    fn test_zero_terminated() {
        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join("test.txt");
        std::fs::write(&file, "x").unwrap();
        let output = cmd().args(["-z", file.to_str().unwrap()]).output().unwrap();
        assert!(output.status.success());
        // Output should end with NUL instead of newline
        assert!(output.stdout.ends_with(b"\0"));
        assert!(!output.stdout.ends_with(b"\n"));
    }

    #[test]
    fn test_check_status_flag() {
        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join("test.txt");
        std::fs::write(&file, "hello\n").unwrap();
        let output = cmd().arg(file.to_str().unwrap()).output().unwrap();
        let checksum_line = String::from_utf8_lossy(&output.stdout);
        let checksums = dir.path().join("sums.txt");
        std::fs::write(&checksums, checksum_line.as_ref()).unwrap();
        let output = cmd()
            .args(["--check", "--status", checksums.to_str().unwrap()])
            .output()
            .unwrap();
        assert!(output.status.success());
        // --status: no output on stdout
        assert!(output.stdout.is_empty());
    }

    #[cfg(unix)]
    #[test]
    fn test_dash_as_stdin() {
        use std::io::Write;
        use std::process::Stdio;
        let mut child = cmd()
            .arg("-")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .spawn()
            .unwrap();
        child.stdin.take().unwrap().write_all(b"test\n").unwrap();
        let output = child.wait_with_output().unwrap();
        assert!(output.status.success());
        let stdout = String::from_utf8_lossy(&output.stdout);
        let stdout = stdout.trim();
        assert!(stdout.contains("  -"));
    }
}
