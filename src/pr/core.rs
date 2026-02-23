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
    let mut result = String::with_capacity(line.len());
    let mut col = 0;
    for ch in line.chars() {
        if ch == tab_char {
            let spaces = tab_width - (col % tab_width);
            for _ in 0..spaces {
                result.push(' ');
            }
            col += spaces;
        } else {
            result.push(ch);
            col += 1;
        }
    }
    result
}

/// Convert a character to hat notation (^X) for control characters.
fn to_hat_notation(ch: char) -> String {
    let b = ch as u32;
    if b < 32 {
        format!("^{}", (b as u8 + b'@') as char)
    } else if b == 127 {
        "^?".to_string()
    } else {
        ch.to_string()
    }
}

/// Convert a character using -v notation (like cat -v).
fn to_nonprinting(ch: char) -> String {
    let b = ch as u32;
    if b < 32 && b != 9 && b != 10 {
        // Control chars except TAB and LF
        format!("^{}", (b as u8 + b'@') as char)
    } else if b == 127 {
        "^?".to_string()
    } else if b >= 128 && b < 160 {
        format!("M-^{}", (b as u8 - 128 + b'@') as char)
    } else if b >= 160 && b < 255 {
        format!("M-{}", (b as u8 - 128) as char)
    } else if b == 255 {
        "M-^?".to_string()
    } else {
        ch.to_string()
    }
}

/// Process a line for control char display.
fn process_control_chars(line: &str, show_control: bool, show_nonprinting: bool) -> String {
    if !show_control && !show_nonprinting {
        return line.to_string();
    }
    let mut result = String::with_capacity(line.len());
    for ch in line.chars() {
        if show_nonprinting {
            result.push_str(&to_nonprinting(ch));
        } else if show_control {
            result.push_str(&to_hat_notation(ch));
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
    let tab_size = 8;
    let mut pos = abs_pos;
    while pos < target_abs_pos {
        let next_tab = ((pos / tab_size) + 1) * tab_size;
        if next_tab <= target_abs_pos {
            output.write_all(b"\t")?;
            pos = next_tab;
        } else {
            let n = target_abs_pos - pos;
            if n <= SPACES.len() {
                output.write_all(&SPACES[..n])?;
            } else {
                for _ in 0..n {
                    output.write_all(b" ")?;
                }
            }
            pos = target_abs_pos;
        }
    }
    Ok(())
}

/// Paginate raw byte data — fast path that avoids per-line String allocation.
/// When no tab expansion or control char processing is needed, lines are
/// extracted as &str slices directly from the input buffer (zero-copy).
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

    // Fast path: zero-copy line extraction from byte data
    let text = String::from_utf8_lossy(data);
    // Split into lines without trailing newlines (matching BufRead::lines behavior)
    let all_lines: Vec<&str> = text
        .split('\n')
        .map(|l| l.strip_suffix('\r').unwrap_or(l))
        .collect();
    // Remove trailing empty line from final newline (matching lines() behavior)
    let all_lines = if all_lines.last() == Some(&"") {
        &all_lines[..all_lines.len() - 1]
    } else {
        &all_lines[..]
    };

    pr_lines_generic(all_lines, output, config, filename, file_date)
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

    // Convert to &str slice for the generic paginator
    let refs: Vec<&str> = all_lines.iter().map(|s| s.as_str()).collect();
    pr_lines_generic(&refs, output, config, filename, file_date)
}

/// Core paginator that works on a slice of string references.
fn pr_lines_generic<W: Write>(
    all_lines: &[&str],
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

    while line_idx < total_lines || (line_idx == 0 && total_lines == 0) {
        // For empty input, output one empty page (matching GNU behavior)
        if total_lines == 0 && line_idx == 0 {
            if page_num >= config.first_page
                && (config.last_page == 0 || page_num <= config.last_page)
            {
                if !config.omit_header && !config.omit_pagination && !suppress_header {
                    write_header(output, &date_str, header_str, page_num, config)?;
                }
                if !config.omit_header && !config.omit_pagination && !suppress_header {
                    write_footer(output, config)?;
                }
            }
            break;
        }

        let page_end = (line_idx + lines_consumed_per_page).min(total_lines);

        if page_num >= config.first_page && (config.last_page == 0 || page_num <= config.last_page)
        {
            // Write header
            if !config.omit_header && !config.omit_pagination && !suppress_header {
                write_header(output, &date_str, header_str, page_num, config)?;
            }

            // Write body
            if columns > 1 {
                write_multicolumn_body(
                    output,
                    &all_lines[line_idx..page_end],
                    effective_config,
                    columns,
                    &mut line_number,
                    body_lines_per_page,
                )?;
            } else {
                write_single_column_body(
                    output,
                    &all_lines[line_idx..page_end],
                    effective_config,
                    &mut line_number,
                    body_lines_per_page,
                )?;
            }

            // Write footer
            if !config.omit_header && !config.omit_pagination && !suppress_header {
                write_footer(output, config)?;
            }
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

    while line_idx < max_lines {
        let page_end = (line_idx + input_lines_per_page).min(max_lines);

        if page_num >= config.first_page && (config.last_page == 0 || page_num <= config.last_page)
        {
            if !config.omit_header && !config.omit_pagination && !suppress_header {
                write_header(output, &date_str, header_str, page_num, config)?;
            }

            let indent_str = " ".repeat(config.indent);
            let mut body_lines_written = 0;
            for i in line_idx..page_end {
                if config.double_space && body_lines_written > 0 {
                    writeln!(output)?;
                    body_lines_written += 1;
                }

                output.write_all(indent_str.as_bytes())?;
                let mut abs_pos = config.indent;

                if let Some((sep, digits)) = config.number_lines {
                    write!(output, "{:>width$}{}", line_number, sep, width = digits)?;
                    abs_pos += digits + 1;
                    line_number += 1;
                }

                for (fi, file_lines) in inputs.iter().enumerate() {
                    let content = if i < file_lines.len() {
                        &file_lines[i]
                    } else {
                        ""
                    };
                    let truncated = if !explicit_sep && content.len() > col_width.saturating_sub(1)
                    {
                        // Non-explicit separator: always truncate, leave room for separator
                        &content[..col_width.saturating_sub(1)]
                    } else if explicit_sep && config.truncate_lines && content.len() > col_width {
                        // Explicit separator with -W: truncate to col_width
                        &content[..col_width]
                    } else {
                        content
                    };
                    if fi < num_files - 1 {
                        // Non-last column: pad to next column boundary
                        if explicit_sep {
                            if fi > 0 {
                                write!(output, "{}", col_sep)?;
                            }
                            write!(output, "{:<width$}", truncated, width = col_width)?;
                            abs_pos = (fi + 1) * col_width + config.indent + fi * col_sep.len();
                        } else {
                            write!(output, "{}", truncated)?;
                            abs_pos += truncated.len();
                            let target = (fi + 1) * col_width + config.indent;
                            write_column_padding(output, abs_pos, target)?;
                            abs_pos = target;
                        }
                    } else {
                        // Last column: no padding
                        if explicit_sep && fi > 0 {
                            write!(output, "{}", col_sep)?;
                        }
                        write!(output, "{}", truncated)?;
                    }
                }
                writeln!(output)?;
                body_lines_written += 1;
            }

            // Pad remaining body lines
            while body_lines_written < body_lines_per_page {
                writeln!(output)?;
                body_lines_written += 1;
            }

            if !config.omit_header && !config.omit_pagination && !suppress_header {
                write_footer(output, config)?;
            }
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
    lines: &[&str],
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

        let content = if config.truncate_lines {
            if line.len() > content_width {
                &line[..content_width]
            } else {
                line
            }
        } else {
            line
        };

        // Direct write_all avoids std::fmt Display dispatch overhead
        output.write_all(content.as_bytes())?;
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
    lines: &[&str],
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

    let indent_str = " ".repeat(config.indent);
    let mut body_lines_written = 0;

    if config.across {
        // Print columns across: line 0 fills col0, line 1 fills col1, etc.
        let mut i = 0;
        while i < lines.len() {
            if config.double_space && body_lines_written > 0 {
                writeln!(output)?;
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
                        write!(output, "{}", col_sep)?;
                        abs_pos += col_sep.len();
                    }
                    if let Some((sep, digits)) = config.number_lines {
                        write!(output, "{:>width$}{}", line_number, sep, width = digits)?;
                        abs_pos += digits + 1;
                        *line_number += 1;
                    }
                    let content = lines[li];
                    let truncated = if config.truncate_lines && content.len() > col_width {
                        &content[..col_width]
                    } else {
                        content
                    };
                    output.write_all(truncated.as_bytes())?;
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
                writeln!(output)?;
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
                        write!(output, "{}", col_sep)?;
                        abs_pos += col_sep.len();
                    }
                    if let Some((sep, digits)) = config.number_lines {
                        let num = config.first_line_number + li;
                        write!(output, "{:>width$}{}", num, sep, width = digits)?;
                        abs_pos += digits + 1;
                    }
                    let content = lines[li];
                    let truncated = if config.truncate_lines && content.len() > col_width {
                        &content[..col_width]
                    } else {
                        content
                    };
                    output.write_all(truncated.as_bytes())?;
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
                            write!(output, "{}", col_sep)?;
                            abs_pos += col_sep.len();
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
