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
        "Usage: {0} [OPTION] [NUMBER]...\n\
         Print the prime factors of each specified integer.\n\n\
         \x20 -h, --exponents   print repeated factors in p^e notation\n\
         \x20     --help         display this help and exit\n\
         \x20     --version      output version information and exit\n\n\
         Print the prime factors of each specified integer NUMBER. If none\n\
         are specified on the command line, read them from standard input.\n",
        TOOL_NAME
    );
}

fn print_version() {
    println!("{} (fcoreutils) {}", TOOL_NAME, env!("CARGO_PKG_VERSION"));
}

/// Process a single CLI argument: parse as u128, print factors.
/// Returns true on error (matching all other functions in this file).
fn process_number(token: &str, exponents: bool, out: &mut impl Write) -> bool {
    // Strip leading '+' (GNU compat)
    let clean = token.strip_prefix('+').unwrap_or(token);
    match clean.parse::<u128>() {
        Ok(n) => {
            if exponents {
                let line = format_factors_exp(n);
                if writeln!(out, "{}", line).is_err() {
                    process::exit(0);
                }
            } else {
                let line = factor::format_factors(n);
                if writeln!(out, "{}", line).is_err() {
                    process::exit(0);
                }
            }
            false
        }
        Err(_) => {
            // Try big number path for numbers > u128::MAX
            if clean.bytes().all(|b| b.is_ascii_digit()) && !clean.is_empty() {
                return process_big_number(clean, exponents, out);
            }
            eprintln!(
                "{}: \u{2018}{}\u{2019} is not a valid positive integer",
                TOOL_NAME, token
            );
            true
        }
    }
}

/// Format factors with exponent notation: "3000: 2^3 3 5^3"
fn format_factors_exp(n: u128) -> String {
    let factors = factor::factorize(n);
    let mut result = format!("{}:", n);
    let mut i = 0;
    while i < factors.len() {
        let p = factors[i];
        let mut count = 1;
        while i + count < factors.len() && factors[i + count] == p {
            count += 1;
        }
        result.push(' ');
        result.push_str(&p.to_string());
        if count > 1 {
            result.push('^');
            result.push_str(&count.to_string());
        }
        i += count;
    }
    result
}

/// Factorize a number larger than u128::MAX using decimal string division.
fn process_big_number(s: &str, exponents: bool, out: &mut impl Write) -> bool {
    let mut digits: Vec<u8> = s.bytes().map(|b| b - b'0').collect();
    // Remove leading zeros
    while digits.len() > 1 && digits[0] == 0 {
        digits.remove(0);
    }
    let mut factors: Vec<String> = Vec::new();

    // Trial division by small primes
    let small_primes: &[u64] = &[
        2, 3, 5, 7, 11, 13, 17, 19, 23, 29, 31, 37, 41, 43, 47, 53, 59, 61, 67, 71, 73, 79, 83, 89,
        97, 101, 103, 107, 109, 113, 127, 131, 137, 139, 149, 151, 157, 163, 167, 173, 179, 181,
        191, 193, 197, 199, 211, 223, 227, 229, 233, 239, 241, 251, 257, 263, 269, 271, 277, 281,
        283, 293, 307, 311, 313, 317, 331, 337, 347, 349, 353, 359, 367, 373, 379, 383, 389, 397,
        401, 409, 419, 421, 431, 433, 439, 443, 449, 457, 461, 463, 467, 479, 487, 491, 499, 503,
        509, 521, 523, 541, 547, 557, 563, 569, 571, 577, 587, 593, 599, 601, 607, 613, 617, 619,
        631, 641, 643, 647, 653, 659, 661, 673, 677, 683, 691, 701, 709, 719, 727, 733, 739, 743,
        751, 757, 761, 769, 773, 787, 797, 809, 811, 821, 823, 827, 829, 839, 853, 857, 859, 863,
        877, 881, 883, 887, 907, 911, 919, 929, 937, 941, 947, 953, 967, 971, 977, 983, 991, 997,
    ];

    for &p in small_primes {
        loop {
            let rem = big_mod(&digits, p);
            if rem != 0 {
                break;
            }
            digits = big_div(&digits, p);
            factors.push(p.to_string());
        }
        // If quotient fits in u128, switch to fast path
        if let Some(n) = big_to_u128(&digits) {
            if n <= 1 {
                break;
            }
            let remaining = factor::factorize(n);
            for f in remaining {
                factors.push(f.to_string());
            }
            digits = vec![0]; // signal done
            break;
        }
    }

    // If still have a remainder > 1 and > u128, it's a large prime factor
    if let Some(n) = big_to_u128(&digits) {
        if n > 1 {
            let remaining = factor::factorize(n);
            for f in remaining {
                factors.push(f.to_string());
            }
        }
    } else {
        // Number is still > u128::MAX after trial division — emit as single factor.
        // Limitation: this may be composite if all prime factors > 997. A full
        // implementation would use Pollard's rho + Miller-Rabin (as GNU factor does).
        let s = digits
            .iter()
            .map(|d| (d + b'0') as char)
            .collect::<String>();
        factors.push(s);
    }

    // Format output
    let mut line = format!("{}:", s);
    if exponents {
        let mut i = 0;
        while i < factors.len() {
            let p = &factors[i];
            let mut count = 1;
            while i + count < factors.len() && factors[i + count] == *p {
                count += 1;
            }
            line.push(' ');
            line.push_str(p);
            if count > 1 {
                line.push('^');
                line.push_str(&count.to_string());
            }
            i += count;
        }
    } else {
        for f in &factors {
            line.push(' ');
            line.push_str(f);
        }
    }

    if writeln!(out, "{}", line).is_err() {
        process::exit(0);
    }
    false
}

/// Compute big_number % small_divisor using long division on decimal digits.
fn big_mod(digits: &[u8], d: u64) -> u64 {
    let mut rem: u64 = 0;
    for &dig in digits {
        rem = (rem * 10 + dig as u64) % d;
    }
    rem
}

/// Compute big_number / small_divisor using long division on decimal digits.
fn big_div(digits: &[u8], d: u64) -> Vec<u8> {
    let mut result = Vec::with_capacity(digits.len());
    let mut rem: u64 = 0;
    for &dig in digits {
        rem = rem * 10 + dig as u64;
        result.push((rem / d) as u8);
        rem %= d;
    }
    // Remove leading zeros
    while result.len() > 1 && result[0] == 0 {
        result.remove(0);
    }
    result
}

/// Try to convert big decimal digits to u128.
fn big_to_u128(digits: &[u8]) -> Option<u128> {
    let mut n: u128 = 0;
    for &d in digits {
        n = n.checked_mul(10)?.checked_add(d as u128)?;
    }
    Some(n)
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
/// Returns true on error (matching the convention of all other functions in this file).
#[inline]
fn factor_token(
    token: &[u8],
    exponents: bool,
    out_buf: &mut Vec<u8>,
    out: &mut BufWriter<io::StdoutLock>,
) -> bool {
    if token.is_empty() {
        return false;
    }

    // Strip leading '+' (GNU compat)
    let token = if !token.is_empty() && token[0] == b'+' {
        &token[1..]
    } else {
        token
    };
    if token.is_empty() {
        return report_invalid(b"+", out_buf, out);
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
        if exponents {
            write_factors_u64_exp(n64, out_buf);
        } else {
            factor::write_factors_u64(n64, out_buf);
        }
        flush_if_full(out_buf, out);
        return false;
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
            if exponents {
                write_factors_exp(n, out_buf);
            } else {
                factor::write_factors(n, out_buf);
            }
            flush_if_full(out_buf, out);
            return false;
        }

        // Number overflows u128 — try big number path if all digits
        if token.iter().all(|&b| b.is_ascii_digit()) {
            if !out_buf.is_empty() {
                let _ = out.write_all(out_buf);
                out_buf.clear();
            }
            let _ = out.flush();
            let token_str = std::str::from_utf8(token).unwrap_or("");
            return process_big_number(token_str, exponents, out);
        }
    }

    report_invalid(token, out_buf, out)
}

fn report_invalid(
    token: &[u8],
    out_buf: &mut Vec<u8>,
    out: &mut BufWriter<io::StdoutLock>,
) -> bool {
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
    true
}

/// Write u64 factors in exponent notation.
fn write_factors_u64_exp(n: u64, out: &mut Vec<u8>) {
    let mut buf = itoa::Buffer::new();
    out.extend_from_slice(buf.format(n).as_bytes());
    out.push(b':');
    if n <= 1 {
        out.push(b'\n');
        return;
    }
    let factors = factor::factorize(n as u128);
    write_exp_factors(&factors, out);
    out.push(b'\n');
}

/// Write u128 factors in exponent notation.
fn write_factors_exp(n: u128, out: &mut Vec<u8>) {
    use std::fmt::Write;
    if n <= u64::MAX as u128 {
        write_factors_u64_exp(n as u64, out);
        return;
    }
    let mut s = String::new();
    let _ = write!(s, "{}", n);
    out.extend_from_slice(s.as_bytes());
    out.push(b':');
    let factors = factor::factorize(n);
    write_exp_factors(&factors, out);
    out.push(b'\n');
}

/// Write factors in p^e notation to buffer.
fn write_exp_factors(factors: &[u128], out: &mut Vec<u8>) {
    let mut buf = itoa::Buffer::new();
    let mut i = 0;
    while i < factors.len() {
        let p = factors[i];
        let mut count = 1u32;
        while i + count as usize <= factors.len().saturating_sub(1)
            && factors[i + count as usize] == p
        {
            count += 1;
        }
        out.push(b' ');
        if p <= u64::MAX as u128 {
            out.extend_from_slice(buf.format(p as u64).as_bytes());
        } else {
            use std::fmt::Write;
            let mut s = String::new();
            let _ = write!(s, "{}", p);
            out.extend_from_slice(s.as_bytes());
        }
        if count > 1 {
            out.push(b'^');
            out.extend_from_slice(buf.format(count).as_bytes());
        }
        i += count as usize;
    }
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

/// Process byte buffer of whitespace-delimited numbers (used by mmap path).
fn process_bytes(input: &[u8], exponents: bool, out: &mut BufWriter<io::StdoutLock>) -> bool {
    let mut out_buf = Vec::with_capacity(128 * 1024);
    let had_error = process_tokens(input, exponents, &mut out_buf, out);
    if !out_buf.is_empty() && out.write_all(&out_buf).is_err() {
        process::exit(0);
    }
    had_error
}

/// Process numbers from stdin using raw byte scanning for maximum throughput.
/// Uses mmap for file redirections (zero-copy), streaming chunks for pipes.
fn process_stdin(exponents: bool, out: &mut BufWriter<io::StdoutLock>) -> bool {
    // Try mmap for file redirections (zero-copy, zero-allocation input)
    #[cfg(unix)]
    {
        if let Some(mmap) = try_mmap_stdin() {
            return process_bytes(&mmap, exponents, out);
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
    let mut out_buf = Vec::with_capacity(128 * 1024);

    loop {
        let n = match reader.read(&mut buf[leftover..]) {
            Ok(0) => {
                // EOF: process any remaining leftover bytes
                if leftover > 0 && process_tokens(&buf[..leftover], exponents, &mut out_buf, out) {
                    had_error = true;
                }
                break;
            }
            Ok(n) => n,
            Err(ref e) if e.kind() == io::ErrorKind::Interrupted => continue,
            Err(e) => {
                // Flush any buffered output before reporting the error
                if !out_buf.is_empty() {
                    let _ = out.write_all(&out_buf);
                }
                let _ = out.flush();
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
                        .unwrap_or(leftover); // no whitespace: process entire buffer (single huge token)
                    if process_tokens(&buf[..split], exponents, &mut out_buf, out) {
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
        if process_tokens(&buf[..boundary], exponents, &mut out_buf, out) {
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
    exponents: bool,
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

        if factor_token(&input[start..pos], exponents, out_buf, out) {
            had_error = true;
        }
    }

    had_error
}

fn main() {
    coreutils_rs::common::reset_sigpipe();

    let args: Vec<String> = std::env::args().skip(1).collect();

    let mut numbers: Vec<String> = Vec::new();
    let mut saw_dashdash = false;
    let mut exponents = false;

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
            "-h" | "--exponents" => {
                exponents = true;
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
        had_error = process_stdin(exponents, &mut out);
    } else {
        for num_str in &numbers {
            if process_number(num_str, exponents, &mut out) {
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

#[cfg(test)]
mod tests {
    use std::process::Command;

    fn cmd() -> Command {
        let mut path = std::env::current_exe().unwrap();
        path.pop();
        path.pop();
        path.push("ffactor");
        Command::new(path)
    }

    #[test]
    fn test_factor_help() {
        let output = cmd().arg("--help").output().unwrap();
        assert!(output.status.success());
        assert!(String::from_utf8_lossy(&output.stdout).contains("Usage"));
    }

    #[test]
    fn test_factor_version() {
        let output = cmd().arg("--version").output().unwrap();
        assert!(output.status.success());
        assert!(String::from_utf8_lossy(&output.stdout).contains("fcoreutils"));
    }

    #[test]
    fn test_factor_one() {
        let output = cmd().arg("1").output().unwrap();
        assert!(output.status.success());
        let stdout = String::from_utf8_lossy(&output.stdout);
        assert_eq!(stdout.trim(), "1:");
    }

    #[test]
    fn test_factor_prime() {
        let output = cmd().arg("7").output().unwrap();
        assert!(output.status.success());
        let stdout = String::from_utf8_lossy(&output.stdout);
        assert_eq!(stdout.trim(), "7: 7");
    }

    #[test]
    fn test_factor_composite() {
        let output = cmd().arg("12").output().unwrap();
        assert!(output.status.success());
        let stdout = String::from_utf8_lossy(&output.stdout);
        assert_eq!(stdout.trim(), "12: 2 2 3");
    }

    #[test]
    fn test_factor_large_prime() {
        let output = cmd().arg("999999937").output().unwrap();
        assert!(output.status.success());
        let stdout = String::from_utf8_lossy(&output.stdout);
        assert_eq!(stdout.trim(), "999999937: 999999937");
    }

    #[test]
    fn test_factor_perfect_square() {
        let output = cmd().arg("144").output().unwrap();
        assert!(output.status.success());
        let stdout = String::from_utf8_lossy(&output.stdout);
        assert_eq!(stdout.trim(), "144: 2 2 2 2 3 3");
    }

    #[test]
    fn test_factor_power_of_two() {
        let output = cmd().arg("1024").output().unwrap();
        assert!(output.status.success());
        let stdout = String::from_utf8_lossy(&output.stdout);
        assert_eq!(stdout.trim(), "1024: 2 2 2 2 2 2 2 2 2 2");
    }

    #[test]
    fn test_factor_multiple_args() {
        let output = cmd().args(["6", "15", "28"]).output().unwrap();
        assert!(output.status.success());
        let stdout = String::from_utf8_lossy(&output.stdout);
        let lines: Vec<&str> = stdout.lines().collect();
        assert_eq!(lines.len(), 3);
        assert_eq!(lines[0], "6: 2 3");
        assert_eq!(lines[1], "15: 3 5");
        assert_eq!(lines[2], "28: 2 2 7");
    }

    #[test]
    fn test_factor_stdin() {
        use std::io::Write;
        use std::process::Stdio;
        let mut child = cmd()
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .spawn()
            .unwrap();
        child.stdin.take().unwrap().write_all(b"42\n").unwrap();
        let output = child.wait_with_output().unwrap();
        assert!(output.status.success());
        let stdout = String::from_utf8_lossy(&output.stdout);
        assert_eq!(stdout.trim(), "42: 2 3 7");
    }

    #[test]
    fn test_factor_zero() {
        let output = cmd().arg("0").output().unwrap();
        // GNU factor prints "0:" for 0
        let stdout = String::from_utf8_lossy(&output.stdout);
        assert!(stdout.contains("0:"));
    }

    #[test]
    fn test_factor_two() {
        let output = cmd().arg("2").output().unwrap();
        assert!(output.status.success());
        let stdout = String::from_utf8_lossy(&output.stdout);
        assert_eq!(stdout.trim(), "2: 2");
    }

    #[test]
    fn test_factor_invalid_input() {
        let output = cmd().arg("abc").output().unwrap();
        assert!(!output.status.success());
    }

    #[test]
    fn test_factor_large_number() {
        // 2^31 - 1 = Mersenne prime
        let output = cmd().arg("2147483647").output().unwrap();
        assert!(output.status.success());
        let stdout = String::from_utf8_lossy(&output.stdout);
        assert_eq!(stdout.trim(), "2147483647: 2147483647");
    }
}
