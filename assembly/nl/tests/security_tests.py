#!/usr/bin/env python3
"""security_tests.py — Security & memory safety tests for fnl (assembly nl).

Uses the shared SecurityTestFramework for categories 1-12,
with nl-specific tests in category 13.
"""

import os
import sys
import tempfile

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', '..', 'tests'))
from security_framework import SecurityTestFramework

config = {
    'tool_name': 'nl',
    'bin_name': 'fnl',
    'gnu_path': '/usr/bin/nl',
    'bss_size': 65536,
    'max_binary_size': 100000,
    'test_args': [],
    'test_stdin': b'hello\nworld\n',
    'timeout': 5,
}


def tool_specific_tests(fw):
    """Category 13: nl-specific tests."""
    fw.log("\n=== Nl-Specific Tests ===")

    # Basic numbering — compare with GNU
    data = b"hello\nworld\n"
    rc_a, out_a, _ = fw.run_asm([], stdin_data=data)
    rc_g, out_g, _ = fw.run_gnu([], stdin_data=data)
    fw.report_result(out_a == out_g, "nl: basic numbering matches GNU")

    # Default format: tab separator
    rc_a, out_a, _ = fw.run_asm([], stdin_data=b"hello\n")
    fw.report_result(b"\t" in out_a, "nl: output contains tab separator")
    first_line = out_a.split(b"\n")[0]
    fw.report_result(first_line.strip().startswith(b"1"), "nl: line number present")

    # -b a (number all lines, including empty)
    data = b"hello\n\nworld\n"
    rc_a, out_a, _ = fw.run_asm(["-b", "a"], stdin_data=data)
    rc_g, out_g, _ = fw.run_gnu(["-b", "a"], stdin_data=data)
    fw.report_result(out_a == out_g, "nl: -b a (number all) matches GNU")

    # -b t (number non-empty lines, default)
    rc_a, out_a, _ = fw.run_asm(["-b", "t"], stdin_data=data)
    rc_g, out_g, _ = fw.run_gnu(["-b", "t"], stdin_data=data)
    fw.report_result(out_a == out_g, "nl: -b t (number non-empty) matches GNU")

    # -b n (no numbering)
    data = b"hello\nworld\n"
    rc_a, out_a, _ = fw.run_asm(["-b", "n"], stdin_data=data)
    rc_g, out_g, _ = fw.run_gnu(["-b", "n"], stdin_data=data)
    fw.report_result(out_a == out_g, "nl: -b n (no numbering) matches GNU")

    # -n ln (left justified)
    rc_a, out_a, _ = fw.run_asm(["-n", "ln"], stdin_data=data)
    rc_g, out_g, _ = fw.run_gnu(["-n", "ln"], stdin_data=data)
    fw.report_result(out_a == out_g, "nl: -n ln (left justified) matches GNU")

    # -n rn (right justified, default)
    rc_a, out_a, _ = fw.run_asm(["-n", "rn"], stdin_data=data)
    rc_g, out_g, _ = fw.run_gnu(["-n", "rn"], stdin_data=data)
    fw.report_result(out_a == out_g, "nl: -n rn (right justified) matches GNU")

    # -n rz (leading zeros)
    rc_a, out_a, _ = fw.run_asm(["-n", "rz"], stdin_data=data)
    rc_g, out_g, _ = fw.run_gnu(["-n", "rz"], stdin_data=data)
    fw.report_result(out_a == out_g, "nl: -n rz (leading zeros) matches GNU")

    # -w width
    rc_a, out_a, _ = fw.run_asm(["-w", "3"], stdin_data=data)
    rc_g, out_g, _ = fw.run_gnu(["-w", "3"], stdin_data=data)
    fw.report_result(out_a == out_g, "nl: -w 3 (width) matches GNU")

    rc_a, out_a, _ = fw.run_asm(["-w", "10"], stdin_data=data)
    rc_g, out_g, _ = fw.run_gnu(["-w", "10"], stdin_data=data)
    fw.report_result(out_a == out_g, "nl: -w 10 (wide) matches GNU")

    # -s separator
    rc_a, out_a, _ = fw.run_asm(["-s", ": "], stdin_data=data)
    rc_g, out_g, _ = fw.run_gnu(["-s", ": "], stdin_data=data)
    fw.report_result(out_a == out_g, "nl: -s ': ' (separator) matches GNU")

    rc_a, out_a, _ = fw.run_asm(["-s", "|"], stdin_data=data)
    rc_g, out_g, _ = fw.run_gnu(["-s", "|"], stdin_data=data)
    fw.report_result(out_a == out_g, "nl: -s '|' (single char separator) matches GNU")

    # -i increment
    data = b"line1\nline2\nline3\n"
    rc_a, out_a, _ = fw.run_asm(["-i", "2", "-b", "a"], stdin_data=data)
    rc_g, out_g, _ = fw.run_gnu(["-i", "2", "-b", "a"], stdin_data=data)
    fw.report_result(out_a == out_g, "nl: -i 2 (increment) matches GNU")

    rc_a, out_a, _ = fw.run_asm(["-i", "5", "-b", "a"], stdin_data=data)
    rc_g, out_g, _ = fw.run_gnu(["-i", "5", "-b", "a"], stdin_data=data)
    fw.report_result(out_a == out_g, "nl: -i 5 (increment by 5) matches GNU")

    # -v starting number
    data = b"hello\nworld\n"
    rc_a, out_a, _ = fw.run_asm(["-v", "10"], stdin_data=data)
    rc_g, out_g, _ = fw.run_gnu(["-v", "10"], stdin_data=data)
    fw.report_result(out_a == out_g, "nl: -v 10 (starting number) matches GNU")

    rc_a, out_a, _ = fw.run_asm(["-v", "0"], stdin_data=data)
    rc_g, out_g, _ = fw.run_gnu(["-v", "0"], stdin_data=data)
    fw.report_result(out_a == out_g, "nl: -v 0 (start at zero) matches GNU")

    # Empty input
    rc_a, out_a, _ = fw.run_asm([], stdin_data=b"")
    rc_g, out_g, _ = fw.run_gnu([], stdin_data=b"")
    fw.report_result(out_a == out_g, "nl: empty input matches GNU")

    # Only empty lines
    data = b"\n\n\n"
    rc_a, out_a, _ = fw.run_asm([], stdin_data=data)
    rc_g, out_g, _ = fw.run_gnu([], stdin_data=data)
    fw.report_result(out_a == out_g, "nl: only empty lines matches GNU")

    # Mixed empty and non-empty
    data = b"hello\n\n\nworld\n\nfoo\n"
    rc_a, out_a, _ = fw.run_asm([], stdin_data=data)
    rc_g, out_g, _ = fw.run_gnu([], stdin_data=data)
    fw.report_result(out_a == out_g, "nl: mixed empty/non-empty matches GNU")

    # Single line no newline
    rc_a, out_a, _ = fw.run_asm([], stdin_data=b"hello")
    rc_g, out_g, _ = fw.run_gnu([], stdin_data=b"hello")
    fw.report_result(out_a == out_g, "nl: single line no trailing newline matches GNU")

    # Combined options
    data = b"line1\n\nline3\n"
    rc_a, out_a, _ = fw.run_asm(["-b", "a", "-n", "rz", "-w", "4", "-s", ". ", "-v", "100", "-i", "10"], stdin_data=data)
    rc_g, out_g, _ = fw.run_gnu(["-b", "a", "-n", "rz", "-w", "4", "-s", ". ", "-v", "100", "-i", "10"], stdin_data=data)
    fw.report_result(out_a == out_g, "nl: combined options matches GNU")

    # File argument
    with tempfile.NamedTemporaryFile(mode='wb', suffix='.txt', delete=False) as f:
        f.write(b"file line 1\nfile line 2\nfile line 3\n")
        tmpfile = f.name
    try:
        rc_a, out_a, _ = fw.run_asm([tmpfile])
        rc_g, out_g, _ = fw.run_gnu([tmpfile])
        fw.report_result(out_a == out_g, "nl: file argument matches GNU")
    finally:
        os.unlink(tmpfile)

    # Nonexistent file
    rc_a, _, err_a = fw.run_asm(["/nonexistent/file.txt"])
    fw.report_result(rc_a != 0, "nl: nonexistent file returns nonzero")

    # Long lines
    long_line = b"A" * 10000 + b"\n"
    rc_a, out_a, _ = fw.run_asm([], stdin_data=long_line)
    rc_g, out_g, _ = fw.run_gnu([], stdin_data=long_line)
    fw.report_result(out_a == out_g, "nl: very long line (10KB) matches GNU")

    # Many lines
    many = b"".join(f"line{i:06d}\n".encode() for i in range(1000))
    rc_a, out_a, _ = fw.run_asm([], stdin_data=many, timeout=10)
    rc_g, out_g, _ = fw.run_gnu([], stdin_data=many, timeout=10)
    fw.report_result(out_a == out_g, "nl: 1000 lines matches GNU")

    # -p (no reset at logical pages)
    data = b"\\:\\:\\:\nhello\nworld\n\\:\\:\\:\nfoo\nbar\n"
    rc_a, out_a, _ = fw.run_asm(["-p", "-b", "a"], stdin_data=data)
    rc_g, out_g, _ = fw.run_gnu(["-p", "-b", "a"], stdin_data=data)
    fw.report_result(out_a == out_g, "nl: -p (no page reset) matches GNU")

    # Special characters
    data = b"!@#$%^&*()\n[]{}<>|\\~`\n"
    rc_a, out_a, _ = fw.run_asm([], stdin_data=data)
    rc_g, out_g, _ = fw.run_gnu([], stdin_data=data)
    fw.report_result(out_a == out_g, "nl: special characters matches GNU")

    # --help/--version
    rc_a, out_a, _ = fw.run_asm(["--help"])
    fw.report_result(rc_a == 0 and len(out_a) > 0, "nl: --help works")

    rc_a, out_a, _ = fw.run_asm(["--version"])
    fw.report_result(rc_a == 0 and len(out_a) > 0, "nl: --version works")


if __name__ == '__main__':
    fw = SecurityTestFramework(config)
    fw.run_all(tool_specific_fn=tool_specific_tests)
