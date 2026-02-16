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

/// Build line start/end offsets for a given data buffer.
/// Returns a Vec of (start, end) pairs where end is exclusive and does NOT include the terminator.
#[inline]
fn build_line_offsets(data: &[u8], terminator: u8) -> Vec<(usize, usize)> {
    let mut offsets = Vec::new();
    let mut start = 0;
    for pos in memchr::memchr_iter(terminator, data) {
        offsets.push((start, pos));
        start = pos + 1;
    }
    // Last line without trailing terminator
    if start < data.len() {
        offsets.push((start, data.len()));
    }
    offsets
}

/// Paste files in normal (parallel) mode.
/// For each line index, concatenate corresponding lines from all files with delimiters.
pub fn paste_parallel(
    file_data: &[&[u8]],
    config: &PasteConfig,
    out: &mut impl Write,
) -> std::io::Result<()> {
    let terminator = if config.zero_terminated { 0u8 } else { b'\n' };

    // Build line offset arrays for each file
    let all_offsets: Vec<Vec<(usize, usize)>> = file_data
        .iter()
        .map(|d| build_line_offsets(d, terminator))
        .collect();

    let max_lines = all_offsets.iter().map(|o| o.len()).max().unwrap_or(0);
    if max_lines == 0 && file_data.iter().all(|d| d.is_empty()) {
        return Ok(());
    }

    // Estimate output size
    let total_input: usize = file_data.iter().map(|d| d.len()).sum();
    let delim_overhead = max_lines * file_data.len();
    let mut output = Vec::with_capacity(total_input + delim_overhead);

    let delims = &config.delimiters;

    for line_idx in 0..max_lines {
        for (file_idx, (offsets, data)) in all_offsets.iter().zip(file_data.iter()).enumerate() {
            if file_idx > 0 {
                // Insert delimiter between fields
                if !delims.is_empty() {
                    let d = delims[(file_idx - 1) % delims.len()];
                    output.push(d);
                }
            }
            if line_idx < offsets.len() {
                let (start, end) = offsets[line_idx];
                output.extend_from_slice(&data[start..end]);
            }
            // If line_idx >= offsets.len(), we output empty field (nothing appended)
        }
        output.push(terminator);
    }

    out.write_all(&output)
}

/// Paste files in serial mode.
/// For each file, join all lines with the delimiter list (cycling).
pub fn paste_serial(
    file_data: &[&[u8]],
    config: &PasteConfig,
    out: &mut impl Write,
) -> std::io::Result<()> {
    let terminator = if config.zero_terminated { 0u8 } else { b'\n' };
    let delims = &config.delimiters;

    // Estimate output size
    let total_input: usize = file_data.iter().map(|d| d.len()).sum();
    let mut output = Vec::with_capacity(total_input + file_data.len());

    for data in file_data {
        let offsets = build_line_offsets(data, terminator);
        for (i, &(start, end)) in offsets.iter().enumerate() {
            if i > 0 {
                if !delims.is_empty() {
                    let d = delims[(i - 1) % delims.len()];
                    output.push(d);
                }
            }
            output.extend_from_slice(&data[start..end]);
        }
        output.push(terminator);
    }

    out.write_all(&output)
}

/// Main paste entry point.
pub fn paste(
    file_data: &[&[u8]],
    config: &PasteConfig,
    out: &mut impl Write,
) -> std::io::Result<()> {
    if config.serial {
        paste_serial(file_data, config, out)
    } else {
        paste_parallel(file_data, config, out)
    }
}
