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

/// Pre-split a file into line offset pairs using a single SIMD memchr_iter pass.
/// Returns a Vec of (start, end) byte offsets — one per line.
#[inline]
fn presplit_lines(data: &[u8], terminator: u8) -> Vec<(u32, u32)> {
    if data.is_empty() {
        return Vec::new();
    }
    debug_assert!(
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

        debug_assert!(pos <= exact_size);
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
