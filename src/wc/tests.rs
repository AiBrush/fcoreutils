use super::*;

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
fn test_count_chars_ascii() {
    assert_eq!(count_chars(b"hello"), 5);
}

#[test]
fn test_count_chars_utf8_2byte() {
    // "cafe\u{0301}" = "caf" + e + combining accent (2 bytes for accent)
    // But let's use a simpler example: \u{00E9} = "e with acute" = 0xC3 0xA9
    assert_eq!(count_chars("caf\u{00e9}".as_bytes()), 4);
}

#[test]
fn test_count_chars_utf8_3byte() {
    // \u{4e16} = CJK character = 3 bytes
    assert_eq!(count_chars("\u{4e16}".as_bytes()), 1);
}

#[test]
fn test_count_chars_utf8_4byte() {
    // \u{1F600} = emoji = 4 bytes
    assert_eq!(count_chars("\u{1F600}".as_bytes()), 1);
}

#[test]
fn test_count_chars_empty() {
    assert_eq!(count_chars(b""), 0);
}

#[test]
fn test_max_line_length_empty() {
    assert_eq!(max_line_length(b""), 0);
}

#[test]
fn test_max_line_length_single_line() {
    assert_eq!(max_line_length(b"hello\n"), 5);
}

#[test]
fn test_max_line_length_no_newline() {
    assert_eq!(max_line_length(b"hello"), 5);
}

#[test]
fn test_max_line_length_multiple_lines() {
    assert_eq!(max_line_length(b"hi\nhello\nbye\n"), 5);
}

#[test]
fn test_max_line_length_with_tab() {
    // Tab advances to next multiple of 8
    // "a\t" = position 0: 'a' (len=1), position 1: tab -> advances to 8
    assert_eq!(max_line_length(b"a\t\n"), 8);
}

#[test]
fn test_max_line_length_tab_at_boundary() {
    // 8 chars then tab -> advances from 8 to 16
    assert_eq!(max_line_length(b"12345678\t\n"), 16);
}

#[test]
fn test_count_all_simple() {
    let data = b"hello world\n";
    let counts = count_all(data);
    assert_eq!(counts.lines, 1);
    assert_eq!(counts.words, 2);
    assert_eq!(counts.bytes, 12);
    assert_eq!(counts.chars, 12);
    assert_eq!(counts.max_line_length, 11);
}

#[test]
fn test_count_all_empty() {
    let counts = count_all(b"");
    assert_eq!(counts.lines, 0);
    assert_eq!(counts.words, 0);
    assert_eq!(counts.bytes, 0);
    assert_eq!(counts.chars, 0);
    assert_eq!(counts.max_line_length, 0);
}

#[test]
fn test_count_all_multiline() {
    let data = b"one two\nthree\nfour five six\n";
    let counts = count_all(data);
    assert_eq!(counts.lines, 3);
    assert_eq!(counts.words, 6);
    assert_eq!(counts.bytes, 28);
    assert_eq!(counts.max_line_length, 13); // "four five six" = 13
}

#[test]
fn test_count_all_binary_data() {
    let data = b"\x00\x01\x02\n\xff\xfe\n";
    let counts = count_all(data);
    assert_eq!(counts.lines, 2);
    assert_eq!(counts.bytes, 7);
    // \x00, \x01, \x02 are words (non-whitespace, non-continuation bytes)
    assert_eq!(counts.words, 2); // "\x00\x01\x02" then "\xff\xfe"
    // All 7 bytes are char starts (none are continuation bytes 0x80..0xBF)
    assert_eq!(counts.chars, 7);
}
