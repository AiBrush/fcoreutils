// fseq -- print a sequence of numbers
//
// Usage: seq [OPTION]... LAST
//        seq [OPTION]... FIRST LAST
//        seq [OPTION]... FIRST INCREMENT LAST

use std::process;

/// Write buffer directly to fd 1, bypassing BufWriter overhead.
/// Returns false on unrecoverable error (caller should stop generating output).
fn write_all_fd1(buf: &[u8]) -> bool {
    let mut pos = 0;
    while pos < buf.len() {
        let ret = unsafe {
            libc::write(
                1,
                buf[pos..].as_ptr() as *const libc::c_void,
                (buf.len() - pos) as _,
            )
        };
        if ret > 0 {
            pos += ret as usize;
        } else if ret < 0 {
            let err = std::io::Error::last_os_error();
            if err.kind() == std::io::ErrorKind::Interrupted {
                continue;
            }
            return false;
        } else {
            return false;
        }
    }
    true
}

const TOOL_NAME: &str = "seq";
const VERSION: &str = env!("CARGO_PKG_VERSION");

fn print_help() {
    println!("Usage: {} [OPTION]... LAST", TOOL_NAME);
    println!("  or:  {} [OPTION]... FIRST LAST", TOOL_NAME);
    println!("  or:  {} [OPTION]... FIRST INCREMENT LAST", TOOL_NAME);
    println!("Print numbers from FIRST to LAST, in steps of INCREMENT.");
    println!();
    println!("Mandatory arguments to long options are mandatory for short options too.");
    println!("  -f, --format=FORMAT      use printf style floating-point FORMAT");
    println!("  -s, --separator=STRING   use STRING to separate numbers (default: \\n)");
    println!("  -w, --equal-width        equalize width by padding with leading zeroes");
    println!("      --help     display this help and exit");
    println!("      --version  output version information and exit");
    println!();
    println!("If FIRST or INCREMENT is omitted, it defaults to 1.");
    println!("An omitted INCREMENT defaults to 1 even when LAST is smaller than FIRST.");
    println!("The sequence of numbers ends when the sum of the current number and");
    println!("INCREMENT would become greater than LAST.");
    println!("FIRST, INCREMENT, and LAST are interpreted as floating point values.");
    println!("FORMAT must be suitable for printing one argument of type 'double';");
    println!("it defaults to %.PRECf if FIRST, INCREMENT, and LAST are all fixed point");
    println!("decimal numbers with maximum precision PREC, and to %g otherwise.");
}

fn print_version() {
    println!("{} (fcoreutils) {}", TOOL_NAME, VERSION);
}

/// Count the number of decimal places in a number string.
fn decimal_places(s: &str) -> usize {
    // Strip leading minus
    let s = s.strip_prefix('-').unwrap_or(s);
    if let Some(pos) = s.find('.') {
        let frac = &s[pos + 1..];
        // Trim trailing zeros for precision determination
        let trimmed = frac.trim_end_matches('0');
        if trimmed.is_empty() { 0 } else { trimmed.len() }
    } else {
        0
    }
}

/// Count total width needed for equal-width formatting.
fn number_width(s: &str) -> usize {
    s.len()
}

/// Determine if a string represents a pure integer.
fn is_integer_str(s: &str) -> bool {
    let s = s.strip_prefix('-').unwrap_or(s);
    if s.is_empty() {
        return false;
    }
    s.chars().all(|c| c.is_ascii_digit())
}

/// Format a number according to printf-style format string.
/// Supports %e, %f, %g with optional width and precision.
fn format_number(fmt: &str, value: f64) -> String {
    // Parse the format string: %[flags][width][.precision]type
    let bytes = fmt.as_bytes();
    let mut i = 0;

    // Find the % sign
    while i < bytes.len() && bytes[i] != b'%' {
        i += 1;
    }
    let prefix = &fmt[..i];
    if i >= bytes.len() {
        return fmt.to_string();
    }
    i += 1; // skip %

    // Handle %%
    if i < bytes.len() && bytes[i] == b'%' {
        return format!("{prefix}%{}", format_number(&fmt[i + 1..], value));
    }

    // Parse flags
    let mut zero_pad = false;
    let mut left_align = false;
    let mut plus_sign = false;
    let mut space_sign = false;
    while i < bytes.len() {
        match bytes[i] {
            b'0' => zero_pad = true,
            b'-' => left_align = true,
            b'+' => plus_sign = true,
            b' ' => space_sign = true,
            b'#' => {} // we ignore # for now
            _ => break,
        }
        i += 1;
    }

    // Parse width
    let mut width: usize = 0;
    while i < bytes.len() && bytes[i].is_ascii_digit() {
        width = width
            .saturating_mul(10)
            .saturating_add((bytes[i] - b'0') as usize);
        i += 1;
    }

    // Parse precision
    let mut precision: Option<usize> = None;
    if i < bytes.len() && bytes[i] == b'.' {
        i += 1;
        let mut prec: usize = 0;
        while i < bytes.len() && bytes[i].is_ascii_digit() {
            prec = prec
                .saturating_mul(10)
                .saturating_add((bytes[i] - b'0') as usize);
            i += 1;
        }
        precision = Some(prec);
    }

    // Parse type
    if i >= bytes.len() {
        return fmt.to_string();
    }
    let conv_type = bytes[i] as char;
    i += 1;
    let suffix = &fmt[i..];

    let formatted = match conv_type {
        'f' => {
            let prec = precision.unwrap_or(6);
            format!("{:.prec$}", value, prec = prec)
        }
        'e' => {
            let prec = precision.unwrap_or(6);
            format_scientific(value, prec, 'e')
        }
        'E' => {
            let prec = precision.unwrap_or(6);
            format_scientific(value, prec, 'E')
        }
        'g' => {
            let prec = precision.unwrap_or(6);
            format_g(value, prec, false)
        }
        'G' => {
            let prec = precision.unwrap_or(6);
            format_g(value, prec, true)
        }
        _ => {
            // Unknown format, just print the number
            format!("{}", value)
        }
    };

    // Apply width and padding
    let sign_prefix = if value < 0.0 {
        // The number already contains the minus sign
        ""
    } else if plus_sign {
        "+"
    } else if space_sign {
        " "
    } else {
        ""
    };

    // We need to handle the sign separately for zero-padding
    let num_str = if !sign_prefix.is_empty() && !formatted.starts_with('-') {
        format!("{sign_prefix}{formatted}")
    } else {
        formatted
    };

    let padded = if width > 0 && num_str.len() < width {
        let pad_len = width - num_str.len();
        if left_align {
            format!("{num_str}{}", " ".repeat(pad_len))
        } else if zero_pad && !left_align {
            // Zero-pad: put zeros after sign
            if num_str.starts_with('-') || num_str.starts_with('+') || num_str.starts_with(' ') {
                let (sign, rest) = num_str.split_at(1);
                format!("{sign}{}{rest}", "0".repeat(pad_len))
            } else {
                format!("{}{num_str}", "0".repeat(pad_len))
            }
        } else {
            format!("{}{num_str}", " ".repeat(pad_len))
        }
    } else {
        num_str
    };

    format!("{prefix}{padded}{suffix}")
}

/// Format in scientific notation matching C's %e.
fn format_scientific(value: f64, prec: usize, e_char: char) -> String {
    if value == 0.0 {
        let sign = if value.is_sign_negative() { "-" } else { "" };
        if prec == 0 {
            return format!("{sign}0{e_char}+00");
        }
        return format!("{sign}0.{:0>prec$}{e_char}+00", "", prec = prec);
    }

    let abs = value.abs();
    let sign = if value < 0.0 { "-" } else { "" };
    let exp = abs.log10().floor() as i32;
    let mantissa = abs / 10f64.powi(exp);

    // Round the mantissa to the specified precision
    let factor = 10f64.powi(prec as i32);
    let mantissa = (mantissa * factor).round() / factor;

    // Handle mantissa rounding up to 10
    let (mantissa, exp) = if mantissa >= 10.0 {
        (mantissa / 10.0, exp + 1)
    } else {
        (mantissa, exp)
    };

    let exp_sign = if exp >= 0 { '+' } else { '-' };
    let exp_abs = exp.unsigned_abs();

    if prec == 0 {
        format!("{sign}{mantissa:.0}{e_char}{exp_sign}{exp_abs:02}")
    } else {
        format!(
            "{sign}{mantissa:.prec$}{e_char}{exp_sign}{exp_abs:02}",
            prec = prec
        )
    }
}

/// Format using %g - shortest representation.
fn format_g(value: f64, prec: usize, upper: bool) -> String {
    let prec = if prec == 0 { 1 } else { prec };

    if value == 0.0 {
        let sign = if value.is_sign_negative() { "-" } else { "" };
        return format!("{sign}0");
    }

    let abs = value.abs();
    let exp = abs.log10().floor() as i32;

    let e_char = if upper { 'E' } else { 'e' };

    if exp < -4 || exp >= prec as i32 {
        // Use scientific notation
        let sig_prec = prec.saturating_sub(1);
        let s = format_scientific(value, sig_prec, e_char);
        trim_g_trailing_zeros(&s)
    } else {
        // Use fixed notation
        let decimal_prec = if prec as i32 > exp + 1 {
            (prec as i32 - exp - 1) as usize
        } else {
            0
        };
        let s = format!("{value:.decimal_prec$}");
        trim_g_trailing_zeros(&s)
    }
}

/// Trim trailing zeros from %g formatted output (but not from the exponent).
fn trim_g_trailing_zeros(s: &str) -> String {
    // Split at 'e' or 'E' if present
    if let Some(e_pos) = s.find(['e', 'E']) {
        let (mantissa, exponent) = s.split_at(e_pos);
        let trimmed = mantissa.trim_end_matches('0').trim_end_matches('.');
        format!("{trimmed}{exponent}")
    } else {
        s.trim_end_matches('0').trim_end_matches('.').to_string()
    }
}

fn main() {
    coreutils_rs::common::reset_sigpipe();

    let args: Vec<String> = std::env::args().skip(1).collect();

    // Parse options
    let mut format: Option<String> = None;
    let mut separator = "\n".to_string();
    let mut equal_width = false;
    let mut positional: Vec<String> = Vec::new();

    let mut i = 0;
    let mut saw_dashdash = false;
    while i < args.len() {
        let arg = &args[i];
        if saw_dashdash {
            positional.push(arg.clone());
            i += 1;
            continue;
        }
        match arg.as_str() {
            "--" => {
                saw_dashdash = true;
            }
            "--help" => {
                print_help();
                return;
            }
            "--version" => {
                print_version();
                return;
            }
            "-w" | "--equal-width" => {
                equal_width = true;
            }
            "-f" | "--format" => {
                i += 1;
                if i >= args.len() {
                    eprintln!(
                        "{}: option requires an argument -- \u{2018}f\u{2019}",
                        TOOL_NAME
                    );
                    process::exit(1);
                }
                format = Some(args[i].clone());
            }
            "-s" | "--separator" => {
                i += 1;
                if i >= args.len() {
                    eprintln!(
                        "{}: option requires an argument -- \u{2018}s\u{2019}",
                        TOOL_NAME
                    );
                    process::exit(1);
                }
                separator = args[i].clone();
            }
            _ => {
                if let Some(rest) = arg.strip_prefix("--format=") {
                    format = Some(rest.to_string());
                } else if let Some(rest) = arg.strip_prefix("--separator=") {
                    separator = rest.to_string();
                } else if let Some(rest) = arg.strip_prefix("-f") {
                    format = Some(rest.to_string());
                } else if let Some(rest) = arg.strip_prefix("-s") {
                    separator = rest.to_string();
                } else {
                    // Could be a negative number or positional arg
                    positional.push(arg.clone());
                }
            }
        }
        i += 1;
    }

    if positional.is_empty() {
        eprintln!("{}: missing operand", TOOL_NAME);
        process::exit(1);
    }

    let (first_str, increment_str, last_str) = match positional.len() {
        1 => ("1".to_string(), "1".to_string(), positional[0].clone()),
        2 => (
            positional[0].clone(),
            "1".to_string(),
            positional[1].clone(),
        ),
        3 => (
            positional[0].clone(),
            positional[1].clone(),
            positional[2].clone(),
        ),
        _ => {
            eprintln!(
                "{}: extra operand \u{2018}{}\u{2019}",
                TOOL_NAME, positional[3]
            );
            process::exit(1);
        }
    };

    let first: f64 = match first_str.parse() {
        Ok(v) => v,
        Err(_) => {
            eprintln!(
                "{}: invalid floating point argument: \u{2018}{}\u{2019}",
                TOOL_NAME, first_str
            );
            process::exit(1);
        }
    };
    let increment: f64 = match increment_str.parse() {
        Ok(v) => v,
        Err(_) => {
            eprintln!(
                "{}: invalid floating point argument: \u{2018}{}\u{2019}",
                TOOL_NAME, increment_str
            );
            process::exit(1);
        }
    };
    let last: f64 = match last_str.parse() {
        Ok(v) => v,
        Err(_) => {
            eprintln!(
                "{}: invalid floating point argument: \u{2018}{}\u{2019}",
                TOOL_NAME, last_str
            );
            process::exit(1);
        }
    };

    if increment == 0.0 {
        eprintln!(
            "{}: invalid Zero increment value: \u{2018}{}\u{2019}",
            TOOL_NAME, increment_str
        );
        eprintln!("Try '{} --help' for more information.", TOOL_NAME);
        process::exit(1);
    }

    // Determine precision from input
    let prec = decimal_places(&first_str)
        .max(decimal_places(&increment_str))
        .max(decimal_places(&last_str));

    // Determine if we should use integer mode
    let use_int = prec == 0
        && is_integer_str(&first_str)
        && is_integer_str(&increment_str)
        && is_integer_str(&last_str)
        && format.is_none();

    // Determine format string
    let mut int_pad_width: usize = 0; // For integer equal-width, use native formatting
    let fmt = if let Some(ref f) = format {
        if equal_width {
            eprintln!(
                "{}: format string may not be specified when printing equal width strings",
                TOOL_NAME
            );
            process::exit(1);
        }
        f.clone()
    } else if equal_width {
        // Determine the width needed
        let first_width = if use_int {
            format_int_value(first as i64).len()
        } else {
            format_fixed(first, prec).len()
        };
        let last_width = if use_int {
            format_int_value(last as i64).len()
        } else {
            format_fixed(last, prec).len()
        };
        let w = first_width.max(last_width);
        if use_int {
            // Use native Rust integer zero-padding (avoids %g scientific notation for large numbers)
            int_pad_width = w;
            "INT_PAD".to_string() // Marker to enter the format path
        } else {
            format!("%0{w}.{prec}f")
        }
    } else if prec > 0 {
        // Empty: use write_fixed_to_buf fast path with prec
        String::new()
    } else {
        String::new() // Will use integer or default formatting
    };

    let mut is_first = true;
    let sep_bytes = separator.as_bytes();
    let sep_is_newline = separator == "\n";

    if use_int && fmt.is_empty() {
        // Ultra-fast integer path: write directly into fixed buffer, bypass Vec overhead.
        let first_i = first as i64;
        let inc_i = increment as i64;
        let last_i = last as i64;

        const BUF_SIZE: usize = 1024 * 1024;
        const FLUSH_AT: usize = BUF_SIZE - 32; // 32 bytes margin for max i64 + newline
        let mut buf = vec![0u8; BUF_SIZE];
        let mut offset: usize = 0;

        // Enlarge pipe buffer to match our write size for minimal syscalls
        #[cfg(target_os = "linux")]
        unsafe {
            libc::fcntl(1, libc::F_SETPIPE_SZ, BUF_SIZE as libc::c_int);
        }

        let mut current = first_i;
        if inc_i == 1 && first_i >= 0 && sep_is_newline {
            // Digit-width-batched ASCII counter: process numbers in groups
            // of equal digit count (1-9, 10-99, 100-999, ...) so each batch
            // has a compile-time-known copy size. This lets the compiler
            // inline copy_nonoverlapping as a single MOV instruction instead
            // of a memcpy function call.
            let mut digits = [b'0'; 21]; // ASCII '0' fill for carry propagation
            digits[20] = b'\n'; // sentinel newline
            let mut len: usize;

            // Initialize with first number
            {
                let mut itoa_buf = itoa::Buffer::new();
                let s = itoa_buf.format(current);
                let bytes = s.as_bytes();
                len = bytes.len();
                digits[20 - len..20].copy_from_slice(bytes);
            }

            while current <= last_i {
                // End of current digit-width batch (e.g., 999 for 3-digit)
                let batch_end = if len < 19 {
                    std::cmp::min(10i64.pow(len as u32) - 1, last_i)
                } else {
                    last_i
                };

                // Each invocation generates a loop with compile-time ENTRY size.
                // Decade-unrolled: writes 10 numbers per carry by cycling last
                // digit 0-9 directly in the output buffer.
                macro_rules! batch {
                    ($w:literal) => {{
                        const ENTRY: usize = $w + 1; // digits + newline
                        const START: usize = 20 - $w;
                        while current <= batch_end {
                            let remaining = FLUSH_AT - offset;
                            let can_fit = remaining / ENTRY;
                            let run_end = std::cmp::min(current + can_fit as i64 - 1, batch_end);
                            // Handle prefix: numbers before next decade boundary
                            while current <= run_end && (current % 10) != 0 {
                                unsafe {
                                    std::ptr::copy_nonoverlapping(
                                        digits.as_ptr().add(START),
                                        buf.as_mut_ptr().add(offset),
                                        ENTRY,
                                    );
                                }
                                offset += ENTRY;
                                current += 1;
                                let mut p = 19usize;
                                loop {
                                    if digits[p] < b'9' {
                                        digits[p] += 1;
                                        break;
                                    }
                                    digits[p] = b'0';
                                    p -= 1;
                                }
                            }
                            // Decade-unrolled: write 10 numbers per iteration
                            // Last digit is stamped directly, no carry logic needed.
                            while current + 9 <= run_end {
                                let base = offset;
                                digits[19] = b'0';
                                // Copy all 10 entries with cycling last digit
                                let mut d = 0usize;
                                while d < 10 {
                                    unsafe {
                                        let dst = buf.as_mut_ptr().add(base + d * ENTRY);
                                        std::ptr::copy_nonoverlapping(
                                            digits.as_ptr().add(START),
                                            dst,
                                            ENTRY,
                                        );
                                        // Stamp last digit directly in output
                                        *dst.add($w - 1) = b'0' + d as u8;
                                    }
                                    d += 1;
                                }
                                offset = base + ENTRY * 10;
                                current += 10;
                                // Carry for tens digit (once per 10 numbers)
                                let mut p = 18usize;
                                loop {
                                    if digits[p] < b'9' {
                                        digits[p] += 1;
                                        break;
                                    }
                                    digits[p] = b'0';
                                    p -= 1;
                                }
                            }
                            // Handle suffix: remaining numbers after last full decade
                            while current <= run_end {
                                unsafe {
                                    std::ptr::copy_nonoverlapping(
                                        digits.as_ptr().add(START),
                                        buf.as_mut_ptr().add(offset),
                                        ENTRY,
                                    );
                                }
                                offset += ENTRY;
                                current += 1;
                                let mut p = 19usize;
                                loop {
                                    if digits[p] < b'9' {
                                        digits[p] += 1;
                                        break;
                                    }
                                    digits[p] = b'0';
                                    p -= 1;
                                }
                            }
                            if offset >= FLUSH_AT {
                                if !write_all_fd1(&buf[..offset]) {
                                    return;
                                }
                                offset = 0;
                            }
                        }
                    }};
                }

                match len {
                    1 => batch!(1),
                    2 => batch!(2),
                    3 => batch!(3),
                    4 => batch!(4),
                    5 => batch!(5),
                    6 => batch!(6),
                    7 => batch!(7),
                    8 => batch!(8),
                    9 => batch!(9),
                    10 => batch!(10),
                    11 => batch!(11),
                    12 => batch!(12),
                    13 => batch!(13),
                    14 => batch!(14),
                    15 => batch!(15),
                    16 => batch!(16),
                    17 => batch!(17),
                    18 => batch!(18),
                    19 => batch!(19),
                    _ => unreachable!("i64 has at most 19 digits"),
                }

                // Next digit width: set leading '1' for the new power of 10.
                // The lower digits are already '0' from carry propagation or
                // from the initial fill; this write is the definitive init.
                if current <= last_i {
                    len += 1;
                    digits[20 - len] = b'1';
                }
            }

            if offset > 0 {
                let _ = write_all_fd1(&buf[..offset]);
            }
        } else if inc_i > 0 && sep_is_newline {
            // Positive increment with newline separator (non-1 increment)
            let mut itoa_buf = itoa::Buffer::new();
            while current <= last_i {
                let s = itoa_buf.format(current);
                let bytes = s.as_bytes();
                let len = bytes.len();
                unsafe {
                    std::ptr::copy_nonoverlapping(
                        bytes.as_ptr(),
                        buf.as_mut_ptr().add(offset),
                        len,
                    );
                }
                offset += len;
                buf[offset] = b'\n';
                offset += 1;
                if offset >= FLUSH_AT {
                    if !write_all_fd1(&buf[..offset]) {
                        return;
                    }
                    offset = 0;
                }
                current += inc_i;
            }
            if offset > 0 {
                let _ = write_all_fd1(&buf[..offset]);
            }
        } else if inc_i > 0 {
            let mut vbuf = Vec::with_capacity(BUF_SIZE);
            let mut itoa_buf2 = itoa::Buffer::new();
            while current <= last_i {
                if !is_first {
                    vbuf.extend_from_slice(sep_bytes);
                }
                is_first = false;
                let s = itoa_buf2.format(current);
                vbuf.extend_from_slice(s.as_bytes());
                if vbuf.len() >= FLUSH_AT {
                    if !write_all_fd1(&vbuf) {
                        return;
                    }
                    vbuf.clear();
                }
                current += inc_i;
            }
            if !is_first {
                vbuf.push(b'\n');
            }
            if !vbuf.is_empty() {
                let _ = write_all_fd1(&vbuf);
            }
        } else {
            let mut vbuf = Vec::with_capacity(BUF_SIZE);
            let mut itoa_buf2 = itoa::Buffer::new();
            while current >= last_i {
                if !is_first {
                    vbuf.extend_from_slice(sep_bytes);
                }
                is_first = false;
                let s = itoa_buf2.format(current);
                vbuf.extend_from_slice(s.as_bytes());
                if vbuf.len() >= FLUSH_AT {
                    if !write_all_fd1(&vbuf) {
                        return;
                    }
                    vbuf.clear();
                }
                current += inc_i;
            }
            if !is_first {
                vbuf.push(b'\n');
            }
            if !vbuf.is_empty() {
                let _ = write_all_fd1(&vbuf);
            }
        }
    } else if use_int && !fmt.is_empty() {
        // Integer values with format string (e.g., equal-width)
        let first_i = first as i64;
        let inc_i = increment as i64;
        let last_i = last as i64;

        let mut itoa_buf = itoa::Buffer::new();
        let mut buf = Vec::with_capacity(256 * 1024);
        let flush_threshold = 240 * 1024;

        let mut current = first_i;
        if inc_i > 0 {
            while current <= last_i {
                if !is_first {
                    buf.extend_from_slice(sep_bytes);
                }
                is_first = false;
                if int_pad_width > 0 {
                    // Zero-padded integer using itoa + manual padding
                    let s = itoa_buf.format(current);
                    let s_bytes = s.as_bytes();
                    if current < 0 {
                        buf.push(b'-');
                        let digits = &s_bytes[1..]; // skip '-'
                        if digits.len() < int_pad_width - 1 {
                            let pad = int_pad_width - 1 - digits.len();
                            buf.extend(std::iter::repeat_n(b'0', pad));
                        }
                        buf.extend_from_slice(digits);
                    } else if s_bytes.len() < int_pad_width {
                        let pad = int_pad_width - s_bytes.len();
                        buf.extend(std::iter::repeat_n(b'0', pad));
                        buf.extend_from_slice(s_bytes);
                    } else {
                        buf.extend_from_slice(s_bytes);
                    }
                } else {
                    let s = format_number(&fmt, current as f64);
                    buf.extend_from_slice(s.as_bytes());
                }
                if buf.len() >= flush_threshold {
                    if !write_all_fd1(&buf) {
                        return;
                    }
                    buf.clear();
                }
                current += inc_i;
            }
        } else {
            while current >= last_i {
                if !is_first {
                    buf.extend_from_slice(sep_bytes);
                }
                is_first = false;
                if int_pad_width > 0 {
                    let s = itoa_buf.format(current);
                    let s_bytes = s.as_bytes();
                    if current < 0 {
                        buf.push(b'-');
                        let digits = &s_bytes[1..];
                        if digits.len() < int_pad_width - 1 {
                            let pad = int_pad_width - 1 - digits.len();
                            buf.extend(std::iter::repeat_n(b'0', pad));
                        }
                        buf.extend_from_slice(digits);
                    } else if s_bytes.len() < int_pad_width {
                        let pad = int_pad_width - s_bytes.len();
                        buf.extend(std::iter::repeat_n(b'0', pad));
                        buf.extend_from_slice(s_bytes);
                    } else {
                        buf.extend_from_slice(s_bytes);
                    }
                } else {
                    let s = format_number(&fmt, current as f64);
                    buf.extend_from_slice(s.as_bytes());
                }
                if buf.len() >= flush_threshold {
                    if !write_all_fd1(&buf) {
                        return;
                    }
                    buf.clear();
                }
                current += inc_i;
            }
        }
        if !is_first {
            buf.push(b'\n');
        }
        if !buf.is_empty() {
            let _ = write_all_fd1(&buf);
        }
    } else if fmt.is_empty()
        && prec > 0
        && prec <= 15
        && scaled_fits_i64(first, last, increment, prec)
    {
        // Fast integer-based float path: convert to scaled integers to
        // eliminate FP operations from the inner loop entirely.
        // E.g., seq 0 0.1 100000 → iterate 0..1000000 with scale=10.
        let scale = 10i64.pow(prec as u32);
        let int_first = (first * scale as f64).round() as i64;
        let int_last = (last * scale as f64).round() as i64;
        let int_inc = (increment * scale as f64).round() as i64;

        {
            let mut val = int_first;
            let mut buf = Vec::with_capacity(256 * 1024);
            let flush_threshold = 240 * 1024;
            let mut itoa_buf = itoa::Buffer::new();

            if int_inc > 0 {
                while val <= int_last {
                    if !is_first {
                        buf.extend_from_slice(sep_bytes);
                    }
                    is_first = false;
                    write_scaled_int(&mut buf, val, prec, scale, &mut itoa_buf);
                    if buf.len() >= flush_threshold {
                        if !write_all_fd1(&buf) {
                            return;
                        }
                        buf.clear();
                    }
                    val += int_inc;
                }
            } else {
                while val >= int_last {
                    if !is_first {
                        buf.extend_from_slice(sep_bytes);
                    }
                    is_first = false;
                    write_scaled_int(&mut buf, val, prec, scale, &mut itoa_buf);
                    if buf.len() >= flush_threshold {
                        if !write_all_fd1(&buf) {
                            return;
                        }
                        buf.clear();
                    }
                    val += int_inc;
                }
            }

            if !is_first {
                buf.push(b'\n');
            }
            if !buf.is_empty() {
                let _ = write_all_fd1(&buf);
            }
        }
    } else {
        // General float path with format_number or write_fixed_to_buf
        let mut step: u64 = 0;
        let mut buf = Vec::with_capacity(256 * 1024);
        let flush_threshold = 240 * 1024;
        if increment > 0.0 {
            loop {
                let val = first + step as f64 * increment;
                if val > last {
                    break;
                }
                if !is_first {
                    buf.extend_from_slice(sep_bytes);
                }
                is_first = false;
                if fmt.is_empty() {
                    write_fixed_to_buf(&mut buf, val, prec);
                } else {
                    let s = format_number(&fmt, val);
                    buf.extend_from_slice(s.as_bytes());
                }
                if buf.len() >= flush_threshold {
                    if !write_all_fd1(&buf) {
                        return;
                    }
                    buf.clear();
                }
                step += 1;
            }
        } else {
            loop {
                let val = first + step as f64 * increment;
                if val < last {
                    break;
                }
                if !is_first {
                    buf.extend_from_slice(sep_bytes);
                }
                is_first = false;
                if fmt.is_empty() {
                    write_fixed_to_buf(&mut buf, val, prec);
                } else {
                    let s = format_number(&fmt, val);
                    buf.extend_from_slice(s.as_bytes());
                }
                if buf.len() >= flush_threshold {
                    if !write_all_fd1(&buf) {
                        return;
                    }
                    buf.clear();
                }
                step += 1;
            }
        }

        // Flush remaining data in the float path buffer
        if !is_first {
            buf.push(b'\n');
        }
        if !buf.is_empty() {
            let _ = write_all_fd1(&buf);
        }
    }
}

fn format_int_value(v: i64) -> String {
    format!("{v}")
}

fn format_fixed(value: f64, prec: usize) -> String {
    if prec == 0 {
        format!("{}", value as i64)
    } else {
        format!("{value:.prec$}", prec = prec)
    }
}

/// Check if all scaled float values fit safely in i64 and increment is non-zero.
fn scaled_fits_i64(first: f64, last: f64, increment: f64, prec: usize) -> bool {
    let scale_f = 10f64.powi(prec as i32);
    let f = (first * scale_f).round();
    let l = (last * scale_f).round();
    let inc = (increment * scale_f).round();
    let i64_max = i64::MAX as f64;
    let i64_min = i64::MIN as f64;
    f >= i64_min
        && f <= i64_max
        && l >= i64_min
        && l <= i64_max
        && inc >= i64_min
        && inc <= i64_max
        && inc != 0.0
}

/// Write a scaled integer as a fixed-point decimal string into the buffer.
/// E.g., val=12345, prec=1, scale=10 → "1234.5"
/// Works entirely in integer space — no FP ops, no Formatter.
#[inline(always)]
fn write_scaled_int(
    buf: &mut Vec<u8>,
    val: i64,
    prec: usize,
    scale: i64,
    itoa_buf: &mut itoa::Buffer,
) {
    let negative = val < 0;
    let abs_val = if negative {
        val.wrapping_neg() as u64
    } else {
        val as u64
    };
    let scale_u = scale as u64;
    let int_part = abs_val / scale_u;
    let frac_part = abs_val % scale_u;

    if negative && (int_part > 0 || frac_part > 0) {
        buf.push(b'-');
    }

    buf.extend_from_slice(itoa_buf.format(int_part).as_bytes());
    buf.push(b'.');

    // Pad fractional part with leading zeros, then write digits
    let frac_str = itoa_buf.format(frac_part);
    let frac_bytes = frac_str.as_bytes();
    for _ in 0..(prec - frac_bytes.len()) {
        buf.push(b'0');
    }
    buf.extend_from_slice(frac_bytes);
}

/// Write a fixed-point formatted float directly into output buffer.
/// Uses itoa for integer part + direct byte ops for fractional part.
/// ~5x faster than format!("{:.prec$}") by bypassing Formatter infrastructure.
fn write_fixed_to_buf(buf: &mut Vec<u8>, value: f64, prec: usize) {
    if prec == 0 {
        let mut itoa_buf = itoa::Buffer::new();
        buf.extend_from_slice(itoa_buf.format(value as i64).as_bytes());
        return;
    }

    // For prec 1-15, use fast integer-based formatting (with overflow guard)
    if prec <= 15 {
        let negative = value < 0.0;
        let abs_val = value.abs();
        let scale = 10u64.pow(prec as u32);
        let scaled_f = (abs_val * scale as f64).round();
        if scaled_f >= u64::MAX as f64 {
            use std::io::Write;
            write!(buf, "{value:.prec$}").unwrap();
            return;
        }
        let scaled = scaled_f as u64;
        let int_part = scaled / scale;
        let frac_part = scaled % scale;

        if negative && (int_part > 0 || frac_part > 0) {
            buf.push(b'-');
        }

        let mut itoa_buf = itoa::Buffer::new();
        buf.extend_from_slice(itoa_buf.format(int_part).as_bytes());
        buf.push(b'.');

        // Pad fractional part with leading zeros
        let frac_str = itoa_buf.format(frac_part);
        let frac_bytes = frac_str.as_bytes();
        for _ in 0..(prec - frac_bytes.len()) {
            buf.push(b'0');
        }
        buf.extend_from_slice(frac_bytes);
    } else {
        // Fallback for extreme precision
        use std::io::Write;
        write!(buf, "{value:.prec$}").unwrap();
    }
}

/// Return the width needed for equal-width display of a number string.
#[allow(dead_code)]
fn display_width(s: &str) -> usize {
    number_width(s)
}

#[cfg(test)]
mod tests {
    use std::process::Command;

    fn cmd() -> Command {
        let mut path = std::env::current_exe().unwrap();
        path.pop();
        path.pop();
        path.push("fseq");
        Command::new(path)
    }

    /// Normalize line endings for cross-platform test compatibility.
    fn norm(s: &str) -> String {
        s.replace("\r\n", "\n")
    }

    #[test]
    fn test_basic_1_to_10() {
        let output = cmd().arg("10").output().unwrap();
        assert!(output.status.success());
        let stdout = norm(&String::from_utf8_lossy(&output.stdout));
        let expected = "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n";
        assert_eq!(stdout, expected);
    }

    #[test]
    fn test_first_and_last() {
        let output = cmd().args(["3", "7"]).output().unwrap();
        assert!(output.status.success());
        let stdout = norm(&String::from_utf8_lossy(&output.stdout));
        assert_eq!(stdout, "3\n4\n5\n6\n7\n");
    }

    #[test]
    fn test_first_increment_last() {
        let output = cmd().args(["1", "2", "10"]).output().unwrap();
        assert!(output.status.success());
        let stdout = norm(&String::from_utf8_lossy(&output.stdout));
        assert_eq!(stdout, "1\n3\n5\n7\n9\n");
    }

    #[test]
    fn test_format_f() {
        let output = cmd().args(["-f", "%03g", "5"]).output().unwrap();
        assert!(output.status.success());
        let stdout = norm(&String::from_utf8_lossy(&output.stdout));
        assert_eq!(stdout, "001\n002\n003\n004\n005\n");
    }

    #[test]
    fn test_separator() {
        let output = cmd().args(["-s", ", ", "5"]).output().unwrap();
        assert!(output.status.success());
        let stdout = norm(&String::from_utf8_lossy(&output.stdout));
        assert_eq!(stdout, "1, 2, 3, 4, 5\n");
    }

    #[test]
    fn test_equal_width() {
        let output = cmd().args(["-w", "1", "10"]).output().unwrap();
        assert!(output.status.success());
        let stdout = norm(&String::from_utf8_lossy(&output.stdout));
        assert_eq!(stdout, "01\n02\n03\n04\n05\n06\n07\n08\n09\n10\n");
    }

    #[test]
    fn test_negative_numbers() {
        let output = cmd().args(["-3", "3"]).output().unwrap();
        assert!(output.status.success());
        let stdout = norm(&String::from_utf8_lossy(&output.stdout));
        assert_eq!(stdout, "-3\n-2\n-1\n0\n1\n2\n3\n");
    }

    #[test]
    fn test_floating_point() {
        let output = cmd().args(["0.5", "0.5", "2.5"]).output().unwrap();
        assert!(output.status.success());
        let stdout = norm(&String::from_utf8_lossy(&output.stdout));
        assert_eq!(stdout, "0.5\n1.0\n1.5\n2.0\n2.5\n");
    }

    #[test]
    fn test_countdown() {
        let output = cmd().args(["5", "-1", "1"]).output().unwrap();
        assert!(output.status.success());
        let stdout = norm(&String::from_utf8_lossy(&output.stdout));
        assert_eq!(stdout, "5\n4\n3\n2\n1\n");
    }

    #[test]
    fn test_single_number() {
        let output = cmd().arg("1").output().unwrap();
        assert!(output.status.success());
        let stdout = norm(&String::from_utf8_lossy(&output.stdout));
        assert_eq!(stdout, "1\n");
    }

    #[test]
    fn test_large_range() {
        let output = cmd().arg("10000").output().unwrap();
        assert!(output.status.success());
        let stdout = norm(&String::from_utf8_lossy(&output.stdout));
        let lines: Vec<&str> = stdout.trim_end().split('\n').collect();
        assert_eq!(lines.len(), 10000);
        assert_eq!(lines[0], "1");
        assert_eq!(lines[9999], "10000");
    }

    #[test]
    fn test_help() {
        let output = cmd().arg("--help").output().unwrap();
        assert!(output.status.success());
        let stdout = String::from_utf8_lossy(&output.stdout);
        assert!(stdout.contains("Usage:"));
        assert!(stdout.contains("seq"));
    }

    #[test]
    fn test_version() {
        let output = cmd().arg("--version").output().unwrap();
        assert!(output.status.success());
        let stdout = String::from_utf8_lossy(&output.stdout);
        assert!(stdout.contains("seq"));
        assert!(stdout.contains("fcoreutils"));
    }

    /// Check if system seq is GNU seq (BSD seq on macOS behaves differently)
    fn is_gnu_seq() -> bool {
        Command::new("seq")
            .arg("--version")
            .output()
            .map(|o| {
                let stdout = String::from_utf8_lossy(&o.stdout);
                let stderr = String::from_utf8_lossy(&o.stderr);
                stdout.contains("GNU") || stderr.contains("GNU")
            })
            .unwrap_or(false)
    }

    #[test]
    fn test_match_gnu_basic() {
        if !is_gnu_seq() {
            return;
        }
        let gnu = Command::new("seq").arg("10").output().unwrap();
        let ours = cmd().arg("10").output().unwrap();
        assert_eq!(
            norm(&String::from_utf8_lossy(&ours.stdout)),
            norm(&String::from_utf8_lossy(&gnu.stdout)),
            "Output mismatch with GNU seq for 'seq 10'"
        );
    }

    #[test]
    fn test_match_gnu_first_last() {
        if !is_gnu_seq() {
            return;
        }
        let gnu = Command::new("seq").args(["5", "15"]).output().unwrap();
        let ours = cmd().args(["5", "15"]).output().unwrap();
        assert_eq!(
            norm(&String::from_utf8_lossy(&ours.stdout)),
            norm(&String::from_utf8_lossy(&gnu.stdout)),
            "Output mismatch with GNU seq for 'seq 5 15'"
        );
    }

    #[test]
    fn test_match_gnu_increment() {
        if !is_gnu_seq() {
            return;
        }
        let gnu = Command::new("seq").args(["1", "3", "20"]).output().unwrap();
        let ours = cmd().args(["1", "3", "20"]).output().unwrap();
        assert_eq!(
            norm(&String::from_utf8_lossy(&ours.stdout)),
            norm(&String::from_utf8_lossy(&gnu.stdout)),
            "Output mismatch with GNU seq for 'seq 1 3 20'"
        );
    }

    #[test]
    fn test_match_gnu_separator() {
        if !is_gnu_seq() {
            return;
        }
        let gnu = Command::new("seq").args(["-s", ":", "5"]).output().unwrap();
        let ours = cmd().args(["-s", ":", "5"]).output().unwrap();
        assert_eq!(
            norm(&String::from_utf8_lossy(&ours.stdout)),
            norm(&String::from_utf8_lossy(&gnu.stdout)),
            "Output mismatch with GNU seq for 'seq -s : 5'"
        );
    }

    #[test]
    fn test_match_gnu_equal_width() {
        if !is_gnu_seq() {
            return;
        }
        let gnu = Command::new("seq")
            .args(["-w", "1", "100"])
            .output()
            .unwrap();
        let ours = cmd().args(["-w", "1", "100"]).output().unwrap();
        assert_eq!(
            norm(&String::from_utf8_lossy(&ours.stdout)),
            norm(&String::from_utf8_lossy(&gnu.stdout)),
            "Output mismatch with GNU seq for 'seq -w 1 100'"
        );
    }

    #[test]
    fn test_zero_increment() {
        let output = cmd().args(["1", "0", "5"]).output().unwrap();
        assert!(!output.status.success());
    }

    #[test]
    fn test_empty_sequence() {
        // When first > last with positive increment, output nothing
        let output = cmd().args(["5", "1"]).output().unwrap();
        assert!(output.status.success());
        let stdout = norm(&String::from_utf8_lossy(&output.stdout));
        assert_eq!(stdout, "");
    }

    #[test]
    fn test_equal_width_negative() {
        let output = cmd().args(["-w", "-5", "5"]).output().unwrap();
        assert!(output.status.success());
        let stdout = norm(&String::from_utf8_lossy(&output.stdout));
        // Should zero-pad to match widths
        assert!(stdout.contains("-5\n"));
        assert!(stdout.contains("05\n") || stdout.contains("5\n"));
    }
}
