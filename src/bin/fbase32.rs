// fbase32 — Base32 encode/decode data (GNU base32 replacement, RFC 4648)

use std::io::{self, Read, Write};
use std::process;

/// Write buffer directly to fd 1, bypassing BufWriter overhead.
#[cfg(unix)]
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

#[cfg(not(unix))]
fn write_all_fd1(buf: &[u8]) -> bool {
    use std::io::Write;
    std::io::stdout().lock().write_all(buf).is_ok()
}

const TOOL_NAME: &str = "base32";
const VERSION: &str = env!("CARGO_PKG_VERSION");

/// Base32 alphabet per RFC 4648
const BASE32_ALPHABET: &[u8; 32] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";

/// Build a decoding table: maps ASCII byte -> 5-bit value (0-31), 0xFF for invalid.
const fn build_decode_table() -> [u8; 256] {
    let mut table = [0xFFu8; 256];
    let alpha = b"ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";
    let mut i = 0;
    while i < 32 {
        table[alpha[i] as usize] = i as u8;
        // Also accept lowercase
        if alpha[i] >= b'A' && alpha[i] <= b'Z' {
            table[(alpha[i] - b'A' + b'a') as usize] = i as u8;
        }
        i += 1;
    }
    table
}

const DECODE_TABLE: [u8; 256] = build_decode_table();

struct Cli {
    decode: bool,
    ignore_garbage: bool,
    wrap: usize,
    file: Option<String>,
}

fn parse_args() -> Cli {
    let mut cli = Cli {
        decode: false,
        ignore_garbage: false,
        wrap: 76,
        file: None,
    };

    let mut args = std::env::args_os().skip(1);
    #[allow(clippy::while_let_on_iterator)]
    while let Some(arg) = args.next() {
        let bytes = arg.as_encoded_bytes();
        if bytes == b"--" {
            if let Some(f) = args.next() {
                cli.file = Some(f.to_string_lossy().into_owned());
            }
            break;
        }
        if bytes.starts_with(b"--") {
            if bytes.starts_with(b"--wrap=") {
                let val = std::str::from_utf8(&bytes[7..]).unwrap_or("76");
                cli.wrap = val.parse().unwrap_or_else(|_| {
                    eprintln!("{}: invalid wrap size: '{}'", TOOL_NAME, val);
                    process::exit(1);
                });
            } else {
                match bytes {
                    b"--decode" => cli.decode = true,
                    b"--ignore-garbage" => cli.ignore_garbage = true,
                    b"--wrap" => {
                        if let Some(v) = args.next() {
                            let s = v.to_string_lossy();
                            cli.wrap = s.parse().unwrap_or_else(|_| {
                                eprintln!("{}: invalid wrap size: '{}'", TOOL_NAME, s);
                                process::exit(1);
                            });
                        } else {
                            eprintln!("{}: option '--wrap' requires an argument", TOOL_NAME);
                            process::exit(1);
                        }
                    }
                    b"--help" => {
                        print!(
                            "Usage: {tool} [OPTION]... [FILE]\n\
                             Base32 encode or decode FILE, or standard input, to standard output.\n\n\
                             With no FILE, or when FILE is -, read standard input.\n\n\
                             Mandatory arguments to long options are mandatory for short options too.\n\
                             \x20 -d, --decode          decode data\n\
                             \x20 -i, --ignore-garbage  when decoding, ignore non-alphabet characters\n\
                             \x20 -w, --wrap=COLS       wrap encoded lines after COLS character (default 76).\n\
                             \x20                         Use 0 to disable line wrapping\n\
                             \x20     --help             display this help and exit\n\
                             \x20     --version          output version information and exit\n\n\
                             The data are encoded as described for the base32 alphabet in RFC 4648.\n\
                             When decoding, the input may contain newlines in addition to the bytes of\n\
                             the formal base32 alphabet.  Use --ignore-garbage to attempt to recover\n\
                             from any other non-alphabet bytes in the encoded stream.\n",
                            tool = TOOL_NAME
                        );
                        process::exit(0);
                    }
                    b"--version" => {
                        println!("{} (fcoreutils) {}", TOOL_NAME, VERSION);
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
            }
        } else if bytes.len() > 1 && bytes[0] == b'-' {
            let mut i = 1;
            while i < bytes.len() {
                match bytes[i] {
                    b'd' => cli.decode = true,
                    b'i' => cli.ignore_garbage = true,
                    b'w' => {
                        if i + 1 < bytes.len() {
                            let val = std::str::from_utf8(&bytes[i + 1..]).unwrap_or("76");
                            cli.wrap = val.parse().unwrap_or_else(|_| {
                                eprintln!("{}: invalid wrap size: '{}'", TOOL_NAME, val);
                                process::exit(1);
                            });
                            i = bytes.len();
                            continue;
                        } else if let Some(v) = args.next() {
                            let s = v.to_string_lossy();
                            cli.wrap = s.parse().unwrap_or_else(|_| {
                                eprintln!("{}: invalid wrap size: '{}'", TOOL_NAME, s);
                                process::exit(1);
                            });
                        } else {
                            eprintln!("{}: option requires an argument -- 'w'", TOOL_NAME);
                            process::exit(1);
                        }
                    }
                    _ => {
                        eprintln!("{}: invalid option -- '{}'", TOOL_NAME, bytes[i] as char);
                        eprintln!("Try '{} --help' for more information.", TOOL_NAME);
                        process::exit(1);
                    }
                }
                i += 1;
            }
        } else {
            cli.file = Some(arg.to_string_lossy().into_owned());
        }
    }

    cli
}

/// Encode binary data to Base32 bytes (used only by tests; streaming path uses encode_5_to_8).
#[cfg(test)]
fn base32_encode(data: &[u8]) -> Vec<u8> {
    if data.is_empty() {
        return Vec::new();
    }

    let out_len = data.len().div_ceil(5) * 8;
    let mut result = Vec::with_capacity(out_len);

    let full_chunks = data.len() / 5;
    let remainder = data.len() % 5;

    // Process all full 5-byte chunks without branch overhead
    let full_end = full_chunks * 5;
    let full_data = &data[..full_end];
    for chunk in full_data.chunks_exact(5) {
        let b0 = chunk[0];
        let b1 = chunk[1];
        let b2 = chunk[2];
        let b3 = chunk[3];
        let b4 = chunk[4];

        result.extend_from_slice(&[
            BASE32_ALPHABET[(b0 >> 3) as usize],
            BASE32_ALPHABET[((b0 & 0x07) << 2 | b1 >> 6) as usize],
            BASE32_ALPHABET[((b1 >> 1) & 0x1F) as usize],
            BASE32_ALPHABET[((b1 & 0x01) << 4 | b2 >> 4) as usize],
            BASE32_ALPHABET[((b2 & 0x0F) << 1 | b3 >> 7) as usize],
            BASE32_ALPHABET[((b3 >> 2) & 0x1F) as usize],
            BASE32_ALPHABET[((b3 & 0x03) << 3 | b4 >> 5) as usize],
            BASE32_ALPHABET[(b4 & 0x1F) as usize],
        ]);
    }

    // Handle the last partial chunk with padding
    if remainder > 0 {
        let chunk = &data[full_end..];
        let mut buf = [0u8; 5];
        buf[..chunk.len()].copy_from_slice(chunk);
        let b0 = buf[0];
        let b1 = buf[1];
        let b2 = buf[2];
        let b3 = buf[3];
        let b4 = buf[4];

        result.push(BASE32_ALPHABET[(b0 >> 3) as usize]);
        result.push(BASE32_ALPHABET[((b0 & 0x07) << 2 | b1 >> 6) as usize]);
        match remainder {
            1 => result.extend_from_slice(b"======"),
            2 => {
                result.push(BASE32_ALPHABET[((b1 >> 1) & 0x1F) as usize]);
                result.push(BASE32_ALPHABET[((b1 & 0x01) << 4 | b2 >> 4) as usize]);
                result.extend_from_slice(b"====");
            }
            3 => {
                result.push(BASE32_ALPHABET[((b1 >> 1) & 0x1F) as usize]);
                result.push(BASE32_ALPHABET[((b1 & 0x01) << 4 | b2 >> 4) as usize]);
                result.push(BASE32_ALPHABET[((b2 & 0x0F) << 1 | b3 >> 7) as usize]);
                result.extend_from_slice(b"===");
            }
            4 => {
                result.push(BASE32_ALPHABET[((b1 >> 1) & 0x1F) as usize]);
                result.push(BASE32_ALPHABET[((b1 & 0x01) << 4 | b2 >> 4) as usize]);
                result.push(BASE32_ALPHABET[((b2 & 0x0F) << 1 | b3 >> 7) as usize]);
                result.push(BASE32_ALPHABET[((b3 >> 2) & 0x1F) as usize]);
                result.push(BASE32_ALPHABET[((b3 & 0x03) << 3 | b4 >> 5) as usize]);
                result.push(b'=');
            }
            _ => unreachable!(),
        }
    }

    result
}

/// Decode Base32 string back to binary data.
/// Single-pass fused filter+decode with 8-byte-at-a-time fast path.
fn base32_decode(input: &[u8], ignore_garbage: bool) -> Result<Vec<u8>, String> {
    let mut result = Vec::with_capacity(input.len() * 5 / 8 + 5);
    let mut vals = [0u8; 8];
    let mut n = 0usize; // valid (non-padding) chars in current group
    let mut pos = 0usize; // total position in group (valid + padding)
    let mut i = 0usize;

    while i < input.len() {
        // Fast path: when starting a new group, try to decode 8 valid chars at once
        if pos == 0 && i + 8 <= input.len() {
            let chunk = &input[i..i + 8];
            let v0 = DECODE_TABLE[chunk[0] as usize];
            let v1 = DECODE_TABLE[chunk[1] as usize];
            let v2 = DECODE_TABLE[chunk[2] as usize];
            let v3 = DECODE_TABLE[chunk[3] as usize];
            let v4 = DECODE_TABLE[chunk[4] as usize];
            let v5 = DECODE_TABLE[chunk[5] as usize];
            let v6 = DECODE_TABLE[chunk[6] as usize];
            let v7 = DECODE_TABLE[chunk[7] as usize];

            if (v0 | v1 | v2 | v3 | v4 | v5 | v6 | v7) <= 0x1F {
                result.extend_from_slice(&[
                    (v0 << 3) | (v1 >> 2),
                    (v1 << 6) | (v2 << 1) | (v3 >> 4),
                    (v3 << 4) | (v4 >> 1),
                    (v4 << 7) | (v5 << 2) | (v6 >> 3),
                    (v6 << 5) | v7,
                ]);
                i += 8;
                continue;
            }
        }

        // Slow path: process byte by byte
        let b = input[i];
        i += 1;

        if b == b'\n' || b == b'\r' {
            continue;
        }
        if b == b'=' {
            pos += 1;
            if pos == 8 {
                if n >= 2 {
                    result.push((vals[0] << 3) | (vals[1] >> 2));
                }
                if n >= 4 {
                    result.push((vals[1] << 6) | (vals[2] << 1) | (vals[3] >> 4));
                }
                if n >= 5 {
                    result.push((vals[3] << 4) | (vals[4] >> 1));
                }
                if n >= 7 {
                    result.push((vals[4] << 7) | (vals[5] << 2) | (vals[6] >> 3));
                }
                n = 0;
                pos = 0;
            }
            continue;
        }
        let v = DECODE_TABLE[b as usize];
        if v == 0xFF {
            if !ignore_garbage {
                return Err(format!("{}: invalid input", TOOL_NAME));
            }
            continue;
        }
        vals[pos] = v;
        n += 1;
        pos += 1;
        if pos == 8 {
            result.extend_from_slice(&[
                (vals[0] << 3) | (vals[1] >> 2),
                (vals[1] << 6) | (vals[2] << 1) | (vals[3] >> 4),
                (vals[3] << 4) | (vals[4] >> 1),
                (vals[4] << 7) | (vals[5] << 2) | (vals[6] >> 3),
                (vals[6] << 5) | vals[7],
            ]);
            n = 0;
            pos = 0;
        }
    }

    // Trailing partial group
    if n >= 2 {
        result.push((vals[0] << 3) | (vals[1] >> 2));
    }
    if n >= 4 {
        result.push((vals[1] << 6) | (vals[2] << 1) | (vals[3] >> 4));
    }
    if n >= 5 {
        result.push((vals[3] << 4) | (vals[4] >> 1));
    }
    if n >= 7 {
        result.push((vals[4] << 7) | (vals[5] << 2) | (vals[6] >> 3));
    }
    if n >= 8 {
        result.push((vals[6] << 5) | vals[7]);
    }

    Ok(result)
}

/// Encode 5 bytes into 8 base32 characters directly into output buffer.
/// Returns 8 (bytes written). Caller must ensure `out` has at least 8 bytes.
#[inline(always)]
fn encode_5_to_8(b0: u8, b1: u8, b2: u8, b3: u8, b4: u8, out: &mut [u8]) {
    out[0] = BASE32_ALPHABET[(b0 >> 3) as usize];
    out[1] = BASE32_ALPHABET[((b0 & 0x07) << 2 | b1 >> 6) as usize];
    out[2] = BASE32_ALPHABET[((b1 >> 1) & 0x1F) as usize];
    out[3] = BASE32_ALPHABET[((b1 & 0x01) << 4 | b2 >> 4) as usize];
    out[4] = BASE32_ALPHABET[((b2 & 0x0F) << 1 | b3 >> 7) as usize];
    out[5] = BASE32_ALPHABET[((b3 >> 2) & 0x1F) as usize];
    out[6] = BASE32_ALPHABET[((b3 & 0x03) << 3 | b4 >> 5) as usize];
    out[7] = BASE32_ALPHABET[(b4 & 0x1F) as usize];
}

/// Encode and write with line wrapping using raw fd1 writes.
/// Two-phase approach: batch-encode raw base32 chars, then insert newlines.
/// Eliminates per-5-byte copy_with_wrap overhead (was 2M calls for 10MB).
fn encode_streaming(data: &[u8], wrap: usize) -> io::Result<()> {
    if data.is_empty() {
        return Ok(());
    }

    let full_chunks = data.len() / 5;
    let remainder = data.len() % 5;
    let full_end = full_chunks * 5;

    // Process in 256KB input batches to bound memory
    const BATCH_INPUT: usize = 256 * 1024;
    // Align batch to 5 bytes
    let batch_input = BATCH_INPUT / 5 * 5;
    // Output per batch: batch_input/5*8 raw + batch_input/5*8/wrap newlines + margin
    let batch_output_raw = batch_input / 5 * 8;
    let batch_output_wrapped = if wrap > 0 {
        batch_output_raw + batch_output_raw / wrap + 16
    } else {
        batch_output_raw + 16
    };
    let mut raw_buf = vec![0u8; batch_output_raw + 16];
    let mut wrap_buf = if wrap > 0 {
        vec![0u8; batch_output_wrapped]
    } else {
        Vec::new()
    };
    let mut col = 0usize;

    let mut input_pos = 0usize;
    while input_pos < full_end {
        let batch_end = (input_pos + batch_input).min(full_end);
        let batch = &data[input_pos..batch_end];

        // Encode batch into raw_buf
        let mut raw_offset = 0usize;
        for chunk in batch.chunks_exact(5) {
            encode_5_to_8(
                chunk[0],
                chunk[1],
                chunk[2],
                chunk[3],
                chunk[4],
                &mut raw_buf[raw_offset..],
            );
            raw_offset += 8;
        }

        if wrap == 0 {
            if !write_all_fd1(&raw_buf[..raw_offset]) {
                return Ok(());
            }
        } else {
            // Insert newlines in a single pass
            let written = insert_newlines(&raw_buf[..raw_offset], &mut wrap_buf, wrap, &mut col);
            if !write_all_fd1(&wrap_buf[..written]) {
                return Ok(());
            }
        }
        input_pos = batch_end;
    }

    // Handle the last partial chunk with padding
    if remainder > 0 {
        let chunk = &data[full_end..];
        let mut padded = [0u8; 5];
        padded[..chunk.len()].copy_from_slice(chunk);
        let (b0, b1, b2, b3, b4) = (padded[0], padded[1], padded[2], padded[3], padded[4]);

        let mut partial = [b'='; 8];
        partial[0] = BASE32_ALPHABET[(b0 >> 3) as usize];
        partial[1] = BASE32_ALPHABET[((b0 & 0x07) << 2 | b1 >> 6) as usize];
        if remainder >= 2 {
            partial[2] = BASE32_ALPHABET[((b1 >> 1) & 0x1F) as usize];
            partial[3] = BASE32_ALPHABET[((b1 & 0x01) << 4 | b2 >> 4) as usize];
        }
        if remainder >= 3 {
            partial[4] = BASE32_ALPHABET[((b2 & 0x0F) << 1 | b3 >> 7) as usize];
        }
        if remainder >= 4 {
            partial[5] = BASE32_ALPHABET[((b3 >> 2) & 0x1F) as usize];
            partial[6] = BASE32_ALPHABET[((b3 & 0x03) << 3 | b4 >> 5) as usize];
        }

        if wrap == 0 {
            write_all_fd1(&partial);
        } else {
            let mut tail_buf = [0u8; 24]; // 8 chars + possible newline + margin
            let written = insert_newlines(&partial, &mut tail_buf, wrap, &mut col);
            write_all_fd1(&tail_buf[..written]);
        }
    }

    // Final newline if there's a partial line
    if wrap > 0 && col > 0 {
        write_all_fd1(b"\n");
    }

    Ok(())
}

/// Insert newlines into raw encoded data at `wrap` column boundaries.
/// Single pass: copies chunks of (wrap - col) bytes, inserting \n between.
/// Returns number of bytes written to `out`.
#[inline]
fn insert_newlines(raw: &[u8], out: &mut [u8], wrap: usize, col: &mut usize) -> usize {
    let mut ri = 0usize;
    let mut wi = 0usize;

    while ri < raw.len() {
        let space = wrap - *col;
        let available = raw.len() - ri;
        let to_copy = space.min(available);
        out[wi..wi + to_copy].copy_from_slice(&raw[ri..ri + to_copy]);
        wi += to_copy;
        ri += to_copy;
        *col += to_copy;
        if *col == wrap {
            out[wi] = b'\n';
            wi += 1;
            *col = 0;
        }
    }
    wi
}

fn main() {
    coreutils_rs::common::reset_sigpipe();

    let cli = parse_args();
    let filename = cli.file.as_deref().unwrap_or("-");

    let data = if filename == "-" {
        let mut buf = Vec::new();
        if let Err(e) = io::stdin().lock().read_to_end(&mut buf) {
            eprintln!("{}: {}", TOOL_NAME, coreutils_rs::common::io_error_msg(&e));
            process::exit(1);
        }
        buf
    } else {
        match std::fs::read(filename) {
            Ok(d) => d,
            Err(e) => {
                eprintln!(
                    "{}: {}: {}",
                    TOOL_NAME,
                    filename,
                    coreutils_rs::common::io_error_msg(&e)
                );
                process::exit(1);
            }
        }
    };

    let stdout = io::stdout();
    let mut out = io::BufWriter::with_capacity(1024 * 1024, stdout.lock());

    if cli.decode {
        match base32_decode(&data, cli.ignore_garbage) {
            Ok(decoded) => {
                if let Err(e) = out.write_all(&decoded) {
                    if e.kind() == io::ErrorKind::BrokenPipe {
                        process::exit(0);
                    }
                    eprintln!("{}: write error: {}", TOOL_NAME, e);
                    process::exit(1);
                }
            }
            Err(msg) => {
                eprintln!("{}", msg);
                process::exit(1);
            }
        }
    } else {
        if let Err(e) = encode_streaming(&data, cli.wrap) {
            if e.kind() == io::ErrorKind::BrokenPipe {
                process::exit(0);
            }
            eprintln!("{}: write error: {}", TOOL_NAME, e);
            process::exit(1);
        }
        return;
    }

    if let Err(e) = out.flush()
        && e.kind() != io::ErrorKind::BrokenPipe
    {
        eprintln!("{}: write error: {}", TOOL_NAME, e);
        process::exit(1);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;
    use std::process::Command;

    fn cmd() -> Command {
        let mut path = std::env::current_exe().unwrap();
        path.pop();
        path.pop();
        path.push("fbase32");
        Command::new(path)
    }

    #[test]
    fn test_help() {
        let output = cmd().arg("--help").output().unwrap();
        assert!(output.status.success());
        let stdout = String::from_utf8_lossy(&output.stdout);
        assert!(stdout.contains("Usage:"));
        assert!(stdout.contains("--decode"));
    }

    #[test]
    fn test_version() {
        let output = cmd().arg("--version").output().unwrap();
        assert!(output.status.success());
        let stdout = String::from_utf8_lossy(&output.stdout);
        assert!(stdout.contains("base32"));
        assert!(stdout.contains("fcoreutils"));
    }

    #[test]
    fn test_encode_hello() {
        // "Hello" in base32 is "JBSWY3DP"
        let mut child = cmd()
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::piped())
            .spawn()
            .unwrap();
        child.stdin.take().unwrap().write_all(b"Hello").unwrap();
        let output = child.wait_with_output().unwrap();
        assert!(output.status.success());
        let stdout = String::from_utf8_lossy(&output.stdout);
        assert_eq!(stdout.trim(), "JBSWY3DP");
    }

    #[test]
    fn test_encode_hello_newline() {
        // "Hello\n" in base32 is "JBSWY3DPBI======"
        let mut child = cmd()
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::piped())
            .spawn()
            .unwrap();
        child.stdin.take().unwrap().write_all(b"Hello\n").unwrap();
        let output = child.wait_with_output().unwrap();
        assert!(output.status.success());
        let stdout = String::from_utf8_lossy(&output.stdout);
        assert_eq!(stdout.trim(), "JBSWY3DPBI======");
    }

    #[test]
    fn test_decode() {
        let mut child = cmd()
            .arg("-d")
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::piped())
            .spawn()
            .unwrap();
        child
            .stdin
            .take()
            .unwrap()
            .write_all(b"JBSWY3DP\n")
            .unwrap();
        let output = child.wait_with_output().unwrap();
        assert!(output.status.success());
        assert_eq!(&output.stdout, b"Hello");
    }

    #[test]
    fn test_roundtrip() {
        let input = b"The quick brown fox jumps over the lazy dog";

        // Encode
        let mut child = cmd()
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::piped())
            .spawn()
            .unwrap();
        child.stdin.take().unwrap().write_all(input).unwrap();
        let encode_output = child.wait_with_output().unwrap();
        assert!(encode_output.status.success());

        // Decode
        let mut child = cmd()
            .arg("-d")
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::piped())
            .spawn()
            .unwrap();
        child
            .stdin
            .take()
            .unwrap()
            .write_all(&encode_output.stdout)
            .unwrap();
        let decode_output = child.wait_with_output().unwrap();
        assert!(decode_output.status.success());
        assert_eq!(&decode_output.stdout, input);
    }

    #[test]
    fn test_wrap_flag() {
        // Test -w 10 wraps at 10 columns
        let mut child = cmd()
            .arg("-w")
            .arg("10")
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::piped())
            .spawn()
            .unwrap();
        child
            .stdin
            .take()
            .unwrap()
            .write_all(b"Hello, World!")
            .unwrap();
        let output = child.wait_with_output().unwrap();
        assert!(output.status.success());
        let stdout = String::from_utf8_lossy(&output.stdout);
        for line in stdout.lines() {
            assert!(line.len() <= 10, "line longer than 10: {}", line);
        }
    }

    #[test]
    fn test_wrap_zero() {
        // -w 0 disables wrapping
        let mut child = cmd()
            .arg("-w")
            .arg("0")
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::piped())
            .spawn()
            .unwrap();
        child
            .stdin
            .take()
            .unwrap()
            .write_all(b"Hello, World! This is a longer test input to verify no wrapping.")
            .unwrap();
        let output = child.wait_with_output().unwrap();
        assert!(output.status.success());
        let stdout = String::from_utf8_lossy(&output.stdout);
        let lines: Vec<&str> = stdout.lines().collect();
        assert_eq!(lines.len(), 1, "should be a single line with -w 0");
    }

    #[test]
    fn test_ignore_garbage() {
        // -i should ignore garbage characters during decode
        let mut child = cmd()
            .arg("-d")
            .arg("-i")
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::piped())
            .spawn()
            .unwrap();
        // Insert garbage characters in base32 encoded "Hello"
        child
            .stdin
            .take()
            .unwrap()
            .write_all(b"JB!!S##WY3DP\n")
            .unwrap();
        let output = child.wait_with_output().unwrap();
        assert!(output.status.success());
        assert_eq!(&output.stdout, b"Hello");
    }

    #[test]
    fn test_empty_input() {
        let mut child = cmd()
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::piped())
            .spawn()
            .unwrap();
        child.stdin.take().unwrap().write_all(b"").unwrap();
        let output = child.wait_with_output().unwrap();
        assert!(output.status.success());
        assert!(output.stdout.is_empty());
    }

    #[test]
    fn test_encode_lib_function() {
        // Unit test encode directly
        assert_eq!(base32_encode(b""), b"");
        assert_eq!(base32_encode(b"f"), b"MY======");
        assert_eq!(base32_encode(b"fo"), b"MZXQ====");
        assert_eq!(base32_encode(b"foo"), b"MZXW6===");
        assert_eq!(base32_encode(b"foob"), b"MZXW6YQ=");
        assert_eq!(base32_encode(b"fooba"), b"MZXW6YTB");
        assert_eq!(base32_encode(b"foobar"), b"MZXW6YTBOI======");
    }

    #[test]
    fn test_decode_lib_function() {
        assert_eq!(base32_decode(b"", false).unwrap(), b"");
        assert_eq!(base32_decode(b"MY======", false).unwrap(), b"f");
        assert_eq!(base32_decode(b"MZXQ====", false).unwrap(), b"fo");
        assert_eq!(base32_decode(b"MZXW6===", false).unwrap(), b"foo");
        assert_eq!(base32_decode(b"MZXW6YQ=", false).unwrap(), b"foob");
        assert_eq!(base32_decode(b"MZXW6YTB", false).unwrap(), b"fooba");
        assert_eq!(
            base32_decode(b"MZXW6YTBOI======", false).unwrap(),
            b"foobar"
        );
    }

    #[test]
    fn test_compare_gnu_base32_encode() {
        if Command::new("base32").arg("--version").output().is_err() {
            return;
        }
        let input = b"Hello, World!\n";

        let mut gnu_child = match Command::new("base32")
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::piped())
            .spawn()
        {
            Ok(c) => c,
            Err(_) => return,
        };
        gnu_child.stdin.take().unwrap().write_all(input).unwrap();
        let gnu_out = gnu_child.wait_with_output().unwrap();

        let mut our_child = cmd()
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::piped())
            .spawn()
            .unwrap();
        our_child.stdin.take().unwrap().write_all(input).unwrap();
        let our_out = our_child.wait_with_output().unwrap();
        assert_eq!(
            String::from_utf8_lossy(&our_out.stdout),
            String::from_utf8_lossy(&gnu_out.stdout),
            "Encoding mismatch with GNU base32"
        );
    }

    #[test]
    fn test_compare_gnu_base32_decode() {
        if Command::new("base32").arg("--version").output().is_err() {
            return;
        }
        let encoded = b"JBSWY3DPEHPK3PXP\n";

        let mut gnu_child = match Command::new("base32")
            .arg("-d")
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::piped())
            .spawn()
        {
            Ok(c) => c,
            Err(_) => return,
        };
        gnu_child.stdin.take().unwrap().write_all(encoded).unwrap();
        let gnu_out = gnu_child.wait_with_output().unwrap();

        let mut our_child = cmd()
            .arg("-d")
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::piped())
            .spawn()
            .unwrap();
        our_child.stdin.take().unwrap().write_all(encoded).unwrap();
        let our_out = our_child.wait_with_output().unwrap();
        assert_eq!(
            our_out.stdout, gnu_out.stdout,
            "Decoding mismatch with GNU base32"
        );
    }

    #[test]
    fn test_long_decode_flag() {
        let mut child = cmd()
            .arg("--decode")
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::piped())
            .spawn()
            .unwrap();
        child
            .stdin
            .take()
            .unwrap()
            .write_all(b"JBSWY3DP\n")
            .unwrap();
        let output = child.wait_with_output().unwrap();
        assert!(output.status.success());
        assert_eq!(&output.stdout, b"Hello");
    }

    #[test]
    fn test_binary_roundtrip() {
        let data: Vec<u8> = (0..=255).collect();
        let mut enc = cmd()
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::piped())
            .spawn()
            .unwrap();
        enc.stdin.take().unwrap().write_all(&data).unwrap();
        let encoded = enc.wait_with_output().unwrap();
        assert!(encoded.status.success());

        let mut dec = cmd()
            .arg("-d")
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::piped())
            .spawn()
            .unwrap();
        dec.stdin
            .take()
            .unwrap()
            .write_all(&encoded.stdout)
            .unwrap();
        let decoded = dec.wait_with_output().unwrap();
        assert!(decoded.status.success());
        assert_eq!(decoded.stdout, data);
    }

    #[test]
    fn test_decode_invalid_input() {
        let mut child = cmd()
            .arg("-d")
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::piped())
            .spawn()
            .unwrap();
        child
            .stdin
            .take()
            .unwrap()
            .write_all(b"!!!INVALID!!!\n")
            .unwrap();
        let output = child.wait_with_output().unwrap();
        assert!(!output.status.success());
    }

    #[test]
    fn test_file_input() {
        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join("test.txt");
        std::fs::write(&file, "Hello").unwrap();
        let output = cmd().arg(file.to_str().unwrap()).output().unwrap();
        assert!(output.status.success());
        let stdout = String::from_utf8_lossy(&output.stdout);
        assert_eq!(stdout.trim(), "JBSWY3DP");
    }

    #[test]
    fn test_invalid_option() {
        let output = cmd().arg("--invalid").output().unwrap();
        assert!(!output.status.success());
    }

    #[test]
    fn test_nonexistent_file() {
        let output = cmd().arg("/nonexistent/file.txt").output().unwrap();
        assert!(!output.status.success());
    }

    #[test]
    fn test_rfc4648_vectors() {
        let test_cases: &[(&[u8], &str)] = &[
            (b"", ""),
            (b"f", "MY======"),
            (b"fo", "MZXQ===="),
            (b"foo", "MZXW6==="),
            (b"foob", "MZXW6YQ="),
            (b"fooba", "MZXW6YTB"),
            (b"foobar", "MZXW6YTBOI======"),
        ];
        for (input, expected) in test_cases {
            let mut child = cmd()
                .stdin(std::process::Stdio::piped())
                .stdout(std::process::Stdio::piped())
                .spawn()
                .unwrap();
            child.stdin.take().unwrap().write_all(input).unwrap();
            let output = child.wait_with_output().unwrap();
            assert!(output.status.success());
            assert_eq!(
                String::from_utf8_lossy(&output.stdout).trim(),
                *expected,
                "mismatch for {:?}",
                String::from_utf8_lossy(input)
            );
        }
    }
}
