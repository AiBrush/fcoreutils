use super::*;

// ──────────────────────────────────────────────────
// Line counting tests
// ──────────────────────────────────────────────────

#[test]
fn test_count_lines_empty() {
    assert_eq!(count_lines(b""), 0);
}

#[test]
fn test_count_lines_single_newline() {
    assert_eq!(count_lines(b"\n"), 1);
}

#[test]
fn test_count_lines_no_trailing_newline() {
    assert_eq!(count_lines(b"hello"), 0);
}

#[test]
fn test_count_lines_multiple() {
    assert_eq!(count_lines(b"one\ntwo\nthree\n"), 3);
}

#[test]
fn test_count_lines_only_newlines() {
    assert_eq!(count_lines(b"\n\n\n"), 3);
}

#[test]
fn test_count_lines_crlf() {
    // \r is not a line terminator, only \n counts
    assert_eq!(count_lines(b"hello\r\nworld\r\n"), 2);
}

#[test]
fn test_count_lines_cr_only() {
    // \r alone does not count as a line
    assert_eq!(count_lines(b"hello\rworld\r"), 0);
}

// ──────────────────────────────────────────────────
// Byte counting tests
// ──────────────────────────────────────────────────

#[test]
fn test_count_bytes_empty() {
    assert_eq!(count_bytes(b""), 0);
}

#[test]
fn test_count_bytes_ascii() {
    assert_eq!(count_bytes(b"hello"), 5);
}

#[test]
fn test_count_bytes_with_newline() {
    assert_eq!(count_bytes(b"hello\n"), 6);
}

#[test]
fn test_count_bytes_utf8() {
    // "café" in UTF-8 is 5 bytes
    assert_eq!(count_bytes("caf\u{00e9}".as_bytes()), 5);
}

// ──────────────────────────────────────────────────
// Word counting tests (2-state logic: space or word content)
// ──────────────────────────────────────────────────

#[test]
fn test_count_words_empty() {
    assert_eq!(count_words(b""), 0);
}

#[test]
fn test_count_words_single() {
    assert_eq!(count_words(b"hello"), 1);
}

#[test]
fn test_count_words_multiple() {
    assert_eq!(count_words(b"hello world"), 2);
}

#[test]
fn test_count_words_leading_trailing_whitespace() {
    assert_eq!(count_words(b"  hello  world  "), 2);
}

#[test]
fn test_count_words_tabs_and_newlines() {
    assert_eq!(count_words(b"one\ttwo\nthree"), 3);
}

#[test]
fn test_count_words_all_whitespace() {
    assert_eq!(count_words(b" \t\n\r"), 0);
}

#[test]
fn test_count_words_form_feed_vertical_tab() {
    // Form feed (0x0C) and vertical tab (0x0B) are whitespace per GNU wc
    assert_eq!(count_words(b"a\x0Bb\x0Cc"), 3);
}

#[test]
fn test_count_words_single_char() {
    assert_eq!(count_words(b"a"), 1);
}

#[test]
fn test_count_words_only_newlines() {
    assert_eq!(count_words(b"\n\n\n"), 0);
}

#[test]
fn test_count_words_mixed_whitespace() {
    assert_eq!(count_words(b" \t\n\r\x0B\x0C"), 0);
}

#[test]
fn test_count_words_crlf_separated() {
    assert_eq!(count_words(b"hello\r\nworld"), 2);
}

#[test]
fn test_count_words_binary_data_nul_word_content() {
    // GNU wc 9.7: NUL is word content (not a word-break).
    // "\x00hello\x00world" is one continuous word.
    assert_eq!(count_words(b"\x00hello\x00world"), 1);
}

#[test]
fn test_count_words_nul_between_spaces() {
    // GNU wc 9.4: NUL is transparent (non-printable control).
    // "hello" = word 1, " " breaks, "\x00" transparent, " " breaks, "world" = word 2
    assert_eq!(count_words(b"hello \x00 world"), 2);
}

#[test]
fn test_count_words_consecutive_non_ws() {
    assert_eq!(count_words(b"abcdef"), 1);
}

#[test]
fn test_count_words_all_whitespace_types() {
    // Each whitespace type separates words
    assert_eq!(count_words(b"a b\tc\nd\re\x0Bf\x0Cg"), 7);
}

// ──────────────────────────────────────────────────
// UTF-8 3-state word counting (matching GNU wc 9.4):
//   - Printable ASCII (0x21-0x7E): word content
//   - Whitespace (0x09-0x0D, 0x20): word break
//   - Control chars (NUL, 0x01-0x08, 0x0E-0x1F, 0x7F): transparent
//   - Encoding errors (invalid UTF-8): transparent (skip 1 byte, no state change)
//   - Valid multi-byte printable chars: word content
// ──────────────────────────────────────────────────

#[test]
fn test_utf8_nul_is_transparent() {
    // GNU wc 9.4: NUL is transparent (non-printable control)
    assert_eq!(count_words(b"\x00"), 0);
    assert_eq!(count_words(b"\x00\x00"), 0);
}

#[test]
fn test_utf8_control_chars_are_transparent() {
    // GNU wc 9.4: ASCII control chars are transparent (not word-break, not word content)
    assert_eq!(count_words(b"\x01"), 0);
    assert_eq!(count_words(b"\x08"), 0);
    assert_eq!(count_words(b"\x0E"), 0);
    assert_eq!(count_words(b"\x1F"), 0);
    assert_eq!(count_words(b"\x7f"), 0);
}

#[test]
fn test_utf8_control_chars_dont_break_words() {
    // GNU wc 9.4: control chars are transparent — don't break words
    assert_eq!(count_words(b"hello\x01world"), 1);
    assert_eq!(count_words(b"hello\x7fworld"), 1);
    assert_eq!(count_words(b"hello\x00world"), 1);
}

#[test]
fn test_utf8_nonprintable_is_transparent() {
    // GNU wc 9.4: non-printable control bytes are transparent (0 words)
    assert_eq!(count_words(b"\x00\x01\x02"), 0);
    // NUL at start is transparent, "hello" starts word
    assert_eq!(count_words(b"\x00hello"), 1);
}

#[test]
fn test_utf8_space_still_breaks() {
    // Space breaks words; NUL (transparent) doesn't
    assert_eq!(count_words(b"hello\x00 world"), 2);
    assert_eq!(count_words(b"hello \x00world"), 2);
}

#[test]
fn test_c_locale_high_bytes_are_transparent() {
    // GNU wc 9.4 C locale: high bytes are transparent (not printable, not space)
    // They don't start words, don't continue words, don't break words
    assert_eq!(count_words_locale(b"\x80", false), 0);
    assert_eq!(count_words_locale(b"\xFF", false), 0);
    // High bytes between printable ASCII: transparent, doesn't split word
    assert_eq!(count_words_locale(b"hello\x80world", false), 1);
    // High bytes between spaces: transparent, not counted as word
    assert_eq!(count_words_locale(b"hello \x80 world", false), 2);
    // 0xA0 is also transparent (not printable in C locale)
    assert_eq!(count_words_locale(b"hello\xa0world", false), 1);
}

#[test]
fn test_c_locale_word_counting() {
    // GNU wc 9.4 C locale: 3-state model
    // Word content: printable ASCII (0x21-0x7E)
    // Word break: whitespace (0x09-0x0D, 0x20)
    // Transparent: everything else (NUL, controls, DEL, high bytes)
    assert_eq!(count_words_locale(b"hello", false), 1);
    assert_eq!(count_words_locale(b"hello world", false), 2);
    // Control chars are TRANSPARENT in C locale (GNU 9.4) — not words
    assert_eq!(count_words_locale(b"\x01", false), 0);
    assert_eq!(count_words_locale(b"\x7f", false), 0);
    // DEL (0x7F) is transparent, doesn't break printable word
    assert_eq!(count_words_locale(b"hello\x7fworld", false), 1);
    // NUL is transparent, doesn't break printable word
    assert_eq!(count_words_locale(b"hello\x00world", false), 1);
    // All non-printable bytes: 0 words (all transparent)
    assert_eq!(
        count_words_locale(b"\x00\x01\x02\x80\x81\xfe\xff", false),
        0
    );
}

#[test]
fn test_first_is_word_c_scans_past_transparent() {
    // first_is_word_c should scan past transparent bytes to find the first meaningful byte
    assert!(first_is_word_c(b"hello")); // starts with printable
    assert!(!first_is_word_c(b" hello")); // starts with break
    assert!(!first_is_word_c(b"")); // empty
    assert!(!first_is_word_c(b"\x00\x80\xff")); // all transparent
    // Transparent bytes before word content → true
    assert!(first_is_word_c(b"\x00\x80hello"));
    assert!(first_is_word_c(b"\xff\xfea"));
    // Transparent bytes before break → false
    assert!(!first_is_word_c(b"\x00\x80 hello"));
    assert!(!first_is_word_c(b"\xff\n"));
}

#[test]
fn test_utf8_c1_controls_word_content() {
    // C1 control characters (U+0080-U+009F) are valid 2-byte UTF-8 sequences.
    // They are non-printable but valid — treated as word content per GNU wc.
    // U+0080 = 0xC2 0x80 (PAD control)
    assert_eq!(count_words(b"\xC2\x80"), 1);
    // C1 control between words: word content, doesn't break
    assert_eq!(count_words(b"hello\xC2\x80world"), 1);
}

#[test]
fn test_3state_utf8_valid_multibyte_is_word() {
    // Valid UTF-8 printable multi-byte chars (>= U+00A0) are word content
    // U+00E9 (é) = 0xC3 0xA9
    assert_eq!(count_words("café".as_bytes()), 1);
    // U+4E16 (世) = 3 bytes
    assert_eq!(count_words("世界".as_bytes()), 1);
}

#[test]
fn test_utf8_invalid_encoding_is_transparent() {
    // Standalone continuation bytes (0x80-0xBF) in UTF-8: transparent (no word started)
    assert_eq!(count_words(b"\x80\x81\x82"), 0);
    // Encoding error between printable text: transparent → stays in word → 1 word
    // (matches GNU mbrtowc which skips 1 byte on error without changing in_word)
    assert_eq!(count_words(b"hello\x80world"), 1);
    // Invalid bytes >= 0xF5: transparent
    assert_eq!(count_words(b"\xF5\xF6\xFF"), 0);
    // null_bytes.bin: all non-printable/invalid bytes → 0 words
    assert_eq!(count_words(b"\x00\x01\x02\x80\x81\xfe\xff"), 0);
}

#[test]
fn test_3state_utf8_unicode_space_breaks() {
    // Unicode NBSP (U+00A0 = 0xC2 0xA0) is a space character
    assert_eq!(count_words("hello\u{00A0}world".as_bytes()), 2);
    // Ideographic space (U+3000 = 0xE3 0x80 0x80)
    assert_eq!(count_words("hello\u{3000}world".as_bytes()), 2);
}

// ──────────────────────────────────────────────────
// Character counting tests (UTF-8 mode)
// ──────────────────────────────────────────────────

#[test]
fn test_count_chars_ascii() {
    assert_eq!(count_chars_utf8(b"hello"), 5);
}

#[test]
fn test_count_chars_utf8_2byte() {
    // \u{00E9} = "e with acute" = 0xC3 0xA9 (2 bytes, 1 char)
    assert_eq!(count_chars_utf8("caf\u{00e9}".as_bytes()), 4);
}

#[test]
fn test_count_chars_utf8_3byte() {
    // \u{4e16} = CJK character = 3 bytes, 1 char
    assert_eq!(count_chars_utf8("\u{4e16}".as_bytes()), 1);
}

#[test]
fn test_count_chars_utf8_4byte() {
    // \u{1F600} = emoji = 4 bytes, 1 char
    assert_eq!(count_chars_utf8("\u{1F600}".as_bytes()), 1);
}

#[test]
fn test_count_chars_empty() {
    assert_eq!(count_chars_utf8(b""), 0);
}

#[test]
fn test_count_chars_mixed_utf8() {
    // "héllo" = h(1) + é(2) + l(1) + l(1) + o(1) = 6 bytes, 5 chars
    assert_eq!(count_chars_utf8("h\u{00e9}llo".as_bytes()), 5);
}

#[test]
fn test_count_chars_non_continuation_bytes() {
    // Bytes that are NOT continuation bytes (not in 0x80..0xBF) count as char starts
    // 0x00, 0x01, 0xFF, 0xFE are all non-continuation
    let data = b"\x00\x01\xff\xfe";
    assert_eq!(count_chars_utf8(data), 4);
}

#[test]
fn test_count_chars_pure_continuation_bytes() {
    // Bare continuation bytes (0x80..0xBF) are not counted
    let data = b"\x80\x81\xBF";
    assert_eq!(count_chars_utf8(data), 0);
}

// ──────────────────────────────────────────────────
// Character counting tests (C locale mode)
// ──────────────────────────────────────────────────

#[test]
fn test_count_chars_c_locale() {
    // In C locale, each byte is one character
    assert_eq!(count_chars_c(b"hello"), 5);
    assert_eq!(count_chars_c("caf\u{00e9}".as_bytes()), 5); // 5 bytes = 5 chars
    assert_eq!(count_chars_c(b""), 0);
}

#[test]
fn test_count_chars_locale_dispatch() {
    let data = "caf\u{00e9}".as_bytes(); // 5 bytes, 4 UTF-8 chars
    assert_eq!(count_chars(data, true), 4); // UTF-8 mode
    assert_eq!(count_chars(data, false), 5); // C locale mode
}

// ──────────────────────────────────────────────────
// Max line length tests (C locale)
// ──────────────────────────────────────────────────

#[test]
fn test_max_line_length_c_empty() {
    assert_eq!(max_line_length_c(b""), 0);
}

#[test]
fn test_max_line_length_c_single_line() {
    assert_eq!(max_line_length_c(b"hello\n"), 5);
}

#[test]
fn test_max_line_length_c_no_newline() {
    assert_eq!(max_line_length_c(b"hello"), 5);
}

#[test]
fn test_max_line_length_c_multiple_lines() {
    assert_eq!(max_line_length_c(b"hi\nhello\nbye\n"), 5);
}

#[test]
fn test_max_line_length_c_with_tab() {
    // "a\t" = position 0: 'a' (len=1), position 1: tab -> advances to 8
    assert_eq!(max_line_length_c(b"a\t\n"), 8);
}

#[test]
fn test_max_line_length_c_tab_at_boundary() {
    // 8 chars then tab -> advances from 8 to 16
    assert_eq!(max_line_length_c(b"12345678\t\n"), 16);
}

#[test]
fn test_max_line_length_c_vertical_tab_zero_width() {
    // \v (0x0B) has zero display width
    assert_eq!(max_line_length_c(b"abc\x0Bdef\n"), 6);
}

#[test]
fn test_max_line_length_c_cr_resets_position() {
    // \r resets cursor position to 0 (carriage return)
    // "abcde\rXY" → max position is 5 (from "abcde"), then \r resets to 0, X=1, Y=2
    assert_eq!(max_line_length_c(b"abcde\rXY\n"), 5);
}

#[test]
fn test_max_line_length_c_form_feed_line_terminator() {
    // \f acts as a line terminator (records max, resets position)
    assert_eq!(max_line_length_c(b"abc\x0Cdef\n"), 3);
}

#[test]
fn test_max_line_length_c_non_printable_zero_width() {
    // Non-printable ASCII control chars (0x00, 0x01, 0x08, 0x7F) have width 0
    assert_eq!(max_line_length_c(b"abc\x01\x02\x7fdef\n"), 6);
}

#[test]
fn test_max_line_length_c_nul_zero_width() {
    // NUL bytes have width 0
    assert_eq!(max_line_length_c(b"abc\x00def\n"), 6);
}

#[test]
fn test_max_line_length_c_backspace_zero_width() {
    // Backspace (0x08) has width 0 (non-printable)
    assert_eq!(max_line_length_c(b"abc\x08de\n"), 5);
}

#[test]
fn test_max_line_length_c_high_bytes_zero_width() {
    // Bytes >= 0x80 have width 0 in C locale
    assert_eq!(max_line_length_c(b"abc\xc3\xa9def\n"), 6);
}

#[test]
fn test_max_line_length_c_empty_lines() {
    // Empty lines have width 0, max should be from the non-empty line
    assert_eq!(max_line_length_c(b"\nhello\n\n"), 5);
}

// ──────────────────────────────────────────────────
// Max line length tests (UTF-8 locale)
// ──────────────────────────────────────────────────

#[test]
fn test_max_line_length_utf8_ascii() {
    assert_eq!(max_line_length_utf8(b"hello\n"), 5);
}

#[test]
fn test_max_line_length_utf8_multibyte() {
    // "café latté\n" — each accented char is 1 display width
    // c(1) a(1) f(1) é(1) ' '(1) l(1) a(1) t(1) t(1) é(1) = 10
    let data = "caf\u{00e9} latt\u{00e9}\n".as_bytes();
    assert_eq!(max_line_length_utf8(data), 10);
}

#[test]
fn test_max_line_length_utf8_cjk_wide() {
    // CJK characters have display width 2
    // "世界\n" = 2 chars × 2 width = 4
    let data = "\u{4e16}\u{754c}\n".as_bytes();
    assert_eq!(max_line_length_utf8(data), 4);
}

#[test]
fn test_max_line_length_utf8_cr_resets() {
    assert_eq!(max_line_length_utf8(b"abcde\rXY\n"), 5);
}

#[test]
fn test_max_line_length_utf8_form_feed() {
    assert_eq!(max_line_length_utf8(b"abc\x0Cdef\n"), 3);
}

#[test]
fn test_max_line_length_utf8_non_printable() {
    assert_eq!(max_line_length_utf8(b"abc\x01\x02\x7fdef\n"), 6);
}

#[test]
fn test_max_line_length_utf8_tab() {
    assert_eq!(max_line_length_utf8(b"a\t\n"), 8);
}

// ──────────────────────────────────────────────────
// count_all tests
// ──────────────────────────────────────────────────

#[test]
fn test_count_all_simple() {
    let data = b"hello world\n";
    let counts = count_all(data, false);
    assert_eq!(counts.lines, 1);
    assert_eq!(counts.words, 2);
    assert_eq!(counts.bytes, 12);
    assert_eq!(counts.chars, 12);
    assert_eq!(counts.max_line_length, 11);
}

#[test]
fn test_count_all_empty() {
    let counts = count_all(b"", false);
    assert_eq!(counts.lines, 0);
    assert_eq!(counts.words, 0);
    assert_eq!(counts.bytes, 0);
    assert_eq!(counts.chars, 0);
    assert_eq!(counts.max_line_length, 0);
}

#[test]
fn test_count_all_multiline() {
    let data = b"one two\nthree\nfour five six\n";
    let counts = count_all(data, false);
    assert_eq!(counts.lines, 3);
    assert_eq!(counts.words, 6);
    assert_eq!(counts.bytes, 28);
    assert_eq!(counts.max_line_length, 13); // "four five six" = 13
}

#[test]
fn test_count_all_binary_data() {
    let data = b"\x00\x01\x02\n\xff\xfe\n";
    let counts = count_all(data, false);
    assert_eq!(counts.lines, 2);
    assert_eq!(counts.bytes, 7);
    // GNU wc 9.4 C locale: \x00, \x01, \x02 are transparent (not printable).
    // \n breaks. \xFF, \xFE are transparent. \n breaks. 0 words.
    assert_eq!(counts.words, 0);
    // C locale: each byte is a char
    assert_eq!(counts.chars, 7);
}

// ──────────────────────────────────────────────────
// Edge cases and GNU compatibility
// ──────────────────────────────────────────────────

#[test]
fn test_gnu_trailing_newline() {
    // GNU wc counts newlines, not logical lines.
    // "hello" has 0 newlines → 0 lines
    assert_eq!(count_lines(b"hello"), 0);
    // "hello\n" has 1 newline → 1 line
    assert_eq!(count_lines(b"hello\n"), 1);
}

#[test]
fn test_gnu_word_definition() {
    // UTF-8 mode (matching GNU wc 9.4):
    // NUL and control chars are transparent (non-printable, non-space)
    assert_eq!(count_words(b"\x00"), 0); // NUL: transparent
    assert_eq!(count_words(b"\x01"), 0); // SOH: transparent
    assert_eq!(count_words(b"\x7f"), 0); // DEL: transparent
    // Printable ASCII is word content
    assert_eq!(count_words(b"!"), 1);
    assert_eq!(count_words(b"hello"), 1);
    // In UTF-8 mode, valid multi-byte sequences (>= U+00A0) are word content
    assert_eq!(count_words("café".as_bytes()), 1);
    // text with embedded NULs: NUL is transparent, text forms one word
    assert_eq!(count_words(b"text\x00with\x00nulls"), 1);
}

#[test]
fn test_c_locale_cjk_word_count() {
    // GNU wc 9.4 C locale: high bytes are transparent, only printable ASCII forms words.
    // "世界" bytes: e4 b8 96 e7 95 8c — all non-printable in C locale. 0 words.
    let data = "世界".as_bytes();
    assert_eq!(count_words_locale(data, false), 0);
    // Mixed: "Hello, 世界!" — "Hello," (word 1), space breaks, "!" (word 2)
    // CJK bytes between space and "!" are transparent
    let mixed = "Hello, 世界!".as_bytes();
    assert_eq!(count_words_locale(mixed, false), 2);
    // Japanese CJK only: all non-printable bytes in C locale → 0 words
    let multi = "こんにちは\nさようなら\n".as_bytes();
    assert_eq!(count_words_locale(multi, false), 0);
    // Full test data: "Hello, 世界!\n你好世界\nこんにちは\n"
    // Line 1: "Hello," (word 1) + space + transparent bytes + "!" (word 2)
    // Line 2: all CJK bytes are transparent → 0 words
    // Line 3: all CJK bytes are transparent → 0 words
    // Total: 2. Matches GNU wc 9.4 on Ubuntu 24.04.
    let full = "Hello, 世界!\n你好世界\nこんにちは\n".as_bytes();
    assert_eq!(count_words_locale(full, false), 2);
}

#[test]
fn test_large_word_count() {
    // Stress test: many words
    let data = b"a b c d e f g h i j k l m n o p q r s t u v w x y z\n";
    assert_eq!(count_words(data), 26);
}

#[test]
fn test_utf8_chars_with_words() {
    // "café latte" = 10 chars (c,a,f,é,space,l,a,t,t,e), 2 words
    let data = "caf\u{00e9} latte".as_bytes();
    assert_eq!(count_words(data), 2);
    assert_eq!(count_chars_utf8(data), 10);
    assert_eq!(count_bytes(data), 11); // é is 2 bytes
}

#[test]
fn test_single_newline_counts() {
    let data = b"\n";
    assert_eq!(count_lines(data), 1);
    assert_eq!(count_words(data), 0);
    assert_eq!(count_bytes(data), 1);
    assert_eq!(count_chars_utf8(data), 1);
    assert_eq!(max_line_length_c(data), 0);
}
