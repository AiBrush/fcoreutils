#!/usr/bin/env python3
"""security_tests.py -- Security & memory safety tests for fjoin.

Uses the shared SecurityTestFramework for categories 1-12,
plus tool-specific tests for join correctness and argument parsing.
"""

import sys
import os
import tempfile

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', '..', 'tests'))
from security_framework import SecurityTestFramework

# Create temp files for test_args (join needs two sorted file arguments)
_f1 = tempfile.NamedTemporaryFile(mode='wb', suffix='.txt', delete=False)
_f1.write(b"a 1\nb 2\nc 3\n")
_f1.close()
_f2 = tempfile.NamedTemporaryFile(mode='wb', suffix='.txt', delete=False)
_f2.write(b"b x\nc y\nd z\n")
_f2.close()

config = {
    'tool_name': 'join',
    'bin_name': 'fjoin',
    'gnu_path': '/usr/bin/join',
    'bss_size': 65536,
    'max_binary_size': 200000,
    'test_args': [_f1.name, _f2.name],
    'test_stdin': None,
    'timeout': 5,
}


def _make_temp(content):
    """Write content to a temp file, return path."""
    f = tempfile.NamedTemporaryFile(mode='wb', suffix='.txt', delete=False)
    f.write(content)
    f.close()
    return f.name


def tool_specific_tests(fw):
    """Category 13: join-specific tests (argument parsing + correctness)."""
    fw.log("\n=== Tool-Specific: join argument parsing ===")

    f1 = _make_temp(b"a 1\nb 2\nc 3\n")
    f2 = _make_temp(b"b x\nc y\nd z\n")
    temp_files = [f1, f2]

    try:
        # Valid flag combinations
        for desc, args in [
            ("-a 1", ["-a", "1"]),
            ("-a 2", ["-a", "2"]),
            ("-v 1", ["-v", "1"]),
            ("-v 2", ["-v", "2"]),
            ("-e X", ["-e", "X"]),
            ("-i", ["-i"]),
            ("-j 1", ["-j", "1"]),
            ("-o 0", ["-o", "0"]),
            ("-t :", ["-t", ":"]),
            ("-1 1", ["-1", "1"]),
            ("-2 1", ["-2", "1"]),
            ("-z", ["-z"]),
            ("--check-order", ["--check-order"]),
            ("--nocheck-order", ["--nocheck-order"]),
            ("--header", ["--header"]),
            ("--ignore-case", ["--ignore-case"]),
            ("--zero-terminated", ["--zero-terminated"]),
        ]:
            rc, _, _ = fw.run_asm(args + [f1, f2])
            fw.report_result(rc < 128, f"args: {desc} no crash (rc={rc})")

        # Error cases (should exit 1, not crash)
        for desc, args in [
            ("no args", []),
            ("one arg", [f1]),
            ("three args", [f1, f2, f1]),
            ("nonexistent file", [f1, "/nonexistent_file_xyzzy"]),
            ("unknown long opt", ["--foobar", f1, f2]),
        ]:
            rc, _, _ = fw.run_asm(args)
            fw.report_result(rc < 128 and rc != 0, f"args: {desc} exits non-zero no crash (rc={rc})")

        # -- end of options
        rc, out, _ = fw.run_asm(["--", f1, f2])
        fw.report_result(rc == 0, "args: -- end of options")

        # --help and --version
        rc, out, _ = fw.run_asm(["--help"])
        fw.report_result(rc == 0 and len(out) > 50, f"args: --help (rc={rc}, len={len(out)})")

        rc, out, _ = fw.run_asm(["--version"])
        fw.report_result(rc == 0 and len(out) > 5, f"args: --version (rc={rc}, len={len(out)})")

    finally:
        for f in temp_files:
            try:
                os.unlink(f)
            except OSError:
                pass  # temp file already removed or never created

    # Correctness verification
    fw.log("\n=== Tool-Specific: join correctness ===")
    temp_files = []

    try:
        test_cases = [
            ("basic", b"1 a\n2 b\n3 c\n", b"1 x\n2 y\n3 z\n", []),
            ("identical", b"a 1\nb 2\nc 3\n", b"a 1\nb 2\nc 3\n", []),
            ("disjoint", b"x 1\ny 2\n", b"a 3\nb 4\n", []),
            ("empty both", b"", b"", []),
            ("empty first", b"", b"a 1\nb 2\n", []),
            ("empty second", b"a 1\nb 2\n", b"", []),
            ("-a 1", b"1 a\n2 b\n3 c\n", b"2 x\n3 y\n4 z\n", ["-a", "1"]),
            ("-a 2", b"1 a\n2 b\n3 c\n", b"2 x\n3 y\n4 z\n", ["-a", "2"]),
            ("-a 1 -a 2", b"1 a\n2 b\n3 c\n", b"2 x\n3 y\n4 z\n", ["-a", "1", "-a", "2"]),
            ("-v 1", b"1 a\n2 b\n3 c\n", b"2 x\n3 y\n4 z\n", ["-v", "1"]),
            ("-v 2", b"1 a\n2 b\n3 c\n", b"2 x\n3 y\n4 z\n", ["-v", "2"]),
            ("-t:", b"1:a\n2:b\n", b"1:x\n2:y\n", ["-t", ":"]),
            ("-j 2", b"alice 1\nbob 2\n", b"apples 1\nbananas 2\n", ["-j", "2"]),
            ("-o format", b"1 a b\n2 c d\n", b"1 x y\n2 w z\n", ["-o", "0,1.2,2.2"]),
            ("-e filler", b"1 a\n2 b\n", b"1 x\n3 y\n",
             ["-e", "MISS", "-a", "1", "-a", "2", "-o", "0,1.2,2.2"]),
            ("-i case", b"A 1\nB 2\n", b"a x\nb y\n", ["-i"]),
            ("--header", b"H1 H2\n1 a\n2 b\n", b"H1 H3\n1 x\n2 y\n", ["--header"]),
            ("single line", b"a 1\n", b"a 2\n", []),
            ("no trailing nl", b"a 1\nb 2", b"b x\nc y", []),
            ("cross-product", b"1 a\n1 b\n2 c\n", b"1 x\n1 y\n2 z\n", []),
        ]

        for desc, data1, data2, flags in test_cases:
            tf1 = _make_temp(data1)
            tf2 = _make_temp(data2)
            temp_files.extend([tf1, tf2])

            grc, gout, _ = fw.run_gnu(flags + [tf1, tf2])
            arc, aout, _ = fw.run_asm(flags + [tf1, tf2])

            match = (gout == aout and grc == arc)
            fw.report_result(match, f"correct: {desc} (gnu_rc={grc}, asm_rc={arc})")

    finally:
        for f in temp_files:
            try:
                os.unlink(f)
            except OSError:
                pass  # temp file already removed or never created


if __name__ == '__main__':
    try:
        fw = SecurityTestFramework(config)
        fw.run_all(tool_specific_fn=tool_specific_tests)
    finally:
        for _f in [_f1.name, _f2.name]:
            try:
                os.unlink(_f)
            except OSError:
                pass  # best-effort cleanup of config temp files
