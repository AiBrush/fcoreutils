use super::core::*;

/// Helper: run uniq with default config on input string, return output string.
fn run_uniq(input: &str) -> String {
    let config = UniqConfig::default();
    let mut output = Vec::new();
    process_uniq(input.as_bytes(), &mut output, &config).unwrap();
    String::from_utf8(output).unwrap()
}

/// Helper: run uniq with custom config.
fn run_uniq_cfg(input: &str, config: &UniqConfig) -> String {
    let mut output = Vec::new();
    process_uniq(input.as_bytes(), &mut output, config).unwrap();
    String::from_utf8(output).unwrap()
}

// ========== Default mode ==========

#[test]
fn test_empty_input() {
    assert_eq!(run_uniq(""), "");
}

#[test]
fn test_single_line() {
    assert_eq!(run_uniq("hello\n"), "hello\n");
}

#[test]
fn test_single_line_no_newline() {
    assert_eq!(run_uniq("hello"), "hello\n");
}

#[test]
fn test_unique_lines() {
    assert_eq!(run_uniq("a\nb\nc\n"), "a\nb\nc\n");
}

#[test]
fn test_all_same() {
    assert_eq!(run_uniq("a\na\na\n"), "a\n");
}

#[test]
fn test_adjacent_duplicates() {
    assert_eq!(run_uniq("a\na\nb\nb\nc\n"), "a\nb\nc\n");
}

#[test]
fn test_non_adjacent_not_deduped() {
    assert_eq!(run_uniq("a\nb\na\n"), "a\nb\na\n");
}

// ========== -c (count) mode ==========

#[test]
fn test_count_mode() {
    let config = UniqConfig {
        count: true,
        ..Default::default()
    };
    let result = run_uniq_cfg("a\na\nb\nc\nc\nc\n", &config);
    assert_eq!(result, "      2 a\n      1 b\n      3 c\n");
}

#[test]
fn test_count_single() {
    let config = UniqConfig {
        count: true,
        ..Default::default()
    };
    let result = run_uniq_cfg("hello\n", &config);
    assert_eq!(result, "      1 hello\n");
}

// ========== -d (repeated only) ==========

#[test]
fn test_repeated_only() {
    let config = UniqConfig {
        mode: OutputMode::RepeatedOnly,
        ..Default::default()
    };
    let result = run_uniq_cfg("a\na\nb\nc\nc\n", &config);
    assert_eq!(result, "a\nc\n");
}

#[test]
fn test_repeated_only_no_dupes() {
    let config = UniqConfig {
        mode: OutputMode::RepeatedOnly,
        ..Default::default()
    };
    let result = run_uniq_cfg("a\nb\nc\n", &config);
    assert_eq!(result, "");
}

// ========== -u (unique only) ==========

#[test]
fn test_unique_only() {
    let config = UniqConfig {
        mode: OutputMode::UniqueOnly,
        ..Default::default()
    };
    let result = run_uniq_cfg("a\na\nb\nc\nc\n", &config);
    assert_eq!(result, "b\n");
}

#[test]
fn test_unique_only_all_dupes() {
    let config = UniqConfig {
        mode: OutputMode::UniqueOnly,
        ..Default::default()
    };
    let result = run_uniq_cfg("a\na\nb\nb\n", &config);
    assert_eq!(result, "");
}

// ========== -D (all repeated) ==========

#[test]
fn test_all_repeated_none() {
    let config = UniqConfig {
        mode: OutputMode::AllRepeated(AllRepeatedMethod::None),
        ..Default::default()
    };
    let result = run_uniq_cfg("a\na\nb\nc\nc\n", &config);
    assert_eq!(result, "a\na\nc\nc\n");
}

#[test]
fn test_all_repeated_separate() {
    let config = UniqConfig {
        mode: OutputMode::AllRepeated(AllRepeatedMethod::Separate),
        ..Default::default()
    };
    let result = run_uniq_cfg("a\na\nb\nc\nc\n", &config);
    assert_eq!(result, "a\na\n\nc\nc\n");
}

#[test]
fn test_all_repeated_prepend() {
    let config = UniqConfig {
        mode: OutputMode::AllRepeated(AllRepeatedMethod::Prepend),
        ..Default::default()
    };
    let result = run_uniq_cfg("a\na\nb\nc\nc\n", &config);
    assert_eq!(result, "\na\na\n\nc\nc\n");
}

// ========== -i (ignore case) ==========

#[test]
fn test_ignore_case() {
    let config = UniqConfig {
        ignore_case: true,
        ..Default::default()
    };
    let result = run_uniq_cfg("Hello\nhello\nHELLO\nworld\n", &config);
    assert_eq!(result, "Hello\nworld\n");
}

// ========== -f (skip fields) ==========

#[test]
fn test_skip_fields() {
    let config = UniqConfig {
        skip_fields: 1,
        ..Default::default()
    };
    let result = run_uniq_cfg("1 foo\n2 foo\n3 bar\n", &config);
    assert_eq!(result, "1 foo\n3 bar\n");
}

#[test]
fn test_skip_fields_tabs() {
    let config = UniqConfig {
        skip_fields: 1,
        ..Default::default()
    };
    let result = run_uniq_cfg("1\tfoo\n2\tfoo\n3\tbar\n", &config);
    assert_eq!(result, "1\tfoo\n3\tbar\n");
}

// ========== -s (skip chars) ==========

#[test]
fn test_skip_chars() {
    let config = UniqConfig {
        skip_chars: 2,
        ..Default::default()
    };
    let result = run_uniq_cfg("aafoo\nbbfoo\nccbar\n", &config);
    assert_eq!(result, "aafoo\nccbar\n");
}

// ========== -w (check chars) ==========

#[test]
fn test_check_chars() {
    let config = UniqConfig {
        check_chars: Some(3),
        ..Default::default()
    };
    let result = run_uniq_cfg("foobar\nfoobaz\nqux\n", &config);
    assert_eq!(result, "foobar\nqux\n");
}

// ========== Combined flags ==========

#[test]
fn test_count_and_repeated() {
    let config = UniqConfig {
        mode: OutputMode::RepeatedOnly,
        count: true,
        ..Default::default()
    };
    let result = run_uniq_cfg("a\na\nb\nc\nc\nc\n", &config);
    assert_eq!(result, "      2 a\n      3 c\n");
}

#[test]
fn test_skip_fields_and_chars() {
    let config = UniqConfig {
        skip_fields: 1,
        skip_chars: 1,
        ..Default::default()
    };
    // GNU: skip 1 field (blanks+non-blanks) → " xfoo", then skip 1 char → "xfoo"
    // "xfoo" vs "yfoo" vs "zbar" → all different
    let result = run_uniq_cfg("1 xfoo\n2 yfoo\n3 zbar\n", &config);
    assert_eq!(result, "1 xfoo\n2 yfoo\n3 zbar\n");
}

// ========== --group mode ==========

#[test]
fn test_group_separate() {
    let config = UniqConfig {
        mode: OutputMode::Group(GroupMethod::Separate),
        ..Default::default()
    };
    let result = run_uniq_cfg("a\na\nb\nc\nc\n", &config);
    assert_eq!(result, "a\na\n\nb\n\nc\nc\n");
}

#[test]
fn test_group_prepend() {
    let config = UniqConfig {
        mode: OutputMode::Group(GroupMethod::Prepend),
        ..Default::default()
    };
    let result = run_uniq_cfg("a\na\nb\n", &config);
    assert_eq!(result, "\na\na\n\nb\n");
}

#[test]
fn test_group_append() {
    let config = UniqConfig {
        mode: OutputMode::Group(GroupMethod::Append),
        ..Default::default()
    };
    let result = run_uniq_cfg("a\na\nb\n", &config);
    assert_eq!(result, "a\na\n\nb\n\n");
}

#[test]
fn test_group_both() {
    let config = UniqConfig {
        mode: OutputMode::Group(GroupMethod::Both),
        ..Default::default()
    };
    let result = run_uniq_cfg("a\na\nb\n", &config);
    assert_eq!(result, "\na\na\n\nb\n\n");
}

// ========== -z (zero terminated) ==========

#[test]
fn test_zero_terminated() {
    let config = UniqConfig {
        zero_terminated: true,
        ..Default::default()
    };
    let input = "a\0a\0b\0";
    let mut output = Vec::new();
    process_uniq(input.as_bytes(), &mut output, &config).unwrap();
    assert_eq!(output, b"a\0b\0");
}
