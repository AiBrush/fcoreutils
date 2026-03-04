use std::io::{self, BufRead, Write};
use std::time::{SystemTime, UNIX_EPOCH};

/// Default page length in lines.
pub const DEFAULT_PAGE_LENGTH: usize = 66;
/// Default page width in columns.
pub const DEFAULT_PAGE_WIDTH: usize = 72;
/// Number of header lines (2 blank + 1 header + 2 blank).
pub const HEADER_LINES: usize = 5;
/// Number of footer lines (5 blank).
pub const FOOTER_LINES: usize = 5;

/// Configuration for the pr command.
#[derive(Clone)]
pub struct PrConfig {
    /// First page to print (1-indexed).
    pub first_page: usize,
    /// Last page to print (0 = no limit).
    pub last_page: usize,
    /// Number of columns.
    pub columns: usize,
    /// Print columns across rather than down.
    pub across: bool,
    /// Show control characters in hat notation (^X).
    pub show_control_chars: bool,
    /// Double-space output.
    pub double_space: bool,
    /// Date format string for header.
    pub date_format: String,
    /// Expand input tabs to spaces (char, width).
    pub expand_tabs: Option<(char, usize)>,
    /// Use form feeds instead of newlines for page breaks.
    pub form_feed: bool,
    /// Custom header string (replaces filename).
    pub header: Option<String>,
    /// Replace spaces with tabs in output (char, width).
    pub output_tabs: Option<(char, usize)>,
    /// Join lines (do not truncate lines when using columns).
    pub join_lines: bool,
    /// Page length in lines (including header/footer).
    pub page_length: usize,
    /// Merge multiple files side by side.
    pub merge: bool,
    /// Number lines: (separator_char, digits).
    pub number_lines: Option<(char, usize)>,
    /// First line number.
    pub first_line_number: usize,
    /// Indent (offset) each line by this many spaces.
    pub indent: usize,
    /// Suppress file-not-found warnings.
    pub no_file_warnings: bool,
    /// Column separator character.
    pub separator: Option<char>,
    /// Column separator string.
    pub sep_string: Option<String>,
    /// Omit header and trailer.
    pub omit_header: bool,
    /// Omit header, trailer, and form feeds.
    pub omit_pagination: bool,
    /// Show nonprinting characters.
    pub show_nonprinting: bool,
    /// Page width.
    pub page_width: usize,
    /// Truncate lines to page width (-W).
    pub truncate_lines: bool,
}

impl Default for PrConfig {
    fn default() -> Self {
        Self {
            first_page: 1,
            last_page: 0,
            columns: 1,
            across: false,
            show_control_chars: false,
            double_space: false,
            date_format: "%Y-%m-%d %H:%M".to_string(),
            expand_tabs: None,
            form_feed: false,
            header: None,
            output_tabs: None,
            join_lines: false,
            page_length: DEFAULT_PAGE_LENGTH,
            merge: false,
            number_lines: None,
            first_line_number: 1,
            indent: 0,
            no_file_warnings: false,
            separator: None,
            sep_string: None,
            omit_header: false,
            omit_pagination: false,
            show_nonprinting: false,
            page_width: DEFAULT_PAGE_WIDTH,
            truncate_lines: false,
        }
    }
}

/// Format a SystemTime as a date string using libc strftime.
fn format_header_date(time: &SystemTime, format: &str) -> String {
    let secs = time
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs() as i64;
    let mut tm: libc::tm = unsafe { std::mem::zeroed() };
    unsafe {
        libc::localtime_r(&secs, &mut tm);
    }

    // Use strftime via libc
    let c_format = std::ffi::CString::new(format).unwrap_or_default();
    let mut buf = vec![0u8; 256];
    let len = unsafe {
        libc::strftime(
            buf.as_mut_ptr() as *mut libc::c_char,
            buf.len(),
            c_format.as_ptr(),
            &tm,
        )
    };
    if len == 0 {
        return String::new();
    }
    buf.truncate(len);
    String::from_utf8_lossy(&buf).into_owned()
}

/// Expand tabs in a line to spaces.
fn expand_tabs_in_line(line: &str, tab_char: char, tab_width: usize) -> String {
    if tab_width == 0 {
        return line.replace(tab_char, "");
    }
    // Pre-allocate with extra capacity for tab expansion
    let mut result = String::with_capacity(line.len() + line.len() / 4);
    let tab_byte = tab_char as u8;
    let bytes = line.as_bytes();
    let mut col = 0;
    let mut seg_start = 0;

    for (i, &b) in bytes.iter().enumerate() {
        if b == tab_byte {
            // Copy segment before tab
            if i > seg_start {
                result.push_str(&line[seg_start..i]);
                col += i - seg_start;
            }
            let spaces = tab_width - (col % tab_width);
            // Batch push spaces
            let space_buf = "                                ";
            let mut remaining = spaces;
            while remaining > 0 {
                let chunk = remaining.min(space_buf.len());
                result.push_str(&space_buf[..chunk]);
                remaining -= chunk;
            }
            col += spaces;
            seg_start = i + 1;
        }
    }
    // Copy remaining segment after last tab
    if seg_start < bytes.len() {
        result.push_str(&line[seg_start..]);
    }
    result
}

/// Push hat notation (^X) for a control character into a String, avoiding allocation.
#[inline]
fn push_hat_notation(result: &mut String, ch: char) {
    let b = ch as u32;
    if b < 32 {
        result.push('^');
        result.push((b as u8 + b'@') as char);
    } else if b == 127 {
        result.push_str("^?");
    } else {
        result.push(ch);
    }
}

/// Push nonprinting notation (like cat -v) for a character into a String.
#[inline]
fn push_nonprinting(result: &mut String, ch: char) {
    let b = ch as u32;
    if b < 32 && b != 9 && b != 10 {
        result.push('^');
        result.push((b as u8 + b'@') as char);
    } else if b == 127 {
        result.push_str("^?");
    } else if b >= 128 && b < 160 {
        result.push_str("M-^");
        result.push((b as u8 - 128 + b'@') as char);
    } else if b >= 160 && b < 255 {
        result.push_str("M-");
        result.push((b as u8 - 128) as char);
    } else if b == 255 {
        result.push_str("M-^?");
    } else {
        result.push(ch);
    }
}

/// Process a line for control char display.
fn process_control_chars(line: &str, show_control: bool, show_nonprinting: bool) -> String {
    if !show_control && !show_nonprinting {
        return line.to_string();
    }
    let mut result = String::with_capacity(line.len() + line.len() / 4);
    for ch in line.chars() {
        if show_nonprinting {
            push_nonprinting(&mut result, ch);
        } else if show_control {
            push_hat_notation(&mut result, ch);
        } else {
            result.push(ch);
        }
    }
    result
}

/// Get the column separator to use.
fn get_column_separator(config: &PrConfig) -> String {
    if let Some(ref s) = config.sep_string {
        s.clone()
    } else if let Some(c) = config.separator {
        c.to_string()
    } else {
        " ".to_string()
    }
}

/// Check if the user has explicitly set a column separator.
fn has_explicit_separator(config: &PrConfig) -> bool {
    config.sep_string.is_some() || config.separator.is_some()
}

/// Write tab-based padding from an absolute position on the line to a target absolute position.
/// GNU pr pads columns using tab characters (8-space tab stops) to reach the column boundary.
/// `abs_pos` is the current absolute position on the line.
/// `target_abs_pos` is the target absolute position.
/// Static spaces buffer for padding without allocation.
const SPACES: [u8; 256] = [b' '; 256];

/// Write `n` spaces to output using the static SPACES buffer.
#[inline]
fn write_spaces<W: Write>(output: &mut W, n: usize) -> io::Result<()> {
    let mut remaining = n;
    while remaining > 0 {
        let chunk = remaining.min(SPACES.len());
        output.write_all(&SPACES[..chunk])?;
        remaining -= chunk;
    }
    Ok(())
}

fn write_column_padding<W: Write>(
    output: &mut W,
    abs_pos: usize,
    target_abs_pos: usize,
) -> io::Result<()> {
    // GNU pr uses plain spaces for column padding by default
    let n = target_abs_pos.saturating_sub(abs_pos);
    write_spaces(output, n)
}

/// Paginate raw byte data — fast path that avoids per-line String allocation.
/// When no tab expansion or control char processing is needed, lines are
/// extracted as byte slices directly from the input buffer (zero-copy).
pub fn pr_data<W: Write>(
    data: &[u8],
    output: &mut W,
    config: &PrConfig,
    filename: &str,
    file_date: Option<SystemTime>,
) -> io::Result<()> {
    let needs_transform =
        config.expand_tabs.is_some() || config.show_control_chars || config.show_nonprinting;

    if needs_transform {
        // Fall back to the String-based path for transforms
        let reader = io::Cursor::new(data);
        return pr_file(reader, output, config, filename, file_date);
    }

    // Ultra-fast path: single column, no per-line transforms → contiguous chunk writes
    // Instead of splitting into individual lines and writing each one, we index newline
    // positions and write entire page bodies as contiguous slices of the original data.
    let is_simple = config.columns <= 1
        && config.number_lines.is_none()
        && config.indent == 0
        && !config.truncate_lines
        && !config.double_space
        && !config.across
        && memchr::memchr(b'\r', data).is_none();

    if is_simple {
        // Passthrough: -t with no transforms → output == input
        if config.omit_header || config.omit_pagination {
            return output.write_all(data);
        }
        return pr_data_contiguous(data, output, config, filename, file_date);
    }

    // Fast path: single column with numbering only (no indent, no truncate, no double-space)
    if config.columns <= 1
        && config.number_lines.is_some()
        && config.indent == 0
        && !config.truncate_lines
        && !config.double_space
        && memchr::memchr(b'\r', data).is_none()
    {
        return pr_data_numbered(data, output, config, filename, file_date);
    }

    // Normal path: split into line byte slices using SIMD memchr
    let mut lines: Vec<&[u8]> = Vec::with_capacity(data.len() / 40 + 64);
    let mut start = 0;
    for pos in memchr::memchr_iter(b'\n', data) {
        let end = if pos > start && data[pos - 1] == b'\r' {
            pos - 1
        } else {
            pos
        };
        lines.push(&data[start..end]);
        start = pos + 1;
    }
    // Handle last line without trailing newline
    if start < data.len() {
        let end = if data.last() == Some(&b'\r') {
            data.len() - 1
        } else {
            data.len()
        };
        lines.push(&data[start..end]);
    }

    pr_lines_generic(&lines, output, config, filename, file_date)
}

/// Ultra-fast contiguous-write paginator for single-column, no-transform mode.
/// Streams through data using memchr_iter without building a Vec<usize> of newline positions.
/// Pre-computes the header prefix (date + filename) once, appending only the page number per page.
fn pr_data_contiguous<W: Write>(
    data: &[u8],
    output: &mut W,
    config: &PrConfig,
    filename: &str,
    file_date: Option<SystemTime>,
) -> io::Result<()> {
    let date = file_date.unwrap_or_else(SystemTime::now);
    let header_str = config.header.as_deref().unwrap_or(filename);
    let date_str = format_header_date(&date, &config.date_format);

    let suppress_header = !config.omit_header
        && !config.omit_pagination
        && config.page_length <= HEADER_LINES + FOOTER_LINES;
    let body_lines_per_page = if config.omit_header || config.omit_pagination {
        if config.page_length > 0 {
            config.page_length
        } else {
            DEFAULT_PAGE_LENGTH
        }
    } else if suppress_header {
        config.page_length
    } else {
        config.page_length - HEADER_LINES - FOOTER_LINES
    };
    let show_header = !config.omit_header && !config.omit_pagination && !suppress_header;

    if data.is_empty() {
        if show_header {
            let mut page_buf: Vec<u8> = Vec::with_capacity(256);
            write_header(&mut page_buf, &date_str, header_str, 1, config)?;
            write_footer(&mut page_buf, config)?;
            output.write_all(&page_buf)?;
        }
        return Ok(());
    }

    let footer: &[u8] = if show_header {
        if config.form_feed {
            b"\x0c"
        } else {
            b"\n\n\n\n\n"
        }
    } else {
        b""
    };

    // Stream through data: skip body_lines_per_page newlines at a time
    let mut page_buf: Vec<u8> = Vec::with_capacity(128 * 1024);
    let mut page_num = 1usize;
    let mut byte_pos = 0usize;
    loop {
        if byte_pos >= data.len() {
            break;
        }

        // Find the end of this page: skip body_lines_per_page newlines
        let page_start = byte_pos;
        let mut lines_found = 0usize;
        let remaining = &data[byte_pos..];
        let mut page_end = data.len();

        for nl_off in memchr::memchr_iter(b'\n', remaining) {
            lines_found += 1;
            if lines_found >= body_lines_per_page {
                page_end = byte_pos + nl_off + 1;
                break;
            }
        }

        let in_range = page_num >= config.first_page
            && (config.last_page == 0 || page_num <= config.last_page);

        if in_range {
            page_buf.clear();

            if show_header {
                write_header(&mut page_buf, &date_str, header_str, page_num, config)?;
            }

            // Write body: contiguous slice of original data
            page_buf.extend_from_slice(&data[page_start..page_end]);

            // Ensure last line ends with newline
            if page_buf.last() != Some(&b'\n') {
                page_buf.push(b'\n');
            }

            // Pad remaining body lines
            if show_header || (!config.omit_header && !config.omit_pagination) {
                let pad_lines = body_lines_per_page.saturating_sub(lines_found);
                page_buf.resize(page_buf.len() + pad_lines, b'\n');
            }

            page_buf.extend_from_slice(footer);

            output.write_all(&page_buf)?;
        }

        byte_pos = page_end;
        page_num += 1;

        // If we didn't find enough lines, we've consumed all data
        if lines_found < body_lines_per_page {
            break;
        }
    }

    Ok(())
}

/// Fast numbered single-column paginator.
/// Uses unsafe pointer arithmetic to format numbered lines directly into
/// a pre-allocated buffer, avoiding per-line write_all overhead.
fn pr_data_numbered<W: Write>(
    data: &[u8],
    output: &mut W,
    config: &PrConfig,
    filename: &str,
    file_date: Option<SystemTime>,
) -> io::Result<()> {
    let date = file_date.unwrap_or_else(SystemTime::now);
    let header_str = config.header.as_deref().unwrap_or(filename);
    let date_str = format_header_date(&date, &config.date_format);

    let (sep_char, digits) = config.number_lines.unwrap_or(('\t', 5));
    let sep_byte = sep_char as u8;
    // prefix_len = padding spaces + number digits + separator
    let prefix_len = digits + 1; // digits + separator

    let suppress_header = !config.omit_header
        && !config.omit_pagination
        && config.page_length <= HEADER_LINES + FOOTER_LINES;
    let body_lines_per_page = if config.omit_header || config.omit_pagination {
        if config.page_length > 0 {
            config.page_length
        } else {
            DEFAULT_PAGE_LENGTH
        }
    } else if suppress_header {
        config.page_length
    } else {
        config.page_length - HEADER_LINES - FOOTER_LINES
    };
    let show_header = !config.omit_header && !config.omit_pagination && !suppress_header;

    // Pre-allocate output buffer: ~128KB for a page
    const BUF_SIZE: usize = 128 * 1024;
    let mut page_buf: Vec<u8> = Vec::with_capacity(BUF_SIZE + 4096);

    let mut line_number = config.first_line_number;
    let mut page_num = 1usize;

    // Pre-split lines using SIMD memchr for fast iteration
    let mut line_starts: Vec<usize> = Vec::with_capacity(data.len() / 40 + 64);
    line_starts.push(0);
    for pos in memchr::memchr_iter(b'\n', data) {
        line_starts.push(pos + 1);
    }
    let total_lines = if !data.is_empty() && data[data.len() - 1] == b'\n' {
        line_starts.len() - 1
    } else {
        line_starts.len()
    };

    let mut line_idx = 0;

    while line_idx < total_lines {
        let page_end = (line_idx + body_lines_per_page).min(total_lines);
        let in_range = page_num >= config.first_page
            && (config.last_page == 0 || page_num <= config.last_page);

        if in_range {
            page_buf.clear();

            if show_header {
                write_header(&mut page_buf, &date_str, header_str, page_num, config)?;
            }

            // Write numbered lines using unsafe pointer arithmetic
            let src = data.as_ptr();
            for li in line_idx..page_end {
                let line_start = line_starts[li];
                let line_end = if li + 1 < line_starts.len() {
                    // strip trailing \n (and \r\n)
                    let end = line_starts[li + 1] - 1;
                    if end > line_start && data[end - 1] == b'\r' {
                        end - 1
                    } else {
                        end
                    }
                } else {
                    data.len()
                };
                let line_len = line_end - line_start;

                // Ensure capacity: prefix + content + newline
                let needed = prefix_len + line_len + 1;
                page_buf.reserve(needed);

                let wp = page_buf.len();
                let base = page_buf.as_mut_ptr();

                // Format line number with right-aligned padding
                let mut n = line_number;
                let mut num_pos = 19usize;
                let mut num_tmp = [0u8; 20];
                loop {
                    num_tmp[num_pos] = b'0' + (n % 10) as u8;
                    n /= 10;
                    if n == 0 || num_pos == 0 {
                        break;
                    }
                    num_pos -= 1;
                }
                let num_digits = 20 - num_pos;
                let padding = digits.saturating_sub(num_digits);

                unsafe {
                    let dst = base.add(wp);
                    // Write padding spaces
                    std::ptr::write_bytes(dst, b' ', padding);
                    // Write number digits
                    std::ptr::copy_nonoverlapping(
                        num_tmp.as_ptr().add(num_pos),
                        dst.add(padding),
                        num_digits,
                    );
                    // Write separator
                    *dst.add(padding + num_digits) = sep_byte;
                    // Write line content
                    if line_len > 0 {
                        std::ptr::copy_nonoverlapping(
                            src.add(line_start),
                            dst.add(prefix_len),
                            line_len,
                        );
                    }
                    // Write newline
                    *dst.add(prefix_len + line_len) = b'\n';
                    page_buf.set_len(wp + prefix_len + line_len + 1);
                }

                line_number += 1;
            }

            // Pad remaining body lines
            if show_header {
                let body_lines_written = page_end - line_idx;
                let pad = body_lines_per_page.saturating_sub(body_lines_written);
                page_buf.resize(page_buf.len() + pad, b'\n');
            }

            // Footer
            if show_header {
                write_footer(&mut page_buf, config)?;
            }

            output.write_all(&page_buf)?;
        } else {
            // Skip page but still advance line number
            line_number += page_end - line_idx;
        }

        line_idx = page_end;
        page_num += 1;
    }

    Ok(())
}

/// Paginate a single file and write output.
pub fn pr_file<R: BufRead, W: Write>(
    input: R,
    output: &mut W,
    config: &PrConfig,
    filename: &str,
    file_date: Option<SystemTime>,
) -> io::Result<()> {
    // Read all lines with transforms applied
    let mut all_lines: Vec<String> = Vec::new();
    for line_result in input.lines() {
        let line = line_result?;
        let mut line = line;

        // Expand tabs if requested
        if let Some((tab_char, tab_width)) = config.expand_tabs {
            line = expand_tabs_in_line(&line, tab_char, tab_width);
        }

        // Process control characters (skip when not needed to avoid copying)
        if config.show_control_chars || config.show_nonprinting {
            line = process_control_chars(&line, config.show_control_chars, config.show_nonprinting);
        }

        all_lines.push(line);
    }

    // Convert to &[u8] slices for the byte-based paginator
    let refs: Vec<&[u8]> = all_lines.iter().map(|s| s.as_bytes()).collect();
    pr_lines_generic(&refs, output, config, filename, file_date)
}

/// Core paginator that works on a slice of byte slices (zero-copy).
fn pr_lines_generic<W: Write>(
    all_lines: &[&[u8]],
    output: &mut W,
    config: &PrConfig,
    filename: &str,
    file_date: Option<SystemTime>,
) -> io::Result<()> {
    let date = file_date.unwrap_or_else(SystemTime::now);

    let header_str = config.header.as_deref().unwrap_or(filename);
    let date_str = format_header_date(&date, &config.date_format);

    // Calculate body lines per page
    // When page_length is too small for header+footer, GNU pr suppresses
    // headers/footers and uses page_length as the body size.
    let suppress_header = !config.omit_header
        && !config.omit_pagination
        && config.page_length <= HEADER_LINES + FOOTER_LINES;
    // When suppress_header is active, create a config view with omit_header set
    // so that sub-functions skip padding to body_lines_per_page.
    let suppressed_config;
    let effective_config = if suppress_header {
        suppressed_config = PrConfig {
            omit_header: true,
            ..config.clone()
        };
        &suppressed_config
    } else {
        config
    };
    let body_lines_per_page = if config.omit_header || config.omit_pagination {
        if config.page_length > 0 {
            config.page_length
        } else {
            DEFAULT_PAGE_LENGTH
        }
    } else if suppress_header {
        config.page_length
    } else {
        config.page_length - HEADER_LINES - FOOTER_LINES
    };

    // Account for double spacing: each input line takes 2 output lines
    let input_lines_per_page = if config.double_space {
        (body_lines_per_page + 1) / 2
    } else {
        body_lines_per_page
    };

    // Handle multi-column mode
    let columns = config.columns.max(1);

    // GNU pr in multi-column down mode: each page has body_lines_per_page rows,
    // each row shows one value from each column. So up to
    // input_lines_per_page * columns input lines can be consumed per page.
    // actual_lines_per_column = ceil(page_lines / columns) for each page.
    let lines_consumed_per_page = if columns > 1 && !config.across {
        input_lines_per_page * columns
    } else {
        input_lines_per_page
    };

    // Split into pages
    let total_lines = all_lines.len();
    let mut line_number = config.first_line_number;
    let mut page_num = 1usize;
    let mut line_idx = 0;
    // Page-level output buffer: batch many small writes into one large write_all
    let mut page_buf: Vec<u8> = Vec::with_capacity(128 * 1024);

    while line_idx < total_lines || (line_idx == 0 && total_lines == 0) {
        // For empty input, output one empty page (matching GNU behavior)
        if total_lines == 0 && line_idx == 0 {
            if page_num >= config.first_page
                && (config.last_page == 0 || page_num <= config.last_page)
            {
                if !config.omit_header && !config.omit_pagination && !suppress_header {
                    write_header(&mut page_buf, &date_str, header_str, page_num, config)?;
                    write_footer(&mut page_buf, config)?;
                    output.write_all(&page_buf)?;
                }
            }
            break;
        }

        let page_end = (line_idx + lines_consumed_per_page).min(total_lines);

        if page_num >= config.first_page && (config.last_page == 0 || page_num <= config.last_page)
        {
            page_buf.clear();

            // Write header to page buffer
            if !config.omit_header && !config.omit_pagination && !suppress_header {
                write_header(&mut page_buf, &date_str, header_str, page_num, config)?;
            }

            // Write body to page buffer
            if columns > 1 {
                write_multicolumn_body(
                    &mut page_buf,
                    &all_lines[line_idx..page_end],
                    effective_config,
                    columns,
                    &mut line_number,
                    body_lines_per_page,
                )?;
            } else {
                write_single_column_body(
                    &mut page_buf,
                    &all_lines[line_idx..page_end],
                    effective_config,
                    &mut line_number,
                    body_lines_per_page,
                )?;
            }

            // Write footer to page buffer
            if !config.omit_header && !config.omit_pagination && !suppress_header {
                write_footer(&mut page_buf, config)?;
            }

            // Flush entire page to output in one call
            output.write_all(&page_buf)?;
        }

        line_idx = page_end;
        page_num += 1;

        // Break if we've consumed all lines
        if line_idx >= total_lines {
            break;
        }
    }

    Ok(())
}

/// Paginate multiple files merged side by side (-m mode).
pub fn pr_merge<W: Write>(
    inputs: &[Vec<String>],
    output: &mut W,
    config: &PrConfig,
    _filenames: &[&str],
    file_dates: &[SystemTime],
) -> io::Result<()> {
    let date = file_dates.first().copied().unwrap_or_else(SystemTime::now);
    let date_str = format_header_date(&date, &config.date_format);
    let header_str = config.header.as_deref().unwrap_or("");

    let suppress_header = !config.omit_header
        && !config.omit_pagination
        && config.page_length <= HEADER_LINES + FOOTER_LINES;
    let body_lines_per_page = if config.omit_header || config.omit_pagination {
        if config.page_length > 0 {
            config.page_length
        } else {
            DEFAULT_PAGE_LENGTH
        }
    } else if suppress_header {
        config.page_length
    } else {
        config.page_length - HEADER_LINES - FOOTER_LINES
    };

    let input_lines_per_page = if config.double_space {
        (body_lines_per_page + 1) / 2
    } else {
        body_lines_per_page
    };

    let num_files = inputs.len();
    let explicit_sep = has_explicit_separator(config);
    let col_sep = get_column_separator(config);
    let col_width = if explicit_sep {
        if num_files > 1 {
            (config
                .page_width
                .saturating_sub(col_sep.len() * (num_files - 1)))
                / num_files
        } else {
            config.page_width
        }
    } else {
        config.page_width / num_files
    };

    let max_lines = inputs.iter().map(|f| f.len()).max().unwrap_or(0);
    let mut page_num = 1usize;
    let mut line_idx = 0;
    let mut line_number = config.first_line_number;

    let col_sep_bytes = col_sep.as_bytes();
    let mut page_buf: Vec<u8> = Vec::with_capacity(128 * 1024);
    let mut num_buf = [0u8; 32];

    while line_idx < max_lines {
        let page_end = (line_idx + input_lines_per_page).min(max_lines);

        if page_num >= config.first_page && (config.last_page == 0 || page_num <= config.last_page)
        {
            page_buf.clear();

            if !config.omit_header && !config.omit_pagination && !suppress_header {
                write_header(&mut page_buf, &date_str, header_str, page_num, config)?;
            }

            let indent_str = " ".repeat(config.indent);
            let mut body_lines_written = 0;
            for i in line_idx..page_end {
                if config.double_space && body_lines_written > 0 {
                    page_buf.push(b'\n');
                    body_lines_written += 1;
                }

                page_buf.extend_from_slice(indent_str.as_bytes());
                let mut abs_pos = config.indent;

                if let Some((sep, digits)) = config.number_lines {
                    let num_str = format_line_number(line_number, sep, digits, &mut num_buf);
                    page_buf.extend_from_slice(num_str);
                    abs_pos += digits + 1;
                    line_number += 1;
                }

                for (fi, file_lines) in inputs.iter().enumerate() {
                    let content = if i < file_lines.len() {
                        file_lines[i].as_bytes()
                    } else {
                        b"" as &[u8]
                    };
                    let truncated = if !explicit_sep && content.len() > col_width.saturating_sub(1)
                    {
                        &content[..col_width.saturating_sub(1)]
                    } else if explicit_sep && config.truncate_lines && content.len() > col_width {
                        &content[..col_width]
                    } else {
                        content
                    };
                    if fi < num_files - 1 {
                        if explicit_sep {
                            if fi > 0 {
                                page_buf.extend_from_slice(col_sep_bytes);
                            }
                            page_buf.extend_from_slice(truncated);
                            abs_pos +=
                                truncated.len() + if fi > 0 { col_sep_bytes.len() } else { 0 };
                        } else {
                            page_buf.extend_from_slice(truncated);
                            abs_pos += truncated.len();
                            let target = (fi + 1) * col_width + config.indent;
                            write_column_padding(&mut page_buf, abs_pos, target)?;
                            abs_pos = target;
                        }
                    } else {
                        if explicit_sep && fi > 0 {
                            page_buf.extend_from_slice(col_sep_bytes);
                        }
                        page_buf.extend_from_slice(truncated);
                    }
                }
                page_buf.push(b'\n');
                body_lines_written += 1;
            }

            // Pad remaining body lines
            while body_lines_written < body_lines_per_page {
                page_buf.push(b'\n');
                body_lines_written += 1;
            }

            if !config.omit_header && !config.omit_pagination && !suppress_header {
                write_footer(&mut page_buf, config)?;
            }

            output.write_all(&page_buf)?;
        }

        line_idx = page_end;
        page_num += 1;
    }

    Ok(())
}

/// Write page header: 2 blank lines, date/header/page line, 2 blank lines.
fn write_header<W: Write>(
    output: &mut W,
    date_str: &str,
    header: &str,
    page_num: usize,
    config: &PrConfig,
) -> io::Result<()> {
    // 2 blank lines
    output.write_all(b"\n\n")?;

    // Header line: date is left-aligned, header is centered, Page N is right-aligned.
    let line_width = config.page_width;

    let left = date_str;
    let center = header;
    let left_len = left.len();
    let center_len = center.len();

    // Format "Page N" without allocation for small page numbers
    let mut page_buf = [0u8; 32];
    let page_str = format_page_number(page_num, &mut page_buf);
    let right_len = page_str.len();

    // GNU pr centers the header title within the line.
    if left_len + center_len + right_len + 2 >= line_width {
        output.write_all(left.as_bytes())?;
        output.write_all(b" ")?;
        output.write_all(center.as_bytes())?;
        output.write_all(b" ")?;
        output.write_all(page_str)?;
        output.write_all(b"\n")?;
    } else {
        let total_spaces = line_width - left_len - center_len - right_len;
        let left_spaces = total_spaces / 2;
        let right_spaces = total_spaces - left_spaces;
        output.write_all(left.as_bytes())?;
        write_spaces(output, left_spaces)?;
        output.write_all(center.as_bytes())?;
        write_spaces(output, right_spaces)?;
        output.write_all(page_str)?;
        output.write_all(b"\n")?;
    }

    // 2 blank lines
    output.write_all(b"\n\n")?;

    Ok(())
}

/// Format "Page N" into a stack buffer, returning the used slice.
#[inline]
fn format_page_number(page_num: usize, buf: &mut [u8; 32]) -> &[u8] {
    const PREFIX: &[u8] = b"Page ";
    let prefix_len = PREFIX.len();
    buf[..prefix_len].copy_from_slice(PREFIX);
    // Format number into a separate stack buffer to avoid overlapping borrow
    let mut num_buf = [0u8; 20];
    let mut n = page_num;
    let mut pos = 19;
    loop {
        num_buf[pos] = b'0' + (n % 10) as u8;
        n /= 10;
        if n == 0 {
            break;
        }
        pos -= 1;
    }
    let num_len = 20 - pos;
    buf[prefix_len..prefix_len + num_len].copy_from_slice(&num_buf[pos..20]);
    &buf[..prefix_len + num_len]
}

/// Write page footer: 5 blank lines (or form feed).
fn write_footer<W: Write>(output: &mut W, config: &PrConfig) -> io::Result<()> {
    if config.form_feed {
        output.write_all(b"\x0c")?;
    } else {
        output.write_all(b"\n\n\n\n\n")?;
    }
    Ok(())
}

/// Write body for single column mode.
fn write_single_column_body<W: Write>(
    output: &mut W,
    lines: &[&[u8]],
    config: &PrConfig,
    line_number: &mut usize,
    body_lines_per_page: usize,
) -> io::Result<()> {
    let indent_str = " ".repeat(config.indent);
    let content_width = if config.truncate_lines {
        compute_content_width(config)
    } else {
        0
    };
    let mut body_lines_written = 0;
    // Pre-allocate line number buffer to avoid per-line write! formatting
    let mut num_buf = [0u8; 32];

    for line in lines.iter() {
        output.write_all(indent_str.as_bytes())?;

        if let Some((sep, digits)) = config.number_lines {
            // Format line number directly into buffer, avoiding write! overhead
            let num_str = format_line_number(*line_number, sep, digits, &mut num_buf);
            output.write_all(num_str)?;
            *line_number += 1;
        }

        let content: &[u8] = if config.truncate_lines {
            if line.len() > content_width {
                &line[..content_width]
            } else {
                line
            }
        } else {
            line
        };

        // Direct write_all of byte slice — no format dispatch or UTF-8 overhead
        output.write_all(content)?;
        output.write_all(b"\n")?;
        body_lines_written += 1;
        if body_lines_written >= body_lines_per_page {
            break;
        }

        // Double-space: write blank line AFTER each content line
        if config.double_space {
            output.write_all(b"\n")?;
            body_lines_written += 1;
            if body_lines_written >= body_lines_per_page {
                break;
            }
        }
    }

    // Pad remaining body lines if not omitting headers
    if !config.omit_header && !config.omit_pagination {
        while body_lines_written < body_lines_per_page {
            output.write_all(b"\n")?;
            body_lines_written += 1;
        }
    }

    Ok(())
}

/// Format a line number with right-aligned padding and separator into a stack buffer.
/// Returns the formatted slice. Avoids write!() per-line overhead.
#[inline]
fn format_line_number(num: usize, sep: char, digits: usize, buf: &mut [u8; 32]) -> &[u8] {
    // Format the number
    let mut n = num;
    let mut pos = 31;
    loop {
        buf[pos] = b'0' + (n % 10) as u8;
        n /= 10;
        if n == 0 || pos == 0 {
            break;
        }
        pos -= 1;
    }
    let num_digits = 32 - pos;
    // Build the output: spaces for padding + number + separator
    let padding = if digits > num_digits {
        digits - num_digits
    } else {
        0
    };
    let total_len = padding + num_digits + sep.len_utf8();
    // We need a separate output buffer since we're using buf for the number
    // Just use the write_all approach with two calls for simplicity
    let start = 32 - num_digits;
    // Return just the number portion; caller handles padding via spaces
    // Actually, let's format properly into a contiguous buffer
    let sep_byte = sep as u8; // ASCII separator assumed
    let out_start = 32usize.saturating_sub(total_len);
    // Fill padding
    for i in out_start..out_start + padding {
        buf[i] = b' ';
    }
    // Number is already at positions [start..32], shift if needed
    if out_start + padding != start {
        let src = start;
        let dst = out_start + padding;
        for i in 0..num_digits {
            buf[dst + i] = buf[src + i];
        }
    }
    // Add separator
    buf[out_start + padding + num_digits] = sep_byte;
    &buf[out_start..out_start + total_len]
}

/// Compute available content width after accounting for numbering and indent.
fn compute_content_width(config: &PrConfig) -> usize {
    let mut w = config.page_width;
    w = w.saturating_sub(config.indent);
    if let Some((_, digits)) = config.number_lines {
        w = w.saturating_sub(digits + 1); // digits + separator
    }
    w
}

/// Write body for multi-column mode.
fn write_multicolumn_body<W: Write>(
    output: &mut W,
    lines: &[&[u8]],
    config: &PrConfig,
    columns: usize,
    line_number: &mut usize,
    body_lines_per_page: usize,
) -> io::Result<()> {
    let explicit_sep = has_explicit_separator(config);
    let col_sep = get_column_separator(config);
    // When no explicit separator, GNU pr uses the full page_width / columns as column width
    // and pads with tabs. When separator is explicit, use sep width in calculation.
    let col_width = if explicit_sep {
        if columns > 1 {
            (config
                .page_width
                .saturating_sub(col_sep.len() * (columns - 1)))
                / columns
        } else {
            config.page_width
        }
    } else {
        config.page_width / columns
    };
    // GNU pr truncates lines in multi-column mode by default, unless -J (join_lines) is set.
    // For non-explicit separator, truncate to col_width - 1 to leave room for padding.
    let do_truncate = !config.join_lines;
    let content_width = if explicit_sep {
        col_width
    } else {
        col_width.saturating_sub(1)
    };

    let indent_str = " ".repeat(config.indent);
    let col_sep_bytes = col_sep.as_bytes();
    let mut body_lines_written = 0;
    let mut num_buf = [0u8; 32];

    if config.across {
        // Print columns across: line 0 fills col0, line 1 fills col1, etc.
        let mut i = 0;
        while i < lines.len() {
            if config.double_space && body_lines_written > 0 {
                output.write_all(b"\n")?;
                body_lines_written += 1;
                if body_lines_written >= body_lines_per_page {
                    break;
                }
            }

            output.write_all(indent_str.as_bytes())?;
            let mut abs_pos = config.indent;

            // Find the last column with data on this row
            let mut last_data_col = 0;
            for col in 0..columns {
                let li = i + col;
                if li < lines.len() {
                    last_data_col = col;
                }
            }

            for col in 0..columns {
                let li = i + col;
                if li < lines.len() {
                    if explicit_sep && col > 0 {
                        output.write_all(col_sep_bytes)?;
                        abs_pos += col_sep_bytes.len();
                    }
                    if let Some((sep, digits)) = config.number_lines {
                        let num_str = format_line_number(*line_number, sep, digits, &mut num_buf);
                        output.write_all(num_str)?;
                        abs_pos += digits + 1;
                        *line_number += 1;
                    }
                    let content: &[u8] = lines[li];
                    let mut truncated = if do_truncate && content.len() > content_width {
                        &content[..content_width]
                    } else {
                        content
                    };
                    // GNU pr strips trailing spaces from the last column
                    if col == last_data_col && !explicit_sep {
                        while truncated.last() == Some(&b' ') {
                            truncated = &truncated[..truncated.len() - 1];
                        }
                    }
                    output.write_all(truncated)?;
                    abs_pos += truncated.len();
                    if col < last_data_col && !explicit_sep {
                        let target = (col + 1) * col_width + config.indent;
                        write_column_padding(output, abs_pos, target)?;
                        abs_pos = target;
                    }
                }
            }
            output.write_all(b"\n")?;
            body_lines_written += 1;
            i += columns;
        }
    } else {
        // Print columns down: distribute lines across columns.
        // GNU pr distributes evenly: base = lines/cols, extra = lines%cols.
        // First 'extra' columns get base+1 lines, rest get base lines.
        let n = lines.len();
        let base = n / columns;
        let extra = n % columns;

        // Compute start offset of each column
        let mut col_starts = vec![0usize; columns + 1];
        for col in 0..columns {
            let col_lines = base + if col < extra { 1 } else { 0 };
            col_starts[col + 1] = col_starts[col] + col_lines;
        }

        // Number of rows = max lines in any column
        let num_rows = if extra > 0 { base + 1 } else { base };

        for row in 0..num_rows {
            if config.double_space && row > 0 {
                output.write_all(b"\n")?;
                body_lines_written += 1;
                if body_lines_written >= body_lines_per_page {
                    break;
                }
            }

            output.write_all(indent_str.as_bytes())?;
            let mut abs_pos = config.indent;

            // Find the last column with data for this row
            let mut last_data_col = 0;
            for col in 0..columns {
                let col_lines = col_starts[col + 1] - col_starts[col];
                if row < col_lines {
                    last_data_col = col;
                }
            }

            for col in 0..columns {
                let col_lines = col_starts[col + 1] - col_starts[col];
                let li = col_starts[col] + row;
                if row < col_lines {
                    if explicit_sep && col > 0 {
                        output.write_all(col_sep_bytes)?;
                        abs_pos += col_sep_bytes.len();
                    }
                    if let Some((sep, digits)) = config.number_lines {
                        let num = config.first_line_number + li;
                        let num_str = format_line_number(num, sep, digits, &mut num_buf);
                        output.write_all(num_str)?;
                        abs_pos += digits + 1;
                    }
                    let content: &[u8] = lines[li];
                    let mut truncated = if do_truncate && content.len() > content_width {
                        &content[..content_width]
                    } else {
                        content
                    };
                    // GNU pr strips trailing spaces from the last column
                    if col == last_data_col && !explicit_sep {
                        while truncated.last() == Some(&b' ') {
                            truncated = &truncated[..truncated.len() - 1];
                        }
                    }
                    output.write_all(truncated)?;
                    abs_pos += truncated.len();
                    if col < last_data_col && !explicit_sep {
                        // Not the last column with data: pad to next column boundary
                        let target = (col + 1) * col_width + config.indent;
                        write_column_padding(output, abs_pos, target)?;
                        abs_pos = target;
                    }
                } else if col <= last_data_col {
                    // Empty column before the last data column: pad to next boundary
                    if explicit_sep {
                        if col > 0 {
                            output.write_all(col_sep_bytes)?;
                            abs_pos += col_sep_bytes.len();
                        }
                        // For explicit separator, just write separator, no padding
                    } else {
                        let target = (col + 1) * col_width + config.indent;
                        write_column_padding(output, abs_pos, target)?;
                        abs_pos = target;
                    }
                }
                // Empty columns after last data column: skip entirely
            }
            output.write_all(b"\n")?;
            body_lines_written += 1;
        }
        // Update line_number for the lines we processed
        if config.number_lines.is_some() {
            *line_number += lines.len();
        }
    }

    // Pad remaining body lines
    if !config.omit_header && !config.omit_pagination {
        while body_lines_written < body_lines_per_page {
            output.write_all(b"\n")?;
            body_lines_written += 1;
        }
    }

    Ok(())
}
