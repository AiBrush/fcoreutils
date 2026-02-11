#[cfg(test)]
mod tests {
    use crate::base64::core::*;

    fn encode_bytes(input: &[u8], wrap: usize) -> Vec<u8> {
        let mut out = Vec::new();
        encode_to_writer(input, wrap, &mut out).unwrap();
        out
    }

    fn decode_bytes(input: &[u8], ignore_garbage: bool) -> Result<Vec<u8>, std::io::Error> {
        let mut out = Vec::new();
        decode_to_writer(input, ignore_garbage, &mut out)?;
        Ok(out)
    }

    // ===== ENCODING TESTS =====

    #[test]
    fn test_encode_empty() {
        assert_eq!(encode_bytes(b"", 76), b"");
    }

    #[test]
    fn test_encode_hello() {
        assert_eq!(encode_bytes(b"Hello", 76), b"SGVsbG8=\n");
    }

    #[test]
    fn test_encode_single_byte() {
        assert_eq!(encode_bytes(b"a", 76), b"YQ==\n");
    }

    #[test]
    fn test_encode_two_bytes() {
        assert_eq!(encode_bytes(b"ab", 76), b"YWI=\n");
    }

    #[test]
    fn test_encode_three_bytes() {
        assert_eq!(encode_bytes(b"abc", 76), b"YWJj\n");
    }

    #[test]
    fn test_encode_four_bytes() {
        assert_eq!(encode_bytes(b"abcd", 76), b"YWJjZA==\n");
    }

    #[test]
    fn test_encode_wrap_default() {
        // A long string that wraps at 76 columns
        let input = b"Hello World This Is A Long String For Testing Wrapping Behavior In Base64";
        let result = encode_bytes(input, 76);
        let result_str = std::str::from_utf8(&result).unwrap();
        let lines: Vec<&str> = result_str.trim_end_matches('\n').split('\n').collect();
        assert_eq!(lines[0].len(), 76);
        assert!(lines[1].len() <= 76);
    }

    #[test]
    fn test_encode_no_wrap() {
        let input = b"Hello World This Is A Long String For Testing Wrapping Behavior In Base64";
        let result = encode_bytes(input, 0);
        let result_str = std::str::from_utf8(&result).unwrap();
        // -w 0: no wrapping, no trailing newline (matches GNU behavior)
        assert!(!result_str.contains('\n'));
    }

    #[test]
    fn test_encode_wrap_20() {
        let input = b"Hello World";
        let result = encode_bytes(input, 20);
        assert_eq!(&result, b"SGVsbG8gV29ybGQ=\n");
    }

    // ===== DECODING TESTS =====

    #[test]
    fn test_decode_empty() {
        assert_eq!(decode_bytes(b"", false).unwrap(), b"");
    }

    #[test]
    fn test_decode_hello() {
        assert_eq!(
            decode_bytes(b"SGVsbG8=", false).unwrap(),
            b"Hello"
        );
    }

    #[test]
    fn test_decode_with_newlines() {
        // GNU base64 decode accepts newlines in input
        assert_eq!(
            decode_bytes(b"SGVs\nbG8=\n", false).unwrap(),
            b"Hello"
        );
    }

    #[test]
    fn test_decode_ignore_garbage() {
        assert_eq!(
            decode_bytes(b"SGVs!!bG8=", true).unwrap(),
            b"Hello"
        );
    }

    #[test]
    fn test_decode_invalid_without_ignore() {
        assert!(decode_bytes(b"SGVs!!bG8=", false).is_err());
    }

    // ===== ROUNDTRIP TESTS =====

    #[test]
    fn test_roundtrip_empty() {
        let encoded = encode_bytes(b"", 76);
        if !encoded.is_empty() {
            let decoded = decode_bytes(&encoded, false).unwrap();
            assert_eq!(decoded, b"");
        }
    }

    #[test]
    fn test_roundtrip_binary() {
        let input: Vec<u8> = (0..=255).collect();
        let encoded = encode_bytes(&input, 76);
        let decoded = decode_bytes(&encoded, false).unwrap();
        assert_eq!(decoded, input);
    }

    #[test]
    fn test_roundtrip_large() {
        let input: Vec<u8> = (0..10000).map(|i| (i % 256) as u8).collect();
        let encoded = encode_bytes(&input, 76);
        let decoded = decode_bytes(&encoded, false).unwrap();
        assert_eq!(decoded, input);
    }

    #[test]
    fn test_roundtrip_no_wrap() {
        // -w 0 output has no trailing newline; decode must handle that
        let input: Vec<u8> = (0..1000).map(|i| (i % 256) as u8).collect();
        let encoded = encode_bytes(&input, 0);
        assert!(!encoded.ends_with(b"\n"), "no-wrap should not have trailing newline");
        let decoded = decode_bytes(&encoded, false).unwrap();
        assert_eq!(decoded, input);
    }

    // ===== GNU COMPATIBILITY TESTS =====

    #[test]
    fn test_encode_wrap_exact_boundary() {
        // Input that produces exactly 76 chars of base64 (57 bytes → 76 base64 chars)
        let input: Vec<u8> = (0..57).collect();
        let result = encode_bytes(&input, 76);
        let result_str = std::str::from_utf8(&result).unwrap();
        // Should be exactly one line of 76 chars + newline
        assert_eq!(result_str.len(), 77); // 76 chars + \n
        assert!(result_str.ends_with('\n'));
    }

    #[test]
    fn test_encode_wrap_just_over_boundary() {
        // 58 bytes → 80 base64 chars → wraps to two lines
        let input: Vec<u8> = (0..58).collect();
        let result = encode_bytes(&input, 76);
        let result_str = std::str::from_utf8(&result).unwrap();
        let lines: Vec<&str> = result_str.trim_end_matches('\n').split('\n').collect();
        assert_eq!(lines.len(), 2);
        assert_eq!(lines[0].len(), 76);
    }

    #[test]
    fn test_decode_no_padding() {
        // "YWJj" decodes to "abc" (no padding needed, 4 base64 chars → 3 bytes)
        assert_eq!(decode_bytes(b"YWJj", false).unwrap(), b"abc");
    }

    #[test]
    fn test_decode_with_whitespace_variants() {
        // Should handle \r\n, tabs, spaces in encoded data
        assert_eq!(
            decode_bytes(b"YWJj\r\nZGVm\n", false).unwrap(),
            b"abcdef"
        );
    }

    #[test]
    fn test_encode_all_byte_values() {
        // All 256 byte values
        let input: Vec<u8> = (0..=255).collect();
        let encoded = encode_bytes(&input, 76);
        let decoded = decode_bytes(&encoded, false).unwrap();
        assert_eq!(decoded, input);
    }

    #[test]
    fn test_decode_ignore_garbage_various() {
        // Various garbage characters should be stripped with -i
        assert_eq!(
            decode_bytes(b"Y!!!W@@@J###j$$$", true).unwrap(),
            b"abc"
        );
    }

    #[test]
    fn test_encode_stream_no_wrap() {
        let input = b"Hello World";
        let mut reader = &input[..];
        let mut output = Vec::new();
        encode_stream(&mut reader, 0, &mut output).unwrap();
        // -w 0: no trailing newline
        assert_eq!(output, b"SGVsbG8gV29ybGQ=");
    }

    // ===== STREAM TESTS =====

    #[test]
    fn test_encode_stream_basic() {
        let input = b"Hello World";
        let mut reader = &input[..];
        let mut output = Vec::new();
        encode_stream(&mut reader, 76, &mut output).unwrap();
        assert_eq!(output, b"SGVsbG8gV29ybGQ=\n");
    }

    #[test]
    fn test_decode_stream_basic() {
        let input = b"SGVsbG8gV29ybGQ=\n";
        let mut reader = &input[..];
        let mut output = Vec::new();
        decode_stream(&mut reader, false, &mut output).unwrap();
        assert_eq!(output, b"Hello World");
    }
}
