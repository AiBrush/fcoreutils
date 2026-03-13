#!/usr/bin/env python3
"""security_tests.py — Security & memory safety tests for fhead (assembly head).

Uses the shared SecurityTestFramework plus head-specific tests.
"""

import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', '..', 'tests'))
from security_framework import SecurityTestFramework

config = {
    'tool_name': 'head',
    'bin_name': 'fhead',
    'gnu_path': '/usr/bin/head',
    'bss_size': 65536,
    'max_binary_size': 30000,
    'test_args': [],
    'test_stdin': b'line1\nline2\nline3\nline4\nline5\n',
    'timeout': 5,
}


def tool_specific_tests(fw):
    """Category 13: head-specific tests."""
    fw.log("\n=== Head-Specific Tests ===")

    lines_20 = b"".join(f"line{i:03d}\n".encode() for i in range(20))
    lines_5 = b"".join(f"line{i:03d}\n".encode() for i in range(5))

    # Default 10 lines
    rc_a, out_a, _ = fw.run_asm([], stdin_data=lines_20)
    rc_g, out_g, _ = fw.run_gnu([], stdin_data=lines_20)
    fw.report_result(out_a == out_g, "head: default 10 lines matches GNU")

    # -n N
    for n in [1, 5, 10, 15, 20, 100]:
        rc_a, out_a, _ = fw.run_asm(["-n", str(n)], stdin_data=lines_20)
        rc_g, out_g, _ = fw.run_gnu(["-n", str(n)], stdin_data=lines_20)
        fw.report_result(out_a == out_g, f"head: -n {n} matches GNU")

    # -n 0
    rc_a, out_a, _ = fw.run_asm(["-n", "0"], stdin_data=lines_20)
    rc_g, out_g, _ = fw.run_gnu(["-n", "0"], stdin_data=lines_20)
    fw.report_result(out_a == out_g, "head: -n 0 matches GNU")

    # Fewer lines than requested
    rc_a, out_a, _ = fw.run_asm(["-n", "100"], stdin_data=lines_5)
    rc_g, out_g, _ = fw.run_gnu(["-n", "100"], stdin_data=lines_5)
    fw.report_result(out_a == out_g, "head: fewer lines than requested")

    # Empty input
    rc_a, out_a, _ = fw.run_asm([], stdin_data=b"")
    rc_g, out_g, _ = fw.run_gnu([], stdin_data=b"")
    fw.report_result(out_a == out_g, "head: empty input")

    # Single line, no trailing newline
    rc_a, out_a, _ = fw.run_asm([], stdin_data=b"no newline")
    rc_g, out_g, _ = fw.run_gnu([], stdin_data=b"no newline")
    fw.report_result(out_a == out_g, "head: single line no trailing newline")

    # Binary data preservation
    binary_data = bytes(range(256)) + b"\n" + bytes(range(256)) + b"\n"
    rc_a, out_a, _ = fw.run_asm(["-n", "1"], stdin_data=binary_data)
    rc_g, out_g, _ = fw.run_gnu(["-n", "1"], stdin_data=binary_data)
    fw.report_result(out_a == out_g, "head: binary data preservation")

    # -c N (byte count) if supported
    rc_a, out_a, _ = fw.run_asm(["-c", "10"], stdin_data=b"hello world this is a test\n")
    rc_g, out_g, _ = fw.run_gnu(["-c", "10"], stdin_data=b"hello world this is a test\n")
    if rc_a == 0 and rc_g == 0:
        fw.report_result(out_a == out_g, "head: -c 10 bytes matches GNU")
    else:
        fw.skip_test("head: -c byte mode", "not supported")

    # CRLF line counting
    crlf_data = b"line1\r\nline2\r\nline3\r\n"
    rc_a, out_a, _ = fw.run_asm(["-n", "2"], stdin_data=crlf_data)
    rc_g, out_g, _ = fw.run_gnu(["-n", "2"], stdin_data=crlf_data)
    fw.report_result(out_a == out_g, "head: CRLF line counting matches GNU")

    # Very large line count (should not hang)
    data = b"x\n" * 10
    rc_a, out_a, _ = fw.run_asm(["-n", "999999"], stdin_data=data)
    fw.report_result(rc_a < 128 and out_a == data, "head: -n 999999 with small input")

    # --help / --version
    rc_a, out_a, _ = fw.run_asm(["--help"])
    fw.report_result(rc_a == 0 and len(out_a) > 0, "head: --help works")

    rc_a, out_a, _ = fw.run_asm(["--version"])
    fw.report_result(rc_a == 0 and len(out_a) > 0, "head: --version works")

    # Large input default head
    large = b"".join(f"L{i:08d}\n".encode() for i in range(10000))
    rc_a, out_a, _ = fw.run_asm([], stdin_data=large)
    rc_g, out_g, _ = fw.run_gnu([], stdin_data=large)
    fw.report_result(out_a == out_g, "head: large input (10K lines) default 10")


if __name__ == '__main__':
    fw = SecurityTestFramework(config)
    fw.run_all(tool_specific_fn=tool_specific_tests)
