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

        let token = &input[start..pos];

        // Fast inline parse: all digits → number
        let mut valid = !token.is_empty();
        if valid && token.len() <= 19 {
            // u64 fast path: parse directly to u64, call write_factors_u64
            let mut n64: u64 = 0;
            for &b in token {
                let d = b.wrapping_sub(b'0');
                if d > 9 {
                    valid = false;
                    break;
                }
                n64 = match n64.checked_mul(10) {
                    Some(v) => match v.checked_add(d as u64) {
                        Some(v) => v,
                        None => {
                            valid = false;
                            break;
                        }
                    },
                    None => {
                        valid = false;
                        break;
                    }
                };
            }
            if valid {
                factor::write_factors_u64(n64, &mut out_buf);
                if out_buf.len() >= 128 * 1024 {
                    if out.write_all(&out_buf).is_err() {
                        process::exit(0);
                    }
                    out_buf.clear();
                }
                continue;
            }
        } else if valid {
            // u128 path for 20+ digit numbers
            let mut n: u128 = 0;
            for &b in token {
                let d = b.wrapping_sub(b'0');
                if d > 9 {
                    valid = false;
                    break;
                }
                n = match n.checked_mul(10) {
                    Some(v) => match v.checked_add(d as u128) {
                        Some(v) => v,
                        None => {
                            valid = false;
                            break;
                        }
                    },
                    None => {
                        valid = false;
                        break;
                    }
                };
            }
            if valid {
                factor::write_factors(n, &mut out_buf);
                if out_buf.len() >= 128 * 1024 {
                    if out.write_all(&out_buf).is_err() {
                        process::exit(0);
                    }
                    out_buf.clear();
                }
                continue;
            }
        }

        // Invalid token
        if !out_buf.is_empty() {
            let _ = out.write_all(&out_buf);
            out_buf.clear();
        }
        let _ = out.flush();
        let token_str = String::from_utf8_lossy(token);
        eprintln!(
            "{}: \u{2018}{}\u{2019} is not a valid positive integer",
            TOOL_NAME, token_str
        );
        had_error = true;
    }

    if !out_buf.is_empty() && out.write_all(&out_buf).is_err() {
        process::exit(0);
    }

    had_error
}

/// Process numbers from stdin using raw byte scanning for maximum throughput.
/// Uses mmap for file redirections (zero-copy), read_to_end for pipes.
fn process_stdin(out: &mut BufWriter<io::StdoutLock>) -> bool {
    // Try mmap for file redirections (zero-copy, zero-allocation input)
    #[cfg(unix)]
    {
        if let Some(mmap) = try_mmap_stdin() {
            return process_bytes(&mmap, out);
        }
    }

    // Pipe fallback: read all stdin into memory
    use std::io::Read;
    let stdin = io::stdin();
    let mut input = Vec::new();
    if let Err(e) = stdin.lock().read_to_end(&mut input) {
        eprintln!("{}: read error: {}", TOOL_NAME, e);
        return true;
    }
    process_bytes(&input, out)
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
