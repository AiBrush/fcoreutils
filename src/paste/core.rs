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
const BUF_SIZE: usize = 1024 * 1024;

/// Raw write to stdout fd 1. Returns any error encountered.
#[cfg(unix)]
fn raw_write_all(data: &[u8]) -> std::io::Result<()> {
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
fn raw_write_all(data: &[u8]) -> std::io::Result<()> {
    let stdout = std::io::stdout();
    let mut lock = stdout.lock();
    lock.write_all(data)?;
    lock.flush()
}

/// A streaming output writer that buffers into a fixed-size buffer
/// and flushes via raw libc::write on Unix for minimal overhead.
struct RawBufWriter {
    buf: Vec<u8>,
    error: Option<std::io::Error>,
}

impl RawBufWriter {
    fn new() -> Self {
        let mut buf = Vec::with_capacity(BUF_SIZE);
        // Touch all pages upfront to avoid page faults during hot loop
        unsafe {
            std::ptr::write_bytes(buf.as_mut_ptr(), 0, BUF_SIZE);
        }
        Self { buf, error: None }
    }

    /// Append a single byte. Flushes if buffer is full.
    #[inline(always)]
    fn push(&mut self, b: u8) {
        if self.buf.len() >= BUF_SIZE {
            self.flush_buf();
        }
        self.buf.push(b);
    }

    /// Append a slice. Flushes as needed for large slices.
    #[inline(always)]
    fn extend(&mut self, data: &[u8]) {
        let avail = BUF_SIZE - self.buf.len();
        if data.len() <= avail {
            self.buf.extend_from_slice(data);
        } else {
            self.extend_slow(data);
        }
    }

    #[cold]
    fn extend_slow(&mut self, data: &[u8]) {
        if self.error.is_some() {
            return;
        }
        let avail = BUF_SIZE - self.buf.len();
        // Fill current buffer
        self.buf.extend_from_slice(&data[..avail]);
        self.flush_buf();
        let mut remaining = &data[avail..];
        // Write full BUF_SIZE chunks directly, bypassing the buffer
        while remaining.len() >= BUF_SIZE {
            if let Err(e) = raw_write_all(&remaining[..BUF_SIZE]) {
                self.error = Some(e);
                return;
            }
            remaining = &remaining[BUF_SIZE..];
        }
        // Buffer the tail
        if !remaining.is_empty() {
            self.buf.extend_from_slice(remaining);
        }
    }

    /// Flush internal buffer.
    fn flush_buf(&mut self) {
        if !self.buf.is_empty() && self.error.is_none() {
            if let Err(e) = raw_write_all(&self.buf) {
                self.error = Some(e);
            }
            self.buf.clear();
        }
    }

    /// Finish: flush remaining data and return any error.
    fn finish(mut self) -> std::io::Result<()> {
        self.flush_buf();
        match self.error {
            Some(e) => Err(e),
            None => Ok(()),
        }
    }
}

/// Fast path for the common case: 2 files, single-byte delimiter (usually tab).
/// Scans both files simultaneously with memchr, writing results into a 1MB buffer.
/// Uses unsafe pointer writes to eliminate bounds checks in the hot loop.
fn paste_two_files_fast(
    data_a: &[u8],
    data_b: &[u8],
    delim: u8,
    terminator: u8,
) -> std::io::Result<()> {
    let buf_cap = BUF_SIZE;
    let mut buf: Vec<u8> = Vec::with_capacity(buf_cap);
    // Pre-fault pages
    unsafe {
        std::ptr::write_bytes(buf.as_mut_ptr(), 0, buf_cap);
    }

    let base = buf.as_mut_ptr();
    let mut pos: usize = 0;
    let mut cur_a: usize = 0;
    let mut cur_b: usize = 0;
    let done_a = data_a.is_empty();
    let done_b = data_b.is_empty();

    if done_a && done_b {
        return Ok(());
    }

    loop {
        let a_exhausted = cur_a >= data_a.len();
        let b_exhausted = cur_b >= data_b.len();
        if a_exhausted && b_exhausted {
            break;
        }

        // Find line end in file A
        let (line_a_ptr, line_a_len, new_cur_a) = if !a_exhausted {
            match memchr::memchr(terminator, &data_a[cur_a..]) {
                Some(off) => (data_a.as_ptr().wrapping_add(cur_a), off, cur_a + off + 1),
                None => (
                    data_a.as_ptr().wrapping_add(cur_a),
                    data_a.len() - cur_a,
                    data_a.len(),
                ),
            }
        } else {
            (std::ptr::null(), 0, cur_a)
        };

        // Find line end in file B
        let (line_b_ptr, line_b_len, new_cur_b) = if !b_exhausted {
            match memchr::memchr(terminator, &data_b[cur_b..]) {
                Some(off) => (data_b.as_ptr().wrapping_add(cur_b), off, cur_b + off + 1),
                None => (
                    data_b.as_ptr().wrapping_add(cur_b),
                    data_b.len() - cur_b,
                    data_b.len(),
                ),
            }
        } else {
            (std::ptr::null(), 0, cur_b)
        };

        cur_a = new_cur_a;
        cur_b = new_cur_b;

        // Total bytes for this output line: line_a + delim + line_b + terminator
        let out_len = line_a_len + 1 + line_b_len + 1;

        // Flush if needed
        if pos + out_len > buf_cap {
            unsafe { buf.set_len(pos) };
            raw_write_all(&buf)?;
            buf.clear();
            pos = 0;
        }

        // Write directly with unsafe pointer copies
        unsafe {
            if line_a_len > 0 {
                std::ptr::copy_nonoverlapping(line_a_ptr, base.add(pos), line_a_len);
                pos += line_a_len;
            }
            *base.add(pos) = delim;
            pos += 1;
            if line_b_len > 0 {
                std::ptr::copy_nonoverlapping(line_b_ptr, base.add(pos), line_b_len);
                pos += line_b_len;
            }
            *base.add(pos) = terminator;
            pos += 1;
        }
    }

    // Final flush
    if pos > 0 {
        unsafe { buf.set_len(pos) };
        raw_write_all(&buf)?;
    }

    Ok(())
}

/// Streaming paste for the parallel (normal) mode.
/// Uses memchr per-line scanning and a 1MB output buffer with raw fd writes.
/// For the common 2-file case, dispatches to an optimized fast path.
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
        // If data ends with terminator, output is identical to input
        if *data.last().unwrap() == terminator {
            return raw_write_all(data);
        }
        // Otherwise: write data + terminator
        raw_write_all(data)?;
        return raw_write_all(&[terminator]);
    }

    // Fast path: 2 files with single-byte delimiter (the common case: `paste file1 file2`)
    if nfiles == 2 && delims.len() == 1 {
        return paste_two_files_fast(file_data[0], file_data[1], delims[0], terminator);
    }

    let mut writer = RawBufWriter::new();

    // Cursors: current position in each file.
    // Initialize to usize::MAX for empty files (already exhausted).
    let mut cursors: Vec<usize> = file_data
        .iter()
        .map(|d| if d.is_empty() { usize::MAX } else { 0 })
        .collect();
    let mut active_count = file_data.iter().filter(|d| !d.is_empty()).count();

    loop {
        if active_count == 0 {
            break;
        }

        let mut newly_exhausted = 0;

        for file_idx in 0..nfiles {
            if file_idx > 0 && has_delims {
                writer.push(delims[(file_idx - 1) % delims.len()]);
            }

            let cursor = cursors[file_idx];
            if cursor == usize::MAX {
                continue;
            }

            let data = file_data[file_idx];

            match memchr::memchr(terminator, &data[cursor..]) {
                Some(offset) => {
                    writer.extend(&data[cursor..cursor + offset]);
                    let new_cursor = cursor + offset + 1;
                    if new_cursor >= data.len() {
                        cursors[file_idx] = usize::MAX;
                        newly_exhausted += 1;
                    } else {
                        cursors[file_idx] = new_cursor;
                    }
                }
                None => {
                    writer.extend(&data[cursor..]);
                    cursors[file_idx] = usize::MAX;
                    newly_exhausted += 1;
                }
            }
        }

        writer.push(terminator);
        active_count -= newly_exhausted;
    }

    writer.finish()
}

/// Streaming paste for serial mode.
pub fn paste_serial_stream(file_data: &[&[u8]], config: &PasteConfig) -> std::io::Result<()> {
    let terminator = if config.zero_terminated { 0u8 } else { b'\n' };
    let delims = &config.delimiters;
    let has_delims = !delims.is_empty();

    let mut writer = RawBufWriter::new();

    for data in file_data {
        if data.is_empty() {
            writer.push(terminator);
            continue;
        }

        let mut cursor = 0;
        let mut first = true;
        let mut delim_idx = 0;

        while cursor < data.len() {
            if !first && has_delims {
                writer.push(delims[delim_idx % delims.len()]);
                delim_idx += 1;
            }
            first = false;

            match memchr::memchr(terminator, &data[cursor..]) {
                Some(offset) => {
                    writer.extend(&data[cursor..cursor + offset]);
                    cursor += offset + 1;
                }
                None => {
                    writer.extend(&data[cursor..]);
                    cursor = data.len();
                }
            }
        }

        writer.push(terminator);
    }

    writer.finish()
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
