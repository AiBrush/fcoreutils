use std::io::{self, BufWriter, Read, Write};

/// Size of chunks for streaming encode/decode. 64KB aligned to 3 bytes for encoding.
const ENCODE_CHUNK: usize = 64 * 1024 - (64 * 1024 % 3); // 65,535 → 65,535 is divisible by 3? No. 65536/3=21845.33. So 21845*3=65535. Yes!
/// For decode, we read in chunks aligned to 4 bytes.
#[allow(dead_code)]
const DECODE_CHUNK: usize = 64 * 1024;

const BASE64_ENGINE: &base64_simd::Base64 = &base64_simd::STANDARD;

/// Encode data and write to output with line wrapping.
pub fn encode_to_writer(data: &[u8], wrap_col: usize, out: &mut impl Write) -> io::Result<()> {
    if data.is_empty() {
        return Ok(());
    }

    // Encode in chunks to handle large data without huge allocations.
    // Process in chunks of ENCODE_CHUNK bytes (divisible by 3 for clean base64 boundaries).
    let mut col = 0usize;

    for chunk in data.chunks(ENCODE_CHUNK) {
        let encoded = BASE64_ENGINE.encode_to_string(chunk);
        if wrap_col == 0 {
            out.write_all(encoded.as_bytes())?;
        } else {
            write_wrapped(out, encoded.as_bytes(), wrap_col, &mut col)?;
        }
    }

    // Final newline: GNU adds a trailing newline only when wrapping is enabled.
    // With -w 0, no trailing newline is emitted.
    if wrap_col > 0 && col > 0 {
        out.write_all(b"\n")?;
    }

    Ok(())
}

/// Write base64 text with line wrapping, tracking current column position.
fn write_wrapped(
    out: &mut impl Write,
    data: &[u8],
    wrap_col: usize,
    col: &mut usize,
) -> io::Result<()> {
    let mut remaining = data;

    while !remaining.is_empty() {
        let space = wrap_col - *col;
        if remaining.len() <= space {
            out.write_all(remaining)?;
            *col += remaining.len();
            if *col == wrap_col {
                out.write_all(b"\n")?;
                *col = 0;
            }
            break;
        } else {
            out.write_all(&remaining[..space])?;
            out.write_all(b"\n")?;
            remaining = &remaining[space..];
            *col = 0;
        }
    }

    Ok(())
}

/// Decode base64 data and write to output.
/// When `ignore_garbage` is true, strip all non-base64 characters.
/// When false, only strip whitespace (standard behavior).
pub fn decode_to_writer(
    data: &[u8],
    ignore_garbage: bool,
    out: &mut impl Write,
) -> io::Result<()> {
    if data.is_empty() {
        return Ok(());
    }

    if ignore_garbage {
        // Strip everything that's not in the base64 alphabet or '=' padding
        let cleaned: Vec<u8> = data
            .iter()
            .copied()
            .filter(|&b| is_base64_char(b))
            .collect();
        decode_clean_data(&cleaned, out)
    } else {
        // Use forgiving decode which strips whitespace
        decode_forgiving(data, out)
    }
}

/// Decode already-cleaned base64 data (no whitespace/garbage).
fn decode_clean_data(data: &[u8], out: &mut impl Write) -> io::Result<()> {
    if data.is_empty() {
        return Ok(());
    }
    match BASE64_ENGINE.decode_to_vec(data) {
        Ok(decoded) => {
            out.write_all(&decoded)?;
            Ok(())
        }
        Err(_) => Err(io::Error::new(io::ErrorKind::InvalidData, "invalid input")),
    }
}

/// Decode with forgiving mode (strips whitespace, tolerates missing padding).
fn decode_forgiving(data: &[u8], out: &mut impl Write) -> io::Result<()> {
    match base64_simd::forgiving_decode_to_vec(data) {
        Ok(decoded) => {
            out.write_all(&decoded)?;
            Ok(())
        }
        Err(_) => Err(io::Error::new(io::ErrorKind::InvalidData, "invalid input")),
    }
}

/// Check if a byte is a valid base64 alphabet character or padding.
#[inline]
fn is_base64_char(b: u8) -> bool {
    b.is_ascii_alphanumeric() || b == b'+' || b == b'/' || b == b'='
}

/// Stream-encode from a reader to a writer. Used for stdin processing.
pub fn encode_stream(
    reader: &mut impl Read,
    wrap_col: usize,
    writer: &mut impl Write,
) -> io::Result<()> {
    let mut buf = vec![0u8; ENCODE_CHUNK];
    let mut col = 0usize;
    let mut out = BufWriter::new(writer);

    loop {
        // Read exactly ENCODE_CHUNK bytes (or less at EOF) for clean 3-byte alignment
        let n = read_full(reader, &mut buf)?;
        if n == 0 {
            break;
        }

        let encoded = BASE64_ENGINE.encode_to_string(&buf[..n]);

        if wrap_col == 0 {
            out.write_all(encoded.as_bytes())?;
        } else {
            write_wrapped(&mut out, encoded.as_bytes(), wrap_col, &mut col)?;
        }
    }

    // Final newline: GNU adds a trailing newline only when wrapping is enabled.
    // With -w 0, no trailing newline is emitted.
    if wrap_col > 0 && col > 0 {
        out.write_all(b"\n")?;
    }

    out.flush()
}

/// Stream-decode from a reader to a writer. Used for stdin processing.
pub fn decode_stream(
    reader: &mut impl Read,
    ignore_garbage: bool,
    writer: &mut impl Write,
) -> io::Result<()> {
    // For streaming decode, read all input first since base64 has padding semantics.
    let mut data = Vec::new();
    reader.read_to_end(&mut data)?;

    let mut out = BufWriter::new(writer);
    decode_to_writer(&data, ignore_garbage, &mut out)?;
    out.flush()
}

/// Read as many bytes as possible into buf, retrying on partial reads.
fn read_full(reader: &mut impl Read, buf: &mut [u8]) -> io::Result<usize> {
    let mut total = 0;
    while total < buf.len() {
        match reader.read(&mut buf[total..]) {
            Ok(0) => break,
            Ok(n) => total += n,
            Err(e) if e.kind() == io::ErrorKind::Interrupted => continue,
            Err(e) => return Err(e),
        }
    }
    Ok(total)
}
