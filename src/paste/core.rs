use std::io::Write;

/// Configuration for the paste command.
pub struct PasteConfig {
    /// Delimiter characters, cycled through columns.
    pub delimiters: Vec<u8>,
    /// Serial mode: paste one file at a time.
    pub serial: bool,
    /// Use NUL as line terminator instead of newline.
    pub zero_terminated: bool,
}

impl Default for PasteConfig {
    fn default() -> Self {
        Self {
            delimiters: vec![b'\t'],
            serial: false,
            zero_terminated: false,
        }
    }
}

/// Parse delimiter string with escape sequences.
/// Supports: \n (newline), \t (tab), \\ (backslash), \0 (NUL), empty string (no delimiter).
pub fn parse_delimiters(s: &str) -> Vec<u8> {
    if s.is_empty() {
        return Vec::new();
    }
    let bytes = s.as_bytes();
    let mut result = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'\\' && i + 1 < bytes.len() {
            match bytes[i + 1] {
                b'n' => {
                    result.push(b'\n');
                    i += 2;
                }
                b't' => {
                    result.push(b'\t');
                    i += 2;
                }
                b'\\' => {
                    result.push(b'\\');
                    i += 2;
                }
                b'0' => {
                    result.push(0);
                    i += 2;
                }
                _ => {
                    // Unknown escape: treat backslash as literal
                    result.push(b'\\');
                    i += 1;
                }
            }
        } else {
            result.push(bytes[i]);
            i += 1;
        }
    }
    result
}

/// Output buffer size for streaming paste (1 MiB).
const BUF_SIZE: usize = 4 * 1024 * 1024;

/// Raw write to stdout fd 1. Returns any error encountered.
#[cfg(unix)]
pub fn raw_write_all(data: &[u8]) -> std::io::Result<()> {
    let mut written = 0;
    while written < data.len() {
        let ret = unsafe {
            libc::write(
                1,
                data[written..].as_ptr() as *const libc::c_void,
                (data.len() - written) as _,
            )
        };
        if ret > 0 {
            written += ret as usize;
        } else if ret == 0 {
            return Err(std::io::Error::new(
                std::io::ErrorKind::WriteZero,
                "write returned 0",
            ));
        } else {
            let err = std::io::Error::last_os_error();
            if err.kind() == std::io::ErrorKind::Interrupted {
                continue;
            }
            return Err(err);
        }
    }
    Ok(())
}

#[cfg(not(unix))]
pub fn raw_write_all(data: &[u8]) -> std::io::Result<()> {
    let stdout = std::io::stdout();
    let mut lock = stdout.lock();
    lock.write_all(data)?;
    lock.flush()
}

/// Streaming paste for the parallel (normal) mode.
/// Scans each file line-by-line with memchr on-the-fly — no pre-split offset arrays.
/// Uses a single 1MB output buffer with raw fd writes.
pub fn paste_parallel_stream(file_data: &[&[u8]], config: &PasteConfig) -> std::io::Result<()> {
    let terminator = if config.zero_terminated { 0u8 } else { b'\n' };
    let delims = &config.delimiters;
    let has_delims = !delims.is_empty();
    let nfiles = file_data.len();

    if nfiles == 0 || file_data.iter().all(|d| d.is_empty()) {
        return Ok(());
    }

    // Fast path: single file is a passthrough (output == input)
    if nfiles == 1 {
        let data = file_data[0];
        if data.is_empty() {
            return Ok(());
        }
        if *data.last().unwrap() == terminator {
            return raw_write_all(data);
        }
        raw_write_all(data)?;
        return raw_write_all(&[terminator]);
    }

    // Fast path: 2 files with single-byte delimiter (the most common case)
    if nfiles == 2 && delims.len() == 1 {
        return paste_two_files_streaming(file_data[0], file_data[1], delims[0], terminator);
    }

    // General N-file streaming paste
    paste_n_files_streaming(file_data, delims, has_delims, nfiles, terminator)
}

/// Fast path for 2-file paste: uses unsafe pointer writes and direct memchr scanning.
/// Avoids pre-split offset arrays entirely — scans both files in lockstep.
fn paste_two_files_streaming(
    data_a: &[u8],
    data_b: &[u8],
    delim: u8,
    terminator: u8,
) -> std::io::Result<()> {
    if data_a.is_empty() && data_b.is_empty() {
        return Ok(());
    }

    let buf_cap = BUF_SIZE;
    let mut buf: Vec<u8> = Vec::with_capacity(buf_cap + 65536);
    let mut pos: usize = 0;

    let mut cur_a: usize = 0;
    let mut cur_b: usize = 0;

    let ptr_a = data_a.as_ptr();
    let ptr_b = data_b.as_ptr();
    let len_a = data_a.len();
    let len_b = data_b.len();

    while cur_a < len_a || cur_b < len_b {
        // Find line boundaries in both files
        let (a_start, a_len, next_a) = if cur_a < len_a {
            if let Some(nl) = memchr::memchr(terminator, &data_a[cur_a..]) {
                (cur_a, nl, cur_a + nl + 1)
            } else {
                (cur_a, len_a - cur_a, len_a)
            }
        } else {
            (0, 0, cur_a)
        };

        let (b_start, b_len, next_b) = if cur_b < len_b {
            if let Some(nl) = memchr::memchr(terminator, &data_b[cur_b..]) {
                (cur_b, nl, cur_b + nl + 1)
            } else {
                (cur_b, len_b - cur_b, len_b)
            }
        } else {
            (0, 0, cur_b)
        };

        let out_len = a_len + 1 + b_len + 1;

        // Ensure buffer has space
        if pos + out_len > buf.capacity() {
            unsafe { buf.set_len(pos) };
            raw_write_all(&buf)?;
            buf.clear();
            pos = 0;
            if out_len > buf.capacity() {
                buf.reserve(out_len);
            }
        }

        // Write line with unsafe pointer copies
        unsafe {
            let base = buf.as_mut_ptr();
            if a_len > 0 {
                std::ptr::copy_nonoverlapping(ptr_a.add(a_start), base.add(pos), a_len);
                pos += a_len;
            }
            *base.add(pos) = delim;
            pos += 1;
            if b_len > 0 {
                std::ptr::copy_nonoverlapping(ptr_b.add(b_start), base.add(pos), b_len);
                pos += b_len;
            }
            *base.add(pos) = terminator;
            pos += 1;
        }

        cur_a = next_a;
        cur_b = next_b;

        // Flush when buffer is full
        if pos >= buf_cap {
            unsafe { buf.set_len(pos) };
            raw_write_all(&buf)?;
            buf.clear();
            pos = 0;
        }
    }

    // Final flush
    if pos > 0 {
        unsafe { buf.set_len(pos) };
        raw_write_all(&buf)?;
    }

    Ok(())
}

/// General N-file streaming paste with memchr cursors and unsafe pointer writes.
fn paste_n_files_streaming(
    file_data: &[&[u8]],
    delims: &[u8],
    has_delims: bool,
    nfiles: usize,
    terminator: u8,
) -> std::io::Result<()> {
    let mut cursors: Vec<usize> = vec![0; nfiles];
    let buf_cap = BUF_SIZE;
    let mut buf: Vec<u8> = Vec::with_capacity(buf_cap + 65536);
    let mut pos: usize = 0;

    loop {
        // Check if any file still has data before writing anything
        let mut any_data = false;
        for i in 0..nfiles {
            if cursors[i] < file_data[i].len() {
                any_data = true;
                break;
            }
        }
        if !any_data {
            break;
        }

        for file_idx in 0..nfiles {
            let data = file_data[file_idx];
            let cursor = cursors[file_idx];

            // Delimiter before columns 1..N
            if file_idx > 0 && has_delims {
                let d = unsafe { *delims.get_unchecked((file_idx - 1) % delims.len()) };
                if pos >= buf.capacity() {
                    unsafe { buf.set_len(pos) };
                    raw_write_all(&buf)?;
                    buf.clear();
                    pos = 0;
                }
                unsafe { *buf.as_mut_ptr().add(pos) = d };
                pos += 1;
            }

            if cursor < data.len() {
                let remaining = &data[cursor..];
                let (line_len, next) = if let Some(nl_pos) = memchr::memchr(terminator, remaining) {
                    (nl_pos, cursor + nl_pos + 1)
                } else {
                    (remaining.len(), data.len())
                };

                if line_len > 0 {
                    if pos + line_len > buf.capacity() {
                        unsafe { buf.set_len(pos) };
                        raw_write_all(&buf)?;
                        buf.clear();
                        pos = 0;
                        if line_len > buf.capacity() {
                            buf.reserve(line_len + 4096);
                        }
                    }
                    unsafe {
                        std::ptr::copy_nonoverlapping(
                            data.as_ptr().add(cursor),
                            buf.as_mut_ptr().add(pos),
                            line_len,
                        );
                    }
                    pos += line_len;
                }
                cursors[file_idx] = next;
            }
        }

        // Terminator
        if pos >= buf.capacity() {
            unsafe { buf.set_len(pos) };
            raw_write_all(&buf)?;
            buf.clear();
            pos = 0;
        }
        unsafe { *buf.as_mut_ptr().add(pos) = terminator };
        pos += 1;

        // Flush when buffer is full
        if pos >= buf_cap {
            unsafe { buf.set_len(pos) };
            raw_write_all(&buf)?;
            buf.clear();
            pos = 0;
        }
    }

    // Final flush
    if pos > 0 {
        unsafe { buf.set_len(pos) };
        raw_write_all(&buf)?;
    }

    Ok(())
}

/// Streaming paste for serial mode.
/// For each file, join all lines with the delimiter list (cycling).
pub fn paste_serial_stream(file_data: &[&[u8]], config: &PasteConfig) -> std::io::Result<()> {
    let terminator = if config.zero_terminated { 0u8 } else { b'\n' };
    let delims = &config.delimiters;
    let has_delims = !delims.is_empty();

    let mut buf: Vec<u8> = Vec::with_capacity(BUF_SIZE + 4096);

    for data in file_data {
        if data.is_empty() {
            buf.push(terminator);
            if buf.len() >= BUF_SIZE {
                raw_write_all(&buf)?;
                buf.clear();
            }
            continue;
        }

        let mut cursor = 0usize;
        let mut line_idx = 0usize;

        while cursor < data.len() {
            // Delimiter before lines 1..N
            if line_idx > 0 && has_delims {
                buf.push(delims[(line_idx - 1) % delims.len()]);
            }

            let remaining = &data[cursor..];
            if let Some(nl_pos) = memchr::memchr(terminator, remaining) {
                buf.extend_from_slice(&remaining[..nl_pos]);
                cursor += nl_pos + 1;
            } else {
                buf.extend_from_slice(remaining);
                cursor = data.len();
            }

            line_idx += 1;

            if buf.len() >= BUF_SIZE {
                raw_write_all(&buf)?;
                buf.clear();
            }
        }

        buf.push(terminator);
        if buf.len() >= BUF_SIZE {
            raw_write_all(&buf)?;
            buf.clear();
        }
    }

    // Final flush
    if !buf.is_empty() {
        raw_write_all(&buf)?;
    }

    Ok(())
}

/// Streaming paste entry point. Writes directly to stdout using raw fd writes.
pub fn paste_stream(file_data: &[&[u8]], config: &PasteConfig) -> std::io::Result<()> {
    if config.serial {
        paste_serial_stream(file_data, config)
    } else {
        paste_parallel_stream(file_data, config)
    }
}

/// Pre-split a file into line offset pairs using a single SIMD memchr_iter pass.
/// Returns a Vec of (start, end) byte offsets — one per line.
#[inline]
fn presplit_lines(data: &[u8], terminator: u8) -> Vec<(u32, u32)> {
    if data.is_empty() {
        return Vec::new();
    }
    assert!(
        data.len() <= u32::MAX as usize,
        "presplit_lines: data exceeds 4 GiB"
    );
    // Heuristic: assume average line length ~40 bytes to avoid a count pre-scan.
    let estimated_lines = data.len() / 40 + 1;
    let mut offsets = Vec::with_capacity(estimated_lines);
    let mut start = 0u32;
    for pos in memchr::memchr_iter(terminator, data) {
        offsets.push((start, pos as u32));
        start = pos as u32 + 1;
    }
    if data.last() != Some(&terminator) && (start as usize) < data.len() {
        offsets.push((start, data.len() as u32));
    }
    offsets
}

/// Paste files in normal (parallel) mode and return the output buffer.
/// Pre-splits files into line offsets (one SIMD pass each), then the main
/// loop uses O(1) array indexing instead of per-line memchr calls.
/// Uses unsafe raw pointer writes to eliminate bounds-check overhead.
pub fn paste_parallel_to_vec(file_data: &[&[u8]], config: &PasteConfig) -> Vec<u8> {
    let terminator = if config.zero_terminated { 0u8 } else { b'\n' };
    let delims = &config.delimiters;

    if file_data.is_empty() || file_data.iter().all(|d| d.is_empty()) {
        return Vec::new();
    }

    // Pre-split each file into line offsets — single SIMD pass per file.
    let file_lines: Vec<Vec<(u32, u32)>> = file_data
        .iter()
        .map(|data| presplit_lines(data, terminator))
        .collect();

    let max_lines = file_lines.iter().map(|l| l.len()).max().unwrap_or(0);
    if max_lines == 0 {
        return Vec::new();
    }

    // Compute exact output size to avoid reallocation.
    let nfiles = file_data.len();
    let has_delims = !delims.is_empty();
    let delims_per_line = if has_delims && nfiles > 1 {
        nfiles - 1
    } else {
        0
    };

    let mut exact_size = max_lines * (delims_per_line + 1); // delimiters + terminators
    for fl in &file_lines {
        for &(s, e) in fl.iter() {
            exact_size += (e - s) as usize;
        }
    }
    // Empty-file lines contribute nothing but delimiter slots are already counted

    let mut output = Vec::with_capacity(exact_size);

    // SAFETY: We computed exact_size above. All writes go through raw pointers
    // with total bytes written == exact_size. We set_len at the end.
    unsafe {
        let base: *mut u8 = output.as_mut_ptr();
        let mut pos = 0usize;

        for line_idx in 0..max_lines {
            for file_idx in 0..nfiles {
                if file_idx > 0 && has_delims {
                    *base.add(pos) = delims[(file_idx - 1) % delims.len()];
                    pos += 1;
                }
                let lines = &file_lines[file_idx];
                if line_idx < lines.len() {
                    let (s, e) = *lines.get_unchecked(line_idx);
                    let len = (e - s) as usize;
                    if len > 0 {
                        std::ptr::copy_nonoverlapping(
                            file_data.get_unchecked(file_idx).as_ptr().add(s as usize),
                            base.add(pos),
                            len,
                        );
                        pos += len;
                    }
                }
            }
            *base.add(pos) = terminator;
            pos += 1;
        }

        assert_eq!(pos, exact_size, "exact_size miscalculated");
        output.set_len(pos);
    }

    output
}

/// Paste files in serial mode and return the output buffer.
/// For each file, join all lines with the delimiter list (cycling).
/// Pre-splits lines using SIMD memchr, then iterates offset pairs.
pub fn paste_serial_to_vec(file_data: &[&[u8]], config: &PasteConfig) -> Vec<u8> {
    let terminator = if config.zero_terminated { 0u8 } else { b'\n' };
    let delims = &config.delimiters;
    let has_delims = !delims.is_empty();

    // Estimate output size
    let total_input: usize = file_data.iter().map(|d| d.len()).sum();
    let mut output = Vec::with_capacity(total_input + file_data.len());

    for data in file_data {
        if data.is_empty() {
            output.push(terminator);
            continue;
        }
        let lines = presplit_lines(data, terminator);
        if lines.is_empty() {
            output.push(terminator);
            continue;
        }
        // First line: no leading delimiter
        let (s, e) = lines[0];
        output.extend_from_slice(&data[s as usize..e as usize]);
        // Subsequent lines: prepend cycling delimiter
        for (i, &(s, e)) in lines[1..].iter().enumerate() {
            if has_delims {
                output.push(delims[i % delims.len()]);
            }
            output.extend_from_slice(&data[s as usize..e as usize]);
        }
        output.push(terminator);
    }

    output
}

/// Main paste entry point. Writes directly to the provided writer.
pub fn paste(
    file_data: &[&[u8]],
    config: &PasteConfig,
    out: &mut impl Write,
) -> std::io::Result<()> {
    let output = if config.serial {
        paste_serial_to_vec(file_data, config)
    } else {
        paste_parallel_to_vec(file_data, config)
    };
    out.write_all(&output)
}

/// Build the paste output as a Vec, then return it for the caller to write.
/// This allows the binary to use raw write() for maximum throughput.
pub fn paste_to_vec(file_data: &[&[u8]], config: &PasteConfig) -> Vec<u8> {
    if config.serial {
        paste_serial_to_vec(file_data, config)
    } else {
        paste_parallel_to_vec(file_data, config)
    }
}
