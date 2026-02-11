use memchr::memchr_iter;

/// Results from counting a byte slice.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct WcCounts {
    pub lines: u64,
    pub words: u64,
    pub bytes: u64,
    pub chars: u64,
    pub max_line_length: u64,
}

/// Whitespace lookup table for branchless word boundary detection.
/// GNU wc uses C locale `isspace()`: space, tab, newline, CR, form feed, vertical tab.
const fn make_ws_table() -> [u8; 256] {
    let mut t = [0u8; 256];
    t[0x09] = 1; // \t  horizontal tab
    t[0x0A] = 1; // \n  newline
    t[0x0B] = 1; // \v  vertical tab
    t[0x0C] = 1; // \f  form feed
    t[0x0D] = 1; // \r  carriage return
    t[0x20] = 1; //     space
    t
}

/// Precomputed whitespace lookup: `WS_TABLE[byte] == 1` if whitespace, `0` otherwise.
const WS_TABLE: [u8; 256] = make_ws_table();

/// Count newlines using SIMD-accelerated memchr.
/// GNU wc counts newline bytes (`\n`), not logical lines.
#[inline]
pub fn count_lines(data: &[u8]) -> u64 {
    memchr_iter(b'\n', data).count() as u64
}

/// Count bytes. Trivial but included for API consistency.
#[inline]
pub fn count_bytes(data: &[u8]) -> u64 {
    data.len() as u64
}

/// Count words using a branchless lookup table.
/// A word is a maximal run of non-whitespace bytes (GNU wc definition).
///
/// Uses a branchless state machine: a word starts at each transition
/// from whitespace to non-whitespace. The lookup table and XOR/AND
/// avoid all branches in the hot loop, eliminating branch misprediction.
pub fn count_words(data: &[u8]) -> u64 {
    let mut words = 0u64;
    let mut prev_ws = 1u8; // treat start-of-data as whitespace

    for &b in data {
        let curr_ws = WS_TABLE[b as usize];
        // Branchless: add 1 when prev was whitespace AND current is NOT whitespace.
        // curr_ws ^ 1 flips 0↔1, so it's 1 when current is non-whitespace.
        // prev_ws & (curr_ws ^ 1) is 1 only at word-start transitions.
        words += (prev_ws & (curr_ws ^ 1)) as u64;
        prev_ws = curr_ws;
    }
    words
}

/// Count UTF-8 characters by counting non-continuation bytes.
/// A continuation byte has the bit pattern `10xxxxxx` (0x80..0xBF).
/// Every other byte starts a new character (ASCII, multi-byte leader, or invalid).
///
/// This is correct for valid UTF-8 and matches the common approach used by
/// high-performance text tools (ripgrep, etc.).
pub fn count_chars(data: &[u8]) -> u64 {
    let mut count = 0u64;
    for &b in data {
        count += ((b & 0xC0) != 0x80) as u64;
    }
    count
}

/// Compute maximum display width of any line (C/POSIX locale).
///
/// Lines are delimited by `\n`. Display width rules:
/// - `\n`: terminates the line (not counted in width)
/// - `\t`: advances to the next tab stop (multiple of 8)
/// - `\r`: zero display width (not a line terminator)
/// - `\v` (0x0B): zero display width
/// - All other bytes: width 1
pub fn max_line_length(data: &[u8]) -> u64 {
    let mut max_len: u64 = 0;
    let mut current_len: u64 = 0;

    for &b in data {
        if b == b'\n' {
            if current_len > max_len {
                max_len = current_len;
            }
            current_len = 0;
        } else if b == b'\t' {
            // Tab: advance to next multiple of 8
            current_len = (current_len + 8) & !7;
        } else if b == b'\r' || b == 0x0B {
            // CR and VT: zero display width
        } else {
            current_len += 1;
        }
    }

    // Handle last line (may not end with \n)
    if current_len > max_len {
        max_len = current_len;
    }

    max_len
}

/// Count all metrics using optimized individual passes.
///
/// Each metric uses its own optimized algorithm:
/// - Lines: SIMD-accelerated memchr
/// - Words: branchless lookup table
/// - Chars: non-continuation byte counting
/// - Max line length: single-pass with display width tracking
///
/// Multi-pass is faster than single-pass because each pass has a tight,
/// specialized loop. After the first pass, data is hot in L2/L3 cache,
/// making subsequent passes nearly free for memory bandwidth.
pub fn count_all(data: &[u8]) -> WcCounts {
    WcCounts {
        lines: count_lines(data),
        words: count_words(data),
        bytes: data.len() as u64,
        chars: count_chars(data),
        max_line_length: max_line_length(data),
    }
}
