use super::*;
use std::io::Cursor;

#[test]
fn test_sha256_empty() {
    let hash = hash_reader(HashAlgorithm::Sha256, Cursor::new(b"")).unwrap();
    assert_eq!(
        hash,
        "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    );
}

#[test]
fn test_sha256_hello_newline() {
    // echo "hello" | sha256sum → hash of "hello\n"
    let hash = hash_reader(HashAlgorithm::Sha256, Cursor::new(b"hello\n")).unwrap();
    assert_eq!(
        hash,
        "5891b5b522d5df086d0ff0b110fbd9d21bb4fc7163af34d08286a2e846f6be03"
    );
}

#[test]
fn test_md5_empty() {
    let hash = hash_reader(HashAlgorithm::Md5, Cursor::new(b"")).unwrap();
    assert_eq!(hash, "d41d8cd98f00b204e9800998ecf8427e");
}

#[test]
fn test_md5_hello_newline() {
    let hash = hash_reader(HashAlgorithm::Md5, Cursor::new(b"hello\n")).unwrap();
    assert_eq!(hash, "b1946ac92492d2347c6235b4d2611184");
}

#[test]
fn test_blake2b_empty() {
    let hash = hash_reader(HashAlgorithm::Blake2b, Cursor::new(b"")).unwrap();
    assert_eq!(
        hash,
        "786a02f742015903c6c6fd852552d272912f4740e15847618a86e217f71f5419\
         d25e1031afee585313896444934eb04b903a685b1448b755d56f701afe9be2ce"
    );
}

#[test]
fn test_blake2b_hello_newline() {
    let hash = hash_reader(HashAlgorithm::Blake2b, Cursor::new(b"hello\n")).unwrap();
    assert_eq!(
        hash,
        "f60ce482e5cc1229f39d71313171a8d9f4ca3a87d066bf4b205effb528192a75\
         f14f3271e2c1a90e1de53f275b4d4793eef2f5e31ea90d2ce29d2e481c36435f"
    );
}

#[test]
fn test_hex_encode() {
    assert_eq!(hex_encode(&[0x00, 0xff, 0xab]), "00ffab");
}

#[test]
fn test_parse_check_line_standard() {
    let (hash, file) = parse_check_line("abc123  test.txt").unwrap();
    assert_eq!(hash, "abc123");
    assert_eq!(file, "test.txt");
}

#[test]
fn test_parse_check_line_binary() {
    let (hash, file) = parse_check_line("abc123 *test.txt").unwrap();
    assert_eq!(hash, "abc123");
    assert_eq!(file, "test.txt");
}

#[test]
fn test_parse_check_line_invalid() {
    assert!(parse_check_line("no valid format").is_none());
}
