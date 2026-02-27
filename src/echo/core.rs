/// Configuration for the echo command.
pub struct EchoConfig {
    /// Whether to append a trailing newline (true by default; `-n` disables it).
    pub trailing_newline: bool,
    /// Whether to interpret backslash escape sequences (`-e` enables, `-E` disables).
    pub interpret_escapes: bool,
}

impl Default for EchoConfig {
    fn default() -> Self {
        Self {
            trailing_newline: true,
            interpret_escapes: false,
        }
    }
}

/// Parse the raw command-line arguments (after the program name) into an
/// `EchoConfig` and the remaining text arguments.
///
/// GNU echo uses *manual* flag parsing: a leading argument is only treated as
/// flags if it starts with `-` and every subsequent character is one of `n`,
/// `e`, or `E`.  Combined flags like `-neE` are valid.  Anything else (e.g.
/// `-z`, `--foo`, or even `-`) is treated as a normal text argument.
///
/// When `POSIXLY_CORRECT` is set, escapes are always interpreted.
/// GNU coreutils 9.x: if the FIRST arg is exactly "-n", recognize it and
/// subsequent option-like args (including combined flags like -nE, -ne).
/// Only -n has effect (suppress newline); -e/-E are consumed but ignored
/// (escapes stay on). If the first arg is NOT "-n", no options recognized.
pub fn parse_echo_args(args: &[String]) -> (EchoConfig, &[String]) {
    // POSIXLY_CORRECT: escapes always interpreted
    if std::env::var_os("POSIXLY_CORRECT").is_some() {
        let mut config = EchoConfig {
            trailing_newline: true,
            interpret_escapes: true,
        };
        // Only recognize options if first arg is exactly "-n"
        if args.first().map(|s| s.as_str()) == Some("-n") {
            config.trailing_newline = false;
            let mut idx = 1;
            // Consume subsequent option-like args
            for arg in &args[1..] {
                let bytes = arg.as_bytes();
                if bytes.len() < 2 || bytes[0] != b'-' {
                    break;
                }
                let all_flags = bytes[1..]
                    .iter()
                    .all(|&b| b == b'n' || b == b'e' || b == b'E');
                if !all_flags {
                    break;
                }
                for &b in &bytes[1..] {
                    if b == b'n' {
                        config.trailing_newline = false;
                    }
                }
                idx += 1;
            }
            return (config, &args[idx..]);
        }
        return (config, args);
    }

    let mut config = EchoConfig::default();
    let mut idx = 0;

    for arg in args {
        let bytes = arg.as_bytes();
        // Must start with '-' and have at least one flag character
        if bytes.len() < 2 || bytes[0] != b'-' {
            break;
        }
        // Every character after '-' must be n, e, or E
        let all_flags = bytes[1..]
            .iter()
            .all(|&b| b == b'n' || b == b'e' || b == b'E');
        if !all_flags {
            break;
        }
        // Apply flags
        for &b in &bytes[1..] {
            match b {
                b'n' => config.trailing_newline = false,
                b'e' => config.interpret_escapes = true,
                b'E' => config.interpret_escapes = false,
                _ => unreachable!(),
            }
        }
        idx += 1;
    }

    (config, &args[idx..])
}

/// Produce the output bytes for an echo invocation.
///
/// The returned `Vec<u8>` contains exactly the bytes that should be written to
/// stdout (including or excluding the trailing newline, and with escape
/// sequences expanded when `config.interpret_escapes` is true).
pub fn echo_output(args: &[String], config: &EchoConfig) -> Vec<u8> {
    let mut out: Vec<u8> = Vec::new();

    for (i, arg) in args.iter().enumerate() {
        if i > 0 {
            out.push(b' ');
        }
        if config.interpret_escapes {
            if !expand_escapes(arg.as_bytes(), &mut out) {
                // \c encountered — stop all output immediately
                return out;
            }
        } else {
            out.extend_from_slice(arg.as_bytes());
        }
    }

    if config.trailing_newline {
        out.push(b'\n');
    }

    out
}

/// Expand backslash escape sequences in `src`, appending the result to `out`.
///
/// Returns `true` if all bytes were processed normally, or `false` if `\c`
/// was encountered (meaning output should stop immediately).
fn expand_escapes(src: &[u8], out: &mut Vec<u8>) -> bool {
    let len = src.len();
    let mut i = 0;

    while i < len {
        if src[i] != b'\\' {
            out.push(src[i]);
            i += 1;
            continue;
        }

        // We have a backslash — look at the next character
        i += 1;
        if i >= len {
            // Trailing backslash with nothing after — output it literally
            out.push(b'\\');
            break;
        }

        match src[i] {
            b'\\' => out.push(b'\\'),
            b'a' => out.push(0x07),
            b'b' => out.push(0x08),
            b'c' => return false, // stop output
            b'e' => out.push(0x1B),
            b'f' => out.push(0x0C),
            b'n' => out.push(b'\n'),
            b'r' => out.push(b'\r'),
            b't' => out.push(b'\t'),
            b'v' => out.push(0x0B),
            b'0' => {
                // \0NNN — octal with \0 prefix (up to 3 more octal digits)
                // GNU echo treats \0 as a prefix: read up to 3 MORE digits
                let mut val: u16 = 0;
                let mut consumed = 0;
                let mut j = i + 1;
                while j < len && consumed < 3 && src[j] >= b'0' && src[j] <= b'7' {
                    val = val * 8 + (src[j] - b'0') as u16;
                    j += 1;
                    consumed += 1;
                }
                out.push(val as u8);
                i = j - 1; // will be incremented at end of loop
            }
            b'1'..=b'7' => {
                // \NNN — octal (up to 3 total digits including the first)
                let first = src[i] - b'0';
                let mut val = first as u16;
                let mut consumed = 0;
                let mut j = i + 1;
                while j < len && consumed < 2 && src[j] >= b'0' && src[j] <= b'7' {
                    val = val * 8 + (src[j] - b'0') as u16;
                    j += 1;
                    consumed += 1;
                }
                out.push(val as u8);
                i = j - 1; // will be incremented at end of loop
            }
            b'x' => {
                // \xHH — hexadecimal (up to 2 hex digits)
                let start = i + 1;
                let mut end = start;
                while end < len && end < start + 2 && is_hex_digit(src[end]) {
                    end += 1;
                }
                if start == end {
                    // No hex digits: output \x literally
                    out.push(b'\\');
                    out.push(b'x');
                } else {
                    out.push(parse_hex(&src[start..end]));
                    i = end - 1; // will be incremented at end of loop
                }
            }
            other => {
                // Unknown escape — output the backslash and the character literally
                out.push(b'\\');
                out.push(other);
            }
        }
        i += 1;
    }

    true
}

#[inline]
fn is_hex_digit(b: u8) -> bool {
    b.is_ascii_hexdigit()
}

fn parse_hex(digits: &[u8]) -> u8 {
    let mut val: u8 = 0;
    for &d in digits {
        let nibble = match d {
            b'0'..=b'9' => d - b'0',
            b'a'..=b'f' => d - b'a' + 10,
            b'A'..=b'F' => d - b'A' + 10,
            _ => unreachable!(),
        };
        val = val * 16 + nibble;
    }
    val
}
