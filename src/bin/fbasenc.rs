// fbasenc — encode/decode data in various encodings (GNU basenc replacement)

use std::io::{self, Read, Write};
use std::process;

use base64_simd::AsOut;

const TOOL_NAME: &str = "basenc";
const VERSION: &str = env!("CARGO_PKG_VERSION");

/// SIMD-accelerated base64 engine (standard alphabet with padding).
const B64_STANDARD: &base64_simd::Base64 = &base64_simd::STANDARD;
/// SIMD-accelerated base64 engine (URL-safe alphabet with padding).
const B64_URL_SAFE: &base64_simd::Base64 = &base64_simd::URL_SAFE;

/// Raw stdin reader for zero-overhead pipe reads on Linux.
/// Bypasses Rust's StdinLock (mutex + 8KB BufReader) for direct libc::read(0).
#[cfg(target_os = "linux")]
struct RawStdin;

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

#[derive(Clone, Copy, PartialEq)]
enum Encoding {
    Base64,
    Base64Url,
    Base32,
    Base32Hex,
    Base16,
    Base2Msbf,
    Base2Lsbf,
    Z85,
}

struct Cli {
    encoding: Option<Encoding>,
    decode: bool,
    ignore_garbage: bool,
    wrap: usize,
    file: Option<String>,
}

fn parse_args() -> Cli {
    let mut cli = Cli {
        encoding: None,
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
                    b"--base64" => cli.encoding = Some(Encoding::Base64),
                    b"--base64url" => cli.encoding = Some(Encoding::Base64Url),
                    b"--base32" => cli.encoding = Some(Encoding::Base32),
                    b"--base32hex" => cli.encoding = Some(Encoding::Base32Hex),
                    b"--base16" => cli.encoding = Some(Encoding::Base16),
                    b"--base2msbf" => cli.encoding = Some(Encoding::Base2Msbf),
                    b"--base2lsbf" => cli.encoding = Some(Encoding::Base2Lsbf),
                    b"--z85" => cli.encoding = Some(Encoding::Z85),
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
                             basenc encode or decode FILE, or standard input, to standard output.\n\n\
                             With no FILE, or when FILE is -, read standard input.\n\n\
                             Mandatory arguments to long options are mandatory for short options too.\n\
                             \x20     --base64          same as 'base64' program (RFC4648 section 4)\n\
                             \x20     --base64url       file- and url-safe base64 (RFC4648 section 5)\n\
                             \x20     --base32          same as 'base32' program (RFC4648 section 6)\n\
                             \x20     --base32hex       extended hex alphabet base32 (RFC4648 section 7)\n\
                             \x20     --base16          hex encoding (RFC4648 section 8)\n\
                             \x20     --base2msbf       bit string with most significant bit (msb) first\n\
                             \x20     --base2lsbf       bit string with least significant bit (lsb) first\n\
                             \x20     --z85             ascii85-like encoding (ZeroMQ spec:32/Z85)\n\
                             \x20 -d, --decode          decode data\n\
                             \x20 -i, --ignore-garbage  when decoding, ignore non-alphabet characters\n\
                             \x20 -w, --wrap=COLS       wrap encoded lines after COLS character (default 76).\n\
                             \x20                         Use 0 to disable line wrapping\n\
                             \x20     --help             display this help and exit\n\
                             \x20     --version          output version information and exit\n\n\
                             When decoding, the input may contain newlines in addition to the bytes of\n\
                             the formal alphabet.  Use --ignore-garbage to attempt to recover\n\
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
        } else if cli.file.is_some() {
            eprintln!(
                "{}: extra operand \u{2018}{}\u{2019}",
                TOOL_NAME,
                arg.to_string_lossy()
            );
            eprintln!("Try '{} --help' for more information.", TOOL_NAME);
            process::exit(1);
        } else {
            cli.file = Some(arg.to_string_lossy().into_owned());
        }
    }

    cli
}

// ======================== Base64 ========================

const BASE64_ALPHABET: &[u8; 64] =
    b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
const BASE64URL_ALPHABET: &[u8; 64] =
    b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";

const fn build_base64_decode_table(alphabet: &[u8; 64]) -> [u8; 256] {
    let mut table = [0xFFu8; 256];
    let mut i = 0;
    while i < 64 {
        table[alphabet[i] as usize] = i as u8;
        i += 1;
    }
    table
}

const BASE64_DECODE: [u8; 256] = build_base64_decode_table(BASE64_ALPHABET);
const BASE64URL_DECODE: [u8; 256] = build_base64_decode_table(BASE64URL_ALPHABET);

#[cfg(test)]
fn base64_encode(data: &[u8], alphabet: &[u8; 64]) -> String {
    // SAFETY: result contains only ASCII bytes from the base64 alphabet
    unsafe { String::from_utf8_unchecked(base64_encode_bytes(data, alphabet)) }
}

/// Decode result: decoded data + optional error message.
/// When error is Some, the caller should write data (if any) then report the error.
struct DecodeOutput {
    data: Vec<u8>,
    error: Option<String>,
}

fn base64_decode(input: &[u8], decode_table: &[u8; 256], ignore_garbage: bool) -> DecodeOutput {
    let mut result = Vec::with_capacity(input.len() * 3 / 4 + 3);
    let mut vals = [0u8; 4];
    let mut n = 0usize;
    let mut pos = 0usize;

    for &b in input {
        if b == b'\n' || b == b'\r' {
            continue;
        }
        if b == b'=' {
            pos += 1;
            if pos == 4 {
                if n >= 2 {
                    result.push((vals[0] << 2) | (vals[1] >> 4));
                }
                if n >= 3 {
                    result.push((vals[1] << 4) | (vals[2] >> 2));
                }
                n = 0;
                pos = 0;
            }
            continue;
        }
        let v = decode_table[b as usize];
        if v == 0xFF {
            if !ignore_garbage {
                return DecodeOutput {
                    data: result,
                    error: Some(format!("{}: invalid input", TOOL_NAME)),
                };
            }
            continue;
        }
        vals[pos] = v;
        n += 1;
        pos += 1;
        if pos == 4 {
            result.extend_from_slice(&[
                (vals[0] << 2) | (vals[1] >> 4),
                (vals[1] << 4) | (vals[2] >> 2),
                (vals[2] << 6) | vals[3],
            ]);
            n = 0;
            pos = 0;
        }
    }

    // Incomplete final group: GNU auto-pads when there are enough chars to
    // produce output bytes.  For base64, 2 chars → 1 byte (still reports error
    // because 2 padding chars are missing), 3 chars → 2 bytes (auto-padded, no error).
    if n > 0 {
        if n >= 2 {
            result.push((vals[0] << 2) | (vals[1] >> 4));
        }
        if n >= 3 {
            result.push((vals[1] << 4) | (vals[2] >> 2));
        }
        // GNU only errors when the incomplete group can't be cleanly auto-padded
        // (i.e., only 1 char or exactly 2 chars which need 2 padding chars)
        if n < 3 {
            return DecodeOutput {
                data: result,
                error: Some(format!("{}: invalid input", TOOL_NAME)),
            };
        }
    }

    DecodeOutput {
        data: result,
        error: None,
    }
}

// ======================== Base32 ========================

const BASE32_ALPHABET: &[u8; 32] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";
const BASE32HEX_ALPHABET: &[u8; 32] = b"0123456789ABCDEFGHIJKLMNOPQRSTUV";

const fn build_base32_decode_table(alphabet: &[u8; 32]) -> [u8; 256] {
    let mut table = [0xFFu8; 256];
    let mut i = 0;
    while i < 32 {
        table[alphabet[i] as usize] = i as u8;
        // Also accept lowercase for letters
        if alphabet[i] >= b'A' && alphabet[i] <= b'Z' {
            table[(alphabet[i] - b'A' + b'a') as usize] = i as u8;
        }
        i += 1;
    }
    table
}

const BASE32_DECODE: [u8; 256] = build_base32_decode_table(BASE32_ALPHABET);
const BASE32HEX_DECODE: [u8; 256] = build_base32_decode_table(BASE32HEX_ALPHABET);

fn base32_decode(input: &[u8], decode_table: &[u8; 256], ignore_garbage: bool) -> DecodeOutput {
    let mut result = Vec::with_capacity(input.len() * 5 / 8 + 5);
    let mut vals = [0u8; 8];
    let mut n = 0usize;
    let mut pos = 0usize;
    let mut i = 0usize;

    while i < input.len() {
        // Fast path: decode 8 valid chars at once when starting a new group
        if pos == 0 && i + 8 <= input.len() {
            let chunk = &input[i..i + 8];
            let v0 = decode_table[chunk[0] as usize];
            let v1 = decode_table[chunk[1] as usize];
            let v2 = decode_table[chunk[2] as usize];
            let v3 = decode_table[chunk[3] as usize];
            let v4 = decode_table[chunk[4] as usize];
            let v5 = decode_table[chunk[5] as usize];
            let v6 = decode_table[chunk[6] as usize];
            let v7 = decode_table[chunk[7] as usize];

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
        let v = decode_table[b as usize];
        if v == 0xFF {
            if !ignore_garbage {
                return DecodeOutput {
                    data: result,
                    error: Some(format!("{}: invalid input", TOOL_NAME)),
                };
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

    // Incomplete final group: GNU auto-pads when there are enough chars to
    // produce output bytes.  For base32, 2+ chars can produce partial output.
    if n > 0 {
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
        // Only error if we have exactly 1, 3, or 6 chars (invalid partial groups)
        // Valid partial groups: 2 (1 byte), 4 (2 bytes), 5 (3 bytes), 7 (4 bytes)
        if n == 1 || n == 3 || n == 6 {
            return DecodeOutput {
                data: result,
                error: Some(format!("{}: invalid input", TOOL_NAME)),
            };
        }
    }

    DecodeOutput {
        data: result,
        error: None,
    }
}

// ======================== Base16 ========================

#[cfg(test)]
fn base16_encode(data: &[u8]) -> String {
    // SAFETY: result contains only ASCII hex digits
    unsafe { String::from_utf8_unchecked(base16_encode_bytes(data)) }
}

fn base16_decode(input: &[u8], ignore_garbage: bool) -> DecodeOutput {
    let mut result = Vec::with_capacity(input.len() / 2 + 1);
    let mut pending: i16 = -1;

    for &b in input {
        if b == b'\n' || b == b'\r' {
            continue;
        }
        let v = hex_val(b);
        if v == 0xFF {
            if !ignore_garbage {
                return DecodeOutput {
                    data: result,
                    error: Some(format!("{}: invalid input", TOOL_NAME)),
                };
            }
            continue;
        }
        if pending < 0 {
            pending = v as i16;
        } else {
            result.push(((pending as u8) << 4) | v);
            pending = -1;
        }
    }

    if pending >= 0 {
        return DecodeOutput {
            data: result,
            error: Some(format!("{}: invalid input", TOOL_NAME)),
        };
    }

    DecodeOutput {
        data: result,
        error: None,
    }
}

/// Hex decode for base16 (GNU basenc accepts both upper and lowercase in --base16 decode).
fn hex_val(b: u8) -> u8 {
    match b {
        b'0'..=b'9' => b - b'0',
        b'A'..=b'F' => b - b'A' + 10,
        b'a'..=b'f' => b - b'a' + 10,
        _ => 0xFF,
    }
}

// ======================== Base2 ========================

#[cfg(test)]
fn base2msbf_encode(data: &[u8]) -> String {
    // SAFETY: result contains only b'0' and b'1' bytes
    unsafe { String::from_utf8_unchecked(base2msbf_encode_bytes(data)) }
}

fn base2msbf_decode(input: &[u8], ignore_garbage: bool) -> DecodeOutput {
    let mut result = Vec::with_capacity(input.len() / 8 + 1);
    let mut byte = 0u8;
    let mut bits = 0u8;

    for &b in input {
        if b == b'\n' || b == b'\r' {
            continue;
        }
        if b != b'0' && b != b'1' {
            if !ignore_garbage {
                return DecodeOutput {
                    data: result,
                    error: Some(format!("{}: invalid input", TOOL_NAME)),
                };
            }
            continue;
        }
        byte = (byte << 1) | (b - b'0');
        bits += 1;
        if bits == 8 {
            result.push(byte);
            byte = 0;
            bits = 0;
        }
    }

    if bits != 0 {
        return DecodeOutput {
            data: result,
            error: Some(format!("{}: invalid input", TOOL_NAME)),
        };
    }

    DecodeOutput {
        data: result,
        error: None,
    }
}

#[cfg(test)]
fn base2lsbf_encode(data: &[u8]) -> String {
    // SAFETY: result contains only b'0' and b'1' bytes
    unsafe { String::from_utf8_unchecked(base2lsbf_encode_bytes(data)) }
}

fn base2lsbf_decode(input: &[u8], ignore_garbage: bool) -> DecodeOutput {
    let mut result = Vec::with_capacity(input.len() / 8 + 1);
    let mut byte = 0u8;
    let mut bits = 0u8;

    for &b in input {
        if b == b'\n' || b == b'\r' {
            continue;
        }
        if b != b'0' && b != b'1' {
            if !ignore_garbage {
                return DecodeOutput {
                    data: result,
                    error: Some(format!("{}: invalid input", TOOL_NAME)),
                };
            }
            continue;
        }
        byte |= (b - b'0') << bits;
        bits += 1;
        if bits == 8 {
            result.push(byte);
            byte = 0;
            bits = 0;
        }
    }

    if bits != 0 {
        return DecodeOutput {
            data: result,
            error: Some(format!("{}: invalid input", TOOL_NAME)),
        };
    }

    DecodeOutput {
        data: result,
        error: None,
    }
}

// ======================== Z85 ========================

const Z85_ENCODE_TABLE: &[u8; 85] =
    b"0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ.-:+=^!/*?&<>()[]{}@%$#";

const fn build_z85_decode_table() -> [u8; 256] {
    let alpha =
        b"0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ.-:+=^!/*?&<>()[]{}@%$#";
    let mut table = [0xFFu8; 256];
    let mut i = 0;
    while i < 85 {
        table[alpha[i] as usize] = i as u8;
        i += 1;
    }
    table
}

const Z85_DECODE_TABLE: [u8; 256] = build_z85_decode_table();

#[cfg(test)]
fn z85_encode(data: &[u8]) -> Result<String, String> {
    // SAFETY: result contains only ASCII bytes from the Z85 alphabet
    Ok(unsafe { String::from_utf8_unchecked(z85_encode_bytes(data)?) })
}

fn z85_decode(input: &[u8], ignore_garbage: bool) -> DecodeOutput {
    let mut result = Vec::with_capacity(input.len() * 4 / 5 + 4);
    let mut value: u32 = 0;
    let mut count = 0u8;

    for &b in input {
        if b == b'\n' || b == b'\r' {
            continue;
        }
        let v = Z85_DECODE_TABLE[b as usize];
        if v == 0xFF {
            if !ignore_garbage {
                return DecodeOutput {
                    data: result,
                    error: Some(format!("{}: invalid input", TOOL_NAME)),
                };
            }
            continue;
        }
        value = value * 85 + u32::from(v);
        count += 1;
        if count == 5 {
            result.extend_from_slice(&[
                (value >> 24) as u8,
                (value >> 16) as u8,
                (value >> 8) as u8,
                value as u8,
            ]);
            value = 0;
            count = 0;
        }
    }

    if count != 0 {
        return DecodeOutput {
            data: result,
            error: Some(format!(
                "{}: invalid input (length must be a multiple of 5 for Z85 decoding)",
                TOOL_NAME
            )),
        };
    }

    DecodeOutput {
        data: result,
        error: None,
    }
}

// ======================== Common ========================

/// Encode and write with line wrapping. For base64/base64url, uses SIMD encoding
/// with backward expansion for wrapping. For other encodings, uses batch buffer.
fn encode_streaming(
    data: &[u8],
    encoding: Encoding,
    wrap: usize,
    out: &mut impl Write,
) -> io::Result<()> {
    if data.is_empty() {
        return Ok(());
    }

    // Fast path: SIMD-accelerated base64/base64url encoding
    match encoding {
        Encoding::Base64 => return encode_base64_simd(data, B64_STANDARD, wrap, out),
        Encoding::Base64Url => return encode_base64_simd(data, B64_URL_SAFE, wrap, out),
        _ => {}
    }

    // Other encodings: batch encode into output buffer, then write once
    encode_streaming_generic(data, encoding, wrap, out)
}

/// SIMD-accelerated base64 encoding with backward expansion for wrapping.
/// Chunked processing keeps memory usage bounded while maximizing throughput.
fn encode_base64_simd(
    data: &[u8],
    engine: &base64_simd::Base64,
    wrap: usize,
    out: &mut impl Write,
) -> io::Result<()> {
    if data.is_empty() {
        return Ok(());
    }

    if wrap == 0 {
        // No wrapping: encode in 8MB chunks directly to reusable buffer
        const CHUNK: usize = 8 * 1024 * 1024 - (8 * 1024 * 1024 % 3);
        let buf_len = engine.encoded_length(data.len().min(CHUNK));
        let mut buf: Vec<u8> = Vec::with_capacity(buf_len);
        #[allow(clippy::uninit_vec)]
        unsafe {
            buf.set_len(buf_len);
        }
        for chunk in data.chunks(CHUNK) {
            let clen = engine.encoded_length(chunk.len());
            let encoded = engine.encode(chunk, buf[..clen].as_out());
            out.write_all(encoded)?;
        }
        return Ok(());
    }

    // Wrapped output: chunked SIMD encode + backward expansion.
    // Process in ~8MB input chunks to keep memory bounded.
    // bytes_per_line = how many input bytes produce exactly wrap encoded chars.
    let bytes_per_line = (wrap / 4) * 3;
    if bytes_per_line == 0 {
        // Extremely small wrap (< 4 chars): character-level encode + wrap
        let full_enc = engine.encode_to_string(data);
        let mut col = 0;
        for ch in full_enc.as_bytes().chunks(1) {
            out.write_all(ch)?;
            col += 1;
            if col == wrap {
                out.write_all(b"\n")?;
                col = 0;
            }
        }
        if col > 0 {
            out.write_all(b"\n")?;
        }
        return Ok(());
    }

    // Process in chunks of N lines worth of input, where N lines fit in ~8MB
    let lines_per_chunk = (8 * 1024 * 1024 / bytes_per_line).max(1);
    let input_chunk_size = lines_per_chunk * bytes_per_line;

    // Output buffer for one chunk: encoded + newlines
    let max_enc = engine.encoded_length(input_chunk_size);
    let max_out = (max_enc / wrap) * (wrap + 1) + wrap + 2;
    let mut buf: Vec<u8> = Vec::with_capacity(max_out);
    #[allow(clippy::uninit_vec)]
    unsafe {
        buf.set_len(max_out);
    }

    // Track column for partial last line across chunks
    let mut col = 0usize;

    for chunk in data.chunks(input_chunk_size) {
        let enc_len = engine.encoded_length(chunk.len());
        if enc_len == 0 {
            continue;
        }

        // Ensure buffer is large enough (last chunk may differ)
        let num_full = enc_len / wrap;
        let rem = enc_len % wrap;
        let out_len = num_full * (wrap + 1) + if rem > 0 { rem } else { 0 };

        if col == 0 {
            // Aligned: encode + expand in one shot
            if buf.len() < out_len + num_full + 2 {
                buf.resize(out_len + num_full + 2, 0);
            }
            let real_out_len = num_full * (wrap + 1) + if rem > 0 { rem + 1 } else { 0 };
            let _ = engine.encode(chunk, buf[..enc_len].as_out());
            // SAFETY: buf was allocated with at least max_out bytes (or resized above),
            // buf[..enc_len] contains the SIMD-encoded data, and real_out_len was
            // calculated as the total bytes needed for encoded data with newlines.
            unsafe {
                expand_backward(buf.as_mut_ptr(), enc_len, real_out_len, wrap);
            }

            // If this chunk has a partial last line, don't emit its trailing newline
            if rem > 0 {
                // Partial last line: emit everything except the final newline,
                // track column for next chunk
                out.write_all(&buf[..real_out_len - 1])?;
                col = rem;
            } else {
                out.write_all(&buf[..real_out_len])?;
                col = 0;
            }
        } else {
            // Unaligned: we have `col` chars on current line from previous chunk.
            // Encode this chunk, then manually wrap with column tracking.
            // Reuse buf: encoded data in buf[..enc_len], build wrapped output in buf[enc_len..].
            let _ = engine.encode(chunk, buf[..enc_len].as_out());
            let out_start = enc_len;
            let mut wp = out_start;
            let mut pos = 0;
            while pos < enc_len {
                let remaining_in_line = wrap - col;
                let available = enc_len - pos;
                let to_write = remaining_in_line.min(available);
                buf.copy_within(pos..pos + to_write, wp);
                wp += to_write;
                pos += to_write;
                col += to_write;
                if col == wrap {
                    buf[wp] = b'\n';
                    wp += 1;
                    col = 0;
                }
            }
            out.write_all(&buf[out_start..wp])?;
        }
    }

    if col > 0 {
        out.write_all(b"\n")?;
    }

    Ok(())
}

/// Expand encoded data in-place by inserting newlines at wrap boundaries.
/// Processes backward so shifted data never overwrites unread source bytes.
///
/// # Safety
/// - `ptr` must point to an allocation of at least `out_len` bytes.
/// - `ptr[0..enc_len]` must contain the SIMD-encoded base64 data.
/// - `out_len` must be calculated as the total bytes needed for encoded data with newlines inserted.
#[inline]
unsafe fn expand_backward(ptr: *mut u8, enc_len: usize, out_len: usize, wrap: usize) {
    let num_full = enc_len / wrap;
    let rem = enc_len % wrap;

    unsafe {
        let mut rp = enc_len;
        let mut wp = out_len;

        if rem > 0 {
            wp -= 1;
            *ptr.add(wp) = b'\n';
            wp -= rem;
            rp -= rem;
            if rp != wp {
                std::ptr::copy(ptr.add(rp), ptr.add(wp), rem);
            }
        }

        let mut lines_left = num_full;
        while lines_left > 0 {
            wp -= 1;
            *ptr.add(wp) = b'\n';
            rp -= wrap;
            wp -= wrap;
            std::ptr::copy(ptr.add(rp), ptr.add(wp), wrap);
            lines_left -= 1;
        }
    }
}

/// Generic streaming encode for non-base64 encodings. Batch into output buffer.
fn encode_streaming_generic(
    data: &[u8],
    encoding: Encoding,
    wrap: usize,
    out: &mut impl Write,
) -> io::Result<()> {
    // Chunk alignment: must be a multiple of the encoding's input block size
    let block_size = match encoding {
        Encoding::Base32 | Encoding::Base32Hex => 5,
        Encoding::Base16 | Encoding::Base2Msbf | Encoding::Base2Lsbf => 1,
        Encoding::Z85 => 4,
        _ => unreachable!(),
    };

    // ~256KB chunks, aligned to block size (up from 64KB)
    let chunk_size = (256 * 1024 / block_size) * block_size;

    // Pre-allocate output buffer large enough for one chunk's encoded + wrapped output
    let max_encoded = match encoding {
        Encoding::Base32 | Encoding::Base32Hex => chunk_size * 8 / 5 + 8,
        Encoding::Base16 => chunk_size * 2,
        Encoding::Base2Msbf | Encoding::Base2Lsbf => chunk_size * 8,
        Encoding::Z85 => chunk_size * 5 / 4 + 5,
        _ => unreachable!(),
    };
    let max_wrapped = if wrap > 0 {
        max_encoded + max_encoded / wrap + 2
    } else {
        max_encoded
    };
    let mut out_buf: Vec<u8> = Vec::with_capacity(max_wrapped);
    let mut col = 0usize;

    for input_chunk in data.chunks(chunk_size) {
        let encoded = match encode_data_bytes(input_chunk, encoding) {
            Ok(e) => e,
            Err(msg) => {
                eprintln!("{}", msg);
                process::exit(1);
            }
        };

        if wrap == 0 {
            out.write_all(&encoded)?;
        } else {
            // Batch wrap into output buffer
            out_buf.clear();
            let mut pos = 0;
            while pos < encoded.len() {
                let remaining_in_line = wrap - col;
                let available = encoded.len() - pos;
                let to_write = remaining_in_line.min(available);
                out_buf.extend_from_slice(&encoded[pos..pos + to_write]);
                pos += to_write;
                col += to_write;
                if col == wrap {
                    out_buf.push(b'\n');
                    col = 0;
                }
            }
            out.write_all(&out_buf)?;
        }
    }

    if wrap > 0 && col > 0 {
        out.write_all(b"\n")?;
    }

    Ok(())
}

/// Encode data directly to bytes, avoiding String allocation.
fn encode_data_bytes(data: &[u8], encoding: Encoding) -> Result<Vec<u8>, String> {
    match encoding {
        Encoding::Base64 => Ok(base64_encode_bytes(data, BASE64_ALPHABET)),
        Encoding::Base64Url => Ok(base64_encode_bytes(data, BASE64URL_ALPHABET)),
        Encoding::Base32 => Ok(base32_encode_bytes(data, BASE32_ALPHABET)),
        Encoding::Base32Hex => Ok(base32_encode_bytes(data, BASE32HEX_ALPHABET)),
        Encoding::Base16 => Ok(base16_encode_bytes(data)),
        Encoding::Base2Msbf => Ok(base2msbf_encode_bytes(data)),
        Encoding::Base2Lsbf => Ok(base2lsbf_encode_bytes(data)),
        Encoding::Z85 => z85_encode_bytes(data),
    }
}

/// Encode base64 directly to bytes (no String intermediate).
/// Optimized: branch-free processing of full 3-byte chunks.
fn base64_encode_bytes(data: &[u8], alphabet: &[u8; 64]) -> Vec<u8> {
    if data.is_empty() {
        return Vec::new();
    }
    let mut result = Vec::with_capacity(data.len().div_ceil(3) * 4);
    let full_end = (data.len() / 3) * 3;

    // Full 3-byte chunks: no padding, no branches
    for chunk in data[..full_end].chunks_exact(3) {
        let b0 = chunk[0];
        let b1 = chunk[1];
        let b2 = chunk[2];
        result.extend_from_slice(&[
            alphabet[(b0 >> 2) as usize],
            alphabet[((b0 & 0x03) << 4 | b1 >> 4) as usize],
            alphabet[((b1 & 0x0F) << 2 | b2 >> 6) as usize],
            alphabet[(b2 & 0x3F) as usize],
        ]);
    }

    // Handle last partial chunk with padding
    let remainder = data.len() % 3;
    if remainder == 1 {
        let b0 = data[full_end];
        result.extend_from_slice(&[
            alphabet[(b0 >> 2) as usize],
            alphabet[((b0 & 0x03) << 4) as usize],
            b'=',
            b'=',
        ]);
    } else if remainder == 2 {
        let b0 = data[full_end];
        let b1 = data[full_end + 1];
        result.extend_from_slice(&[
            alphabet[(b0 >> 2) as usize],
            alphabet[((b0 & 0x03) << 4 | b1 >> 4) as usize],
            alphabet[((b1 & 0x0F) << 2) as usize],
            b'=',
        ]);
    }
    result
}

/// Encode base32 directly to bytes (no String intermediate).
/// Optimized: branch-free processing of full 5-byte chunks.
fn base32_encode_bytes(data: &[u8], alphabet: &[u8; 32]) -> Vec<u8> {
    if data.is_empty() {
        return Vec::new();
    }
    let mut result = Vec::with_capacity(data.len().div_ceil(5) * 8);
    let full_end = (data.len() / 5) * 5;

    // Full 5-byte chunks: no padding, no branches
    for chunk in data[..full_end].chunks_exact(5) {
        let b0 = chunk[0];
        let b1 = chunk[1];
        let b2 = chunk[2];
        let b3 = chunk[3];
        let b4 = chunk[4];
        result.extend_from_slice(&[
            alphabet[(b0 >> 3) as usize],
            alphabet[((b0 & 0x07) << 2 | b1 >> 6) as usize],
            alphabet[((b1 >> 1) & 0x1F) as usize],
            alphabet[((b1 & 0x01) << 4 | b2 >> 4) as usize],
            alphabet[((b2 & 0x0F) << 1 | b3 >> 7) as usize],
            alphabet[((b3 >> 2) & 0x1F) as usize],
            alphabet[((b3 & 0x03) << 3 | b4 >> 5) as usize],
            alphabet[(b4 & 0x1F) as usize],
        ]);
    }

    // Handle last partial chunk with padding
    let remainder = data.len() % 5;
    if remainder > 0 {
        let chunk = &data[full_end..];
        let mut buf = [0u8; 5];
        buf[..chunk.len()].copy_from_slice(chunk);
        let b0 = buf[0];
        let b1 = buf[1];
        let b2 = buf[2];
        let b3 = buf[3];
        let b4 = buf[4];
        result.push(alphabet[(b0 >> 3) as usize]);
        result.push(alphabet[((b0 & 0x07) << 2 | b1 >> 6) as usize]);
        match remainder {
            1 => result.extend_from_slice(b"======"),
            2 => {
                result.push(alphabet[((b1 >> 1) & 0x1F) as usize]);
                result.push(alphabet[((b1 & 0x01) << 4 | b2 >> 4) as usize]);
                result.extend_from_slice(b"====");
            }
            3 => {
                result.push(alphabet[((b1 >> 1) & 0x1F) as usize]);
                result.push(alphabet[((b1 & 0x01) << 4 | b2 >> 4) as usize]);
                result.push(alphabet[((b2 & 0x0F) << 1 | b3 >> 7) as usize]);
                result.extend_from_slice(b"===");
            }
            4 => {
                result.push(alphabet[((b1 >> 1) & 0x1F) as usize]);
                result.push(alphabet[((b1 & 0x01) << 4 | b2 >> 4) as usize]);
                result.push(alphabet[((b2 & 0x0F) << 1 | b3 >> 7) as usize]);
                result.push(alphabet[((b3 >> 2) & 0x1F) as usize]);
                result.push(alphabet[((b3 & 0x03) << 3 | b4 >> 5) as usize]);
                result.push(b'=');
            }
            _ => unreachable!(),
        }
    }
    result
}

/// Pre-computed hex encoding table: byte → 2 hex chars.
const fn build_hex_table() -> [[u8; 2]; 256] {
    let hex = b"0123456789ABCDEF";
    let mut table = [[0u8; 2]; 256];
    let mut i = 0u16;
    while i < 256 {
        table[i as usize] = [hex[(i >> 4) as usize], hex[(i & 0x0F) as usize]];
        i += 1;
    }
    table
}

static HEX_TABLE: [[u8; 2]; 256] = build_hex_table();

/// Encode base16 directly to bytes using lookup table.
fn base16_encode_bytes(data: &[u8]) -> Vec<u8> {
    let mut result = Vec::with_capacity(data.len() * 2);
    for &b in data {
        result.extend_from_slice(&HEX_TABLE[b as usize]);
    }
    result
}

/// Pre-computed MSBF lookup table: byte → 8 ASCII bit characters.
const fn build_base2_msbf_table() -> [[u8; 8]; 256] {
    let mut table = [[0u8; 8]; 256];
    let mut i = 0u16;
    while i < 256 {
        let b = i as u8;
        let mut j = 0;
        while j < 8 {
            table[i as usize][j] = if (b >> (7 - j)) & 1 == 1 { b'1' } else { b'0' };
            j += 1;
        }
        i += 1;
    }
    table
}

/// Pre-computed LSBF lookup table: byte → 8 ASCII bit characters.
const fn build_base2_lsbf_table() -> [[u8; 8]; 256] {
    let mut table = [[0u8; 8]; 256];
    let mut i = 0u16;
    while i < 256 {
        let b = i as u8;
        let mut j = 0;
        while j < 8 {
            table[i as usize][j] = if (b >> j) & 1 == 1 { b'1' } else { b'0' };
            j += 1;
        }
        i += 1;
    }
    table
}

static BASE2_MSBF_TABLE: [[u8; 8]; 256] = build_base2_msbf_table();
static BASE2_LSBF_TABLE: [[u8; 8]; 256] = build_base2_lsbf_table();

/// Encode base2 MSBF directly to bytes using lookup table.
fn base2msbf_encode_bytes(data: &[u8]) -> Vec<u8> {
    let mut result = Vec::with_capacity(data.len() * 8);
    for &b in data {
        result.extend_from_slice(&BASE2_MSBF_TABLE[b as usize]);
    }
    result
}

/// Encode base2 LSBF directly to bytes using lookup table.
fn base2lsbf_encode_bytes(data: &[u8]) -> Vec<u8> {
    let mut result = Vec::with_capacity(data.len() * 8);
    for &b in data {
        result.extend_from_slice(&BASE2_LSBF_TABLE[b as usize]);
    }
    result
}

/// Encode Z85 directly to bytes.
fn z85_encode_bytes(data: &[u8]) -> Result<Vec<u8>, String> {
    if !data.len().is_multiple_of(4) {
        return Err(format!(
            "{}: invalid input (length must be a multiple of 4 for Z85 encoding)",
            TOOL_NAME
        ));
    }
    let mut result = Vec::with_capacity(data.len() * 5 / 4);
    for chunk in data.chunks(4) {
        let mut value = u32::from(chunk[0]) << 24
            | u32::from(chunk[1]) << 16
            | u32::from(chunk[2]) << 8
            | u32::from(chunk[3]);
        let mut chars = [0u8; 5];
        for c in chars.iter_mut().rev() {
            *c = Z85_ENCODE_TABLE[(value % 85) as usize];
            value /= 85;
        }
        result.extend_from_slice(&chars);
    }
    Ok(result)
}

fn decode_data(data: &[u8], encoding: Encoding, ignore_garbage: bool) -> DecodeOutput {
    match encoding {
        Encoding::Base64 => base64_decode(data, &BASE64_DECODE, ignore_garbage),
        Encoding::Base64Url => base64_decode(data, &BASE64URL_DECODE, ignore_garbage),
        Encoding::Base32 => base32_decode(data, &BASE32_DECODE, ignore_garbage),
        Encoding::Base32Hex => base32_decode(data, &BASE32HEX_DECODE, ignore_garbage),
        Encoding::Base16 => base16_decode(data, ignore_garbage),
        Encoding::Base2Msbf => base2msbf_decode(data, ignore_garbage),
        Encoding::Base2Lsbf => base2lsbf_decode(data, ignore_garbage),
        Encoding::Z85 => z85_decode(data, ignore_garbage),
    }
}

/// Input data: either an owned Vec or a memory-mapped file.
enum InputData {
    Owned(Vec<u8>),
    #[cfg(unix)]
    Mmap(memmap2::Mmap),
}

impl std::ops::Deref for InputData {
    type Target = [u8];
    fn deref(&self) -> &[u8] {
        match self {
            InputData::Owned(v) => v,
            #[cfg(unix)]
            InputData::Mmap(m) => m,
        }
    }
}

/// Try to mmap stdin if it's a regular file (e.g. `fbasenc --base64 < file`).
/// Returns None if stdin is a pipe or terminal.
#[cfg(target_os = "linux")]
fn try_mmap_stdin() -> Option<memmap2::Mmap> {
    use std::os::unix::io::FromRawFd;
    let file = unsafe { std::mem::ManuallyDrop::new(std::fs::File::from_raw_fd(0)) };
    let meta = file.metadata().ok()?;
    if !meta.is_file() || meta.len() == 0 {
        return None;
    }
    let mmap = unsafe { memmap2::MmapOptions::new().map(&*file).ok()? };
    unsafe {
        libc::madvise(
            mmap.as_ptr() as *mut libc::c_void,
            mmap.len(),
            libc::MADV_SEQUENTIAL,
        );
    }
    Some(mmap)
}

/// Read all data from stdin using large-buffer reads to minimize syscall count.
#[cfg(target_os = "linux")]
fn read_stdin_fast() -> io::Result<Vec<u8>> {
    // Try to get file size if stdin is a regular file (redirected)
    let size_hint = unsafe {
        let mut st = std::mem::zeroed::<libc::stat>();
        if libc::fstat(0, &mut st) == 0 && (st.st_mode & libc::S_IFMT) == libc::S_IFREG {
            st.st_size as usize
        } else {
            1024 * 1024 // 1MB default for pipes
        }
    };
    let mut buf = Vec::with_capacity(size_hint);
    RawStdin.read_to_end(&mut buf)?;
    Ok(buf)
}

/// Read input data from file or stdin. Uses mmap for files, raw libc::read for stdin on Linux.
fn read_input(filename: &str) -> InputData {
    if filename == "-" {
        #[cfg(target_os = "linux")]
        {
            // Try to mmap stdin if it's a regular file (e.g. redirected from file)
            if let Some(mmap) = try_mmap_stdin() {
                return InputData::Mmap(mmap);
            }
            match read_stdin_fast() {
                Ok(buf) => return InputData::Owned(buf),
                Err(e) => {
                    eprintln!("{}: {}", TOOL_NAME, coreutils_rs::common::io_error_msg(&e));
                    process::exit(1);
                }
            }
        }
        #[cfg(not(target_os = "linux"))]
        {
            let mut buf = Vec::new();
            if let Err(e) = io::stdin().lock().read_to_end(&mut buf) {
                eprintln!("{}: {}", TOOL_NAME, coreutils_rs::common::io_error_msg(&e));
                process::exit(1);
            }
            return InputData::Owned(buf);
        }
    }

    // Try mmap for file input (avoids copy into userspace heap)
    #[cfg(unix)]
    {
        use std::fs::File;
        if let Ok(file) = File::open(filename)
            && let Ok(meta) = file.metadata()
            && meta.len() > 0
            && meta.is_file()
            && let Ok(mmap) = unsafe { memmap2::MmapOptions::new().map(&file) }
        {
            #[cfg(target_os = "linux")]
            unsafe {
                libc::madvise(
                    mmap.as_ptr() as *mut libc::c_void,
                    mmap.len(),
                    libc::MADV_SEQUENTIAL,
                );
            }
            return InputData::Mmap(mmap);
        }
    }

    match std::fs::read(filename) {
        Ok(d) => InputData::Owned(d),
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
}

/// Enlarge stdin/stdout pipe buffers on Linux to reduce syscall count.
#[cfg(target_os = "linux")]
fn enlarge_pipes() {
    for &fd in &[0i32, 1] {
        for &size in &[8 * 1024 * 1024i32, 1024 * 1024, 256 * 1024] {
            if unsafe { libc::fcntl(fd, libc::F_SETPIPE_SZ, size) } >= 0 {
                break;
            }
        }
    }
}

fn main() {
    coreutils_rs::common::reset_sigpipe();

    #[cfg(target_os = "linux")]
    enlarge_pipes();

    let cli = parse_args();

    let encoding = match cli.encoding {
        Some(e) => e,
        None => {
            eprintln!("{}: missing encoding type", TOOL_NAME);
            eprintln!("Try '{} --help' for more information.", TOOL_NAME);
            process::exit(1);
        }
    };

    let filename = cli.file.as_deref().unwrap_or("-");

    let data = read_input(filename);

    let stdout = io::stdout();
    let mut out = io::BufWriter::with_capacity(1024 * 1024, stdout.lock());

    if cli.decode {
        let result = decode_data(&data, encoding, cli.ignore_garbage);
        if !result.data.is_empty() {
            if let Err(e) = out.write_all(&result.data) {
                if e.kind() == io::ErrorKind::BrokenPipe {
                    process::exit(0);
                }
                eprintln!("{}: write error: {}", TOOL_NAME, e);
                process::exit(1);
            }
            // Flush before printing error so partial output appears before error message
            let _ = out.flush();
        }
        if let Some(msg) = result.error {
            eprintln!("{}", msg);
            process::exit(1);
        }
    } else if let Err(e) = encode_streaming(&data, encoding, cli.wrap, &mut out) {
        if e.kind() == io::ErrorKind::BrokenPipe {
            process::exit(0);
        }
        let msg = e.to_string();
        eprintln!("{}: {}", TOOL_NAME, msg);
        process::exit(1);
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
        path.push("fbasenc");
        Command::new(path)
    }

    #[test]
    fn test_help() {
        let output = cmd().arg("--help").output().unwrap();
        assert!(output.status.success());
        let stdout = String::from_utf8_lossy(&output.stdout);
        assert!(stdout.contains("Usage:"));
        assert!(stdout.contains("--base64"));
        assert!(stdout.contains("--z85"));
    }

    #[test]
    fn test_version() {
        let output = cmd().arg("--version").output().unwrap();
        assert!(output.status.success());
        let stdout = String::from_utf8_lossy(&output.stdout);
        assert!(stdout.contains("basenc"));
        assert!(stdout.contains("fcoreutils"));
    }

    #[test]
    fn test_no_encoding_error() {
        let output = cmd().output().unwrap();
        assert!(!output.status.success());
        let stderr = String::from_utf8_lossy(&output.stderr);
        assert!(stderr.contains("missing encoding type"));
    }

    // ---- Base64 tests ----

    #[test]
    fn test_base64_encode() {
        let mut child = cmd()
            .arg("--base64")
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::piped())
            .spawn()
            .unwrap();
        child.stdin.take().unwrap().write_all(b"Hello").unwrap();
        let output = child.wait_with_output().unwrap();
        assert!(output.status.success());
        let stdout = String::from_utf8_lossy(&output.stdout);
        assert_eq!(stdout.trim(), "SGVsbG8=");
    }

    #[test]
    fn test_base64_decode() {
        let mut child = cmd()
            .arg("--base64")
            .arg("-d")
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::piped())
            .spawn()
            .unwrap();
        child
            .stdin
            .take()
            .unwrap()
            .write_all(b"SGVsbG8=\n")
            .unwrap();
        let output = child.wait_with_output().unwrap();
        assert!(output.status.success());
        assert_eq!(&output.stdout, b"Hello");
    }

    #[test]
    fn test_base64_roundtrip() {
        let input = b"The quick brown fox";
        let mut child = cmd()
            .arg("--base64")
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::piped())
            .spawn()
            .unwrap();
        child.stdin.take().unwrap().write_all(input).unwrap();
        let enc = child.wait_with_output().unwrap();
        assert!(enc.status.success());

        let mut child = cmd()
            .arg("--base64")
            .arg("-d")
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::piped())
            .spawn()
            .unwrap();
        child.stdin.take().unwrap().write_all(&enc.stdout).unwrap();
        let dec = child.wait_with_output().unwrap();
        assert!(dec.status.success());
        assert_eq!(&dec.stdout, input);
    }

    // ---- Base64url tests ----

    #[test]
    fn test_base64url_encode() {
        let mut child = cmd()
            .arg("--base64url")
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::piped())
            .spawn()
            .unwrap();
        child.stdin.take().unwrap().write_all(b"Hello").unwrap();
        let output = child.wait_with_output().unwrap();
        assert!(output.status.success());
        let stdout = String::from_utf8_lossy(&output.stdout);
        assert_eq!(stdout.trim(), "SGVsbG8=");
    }

    #[test]
    fn test_base64url_special_chars() {
        // Test data that produces +/ in standard base64 but -_ in url-safe
        let input = b"\xfb\xff\xfe";
        let encoded = base64_encode(input, BASE64URL_ALPHABET);
        assert!(!encoded.contains('+'));
        assert!(!encoded.contains('/'));
        // Should contain - or _ if the data maps to those
        let standard = base64_encode(input, BASE64_ALPHABET);
        // Verify the url-safe version substitutes correctly
        assert_eq!(standard.replace('+', "-").replace('/', "_"), encoded);
    }

    #[test]
    fn test_base64url_roundtrip() {
        let input = b"\xff\xfe\xfd\xfc\xfb\xfa";
        let mut child = cmd()
            .arg("--base64url")
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::piped())
            .spawn()
            .unwrap();
        child.stdin.take().unwrap().write_all(input).unwrap();
        let enc = child.wait_with_output().unwrap();
        assert!(enc.status.success());

        let mut child = cmd()
            .arg("--base64url")
            .arg("-d")
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::piped())
            .spawn()
            .unwrap();
        child.stdin.take().unwrap().write_all(&enc.stdout).unwrap();
        let dec = child.wait_with_output().unwrap();
        assert!(dec.status.success());
        assert_eq!(&dec.stdout, input);
    }

    // ---- Base32 tests ----

    #[test]
    fn test_base32_encode() {
        let mut child = cmd()
            .arg("--base32")
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
    fn test_base32_decode() {
        let mut child = cmd()
            .arg("--base32")
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

    // ---- Base32hex tests ----

    #[test]
    fn test_base32hex_encode() {
        let mut child = cmd()
            .arg("--base32hex")
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::piped())
            .spawn()
            .unwrap();
        child.stdin.take().unwrap().write_all(b"Hello").unwrap();
        let output = child.wait_with_output().unwrap();
        assert!(output.status.success());
        let stdout = String::from_utf8_lossy(&output.stdout);
        // "Hello" in base32hex is "91IMOR3F"
        assert_eq!(stdout.trim(), "91IMOR3F");
    }

    #[test]
    fn test_base32hex_roundtrip() {
        let input = b"test data 12345";
        let mut child = cmd()
            .arg("--base32hex")
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::piped())
            .spawn()
            .unwrap();
        child.stdin.take().unwrap().write_all(input).unwrap();
        let enc = child.wait_with_output().unwrap();
        assert!(enc.status.success());

        let mut child = cmd()
            .arg("--base32hex")
            .arg("-d")
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::piped())
            .spawn()
            .unwrap();
        child.stdin.take().unwrap().write_all(&enc.stdout).unwrap();
        let dec = child.wait_with_output().unwrap();
        assert!(dec.status.success());
        assert_eq!(&dec.stdout, input);
    }

    // ---- Base16 tests ----

    #[test]
    fn test_base16_encode() {
        let mut child = cmd()
            .arg("--base16")
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::piped())
            .spawn()
            .unwrap();
        child.stdin.take().unwrap().write_all(b"Hello").unwrap();
        let output = child.wait_with_output().unwrap();
        assert!(output.status.success());
        let stdout = String::from_utf8_lossy(&output.stdout);
        assert_eq!(stdout.trim(), "48656C6C6F");
    }

    #[test]
    fn test_base16_decode() {
        let mut child = cmd()
            .arg("--base16")
            .arg("-d")
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::piped())
            .spawn()
            .unwrap();
        child
            .stdin
            .take()
            .unwrap()
            .write_all(b"48656C6C6F\n")
            .unwrap();
        let output = child.wait_with_output().unwrap();
        assert!(output.status.success());
        assert_eq!(&output.stdout, b"Hello");
    }

    #[test]
    fn test_base16_roundtrip() {
        let input = b"\x00\x01\x02\xff\xfe\xfd";
        let mut child = cmd()
            .arg("--base16")
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::piped())
            .spawn()
            .unwrap();
        child.stdin.take().unwrap().write_all(input).unwrap();
        let enc = child.wait_with_output().unwrap();
        assert!(enc.status.success());

        let mut child = cmd()
            .arg("--base16")
            .arg("-d")
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::piped())
            .spawn()
            .unwrap();
        child.stdin.take().unwrap().write_all(&enc.stdout).unwrap();
        let dec = child.wait_with_output().unwrap();
        assert!(dec.status.success());
        assert_eq!(&dec.stdout, input);
    }

    // ---- Base2 MSB first tests ----

    #[test]
    fn test_base2msbf_encode() {
        let mut child = cmd()
            .arg("--base2msbf")
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::piped())
            .spawn()
            .unwrap();
        child.stdin.take().unwrap().write_all(b"A").unwrap();
        let output = child.wait_with_output().unwrap();
        assert!(output.status.success());
        let stdout = String::from_utf8_lossy(&output.stdout);
        // 'A' = 0x41 = 01000001
        assert_eq!(stdout.trim(), "01000001");
    }

    #[test]
    fn test_base2msbf_roundtrip() {
        let input = b"Hi";
        let mut child = cmd()
            .arg("--base2msbf")
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::piped())
            .spawn()
            .unwrap();
        child.stdin.take().unwrap().write_all(input).unwrap();
        let enc = child.wait_with_output().unwrap();
        assert!(enc.status.success());

        let mut child = cmd()
            .arg("--base2msbf")
            .arg("-d")
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::piped())
            .spawn()
            .unwrap();
        child.stdin.take().unwrap().write_all(&enc.stdout).unwrap();
        let dec = child.wait_with_output().unwrap();
        assert!(dec.status.success());
        assert_eq!(&dec.stdout, input);
    }

    // ---- Base2 LSB first tests ----

    #[test]
    fn test_base2lsbf_encode() {
        let mut child = cmd()
            .arg("--base2lsbf")
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::piped())
            .spawn()
            .unwrap();
        child.stdin.take().unwrap().write_all(b"A").unwrap();
        let output = child.wait_with_output().unwrap();
        assert!(output.status.success());
        let stdout = String::from_utf8_lossy(&output.stdout);
        // 'A' = 0x41 = 01000001, LSB first = 10000010
        assert_eq!(stdout.trim(), "10000010");
    }

    #[test]
    fn test_base2lsbf_roundtrip() {
        let input = b"Hi";
        let mut child = cmd()
            .arg("--base2lsbf")
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::piped())
            .spawn()
            .unwrap();
        child.stdin.take().unwrap().write_all(input).unwrap();
        let enc = child.wait_with_output().unwrap();
        assert!(enc.status.success());

        let mut child = cmd()
            .arg("--base2lsbf")
            .arg("-d")
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::piped())
            .spawn()
            .unwrap();
        child.stdin.take().unwrap().write_all(&enc.stdout).unwrap();
        let dec = child.wait_with_output().unwrap();
        assert!(dec.status.success());
        assert_eq!(&dec.stdout, input);
    }

    // ---- Z85 tests ----

    #[test]
    fn test_z85_encode() {
        // Z85 requires input length to be multiple of 4
        // "Test" (4 bytes) -> Z85 encode
        let mut child = cmd()
            .arg("--z85")
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::piped())
            .spawn()
            .unwrap();
        child.stdin.take().unwrap().write_all(b"Test").unwrap();
        let output = child.wait_with_output().unwrap();
        assert!(output.status.success());
        let stdout = String::from_utf8_lossy(&output.stdout);
        // Verify it produces valid Z85 output
        assert!(!stdout.trim().is_empty());
    }

    #[test]
    fn test_z85_roundtrip() {
        let input = b"TestData"; // 8 bytes = multiple of 4
        let mut child = cmd()
            .arg("--z85")
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::piped())
            .spawn()
            .unwrap();
        child.stdin.take().unwrap().write_all(input).unwrap();
        let enc = child.wait_with_output().unwrap();
        assert!(enc.status.success());

        let mut child = cmd()
            .arg("--z85")
            .arg("-d")
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::piped())
            .spawn()
            .unwrap();
        child.stdin.take().unwrap().write_all(&enc.stdout).unwrap();
        let dec = child.wait_with_output().unwrap();
        assert!(dec.status.success());
        assert_eq!(&dec.stdout, input);
    }

    #[test]
    fn test_z85_invalid_length() {
        // Z85 encoding requires input length to be a multiple of 4
        let mut child = cmd()
            .arg("--z85")
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::piped())
            .spawn()
            .unwrap();
        child.stdin.take().unwrap().write_all(b"Hi").unwrap();
        let output = child.wait_with_output().unwrap();
        assert!(!output.status.success());
    }

    // ---- Wrap tests ----

    #[test]
    fn test_wrap_flag() {
        let mut child = cmd()
            .arg("--base64")
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
            .write_all(b"Hello, World! This is a test.")
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
        let mut child = cmd()
            .arg("--base64")
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
            .write_all(b"Hello, World! This is a longer test input.")
            .unwrap();
        let output = child.wait_with_output().unwrap();
        assert!(output.status.success());
        let stdout = String::from_utf8_lossy(&output.stdout);
        let lines: Vec<&str> = stdout.lines().collect();
        assert_eq!(lines.len(), 1, "should be a single line with -w 0");
    }

    // ---- Ignore garbage tests ----

    #[test]
    fn test_ignore_garbage() {
        let mut child = cmd()
            .arg("--base64")
            .arg("-d")
            .arg("-i")
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::piped())
            .spawn()
            .unwrap();
        child
            .stdin
            .take()
            .unwrap()
            .write_all(b"SG!!Vs##bG8=\n")
            .unwrap();
        let output = child.wait_with_output().unwrap();
        assert!(output.status.success());
        assert_eq!(&output.stdout, b"Hello");
    }

    // ---- Empty input tests ----

    #[test]
    fn test_empty_input_base64() {
        let mut child = cmd()
            .arg("--base64")
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::piped())
            .spawn()
            .unwrap();
        child.stdin.take().unwrap().write_all(b"").unwrap();
        let output = child.wait_with_output().unwrap();
        assert!(output.status.success());
        // GNU basenc produces no output for empty input
        assert!(output.stdout.is_empty());
    }

    // ---- Unit tests for encoding functions ----

    #[test]
    fn test_base64_encode_fn() {
        assert_eq!(base64_encode(b"", BASE64_ALPHABET), "");
        assert_eq!(base64_encode(b"f", BASE64_ALPHABET), "Zg==");
        assert_eq!(base64_encode(b"fo", BASE64_ALPHABET), "Zm8=");
        assert_eq!(base64_encode(b"foo", BASE64_ALPHABET), "Zm9v");
        assert_eq!(base64_encode(b"foob", BASE64_ALPHABET), "Zm9vYg==");
        assert_eq!(base64_encode(b"fooba", BASE64_ALPHABET), "Zm9vYmE=");
        assert_eq!(base64_encode(b"foobar", BASE64_ALPHABET), "Zm9vYmFy");
    }

    #[test]
    fn test_base64_decode_fn() {
        let r = base64_decode(b"", &BASE64_DECODE, false);
        assert!(r.error.is_none());
        assert_eq!(r.data, b"");

        let r = base64_decode(b"Zg==", &BASE64_DECODE, false);
        assert!(r.error.is_none());
        assert_eq!(r.data, b"f");

        let r = base64_decode(b"Zm8=", &BASE64_DECODE, false);
        assert!(r.error.is_none());
        assert_eq!(r.data, b"fo");

        let r = base64_decode(b"Zm9v", &BASE64_DECODE, false);
        assert!(r.error.is_none());
        assert_eq!(r.data, b"foo");

        let r = base64_decode(b"Zm9vYmFy", &BASE64_DECODE, false);
        assert!(r.error.is_none());
        assert_eq!(r.data, b"foobar");

        // Auto-pad: incomplete final group should decode partial bytes + error
        let r = base64_decode(b"QQ", &BASE64_DECODE, false);
        assert!(r.error.is_some());
        assert_eq!(r.data, b"A");

        // 3 chars: GNU auto-pads (only 1 padding char missing), so no error
        let r = base64_decode(b"QWI", &BASE64_DECODE, false);
        assert!(r.error.is_none());
        assert_eq!(r.data, b"Ab");
    }

    #[test]
    fn test_base16_encode_fn() {
        assert_eq!(base16_encode(b""), "");
        assert_eq!(base16_encode(b"\x00"), "00");
        assert_eq!(base16_encode(b"\xff"), "FF");
        assert_eq!(base16_encode(b"Hello"), "48656C6C6F");
    }

    #[test]
    fn test_base16_decode_fn() {
        let r = base16_decode(b"", false);
        assert!(r.error.is_none());
        assert_eq!(r.data, b"");

        let r = base16_decode(b"00", false);
        assert!(r.error.is_none());
        assert_eq!(r.data, b"\x00");

        let r = base16_decode(b"FF", false);
        assert!(r.error.is_none());
        assert_eq!(r.data, b"\xff");

        let r = base16_decode(b"48656C6C6F", false);
        assert!(r.error.is_none());
        assert_eq!(r.data, b"Hello");

        // GNU basenc --base16 -d accepts lowercase hex
        let r = base16_decode(b"ff", false);
        assert!(r.error.is_none());
        assert_eq!(r.data, b"\xff");
    }

    #[test]
    fn test_base2msbf_encode_fn() {
        assert_eq!(base2msbf_encode(b"A"), "01000001");
        assert_eq!(base2msbf_encode(b"\x00"), "00000000");
        assert_eq!(base2msbf_encode(b"\xff"), "11111111");
    }

    #[test]
    fn test_base2lsbf_encode_fn() {
        assert_eq!(base2lsbf_encode(b"A"), "10000010");
        assert_eq!(base2lsbf_encode(b"\x00"), "00000000");
        assert_eq!(base2lsbf_encode(b"\xff"), "11111111");
    }

    #[test]
    fn test_z85_encode_fn() {
        // ZeroMQ Z85 reference test vector: 4 bytes [0x86, 0x4F, 0xD2, 0x6F] -> "HelloWorld" (partial)
        // Actually the reference: [0x86, 0x4F, 0xD2, 0x6F, 0xB5, 0x59, 0xF7, 0x5B] -> "HelloWorld"
        let input = b"\x86\x4F\xD2\x6F\xB5\x59\xF7\x5B";
        let encoded = z85_encode(input).unwrap();
        assert_eq!(encoded, "HelloWorld");
    }

    #[test]
    fn test_z85_decode_fn() {
        let r = z85_decode(b"HelloWorld", false);
        assert!(r.error.is_none());
        assert_eq!(r.data, b"\x86\x4F\xD2\x6F\xB5\x59\xF7\x5B");
    }

    #[test]
    fn test_compare_gnu_basenc_base64() {
        if Command::new("basenc").arg("--version").output().is_err() {
            return;
        }
        let input = b"Hello, World!\n";

        let mut gnu_child = match Command::new("basenc")
            .arg("--base64")
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
            .arg("--base64")
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::piped())
            .spawn()
            .unwrap();
        our_child.stdin.take().unwrap().write_all(input).unwrap();
        let our_out = our_child.wait_with_output().unwrap();
        assert_eq!(
            String::from_utf8_lossy(&our_out.stdout),
            String::from_utf8_lossy(&gnu_out.stdout),
            "Base64 encoding mismatch with GNU basenc"
        );
    }

    #[test]
    fn test_compare_gnu_basenc_base16() {
        if Command::new("basenc").arg("--version").output().is_err() {
            return;
        }
        let input = b"Hello\n";

        let mut gnu_child = match Command::new("basenc")
            .arg("--base16")
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
            .arg("--base16")
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::piped())
            .spawn()
            .unwrap();
        our_child.stdin.take().unwrap().write_all(input).unwrap();
        let our_out = our_child.wait_with_output().unwrap();
        assert_eq!(
            String::from_utf8_lossy(&our_out.stdout),
            String::from_utf8_lossy(&gnu_out.stdout),
            "Base16 encoding mismatch with GNU basenc"
        );
    }

    #[test]
    fn test_compare_gnu_basenc_base32() {
        if Command::new("basenc").arg("--version").output().is_err() {
            return;
        }
        let input = b"Hello\n";

        let mut gnu_child = match Command::new("basenc")
            .arg("--base32")
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
            .arg("--base32")
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::piped())
            .spawn()
            .unwrap();
        our_child.stdin.take().unwrap().write_all(input).unwrap();
        let our_out = our_child.wait_with_output().unwrap();
        assert_eq!(
            String::from_utf8_lossy(&our_out.stdout),
            String::from_utf8_lossy(&gnu_out.stdout),
            "Base32 encoding mismatch with GNU basenc"
        );
    }
}
