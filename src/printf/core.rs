/// GNU coreutils-compatible printf implementation.
///
/// Processes a printf format string with the given arguments, writing output
/// directly to the provided writer. The format string is reused if there are
/// more arguments than a single pass consumes.
use std::cell::Cell;
use std::io::Write;

thread_local! {
    /// Set to true when a numeric conversion warning occurs (invalid argument).
    static CONV_ERROR: Cell<bool> = const { Cell::new(false) };
}

/// Reset conversion error flag. Call before processing a format string.
pub fn reset_conv_error() {
    CONV_ERROR.with(|c| c.set(false));
}

/// Returns true if a conversion warning occurred since last reset.
pub fn had_conv_error() -> bool {
    CONV_ERROR.with(|c| c.get())
}

fn mark_conv_error(s: &str) {
    eprintln!("printf: '{}': expected a numeric value", s);
    CONV_ERROR.with(|c| c.set(true));
}

fn mark_range_error(s: &str) {
    eprintln!("printf: '{}': Numerical result out of range", s);
    CONV_ERROR.with(|c| c.set(true));
}

/// Process a printf format string with the given arguments, returning raw bytes.
///
/// The format string repeats if there are more arguments than one pass consumes.
/// Processing stops immediately when `\c` is encountered (in the format string
/// itself or inside a `%b` argument).
pub fn process_format_string(format: &str, args: &[&str]) -> Vec<u8> {
    let mut output = Vec::with_capacity(256);
    write_format_string(format, args, &mut output);
    output
}

/// Process a printf format string, writing output directly to `writer`.
///
/// This is the zero-copy fast path: no intermediate `Vec<u8>` is allocated for
/// the entire output. Each formatting helper writes directly into `writer`.
pub fn write_format_string(format: &str, args: &[&str], writer: &mut impl Write) {
    let fmt_bytes = format.as_bytes();

    if args.is_empty() {
        format_one_pass(fmt_bytes, args, &mut 0, writer);
        return;
    }

    let mut arg_idx: usize = 0;
    loop {
        let start_idx = arg_idx;
        let stop = format_one_pass(fmt_bytes, args, &mut arg_idx, writer);
        if stop {
            break;
        }
        // If no arguments were consumed, or we've used them all, stop
        if arg_idx == start_idx || arg_idx >= args.len() {
            break;
        }
    }
}

/// Run one pass of the format string. Returns `true` if output should stop (`\c`).
/// `arg_idx` is advanced as arguments are consumed.
fn format_one_pass(fmt: &[u8], args: &[&str], arg_idx: &mut usize, w: &mut impl Write) -> bool {
    let len = fmt.len();
    let mut i = 0;
    while i < len {
        // Fast path: scan for the next special character (% or \) and write
        // the entire literal run in one call.
        let start = i;
        while i < len && fmt[i] != b'%' && fmt[i] != b'\\' {
            i += 1;
        }
        if i > start {
            let _ = w.write_all(&fmt[start..i]);
        }
        if i >= len {
            break;
        }
        match fmt[i] {
            b'%' => {
                i += 1;
                if i >= len {
                    let _ = w.write_all(b"%");
                    break;
                }
                if fmt[i] == b'%' {
                    let _ = w.write_all(b"%");
                    i += 1;
                    continue;
                }
                let stop = process_conversion(fmt, &mut i, args, arg_idx, w);
                if stop {
                    return true;
                }
            }
            b'\\' => {
                i += 1;
                let stop = process_format_escape(fmt, &mut i, w);
                if stop {
                    return true;
                }
            }
            _ => unreachable!(),
        }
    }
    false
}

/// Process a conversion specifier (the part after `%`).
/// `i` points to the first character after `%`. Returns true if `\c` stop was hit.
fn process_conversion(
    fmt: &[u8],
    i: &mut usize,
    args: &[&str],
    arg_idx: &mut usize,
    w: &mut impl Write,
) -> bool {
    // Parse flags
    let mut flags = FormatFlags::default();
    while *i < fmt.len() {
        match fmt[*i] {
            b'-' => flags.left_align = true,
            b'+' => flags.plus_sign = true,
            b' ' => flags.space_sign = true,
            b'0' => flags.zero_pad = true,
            b'#' => flags.alternate = true,
            _ => break,
        }
        *i += 1;
    }

    // Parse width (may be '*' for dynamic width from args)
    let (width, dyn_left_align) = if *i < fmt.len() && fmt[*i] == b'*' {
        *i += 1;
        let width_arg = consume_arg(args, arg_idx);
        let w_val: i64 = width_arg.parse().unwrap_or(0);
        if w_val < 0 {
            ((-w_val) as usize, true) // negative width -> left-align
        } else {
            (w_val as usize, false)
        }
    } else {
        (parse_decimal(fmt, i), false)
    };
    if dyn_left_align {
        flags.left_align = true;
    }

    // Parse precision (may be '*' for dynamic precision from args)
    let precision = if *i < fmt.len() && fmt[*i] == b'.' {
        *i += 1;
        if *i < fmt.len() && fmt[*i] == b'*' {
            *i += 1;
            let prec_arg = consume_arg(args, arg_idx);
            let p: i64 = prec_arg.parse().unwrap_or(0);
            Some(if p < 0 { 0 } else { p as usize })
        } else {
            Some(parse_decimal(fmt, i))
        }
    } else {
        None
    };

    // Parse conversion character
    if *i >= fmt.len() {
        return false;
    }
    let conv = fmt[*i];
    *i += 1;

    let arg = consume_arg(args, arg_idx);

    match conv {
        b's' => {
            write_string_format(w, arg.as_bytes(), &flags, width, precision);
        }
        b'b' => {
            // %b needs escape processing first, so we must buffer the arg
            let (bytes, stop) = process_b_argument(arg);
            write_string_format(w, &bytes, &flags, width, precision);
            if stop {
                return true;
            }
        }
        b'c' => {
            if let Some(ch) = arg.chars().next() {
                let mut buf = [0u8; 4];
                let encoded = ch.encode_utf8(&mut buf);
                write_string_format(w, encoded.as_bytes(), &flags, width, precision);
            } else {
                // empty arg: output a NUL byte (GNU compat)
                write_string_format(w, &[0], &flags, width, precision);
            }
        }
        b'd' | b'i' => {
            let val = parse_integer(arg);
            let mut buf = itoa::Buffer::new();
            let s = buf.format(val);
            write_numeric_format(w, s, val < 0, &flags, width, precision);
        }
        b'u' => {
            let val = parse_unsigned(arg);
            let mut buf = itoa::Buffer::new();
            let s = buf.format(val);
            write_numeric_format(w, s, false, &flags, width, precision);
        }
        b'o' => {
            let val = parse_unsigned(arg);
            // Format octal into a stack buffer to avoid heap allocation
            let mut octal_buf = [0u8; 22]; // u64 max octal is 22 digits
            let octal_str = format_octal(val, &mut octal_buf);
            let prefix = if flags.alternate && !octal_str.starts_with('0') {
                "0"
            } else {
                ""
            };
            write_numeric_format_with_prefix(w, prefix, octal_str, &flags, width, precision);
        }
        b'x' => {
            let val = parse_unsigned(arg);
            let mut hex_buf = [0u8; 16]; // u64 max hex is 16 digits
            let hex_str = format_hex_lower(val, &mut hex_buf);
            let prefix = if flags.alternate && val != 0 {
                "0x"
            } else {
                ""
            };
            write_numeric_format_with_prefix(w, prefix, hex_str, &flags, width, precision);
        }
        b'X' => {
            let val = parse_unsigned(arg);
            let mut hex_buf = [0u8; 16];
            let hex_str = format_hex_upper(val, &mut hex_buf);
            let prefix = if flags.alternate && val != 0 {
                "0X"
            } else {
                ""
            };
            write_numeric_format_with_prefix(w, prefix, hex_str, &flags, width, precision);
        }
        b'f' => {
            let val = parse_float(arg);
            let prec = precision.unwrap_or(6);
            let s = format!("{:.prec$}", val, prec = prec);
            write_float_format(w, &s, val < 0.0, &flags, width);
        }
        b'e' => {
            let val = parse_float(arg);
            let prec = precision.unwrap_or(6);
            let s = format_scientific(val, prec, 'e');
            write_float_format(w, &s, val < 0.0, &flags, width);
        }
        b'E' => {
            let val = parse_float(arg);
            let prec = precision.unwrap_or(6);
            let s = format_scientific(val, prec, 'E');
            write_float_format(w, &s, val < 0.0, &flags, width);
        }
        b'g' => {
            let val = parse_float(arg);
            let prec = precision.unwrap_or(6);
            let s = format_g(val, prec, false);
            write_float_format(w, &s, val < 0.0, &flags, width);
        }
        b'G' => {
            let val = parse_float(arg);
            let prec = precision.unwrap_or(6);
            let s = format_g(val, prec, true);
            write_float_format(w, &s, val < 0.0, &flags, width);
        }
        b'q' => {
            let quoted = shell_quote(arg);
            write_string_format(w, quoted.as_bytes(), &flags, width, precision);
        }
        _ => {
            // Unknown conversion: output literally
            let _ = w.write_all(&[b'%', conv]);
        }
    }
    false
}

/// Consume the next argument, returning "" if exhausted.
fn consume_arg<'a>(args: &[&'a str], arg_idx: &mut usize) -> &'a str {
    if *arg_idx < args.len() {
        let val = args[*arg_idx];
        *arg_idx += 1;
        val
    } else {
        ""
    }
}

/// Process an escape sequence in the format string.
/// `i` points to the character after `\`. Returns true if `\c` was encountered.
fn process_format_escape(fmt: &[u8], i: &mut usize, w: &mut impl Write) -> bool {
    if *i >= fmt.len() {
        let _ = w.write_all(b"\\");
        return false;
    }
    match fmt[*i] {
        b'\\' => {
            let _ = w.write_all(b"\\");
            *i += 1;
        }
        b'"' => {
            let _ = w.write_all(b"\"");
            *i += 1;
        }
        b'a' => {
            let _ = w.write_all(&[0x07]);
            *i += 1;
        }
        b'b' => {
            let _ = w.write_all(&[0x08]);
            *i += 1;
        }
        b'c' => {
            return true;
        }
        b'e' | b'E' => {
            let _ = w.write_all(&[0x1B]);
            *i += 1;
        }
        b'f' => {
            let _ = w.write_all(&[0x0C]);
            *i += 1;
        }
        b'n' => {
            let _ = w.write_all(b"\n");
            *i += 1;
        }
        b'r' => {
            let _ = w.write_all(b"\r");
            *i += 1;
        }
        b't' => {
            let _ = w.write_all(b"\t");
            *i += 1;
        }
        b'v' => {
            let _ = w.write_all(&[0x0B]);
            *i += 1;
        }
        b'0' => {
            // Octal: \0NNN (up to 3 octal digits after the leading 0)
            *i += 1;
            let val = parse_octal_digits(fmt, i, 3);
            let _ = w.write_all(&[val]);
        }
        b'1'..=b'7' => {
            // Octal: \NNN (up to 3 octal digits)
            let val = parse_octal_digits(fmt, i, 3);
            let _ = w.write_all(&[val]);
        }
        b'x' => {
            *i += 1;
            let val = parse_hex_digits(fmt, i, 2);
            let _ = w.write_all(&[val as u8]);
        }
        b'u' => {
            *i += 1;
            let val = parse_hex_digits(fmt, i, 4);
            if let Some(ch) = char::from_u32(val) {
                let mut buf = [0u8; 4];
                let encoded = ch.encode_utf8(&mut buf);
                let _ = w.write_all(encoded.as_bytes());
            }
        }
        b'U' => {
            *i += 1;
            let val = parse_hex_digits(fmt, i, 8);
            if let Some(ch) = char::from_u32(val) {
                let mut buf = [0u8; 4];
                let encoded = ch.encode_utf8(&mut buf);
                let _ = w.write_all(encoded.as_bytes());
            }
        }
        _ => {
            // Unknown escape: output backslash and the character
            let _ = w.write_all(&[b'\\', fmt[*i]]);
            *i += 1;
        }
    }
    false
}

/// Process backslash escapes in a %b argument string.
/// Returns (bytes, stop) where stop is true if \c was found.
fn process_b_argument(arg: &str) -> (Vec<u8>, bool) {
    let bytes = arg.as_bytes();
    let mut output = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'\\' {
            i += 1;
            if i >= bytes.len() {
                output.push(b'\\');
                break;
            }
            match bytes[i] {
                b'\\' => {
                    output.push(b'\\');
                    i += 1;
                }
                b'a' => {
                    output.push(0x07);
                    i += 1;
                }
                b'b' => {
                    output.push(0x08);
                    i += 1;
                }
                b'c' => {
                    return (output, true);
                }
                b'e' | b'E' => {
                    output.push(0x1B);
                    i += 1;
                }
                b'f' => {
                    output.push(0x0C);
                    i += 1;
                }
                b'n' => {
                    output.push(b'\n');
                    i += 1;
                }
                b'r' => {
                    output.push(b'\r');
                    i += 1;
                }
                b't' => {
                    output.push(b'\t');
                    i += 1;
                }
                b'v' => {
                    output.push(0x0B);
                    i += 1;
                }
                b'0' => {
                    i += 1;
                    let val = parse_octal_digits(bytes, &mut i, 3);
                    output.push(val);
                }
                b'1'..=b'7' => {
                    let val = parse_octal_digits(bytes, &mut i, 3);
                    output.push(val);
                }
                b'x' => {
                    i += 1;
                    let val = parse_hex_digits(bytes, &mut i, 2);
                    output.push(val as u8);
                }
                _ => {
                    // In %b, unknown escapes pass through literally
                    output.push(b'\\');
                    output.push(bytes[i]);
                    i += 1;
                }
            }
        } else {
            output.push(bytes[i]);
            i += 1;
        }
    }
    (output, false)
}

/// Parse up to `max_digits` octal digits from `data` starting at `*i`.
fn parse_octal_digits(data: &[u8], i: &mut usize, max_digits: usize) -> u8 {
    let mut val: u32 = 0;
    let mut count = 0;
    while *i < data.len() && count < max_digits {
        let ch = data[*i];
        if (b'0'..=b'7').contains(&ch) {
            val = val * 8 + (ch - b'0') as u32;
            *i += 1;
            count += 1;
        } else {
            break;
        }
    }
    (val & 0xFF) as u8
}

/// Parse up to `max_digits` hex digits from `data` starting at `*i`.
fn parse_hex_digits(data: &[u8], i: &mut usize, max_digits: usize) -> u32 {
    let mut val: u32 = 0;
    let mut count = 0;
    while *i < data.len() && count < max_digits {
        let ch = data[*i];
        if ch.is_ascii_hexdigit() {
            val = val * 16 + hex_digit_value(ch) as u32;
            *i += 1;
            count += 1;
        } else {
            break;
        }
    }
    val
}

fn hex_digit_value(ch: u8) -> u8 {
    match ch {
        b'0'..=b'9' => ch - b'0',
        b'a'..=b'f' => ch - b'a' + 10,
        b'A'..=b'F' => ch - b'A' + 10,
        _ => 0,
    }
}

/// Parse a decimal integer from `data` at position `*i`.
fn parse_decimal(data: &[u8], i: &mut usize) -> usize {
    let mut val: usize = 0;
    while *i < data.len() && data[*i].is_ascii_digit() {
        val = val
            .saturating_mul(10)
            .saturating_add((data[*i] - b'0') as usize);
        *i += 1;
    }
    val
}

/// Parse an integer argument. Supports decimal, octal (0-prefix), hex (0x-prefix),
/// and single-character constants ('c' or "c").
fn parse_integer(s: &str) -> i64 {
    let s = s.trim();
    if s.is_empty() {
        return 0;
    }

    // Character constants: 'X or "X
    if (s.starts_with('\'') || s.starts_with('"')) && s.len() >= 2 {
        return s[1..].chars().next().map_or(0, |c| c as i64);
    }

    // Try to detect sign
    let (negative, digits) = if let Some(rest) = s.strip_prefix('-') {
        (true, rest)
    } else if let Some(rest) = s.strip_prefix('+') {
        (false, rest)
    } else {
        (false, s)
    };

    // digits must be non-empty and parseable
    if digits.is_empty() {
        mark_conv_error(s);
        return 0;
    }

    let magnitude = if let Some(hex) = digits
        .strip_prefix("0x")
        .or_else(|| digits.strip_prefix("0X"))
    {
        match u64::from_str_radix(hex, 16) {
            Ok(v) => v,
            Err(e) if e.kind() == &std::num::IntErrorKind::PosOverflow => {
                mark_range_error(s);
                if negative {
                    return i64::MIN;
                }
                return i64::MAX;
            }
            Err(_) => {
                mark_conv_error(s);
                0
            }
        }
    } else if let Some(oct) = digits.strip_prefix('0') {
        if oct.is_empty() {
            0
        } else {
            match u64::from_str_radix(oct, 8) {
                Ok(v) => v,
                Err(e) if e.kind() == &std::num::IntErrorKind::PosOverflow => {
                    mark_range_error(s);
                    if negative {
                        return i64::MIN;
                    }
                    return i64::MAX;
                }
                Err(_) => {
                    mark_conv_error(s);
                    0
                }
            }
        }
    } else {
        match digits.parse::<u64>() {
            Ok(v) => v,
            Err(e) if e.kind() == &std::num::IntErrorKind::PosOverflow => {
                mark_range_error(s);
                if negative {
                    return i64::MIN;
                }
                return i64::MAX;
            }
            Err(_) => {
                mark_conv_error(s);
                0
            }
        }
    };

    if negative {
        -(magnitude as i64)
    } else {
        magnitude as i64
    }
}

/// Parse an unsigned integer argument.
fn parse_unsigned(s: &str) -> u64 {
    let s = s.trim();
    if s.is_empty() {
        return 0;
    }

    // Character constants
    if (s.starts_with('\'') || s.starts_with('"')) && s.len() >= 2 {
        return s[1..].chars().next().map_or(0, |c| c as u64);
    }

    // Negative values wrap around like C unsigned
    let (negative, digits) = if let Some(rest) = s.strip_prefix('-') {
        (true, rest)
    } else if let Some(rest) = s.strip_prefix('+') {
        (false, rest)
    } else {
        (false, s)
    };

    // digits must be non-empty and parseable
    if digits.is_empty() {
        mark_conv_error(s);
        return 0;
    }

    let magnitude = if let Some(hex) = digits
        .strip_prefix("0x")
        .or_else(|| digits.strip_prefix("0X"))
    {
        match u64::from_str_radix(hex, 16) {
            Ok(v) => v,
            Err(e) if e.kind() == &std::num::IntErrorKind::PosOverflow => {
                mark_range_error(s);
                u64::MAX
            }
            Err(_) => {
                mark_conv_error(s);
                0
            }
        }
    } else if let Some(oct) = digits.strip_prefix('0') {
        if oct.is_empty() {
            0
        } else {
            match u64::from_str_radix(oct, 8) {
                Ok(v) => v,
                Err(e) if e.kind() == &std::num::IntErrorKind::PosOverflow => {
                    mark_range_error(s);
                    u64::MAX
                }
                Err(_) => {
                    mark_conv_error(s);
                    0
                }
            }
        }
    } else {
        match digits.parse::<u64>() {
            Ok(v) => v,
            Err(e) if e.kind() == &std::num::IntErrorKind::PosOverflow => {
                mark_range_error(s);
                u64::MAX
            }
            Err(_) => {
                mark_conv_error(s);
                0
            }
        }
    };

    if negative {
        magnitude.wrapping_neg()
    } else {
        magnitude
    }
}

/// Parse a floating-point argument.
fn parse_float(s: &str) -> f64 {
    let s = s.trim();
    if s.is_empty() {
        return 0.0;
    }

    // Character constants
    if (s.starts_with('\'') || s.starts_with('"')) && s.len() >= 2 {
        return s[1..].chars().next().map_or(0.0, |c| c as u32 as f64);
    }

    // Handle hex float prefix for parsing
    if s.starts_with("0x") || s.starts_with("0X") || s.starts_with("-0x") || s.starts_with("-0X") {
        // Rust doesn't parse hex floats natively; parse as integer
        return parse_integer(s) as f64;
    }

    s.parse::<f64>().unwrap_or(0.0)
}

#[derive(Default)]
struct FormatFlags {
    left_align: bool,
    plus_sign: bool,
    space_sign: bool,
    zero_pad: bool,
    alternate: bool,
}

/// Write string-formatted output directly (for %s, %b, %c).
/// Avoids allocating a Vec<u8> for the common no-padding case.
fn write_string_format(
    w: &mut impl Write,
    data: &[u8],
    flags: &FormatFlags,
    width: usize,
    precision: Option<usize>,
) {
    let data = if let Some(prec) = precision {
        if data.len() > prec {
            // Truncate to prec bytes, respecting UTF-8 boundaries
            let end = truncate_utf8(data, prec);
            &data[..end]
        } else {
            data
        }
    } else {
        data
    };

    write_padded(w, data, flags, width);
}

/// Truncate byte slice to at most `max_bytes`, respecting UTF-8 char boundaries.
fn truncate_utf8(data: &[u8], max_bytes: usize) -> usize {
    if max_bytes >= data.len() {
        return data.len();
    }
    // If the data is valid UTF-8, truncate at char boundary
    if let Ok(s) = std::str::from_utf8(data) {
        let mut end = 0;
        for ch in s.chars() {
            let next = end + ch.len_utf8();
            if next > max_bytes {
                break;
            }
            end = next;
        }
        end
    } else {
        // Not valid UTF-8: truncate at byte level
        max_bytes
    }
}

/// Write `data` to `w` with space-padding to reach `width`.
/// Zero-allocation for the common case where data.len() >= width.
fn write_padded(w: &mut impl Write, data: &[u8], flags: &FormatFlags, width: usize) {
    if width == 0 || data.len() >= width {
        let _ = w.write_all(data);
        return;
    }
    let pad_len = width - data.len();
    if flags.left_align {
        let _ = w.write_all(data);
        write_repeated(w, b' ', pad_len);
    } else {
        write_repeated(w, b' ', pad_len);
        let _ = w.write_all(data);
    }
}

/// Write a byte repeated `count` times using a stack buffer.
fn write_repeated(w: &mut impl Write, byte: u8, count: usize) {
    const BUF_SIZE: usize = 64;
    let buf = [byte; BUF_SIZE];
    let mut remaining = count;
    while remaining > 0 {
        let chunk = remaining.min(BUF_SIZE);
        let _ = w.write_all(&buf[..chunk]);
        remaining -= chunk;
    }
}

/// Write numeric format directly without heap allocation for common cases.
#[inline]
fn write_numeric_format(
    w: &mut impl Write,
    num_str: &str,
    _is_negative: bool,
    flags: &FormatFlags,
    width: usize,
    precision: Option<usize>,
) {
    write_numeric_format_with_prefix(w, "", num_str, flags, width, precision);
}

/// Format a u64 as octal into a stack buffer. Returns the formatted string slice.
fn format_octal(val: u64, buf: &mut [u8; 22]) -> &str {
    if val == 0 {
        return "0";
    }
    let mut pos = 22;
    let mut v = val;
    while v > 0 {
        pos -= 1;
        buf[pos] = b'0' + (v & 7) as u8;
        v >>= 3;
    }
    // SAFETY: we only wrote ASCII digits
    unsafe { std::str::from_utf8_unchecked(&buf[pos..]) }
}

/// Format a u64 as lowercase hex into a stack buffer. Returns the formatted string slice.
fn format_hex_lower(val: u64, buf: &mut [u8; 16]) -> &str {
    const HEX: &[u8; 16] = b"0123456789abcdef";
    if val == 0 {
        return "0";
    }
    let mut pos = 16;
    let mut v = val;
    while v > 0 {
        pos -= 1;
        buf[pos] = HEX[(v & 0xF) as usize];
        v >>= 4;
    }
    unsafe { std::str::from_utf8_unchecked(&buf[pos..]) }
}

/// Format a u64 as uppercase hex into a stack buffer. Returns the formatted string slice.
fn format_hex_upper(val: u64, buf: &mut [u8; 16]) -> &str {
    const HEX: &[u8; 16] = b"0123456789ABCDEF";
    if val == 0 {
        return "0";
    }
    let mut pos = 16;
    let mut v = val;
    while v > 0 {
        pos -= 1;
        buf[pos] = HEX[(v & 0xF) as usize];
        v >>= 4;
    }
    unsafe { std::str::from_utf8_unchecked(&buf[pos..]) }
}

/// Write numeric format with an optional prefix (e.g., "0x" for hex).
/// Handles sign, precision zero-padding, width, and flag-based padding directly
/// into the writer without heap allocation.
fn write_numeric_format_with_prefix(
    w: &mut impl Write,
    prefix: &str,
    num_str: &str,
    flags: &FormatFlags,
    width: usize,
    precision: Option<usize>,
) {
    // Separate sign from digits
    let (is_negative, raw_digits) = if let Some(rest) = num_str.strip_prefix('-') {
        (true, rest)
    } else {
        (false, num_str)
    };

    let sign: &str = if is_negative {
        "-"
    } else if flags.plus_sign {
        "+"
    } else if flags.space_sign {
        " "
    } else {
        ""
    };

    // Compute digits with precision
    let prec_pad = if let Some(prec) = precision {
        if prec == 0 && raw_digits == "0" {
            // Special case: precision 0 with value 0 → no digits
            // We'll handle this by setting raw_digits to empty
            // Can't reassign raw_digits, so we track it
            usize::MAX // sentinel for "suppress digits"
        } else if prec > raw_digits.len() {
            prec - raw_digits.len()
        } else {
            0
        }
    } else {
        0
    };

    let suppress_digits = prec_pad == usize::MAX;
    let actual_prec_pad = if suppress_digits { 0 } else { prec_pad };
    let digits_len = if suppress_digits { 0 } else { raw_digits.len() };

    let content_len = sign.len() + prefix.len() + actual_prec_pad + digits_len;

    if width > 0 && content_len < width {
        let pad_len = width - content_len;
        if flags.left_align {
            let _ = w.write_all(sign.as_bytes());
            let _ = w.write_all(prefix.as_bytes());
            write_repeated(w, b'0', actual_prec_pad);
            if !suppress_digits {
                let _ = w.write_all(raw_digits.as_bytes());
            }
            write_repeated(w, b' ', pad_len);
        } else if flags.zero_pad && precision.is_none() {
            let _ = w.write_all(sign.as_bytes());
            let _ = w.write_all(prefix.as_bytes());
            write_repeated(w, b'0', pad_len);
            if !suppress_digits {
                let _ = w.write_all(raw_digits.as_bytes());
            }
        } else {
            write_repeated(w, b' ', pad_len);
            let _ = w.write_all(sign.as_bytes());
            let _ = w.write_all(prefix.as_bytes());
            write_repeated(w, b'0', actual_prec_pad);
            if !suppress_digits {
                let _ = w.write_all(raw_digits.as_bytes());
            }
        }
    } else {
        let _ = w.write_all(sign.as_bytes());
        let _ = w.write_all(prefix.as_bytes());
        write_repeated(w, b'0', actual_prec_pad);
        if !suppress_digits {
            let _ = w.write_all(raw_digits.as_bytes());
        }
    }
}

/// Write float format directly to writer.
fn write_float_format(
    w: &mut impl Write,
    num_str: &str,
    _is_negative: bool,
    flags: &FormatFlags,
    width: usize,
) {
    let (sign_prefix, abs_str) = if let Some(rest) = num_str.strip_prefix('-') {
        ("-", rest)
    } else if flags.plus_sign {
        ("+", num_str)
    } else if flags.space_sign {
        (" ", num_str)
    } else {
        ("", num_str)
    };

    let content_len = sign_prefix.len() + abs_str.len();

    if width > 0 && content_len < width {
        let pad_len = width - content_len;
        if flags.left_align {
            let _ = w.write_all(sign_prefix.as_bytes());
            let _ = w.write_all(abs_str.as_bytes());
            write_repeated(w, b' ', pad_len);
        } else if flags.zero_pad {
            let _ = w.write_all(sign_prefix.as_bytes());
            write_repeated(w, b'0', pad_len);
            let _ = w.write_all(abs_str.as_bytes());
        } else {
            write_repeated(w, b' ', pad_len);
            let _ = w.write_all(sign_prefix.as_bytes());
            let _ = w.write_all(abs_str.as_bytes());
        }
    } else {
        let _ = w.write_all(sign_prefix.as_bytes());
        let _ = w.write_all(abs_str.as_bytes());
    }
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

    let factor = 10f64.powi(prec as i32);
    let mantissa = (mantissa * factor).round() / factor;

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
        let sig_prec = prec.saturating_sub(1);
        let s = format_scientific(value, sig_prec, e_char);
        trim_g_trailing_zeros(&s)
    } else {
        let decimal_prec = if prec as i32 > exp + 1 {
            (prec as i32 - exp - 1) as usize
        } else {
            0
        };
        let s = format!("{value:.decimal_prec$}");
        trim_g_trailing_zeros(&s)
    }
}

/// Shell-quote a string for %q format specifier (GNU printf compat).
/// Matches GNU coreutils quoting style (quotearg shell_escape_always_quoting_style):
/// - Empty string -> ''
/// - Safe chars only -> no quoting
/// - Has control/high bytes -> segment-based: 'safe'$'\t''safe'
/// - Has single quotes but no control -> double-quote: "it's"
/// - Otherwise -> single-quote: 'hello world'
fn shell_quote(s: &str) -> String {
    if s.is_empty() {
        return "''".to_string();
    }

    // Check if the string needs quoting at all.
    let needs_quoting = s.starts_with('~')
        || s.bytes().any(|b| {
            !b.is_ascii_alphanumeric()
                && b != b'_'
                && b != b'/'
                && b != b'.'
                && b != b'-'
                && b != b':'
                && b != b','
                && b != b'+'
                && b != b'@'
                && b != b'%'
                && b != b'='
                && b != b'^'
                && b != b'~'
        });

    if !needs_quoting {
        return s.to_string();
    }

    let has_control = s.bytes().any(|b| b < 0x20 || b == 0x7f || b >= 0x80);
    let has_single_quote = s.contains('\'');

    if has_control {
        // GNU uses segment-based quoting: 'safe'$'\t''safe'
        // GNU always starts in single-quote mode, so strings beginning with
        // a control char get an empty '' prefix: ''$'\t''hello'
        let mut result = String::new();
        let bytes = s.as_bytes();
        let mut i = 0;
        // Track whether we're at the start - if first char is control, emit ''
        let mut need_sq_start = true;

        while i < bytes.len() {
            if is_control_byte(bytes[i]) {
                if need_sq_start {
                    // Emit empty single-quote segment before first $'...'
                    result.push_str("''");
                    need_sq_start = false;
                }
                // Emit $'...' segment for consecutive control/high bytes
                result.push_str("$'");
                while i < bytes.len() && is_control_byte(bytes[i]) {
                    emit_escape(bytes[i], &mut result);
                    i += 1;
                }
                result.push('\'');
            } else {
                need_sq_start = false;
                // Emit '...' segment for consecutive safe bytes
                result.push('\'');
                while i < bytes.len() && !is_control_byte(bytes[i]) {
                    if bytes[i] == b'\'' {
                        // Close single quote, emit escaped quote, reopen
                        result.push_str("'\\'");
                    } else {
                        result.push(bytes[i] as char);
                    }
                    i += 1;
                }
                result.push('\'');
            }
        }
        result
    } else if !has_single_quote {
        format!("'{}'", s)
    } else {
        // Has single quotes but no control chars.
        let unsafe_for_dquote = s
            .bytes()
            .any(|b| b == b'$' || b == b'`' || b == b'\\' || b == b'!' || b == b'"');
        if !unsafe_for_dquote {
            format!("\"{}\"", s)
        } else {
            // Use '\'' escaping for single quotes within single-quoted segments
            let mut result = String::from("'");
            for byte in s.bytes() {
                if byte == b'\'' {
                    result.push_str("'\\''");
                } else {
                    result.push(byte as char);
                }
            }
            result.push('\'');
            result
        }
    }
}

fn is_control_byte(b: u8) -> bool {
    b < 0x20 || b == 0x7f || b >= 0x80
}

fn emit_escape(byte: u8, result: &mut String) {
    match byte {
        b'\n' => result.push_str("\\n"),
        b'\t' => result.push_str("\\t"),
        b'\r' => result.push_str("\\r"),
        0x07 => result.push_str("\\a"),
        0x08 => result.push_str("\\b"),
        0x0c => result.push_str("\\f"),
        0x0b => result.push_str("\\v"),
        0x1b => result.push_str("\\E"),
        b => {
            // Use stack-based formatting instead of format!()
            let d2 = b >> 6;
            let d1 = (b >> 3) & 7;
            let d0 = b & 7;
            result.push('\\');
            result.push((b'0' + d2) as char);
            result.push((b'0' + d1) as char);
            result.push((b'0' + d0) as char);
        }
    }
}

/// Trim trailing zeros from %g formatted output.
/// Only trims after a decimal point to avoid turning "100000" into "1".
fn trim_g_trailing_zeros(s: &str) -> String {
    if let Some(e_pos) = s.find(['e', 'E']) {
        let (mantissa, exponent) = s.split_at(e_pos);
        if mantissa.contains('.') {
            let trimmed = mantissa.trim_end_matches('0').trim_end_matches('.');
            format!("{trimmed}{exponent}")
        } else {
            s.to_string()
        }
    } else if s.contains('.') {
        s.trim_end_matches('0').trim_end_matches('.').to_string()
    } else {
        s.to_string()
    }
}
