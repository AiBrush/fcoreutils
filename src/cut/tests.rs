use super::*;

fn cut_field_str(input: &str, delim: u8, spec: &str, complement: bool, suppress: bool) -> String {
    let ranges = parse_ranges(spec, false).unwrap();
    let output_delim = &[delim];
    let mut out = Vec::new();
    cut_fields(
        input.as_bytes(),
        delim,
        &ranges,
        complement,
        output_delim,
        suppress,
        &mut out,
    )
    .unwrap();
    String::from_utf8(out).unwrap()
}

fn cut_byte_str(input: &str, spec: &str, complement: bool) -> String {
    let ranges = parse_ranges(spec, false).unwrap();
    let mut out = Vec::new();
    cut_bytes(input.as_bytes(), &ranges, complement, b"", &mut out).unwrap();
    String::from_utf8(out).unwrap()
}

fn process_data_str(
    input: &str,
    mode: CutMode,
    spec: &str,
    delim: u8,
    complement: bool,
    suppress: bool,
    output_delim: Option<&[u8]>,
    line_delim: u8,
) -> String {
    let ranges = parse_ranges(spec, false).unwrap();
    let default_od = if mode == CutMode::Fields {
        vec![delim]
    } else {
        vec![]
    };
    let od = output_delim.unwrap_or(&default_od);
    let cfg = CutConfig {
        mode,
        ranges: &ranges,
        complement,
        delim,
        output_delim: od,
        suppress_no_delim: suppress,
        line_delim,
    };
    let mut out = Vec::new();
    process_cut_data(input.as_bytes(), &cfg, &mut out).unwrap();
    String::from_utf8(out).unwrap()
}

// --- Range parsing ---

#[test]
fn test_parse_single() {
    let r = parse_ranges("3", false).unwrap();
    assert_eq!(r.len(), 1);
    assert_eq!(r[0].start, 3);
    assert_eq!(r[0].end, 3);
}

#[test]
fn test_parse_range() {
    let r = parse_ranges("2-4", false).unwrap();
    assert_eq!(r.len(), 1);
    assert_eq!(r[0].start, 2);
    assert_eq!(r[0].end, 4);
}

#[test]
fn test_parse_open_start() {
    let r = parse_ranges("-3", false).unwrap();
    assert_eq!(r[0].start, 1);
    assert_eq!(r[0].end, 3);
}

#[test]
fn test_parse_open_end() {
    let r = parse_ranges("3-", false).unwrap();
    assert_eq!(r[0].start, 3);
    assert_eq!(r[0].end, usize::MAX);
}

#[test]
fn test_parse_multiple() {
    let r = parse_ranges("1,3,5", false).unwrap();
    assert_eq!(r.len(), 3);
}

#[test]
fn test_parse_merge_overlapping() {
    let r = parse_ranges("1-3,2-5", false).unwrap();
    assert_eq!(r.len(), 1);
    assert_eq!(r[0].start, 1);
    assert_eq!(r[0].end, 5);
}

#[test]
fn test_parse_merge_adjacent() {
    let r = parse_ranges("1-2,3-4", false).unwrap();
    assert_eq!(r.len(), 1);
    assert_eq!(r[0].start, 1);
    assert_eq!(r[0].end, 4);
}

#[test]
fn test_parse_zero_rejected() {
    assert!(parse_ranges("0", false).is_err());
}

// --- Field cutting ---

#[test]
fn test_cut_field_single() {
    assert_eq!(cut_field_str("a:b:c:d", b':', "2", false, false), "b");
}

#[test]
fn test_cut_field_multiple() {
    assert_eq!(cut_field_str("a:b:c:d", b':', "1,3", false, false), "a:c");
}

#[test]
fn test_cut_field_range() {
    assert_eq!(cut_field_str("a:b:c:d", b':', "2-4", false, false), "b:c:d");
}

#[test]
fn test_cut_field_open_start() {
    assert_eq!(cut_field_str("a:b:c:d", b':', "-2", false, false), "a:b");
}

#[test]
fn test_cut_field_open_end() {
    assert_eq!(cut_field_str("a:b:c:d", b':', "3-", false, false), "c:d");
}

#[test]
fn test_cut_field_no_delim_print() {
    assert_eq!(
        cut_field_str("no delimiter", b':', "1", false, false),
        "no delimiter"
    );
}

#[test]
fn test_cut_field_no_delim_suppress() {
    assert_eq!(cut_field_str("no delimiter", b':', "1", false, true), "");
}

#[test]
fn test_cut_field_complement() {
    assert_eq!(cut_field_str("a:b:c:d", b':', "2", true, false), "a:c:d");
}

#[test]
fn test_cut_field_empty_fields() {
    assert_eq!(cut_field_str("a::c", b':', "2", false, false), "");
    assert_eq!(cut_field_str("::c", b':', "1", false, false), "");
}

#[test]
fn test_cut_field_tab_default() {
    assert_eq!(cut_field_str("a\tb\tc", b'\t', "2", false, false), "b");
}

// --- Byte cutting ---

#[test]
fn test_cut_bytes_single() {
    assert_eq!(cut_byte_str("hello", "1", false), "h");
}

#[test]
fn test_cut_bytes_range() {
    assert_eq!(cut_byte_str("hello world", "1-5", false), "hello");
}

#[test]
fn test_cut_bytes_multiple() {
    assert_eq!(cut_byte_str("hello", "1,3,5", false), "hlo");
}

#[test]
fn test_cut_bytes_complement() {
    assert_eq!(cut_byte_str("hello", "1,3,5", true), "el");
}

#[test]
fn test_cut_bytes_open_end() {
    assert_eq!(cut_byte_str("hello", "3-", false), "llo");
}

// --- Suppress mode (process_cut_data) ---

#[test]
fn test_suppress_skips_no_delim_lines() {
    // Lines without delimiter should be completely suppressed (no newline either)
    let result = process_data_str(
        "has:delim\nno_delim\nalso:has\n",
        CutMode::Fields,
        "1",
        b':',
        false,
        true,
        None,
        b'\n',
    );
    assert_eq!(result, "has\nalso\n");
}

#[test]
fn test_suppress_all_no_delim() {
    let result = process_data_str(
        "line1\nline2\nline3\n",
        CutMode::Fields,
        "1",
        b':',
        false,
        true,
        None,
        b'\n',
    );
    assert_eq!(result, "");
}

#[test]
fn test_no_suppress_prints_whole_line() {
    let result = process_data_str(
        "no_delim\n",
        CutMode::Fields,
        "1",
        b':',
        false,
        false,
        None,
        b'\n',
    );
    assert_eq!(result, "no_delim\n");
}

// --- process_cut_data multi-line ---

#[test]
fn test_process_multiline_fields() {
    let result = process_data_str(
        "a:b:c\nx:y:z\n",
        CutMode::Fields,
        "2",
        b':',
        false,
        false,
        None,
        b'\n',
    );
    assert_eq!(result, "b\ny\n");
}

#[test]
fn test_process_multiline_bytes() {
    let result = process_data_str(
        "hello\nworld\n",
        CutMode::Bytes,
        "1-3",
        b'\t',
        false,
        false,
        None,
        b'\n',
    );
    assert_eq!(result, "hel\nwor\n");
}

// --- Complement field tests (process_cut_data) ---

#[test]
fn test_complement_field_f1() {
    // --complement -f1: output all fields except field 1
    let result = process_data_str(
        "a,b,c,d\n",
        CutMode::Fields,
        "1",
        b',',
        true,
        false,
        None,
        b'\n',
    );
    assert_eq!(result, "b,c,d\n");
}

#[test]
fn test_complement_field_f2() {
    // --complement -f2: output all fields except field 2
    let result = process_data_str(
        "a,b,c,d\n",
        CutMode::Fields,
        "2",
        b',',
        true,
        false,
        None,
        b'\n',
    );
    assert_eq!(result, "a,c,d\n");
}

#[test]
fn test_complement_bytes_b1_3() {
    // --complement -b1-3: output all bytes except 1-3
    let result = process_data_str(
        "hello\n",
        CutMode::Bytes,
        "1-3",
        b'\t',
        true,
        false,
        None,
        b'\n',
    );
    assert_eq!(result, "lo\n");
}

#[test]
fn test_complement_field_multiline() {
    let result = process_data_str(
        "a:b:c\nx:y:z\n",
        CutMode::Fields,
        "2",
        b':',
        true,
        false,
        None,
        b'\n',
    );
    assert_eq!(result, "a:c\nx:z\n");
}

// --- Output delimiter tests ---

#[test]
fn test_output_delimiter_fields() {
    // --output-delimiter=':' with comma-delimited fields
    let result = process_data_str(
        "a,b,c\n",
        CutMode::Fields,
        "1,3",
        b',',
        false,
        false,
        Some(b":"),
        b'\n',
    );
    assert_eq!(result, "a:c\n");
}

#[test]
fn test_output_delimiter_bytes() {
    // --output-delimiter=':' with byte selection
    let result = process_data_str(
        "hello\n",
        CutMode::Bytes,
        "1,3,5",
        b'\t',
        false,
        false,
        Some(b":"),
        b'\n',
    );
    assert_eq!(result, "h:l:o\n");
}

#[test]
fn test_output_delimiter_complement_fields() {
    // --complement --output-delimiter=':' -f2
    let result = process_data_str(
        "a,b,c,d\n",
        CutMode::Fields,
        "2",
        b',',
        true,
        false,
        Some(b":"),
        b'\n',
    );
    assert_eq!(result, "a:c:d\n");
}

// --- Zero-terminated (-z) tests ---

#[test]
fn test_zero_terminated_fields() {
    // -z: NUL-delimited input and output
    let result = process_data_str(
        "a,b\0c,d\0",
        CutMode::Fields,
        "1",
        b',',
        false,
        false,
        None,
        b'\0',
    );
    assert_eq!(result, "a\0c\0");
}

#[test]
fn test_zero_terminated_bytes() {
    // -z with byte selection
    let result = process_data_str(
        "hello\0world\0",
        CutMode::Bytes,
        "1-3",
        b'\t',
        false,
        false,
        None,
        b'\0',
    );
    assert_eq!(result, "hel\0wor\0");
}

#[test]
fn test_zero_terminated_complement() {
    // -z with --complement
    let result = process_data_str(
        "a,b,c\0x,y,z\0",
        CutMode::Fields,
        "2",
        b',',
        true,
        false,
        None,
        b'\0',
    );
    assert_eq!(result, "a,c\0x,z\0");
}

// --- Return value tests ---

#[test]
fn test_cut_fields_returns_false_when_suppressed() {
    let ranges = parse_ranges("1", false).unwrap();
    let mut out = Vec::new();
    let result = cut_fields(b"no_delim", b':', &ranges, false, b":", true, &mut out).unwrap();
    assert!(!result);
    assert!(out.is_empty());
}

#[test]
fn test_cut_fields_returns_true_when_not_suppressed() {
    let ranges = parse_ranges("1", false).unwrap();
    let mut out = Vec::new();
    let result = cut_fields(b"a:b", b':', &ranges, false, b":", false, &mut out).unwrap();
    assert!(result);
    assert_eq!(&out, b"a");
}
