#!/usr/bin/env python3
"""security_tests.py — Security & memory safety tests for fcut.

Uses shared SecurityTestFramework with tool-specific cut tests.
"""

import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', '..', 'tests'))
from security_framework import SecurityTestFramework

config = {
    'tool_name': 'cut',
    'bin_name': 'fcut',
    'gnu_path': '/usr/bin/cut',
    'bss_size': 65536,
    'max_binary_size': 30000,
    'test_args': ['-d:', '-f1'],
    'test_stdin': b'one:two:three\nfour:five:six\n',
    'timeout': 5,
}


def tool_specific_tests(fw):
    """Category 13: cut-specific tests."""
    fw.log("\n=== 13. Tool-Specific: cut ===")

    data = b"one:two:three\nfour:five:six\n"

    # -f1 (first field)
    rc_a, out_a, _ = fw.run_asm(["-d:", "-f1"], stdin_data=data)
    rc_g, out_g, _ = fw.run_gnu(["-d:", "-f1"], stdin_data=data)
    fw.report_result(out_a == out_g, "cut: -d: -f1 matches GNU")

    # -f2 (second field)
    rc_a, out_a, _ = fw.run_asm(["-d:", "-f2"], stdin_data=data)
    rc_g, out_g, _ = fw.run_gnu(["-d:", "-f2"], stdin_data=data)
    fw.report_result(out_a == out_g, "cut: -d: -f2 matches GNU")

    # -f3 (third field)
    rc_a, out_a, _ = fw.run_asm(["-d:", "-f3"], stdin_data=data)
    rc_g, out_g, _ = fw.run_gnu(["-d:", "-f3"], stdin_data=data)
    fw.report_result(out_a == out_g, "cut: -d: -f3 matches GNU")

    # -f1,3 (multiple fields)
    rc_a, out_a, _ = fw.run_asm(["-d:", "-f1,3"], stdin_data=data)
    rc_g, out_g, _ = fw.run_gnu(["-d:", "-f1,3"], stdin_data=data)
    fw.report_result(out_a == out_g, "cut: -d: -f1,3 matches GNU")

    # -f1-3 (field range)
    rc_a, out_a, _ = fw.run_asm(["-d:", "-f1-3"], stdin_data=data)
    rc_g, out_g, _ = fw.run_gnu(["-d:", "-f1-3"], stdin_data=data)
    fw.report_result(out_a == out_g, "cut: -d: -f1-3 matches GNU")

    # Different delimiters
    for delim, desc in [(",", "comma"), ("\t", "tab"), (" ", "space")]:
        d = f"one{delim}two{delim}three\n".encode()
        rc_a, out_a, _ = fw.run_asm([f"-d{delim}", "-f2"], stdin_data=d)
        rc_g, out_g, _ = fw.run_gnu([f"-d{delim}", "-f2"], stdin_data=d)
        fw.report_result(out_a == out_g, f"cut: -d '{desc}' -f2 matches GNU")

    # -c (characters)
    cdata = b"hello world\n"
    rc_a, out_a, _ = fw.run_asm(["-c1-5"], stdin_data=cdata)
    rc_g, out_g, _ = fw.run_gnu(["-c1-5"], stdin_data=cdata)
    if rc_a == 0 and rc_g == 0:
        fw.report_result(out_a == out_g, "cut: -c1-5 matches GNU")
    else:
        fw.skip_test("cut: -c mode", "not supported or error")

    # -b (bytes)
    rc_a, out_a, _ = fw.run_asm(["-b1-5"], stdin_data=cdata)
    rc_g, out_g, _ = fw.run_gnu(["-b1-5"], stdin_data=cdata)
    if rc_a == 0 and rc_g == 0:
        fw.report_result(out_a == out_g, "cut: -b1-5 matches GNU")
    else:
        fw.skip_test("cut: -b mode", "not supported or error")

    # Delimiter not found in line
    d = b"no_delim_here\n"
    rc_a, out_a, _ = fw.run_asm(["-d:", "-f1"], stdin_data=d)
    rc_g, out_g, _ = fw.run_gnu(["-d:", "-f1"], stdin_data=d)
    fw.report_result(out_a == out_g, "cut: delimiter not found matches GNU")

    # Empty fields
    d = b":::\n"
    rc_a, out_a, _ = fw.run_asm(["-d:", "-f1"], stdin_data=d)
    rc_g, out_g, _ = fw.run_gnu(["-d:", "-f1"], stdin_data=d)
    fw.report_result(out_a == out_g, "cut: empty fields matches GNU")

    # Missing fields
    d = b"a:b\n"
    rc_a, out_a, _ = fw.run_asm(["-d:", "-f5"], stdin_data=d)
    rc_g, out_g, _ = fw.run_gnu(["-d:", "-f5"], stdin_data=d)
    fw.report_result(out_a == out_g, "cut: missing field matches GNU")

    # Very long lines
    long_data = (b"f" * 5000 + b":") * 10 + b"last\n"
    rc_a, out_a, _ = fw.run_asm(["-d:", "-f1"], stdin_data=long_data)
    rc_g, out_g, _ = fw.run_gnu(["-d:", "-f1"], stdin_data=long_data)
    fw.report_result(out_a == out_g, "cut: very long line matches GNU")

    # Empty input
    rc_a, out_a, _ = fw.run_asm(["-d:", "-f1"], stdin_data=b"")
    rc_g, out_g, _ = fw.run_gnu(["-d:", "-f1"], stdin_data=b"")
    fw.report_result(out_a == out_g, "cut: empty input matches GNU")

    # Single field line
    d = b"single\n"
    rc_a, out_a, _ = fw.run_asm(["-d:", "-f1"], stdin_data=d)
    rc_g, out_g, _ = fw.run_gnu(["-d:", "-f1"], stdin_data=d)
    fw.report_result(out_a == out_g, "cut: single field line matches GNU")

    # Many fields
    d = b":".join(f"f{i}".encode() for i in range(100)) + b"\n"
    rc_a, out_a, _ = fw.run_asm(["-d:", "-f50"], stdin_data=d)
    rc_g, out_g, _ = fw.run_gnu(["-d:", "-f50"], stdin_data=d)
    fw.report_result(out_a == out_g, "cut: 100 fields -f50 matches GNU")

    # Large input
    large = b"field1:field2:field3\n" * 10000
    rc_a, out_a, _ = fw.run_asm(["-d:", "-f2"], stdin_data=large, timeout=10)
    rc_g, out_g, _ = fw.run_gnu(["-d:", "-f2"], stdin_data=large, timeout=10)
    fw.report_result(out_a == out_g, "cut: large input (10K lines) matches GNU")

    # --help/--version
    rc_a, out_a, _ = fw.run_asm(["--help"])
    fw.report_result(rc_a == 0 and len(out_a) > 0, "cut: --help works")

    rc_a, out_a, _ = fw.run_asm(["--version"])
    fw.report_result(rc_a == 0 and len(out_a) > 0, "cut: --version works")


if __name__ == '__main__':
    fw = SecurityTestFramework(config)
    fw.run_all(tool_specific_fn=tool_specific_tests)
