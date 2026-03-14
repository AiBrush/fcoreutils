#!/usr/bin/env python3
"""security_tests.py -- Security & memory safety tests for ftac."""

import sys
import os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', '..', 'tests'))
from security_framework import SecurityTestFramework

config = {
    'tool_name': 'tac',
    'bin_name': 'ftac',
    'gnu_path': '/usr/bin/tac',
    'bss_size': 65536,
    'max_binary_size': 30000,
    'test_args': [],
    'test_stdin': b'line1\nline2\nline3\n',
    'timeout': 5,
}


def tool_specific_tests(fw):
    """13. Tool-specific: tac line reversal behavior."""
    fw.log("\n=== Tool-Specific: tac ===")

    # Basic reverse
    data = b"line1\nline2\nline3\n"
    rc_a, out_a, _ = fw.run_asm([], stdin_data=data)
    rc_g, out_g, _ = fw.run_gnu([], stdin_data=data)
    fw.report_result(out_a == out_g, "tac: basic reverse matches GNU")

    # Single line
    rc_a, out_a, _ = fw.run_asm([], stdin_data=b"single\n")
    rc_g, out_g, _ = fw.run_gnu([], stdin_data=b"single\n")
    fw.report_result(out_a == out_g, "tac: single line matches GNU")

    # Empty input
    rc_a, out_a, _ = fw.run_asm([], stdin_data=b"")
    rc_g, out_g, _ = fw.run_gnu([], stdin_data=b"")
    fw.report_result(out_a == out_g, "tac: empty input matches GNU")

    # No trailing newline
    rc_a, out_a, _ = fw.run_asm([], stdin_data=b"no\nnewline")
    rc_g, out_g, _ = fw.run_gnu([], stdin_data=b"no\nnewline")
    fw.report_result(out_a == out_g, "tac: no trailing newline matches GNU")

    # Many lines
    many = b"".join(f"L{i:05d}\n".encode() for i in range(100))
    rc_a, out_a, _ = fw.run_asm([], stdin_data=many)
    rc_g, out_g, _ = fw.run_gnu([], stdin_data=many)
    fw.report_result(out_a == out_g, "tac: 100 lines matches GNU")

    # Special chars
    special = b"hello world\n\ttabbed\n  spaced  \n!@#$%^&*()\n"
    rc_a, out_a, _ = fw.run_asm([], stdin_data=special)
    rc_g, out_g, _ = fw.run_gnu([], stdin_data=special)
    fw.report_result(out_a == out_g, "tac: special characters matches GNU")

    # Empty lines
    empty_lines = b"\n\n\nfoo\n\nbar\n\n"
    rc_a, out_a, _ = fw.run_asm([], stdin_data=empty_lines)
    rc_g, out_g, _ = fw.run_gnu([], stdin_data=empty_lines)
    fw.report_result(out_a == out_g, "tac: empty lines matches GNU")

    # Very long lines
    long_data = (b"A" * 10000 + b"\n") * 3
    rc_a, out_a, _ = fw.run_asm([], stdin_data=long_data)
    rc_g, out_g, _ = fw.run_gnu([], stdin_data=long_data)
    fw.report_result(out_a == out_g, "tac: very long lines (10KB each) matches GNU")

    # Roundtrip: tac | tac == original
    original = b"alpha\nbeta\ngamma\ndelta\nepsilon\n"
    rc1, mid, _ = fw.run_asm([], stdin_data=original)
    rc2, final, _ = fw.run_asm([], stdin_data=mid)
    fw.report_result(final == original, "tac: roundtrip tac|tac == original")

    # Embedded special bytes
    special_bytes = b"\x01line1\x02\n\x03line2\x04\n\x05line3\x06\n"
    rc_a, out_a, _ = fw.run_asm([], stdin_data=special_bytes)
    rc_g, out_g, _ = fw.run_gnu([], stdin_data=special_bytes)
    fw.report_result(out_a == out_g, "tac: embedded special bytes matches GNU")

    # CRLF
    crlf = b"one\r\ntwo\r\nthree\r\n"
    rc_a, out_a, _ = fw.run_asm([], stdin_data=crlf)
    rc_g, out_g, _ = fw.run_gnu([], stdin_data=crlf)
    fw.report_result(out_a == out_g, "tac: CRLF input matches GNU")

    # Large input
    large = b"".join(f"L{i:08d}\n".encode() for i in range(10000))
    rc_a, out_a, _ = fw.run_asm([], stdin_data=large, timeout=10)
    rc_g, out_g, _ = fw.run_gnu([], stdin_data=large, timeout=10)
    fw.report_result(out_a == out_g, "tac: large input (10K lines) matches GNU")

    # Verify line order
    data = b"1\n2\n3\n4\n5\n"
    rc, out, _ = fw.run_asm([], stdin_data=data)
    fw.report_result(out == b"5\n4\n3\n2\n1\n", "tac: line order is reversed correctly")

    # --help/--version
    rc, out, _ = fw.run_asm(["--help"])
    fw.report_result(rc == 0 and len(out) > 0, "tac: --help works")

    rc, out, _ = fw.run_asm(["--version"])
    fw.report_result(rc == 0 and len(out) > 0, "tac: --version works")


if __name__ == '__main__':
    fw = SecurityTestFramework(config)
    fw.run_all(tool_specific_fn=tool_specific_tests)
