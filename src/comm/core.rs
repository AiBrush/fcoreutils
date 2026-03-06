use std::cmp::Ordering;
use std::io::{self, Write};

/// How to handle sort-order checking.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum OrderCheck {
    /// Default: check, warn once per file, continue, exit 1
    Default,
    /// --check-order: check, error, stop immediately
    Strict,
    /// --nocheck-order: no checking
    None,
}

/// Configuration for the comm command.
pub struct CommConfig {
    pub suppress_col1: bool,
    pub suppress_col2: bool,
    pub suppress_col3: bool,
    pub case_insensitive: bool,
    pub order_check: OrderCheck,
    pub output_delimiter: Option<Vec<u8>>,
    pub total: bool,
    pub zero_terminated: bool,
}

impl Default for CommConfig {
    fn default() -> Self {
        Self {
            suppress_col1: false,
            suppress_col2: false,
            suppress_col3: false,
            case_insensitive: false,
            order_check: OrderCheck::Default,
            output_delimiter: None,
            total: false,
            zero_terminated: false,
        }
    }
}

/// Result of the comm operation.
pub struct CommResult {
    pub count1: usize,
    pub count2: usize,
    pub count3: usize,
    pub had_order_error: bool,
}

/// Compare two byte slices, optionally case-insensitive (ASCII).
#[inline(always)]
fn compare_lines(a: &[u8], b: &[u8], case_insensitive: bool) -> Ordering {
    if case_insensitive {
        for (&ca, &cb) in a.iter().zip(b.iter()) {
            match ca.to_ascii_lowercase().cmp(&cb.to_ascii_lowercase()) {
                Ordering::Equal => continue,
                other => return other,
            }
        }
        a.len().cmp(&b.len())
    } else {
        a.cmp(b)
    }
}

/// Find the next line from data starting at `pos`, delimited by `delim`.
/// Returns (line_slice, next_pos). If no delimiter found, returns remaining data.
#[inline(always)]
fn next_line(data: &[u8], pos: usize, delim: u8) -> (&[u8], usize) {
    let remaining = &data[pos..];
    match memchr::memchr(delim, remaining) {
        Some(offset) => (&data[pos..pos + offset], pos + offset + 1),
        std::option::Option::None => (remaining, data.len()),
    }
}

/// Write prefix + line + delimiter to buf using unsafe raw pointer writes.
/// Caller must ensure buf has sufficient capacity.
#[inline(always)]
unsafe fn write_line(buf: &mut Vec<u8>, prefix: &[u8], line: &[u8], delim: u8) {
    unsafe {
        let start = buf.len();
        let total = prefix.len() + line.len() + 1;
        let dst = buf.as_mut_ptr().add(start);
        if !prefix.is_empty() {
            std::ptr::copy_nonoverlapping(prefix.as_ptr(), dst, prefix.len());
        }
        if !line.is_empty() {
            std::ptr::copy_nonoverlapping(line.as_ptr(), dst.add(prefix.len()), line.len());
        }
        *dst.add(prefix.len() + line.len()) = delim;
        buf.set_len(start + total);
    }
}

/// Ensure buf has at least `needed` bytes of spare capacity.
#[inline(always)]
fn ensure_capacity(buf: &mut Vec<u8>, needed: usize) {
    let avail = buf.capacity() - buf.len();
    if avail < needed {
        buf.reserve(needed + 64 * 1024);
    }
}

/// Fast path for identical inputs: all lines go to column 3.
/// Avoids the merge loop entirely — single memchr scan with direct output.
fn comm_identical(
    data: &[u8],
    config: &CommConfig,
    delim: u8,
    sep: &[u8],
    out: &mut impl Write,
) -> io::Result<CommResult> {
    let show3 = !config.suppress_col3;

    // Count lines for the result
    let stripped = if !data.is_empty() && data.last() == Some(&delim) {
        &data[..data.len() - 1]
    } else {
        data
    };
    let line_count = if stripped.is_empty() {
        0
    } else {
        memchr::memchr_iter(delim, stripped).count() + 1
    };

    if show3 {
        // Build column 3 prefix
        let mut prefix = Vec::new();
        if !config.suppress_col1 {
            prefix.extend_from_slice(sep);
        }
        if !config.suppress_col2 {
            prefix.extend_from_slice(sep);
        }

        // Stream output in 256KB chunks
        let mut buf: Vec<u8> = Vec::with_capacity(256 * 1024);
        let mut pos = 0;
        for nl_pos in memchr::memchr_iter(delim, stripped) {
            let line = &stripped[pos..nl_pos];
            let needed = prefix.len() + line.len() + 1;
            if buf.len() + needed > 192 * 1024 {
                out.write_all(&buf)?;
                buf.clear();
            }
            if buf.capacity() - buf.len() < needed {
                buf.reserve(needed + 64 * 1024);
            }
            unsafe {
                write_line(&mut buf, &prefix, line, delim);
            }
            pos = nl_pos + 1;
        }
        // Handle last line without trailing delimiter
        if pos < stripped.len() {
            let line = &stripped[pos..];
            let needed = prefix.len() + line.len() + 1;
            if buf.capacity() - buf.len() < needed {
                buf.reserve(needed + 1024);
            }
            unsafe {
                write_line(&mut buf, &prefix, line, delim);
            }
        }
        if !buf.is_empty() {
            out.write_all(&buf)?;
        }
    }

    Ok(CommResult {
        count1: 0,
        count2: 0,
        count3: line_count,
        had_order_error: false,
    })
}

/// Run the comm merge algorithm on two sorted inputs.
pub fn comm(
    data1: &[u8],
    data2: &[u8],
    config: &CommConfig,
    tool_name: &str,
    out: &mut impl Write,
) -> io::Result<CommResult> {
    let delim = if config.zero_terminated { b'\0' } else { b'\n' };
    let sep = config.output_delimiter.as_deref().unwrap_or(b"\t");

    // Fast path: identical inputs → all lines are common (column 3).
    // Avoids per-line comparison entirely. Uses single memchr scan.
    // Safe for all order_check modes: when all comparisons are Equal,
    // the merge loop never enters Less/Greater branches where order is checked.
    if data1 == data2 && !config.case_insensitive && !config.total {
        return comm_identical(data1, config, delim, sep, out);
    }

    // Build column prefixes.
    let prefix1: &[u8] = &[];
    let prefix2_owned: Vec<u8> = if !config.suppress_col1 {
        sep.to_vec()
    } else {
        Vec::new()
    };
    let mut prefix3_owned: Vec<u8> = Vec::new();
    if !config.suppress_col1 {
        prefix3_owned.extend_from_slice(sep);
    }
    if !config.suppress_col2 {
        prefix3_owned.extend_from_slice(sep);
    }

    let show1 = !config.suppress_col1;
    let show2 = !config.suppress_col2;
    let show3 = !config.suppress_col3;
    let ci = config.case_insensitive;
    let check_order = config.order_check != OrderCheck::None;
    let strict = config.order_check == OrderCheck::Strict;

    // Use a 256KB output buffer to minimize page faults on first fill.
    // 256KB = 64 pages — faulted once, then stays warm in L2/TLB for reuse.
    // Flushed ~40x for 10MB output vs 2x for 4MB, but each flush is fast
    // (~2µs) and we save ~1000 page faults * ~4µs = ~4ms.
    let buf_cap = 256 * 1024;
    let mut buf: Vec<u8> = Vec::with_capacity(buf_cap);
    let flush_threshold = 192 * 1024;

    let mut count1 = 0usize;
    let mut count2 = 0usize;
    let mut count3 = 0usize;
    let mut had_order_error = false;
    let mut warned1 = false;
    let mut warned2 = false;

    // Streaming merge: track position and previous line for each file
    let mut pos1 = 0usize;
    let mut pos2 = 0usize;

    // Strip trailing delimiter to avoid empty final line
    let len1 = if !data1.is_empty() && data1.last() == Some(&delim) {
        data1.len() - 1
    } else {
        data1.len()
    };
    let len2 = if !data2.is_empty() && data2.last() == Some(&delim) {
        data2.len() - 1
    } else {
        data2.len()
    };

    // Previous line tracking for order checking
    let mut prev1: &[u8] = &[];
    let mut has_prev1 = false;
    let mut prev2: &[u8] = &[];
    let mut has_prev2 = false;

    // Main merge loop: both files have remaining lines
    while pos1 < len1 && pos2 < len2 {
        let (line1, next1) = next_line(&data1[..len1], pos1, delim);
        let (line2, next2) = next_line(&data2[..len2], pos2, delim);

        match compare_lines(line1, line2, ci) {
            Ordering::Less => {
                // Check file1 order
                if check_order
                    && !warned1
                    && has_prev1
                    && compare_lines(line1, prev1, ci) == Ordering::Less
                {
                    had_order_error = true;
                    warned1 = true;
                    eprintln!("{}: file {} is not in sorted order", tool_name, 1);
                    if strict {
                        out.write_all(&buf)?;
                        return Ok(CommResult {
                            count1,
                            count2,
                            count3,
                            had_order_error,
                        });
                    }
                }
                if show1 {
                    ensure_capacity(&mut buf, prefix1.len() + line1.len() + 1);
                    unsafe {
                        write_line(&mut buf, prefix1, line1, delim);
                    }
                }
                count1 += 1;
                prev1 = line1;
                has_prev1 = true;
                pos1 = next1;
            }
            Ordering::Greater => {
                // Check file2 order
                if check_order
                    && !warned2
                    && has_prev2
                    && compare_lines(line2, prev2, ci) == Ordering::Less
                {
                    had_order_error = true;
                    warned2 = true;
                    eprintln!("{}: file {} is not in sorted order", tool_name, 2);
                    if strict {
                        out.write_all(&buf)?;
                        return Ok(CommResult {
                            count1,
                            count2,
                            count3,
                            had_order_error,
                        });
                    }
                }
                if show2 {
                    ensure_capacity(&mut buf, prefix2_owned.len() + line2.len() + 1);
                    unsafe {
                        write_line(&mut buf, &prefix2_owned, line2, delim);
                    }
                }
                count2 += 1;
                prev2 = line2;
                has_prev2 = true;
                pos2 = next2;
            }
            Ordering::Equal => {
                if show3 {
                    ensure_capacity(&mut buf, prefix3_owned.len() + line1.len() + 1);
                    unsafe {
                        write_line(&mut buf, &prefix3_owned, line1, delim);
                    }
                }
                count3 += 1;
                prev1 = line1;
                has_prev1 = true;
                prev2 = line2;
                has_prev2 = true;
                pos1 = next1;
                pos2 = next2;
            }
        }

        if buf.len() >= flush_threshold {
            out.write_all(&buf)?;
            buf.clear();
        }
    }

    // Drain remaining from file 1
    // Fast path: if showing col1 and order check is done (or disabled), bulk copy
    if pos1 < len1 && show1 && (!check_order || warned1) && prefix1.is_empty() {
        // Bulk copy remainder — no per-line processing needed
        let remaining = &data1[pos1..len1];
        let line_count = memchr::memchr_iter(delim, remaining).count();
        let has_trailing = !remaining.is_empty() && remaining.last() != Some(&delim);
        count1 += line_count + if has_trailing { 1 } else { 0 };

        // Flush current buffer, then write remainder directly
        if !buf.is_empty() {
            out.write_all(&buf)?;
            buf.clear();
        }
        out.write_all(remaining)?;
        if has_trailing {
            out.write_all(&[delim])?;
        }
        pos1 = len1;
    }
    while pos1 < len1 {
        let (line1, next1) = next_line(&data1[..len1], pos1, delim);
        if check_order && !warned1 && has_prev1 && compare_lines(line1, prev1, ci) == Ordering::Less
        {
            had_order_error = true;
            warned1 = true;
            eprintln!("{}: file 1 is not in sorted order", tool_name);
            if strict {
                out.write_all(&buf)?;
                return Ok(CommResult {
                    count1,
                    count2,
                    count3,
                    had_order_error,
                });
            }
        }
        if show1 {
            ensure_capacity(&mut buf, line1.len() + 1);
            unsafe {
                write_line(&mut buf, prefix1, line1, delim);
            }
        }
        count1 += 1;
        prev1 = line1;
        has_prev1 = true;
        pos1 = next1;
        if buf.len() >= flush_threshold {
            out.write_all(&buf)?;
            buf.clear();
        }
    }

    // Drain remaining from file 2
    // Fast path: bulk copy when order check is done and we have lines to drain
    if pos2 < len2
        && show2
        && (!check_order || warned2)
        && (config.suppress_col1 || prefix2_owned.is_empty())
    {
        let remaining = &data2[pos2..len2];
        // Only bulk if no prefix needed (single column output) — otherwise per-line
        if prefix2_owned.is_empty() {
            let line_count = memchr::memchr_iter(delim, remaining).count();
            let has_trailing = !remaining.is_empty() && remaining.last() != Some(&delim);
            count2 += line_count + if has_trailing { 1 } else { 0 };
            if !buf.is_empty() {
                out.write_all(&buf)?;
                buf.clear();
            }
            out.write_all(remaining)?;
            if has_trailing {
                out.write_all(&[delim])?;
            }
            pos2 = len2;
        }
    }
    while pos2 < len2 {
        let (line2, next2) = next_line(&data2[..len2], pos2, delim);
        if check_order && !warned2 && has_prev2 && compare_lines(line2, prev2, ci) == Ordering::Less
        {
            had_order_error = true;
            warned2 = true;
            eprintln!("{}: file 2 is not in sorted order", tool_name);
            if strict {
                out.write_all(&buf)?;
                return Ok(CommResult {
                    count1,
                    count2,
                    count3,
                    had_order_error,
                });
            }
        }
        if show2 {
            ensure_capacity(&mut buf, prefix2_owned.len() + line2.len() + 1);
            unsafe {
                write_line(&mut buf, &prefix2_owned, line2, delim);
            }
        }
        count2 += 1;
        prev2 = line2;
        has_prev2 = true;
        pos2 = next2;
        if buf.len() >= flush_threshold {
            out.write_all(&buf)?;
            buf.clear();
        }
    }

    // Total summary line
    if config.total {
        let mut itoa_buf = itoa::Buffer::new();
        buf.extend_from_slice(itoa_buf.format(count1).as_bytes());
        buf.extend_from_slice(sep);
        buf.extend_from_slice(itoa_buf.format(count2).as_bytes());
        buf.extend_from_slice(sep);
        buf.extend_from_slice(itoa_buf.format(count3).as_bytes());
        buf.extend_from_slice(sep);
        buf.extend_from_slice(b"total");
        buf.push(delim);
    }

    if had_order_error && config.order_check == OrderCheck::Default {
        eprintln!("{}: input is not in sorted order", tool_name);
    }

    out.write_all(&buf)?;
    Ok(CommResult {
        count1,
        count2,
        count3,
        had_order_error,
    })
}
