use std::io::{self, BufWriter, Read, Write};

use base64_simd::AsOut;

const BASE64_ENGINE: &base64_simd::Base64 = &base64_simd::STANDARD;

/// Streaming encode chunk: 1MB aligned to 3 bytes.
const STREAM_ENCODE_CHUNK: usize = 1024 * 1024 - (1024 * 1024 % 3);

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

/// Encode without wrapping: use cache-friendly chunks with reusable buffer.
fn encode_no_wrap(data: &[u8], out: &mut impl Write) -> io::Result<()> {
    // Encode in ~1MB chunks to stay cache-friendly and avoid huge allocations.
    const CHUNK_SIZE: usize = 1024 * 1024 - (1024 * 1024 % 3);
    let max_encoded = BASE64_ENGINE.encoded_length(CHUNK_SIZE);
    let mut encode_buf = vec![0u8; max_encoded];

    for chunk in data.chunks(CHUNK_SIZE) {
        let enc_len = BASE64_ENGINE.encoded_length(chunk.len());
        let encoded = BASE64_ENGINE.encode(chunk, encode_buf[..enc_len].as_out());
        out.write_all(encoded)?;
    }

    Ok(())
}

/// Encode with line wrapping using cache-friendly chunks.
/// Each chunk is encoded with SIMD into a reusable buffer, then wrapped
/// and written as a contiguous block. Chunk size fits in L2 cache.
fn encode_wrapped(data: &[u8], wrap_col: usize, out: &mut impl Write) -> io::Result<()> {
    let bytes_per_line = wrap_col * 3 / 4;

    // Chunk size: ~64KB of input → ~87KB encoded → fits in L2 cache.
    // Aligned to bytes_per_line for clean line boundaries.
    let lines_per_chunk = 65536 / bytes_per_line;
    let chunk_input = lines_per_chunk * bytes_per_line;
    let chunk_encoded_max = BASE64_ENGINE.encoded_length(chunk_input);

    // Reuse encode buffer across chunks (no per-chunk allocation).
    let mut encode_buf = vec![0u8; chunk_encoded_max];

    for chunk in data.chunks(chunk_input) {
        let enc_len = BASE64_ENGINE.encoded_length(chunk.len());
        let encoded = BASE64_ENGINE.encode(chunk, encode_buf[..enc_len].as_out());

        // Write lines directly to output (BufWriter handles batching).
        for line in encoded.chunks(wrap_col) {
            out.write_all(line)?;
            out.write_all(b"\n")?;
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
        let cleaned = strip_non_base64(data);
        return decode_clean(out, &cleaned);
    }

    // Fast path: strip newlines with memchr (SIMD), then SIMD decode
    decode_stripping_whitespace(data, out)
}

/// Decode by stripping whitespace with memchr (SIMD) then decoding in-place.
/// Uses cache-friendly blocks to avoid huge intermediate allocations.
fn decode_stripping_whitespace(data: &[u8], out: &mut impl Write) -> io::Result<()> {
    // Quick check: any whitespace at all?
    if memchr::memchr(b'\n', data).is_none() && !data.iter().any(|&b| is_whitespace(b)) {
        return decode_clean(out, data);
    }

    // Process in cache-friendly blocks (~256KB each).
    // Each block: strip newlines, align to 4-byte groups, decode in-place.
    // This avoids allocating a huge ~141MB intermediate buffer.
    const BLOCK_SIZE: usize = 256 * 1024;
    let mut clean_buf = Vec::with_capacity(BLOCK_SIZE + 4);
    let mut leftover: Vec<u8> = Vec::new();

    let num_blocks = (data.len() + BLOCK_SIZE - 1) / BLOCK_SIZE;

    for (block_idx, block) in data.chunks(BLOCK_SIZE).enumerate() {
        clean_buf.clear();

        // Prepend leftover from previous block
        if !leftover.is_empty() {
            clean_buf.extend_from_slice(&leftover);
            leftover.clear();
        }

        // Strip newlines using memchr (SIMD-accelerated)
        let mut last = 0;
        for pos in memchr::memchr_iter(b'\n', block) {
            if pos > last {
                clean_buf.extend_from_slice(&block[last..pos]);
            }
            last = pos + 1;
        }
        if last < block.len() {
            clean_buf.extend_from_slice(&block[last..]);
        }

        // Handle rare case of other whitespace (CR, tab, etc.)
        if clean_buf.iter().any(|&b| is_whitespace(b)) {
            clean_buf.retain(|&b| !is_whitespace(b));
        }

        let is_last = block_idx == num_blocks - 1;

        if !is_last {
            // Trim to multiple of 4, save excess for next block
            let excess = clean_buf.len() % 4;
            if excess > 0 {
                leftover.extend_from_slice(&clean_buf[clean_buf.len() - excess..]);
                clean_buf.truncate(clean_buf.len() - excess);
            }
        }

        if clean_buf.is_empty() {
            continue;
        }

        // Decode in-place (no extra allocation)
        match BASE64_ENGINE.decode_inplace(&mut clean_buf) {
            Ok(decoded) => out.write_all(decoded)?,
            Err(_) => {
                return Err(io::Error::new(io::ErrorKind::InvalidData, "invalid input"))
            }
        }
    }

    Ok(())
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
pub fn encode_stream(
    reader: &mut impl Read,
    wrap_col: usize,
    writer: &mut impl Write,
) -> io::Result<()> {
    let mut buf = vec![0u8; STREAM_ENCODE_CHUNK];
    let mut col = 0usize;
    let mut out = BufWriter::with_capacity(256 * 1024, writer);

    let encode_buf_size = BASE64_ENGINE.encoded_length(STREAM_ENCODE_CHUNK);
    let mut encode_buf = vec![0u8; encode_buf_size];

    loop {
        let n = read_full(reader, &mut buf)?;
        if n == 0 {
            break;
        }

        let enc_len = BASE64_ENGINE.encoded_length(n);
        let encoded = BASE64_ENGINE.encode(&buf[..n], encode_buf[..enc_len].as_out());

        if wrap_col == 0 {
            out.write_all(encoded)?;
        } else {
            write_wrapped(&mut out, encoded, wrap_col, &mut col)?;
        }
    }

    if wrap_col > 0 && col > 0 {
        out.write_all(b"\n")?;
    }

    out.flush()
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

/// Stream-decode from a reader to a writer. Used for stdin processing.
pub fn decode_stream(
    reader: &mut impl Read,
    ignore_garbage: bool,
    writer: &mut impl Write,
) -> io::Result<()> {
    let mut data = Vec::new();
    reader.read_to_end(&mut data)?;

    let mut out = BufWriter::with_capacity(256 * 1024, writer);
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
