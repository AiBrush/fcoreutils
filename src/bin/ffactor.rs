// ffactor -- print prime factors of each number
//
// Usage: factor [NUMBER]...
//        (reads from stdin if no arguments given)

use std::io::{self, BufWriter, Write};
use std::process;

use coreutils_rs::factor;

const TOOL_NAME: &str = "factor";

fn print_help() {
    print!(
        "Usage: {0} [NUMBER]...\n\
         Print the prime factors of each specified integer.\n\n\
         \x20     --help     display this help and exit\n\
         \x20     --version  output version information and exit\n\n\
         Print the prime factors of each specified integer NUMBER. If none\n\
         are specified on the command line, read them from standard input.\n",
        TOOL_NAME
    );
}

fn print_version() {
    println!("{} (fcoreutils) {}", TOOL_NAME, env!("CARGO_PKG_VERSION"));
}

/// Process a single token: parse as u128, print factors, return true on success.
fn process_number(token: &str, out: &mut impl Write) -> bool {
    match token.parse::<u128>() {
        Ok(n) => {
            let line = factor::format_factors(n);
            if writeln!(out, "{}", line).is_err() {
                // Broken pipe or write error; exit cleanly
                process::exit(0);
            }
            true
        }
        Err(_) => {
            eprintln!(
                "{}: \u{2018}{}\u{2019} is not a valid positive integer",
                TOOL_NAME, token
            );
            false
        }
    }
}

/// Try to mmap stdin if it's a regular file (zero-copy, zero-allocation).
#[cfg(unix)]
fn try_mmap_stdin() -> Option<memmap2::Mmap> {
    use std::os::unix::io::FromRawFd;
    let mut stat: libc::stat = unsafe { std::mem::zeroed() };
    if unsafe { libc::fstat(0, &mut stat) } != 0
        || (stat.st_mode & libc::S_IFMT) != libc::S_IFREG
        || stat.st_size <= 0
    {
        return None;
    }
    let file = unsafe { std::fs::File::from_raw_fd(0) };
    let mmap = unsafe { memmap2::MmapOptions::new().map(&file) }.ok();
    std::mem::forget(file); // don't close stdin fd
    mmap
}

/// Parse and factor a single whitespace-delimited token.
/// Returns true if the token was valid, false on error.
#[inline]
fn factor_token(token: &[u8], out_buf: &mut Vec<u8>, out: &mut BufWriter<io::StdoutLock>) -> bool {
    if token.is_empty() {
        return true;
    }

    // Try u64 fast path first (handles all numbers up to u64::MAX = 20 digits).
    let mut n64: u64 = 0;
    let mut valid_u64 = true;
    let mut overflowed = false;
    for &b in token {
        let d = b.wrapping_sub(b'0');
        if d > 9 {
            valid_u64 = false;
            break;
        }
        n64 = match n64.checked_mul(10) {
            Some(v) => match v.checked_add(d as u64) {
                Some(v) => v,
                None => {
                    overflowed = true;
                    break;
                }
            },
            None => {
                overflowed = true;
                break;
            }
        };
    }
    if valid_u64 && !overflowed {
        factor::write_factors_u64(n64, out_buf);
        flush_if_full(out_buf, out);
        return true;
    }

    // u128 path for numbers > u64::MAX
    if overflowed {
        let mut n: u128 = 0;
        let mut valid_u128 = true;
        for &b in token {
            let d = b.wrapping_sub(b'0');
            if d > 9 {
                valid_u128 = false;
                break;
            }
            n = match n.checked_mul(10) {
                Some(v) => match v.checked_add(d as u128) {
                    Some(v) => v,
                    None => {
                        valid_u128 = false;
                        break;
                    }
                },
                None => {
                    valid_u128 = false;
                    break;
                }
            };
        }
        if valid_u128 {
            factor::write_factors(n, out_buf);
            flush_if_full(out_buf, out);
            return true;
        }
    }

    // Invalid token — flush buffered output, then print error
    if !out_buf.is_empty() {
        let _ = out.write_all(out_buf);
        out_buf.clear();
    }
    let _ = out.flush();
    let token_str = String::from_utf8_lossy(token);
    eprintln!(
        "{}: \u{2018}{}\u{2019} is not a valid positive integer",
        TOOL_NAME, token_str
    );
    false
}

/// Flush output buffer if it exceeds 128KB.
#[inline]
fn flush_if_full(out_buf: &mut Vec<u8>, out: &mut BufWriter<io::StdoutLock>) {
    if out_buf.len() >= 128 * 1024 {
        if out.write_all(out_buf).is_err() {
            process::exit(0);
        }
        out_buf.clear();
    }
}

/// Process byte buffer of whitespace-delimited numbers.
fn process_bytes(input: &[u8], out: &mut BufWriter<io::StdoutLock>) -> bool {
    let mut had_error = false;
    let mut out_buf = Vec::with_capacity(256 * 1024);
    let mut pos = 0;
    let len = input.len();

    while pos < len {
        // Skip whitespace
        while pos < len
            && (input[pos] == b' '
                || input[pos] == b'\n'
                || input[pos] == b'\r'
                || input[pos] == b'\t')
        {
            pos += 1;
        }
        if pos >= len {
            break;
        }

        // Scan token
        let start = pos;
        while pos < len
            && input[pos] != b' '
            && input[pos] != b'\n'
            && input[pos] != b'\r'
            && input[pos] != b'\t'
        {
            pos += 1;
        }

        if !factor_token(&input[start..pos], &mut out_buf, out) {
            had_error = true;
        }
    }

    if !out_buf.is_empty() && out.write_all(&out_buf).is_err() {
        process::exit(0);
    }

    had_error
}

/// Process numbers from stdin using raw byte scanning for maximum throughput.
/// Uses mmap for file redirections (zero-copy), streaming chunks for pipes.
fn process_stdin(out: &mut BufWriter<io::StdoutLock>) -> bool {
    // Try mmap for file redirections (zero-copy, zero-allocation input)
    #[cfg(unix)]
    {
        if let Some(mmap) = try_mmap_stdin() {
            return process_bytes(&mmap, out);
        }
    }

    // Pipe: stream-process in chunks so cat and factor overlap.
    // read_to_end would block until all input arrives, preventing overlap.
    use std::io::Read;
    let stdin = io::stdin();
    let mut reader = stdin.lock();
    let mut buf = vec![0u8; 256 * 1024];
    let mut leftover = 0usize; // bytes carried over from previous chunk
    let mut had_error = false;
    let mut out_buf = Vec::with_capacity(256 * 1024);

    loop {
        let n = match reader.read(&mut buf[leftover..]) {
            Ok(0) => {
                // EOF: process any remaining leftover bytes
                if leftover > 0 && process_tokens(&buf[..leftover], &mut out_buf, out) {
                    had_error = true;
                }
                break;
            }
            Ok(n) => n,
            Err(ref e) if e.kind() == io::ErrorKind::Interrupted => continue,
            Err(e) => {
                eprintln!("{}: read error: {}", TOOL_NAME, e);
                return true;
            }
        };

        let total = leftover + n;
        // Find last newline boundary to avoid splitting a number
        let boundary = match memchr::memrchr(b'\n', &buf[..total]) {
            Some(pos) => pos + 1,
            None => {
                // No newline in buffer — carry everything forward
                leftover = total;
                if leftover >= buf.len() {
                    // Buffer full with no newline (very long line).
                    // Find last whitespace to avoid splitting a token.
                    let split = buf[..leftover]
                        .iter()
                        .rposition(|&b| b == b' ' || b == b'\t' || b == b'\r')
                        .map(|p| p + 1)
                        .unwrap_or(leftover); // no whitespace at all: process entire buffer
                    if process_tokens(&buf[..split], &mut out_buf, out) {
                        had_error = true;
                    }
                    let remaining = leftover - split;
                    if remaining > 0 {
                        buf.copy_within(split..leftover, 0);
                    }
                    leftover = remaining;
                }
                continue;
            }
        };

        // Process complete lines
        if process_tokens(&buf[..boundary], &mut out_buf, out) {
            had_error = true;
        }

        // Move leftover (incomplete line) to start of buffer
        let remaining = total - boundary;
        if remaining > 0 {
            buf.copy_within(boundary..total, 0);
        }
        leftover = remaining;
    }

    if !out_buf.is_empty() && out.write_all(&out_buf).is_err() {
        process::exit(0);
    }

    had_error
}

/// Process a chunk of bytes containing whitespace-delimited numbers.
/// Returns true if any error occurred.
fn process_tokens(
    input: &[u8],
    out_buf: &mut Vec<u8>,
    out: &mut BufWriter<io::StdoutLock>,
) -> bool {
    let mut had_error = false;
    let mut pos = 0;
    let len = input.len();

    while pos < len {
        // Skip whitespace
        while pos < len
            && (input[pos] == b' '
                || input[pos] == b'\n'
                || input[pos] == b'\r'
                || input[pos] == b'\t')
        {
            pos += 1;
        }
        if pos >= len {
            break;
        }

        // Scan token
        let start = pos;
        while pos < len
            && input[pos] != b' '
            && input[pos] != b'\n'
            && input[pos] != b'\r'
            && input[pos] != b'\t'
        {
            pos += 1;
        }

        if !factor_token(&input[start..pos], out_buf, out) {
            had_error = true;
        }
    }

    had_error
}

fn main() {
    coreutils_rs::common::reset_sigpipe();

    let args: Vec<String> = std::env::args().skip(1).collect();

    // Parse options (only --help and --version)
    let mut numbers: Vec<String> = Vec::new();
    let mut saw_dashdash = false;

    for arg in &args {
        if saw_dashdash {
            numbers.push(arg.clone());
            continue;
        }
        match arg.as_str() {
            "--" => {
                saw_dashdash = true;
            }
            "--help" => {
                print_help();
                process::exit(0);
            }
            "--version" => {
                print_version();
                process::exit(0);
            }
            _ => {
                if arg.starts_with("--") {
                    eprintln!("{}: unrecognized option \u{2018}{}\u{2019}", TOOL_NAME, arg);
                    process::exit(1);
                }
                numbers.push(arg.clone());
            }
        }
    }

    let stdout = io::stdout();
    let mut out = BufWriter::with_capacity(256 * 1024, stdout.lock());
    let mut had_error = false;

    if numbers.is_empty() {
        had_error = process_stdin(&mut out);
    } else {
        for num_str in &numbers {
            if !process_number(num_str, &mut out) {
                had_error = true;
            }
        }
    }

    if out.flush().is_err() {
        process::exit(0);
    }

    if had_error {
        process::exit(1);
    }
}
