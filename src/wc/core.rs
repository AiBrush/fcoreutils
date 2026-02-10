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

/// Count newlines using SIMD-accelerated memchr.
/// GNU wc counts newline bytes, not logical lines.
#[inline]
pub fn count_lines(data: &[u8]) -> u64 {
    memchr_iter(b'\n', data).count() as u64
}

/// Count bytes. Trivial but included for API consistency.
#[inline]
pub fn count_bytes(data: &[u8]) -> u64 {
    data.len() as u64
}

/// Check if a byte is whitespace per GNU wc's definition.
/// Whitespace: space (0x20), tab (0x09), newline (0x0A), carriage return (0x0D),
/// form feed (0x0C), vertical tab (0x0B).
#[inline]
fn is_word_separator(b: u8) -> bool {
    matches!(b, b' ' | b'\t' | b'\n' | b'\r' | 0x0C | 0x0B)
}

/// Count words: a word is a maximal sequence of non-whitespace bytes.
/// Matches GNU wc behavior using `isspace()` from C locale.
pub fn count_words(data: &[u8]) -> u64 {
    let mut words: u64 = 0;
    let mut in_word = false;

    for &b in data {
        if is_word_separator(b) {
            in_word = false;
        } else if !in_word {
            in_word = true;
            words += 1;
        }
    }
    words
}

/// Count UTF-8 characters. Invalid sequences count each byte as one character,
/// matching GNU wc -m behavior in C locale.
pub fn count_chars(data: &[u8]) -> u64 {
    let mut chars: u64 = 0;
    let mut i = 0;
    while i < data.len() {
        let b = data[i];
        if b < 0x80 {
            // ASCII
            chars += 1;
            i += 1;
        } else if b < 0xC0 {
            // Invalid continuation byte - count as one char
            chars += 1;
            i += 1;
        } else if b < 0xE0 {
            // 2-byte sequence
            chars += 1;
            i += 2;
        } else if b < 0xF0 {
            // 3-byte sequence
            chars += 1;
            i += 3;
        } else {
            // 4-byte sequence
            chars += 1;
            i += 4;
        }
    }
    chars
}

/// Compute max display width of any line.
/// A "line" is delimited by newline. Width is byte count for C locale.
/// GNU wc -L in C/POSIX locale counts bytes per line (not display width).
pub fn max_line_length(data: &[u8]) -> u64 {
    let mut max_len: u64 = 0;
    let mut current_len: u64 = 0;

    for &b in data {
        if b == b'\n' {
            if current_len > max_len {
                max_len = current_len;
            }
            current_len = 0;
        } else if b == b'\r' {
            // CR doesn't contribute to line length
        } else if b == b'\t' {
            // Tab advances to next multiple of 8
            current_len = (current_len + 8) & !7;
        } else {
            current_len += 1;
        }
    }

    // Handle last line (no trailing newline)
    if current_len > max_len {
        max_len = current_len;
    }

    max_len
}

/// Count everything in a single pass for maximum efficiency.
/// When multiple flags are requested, this avoids re-scanning.
///
/// Iterates byte-by-byte for line/word/max-line-length counting, and uses
/// UTF-8 leading byte detection for character counting (a byte is a char
/// start if it's not a continuation byte 0x80..0xBF).
pub fn count_all(data: &[u8]) -> WcCounts {
    let mut lines: u64 = 0;
    let mut words: u64 = 0;
    let mut chars: u64 = 0;
    let mut max_len: u64 = 0;
    let mut current_line_len: u64 = 0;
    let mut in_word = false;

    for &b in data {
        // Line length / max line length tracking
        if b == b'\n' {
            lines += 1;
            if current_line_len > max_len {
                max_len = current_line_len;
            }
            current_line_len = 0;
        } else if b == b'\r' {
            // CR: don't add to line length
        } else if b == b'\t' {
            current_line_len = (current_line_len + 8) & !7;
        } else {
            current_line_len += 1;
        }

        // Word counting
        if is_word_separator(b) {
            in_word = false;
        } else if !in_word {
            in_word = true;
            words += 1;
        }

        // Character counting: count byte if it's not a UTF-8 continuation byte.
        // Continuation bytes are 0x80..0xBF (10xxxxxx). Everything else starts
        // a new character (ASCII, or a multi-byte leading byte, or invalid).
        if (b & 0xC0) != 0x80 {
            chars += 1;
        }
    }

    // Handle last line without trailing newline
    if current_line_len > max_len {
        max_len = current_line_len;
    }

    WcCounts {
        lines,
        words,
        bytes: data.len() as u64,
        chars,
        max_line_length: max_len,
    }
}
