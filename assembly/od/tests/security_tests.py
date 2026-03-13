#!/usr/bin/env python3
"""security_tests.py — Security & memory safety tests for fod (assembly od).

Uses the shared SecurityTestFramework for categories 1-12,
with od-specific tests in category 13.
"""

import os
import sys
import tempfile

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', '..', 'tests'))
from security_framework import SecurityTestFramework

config = {
    'tool_name': 'od',
    'bin_name': 'fod',
    'gnu_path': '/usr/bin/od',
    'bss_size': 65536,
    'max_binary_size': 100000,
    'test_args': [],
    'test_stdin': b'hello world\n',
    'timeout': 5,
}


def tool_specific_tests(fw):
    """Category 13: od-specific tests."""
    fw.log("\n=== Od-Specific Tests ===")

    # Default octal dump
    data = b"AB"
    rc_a, out_a, _ = fw.run_asm([], stdin_data=data)
    rc_g, out_g, _ = fw.run_gnu([], stdin_data=data)
    fw.report_result(out_a == out_g, "od: default octal dump matches GNU")

    # -A d (decimal addresses)
    data = b"hello world\n"
    rc_a, out_a, _ = fw.run_asm(["-A", "d"], stdin_data=data)
    rc_g, out_g, _ = fw.run_gnu(["-A", "d"], stdin_data=data)
    fw.report_result(out_a == out_g, "od: -A d (decimal addresses) matches GNU")

    # -A o (octal addresses, default)
    rc_a, out_a, _ = fw.run_asm(["-A", "o"], stdin_data=data)
    rc_g, out_g, _ = fw.run_gnu(["-A", "o"], stdin_data=data)
    fw.report_result(out_a == out_g, "od: -A o (octal addresses) matches GNU")

    # -A x (hex addresses)
    rc_a, out_a, _ = fw.run_asm(["-A", "x"], stdin_data=data)
    rc_g, out_g, _ = fw.run_gnu(["-A", "x"], stdin_data=data)
    fw.report_result(out_a == out_g, "od: -A x (hex addresses) matches GNU")

    # -A n (no addresses)
    rc_a, out_a, _ = fw.run_asm(["-A", "n"], stdin_data=data)
    rc_g, out_g, _ = fw.run_gnu(["-A", "n"], stdin_data=data)
    fw.report_result(out_a == out_g, "od: -A n (no addresses) matches GNU")

    # -t x1 (hex bytes)
    data = b"\x00\x01\x02\x0a\xff"
    rc_a, out_a, _ = fw.run_asm(["-t", "x1"], stdin_data=data)
    rc_g, out_g, _ = fw.run_gnu(["-t", "x1"], stdin_data=data)
    fw.report_result(out_a == out_g, "od: -t x1 (hex bytes) matches GNU")

    # -t x2 (hex 2-byte)
    data = b"\x00\x01\x02\x03\x04\x05"
    rc_a, out_a, _ = fw.run_asm(["-t", "x2"], stdin_data=data)
    rc_g, out_g, _ = fw.run_gnu(["-t", "x2"], stdin_data=data)
    fw.report_result(out_a == out_g, "od: -t x2 (hex 2-byte) matches GNU")

    # -t o1 (octal bytes)
    data = b"hello"
    rc_a, out_a, _ = fw.run_asm(["-t", "o1"], stdin_data=data)
    rc_g, out_g, _ = fw.run_gnu(["-t", "o1"], stdin_data=data)
    fw.report_result(out_a == out_g, "od: -t o1 (octal bytes) matches GNU")

    # -t d1 (decimal bytes)
    data = b"AB\xff"
    rc_a, out_a, _ = fw.run_asm(["-t", "d1"], stdin_data=data)
    rc_g, out_g, _ = fw.run_gnu(["-t", "d1"], stdin_data=data)
    fw.report_result(out_a == out_g, "od: -t d1 (decimal bytes) matches GNU")

    # -t u1 (unsigned decimal bytes)
    data = b"\x00\x7f\x80\xff"
    rc_a, out_a, _ = fw.run_asm(["-t", "u1"], stdin_data=data)
    rc_g, out_g, _ = fw.run_gnu(["-t", "u1"], stdin_data=data)
    fw.report_result(out_a == out_g, "od: -t u1 (unsigned decimal bytes) matches GNU")

    # -t a (named characters)
    data = b"\x00\x01\x07\x08\x09\x0a\x0d\x1b\x7f"
    rc_a, out_a, _ = fw.run_asm(["-t", "a"], stdin_data=data)
    rc_g, out_g, _ = fw.run_gnu(["-t", "a"], stdin_data=data)
    fw.report_result(out_a == out_g, "od: -t a (named chars) matches GNU")

    # -t c (C-style characters)
    data = b"hello\tworld\n\0"
    rc_a, out_a, _ = fw.run_asm(["-t", "c"], stdin_data=data)
    rc_g, out_g, _ = fw.run_gnu(["-t", "c"], stdin_data=data)
    fw.report_result(out_a == out_g, "od: -t c (C-style chars) matches GNU")

    # Short flags: -b, -c, -d, -x, -o
    for flag, desc in [("-b", "octal bytes"), ("-c", "C chars"), ("-d", "unsigned short"),
                       ("-x", "hex short"), ("-o", "octal short")]:
        data = b"\xde\xad\xbe\xef"
        rc_a, out_a, _ = fw.run_asm([flag], stdin_data=data)
        rc_g, out_g, _ = fw.run_gnu([flag], stdin_data=data)
        fw.report_result(out_a == out_g, f"od: {flag} ({desc}) matches GNU")

    # -j N (skip bytes)
    data = b"ABCDEFGHhello\n"
    rc_a, out_a, _ = fw.run_asm(["-j", "8"], stdin_data=data)
    rc_g, out_g, _ = fw.run_gnu(["-j", "8"], stdin_data=data)
    fw.report_result(out_a == out_g, "od: -j 8 (skip bytes) matches GNU")

    # -N N (limit bytes)
    data = b"hello world this is a long string\n"
    rc_a, out_a, _ = fw.run_asm(["-N", "5"], stdin_data=data)
    rc_g, out_g, _ = fw.run_gnu(["-N", "5"], stdin_data=data)
    fw.report_result(out_a == out_g, "od: -N 5 (limit bytes) matches GNU")

    # -j and -N combined
    data = b"ABCDEFGHIJKLhello world\n"
    rc_a, out_a, _ = fw.run_asm(["-j", "4", "-N", "8"], stdin_data=data)
    rc_g, out_g, _ = fw.run_gnu(["-j", "4", "-N", "8"], stdin_data=data)
    fw.report_result(out_a == out_g, "od: -j 4 -N 8 combined matches GNU")

    # -w N (output width)
    data = bytes(range(64))
    rc_a, out_a, _ = fw.run_asm(["-w16", "-t", "x1"], stdin_data=data)
    rc_g, out_g, _ = fw.run_gnu(["-w16", "-t", "x1"], stdin_data=data)
    fw.report_result(out_a == out_g, "od: -w16 (output width) matches GNU")

    # -v (verbose, no duplicate suppression)
    data = b"\x00" * 64
    rc_a, out_a, _ = fw.run_asm(["-v"], stdin_data=data)
    rc_g, out_g, _ = fw.run_gnu(["-v"], stdin_data=data)
    fw.report_result(out_a == out_g, "od: -v (verbose) matches GNU")

    # Without -v (duplicate suppression with *)
    rc_a, out_a, _ = fw.run_asm([], stdin_data=data)
    rc_g, out_g, _ = fw.run_gnu([], stdin_data=data)
    fw.report_result(out_a == out_g, "od: duplicate suppression (*) matches GNU")

    # Empty input
    rc_a, out_a, _ = fw.run_asm([], stdin_data=b"")
    rc_g, out_g, _ = fw.run_gnu([], stdin_data=b"")
    fw.report_result(out_a == out_g, "od: empty input matches GNU")

    # Single byte
    data = b"\x42"
    rc_a, out_a, _ = fw.run_asm([], stdin_data=data)
    rc_g, out_g, _ = fw.run_gnu([], stdin_data=data)
    fw.report_result(out_a == out_g, "od: single byte matches GNU")

    # All 256 byte values
    data = bytes(range(256))
    rc_a, out_a, _ = fw.run_asm(["-t", "x1"], stdin_data=data)
    rc_g, out_g, _ = fw.run_gnu(["-t", "x1"], stdin_data=data)
    fw.report_result(out_a == out_g, "od: all 256 byte values matches GNU")

    # File argument
    with tempfile.NamedTemporaryFile(mode='wb', suffix='.bin', delete=False) as f:
        f.write(bytes(range(32)))
        tmpfile = f.name
    try:
        rc_a, out_a, _ = fw.run_asm([tmpfile])
        rc_g, out_g, _ = fw.run_gnu([tmpfile])
        fw.report_result(out_a == out_g, "od: file argument matches GNU")
    finally:
        os.unlink(tmpfile)

    # Stdin via -
    data = b"test data\n"
    rc_a, out_a, _ = fw.run_asm(["-"], stdin_data=data)
    rc_g, out_g, _ = fw.run_gnu(["-"], stdin_data=data)
    fw.report_result(out_a == out_g, "od: stdin via '-' matches GNU")

    # Large input
    large = bytes(range(256)) * 100
    rc_a, out_a, _ = fw.run_asm(["-t", "x1"], stdin_data=large, timeout=10)
    rc_g, out_g, _ = fw.run_gnu(["-t", "x1"], stdin_data=large, timeout=10)
    fw.report_result(out_a == out_g, "od: large input (25KB) matches GNU")

    # -t x4 (hex 4-byte words)
    data = b"\xde\xad\xbe\xef\xca\xfe\xba\xbe"
    rc_a, out_a, _ = fw.run_asm(["-t", "x4"], stdin_data=data)
    rc_g, out_g, _ = fw.run_gnu(["-t", "x4"], stdin_data=data)
    fw.report_result(out_a == out_g, "od: -t x4 (hex 4-byte) matches GNU")

    # Exactly 16 bytes (one full default line)
    data = bytes(range(16))
    rc_a, out_a, _ = fw.run_asm([], stdin_data=data)
    rc_g, out_g, _ = fw.run_gnu([], stdin_data=data)
    fw.report_result(out_a == out_g, "od: exactly 16 bytes matches GNU")

    # --help/--version
    rc_a, out_a, _ = fw.run_asm(["--help"])
    fw.report_result(rc_a == 0 and len(out_a) > 0, "od: --help works")

    rc_a, out_a, _ = fw.run_asm(["--version"])
    fw.report_result(rc_a == 0 and len(out_a) > 0, "od: --version works")


if __name__ == '__main__':
    fw = SecurityTestFramework(config)
    fw.run_all(tool_specific_fn=tool_specific_tests)
