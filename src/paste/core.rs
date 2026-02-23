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

/// Paste files in normal (parallel) mode and return the output buffer.
/// Uses cursor-based scanning — no offset arrays, minimal allocation.
pub fn paste_parallel_to_vec(file_data: &[&[u8]], config: &PasteConfig) -> Vec<u8> {
    let terminator = if config.zero_terminated { 0u8 } else { b'\n' };
    let delims = &config.delimiters;

    if file_data.is_empty() || file_data.iter().all(|d| d.is_empty()) {
        return Vec::new();
    }

    // Count max lines using SIMD memchr (fast count pass, no allocation)
    let max_lines = file_data
        .iter()
        .map(|data| {
            if data.is_empty() {
                return 0;
            }
            let count = memchr::memchr_iter(terminator, data).count();
            if data.last() != Some(&terminator) {
                count + 1
            } else {
                count
            }
        })
        .max()
        .unwrap_or(0);

    if max_lines == 0 {
        return Vec::new();
    }

    // Estimate output size
    let total_input: usize = file_data.iter().map(|d| d.len()).sum();
    let delim_overhead = max_lines * file_data.len();
    let mut output = Vec::with_capacity(total_input + delim_overhead);

    // Cursors track current position in each file (no offset arrays needed)
    let mut cursors = vec![0usize; file_data.len()];

    for _ in 0..max_lines {
        for (file_idx, data) in file_data.iter().enumerate() {
            if file_idx > 0 && !delims.is_empty() {
                output.push(delims[(file_idx - 1) % delims.len()]);
            }
            let cursor = &mut cursors[file_idx];
            if *cursor < data.len() {
                match memchr::memchr(terminator, &data[*cursor..]) {
                    Some(pos) => {
                        output.extend_from_slice(&data[*cursor..*cursor + pos]);
                        *cursor += pos + 1;
                    }
                    None => {
                        output.extend_from_slice(&data[*cursor..]);
                        *cursor = data.len();
                    }
                }
            }
        }
        output.push(terminator);
    }

    output
}

/// Paste files in serial mode and return the output buffer.
/// For each file, join all lines with the delimiter list (cycling).
/// Uses inline memchr scanning — no offset arrays needed.
pub fn paste_serial_to_vec(file_data: &[&[u8]], config: &PasteConfig) -> Vec<u8> {
    let terminator = if config.zero_terminated { 0u8 } else { b'\n' };
    let delims = &config.delimiters;

    // Estimate output size
    let total_input: usize = file_data.iter().map(|d| d.len()).sum();
    let mut output = Vec::with_capacity(total_input + file_data.len());

    for data in file_data {
        if data.is_empty() {
            output.push(terminator);
            continue;
        }
        // Strip trailing terminator if present (we add our own at the end)
        let effective = if data.last() == Some(&terminator) {
            &data[..data.len() - 1]
        } else {
            *data
        };
        // Scan through data, replacing terminators with cycling delimiters
        let mut cursor = 0;
        let mut delim_idx = 0;
        while cursor < effective.len() {
            match memchr::memchr(terminator, &effective[cursor..]) {
                Some(pos) => {
                    output.extend_from_slice(&effective[cursor..cursor + pos]);
                    if !delims.is_empty() {
                        output.push(delims[delim_idx % delims.len()]);
                        delim_idx += 1;
                    }
                    cursor += pos + 1;
                }
                None => {
                    output.extend_from_slice(&effective[cursor..]);
                    break;
                }
            }
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
