use std::io::Write;

/// Line numbering style.
#[derive(Clone)]
pub enum NumberingStyle {
    /// Number all lines.
    All,
    /// Number only non-empty lines (default for body).
    NonEmpty,
    /// Don't number lines.
    None,
    /// Number lines matching a basic regular expression.
    Regex(regex::Regex),
}

/// Number format for line numbers.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum NumberFormat {
    /// Left-justified, no leading zeros.
    Ln,
    /// Right-justified, no leading zeros (default).
    Rn,
    /// Right-justified, leading zeros.
    Rz,
}

/// Configuration for the nl command.
pub struct NlConfig {
    pub body_style: NumberingStyle,
    pub header_style: NumberingStyle,
    pub footer_style: NumberingStyle,
    pub section_delimiter: Vec<u8>,
    pub line_increment: i64,
    pub join_blank_lines: usize,
    pub number_format: NumberFormat,
    pub no_renumber: bool,
    pub number_separator: Vec<u8>,
    pub starting_line_number: i64,
    pub number_width: usize,
}

impl Default for NlConfig {
    fn default() -> Self {
        Self {
            body_style: NumberingStyle::NonEmpty,
            header_style: NumberingStyle::None,
            footer_style: NumberingStyle::None,
            section_delimiter: vec![b'\\', b':'],
            line_increment: 1,
            join_blank_lines: 1,
            number_format: NumberFormat::Rn,
            no_renumber: false,
            number_separator: vec![b'\t'],
            starting_line_number: 1,
            number_width: 6,
        }
    }
}

/// Parse a numbering style string.
pub fn parse_numbering_style(s: &str) -> Result<NumberingStyle, String> {
    match s {
        "a" => Ok(NumberingStyle::All),
        "t" => Ok(NumberingStyle::NonEmpty),
        "n" => Ok(NumberingStyle::None),
        _ if s.starts_with('p') => {
            let pattern = &s[1..];
            match regex::Regex::new(pattern) {
                Ok(re) => Ok(NumberingStyle::Regex(re)),
                Err(e) => Err(format!("invalid regular expression: {}", e)),
            }
        }
        _ => Err(format!("invalid numbering style: '{}'", s)),
    }
}

/// Parse a number format string.
pub fn parse_number_format(s: &str) -> Result<NumberFormat, String> {
    match s {
        "ln" => Ok(NumberFormat::Ln),
        "rn" => Ok(NumberFormat::Rn),
        "rz" => Ok(NumberFormat::Rz),
        _ => Err(format!("invalid line numbering: '{}'", s)),
    }
}

/// Logical page section types.
#[derive(Clone, Copy, PartialEq)]
enum Section {
    Header,
    Body,
    Footer,
}

/// Check if a line is a section delimiter.
#[inline]
fn check_section_delimiter(line: &[u8], delim: &[u8]) -> Option<Section> {
    if delim.is_empty() {
        return None;
    }
    let dlen = delim.len();

    // Check header (3x)
    if line.len() == dlen * 3 {
        let mut is_header = true;
        for i in 0..3 {
            if &line[i * dlen..(i + 1) * dlen] != delim {
                is_header = false;
                break;
            }
        }
        if is_header {
            return Some(Section::Header);
        }
    }

    // Check body (2x)
    if line.len() == dlen * 2 && &line[..dlen] == delim && &line[dlen..] == delim {
        return Some(Section::Body);
    }

    // Check footer (1x)
    if line.len() == dlen && line == delim {
        return Some(Section::Footer);
    }

    None
}

/// Format a line number according to the format and width.
#[inline]
fn format_number(num: i64, format: NumberFormat, width: usize, buf: &mut Vec<u8>) {
    let mut num_buf = itoa::Buffer::new();
    let num_str = num_buf.format(num);

    match format {
        NumberFormat::Ln => {
            buf.extend_from_slice(num_str.as_bytes());
            let pad = width.saturating_sub(num_str.len());
            buf.resize(buf.len() + pad, b' ');
        }
        NumberFormat::Rn => {
            let pad = width.saturating_sub(num_str.len());
            buf.resize(buf.len() + pad, b' ');
            buf.extend_from_slice(num_str.as_bytes());
        }
        NumberFormat::Rz => {
            if num < 0 {
                buf.push(b'-');
                let abs_str = &num_str[1..];
                let pad = width.saturating_sub(abs_str.len() + 1);
                buf.resize(buf.len() + pad, b'0');
                buf.extend_from_slice(abs_str.as_bytes());
            } else {
                let pad = width.saturating_sub(num_str.len());
                buf.resize(buf.len() + pad, b'0');
                buf.extend_from_slice(num_str.as_bytes());
            }
        }
    }
}

/// Check if a line should be numbered based on the style.
#[inline]
fn should_number(line: &[u8], style: &NumberingStyle) -> bool {
    match style {
        NumberingStyle::All => true,
        NumberingStyle::NonEmpty => !line.is_empty(),
        NumberingStyle::None => false,
        NumberingStyle::Regex(re) => match std::str::from_utf8(line) {
            Ok(s) => re.is_match(s),
            Err(_) => false,
        },
    }
}

/// Build the nl output into a Vec.
pub fn nl_to_vec(data: &[u8], config: &NlConfig) -> Vec<u8> {
    let mut line_number = config.starting_line_number;
    nl_to_vec_with_state(data, config, &mut line_number)
}

/// Check if config is the simple "number all lines" case suitable for fast path.
#[inline]
fn is_simple_number_all(config: &NlConfig) -> bool {
    matches!(config.body_style, NumberingStyle::All)
        && matches!(config.header_style, NumberingStyle::None)
        && matches!(config.footer_style, NumberingStyle::None)
        && config.join_blank_lines == 1
        && config.line_increment == 1
        && !config.no_renumber
}

/// Ultra-fast path for nl -b a: eliminates section delimiter checks and uses raw
/// buffer writes. Handles all three number formats (Rn, Rz, Ln) in a single
/// function to avoid code duplication.
fn nl_number_all_fast(data: &[u8], config: &NlConfig, line_number: &mut i64) -> Vec<u8> {
    let alloc = (data.len() * 2 + 256).min(128 * 1024 * 1024);
    let mut output: Vec<u8> = Vec::with_capacity(alloc);

    let width = config.number_width;
    let sep = &config.number_separator;
    let fmt = config.number_format;
    let mut num = *line_number;
    let mut pos: usize = 0;

    // Inner write helper: formats number prefix + line content + newline.
    // SAFETY: caller ensures output has capacity for total_len bytes at start_pos.
    #[inline(always)]
    unsafe fn write_numbered_line(
        output: &mut Vec<u8>,
        fmt: NumberFormat,
        num_str: &str,
        pad: usize,
        sep: &[u8],
        line_data: *const u8,
        line_len: usize,
    ) {
        unsafe {
            let prefix_len = pad + num_str.len() + sep.len();
            let total_len = prefix_len + line_len + 1;
            let start_pos = output.len();
            let dst = output.as_mut_ptr().add(start_pos);

            match fmt {
                NumberFormat::Rn => {
                    std::ptr::write_bytes(dst, b' ', pad);
                    std::ptr::copy_nonoverlapping(
                        num_str.as_ptr(),
                        dst.add(pad),
                        num_str.len(),
                    );
                }
                NumberFormat::Rz => {
                    std::ptr::write_bytes(dst, b'0', pad);
                    std::ptr::copy_nonoverlapping(
                        num_str.as_ptr(),
                        dst.add(pad),
                        num_str.len(),
                    );
                }
                NumberFormat::Ln => {
                    std::ptr::copy_nonoverlapping(num_str.as_ptr(), dst, num_str.len());
                    std::ptr::write_bytes(dst.add(num_str.len()), b' ', pad);
                }
            }
            std::ptr::copy_nonoverlapping(
                sep.as_ptr(),
                dst.add(pad + num_str.len()),
                sep.len(),
            );
            std::ptr::copy_nonoverlapping(line_data, dst.add(prefix_len), line_len);
            *dst.add(prefix_len + line_len) = b'\n';
            output.set_len(start_pos + total_len);
        }
    }

    for nl_pos in memchr::memchr_iter(b'\n', data) {
        let line_len = nl_pos - pos;
        let needed = output.len() + line_len + width + sep.len() + 22;
        if needed > output.capacity() {
            output.reserve(needed - output.capacity() + 4 * 1024 * 1024);
        }

        let mut num_buf = itoa::Buffer::new();
        let num_str = num_buf.format(num);
        let pad = width.saturating_sub(num_str.len());

        unsafe {
            write_numbered_line(
                &mut output,
                fmt,
                num_str,
                pad,
                sep,
                data.as_ptr().add(pos),
                line_len,
            );
        }

        num += 1;
        pos = nl_pos + 1;
    }

    // Handle final line without trailing newline
    if pos < data.len() {
        let remaining = data.len() - pos;
        let needed = output.len() + remaining + width + sep.len() + 22;
        if needed > output.capacity() {
            output.reserve(needed - output.capacity() + 1024);
        }
        let mut num_buf = itoa::Buffer::new();
        let num_str = num_buf.format(num);
        let pad = width.saturating_sub(num_str.len());

        unsafe {
            write_numbered_line(
                &mut output,
                fmt,
                num_str,
                pad,
                sep,
                data.as_ptr().add(pos),
                remaining,
            );
        }
        num += 1;
    }

    *line_number = num;
    output
}

/// Build the nl output into a Vec, continuing numbering from `line_number`.
/// Updates `line_number` in place so callers can continue across multiple files.
pub fn nl_to_vec_with_state(data: &[u8], config: &NlConfig, line_number: &mut i64) -> Vec<u8> {
    if data.is_empty() {
        return Vec::new();
    }

    // Fast paths for common benchmark cases.
    // Guard: skip fast path if data contains section delimiters (rare in practice).
    let has_section_delims = !config.section_delimiter.is_empty()
        && memchr::memmem::find(data, &config.section_delimiter).is_some();
    if is_simple_number_all(config) && !has_section_delims {
        return nl_number_all_fast(data, config, line_number);
    }

    // Generic path: pre-allocate generously instead of counting newlines
    let alloc = (data.len() * 2 + 256).min(128 * 1024 * 1024);
    let mut output: Vec<u8> = Vec::with_capacity(alloc);

    let mut current_section = Section::Body;
    let mut consecutive_blanks: usize = 0;

    let mut start = 0;
    let mut line_iter = memchr::memchr_iter(b'\n', data);

    loop {
        let (line, has_newline) = match line_iter.next() {
            Some(pos) => (&data[start..pos], true),
            None => {
                if start < data.len() {
                    (&data[start..], false)
                } else {
                    break;
                }
            }
        };

        // Check for section delimiter
        if let Some(section) = check_section_delimiter(line, &config.section_delimiter) {
            if !config.no_renumber {
                *line_number = config.starting_line_number;
            }
            current_section = section;
            consecutive_blanks = 0;
            output.push(b'\n');
            if has_newline {
                start += line.len() + 1;
            } else {
                break;
            }
            continue;
        }

        let style = match current_section {
            Section::Header => &config.header_style,
            Section::Body => &config.body_style,
            Section::Footer => &config.footer_style,
        };

        let is_blank = line.is_empty();

        if is_blank {
            consecutive_blanks += 1;
        } else {
            consecutive_blanks = 0;
        }

        let do_number = if is_blank && config.join_blank_lines > 1 {
            if should_number(line, style) {
                consecutive_blanks >= config.join_blank_lines
            } else {
                false
            }
        } else {
            should_number(line, style)
        };

        if do_number {
            if is_blank && config.join_blank_lines > 1 {
                consecutive_blanks = 0;
            }
            format_number(
                *line_number,
                config.number_format,
                config.number_width,
                &mut output,
            );
            output.extend_from_slice(&config.number_separator);
            output.extend_from_slice(line);
            *line_number = line_number.wrapping_add(config.line_increment);
        } else {
            // Non-numbered lines: GNU nl outputs width + separator_len total spaces, then content
            let total_pad = config.number_width + config.number_separator.len();
            output.resize(output.len() + total_pad, b' ');
            output.extend_from_slice(line);
        }

        if has_newline {
            output.push(b'\n');
            start += line.len() + 1;
        } else {
            // GNU nl always adds a trailing newline, even when the input lacks one
            // (but has content on the last line). Empty input produces empty output.
            output.push(b'\n');
            break;
        }
    }

    output
}

/// Number lines and write to the provided writer.
pub fn nl(data: &[u8], config: &NlConfig, out: &mut impl Write) -> std::io::Result<()> {
    let output = nl_to_vec(data, config);
    out.write_all(&output)
}
