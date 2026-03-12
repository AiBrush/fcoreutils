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
    // GNU pr uses tabs (8-stop) + trailing spaces to reach column boundary.
    // When the gap can be filled entirely with spaces fewer than one tab
    // stop away, just emit spaces (matching GNU's encoder).
    let n = target_abs_pos.saturating_sub(abs_pos);
    if n == 0 {
        return Ok(());
    }
    let next_tab = (abs_pos / 8 + 1) * 8;
    if next_tab > target_abs_pos {
        // Gap doesn't reach next tab stop → spaces only
        return write_spaces(output, n);
    }
    // Tab to the first tab stop, then continue
    output.write_all(b"\t")?;
    let mut col = next_tab;
    while col < target_abs_pos {
        let nt = (col / 8 + 1) * 8;
        if nt <= target_abs_pos {
            output.write_all(b"\t")?;
            col = nt;
        } else {
            write_spaces(output, target_abs_pos - col)?;
            col = target_abs_pos;
        }
    }
    Ok(())
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

    // Single SIMD pass to detect CR/FF (rare in normal files); cache result
    // for all fast-path guards below.
    let has_cr_or_ff = memchr::memchr2(b'\r', b'\x0c', data).is_some();

    // Ultra-fast path: single column, no per-line transforms → contiguous chunk writes
    let is_simple = config.columns <= 1
        && config.number_lines.is_none()
        && config.indent == 0
        && !config.truncate_lines
        && !config.double_space
        && !config.across
        && !has_cr_or_ff;

    if is_simple {
        // Passthrough: -T (omit_pagination) with no transforms and no page range → output == input.
        if config.omit_pagination && config.first_page == 1 && config.last_page == 0 {
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
        && !has_cr_or_ff
    {
        return pr_data_numbered(data, output, config, filename, file_date);
    }

    // Fast path: multi-column down mode without numbering, no transforms.
    if config.columns > 1
        && config.columns <= 32
        && !config.across
        && config.number_lines.is_none()
        && config.indent == 0
        && !config.double_space
        && !config.join_lines
        && data.len() <= u32::MAX as usize
        && !has_cr_or_ff
    {
        return pr_data_multicolumn_fast(data, output, config, filename, file_date);
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

/// Fast multi-column "down" paginator using unsafe pointer arithmetic.
/// Pre-splits lines via SIMD memchr, pre-computes column padding, and builds
/// output directly into a Vec<u8> buffer with bulk copies. Avoids the many
/// small extend_from_slice calls of the generic multicolumn path.
fn pr_data_multicolumn_fast<W: Write>(
    data: &[u8],
    output: &mut W,
    config: &PrConfig,
    filename: &str,
    file_date: Option<SystemTime>,
) -> io::Result<()> {
    let date = file_date.unwrap_or_else(SystemTime::now);
    let header_str = config.header.as_deref().unwrap_or(filename);
    let date_str = format_header_date(&date, &config.date_format);

    let columns = config.columns.max(1);
    let explicit_sep = has_explicit_separator(config);
    let col_sep = get_column_separator(config);
    let col_sep_bytes = col_sep.as_bytes();
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
    let content_width = if explicit_sep {
        col_width
    } else {
        col_width.saturating_sub(1)
    };

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
    let lines_consumed_per_page = body_lines_per_page * columns;

    // Pre-split lines using SIMD memchr — store (start, len) as u32 pairs for compactness
    let mut line_offsets: Vec<(u32, u32)> = Vec::with_capacity(data.len() / 40 + 64);
    let mut start = 0usize;
    for pos in memchr::memchr_iter(b'\n', data) {
        line_offsets.push((start as u32, (pos - start) as u32));
        start = pos + 1;
    }
    if start < data.len() {
        line_offsets.push((start as u32, (data.len() - start) as u32));
    }
    let total_lines = line_offsets.len();

    // Single output buffer
    let out_cap = (data.len() + data.len() / 3 + 4096).min(64 * 1024 * 1024);
    let mut out_buf: Vec<u8> = Vec::with_capacity(out_cap);

    let mut line_idx = 0usize;
    let mut page_num = 1usize;
    let src = data.as_ptr();

    while line_idx < total_lines || (line_idx == 0 && total_lines == 0) {
        if total_lines == 0 {
            if show_header
                && page_num >= config.first_page
                && (config.last_page == 0 || page_num <= config.last_page)
            {
                write_header(&mut out_buf, &date_str, header_str, page_num, config)?;
                write_footer(&mut out_buf, config)?;
            }
            break;
        }

        let page_end = (line_idx + lines_consumed_per_page).min(total_lines);
        let page_lines = &line_offsets[line_idx..page_end];
        let n = page_lines.len();

        if page_num >= config.first_page && (config.last_page == 0 || page_num <= config.last_page)
        {
            if show_header {
                write_header(&mut out_buf, &date_str, header_str, page_num, config)?;
            }

            // Compute column layout: "down" mode distributes lines across columns
            let base = n / columns;
            let extra = n % columns;
            // Guard ensures columns <= 32, so col_starts[columns] is always in bounds.
            let mut col_starts = [0u32; 33];
            let max_cols = columns;
            for col in 0..max_cols {
                let col_lines = base + if col < extra { 1 } else { 0 };
                col_starts[col + 1] = col_starts[col] + col_lines as u32;
            }
            let num_rows = if extra > 0 { base + 1 } else { base };

            // Build rows directly
            for row in 0..num_rows {
                // Find last column with data for this row
                let mut last_data_col = 0;
                for col in 0..max_cols {
                    let col_lines = (col_starts[col + 1] - col_starts[col]) as usize;
                    if row < col_lines {
                        last_data_col = col;
                    }
                }

                let mut abs_pos = 0usize;
                for col in 0..max_cols {
                    let col_lines = (col_starts[col + 1] - col_starts[col]) as usize;
                    if row < col_lines {
                        let li = col_starts[col] as usize + row;
                        let (off, len) = page_lines[li];
                        let content_len = (len as usize).min(content_width);

                        if explicit_sep && col > 0 {
                            out_buf.extend_from_slice(col_sep_bytes);
                            abs_pos += col_sep_bytes.len();
                        }

                        // Copy line content directly from source.
                        // SAFETY: `src` is `data.as_ptr()` and `out_buf` is a separate
                        // allocation, so reallocating `out_buf` cannot invalidate `src`.
                        // `off` and `len` come from `line_offsets` built by iterating
                        // `memchr_iter` over `data`, guaranteeing `off + len <= data.len()`.
                        // `content_len = len.min(content_width) <= len`, so
                        // `off as usize + content_len <= data.len()`. The u32→usize cast
                        // is lossless because the guard ensures `data.len() <= u32::MAX`.
                        if content_len > 0 {
                            let wp = out_buf.len();
                            out_buf.reserve(content_len);
                            unsafe {
                                std::ptr::copy_nonoverlapping(
                                    src.add(off as usize),
                                    out_buf.as_mut_ptr().add(wp),
                                    content_len,
                                );
                                out_buf.set_len(wp + content_len);
                            }
                        }

                        // Strip trailing spaces from last data column (GNU compat)
                        if col == last_data_col && !explicit_sep {
                            while out_buf.last() == Some(&b' ') {
                                out_buf.pop();
                            }
                        }

                        // abs_pos tracks the column alignment position. The trailing
                        // space strip only fires on last_data_col, after which no more
                        // padding is needed, so the divergence is harmless.
                        abs_pos += content_len;

                        // Pad to next column boundary
                        if col < last_data_col && !explicit_sep {
                            let target = (col + 1) * col_width;
                            if abs_pos < target {
                                write_column_padding_buf(&mut out_buf, abs_pos, target);
                                abs_pos = target;
                            }
                        }
                    } else if col <= last_data_col {
                        // Empty column before last data column
                        if explicit_sep {
                            if col > 0 {
                                out_buf.extend_from_slice(col_sep_bytes);
                                abs_pos += col_sep_bytes.len();
                            }
                        } else {
                            let target = (col + 1) * col_width;
                            write_column_padding_buf(&mut out_buf, abs_pos, target);
                            abs_pos = target;
                        }
                    }
                }
                out_buf.push(b'\n');
            }

            // Pad remaining body lines
            let body_lines_written = num_rows;
            if show_header {
                let pad = body_lines_per_page.saturating_sub(body_lines_written);
                out_buf.resize(out_buf.len() + pad, b'\n');
                write_footer(&mut out_buf, config)?;
            }

            if out_buf.len() >= 64 * 1024 * 1024 {
                output.write_all(&out_buf)?;
                out_buf.clear();
            }
        }

        line_idx = page_end;
        page_num += 1;
    }

    if !out_buf.is_empty() {
        output.write_all(&out_buf)?;
    }
    Ok(())
}

/// Write column padding (tabs + spaces) directly into a Vec<u8> buffer.
/// Avoids the Write trait overhead of write_column_padding.
#[inline]
fn write_column_padding_buf(buf: &mut Vec<u8>, abs_pos: usize, target: usize) {
    let n = target.saturating_sub(abs_pos);
    if n == 0 {
        return;
    }
    let next_tab = (abs_pos / 8 + 1) * 8;
    if next_tab > target {
        // Gap doesn't reach next tab stop — spaces only
        buf.resize(buf.len() + n, b' ');
        return;
    }
    buf.push(b'\t');
    let mut col = next_tab;
    while col < target {
        let nt = (col / 8 + 1) * 8;
        if nt <= target {
            buf.push(b'\t');
            col = nt;
        } else {
            buf.resize(buf.len() + (target - col), b' ');
            col = target;
        }
    }
}

/// Count newlines in a u64 word using SWAR (SIMD Within A Register).
/// Returns the number of 0x0A bytes in the word.
#[inline(always)]
fn count_newlines_u64(word: u64) -> u32 {
    let xor = word ^ 0x0A0A_0A0A_0A0A_0A0Au64;
    let lo = xor.wrapping_sub(0x0101_0101_0101_0101u64);
    let hi = !xor & 0x8080_8080_8080_8080u64;
    (lo & hi).count_ones()
}

/// Ultra-fast contiguous-write paginator for single-column, no-transform mode.
/// Two-pass approach: find page boundaries via SWAR+memchr, then build IoSlice
/// references interleaving metadata (headers/footers) with zero-copy body slices
/// from the original mmap data. Batched writev calls for output.
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

    // Pass 1: find page boundaries using SWAR block counting.
    // Process 64-byte blocks: count newlines with SWAR (8 u64 words per block),
    // skip blocks that don't contain a page boundary, and only do precise
    // memchr_iter scanning in blocks that cross a boundary. This reduces
    // per-newline branch overhead from 2M iterations to ~35K.
    let est_pages = data.len() / (body_lines_per_page * 40) + 2;
    let mut page_bounds: Vec<usize> = Vec::with_capacity(est_pages + 1);
    let mut page_line_counts: Vec<usize> = Vec::with_capacity(est_pages);
    page_bounds.push(0);
    let mut lines_count = 0usize;
    let block_size = 64usize;
    let mut block_start = 0usize;
    let ptr = data.as_ptr();
    while block_start + block_size <= data.len() {
        let mut block_nl = 0u32;
        unsafe {
            for i in 0..8 {
                let word = std::ptr::read_unaligned(ptr.add(block_start + i * 8) as *const u64);
                block_nl += count_newlines_u64(word);
            }
        }
        let block_nl = block_nl as usize;
        if lines_count + block_nl < body_lines_per_page {
            lines_count += block_nl;
            block_start += block_size;
        } else {
            for nl_pos in memchr::memchr_iter(b'\n', &data[block_start..block_start + block_size]) {
                lines_count += 1;
                if lines_count >= body_lines_per_page {
                    page_bounds.push(block_start + nl_pos + 1);
                    page_line_counts.push(lines_count);
                    lines_count = 0;
                }
            }
            block_start += block_size;
        }
    }
    // Handle remaining bytes after last full block
    for nl_pos in memchr::memchr_iter(b'\n', &data[block_start..]) {
        lines_count += 1;
        if lines_count >= body_lines_per_page {
            page_bounds.push(block_start + nl_pos + 1);
            page_line_counts.push(lines_count);
            lines_count = 0;
        }
    }
    if *page_bounds.last().unwrap() < data.len() {
        page_bounds.push(data.len());
        page_line_counts.push(lines_count);
    }
    let total_pages = page_bounds.len() - 1;

    let first_visible = config.first_page.max(1) - 1;
    let last_visible = if config.last_page == 0 {
        total_pages
    } else {
        config.last_page.min(total_pages)
    };
    if first_visible >= total_pages {
        return Ok(());
    }

    if !show_header {
        // No headers/footers — write visible body pages contiguously
        let start = page_bounds[first_visible];
        let end = page_bounds[last_visible];
        return output.write_all(&data[start..end]);
    }

    // Pass 2: build output in a single buffer with 4MB flush threshold.
    // Headers/footers are generated inline; body data is copied from the mmap.
    // A single large write_all uses fewer syscalls than batched writev, which
    // is critical for file output (where writev overhead dominates).
    let visible_count = last_visible - first_visible;
    let footer_bytes: &[u8] = if config.form_feed {
        b"\x0c"
    } else {
        b"\n\n\n\n\n"
    };
    let date_bytes = date_str.as_bytes();
    let header_bytes = header_str.as_bytes();
    let line_width = config.page_width;
    let left_len = date_bytes.len();
    let center_len = header_bytes.len();
    let page_prefix = b"Page ";
    let base_right_len = page_prefix.len() + 1;
    let overflow = left_len + center_len + base_right_len + 2 >= line_width;
    let flush_threshold = 4 * 1024 * 1024;
    let mut out_buf: Vec<u8> = Vec::with_capacity(flush_threshold + 256 * 1024);
    let mut num_tmp = [0u8; 20];

    for pi in first_visible..last_visible {
        let page_num = pi + 1;
        let body_start = page_bounds[pi];
        let body_end = page_bounds[pi + 1];

        if overflow {
            out_buf.extend_from_slice(b"\n\n");
            out_buf.extend_from_slice(date_bytes);
            out_buf.push(b' ');
            out_buf.extend_from_slice(header_bytes);
            out_buf.push(b' ');
            out_buf.extend_from_slice(page_prefix);
            let mut n = page_num;
            let mut pos = 19usize;
            loop {
                num_tmp[pos] = b'0' + (n % 10) as u8;
                n /= 10;
                if n == 0 {
                    break;
                }
                pos -= 1;
            }
            out_buf.extend_from_slice(&num_tmp[pos..20]);
            out_buf.extend_from_slice(b"\n\n\n");
        } else {
            let mut n = page_num;
            let mut pos = 19usize;
            loop {
                num_tmp[pos] = b'0' + (n % 10) as u8;
                n /= 10;
                if n == 0 {
                    break;
                }
                pos -= 1;
            }
            let num_digits = 20 - pos;
            let right_len = page_prefix.len() + num_digits;
            let total_spaces = line_width - left_len - center_len - right_len;
            let left_spaces = total_spaces / 2;
            let right_spaces = total_spaces - left_spaces;
            let hdr_len =
                2 + left_len + left_spaces + center_len + right_spaces + 5 + num_digits + 3;
            out_buf.reserve(hdr_len);
            let wp = out_buf.len();
            unsafe {
                let dst = out_buf.as_mut_ptr().add(wp);
                *dst = b'\n';
                *dst.add(1) = b'\n';
                let mut off = 2;
                std::ptr::copy_nonoverlapping(date_bytes.as_ptr(), dst.add(off), left_len);
                off += left_len;
                std::ptr::write_bytes(dst.add(off), b' ', left_spaces);
                off += left_spaces;
                std::ptr::copy_nonoverlapping(header_bytes.as_ptr(), dst.add(off), center_len);
                off += center_len;
                std::ptr::write_bytes(dst.add(off), b' ', right_spaces);
                off += right_spaces;
                std::ptr::copy_nonoverlapping(page_prefix.as_ptr(), dst.add(off), 5);
                off += 5;
                std::ptr::copy_nonoverlapping(num_tmp.as_ptr().add(pos), dst.add(off), num_digits);
                off += num_digits;
                *dst.add(off) = b'\n';
                *dst.add(off + 1) = b'\n';
                *dst.add(off + 2) = b'\n';
                off += 3;
                out_buf.set_len(wp + off);
            }
        }

        out_buf.extend_from_slice(&data[body_start..body_end]);

        let actual_lines = page_line_counts[pi];
        let has_unterminated = body_end > body_start && data[body_end - 1] != b'\n';
        if has_unterminated {
            out_buf.push(b'\n');
        }
        let effective_lines = actual_lines + has_unterminated as usize;
        let pad = body_lines_per_page.saturating_sub(effective_lines);
        out_buf.resize(out_buf.len() + pad, b'\n');
        out_buf.extend_from_slice(footer_bytes);

        if out_buf.len() >= flush_threshold {
            output.write_all(&out_buf)?;
            out_buf.clear();
        }
    }

    if !out_buf.is_empty() {
        output.write_all(&out_buf)?;
    }
    let _ = visible_count;
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
    debug_assert!(sep_char.is_ascii(), "number separator must be ASCII");
    let sep_byte = sep_char as u8;
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

    // Single output buffer — avoids per-page write_all syscalls.
    // Initial capacity capped at 64MB; Vec grows on demand for larger inputs.
    let num_prefix_est = digits + 2; // padding + digits + separator
    let out_cap =
        (data.len() + total_lines * num_prefix_est + total_lines / 5 + 4096).min(64 * 1024 * 1024);
    let mut out_buf: Vec<u8> = Vec::with_capacity(out_cap);

    let mut line_number = config.first_line_number;
    let mut page_num = 1usize;
    let mut line_idx = 0;

    while line_idx < total_lines {
        let page_end = (line_idx + body_lines_per_page).min(total_lines);
        let in_range = page_num >= config.first_page
            && (config.last_page == 0 || page_num <= config.last_page);

        if in_range {
            if show_header {
                write_header(&mut out_buf, &date_str, header_str, page_num, config)?;
            }

            // Write numbered lines using unsafe pointer arithmetic.
            // SAFETY: `src` points into `data` (a borrowed &[u8]) and is
            // independent of `out_buf`. Reallocations of `out_buf` cannot
            // invalidate `src` because they are separate allocations.
            let src = data.as_ptr();
            for li in line_idx..page_end {
                let line_start = line_starts[li];
                let line_end = if li + 1 < line_starts.len() {
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

                let wp = out_buf.len();

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
                let actual_prefix = padding + num_digits + 1;

                let needed = actual_prefix + line_len + 1;
                if out_buf.len() + needed > out_buf.capacity() {
                    out_buf.reserve(needed);
                }
                let base = out_buf.as_mut_ptr();

                unsafe {
                    let dst = base.add(wp);
                    std::ptr::write_bytes(dst, b' ', padding);
                    std::ptr::copy_nonoverlapping(
                        num_tmp.as_ptr().add(num_pos),
                        dst.add(padding),
                        num_digits,
                    );
                    *dst.add(padding + num_digits) = sep_byte;
                    if line_len > 0 {
                        std::ptr::copy_nonoverlapping(
                            src.add(line_start),
                            dst.add(actual_prefix),
                            line_len,
                        );
                    }
                    *dst.add(actual_prefix + line_len) = b'\n';
                    out_buf.set_len(wp + actual_prefix + line_len + 1);
                }

                line_number += 1;
            }

            if show_header {
                let body_lines_written = page_end - line_idx;
                let pad = body_lines_per_page.saturating_sub(body_lines_written);
                out_buf.resize(out_buf.len() + pad, b'\n');
                write_footer(&mut out_buf, config)?;
            }

            // Flush to writer when buffer exceeds 64MB to bound memory usage.
            if out_buf.len() >= 64 * 1024 * 1024 {
                output.write_all(&out_buf)?;
                out_buf.clear();
            }
        } else {
            line_number += page_end - line_idx;
        }

        line_idx = page_end;
        page_num += 1;
    }

    if !out_buf.is_empty() {
        output.write_all(&out_buf)?;
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

    // Single output buffer for all pages — one write_all at the end
    let total_lines = all_lines.len();
    let mut line_number = config.first_line_number;
    let mut page_num = 1usize;
    let mut line_idx = 0;
    let total_bytes: usize = all_lines.iter().map(|l| l.len() + 1).sum();
    // Initial capacity capped at 64MB; Vec grows on demand for larger inputs.
    let out_cap = (total_bytes + total_bytes / 5 + 4096).min(64 * 1024 * 1024);
    let mut out_buf: Vec<u8> = Vec::with_capacity(out_cap);

    while line_idx < total_lines || (line_idx == 0 && total_lines == 0) {
        if total_lines == 0 && line_idx == 0 {
            if page_num >= config.first_page
                && (config.last_page == 0 || page_num <= config.last_page)
            {
                if !config.omit_header && !config.omit_pagination && !suppress_header {
                    write_header(&mut out_buf, &date_str, header_str, page_num, config)?;
                    write_footer(&mut out_buf, config)?;
                }
            }
            break;
        }

        let page_end = (line_idx + lines_consumed_per_page).min(total_lines);

        if page_num >= config.first_page && (config.last_page == 0 || page_num <= config.last_page)
        {
            if !config.omit_header && !config.omit_pagination && !suppress_header {
                write_header(&mut out_buf, &date_str, header_str, page_num, config)?;
            }

            if columns > 1 {
                write_multicolumn_body(
                    &mut out_buf,
                    &all_lines[line_idx..page_end],
                    effective_config,
                    columns,
                    &mut line_number,
                    body_lines_per_page,
                )?;
            } else {
                write_single_column_body(
                    &mut out_buf,
                    &all_lines[line_idx..page_end],
                    effective_config,
                    &mut line_number,
                    body_lines_per_page,
                )?;
            }

            if !config.omit_header && !config.omit_pagination && !suppress_header {
                write_footer(&mut out_buf, config)?;
            }

            // Flush to writer when buffer exceeds 64MB to bound memory usage.
            if out_buf.len() >= 64 * 1024 * 1024 {
                output.write_all(&out_buf)?;
                out_buf.clear();
            }
        }

        line_idx = page_end;
        page_num += 1;

        if line_idx >= total_lines {
            break;
        }
    }

    if !out_buf.is_empty() {
        output.write_all(&out_buf)?;
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
