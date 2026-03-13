#!/usr/bin/env python3
"""security_tests.py -- Security & memory safety tests for frev.

Uses shared SecurityTestFramework + tool-specific rev tests.
"""

import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', '..', 'tests'))
from security_framework import SecurityTestFramework


def tool_specific_tests(fw):
    """Category 13: rev-specific tests."""
    fw.log("\n=== 13. Tool-Specific: rev ===")

    # Basic reverse
    rc_a, out_a, _ = fw.run_asm([], stdin_data=b"hello\n")
    rc_g, out_g, _ = fw.run_gnu([], stdin_data=b"hello\n")
    fw.report_result(out_a == out_g, "rev: basic reverse matches GNU")
    fw.report_result(out_a == b"olleh\n", "rev: 'hello' -> 'olleh'")

    # Multiple lines
    data = b"abc\ndef\nghi\n"
    rc_a, out_a, _ = fw.run_asm([], stdin_data=data)
    rc_g, out_g, _ = fw.run_gnu([], stdin_data=data)
    fw.report_result(out_a == out_g, "rev: multiple lines matches GNU")

    # Empty input
    rc_a, out_a, _ = fw.run_asm([], stdin_data=b"")
    rc_g, out_g, _ = fw.run_gnu([], stdin_data=b"")
    fw.report_result(out_a == out_g, "rev: empty input matches GNU")

    # Empty lines preserved
    data = b"\n\nhello\n\n"
    rc_a, out_a, _ = fw.run_asm([], stdin_data=data)
    rc_g, out_g, _ = fw.run_gnu([], stdin_data=data)
    fw.report_result(out_a == out_g, "rev: empty lines preserved matches GNU")

    # Single character lines
    data = b"a\nb\nc\n"
    rc_a, out_a, _ = fw.run_asm([], stdin_data=data)
    rc_g, out_g, _ = fw.run_gnu([], stdin_data=data)
    fw.report_result(out_a == out_g, "rev: single char lines matches GNU")

    # Palindrome
    data = b"racecar\nmadam\n"
    rc_a, out_a, _ = fw.run_asm([], stdin_data=data)
    fw.report_result(out_a == b"racecar\nmadam\n", "rev: palindromes unchanged")

    # Spaces and tabs
    data = b"  hello  \n\tworld\t\n"
    rc_a, out_a, _ = fw.run_asm([], stdin_data=data)
    rc_g, out_g, _ = fw.run_gnu([], stdin_data=data)
    fw.report_result(out_a == out_g, "rev: spaces and tabs matches GNU")

    # Very long lines
    long_line = b"A" * 10000 + b"\n"
    rc_a, out_a, _ = fw.run_asm([], stdin_data=long_line)
    rc_g, out_g, _ = fw.run_gnu([], stdin_data=long_line)
    fw.report_result(out_a == out_g, "rev: very long line (10KB) matches GNU")

    # Roundtrip: rev | rev == original
    original = b"hello world\nfoo bar baz\n12345\n"
    rc1, mid, _ = fw.run_asm([], stdin_data=original)
    rc2, final, _ = fw.run_asm([], stdin_data=mid)
    fw.report_result(final == original, "rev: roundtrip rev|rev == original")

    # No trailing newline
    rc_a, out_a, _ = fw.run_asm([], stdin_data=b"hello")
    rc_g, out_g, _ = fw.run_gnu([], stdin_data=b"hello")
    fw.report_result(out_a == out_g, "rev: no trailing newline matches GNU")

    # Special characters
    data = b"!@#$%^&*()\n[]{}<>|\\~`\n"
    rc_a, out_a, _ = fw.run_asm([], stdin_data=data)
    rc_g, out_g, _ = fw.run_gnu([], stdin_data=data)
    fw.report_result(out_a == out_g, "rev: special characters matches GNU")

    # Numbers
    data = b"1234567890\n0987654321\n"
    rc_a, out_a, _ = fw.run_asm([], stdin_data=data)
    fw.report_result(out_a == b"0987654321\n1234567890\n", "rev: numbers reversed correctly")

    # Multibyte chars
    data = "caf\u00e9\n".encode('utf-8')
    rc_a, out_a, _ = fw.run_asm([], stdin_data=data)
    rc_g, out_g, _ = fw.run_gnu([], stdin_data=data)
    fw.report_result(out_a == out_g, "rev: multibyte chars matches GNU")

    # 26 single-char lines
    data = b"".join(f"{c}\n".encode() for c in "abcdefghijklmnopqrstuvwxyz")
    rc_a, out_a, _ = fw.run_asm([], stdin_data=data)
    rc_g, out_g, _ = fw.run_gnu([], stdin_data=data)
    fw.report_result(out_a == out_g, "rev: 26 single-char lines matches GNU")

    # CRLF
    crlf = b"hello\r\nworld\r\n"
    rc_a, out_a, _ = fw.run_asm([], stdin_data=crlf)
    rc_g, out_g, _ = fw.run_gnu([], stdin_data=crlf)
    fw.report_result(out_a == out_g, "rev: CRLF input matches GNU")

    # Large input
    large = b"".join(f"line{i:06d}\n".encode() for i in range(10000))
    rc_a, out_a, _ = fw.run_asm([], stdin_data=large, timeout=10)
    rc_g, out_g, _ = fw.run_gnu([], stdin_data=large, timeout=10)
    fw.report_result(out_a == out_g, "rev: large input (10K lines) matches GNU")

    # Binary data per line
    binary_line = bytes(range(1, 128)) + b"\n"
    rc_a, out_a, _ = fw.run_asm([], stdin_data=binary_line)
    rc_g, out_g, _ = fw.run_gnu([], stdin_data=binary_line)
    fw.report_result(out_a == out_g, "rev: binary data line matches GNU")


config = {
    'tool_name': 'rev',
    'bin_name': 'frev',
    'gnu_path': '/usr/bin/rev',
    'bss_size': 65536,
    'max_binary_size': 30000,
    'test_args': [],
    'test_stdin': b"hello\nworld\n",
    'timeout': 5,
}

if __name__ == '__main__':
    fw = SecurityTestFramework(config)
    fw.run_all(tool_specific_fn=tool_specific_tests)
