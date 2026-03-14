#!/usr/bin/env python3
"""security_tests.py — Security & memory safety tests for ffold (assembly fold).

Uses the shared SecurityTestFramework plus fold-specific tests.
"""

import os
import sys
import tempfile

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', '..', 'tests'))
from security_framework import SecurityTestFramework

config = {
    'tool_name': 'fold',
    'bin_name': 'ffold',
    'gnu_path': '/usr/bin/fold',
    'bss_size': 65536,
    'max_binary_size': 100000,
    'test_args': [],
    'test_stdin': b'hello world this is a test line for folding\n',
    'timeout': 5,
}


def tool_specific_tests(fw):
    """Category 13: fold-specific tests."""
    fw.log("\n=== Fold-Specific Tests ===")

    # Default 80-char wrap
    line80 = b"A" * 80 + b"\n"
    rc_a, out_a, _ = fw.run_asm([], stdin_data=line80)
    rc_g, out_g, _ = fw.run_gnu([], stdin_data=line80)
    fw.report_result(out_a == out_g, "fold: 80-char line (at limit) matches GNU")

    line81 = b"A" * 81 + b"\n"
    rc_a, out_a, _ = fw.run_asm([], stdin_data=line81)
    rc_g, out_g, _ = fw.run_gnu([], stdin_data=line81)
    fw.report_result(out_a == out_g, "fold: 81-char line (over limit) matches GNU")

    line79 = b"A" * 79 + b"\n"
    rc_a, out_a, _ = fw.run_asm([], stdin_data=line79)
    rc_g, out_g, _ = fw.run_gnu([], stdin_data=line79)
    fw.report_result(out_a == out_g, "fold: 79-char line (under limit) matches GNU")

    # -w N (custom width)
    for width in [10, 20, 40, 1, 2]:
        data = b"A" * 100 + b"\n"
        rc_a, out_a, _ = fw.run_asm(["-w", str(width)], stdin_data=data)
        rc_g, out_g, _ = fw.run_gnu(["-w", str(width)], stdin_data=data)
        fw.report_result(out_a == out_g, f"fold: -w {width} matches GNU")

    # -s (break at spaces)
    data = b"the quick brown fox jumps over the lazy dog and keeps on going forever\n"
    rc_a, out_a, _ = fw.run_asm(["-s", "-w", "20"], stdin_data=data)
    rc_g, out_g, _ = fw.run_gnu(["-s", "-w", "20"], stdin_data=data)
    fw.report_result(out_a == out_g, "fold: -s -w 20 (break at spaces) matches GNU")

    # -s with no spaces (should still wrap)
    data = b"A" * 100 + b"\n"
    rc_a, out_a, _ = fw.run_asm(["-s", "-w", "20"], stdin_data=data)
    rc_g, out_g, _ = fw.run_gnu(["-s", "-w", "20"], stdin_data=data)
    fw.report_result(out_a == out_g, "fold: -s with no spaces matches GNU")

    # -b (count bytes, not columns)
    data = b"hello\tworld\n"
    rc_a, out_a, _ = fw.run_asm(["-b", "-w", "8"], stdin_data=data)
    rc_g, out_g, _ = fw.run_gnu(["-b", "-w", "8"], stdin_data=data)
    fw.report_result(out_a == out_g, "fold: -b -w 8 (count bytes) matches GNU")

    # Empty input
    rc_a, out_a, _ = fw.run_asm([], stdin_data=b"")
    rc_g, out_g, _ = fw.run_gnu([], stdin_data=b"")
    fw.report_result(out_a == out_g, "fold: empty input matches GNU")

    # Multiple short lines (no wrapping needed)
    data = b"short\nlines\nhere\n"
    rc_a, out_a, _ = fw.run_asm([], stdin_data=data)
    rc_g, out_g, _ = fw.run_gnu([], stdin_data=data)
    fw.report_result(out_a == out_g, "fold: short lines (no wrap) matches GNU")

    # Tabs
    data = b"\thello\t\tworld\n"
    rc_a, out_a, _ = fw.run_asm([], stdin_data=data)
    rc_g, out_g, _ = fw.run_gnu([], stdin_data=data)
    fw.report_result(out_a == out_g, "fold: tabs matches GNU")

    # No trailing newline
    data = b"hello world"
    rc_a, out_a, _ = fw.run_asm([], stdin_data=data)
    rc_g, out_g, _ = fw.run_gnu([], stdin_data=data)
    fw.report_result(out_a == out_g, "fold: no trailing newline matches GNU")

    # File argument
    with tempfile.NamedTemporaryFile(mode='wb', suffix='.txt', delete=False) as f:
        f.write(b"A" * 100 + b"\n" + b"short\n")
        tmpfile = f.name
    try:
        rc_a, out_a, _ = fw.run_asm([tmpfile])
        rc_g, out_g, _ = fw.run_gnu([tmpfile])
        fw.report_result(out_a == out_g, "fold: file argument matches GNU")
    finally:
        os.unlink(tmpfile)

    # Very long line (10KB)
    data = b"X" * 10000 + b"\n"
    rc_a, out_a, _ = fw.run_asm([], stdin_data=data)
    rc_g, out_g, _ = fw.run_gnu([], stdin_data=data)
    fw.report_result(out_a == out_g, "fold: very long line (10KB) matches GNU")

    # --help / --version
    rc_a, out_a, _ = fw.run_asm(["--help"])
    fw.report_result(rc_a == 0 and len(out_a) > 0, "fold: --help works")

    rc_a, out_a, _ = fw.run_asm(["--version"])
    fw.report_result(rc_a == 0 and len(out_a) > 0, "fold: --version works")


if __name__ == '__main__':
    fw = SecurityTestFramework(config)
    fw.run_all(tool_specific_fn=tool_specific_tests)
