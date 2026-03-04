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
/// Pre-splits both files into line offsets with a single SIMD memchr_iter pass each,
/// then iterates with O(1) indexing, writing into a 1MB buffer with raw fd writes.
fn paste_two_files_fast(
    data_a: &[u8],
    data_b: &[u8],
    delim: u8,
    terminator: u8,
) -> std::io::Result<()> {
    if data_a.is_empty() && data_b.is_empty() {
        return Ok(());
    }

    // Pre-split both files — single SIMD pass each.
    let lines_a = presplit_lines(data_a, terminator);
    let lines_b = presplit_lines(data_b, terminator);
    let max_lines = lines_a.len().max(lines_b.len());
    if max_lines == 0 {
        return Ok(());
    }

    let buf_cap = BUF_SIZE;
    let mut buf: Vec<u8> = Vec::with_capacity(buf_cap);
    // Pre-fault pages
    unsafe {
        std::ptr::write_bytes(buf.as_mut_ptr(), 0, buf_cap);
    }
    let base = buf.as_mut_ptr();
    let mut pos: usize = 0;

    let ptr_a = data_a.as_ptr();
    let ptr_b = data_b.as_ptr();
    let na = lines_a.len();
    let nb = lines_b.len();

    for i in 0..max_lines {
        // Get line lengths from pre-split offsets
        let (a_off, a_len) = if i < na {
            let (s, e) = unsafe { *lines_a.get_unchecked(i) };
            (s as usize, (e - s) as usize)
        } else {
            (0, 0)
        };

        let (b_off, b_len) = if i < nb {
            let (s, e) = unsafe { *lines_b.get_unchecked(i) };
            (s as usize, (e - s) as usize)
        } else {
            (0, 0)
        };

        let out_len = a_len + 1 + b_len + 1;

        // Flush if needed
        if pos + out_len > buf_cap {
            unsafe { buf.set_len(pos) };
            raw_write_all(&buf)?;
            buf.clear();
            pos = 0;
        }

        // Write directly with unsafe pointer copies
        unsafe {
            if a_len > 0 {
                std::ptr::copy_nonoverlapping(ptr_a.add(a_off), base.add(pos), a_len);
                pos += a_len;
            }
            *base.add(pos) = delim;
            pos += 1;
            if b_len > 0 {
                std::ptr::copy_nonoverlapping(ptr_b.add(b_off), base.add(pos), b_len);
                pos += b_len;
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
/// Pre-splits all files into line offsets with SIMD memchr_iter, then uses
/// O(1) indexing with a 1MB output buffer and raw fd writes.
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

    // N-file fast path: unsafe pointer arithmetic with 1MB buffer
    paste_n_files_fast(file_data, delims, has_delims, terminator)
}

/// Fast path for N files: unsafe pointer arithmetic with 1MB buffer.
/// Pre-splits all files into line offsets, then uses O(1) indexing with
/// direct pointer writes to eliminate RawBufWriter overhead.
fn paste_n_files_fast(
    file_data: &[&[u8]],
    delims: &[u8],
    has_delims: bool,
    terminator: u8,
) -> std::io::Result<()> {
    let nfiles = file_data.len();

    // Pre-split all files into line offsets — single SIMD pass per file.
    let file_lines: Vec<Vec<(u32, u32)>> = file_data
        .iter()
        .map(|data| presplit_lines(data, terminator))
        .collect();
    let max_lines = file_lines.iter().map(|l| l.len()).max().unwrap_or(0);
    if max_lines == 0 {
        return Ok(());
    }

    let mut buf_cap = BUF_SIZE;
    let mut buf: Vec<u8> = Vec::with_capacity(buf_cap);
    // Pre-fault pages
    unsafe {
        std::ptr::write_bytes(buf.as_mut_ptr(), 0, buf_cap);
    }
    let mut base = buf.as_mut_ptr();
    let mut pos: usize = 0;

    // Cache file data pointers
    let ptrs: Vec<*const u8> = file_data.iter().map(|d| d.as_ptr()).collect();

    for line_idx in 0..max_lines {
        // Estimate output size for this line
        let mut est_len = nfiles; // delimiters + terminator
        for file_idx in 0..nfiles {
            if line_idx < file_lines[file_idx].len() {
                let (s, e) = unsafe { *file_lines[file_idx].get_unchecked(line_idx) };
                est_len += (e - s) as usize;
            }
        }

        // Flush if needed
        if pos + est_len > buf_cap {
            unsafe {
                buf.set_len(pos);
            }
            raw_write_all(&buf)?;
            buf.clear();
            pos = 0;
            // Grow buffer for oversized lines (> 1 MiB)
            if est_len > buf_cap {
                buf.reserve(est_len);
                buf_cap = buf.capacity();
                base = buf.as_mut_ptr();
            }
        }

        // Write all columns with unsafe pointer copies
        unsafe {
            for file_idx in 0..nfiles {
                if file_idx > 0 && has_delims {
                    *base.add(pos) = *delims.get_unchecked((file_idx - 1) % delims.len());
                    pos += 1;
                }
                let lines = &file_lines[file_idx];
                if line_idx < lines.len() {
                    let (s, e) = *lines.get_unchecked(line_idx);
                    let len = (e - s) as usize;
                    if len > 0 {
                        std::ptr::copy_nonoverlapping(
                            ptrs[file_idx].add(s as usize),
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
    }

    // Final flush
    if pos > 0 {
        unsafe {
            buf.set_len(pos);
        }
        raw_write_all(&buf)?;
    }

    Ok(())
}

/// Streaming paste for serial mode.
/// Pre-splits each file into line offsets with SIMD memchr_iter, then iterates
/// with O(1) indexing.
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

        let lines = presplit_lines(data, terminator);
        if lines.is_empty() {
            writer.push(terminator);
            continue;
        }

        // First line: no leading delimiter
        let (s, e) = lines[0];
        writer.extend(&data[s as usize..e as usize]);
        // Subsequent lines: prepend cycling delimiter
        for (i, &(s, e)) in lines[1..].iter().enumerate() {
            if has_delims {
                writer.push(delims[i % delims.len()]);
            }
            writer.extend(&data[s as usize..e as usize]);
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
