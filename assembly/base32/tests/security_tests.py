#!/usr/bin/env python3
"""Security tests for fbase32 — uses shared framework."""
import sys, os, random, string, base64
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', '..', 'tests'))
from security_framework import SecurityTestFramework

config = {
    'tool_name': 'base32',
    'bin_name': 'fbase32',
    'gnu_path': '/usr/bin/base32',
    'bss_size': 65536,
    'max_binary_size': 30000,
    'test_args': [],
    'test_stdin': b'hello world\n',
}

def tool_specific_tests(fw):
    """13. Tool-specific: base32 encode/decode tests."""
    fw.log("\n=== Base32-Specific Tests ===")

    # Known test vectors (RFC 4648)
    vectors = [
        (b"", b""),
        (b"f", b"MY======\n"),
        (b"fo", b"MZXQ====\n"),
        (b"foo", b"MZXW6===\n"),
        (b"foob", b"MZXW6YQ=\n"),
        (b"fooba", b"MZXW6YTB\n"),
        (b"foobar", b"MZXW6YTBOI======\n"),
    ]
    for input_data, expected in vectors:
        rc_a, out_a, _ = fw.run_asm([], stdin_data=input_data)
        rc_g, out_g, _ = fw.run_gnu([], stdin_data=input_data)
        if len(input_data) > 0:
            fw.report_result(out_a == out_g, f"base32: encode '{input_data.decode()}' matches GNU")
        else:
            fw.report_result(rc_a == rc_g, "base32: empty input exit code matches GNU")

    # Decode test vectors
    decode_vectors = [
        (b"MY======\n", b"f"),
        (b"MZXQ====\n", b"fo"),
        (b"MZXW6===\n", b"foo"),
        (b"MZXW6YQ=\n", b"foob"),
        (b"MZXW6YTB\n", b"fooba"),
        (b"MZXW6YTBOI======\n", b"foobar"),
    ]
    for encoded, expected in decode_vectors:
        rc_a, out_a, _ = fw.run_asm(["-d"], stdin_data=encoded)
        rc_g, out_g, _ = fw.run_gnu(["-d"], stdin_data=encoded)
        fw.report_result(out_a == out_g, f"base32: decode '{encoded.strip().decode()}' matches GNU")

    # Encode/decode roundtrip
    for size in [0, 1, 2, 3, 4, 5, 10, 100, 1000, 10000]:
        data = os.urandom(size) if size > 0 else b""
        rc1, encoded, _ = fw.run_asm([], stdin_data=data)
        if rc1 == 0 and len(encoded) > 0:
            rc2, decoded, _ = fw.run_asm(["-d"], stdin_data=encoded)
            fw.report_result(decoded == data, f"base32: roundtrip {size} bytes")
        elif size == 0:
            fw.report_result(True, f"base32: roundtrip 0 bytes (empty)")
        else:
            fw.report_result(False, f"base32: roundtrip {size} bytes (encode failed)")

    # Decode invalid base32
    rc_a, out_a, err_a = fw.run_asm(["-d"], stdin_data=b"!!!invalid!!!\n")
    fw.report_result(rc_a != 0, "base32: decode invalid base32 returns error")

    # Large file roundtrip
    large_data = os.urandom(1024 * 1024)
    rc1, encoded, _ = fw.run_asm([], stdin_data=large_data, timeout=10)
    if rc1 == 0:
        rc2, decoded, _ = fw.run_asm(["-d"], stdin_data=encoded, timeout=10)
        fw.report_result(decoded == large_data, "base32: 1MB roundtrip")
    else:
        fw.report_result(False, "base32: 1MB encode failed")

    # Binary data roundtrip (all 256 byte values)
    all_bytes = bytes(range(256))
    rc1, encoded, _ = fw.run_asm([], stdin_data=all_bytes)
    if rc1 == 0:
        rc2, decoded, _ = fw.run_asm(["-d"], stdin_data=encoded)
        fw.report_result(decoded == all_bytes, "base32: all 256 byte values roundtrip")
    else:
        fw.report_result(False, "base32: all 256 bytes encode failed")

    # Line wrapping at 76 chars
    data = b"A" * 100
    rc_a, out_a, _ = fw.run_asm([], stdin_data=data)
    rc_g, out_g, _ = fw.run_gnu([], stdin_data=data)
    fw.report_result(out_a == out_g, "base32: line wrapping matches GNU")
    if rc_a == 0:
        lines = out_a.split(b"\n")
        max_line = max(len(l) for l in lines)
        fw.report_result(max_line <= 76, f"base32: max line length {max_line} <= 76")

    # Compare with GNU on various sizes
    for size in [1, 3, 5, 10, 57, 76, 100, 256, 1024]:
        data = os.urandom(size)
        rc_a, out_a, _ = fw.run_asm([], stdin_data=data)
        rc_g, out_g, _ = fw.run_gnu([], stdin_data=data)
        fw.report_result(out_a == out_g, f"base32: encode {size} random bytes matches GNU")

    # Empty input encode
    rc_a, out_a, _ = fw.run_asm([], stdin_data=b"")
    rc_g, out_g, _ = fw.run_gnu([], stdin_data=b"")
    fw.report_result(out_a == out_g, "base32: empty input encode matches GNU")

    # --help/--version
    rc_a, out_a, _ = fw.run_asm(["--help"])
    fw.report_result(rc_a == 0 and len(out_a) > 0, "base32: --help works")

    rc_a, out_a, _ = fw.run_asm(["--version"])
    fw.report_result(rc_a == 0 and len(out_a) > 0, "base32: --version works")

    # Verify encode output matches Python base32 library
    test_data = b"The quick brown fox jumps over the lazy dog"
    expected = base64.b32encode(test_data).decode() + "\n"
    rc_a, out_a, _ = fw.run_asm([], stdin_data=test_data)
    fw.report_result(out_a.decode().strip() == expected.strip(),
                     "base32: encode matches Python base32 lib")

if __name__ == '__main__':
    fw = SecurityTestFramework(config)
    fw.run_all(tool_specific_fn=tool_specific_tests)
