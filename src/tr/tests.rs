use super::charset::{complement, expand_set2, parse_set};

// === parse_set tests ===

#[test]
fn test_parse_literal() {
    assert_eq!(parse_set("abc"), vec![b'a', b'b', b'c']);
}

#[test]
fn test_parse_range() {
    assert_eq!(parse_set("a-e"), vec![b'a', b'b', b'c', b'd', b'e']);
    assert_eq!(parse_set("0-3"), vec![b'0', b'1', b'2', b'3']);
}

#[test]
fn test_parse_range_az() {
    let result = parse_set("a-z");
    assert_eq!(result.len(), 26);
    assert_eq!(result[0], b'a');
    assert_eq!(result[25], b'z');
}

#[test]
fn test_parse_range_upper() {
    let result = parse_set("A-Z");
    assert_eq!(result.len(), 26);
    assert_eq!(result[0], b'A');
    assert_eq!(result[25], b'Z');
}

#[test]
fn test_parse_escape_sequences() {
    assert_eq!(parse_set("\\n"), vec![b'\n']);
    assert_eq!(parse_set("\\t"), vec![b'\t']);
    assert_eq!(parse_set("\\r"), vec![b'\r']);
    assert_eq!(parse_set("\\\\"), vec![b'\\']);
    assert_eq!(parse_set("\\a"), vec![0x07]);
    assert_eq!(parse_set("\\b"), vec![0x08]);
    assert_eq!(parse_set("\\f"), vec![0x0C]);
    assert_eq!(parse_set("\\v"), vec![0x0B]);
}

#[test]
fn test_parse_octal() {
    assert_eq!(parse_set("\\101"), vec![b'A']); // 0o101 = 65 = 'A'
    assert_eq!(parse_set("\\060"), vec![b'0']); // 0o060 = 48 = '0'
    assert_eq!(parse_set("\\000"), vec![0u8]);
}

#[test]
fn test_parse_char_class_lower() {
    let result = parse_set("[:lower:]");
    assert_eq!(result.len(), 26);
    assert_eq!(result[0], b'a');
    assert_eq!(result[25], b'z');
}

#[test]
fn test_parse_char_class_upper() {
    let result = parse_set("[:upper:]");
    assert_eq!(result.len(), 26);
    assert_eq!(result[0], b'A');
    assert_eq!(result[25], b'Z');
}

#[test]
fn test_parse_char_class_digit() {
    let result = parse_set("[:digit:]");
    assert_eq!(result.len(), 10);
    assert_eq!(result[0], b'0');
    assert_eq!(result[9], b'9');
}

#[test]
fn test_parse_char_class_alpha() {
    let result = parse_set("[:alpha:]");
    assert_eq!(result.len(), 52);
}

#[test]
fn test_parse_char_class_alnum() {
    let result = parse_set("[:alnum:]");
    assert_eq!(result.len(), 62);
}

#[test]
fn test_parse_char_class_space() {
    let result = parse_set("[:space:]");
    assert_eq!(result.len(), 6);
    assert!(result.contains(&b'\t'));
    assert!(result.contains(&b'\n'));
    assert!(result.contains(&b' '));
    assert!(result.contains(&b'\r'));
    assert!(result.contains(&0x0B)); // \v
    assert!(result.contains(&0x0C)); // \f
}

#[test]
fn test_parse_char_class_blank() {
    let result = parse_set("[:blank:]");
    assert_eq!(result.len(), 2);
    assert!(result.contains(&b'\t'));
    assert!(result.contains(&b' '));
}

#[test]
fn test_parse_char_class_xdigit() {
    let result = parse_set("[:xdigit:]");
    assert_eq!(result.len(), 22);
}

#[test]
fn test_parse_char_class_punct() {
    let result = parse_set("[:punct:]");
    // Standard ASCII punctuation
    assert!(result.contains(&b'!'));
    assert!(result.contains(&b'.'));
    assert!(result.contains(&b','));
    assert!(!result.contains(&b'a'));
    assert!(!result.contains(&b' '));
}

#[test]
fn test_parse_char_class_print() {
    let result = parse_set("[:print:]");
    assert_eq!(result.len(), 95); // 32..=126
    assert!(result.contains(&b' '));
    assert!(result.contains(&b'~'));
}

#[test]
fn test_parse_char_class_graph() {
    let result = parse_set("[:graph:]");
    assert_eq!(result.len(), 94); // 33..=126
    assert!(!result.contains(&b' '));
    assert!(result.contains(&b'!'));
}

#[test]
fn test_parse_char_class_cntrl() {
    let result = parse_set("[:cntrl:]");
    assert_eq!(result.len(), 33); // 0..=31 + 127
    assert!(result.contains(&0u8));
    assert!(result.contains(&127u8));
}

#[test]
fn test_parse_equiv_class() {
    assert_eq!(parse_set("[=a=]"), vec![b'a']);
    assert_eq!(parse_set("[=z=]"), vec![b'z']);
}

#[test]
fn test_parse_repeat() {
    assert_eq!(parse_set("[x*3]"), vec![b'x', b'x', b'x']);
    assert_eq!(parse_set("[a*5]"), vec![b'a'; 5]);
}

#[test]
fn test_parse_repeat_octal() {
    // [a*010] = repeat 'a' 8 times (010 is octal for 8)
    assert_eq!(parse_set("[a*010]"), vec![b'a'; 8]);
}

#[test]
fn test_parse_combined() {
    // Literal + range
    let result = parse_set("xa-cz");
    assert_eq!(result, vec![b'x', b'a', b'b', b'c', b'z']);
}

// === complement tests ===

#[test]
fn test_complement_basic() {
    let set = parse_set("a-z");
    let comp = complement(&set);
    // complement should have 256-26 = 230 entries
    assert_eq!(comp.len(), 230);
    // 'a' through 'z' should NOT be in complement
    for c in b'a'..=b'z' {
        assert!(!comp.contains(&c));
    }
    // Digits should be in complement
    for c in b'0'..=b'9' {
        assert!(comp.contains(&c));
    }
}

#[test]
fn test_complement_empty() {
    let comp = complement(&[]);
    assert_eq!(comp.len(), 256);
}

#[test]
fn test_complement_full() {
    let all: Vec<u8> = (0u8..=255).collect();
    let comp = complement(&all);
    assert_eq!(comp.len(), 0);
}

#[test]
fn test_complement_sorted() {
    let set = parse_set("abc");
    let comp = complement(&set);
    // Result should be sorted ascending
    for i in 1..comp.len() {
        assert!(comp[i] > comp[i - 1]);
    }
}

// === expand_set2 tests ===

#[test]
fn test_expand_set2_pad_last() {
    let result = expand_set2("AB", 5);
    assert_eq!(result, vec![b'A', b'B', b'B', b'B', b'B']);
}

#[test]
fn test_expand_set2_fill_repeat() {
    let result = expand_set2("[x*]", 5);
    assert_eq!(result, vec![b'x'; 5]);
}

#[test]
fn test_expand_set2_range() {
    let result = expand_set2("A-Z", 26);
    assert_eq!(result.len(), 26);
    assert_eq!(result[0], b'A');
    assert_eq!(result[25], b'Z');
}

#[test]
fn test_expand_set2_class() {
    let result = expand_set2("[:upper:]", 26);
    assert_eq!(result.len(), 26);
    assert_eq!(result[0], b'A');
    assert_eq!(result[25], b'Z');
}

// === Integration-style tests using subprocesses ===

use std::process::Command;

fn ftr_path() -> String {
    let cwd = std::env::current_dir().unwrap();
    let ext = if cfg!(windows) { ".exe" } else { "" };
    // Check release first (CI uses cargo test --release)
    let release = cwd.join(format!("target/release/ftr{}", ext));
    if release.exists() {
        return release.to_string_lossy().into_owned();
    }
    let debug = cwd.join(format!("target/debug/ftr{}", ext));
    debug.to_string_lossy().into_owned()
}

fn run_ftr(input: &[u8], args: &[&str]) -> Vec<u8> {
    use std::io::Write;
    let mut child = Command::new(ftr_path())
        .args(args)
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .spawn()
        .expect("failed to spawn ftr");

    child
        .stdin
        .as_mut()
        .unwrap()
        .write_all(input)
        .expect("failed to write stdin");

    let output = child.wait_with_output().expect("failed to wait on ftr");
    output.stdout
}

fn run_gnu_tr(input: &[u8], args: &[&str]) -> Option<Vec<u8>> {
    use std::io::Write;
    let mut child = match Command::new("tr")
        .args(args)
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .spawn()
    {
        Ok(c) => c,
        Err(_) => return None, // tr not available (e.g., Windows)
    };

    child
        .stdin
        .as_mut()
        .unwrap()
        .write_all(input)
        .expect("failed to write stdin");

    let output = child.wait_with_output().expect("failed to wait on tr");
    Some(output.stdout)
}

/// Assert our output matches GNU tr if available.
/// Only compare on Linux where GNU coreutils tr is guaranteed.
/// macOS uses BSD tr which differs for binary/high-byte handling.
fn assert_gnu_compat(ours: &[u8], gnu: Option<Vec<u8>>) {
    if cfg!(target_os = "linux") {
        if let Some(gnu) = gnu {
            assert_eq!(ours, gnu.as_slice());
        }
    }
}

#[test]
fn test_translate_lowercase_to_uppercase() {
    let input = b"hello world";
    let ours = run_ftr(input, &["a-z", "A-Z"]);
    assert_gnu_compat(&ours, run_gnu_tr(input, &["a-z", "A-Z"]));
    assert_eq!(ours, b"HELLO WORLD");
}

#[test]
fn test_translate_uppercase_to_lowercase() {
    let input = b"HELLO WORLD";
    let ours = run_ftr(input, &["A-Z", "a-z"]);
    assert_gnu_compat(&ours, run_gnu_tr(input, &["A-Z", "a-z"]));
}

#[test]
fn test_delete_vowels() {
    let input = b"hello world";
    let ours = run_ftr(input, &["-d", "aeiou"]);
    assert_gnu_compat(&ours, run_gnu_tr(input, &["-d", "aeiou"]));
    assert_eq!(ours, b"hll wrld");
}

#[test]
fn test_delete_digits() {
    let input = b"abc123def456";
    let ours = run_ftr(input, &["-d", "0-9"]);
    assert_gnu_compat(&ours, run_gnu_tr(input, &["-d", "0-9"]));
    assert_eq!(ours, b"abcdef");
}

#[test]
fn test_squeeze_spaces() {
    let input = b"hello    world   foo";
    let ours = run_ftr(input, &["-s", " "]);
    assert_gnu_compat(&ours, run_gnu_tr(input, &["-s", " "]));
    assert_eq!(ours, b"hello world foo");
}

#[test]
fn test_squeeze_newlines() {
    let input = b"a\n\n\nb\n\nc";
    let ours = run_ftr(input, &["-s", "\\n"]);
    assert_gnu_compat(&ours, run_gnu_tr(input, &["-s", "\\n"]));
    assert_eq!(ours, b"a\nb\nc");
}

#[test]
fn test_delete_complement() {
    let input = b"hello 123 world";
    let ours = run_ftr(input, &["-cd", "0-9"]);
    assert_gnu_compat(&ours, run_gnu_tr(input, &["-cd", "0-9"]));
    assert_eq!(ours, b"123");
}

#[test]
fn test_translate_with_class() {
    let input = b"hello world";
    let ours = run_ftr(input, &["[:lower:]", "[:upper:]"]);
    assert_gnu_compat(&ours, run_gnu_tr(input, &["[:lower:]", "[:upper:]"]));
    assert_eq!(ours, b"HELLO WORLD");
}

#[test]
fn test_translate_rot13() {
    let input = b"hello";
    let ours = run_ftr(input, &["a-zA-Z", "n-za-mN-ZA-M"]);
    assert_gnu_compat(&ours, run_gnu_tr(input, &["a-zA-Z", "n-za-mN-ZA-M"]));
}

#[test]
fn test_delete_squeeze() {
    let input = b"aabbbccddee";
    let ours = run_ftr(input, &["-ds", "a", "d"]);
    assert_gnu_compat(&ours, run_gnu_tr(input, &["-ds", "a", "d"]));
}

#[test]
fn test_translate_single_char() {
    let input = b"a.b.c";
    let ours = run_ftr(input, &[".", ","]);
    assert_gnu_compat(&ours, run_gnu_tr(input, &[".", ","]));
    assert_eq!(ours, b"a,b,c");
}

#[test]
fn test_empty_input() {
    let input = b"";
    let ours = run_ftr(input, &["a-z", "A-Z"]);
    assert_eq!(ours, b"");
}

#[test]
fn test_binary_data() {
    let input: Vec<u8> = (0u8..=255).collect();
    let ours = run_ftr(&input, &["-d", "\\000"]);
    assert_gnu_compat(&ours, run_gnu_tr(&input, &["-d", "\\000"]));
}

#[test]
fn test_squeeze_with_translate() {
    let input = b"aabbbcc";
    let ours = run_ftr(input, &["-s", "a-c", "x-z"]);
    assert_gnu_compat(&ours, run_gnu_tr(input, &["-s", "a-c", "x-z"]));
}

#[test]
fn test_complement_translate() {
    let input = b"hello123";
    let ours = run_ftr(input, &["-c", "a-z", "."]);
    assert_gnu_compat(&ours, run_gnu_tr(input, &["-c", "a-z", "."]));
}

// === Additional edge case tests ===

#[test]
fn test_delete_with_char_class() {
    let input = b"Hello World 123!";
    let ours = run_ftr(input, &["-d", "[:digit:]"]);
    assert_gnu_compat(&ours, run_gnu_tr(input, &["-d", "[:digit:]"]));
    assert_eq!(ours, b"Hello World !");
}

#[test]
fn test_complement_delete_keep_alpha() {
    let input = b"H3llo W0rld!";
    let ours = run_ftr(input, &["-cd", "[:alpha:]"]);
    assert_gnu_compat(&ours, run_gnu_tr(input, &["-cd", "[:alpha:]"]));
    assert_eq!(ours, b"HlloWrld");
}

#[test]
fn test_squeeze_complement() {
    let input = b"hello   123   world";
    let ours = run_ftr(input, &["-cs", "[:alpha:]", " "]);
    assert_gnu_compat(&ours, run_gnu_tr(input, &["-cs", "[:alpha:]", " "]));
}

#[test]
fn test_translate_digits_to_hash() {
    let input = b"phone: 555-1234";
    let ours = run_ftr(input, &["0-9", "[#*]"]);
    assert_gnu_compat(&ours, run_gnu_tr(input, &["0-9", "[#*]"]));
}

#[test]
fn test_delete_newlines() {
    let input = b"line1\nline2\nline3\n";
    let ours = run_ftr(input, &["-d", "\\n"]);
    assert_gnu_compat(&ours, run_gnu_tr(input, &["-d", "\\n"]));
    assert_eq!(ours, b"line1line2line3");
}

#[test]
fn test_squeeze_multiple_chars() {
    let input = b"aabbccaabbcc";
    let ours = run_ftr(input, &["-s", "abc"]);
    assert_gnu_compat(&ours, run_gnu_tr(input, &["-s", "abc"]));
    assert_eq!(ours, b"abcabc");
}

#[test]
fn test_translate_spaces_to_newlines() {
    let input = b"hello world foo bar";
    let ours = run_ftr(input, &[" ", "\\n"]);
    assert_gnu_compat(&ours, run_gnu_tr(input, &[" ", "\\n"]));
    assert_eq!(ours, b"hello\nworld\nfoo\nbar");
}

#[test]
fn test_delete_all_whitespace() {
    let input = b"hello \t world \n foo";
    let ours = run_ftr(input, &["-d", "[:space:]"]);
    assert_gnu_compat(&ours, run_gnu_tr(input, &["-d", "[:space:]"]));
    assert_eq!(ours, b"helloworldfoo");
}

#[test]
fn test_complement_delete_keep_digits_newline() {
    let input = b"abc123\ndef456\n";
    let ours = run_ftr(input, &["-cd", "0-9\\n"]);
    assert_gnu_compat(&ours, run_gnu_tr(input, &["-cd", "0-9\\n"]));
    assert_eq!(ours, b"123\n456\n");
}

#[test]
fn test_translate_upper_class_to_lower_class() {
    let input = b"HELLO WORLD";
    let ours = run_ftr(input, &["[:upper:]", "[:lower:]"]);
    assert_gnu_compat(&ours, run_gnu_tr(input, &["[:upper:]", "[:lower:]"]));
    assert_eq!(ours, b"hello world");
}

#[test]
fn test_identity_translate() {
    let input = b"hello world";
    let ours = run_ftr(input, &["a-z", "a-z"]);
    assert_eq!(ours, b"hello world");
}

#[test]
fn test_delete_squeeze_combined() {
    let input = b"aabbbaaabbba";
    let ours = run_ftr(input, &["-ds", "a", "b"]);
    assert_gnu_compat(&ours, run_gnu_tr(input, &["-ds", "a", "b"]));
    assert_eq!(ours, b"b");
}

#[test]
fn test_null_byte_handling() {
    let input = &[0u8, b'a', 0u8, b'b', 0u8];
    let ours = run_ftr(input, &["\\000", "X"]);
    assert_gnu_compat(&ours, run_gnu_tr(input, &["\\000", "X"]));
    assert_eq!(ours, b"XaXbX");
}

#[test]
fn test_high_bytes() {
    let input = &[b'a', 200u8, b'b', 255u8, b'c'];
    let ours = run_ftr(input, &["-d", "\\200-\\377"]);
    assert_gnu_compat(&ours, run_gnu_tr(input, &["-d", "\\200-\\377"]));
    assert_eq!(ours, b"abc");
}
