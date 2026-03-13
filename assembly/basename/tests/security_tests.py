#!/usr/bin/env python3
"""security_tests.py -- Security & memory safety tests for fbasename."""

import sys
import os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', '..', 'tests'))
from security_framework import SecurityTestFramework

config = {
    'tool_name': 'basename',
    'bin_name': 'fbasename',
    'gnu_path': '/usr/bin/basename',
    'bss_size': 65536,
    'max_binary_size': 30000,
    'test_args': ['/usr/bin/sort'],
    'test_stdin': None,
    'timeout': 5,
}


def tool_specific_tests(fw):
    """13. Tool-specific: basename path stripping behavior."""
    fw.log("\n=== Tool-Specific: basename ===")

    # Core basename behavior
    test_cases = [
        (["/usr/bin/sort"], b"sort\n"),
        (["include/stdio.h", ".h"], b"stdio\n"),
        (["/usr/bin/sort///"], b"sort\n"),
        (["/"], b"/\n"),
        (["sort"], b"sort\n"),
        (["."], b".\n"),
        ([".."], b"..\n"),
        ([""], b"\n"),
        (["-a", "/usr/bin/sort", "/usr/bin/head"], b"sort\nhead\n"),
        (["-s", ".h", "include/stdio.h", "include/errno.h"], b"stdio\nerrno\n"),
    ]

    for args, expected in test_cases:
        rc, out, err = fw.run_asm(args)
        fw.report_result(out == expected,
                         f"basename: {' '.join(args)} -> {expected.rstrip().decode()}")

    # -z produces actual NUL byte terminator
    rc, out, err = fw.run_asm(["-z", "/usr/bin/sort"])
    fw.report_result(out == b"sort\x00", "basename: -z produces NUL byte")
    fw.report_result(b"\n" not in out, "basename: -z no trailing newline")

    # Extremely long path
    long_path = "/" + "/".join(["a" * 200] * 10)
    rc, out, err = fw.run_asm([long_path])
    fw.report_result(rc == 0 and out == b"a" * 200 + b"\n",
                     "basename: extremely long path -> no crash")

    # Path with embedded newlines
    if os.path.exists(fw.gnu_path):
        rc, out, err = fw.run_asm(["hello\nworld"])
        rc_g, out_g, _ = fw.run_gnu(["hello\nworld"])
        fw.report_result(out == out_g, "basename: path with embedded newlines matches GNU")

    # Multiple consecutive slashes
    rc, out, err = fw.run_asm(["///usr///bin///sort"])
    fw.report_result(out == b"sort\n", "basename: multiple consecutive slashes handled")

    # Suffix edge cases
    rc, out, err = fw.run_asm(["file.txt", ".txt"])
    fw.report_result(out == b"file\n", "basename: suffix removal .txt")

    rc, out, err = fw.run_asm(["file.txt", ".c"])
    fw.report_result(out == b"file.txt\n", "basename: suffix no match .c")

    rc, out, err = fw.run_asm([".txt", ".txt"])
    fw.report_result(out == b".txt\n", "basename: suffix same as name -> no removal")

    # --suffix= form
    rc, out, err = fw.run_asm(["--suffix=.h", "stdio.h"])
    fw.report_result(out == b"stdio\n", "basename: --suffix=.h works")

    # Combined flags
    rc, out, err = fw.run_asm(["-az", ".h", "stdio.h", "errno.h"])
    fw.report_result(b"\x00" in out, "basename: -az combined produces NUL")


if __name__ == '__main__':
    fw = SecurityTestFramework(config)
    fw.run_all(tool_specific_fn=tool_specific_tests)
