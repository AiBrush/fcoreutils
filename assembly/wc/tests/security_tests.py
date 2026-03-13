#!/usr/bin/env python3
"""security_tests.py -- Security & memory safety tests for fwc.

Uses the shared SecurityTestFramework with tool-specific wc tests.
"""

import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', '..', 'tests'))
from security_framework import SecurityTestFramework

config = {
    'tool_name': 'wc',
    'bin_name': 'fwc',
    'gnu_path': '/usr/bin/wc',
    'bss_size': 65536,
    'max_binary_size': 40000,
    'test_args': [],
    'test_stdin': b'hello world\nfoo bar baz\n',
    'timeout': 5,
}


def tool_specific_tests(fw):
    """Category 13: wc-specific tests."""
    fw.log("\n=== Wc-Specific Tests ===")

    # Basic counting - compare with GNU
    test_data = b"hello world\nfoo bar baz\n"
    rc_a, out_a, _ = fw.run_asm([], stdin_data=test_data)
    rc_g, out_g, _ = fw.run_gnu([], stdin_data=test_data)
    fw.report_result(out_a == out_g, "wc: default output matches GNU")

    # Line count -l
    data = b"line1\nline2\nline3\n"
    rc_a, out_a, _ = fw.run_asm(["-l"], stdin_data=data)
    rc_g, out_g, _ = fw.run_gnu(["-l"], stdin_data=data)
    fw.report_result(out_a == out_g, "wc: -l line count matches GNU")

    # Word count -w
    data = b"one two three\nfour five\n"
    rc_a, out_a, _ = fw.run_asm(["-w"], stdin_data=data)
    rc_g, out_g, _ = fw.run_gnu(["-w"], stdin_data=data)
    fw.report_result(out_a == out_g, "wc: -w word count matches GNU")

    # Byte count -c
    data = b"hello world\n"
    rc_a, out_a, _ = fw.run_asm(["-c"], stdin_data=data)
    rc_g, out_g, _ = fw.run_gnu(["-c"], stdin_data=data)
    fw.report_result(out_a == out_g, "wc: -c byte count matches GNU")

    # Char count -m (if supported)
    rc_a, out_a, _ = fw.run_asm(["-m"], stdin_data=b"hello\n")
    rc_g, out_g, _ = fw.run_gnu(["-m"], stdin_data=b"hello\n")
    if rc_a == 0 and rc_g == 0:
        fw.report_result(out_a == out_g, "wc: -m char count matches GNU")
    else:
        fw.skip_test("wc: -m char count", "not supported")

    # Empty input
    rc_a, out_a, _ = fw.run_asm([], stdin_data=b"")
    rc_g, out_g, _ = fw.run_gnu([], stdin_data=b"")
    fw.report_result(out_a == out_g, "wc: empty input matches GNU")

    # No trailing newline
    rc_a, out_a, _ = fw.run_asm([], stdin_data=b"hello")
    rc_g, out_g, _ = fw.run_gnu([], stdin_data=b"hello")
    fw.report_result(out_a == out_g, "wc: no trailing newline matches GNU")

    # Only whitespace
    rc_a, out_a, _ = fw.run_asm([], stdin_data=b"   \n\t\t\n  \n")
    rc_g, out_g, _ = fw.run_gnu([], stdin_data=b"   \n\t\t\n  \n")
    fw.report_result(out_a == out_g, "wc: only whitespace matches GNU")

    # Only newlines
    rc_a, out_a, _ = fw.run_asm([], stdin_data=b"\n\n\n")
    rc_g, out_g, _ = fw.run_gnu([], stdin_data=b"\n\n\n")
    fw.report_result(out_a == out_g, "wc: only newlines matches GNU")

    # Binary data with nulls
    data = b"hello\x00world\x00\nfoo\x00bar\n"
    rc_a, out_a, _ = fw.run_asm([], stdin_data=data)
    rc_g, out_g, _ = fw.run_gnu([], stdin_data=data)
    fw.report_result(out_a == out_g, "wc: binary with nulls matches GNU")

    # Single word
    rc_a, out_a, _ = fw.run_asm([], stdin_data=b"word\n")
    rc_g, out_g, _ = fw.run_gnu([], stdin_data=b"word\n")
    fw.report_result(out_a == out_g, "wc: single word matches GNU")

    # Multiple spaces between words
    rc_a, out_a, _ = fw.run_asm([], stdin_data=b"hello    world\n")
    rc_g, out_g, _ = fw.run_gnu([], stdin_data=b"hello    world\n")
    fw.report_result(out_a == out_g, "wc: multiple spaces matches GNU")

    # Tab separated
    rc_a, out_a, _ = fw.run_asm([], stdin_data=b"hello\tworld\n")
    rc_g, out_g, _ = fw.run_gnu([], stdin_data=b"hello\tworld\n")
    fw.report_result(out_a == out_g, "wc: tab separated matches GNU")

    # Known exact counts
    data = b"one two three\nfour five six\n"
    rc_a, out_a, _ = fw.run_asm(["-l"], stdin_data=data)
    fw.report_result(b"2" in out_a, "wc: known 2 lines")

    rc_a, out_a, _ = fw.run_asm(["-w"], stdin_data=data)
    fw.report_result(b"6" in out_a, "wc: known 6 words")

    rc_a, out_a, _ = fw.run_asm(["-c"], stdin_data=data)
    fw.report_result(str(len(data)).encode() in out_a, f"wc: known {len(data)} bytes")

    # Very large input accuracy
    large_data = b"word " * 100000 + b"\n"
    rc_a, out_a, _ = fw.run_asm(["-w"], stdin_data=large_data, timeout=10)
    rc_g, out_g, _ = fw.run_gnu(["-w"], stdin_data=large_data, timeout=10)
    fw.report_result(out_a == out_g, "wc: large input word count matches GNU (100K words)")

    # Lots of lines
    many_lines = b"x\n" * 10000
    rc_a, out_a, _ = fw.run_asm(["-l"], stdin_data=many_lines)
    rc_g, out_g, _ = fw.run_gnu(["-l"], stdin_data=many_lines)
    fw.report_result(out_a == out_g, "wc: 10K lines count matches GNU")

    # Mixed whitespace
    mixed = b"  \t hello   world \t \n \t foo \t bar \n"
    rc_a, out_a, _ = fw.run_asm([], stdin_data=mixed)
    rc_g, out_g, _ = fw.run_gnu([], stdin_data=mixed)
    fw.report_result(out_a == out_g, "wc: mixed whitespace matches GNU")

    # Combined flags
    for flags in [["-l", "-w"], ["-w", "-c"], ["-l", "-w", "-c"]]:
        desc = " ".join(flags)
        rc_a, out_a, _ = fw.run_asm(flags, stdin_data=b"hello world\nfoo\n")
        rc_g, out_g, _ = fw.run_gnu(flags, stdin_data=b"hello world\nfoo\n")
        fw.report_result(out_a == out_g, f"wc: combined {desc} matches GNU")

    # --help/--version
    rc_a, out_a, _ = fw.run_asm(["--help"])
    fw.report_result(rc_a == 0 and len(out_a) > 0, "wc: --help works")

    rc_a, out_a, _ = fw.run_asm(["--version"])
    fw.report_result(rc_a == 0 and len(out_a) > 0, "wc: --version works")


if __name__ == '__main__':
    fw = SecurityTestFramework(config)
    fw.run_all(tool_specific_fn=tool_specific_tests)
