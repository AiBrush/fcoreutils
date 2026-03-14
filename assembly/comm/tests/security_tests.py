#!/usr/bin/env python3
"""security_tests.py -- Security & memory safety tests for fcomm (assembly comm).

Uses shared SecurityTestFramework.
fcomm compares two sorted files line by line (like GNU comm).
"""

import os
import sys
import tempfile
import random

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', '..', 'tests'))
from security_framework import SecurityTestFramework

# Create temp files for test_args (comm needs two file arguments)
_f1 = tempfile.NamedTemporaryFile(mode='wb', suffix='.txt', delete=False)
_f1.write(b"a\nb\nc\n")
_f1.close()
_f2 = tempfile.NamedTemporaryFile(mode='wb', suffix='.txt', delete=False)
_f2.write(b"b\nc\nd\n")
_f2.close()

config = {
    'tool_name': 'comm',
    'bin_name': 'fcomm',
    'gnu_path': '/usr/bin/comm',
    'bss_size': 65536,
    'max_binary_size': 100000,
    'test_args': [_f1.name, _f2.name],
    'test_stdin': None,
    'timeout': 5,
}


def make_temp_file(content):
    f = tempfile.NamedTemporaryFile(mode='wb', suffix='.txt', delete=False)
    f.write(content)
    f.close()
    return f.name


def tool_specific_tests(fw):
    """13. comm-specific tests: argument parsing and correctness."""
    fw.log("\n=== 13. Tool-Specific: comm ===")

    temp_files = []

    try:
        f1 = make_temp_file(b"a\nb\nc\n")
        f2 = make_temp_file(b"b\nc\nd\n")
        temp_files.extend([f1, f2])

        # Argument parsing
        for desc, args in [
            ("-1", ["-1"]),
            ("-2", ["-2"]),
            ("-3", ["-3"]),
            ("-12", ["-12"]),
            ("-123", ["-123"]),
            ("-1 -2 -3", ["-1", "-2", "-3"]),
            ("--total", ["--total"]),
            ("--output-delimiter=|", ["--output-delimiter=|"]),
        ]:
            rc, _, _ = fw.run_asm(args + [f1, f2])
            fw.report_result(rc < 128, f"args: {desc} no crash (rc={rc})")

        # Error cases
        for desc, args in [
            ("no args", []),
            ("one arg", [f1]),
            ("nonexistent file", [f1, "/nonexistent_file_xyzzy"]),
        ]:
            rc, _, _ = fw.run_asm(args)
            fw.report_result(rc < 128 and rc != 0, f"args: {desc} exits non-zero no crash (rc={rc})")

        # --help and --version
        rc, out, _ = fw.run_asm(["--help"])
        fw.report_result(rc == 0 and len(out) > 50, f"args: --help (rc={rc})")
        rc, out, _ = fw.run_asm(["--version"])
        fw.report_result(rc == 0 and len(out) > 5, f"args: --version (rc={rc})")

        # Correctness vs GNU
        if os.path.exists(fw.gnu_path):
            test_cases = [
                ("basic", b"a\nb\nc\n", b"b\nc\nd\n", []),
                ("identical", b"a\nb\nc\n", b"a\nb\nc\n", []),
                ("disjoint", b"x\ny\nz\n", b"a\nb\nc\n", []),
                ("empty both", b"", b"", []),
                ("empty first", b"", b"a\nb\n", []),
                ("-1", b"a\nb\nc\n", b"b\nc\nd\n", ["-1"]),
                ("-23", b"a\nb\nc\n", b"b\nc\nd\n", ["-23"]),
                ("--total", b"a\nb\nc\n", b"b\nc\nd\n", ["--total"]),
                ("--output-delimiter=|", b"a\nb\nc\n", b"b\nc\nd\n", ["--output-delimiter=|"]),
            ]

            for desc, data1, data2, flags in test_cases:
                tf1 = make_temp_file(data1)
                tf2 = make_temp_file(data2)
                temp_files.extend([tf1, tf2])
                grc, gout, _ = fw.run([fw.gnu_path] + flags + [tf1, tf2])
                arc, aout, _ = fw.run_asm(flags + [tf1, tf2])
                fw.report_result(
                    gout == aout and grc == arc,
                    f"correct: {desc} (gnu_rc={grc}, asm_rc={arc})"
                )

        # Fuzzing with random file contents
        crash_count = 0
        for _ in range(30):
            data1 = os.urandom(random.randint(100, 5000))
            data2 = os.urandom(random.randint(100, 5000))
            tf1 = make_temp_file(data1)
            tf2 = make_temp_file(data2)
            temp_files.extend([tf1, tf2])
            rc, _, _ = fw.run_asm([tf1, tf2])
            if rc >= 128:
                crash_count += 1
        fw.report_result(crash_count == 0, f"fuzz: 30 binary blobs (crashes: {crash_count})")

    finally:
        for f in temp_files:
            try:
                os.unlink(f)
            except OSError:
                pass


if __name__ == '__main__':
    try:
        fw = SecurityTestFramework(config)
        fw.run_all(tool_specific_fn=tool_specific_tests)
    finally:
        try:
            os.unlink(_f1.name)
        except OSError:
            pass
        try:
            os.unlink(_f2.name)
        except OSError:
            pass
