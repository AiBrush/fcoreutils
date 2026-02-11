use std::io::{self, BufWriter, Read, Write};

use base64_simd::AsOut;

const BASE64_ENGINE: &base64_simd::Base64 = &base64_simd::STANDARD;

/// Streaming encode chunk: 4MB aligned to 3 bytes for maximum throughput.
const STREAM_ENCODE_CHUNK: usize = 4 * 1024 * 1024 - (4 * 1024 * 1024 % 3);

/// Chunk size for no-wrap encoding: 4MB aligned to 3 bytes.
const NOWRAP_CHUNK: usize = 4 * 1024 * 1024 - (4 * 1024 * 1024 % 3);

/// Encode data and write to output with line wrapping.
/// Uses SIMD encoding with reusable buffers for maximum throughput.
pub fn encode_to_writer(data: &[u8], wrap_col: usize, out: &mut impl Write) -> io::Result<()> {
    if data.is_empty() {
        return Ok(());
    }

    if wrap_col == 0 {
        return encode_no_wrap(data, out);
    }

    encode_wrapped(data, wrap_col, out)
}

/// Encode without wrapping: process in 4MB chunks for bounded memory usage.
/// Each chunk is SIMD-encoded and written immediately. Reuses a single
/// encode buffer across chunks to avoid repeated allocation.
fn encode_no_wrap(data: &[u8], out: &mut impl Write) -> io::Result<()> {
    let enc_max = BASE64_ENGINE.encoded_length(NOWRAP_CHUNK);
    let mut buf = vec![0u8; enc_max];

    for chunk in data.chunks(NOWRAP_CHUNK) {
        let enc_len = BASE64_ENGINE.encoded_length(chunk.len());
        let encoded = BASE64_ENGINE.encode(chunk, buf[..enc_len].as_out());
        out.write_all(encoded)?;
    }
    Ok(())
}

/// Encode with line wrapping using large cache-friendly chunks.
/// Each chunk is SIMD-encoded, then wrapped with newlines in a pre-allocated
/// buffer using direct slice copies, and written with a single write_all.
fn encode_wrapped(data: &[u8], wrap_col: usize, out: &mut impl Write) -> io::Result<()> {
    let bytes_per_line = wrap_col * 3 / 4;

    // Process ~4MB of input per chunk for maximum throughput.
    // Aligned to bytes_per_line for clean line boundaries.
    let lines_per_chunk = (4 * 1024 * 1024) / bytes_per_line;
    let chunk_input = lines_per_chunk * bytes_per_line;
    let chunk_encoded_max = BASE64_ENGINE.encoded_length(chunk_input);

    // Pre-allocate reusable buffers (no per-chunk allocation).
    let mut encode_buf = vec![0u8; chunk_encoded_max];
    // Wrapped output: each line is wrap_col + 1 bytes (content + newline).
    let wrapped_max = (lines_per_chunk + 1) * (wrap_col + 1);
    let mut wrap_buf = vec![0u8; wrapped_max];

    for chunk in data.chunks(chunk_input) {
        let enc_len = BASE64_ENGINE.encoded_length(chunk.len());
        let encoded = BASE64_ENGINE.encode(chunk, encode_buf[..enc_len].as_out());

        // Build wrapped output with direct slice copies (no Vec overhead).
        let mut rp = 0;
        let mut wp = 0;

        while rp + wrap_col <= encoded.len() {
            wrap_buf[wp..wp + wrap_col].copy_from_slice(&encoded[rp..rp + wrap_col]);
            wp += wrap_col;
            wrap_buf[wp] = b'\n';
            wp += 1;
            rp += wrap_col;
        }

        if rp < encoded.len() {
            let remaining = encoded.len() - rp;
            wrap_buf[wp..wp + remaining].copy_from_slice(&encoded[rp..rp + remaining]);
            wp += remaining;
            wrap_buf[wp] = b'\n';
            wp += 1;
        }

        // Single write per chunk (BufWriter bypasses buffer for large writes).
        out.write_all(&wrap_buf[..wp])?;
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
        let cleaned = strip_non_base64(data);
        return decode_clean(out, &cleaned);
    }

    // Fast path: strip newlines with memchr (SIMD), then SIMD decode
    decode_stripping_whitespace(data, out)
}

/// Decode by stripping all whitespace from the entire input at once,
/// then performing a single SIMD decode pass. Avoids block-boundary
/// overhead and gives the decoder the maximum possible contiguous input.
fn decode_stripping_whitespace(data: &[u8], out: &mut impl Write) -> io::Result<()> {
    // Quick check: any whitespace at all?
    if memchr::memchr(b'\n', data).is_none() && !data.iter().any(|&b| is_whitespace(b)) {
        return decode_clean(out, data);
    }

    // Strip newlines from entire input in a single pass using SIMD memchr.
    // Pre-allocate to input size (upper bound; actual will be slightly smaller).
    let mut clean = Vec::with_capacity(data.len());
    let mut last = 0;
    for pos in memchr::memchr_iter(b'\n', data) {
        if pos > last {
            clean.extend_from_slice(&data[last..pos]);
        }
        last = pos + 1;
    }
    if last < data.len() {
        clean.extend_from_slice(&data[last..]);
    }

    // Handle rare case of non-newline whitespace (CR, tab, etc.)
    if clean.iter().any(|&b| is_whitespace(b)) {
        clean.retain(|&b| !is_whitespace(b));
    }

    if clean.is_empty() {
        return Ok(());
    }

    // Single SIMD decode of entire cleaned input (no block boundaries).
    match BASE64_ENGINE.decode_inplace(&mut clean) {
        Ok(decoded) => out.write_all(decoded),
        Err(_) => Err(io::Error::new(io::ErrorKind::InvalidData, "invalid input")),
    }
}

/// Decode clean base64 data (no whitespace) with a single SIMD pass.
fn decode_clean(out: &mut impl Write, data: &[u8]) -> io::Result<()> {
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

/// Strip non-base64 characters (for -i / --ignore-garbage).
fn strip_non_base64(data: &[u8]) -> Vec<u8> {
    data.iter()
        .copied()
        .filter(|&b| is_base64_char(b))
        .collect()
}

/// Check if a byte is a valid base64 alphabet character or padding.
#[inline]
fn is_base64_char(b: u8) -> bool {
    b.is_ascii_alphanumeric() || b == b'+' || b == b'/' || b == b'='
}

/// Check if a byte is ASCII whitespace.
#[inline]
fn is_whitespace(b: u8) -> bool {
    matches!(b, b' ' | b'\t' | b'\n' | b'\r' | 0x0b | 0x0c)
}

/// Stream-encode from a reader to a writer. Used for stdin processing.
/// Uses 4MB read chunks and batches wrapped output for minimum syscalls.
pub fn encode_stream(
    reader: &mut impl Read,
    wrap_col: usize,
    writer: &mut impl Write,
) -> io::Result<()> {
    let mut buf = vec![0u8; STREAM_ENCODE_CHUNK];
    let mut out = BufWriter::with_capacity(2 * 1024 * 1024, writer);

    let encode_buf_size = BASE64_ENGINE.encoded_length(STREAM_ENCODE_CHUNK);
    let mut encode_buf = vec![0u8; encode_buf_size];

    if wrap_col == 0 {
        // No wrapping: encode each chunk and write directly.
        loop {
            let n = read_full(reader, &mut buf)?;
            if n == 0 {
                break;
            }
            let enc_len = BASE64_ENGINE.encoded_length(n);
            let encoded = BASE64_ENGINE.encode(&buf[..n], encode_buf[..enc_len].as_out());
            out.write_all(encoded)?;
        }
    } else {
        // Wrapping: batch wrapped output into a pre-allocated buffer.
        // For 4MB input at 76-col wrap, wrapped output is ~5.6MB.
        let max_wrapped = encode_buf_size + (encode_buf_size / wrap_col + 2);
        let mut wrap_buf = vec![0u8; max_wrapped];
        let mut col = 0usize;

        loop {
            let n = read_full(reader, &mut buf)?;
            if n == 0 {
                break;
            }
            let enc_len = BASE64_ENGINE.encoded_length(n);
            let encoded = BASE64_ENGINE.encode(&buf[..n], encode_buf[..enc_len].as_out());

            // Build wrapped output in wrap_buf, then single write.
            let wp = build_wrapped_output(encoded, wrap_col, &mut col, &mut wrap_buf);
            out.write_all(&wrap_buf[..wp])?;
        }

        if col > 0 {
            out.write_all(b"\n")?;
        }
    }

    out.flush()
}

/// Build wrapped output into a pre-allocated buffer.
/// Returns the number of bytes written to wrap_buf.
/// Updates `col` to track the current column position across calls.
#[inline]
fn build_wrapped_output(
    data: &[u8],
    wrap_col: usize,
    col: &mut usize,
    wrap_buf: &mut [u8],
) -> usize {
    let mut rp = 0;
    let mut wp = 0;

    while rp < data.len() {
        let space = wrap_col - *col;
        let avail = data.len() - rp;

        if avail <= space {
            wrap_buf[wp..wp + avail].copy_from_slice(&data[rp..rp + avail]);
            wp += avail;
            *col += avail;
            if *col == wrap_col {
                wrap_buf[wp] = b'\n';
                wp += 1;
                *col = 0;
            }
            break;
        } else {
            wrap_buf[wp..wp + space].copy_from_slice(&data[rp..rp + space]);
            wp += space;
            wrap_buf[wp] = b'\n';
            wp += 1;
            rp += space;
            *col = 0;
        }
    }

    wp
}

/// Stream-decode from a reader to a writer. Used for stdin processing.
pub fn decode_stream(
    reader: &mut impl Read,
    ignore_garbage: bool,
    writer: &mut impl Write,
) -> io::Result<()> {
    let mut data = Vec::new();
    reader.read_to_end(&mut data)?;

    let mut out = BufWriter::with_capacity(2 * 1024 * 1024, writer);
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
