#!/usr/bin/env python3
"""security_tests.py -- Security & memory safety tests for fpathchk (assembly pathchk).

Uses shared SecurityTestFramework.
fpathchk checks whether file names are valid or portable.
"""

import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', '..', 'tests'))
from security_framework import SecurityTestFramework
from shutil import which

config = {
    'tool_name': 'pathchk',
    'bin_name': 'fpathchk',
    'gnu_path': '/usr/bin/pathchk',
    'bss_size': 4096,
    'max_binary_size': 30000,
    'test_args': ['/usr/bin/sort'],
    'test_stdin': None,
    'timeout': 5,
}


def tool_specific_tests(fw):
    """13. pathchk-specific tests: path validation, portability checks."""
    fw.log("\n=== 13. Tool-Specific: pathchk ===")
    gnu_path = which('pathchk')

    # Valid paths should exit 0
    valid_cases = [
        ["/usr/bin/sort"],
        ["file.txt"],
        ["/"],
        ["."],
        [".."],
        ["a/b/c"],
        ["-"],
    ]
    for args in valid_cases:
        rc, out, err = fw.run_asm(args)
        fw.report_result(rc == 0 and out == b"",
                         f"pathchk: valid path {args} -> exit 0, no output")

    # Multiple paths
    rc, out, err = fw.run_asm(["path1", "path2", "path3"])
    fw.report_result(rc == 0, "pathchk: multiple valid paths -> exit 0")

    # -p flag tests
    rc, out, err = fw.run_asm(["-p", "valid"])
    fw.report_result(rc == 0, "pathchk: -p valid -> exit 0")

    rc, out, err = fw.run_asm(["-p", "hello@world"])
    fw.report_result(rc == 1, "pathchk: -p non-portable char -> exit 1")
    fw.report_result(b"non-portable character" in err,
                     "pathchk: -p non-portable error message")

    rc, out, err = fw.run_asm(["-p", "a" * 15])
    fw.report_result(rc == 1, "pathchk: -p component too long -> exit 1")

    rc, out, err = fw.run_asm(["-p", "a" * 14])
    fw.report_result(rc == 0, "pathchk: -p component exactly 14 -> exit 0")

    # -P flag tests
    rc, out, err = fw.run_asm(["-P", ""])
    fw.report_result(rc == 1, "pathchk: -P empty -> exit 1")
    fw.report_result(b"empty file name" in err, "pathchk: -P empty error message")

    rc, out, err = fw.run_asm(["-P", "--", "-file"])
    fw.report_result(rc == 1, "pathchk: -P leading hyphen -> exit 1")
    fw.report_result(b"leading '-'" in err, "pathchk: -P leading hyphen error message")

    # --portability tests (= -p -P)
    rc, out, err = fw.run_asm(["--portability", "valid"])
    fw.report_result(rc == 0, "pathchk: --portability valid -> exit 0")

    rc, out, err = fw.run_asm(["--portability", ""])
    fw.report_result(rc == 1, "pathchk: --portability empty -> exit 1")

    rc, out, err = fw.run_asm(["--portability", "--", "-file"])
    fw.report_result(rc == 1, "pathchk: --portability leading hyphen -> exit 1")

    # Combined -pP
    rc, out, err = fw.run_asm(["-pP", "valid"])
    fw.report_result(rc == 0, "pathchk: -pP valid -> exit 0")

    # Portable character set: A-Za-z0-9._-
    for char in ['A', 'Z', 'a', 'z', '0', '9', '.', '_', '-']:
        rc, _, _ = fw.run_asm(["-p", f"test{char}name"])
        fw.report_result(rc == 0,
                         f"pathchk: -p portable char '{char}' -> exit 0")

    for char in ['@', '!', '#', '$', '%', ' ', '~', '(', ')']:
        rc, _, _ = fw.run_asm(["-p", f"test{char}name"])
        fw.report_result(rc == 1,
                         f"pathchk: -p non-portable char '{char}' -> exit 1")

    # Long path
    long_path = "/" + "/".join(["a" * 10] * 100)
    rc, out, err = fw.run_asm([long_path])
    fw.report_result(rc >= 0 and rc < 128, "pathchk: long path -> no crash")

    # Extremely long path
    huge_path = "a" * 5000
    rc, out, err = fw.run_asm([huge_path])
    fw.report_result(rc == 1, "pathchk: path > PATH_MAX -> exit 1")

    # Compare with GNU
    if gnu_path:
        test_cases = [
            ["/usr/bin/sort"],
            ["-p", "valid"],
            ["-p", "hello@world"],
            ["-P", ""],
            ["-P", "--", "-file"],
            ["--portability", "valid"],
            ["-p", "a" * 14],
            ["-p", "a" * 15],
        ]
        for args in test_cases:
            rc_f, _, _ = fw.run_asm(args)
            rc_g, _, _ = fw.run([gnu_path] + args)
            fw.report_result(rc_f == rc_g,
                             f"pathchk: exit code matches GNU for {args}")


if __name__ == '__main__':
    fw = SecurityTestFramework(config)
    fw.run_all(tool_specific_fn=tool_specific_tests)
