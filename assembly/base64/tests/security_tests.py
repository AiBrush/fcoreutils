#!/usr/bin/env python3
"""Security tests for fbase64 — uses shared framework."""
import sys, os, random, string, base64 as b64lib
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', '..', 'tests'))
from security_framework import SecurityTestFramework

config = {
    'tool_name': 'base64',
    'bin_name': 'fbase64',
    'gnu_path': '/usr/bin/base64',
    'bss_size': 65536,
    'max_binary_size': 30000,
    'test_args': [],
    'test_stdin': b'hello world\n',
}

def tool_specific_tests(fw):
    """13. Tool-specific: base64 encode/decode tests."""
    fw.log("\n=== Base64-Specific Tests ===")

    # Known test vectors (RFC 4648)
    vectors = [
        (b"", b""),
        (b"f", b"Zg==\n"),
        (b"fo", b"Zm8=\n"),
        (b"foo", b"Zm9v\n"),
        (b"foob", b"Zm9vYg==\n"),
        (b"fooba", b"Zm9vYmE=\n"),
        (b"foobar", b"Zm9vYmFy\n"),
    ]
    for input_data, expected in vectors:
        rc_a, out_a, _ = fw.run_asm([], stdin_data=input_data)
        rc_g, out_g, _ = fw.run_gnu([], stdin_data=input_data)
        if len(input_data) > 0:
            fw.report_result(out_a == out_g, f"base64: encode '{input_data.decode()}' matches GNU")
        else:
            fw.report_result(rc_a == rc_g, "base64: empty input exit code matches GNU")

    # Decode test vectors
    decode_vectors = [
        (b"Zg==\n", b"f"),
        (b"Zm8=\n", b"fo"),
        (b"Zm9v\n", b"foo"),
        (b"Zm9vYg==\n", b"foob"),
        (b"Zm9vYmE=\n", b"fooba"),
        (b"Zm9vYmFy\n", b"foobar"),
    ]
    for encoded, expected in decode_vectors:
        rc_a, out_a, _ = fw.run_asm(["-d"], stdin_data=encoded)
        rc_g, out_g, _ = fw.run_gnu(["-d"], stdin_data=encoded)
        fw.report_result(out_a == out_g, f"base64: decode '{encoded.strip().decode()}' matches GNU")

    # Encode/decode roundtrip
    for size in [0, 1, 2, 3, 10, 100, 1000, 10000]:
        data = os.urandom(size) if size > 0 else b""
        rc1, encoded, _ = fw.run_asm([], stdin_data=data)
        if rc1 == 0 and len(encoded) > 0:
            rc2, decoded, _ = fw.run_asm(["-d"], stdin_data=encoded)
            fw.report_result(decoded == data, f"base64: roundtrip {size} bytes")
        elif size == 0:
            fw.report_result(True, f"base64: roundtrip 0 bytes (empty)")
        else:
            fw.report_result(False, f"base64: roundtrip {size} bytes (encode failed)")

    # Decode invalid base64
    rc_a, out_a, err_a = fw.run_asm(["-d"], stdin_data=b"!!!invalid!!!\n")
    fw.report_result(rc_a != 0, "base64: decode invalid base64 returns error")

    # Large file roundtrip
    large_data = os.urandom(1024 * 1024)
    rc1, encoded, _ = fw.run_asm([], stdin_data=large_data, timeout=10)
    if rc1 == 0:
        rc2, decoded, _ = fw.run_asm(["-d"], stdin_data=encoded, timeout=10)
        fw.report_result(decoded == large_data, "base64: 1MB roundtrip")
    else:
        fw.report_result(False, "base64: 1MB encode failed")

    # Binary data roundtrip (all 256 byte values)
    all_bytes = bytes(range(256))
    rc1, encoded, _ = fw.run_asm([], stdin_data=all_bytes)
    if rc1 == 0:
        rc2, decoded, _ = fw.run_asm(["-d"], stdin_data=encoded)
        fw.report_result(decoded == all_bytes, "base64: all 256 byte values roundtrip")
    else:
        fw.report_result(False, "base64: all 256 bytes encode failed")

    # Line wrapping at 76 chars
    data = b"A" * 100
    rc_a, out_a, _ = fw.run_asm([], stdin_data=data)
    rc_g, out_g, _ = fw.run_gnu([], stdin_data=data)
    fw.report_result(out_a == out_g, "base64: line wrapping matches GNU")
    if rc_a == 0:
        lines = out_a.split(b"\n")
        max_line = max(len(l) for l in lines)
        fw.report_result(max_line <= 76, f"base64: max line length {max_line} <= 76")

    # Compare with GNU on various sizes
    for size in [1, 3, 57, 76, 100, 256, 1024]:
        data = os.urandom(size)
        rc_a, out_a, _ = fw.run_asm([], stdin_data=data)
        rc_g, out_g, _ = fw.run_gnu([], stdin_data=data)
        fw.report_result(out_a == out_g, f"base64: encode {size} random bytes matches GNU")

    # Decode with whitespace
    encoded = b"S G V s\nbG 8 =\n"
    rc_a, out_a, _ = fw.run_asm(["-d"], stdin_data=encoded)
    fw.report_result(rc_a < 128, "base64: decode with spaces no crash")

    # Empty input encode
    rc_a, out_a, _ = fw.run_asm([], stdin_data=b"")
    rc_g, out_g, _ = fw.run_gnu([], stdin_data=b"")
    fw.report_result(out_a == out_g, "base64: empty input encode matches GNU")

    # --help/--version
    rc_a, out_a, _ = fw.run_asm(["--help"])
    fw.report_result(rc_a == 0 and len(out_a) > 0, "base64: --help works")

    rc_a, out_a, _ = fw.run_asm(["--version"])
    fw.report_result(rc_a == 0 and len(out_a) > 0, "base64: --version works")

    # Verify encode output matches Python base64 library
    test_data = b"The quick brown fox jumps over the lazy dog"
    expected = b64lib.b64encode(test_data).decode() + "\n"
    rc_a, out_a, _ = fw.run_asm([], stdin_data=test_data)
    fw.report_result(out_a.decode().strip() == expected.strip(),
                     "base64: encode matches Python base64 lib")

if __name__ == '__main__':
    fw = SecurityTestFramework(config)
    fw.run_all(tool_specific_fn=tool_specific_tests)
