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
// Word counting tests (branchless)
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
fn test_count_words_binary_data() {
    // NUL bytes are not whitespace
    assert_eq!(count_words(b"\x00hello\x00world"), 1); // NUL is not ws, so all one "word"
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
// Character counting tests
// ──────────────────────────────────────────────────

#[test]
fn test_count_chars_ascii() {
    assert_eq!(count_chars(b"hello"), 5);
}

#[test]
fn test_count_chars_utf8_2byte() {
    // \u{00E9} = "e with acute" = 0xC3 0xA9 (2 bytes, 1 char)
    assert_eq!(count_chars("caf\u{00e9}".as_bytes()), 4);
}

#[test]
fn test_count_chars_utf8_3byte() {
    // \u{4e16} = CJK character = 3 bytes, 1 char
    assert_eq!(count_chars("\u{4e16}".as_bytes()), 1);
}

#[test]
fn test_count_chars_utf8_4byte() {
    // \u{1F600} = emoji = 4 bytes, 1 char
    assert_eq!(count_chars("\u{1F600}".as_bytes()), 1);
}

#[test]
fn test_count_chars_empty() {
    assert_eq!(count_chars(b""), 0);
}

#[test]
fn test_count_chars_mixed_utf8() {
    // "héllo" = h(1) + é(2) + l(1) + l(1) + o(1) = 6 bytes, 5 chars
    assert_eq!(count_chars("h\u{00e9}llo".as_bytes()), 5);
}

#[test]
fn test_count_chars_non_continuation_bytes() {
    // Bytes that are NOT continuation bytes (not in 0x80..0xBF) count as char starts
    // 0x00, 0x01, 0xFF, 0xFE are all non-continuation
    let data = b"\x00\x01\xff\xfe";
    assert_eq!(count_chars(data), 4);
}

#[test]
fn test_count_chars_pure_continuation_bytes() {
    // Bare continuation bytes (0x80..0xBF) are not counted
    let data = b"\x80\x81\xBF";
    assert_eq!(count_chars(data), 0);
}

// ──────────────────────────────────────────────────
// Max line length tests
// ──────────────────────────────────────────────────

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
    // "a\t" = position 0: 'a' (len=1), position 1: tab -> advances to 8
    assert_eq!(max_line_length(b"a\t\n"), 8);
}

#[test]
fn test_max_line_length_tab_at_boundary() {
    // 8 chars then tab -> advances from 8 to 16
    assert_eq!(max_line_length(b"12345678\t\n"), 16);
}

#[test]
fn test_max_line_length_vertical_tab_zero_width() {
    // \v (0x0B) should have zero display width
    assert_eq!(max_line_length(b"abc\x0Bdef\n"), 6);
}

#[test]
fn test_max_line_length_cr_zero_width() {
    // \r should have zero display width
    assert_eq!(max_line_length(b"abc\rdef\n"), 6);
}

#[test]
fn test_max_line_length_only_vt() {
    // A line of only vertical tabs has width 0
    assert_eq!(max_line_length(b"\x0B\x0B\x0B\n"), 0);
}

#[test]
fn test_max_line_length_only_cr() {
    // A line of only CRs has width 0
    assert_eq!(max_line_length(b"\r\r\r\n"), 0);
}

#[test]
fn test_max_line_length_mixed_control_chars() {
    // "abc" (3) + \v (0) + "de" (2) + \r (0) + "f" (1) = 6
    assert_eq!(max_line_length(b"abc\x0Bde\rf\n"), 6);
}

#[test]
fn test_max_line_length_tab_after_vt() {
    // "ab" (2) + \v (0) + \t (advances from 2 to 8) = 8
    assert_eq!(max_line_length(b"ab\x0B\t\n"), 8);
}

#[test]
fn test_max_line_length_empty_lines() {
    // Empty lines have width 0, max should be from the non-empty line
    assert_eq!(max_line_length(b"\nhello\n\n"), 5);
}

// ──────────────────────────────────────────────────
// count_all tests
// ──────────────────────────────────────────────────

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
    assert_eq!(counts.words, 2); // "\x00\x01\x02" then "\xff\xfe"
    // All bytes are non-continuation (none are 0x80..0xBF)
    assert_eq!(counts.chars, 7);
}

#[test]
fn test_count_all_matches_individual_functions() {
    let test_data: &[&[u8]] = &[
        b"hello world\n",
        b"",
        b"one two\nthree\nfour five six\n",
        b"\x00\x01\x02\n\xff\xfe\n",
        b"tab\there\n",
        b"  spaces  everywhere  \n",
        b"\n\n\n",
        b"no newline at end",
        b"a\x0Bb\x0Cc\rd\n",
    ];

    for data in test_data {
        let all = count_all(data);
        assert_eq!(
            all.lines,
            count_lines(data),
            "lines mismatch for {:?}",
            data
        );
        assert_eq!(
            all.words,
            count_words(data),
            "words mismatch for {:?}",
            data
        );
        assert_eq!(
            all.bytes,
            count_bytes(data),
            "bytes mismatch for {:?}",
            data
        );
        assert_eq!(
            all.chars,
            count_chars(data),
            "chars mismatch for {:?}",
            data
        );
        assert_eq!(
            all.max_line_length,
            max_line_length(data),
            "max_line_length mismatch for {:?}",
            data
        );
    }
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
    // GNU wc defines a word as a maximal sequence of non-isspace() bytes.
    // isspace() in C locale: space, tab, newline, CR, form feed, vertical tab.
    // NUL bytes are NOT whitespace.
    assert_eq!(count_words(b"\x00"), 1); // NUL is a word
    assert_eq!(count_words(b"\x01"), 1); // SOH is a word
    assert_eq!(count_words(b"\x7f"), 1); // DEL is a word
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
    assert_eq!(count_chars(data), 10);
    assert_eq!(count_bytes(data), 11); // é is 2 bytes
}

#[test]
fn test_max_line_length_with_utf8() {
    // In C locale, max_line_length counts bytes per line (not display width).
    // "café\n" → byte length: 5 (c=1, a=1, f=1, é=2)
    let data = "caf\u{00e9}\n".as_bytes();
    // Each byte >= 0x80 still has width 1 in our implementation
    // 0xC3 → width 1, 0xA9 → width 1, so total = 5
    assert_eq!(max_line_length(data), 5);
}

#[test]
fn test_single_newline_counts() {
    let data = b"\n";
    assert_eq!(count_lines(data), 1);
    assert_eq!(count_words(data), 0);
    assert_eq!(count_bytes(data), 1);
    assert_eq!(count_chars(data), 1);
    assert_eq!(max_line_length(data), 0);
}
