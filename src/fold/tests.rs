use super::*;

fn fold(input: &str, width: usize) -> String {
    let mut out = Vec::new();
    fold_bytes(input.as_bytes(), width, false, false, &mut out).unwrap();
    String::from_utf8(out).unwrap()
}

fn fold_b(input: &str, width: usize) -> String {
    let mut out = Vec::new();
    fold_bytes(input.as_bytes(), width, true, false, &mut out).unwrap();
    String::from_utf8(out).unwrap()
}

fn fold_s(input: &str, width: usize) -> String {
    let mut out = Vec::new();
    fold_bytes(input.as_bytes(), width, false, true, &mut out).unwrap();
    String::from_utf8(out).unwrap()
}

fn fold_bs(input: &str, width: usize) -> String {
    let mut out = Vec::new();
    fold_bytes(input.as_bytes(), width, true, true, &mut out).unwrap();
    String::from_utf8(out).unwrap()
}

// ===== Basic tests =====

#[test]
fn test_empty() {
    assert_eq!(fold("", 80), "");
}

#[test]
fn test_short_line() {
    assert_eq!(fold("hello\n", 80), "hello\n");
}

#[test]
fn test_exact_width() {
    assert_eq!(fold("12345\n", 5), "12345\n");
}

#[test]
fn test_one_over() {
    assert_eq!(fold("123456\n", 5), "12345\n6\n");
}

#[test]
fn test_double_width() {
    assert_eq!(fold("1234567890\n", 5), "12345\n67890\n");
}

#[test]
fn test_no_trailing_newline() {
    assert_eq!(fold("1234567890", 5), "12345\n67890");
}

#[test]
fn test_multiple_lines() {
    assert_eq!(fold("abc\ndef\n", 80), "abc\ndef\n");
}

#[test]
fn test_width_1() {
    assert_eq!(fold("abc\n", 1), "a\nb\nc\n");
}

#[test]
fn test_default_width_80() {
    let line = "a".repeat(100);
    let input = format!("{}\n", line);
    let result = fold(&input, 80);
    let lines: Vec<&str> = result.split('\n').collect();
    assert_eq!(lines[0].len(), 80);
    assert_eq!(lines[1].len(), 20);
}

// ===== -b (bytes) mode =====

#[test]
fn test_bytes_mode() {
    assert_eq!(fold_b("1234567890\n", 5), "12345\n67890\n");
}

#[test]
fn test_bytes_tab() {
    // In byte mode, tab is 1 byte
    assert_eq!(fold_b("\t12345678\n", 5), "\t1234\n5678\n");
}

// ===== -s (spaces) mode =====

#[test]
fn test_spaces_break() {
    // "world test" is exactly 10 chars, fits in width=10
    assert_eq!(fold_s("hello world test\n", 10), "hello \nworld test\n");
}

#[test]
fn test_spaces_no_space_in_range() {
    // No space within width: break at width anyway
    assert_eq!(fold_s("abcdefghijklmno\n", 10), "abcdefghij\nklmno\n");
}

#[test]
fn test_spaces_exact_fit() {
    assert_eq!(fold_s("hello worl\n", 10), "hello worl\n");
}

// ===== -b -s combined =====

#[test]
fn test_bytes_spaces() {
    // "world test" is exactly 10 bytes, fits in width=10
    assert_eq!(fold_bs("hello world test\n", 10), "hello \nworld test\n");
}

// ===== Tab handling (column mode) =====

#[test]
fn test_tab_column_mode() {
    // Tab at column 0 advances to column 8
    let result = fold("\t12345\n", 10);
    // Tab takes 8 columns, then 1 and 2 fit (cols 8,9), but 3 would be col 10 which = width
    assert_eq!(result, "\t12\n345\n");
}

// ===== Edge cases =====

#[test]
fn test_empty_lines() {
    assert_eq!(fold("\n\n\n", 5), "\n\n\n");
}

#[test]
fn test_single_char_lines() {
    assert_eq!(fold("a\nb\nc\n", 80), "a\nb\nc\n");
}

// ===== Integration tests =====

#[cfg(test)]
mod integration {
    use std::process::Command;

    fn bin_path(name: &str) -> std::path::PathBuf {
        let mut path = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"));
        path.push("target");
        if cfg!(debug_assertions) {
            path.push("debug");
        } else {
            path.push("release");
        }
        path.push(name);
        path
    }

    fn run_ffold(input: &[u8], args: &[&str]) -> (Vec<u8>, i32) {
        let mut cmd = Command::new(bin_path("ffold"));
        cmd.args(args);
        cmd.stdin(std::process::Stdio::piped());
        cmd.stdout(std::process::Stdio::piped());
        cmd.stderr(std::process::Stdio::piped());
        let mut child = cmd.spawn().expect("failed to spawn ffold");
        use std::io::Write;
        child.stdin.take().unwrap().write_all(input).unwrap();
        let output = child.wait_with_output().expect("failed to wait");
        (output.stdout, output.status.code().unwrap_or(1))
    }

    #[test]
    fn test_fold_stdin() {
        let input = "a".repeat(100) + "\n";
        let (out, code) = run_ffold(input.as_bytes(), &[]);
        assert_eq!(code, 0);
        let lines: Vec<&[u8]> = out.split(|&b| b == b'\n').collect();
        assert_eq!(lines[0].len(), 80);
        assert_eq!(lines[1].len(), 20);
    }

    #[test]
    fn test_fold_width() {
        let (out, code) = run_ffold(b"1234567890\n", &["-w", "5"]);
        assert_eq!(code, 0);
        assert_eq!(out, b"12345\n67890\n");
    }

    #[test]
    fn test_fold_bytes_flag() {
        let (out, code) = run_ffold(b"1234567890\n", &["-b", "-w", "5"]);
        assert_eq!(code, 0);
        assert_eq!(out, b"12345\n67890\n");
    }

    #[test]
    fn test_fold_spaces_flag() {
        let (out, code) = run_ffold(b"hello world test\n", &["-s", "-w", "10"]);
        assert_eq!(code, 0);
        assert_eq!(out, b"hello \nworld test\n");
    }

    #[test]
    fn test_fold_file() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("test.txt");
        let data = "a".repeat(100) + "\n";
        std::fs::write(&path, &data).unwrap();
        let (out, code) = run_ffold(b"", &["-w", "50", path.to_str().unwrap()]);
        assert_eq!(code, 0);
        let lines: Vec<&[u8]> = out.split(|&b| b == b'\n').collect();
        assert_eq!(lines[0].len(), 50);
        assert_eq!(lines[1].len(), 50);
    }

    #[test]
    fn test_fold_help() {
        let (_, code) = run_ffold(b"", &["--help"]);
        assert_eq!(code, 0);
    }

    #[test]
    fn test_fold_version() {
        let (_, code) = run_ffold(b"", &["--version"]);
        assert_eq!(code, 0);
    }

    #[test]
    fn test_fold_gnu_comparison() {
        let input = b"The quick brown fox jumps over the lazy dog. The quick brown fox jumps over the lazy dog.\n";
        let (our_out, code) = run_ffold(input, &["-w", "30"]);
        assert_eq!(code, 0);

        let gnu_out = Command::new("fold")
            .args(&["-w", "30"])
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::piped())
            .spawn()
            .and_then(|mut child| {
                use std::io::Write;
                child.stdin.take().unwrap().write_all(input).unwrap();
                child.wait_with_output()
            });

        if let Ok(gnu) = gnu_out {
            if gnu.status.success() {
                assert_eq!(our_out, gnu.stdout, "Output differs from GNU fold");
            }
        }
    }

    #[test]
    fn test_fold_gnu_comparison_bs() {
        let input = b"hello world this is a test of folding text at spaces\n";
        let (our_out, code) = run_ffold(input, &["-b", "-s", "-w", "15"]);
        assert_eq!(code, 0);

        let gnu_out = Command::new("fold")
            .args(&["-b", "-s", "-w", "15"])
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::piped())
            .spawn()
            .and_then(|mut child| {
                use std::io::Write;
                child.stdin.take().unwrap().write_all(input).unwrap();
                child.wait_with_output()
            });

        if let Ok(gnu) = gnu_out {
            if gnu.status.success() {
                assert_eq!(our_out, gnu.stdout, "Output differs from GNU fold -bs");
            }
        }
    }

    #[test]
    fn test_fold_nonexistent_file() {
        let (_, code) = run_ffold(b"", &["/tmp/nonexistent_ffold_test_file"]);
        assert_eq!(code, 1);
    }

    #[test]
    fn test_fold_large_file() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("large.txt");
        let mut data = Vec::new();
        for i in 0..10000 {
            data.extend_from_slice(format!("line {:07}: The quick brown fox jumps over the lazy dog and keeps on running\n", i).as_bytes());
        }
        std::fs::write(&path, &data).unwrap();
        let (out, code) = run_ffold(b"", &["-w", "40", path.to_str().unwrap()]);
        assert_eq!(code, 0);
        assert!(!out.is_empty());
    }
}
