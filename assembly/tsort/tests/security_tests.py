#!/usr/bin/env python3
"""security_tests.py -- Security & memory safety tests for ftsort (assembly tsort).

Uses shared SecurityTestFramework. tsort reads pairs of strings and
performs topological sorting.
"""

import os
import sys
import tempfile

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', '..', 'tests'))
from security_framework import SecurityTestFramework

config = {
    'tool_name': 'tsort',
    'bin_name': 'ftsort',
    'gnu_path': '/usr/bin/tsort',
    'bss_size': 65536,
    'max_binary_size': 100000,
    'test_args': [],
    'test_stdin': b'a b\nb c\nc d\n',
    'timeout': 5,
}


def tool_specific_tests(fw):
    """13. tsort-specific tests."""
    fw.log("\n=== 13. Tool-Specific: tsort ===")

    # Basic chain
    data = b"a b\nb c\nc d\n"
    rc_a, out_a, _ = fw.run_asm([], stdin_data=data)
    rc_g, out_g, _ = fw.run_gnu([], stdin_data=data)
    fw.report_result(out_a == out_g, "tsort: basic chain matches GNU")

    # Empty input
    rc_a, out_a, _ = fw.run_asm([], stdin_data=b"")
    rc_g, out_g, _ = fw.run_gnu([], stdin_data=b"")
    fw.report_result(out_a == out_g and rc_a == rc_g, "tsort: empty input matches GNU")

    # Self loop
    data = b"a a\n"
    rc_a, out_a, _ = fw.run_asm([], stdin_data=data)
    rc_g, out_g, _ = fw.run_gnu([], stdin_data=data)
    fw.report_result(out_a == out_g and rc_a == rc_g, "tsort: self loop matches GNU")

    # Diamond
    data = b"a b\na c\nb d\nc d\n"
    rc_a, out_a, _ = fw.run_asm([], stdin_data=data)
    rc_g, out_g, _ = fw.run_gnu([], stdin_data=data)
    fw.report_result(out_a == out_g, "tsort: diamond matches GNU")

    # Cycle
    data = b"a b\nb c\nc a\n"
    rc_a, out_a, err_a = fw.run_asm([], stdin_data=data)
    rc_g, out_g, err_g = fw.run_gnu([], stdin_data=data)
    fw.report_result(out_a == out_g, "tsort: cycle stdout matches GNU")
    fw.report_result(rc_a == rc_g, "tsort: cycle exit code matches GNU")

    # Multiple cycles
    data = b"a b\nb a\nc d\nd c\n"
    rc_a, out_a, _ = fw.run_asm([], stdin_data=data)
    rc_g, out_g, _ = fw.run_gnu([], stdin_data=data)
    fw.report_result(out_a == out_g, "tsort: multiple cycles stdout matches GNU")
    fw.report_result(rc_a == rc_g, "tsort: multiple cycles exit code matches GNU")

    # Odd tokens
    data = b"a\n"
    rc_a, _, _ = fw.run_asm([], stdin_data=data)
    rc_g, _, _ = fw.run_gnu([], stdin_data=data)
    fw.report_result(rc_a == rc_g and rc_a != 0, "tsort: odd tokens exit code matches GNU")

    # Numeric nodes
    data = b"1 2\n2 3\n3 4\n"
    rc_a, out_a, _ = fw.run_asm([], stdin_data=data)
    rc_g, out_g, _ = fw.run_gnu([], stdin_data=data)
    fw.report_result(out_a == out_g, "tsort: numeric nodes matches GNU")

    # Independent nodes
    data = b"a a\nb b\nc c\n"
    rc_a, out_a, _ = fw.run_asm([], stdin_data=data)
    rc_g, out_g, _ = fw.run_gnu([], stdin_data=data)
    fw.report_result(out_a == out_g, "tsort: independent nodes matches GNU")

    # File input
    with tempfile.NamedTemporaryFile(mode='wb', suffix='.txt', delete=False) as f:
        f.write(b"a b\nb c\n")
        tmpfile = f.name
    try:
        rc_a, out_a, _ = fw.run_asm([tmpfile])
        rc_g, out_g, _ = fw.run_gnu([tmpfile])
        fw.report_result(out_a == out_g, "tsort: file argument matches GNU")
    finally:
        os.unlink(tmpfile)

    # stdin via -
    data = b"a b\nb c\n"
    rc_a, out_a, _ = fw.run_asm(["-"], stdin_data=data)
    rc_g, out_g, _ = fw.run_gnu(["-"], stdin_data=data)
    fw.report_result(out_a == out_g, "tsort: stdin via '-' matches GNU")

    # Whitespace handling
    data = b"  a   b  \n  b    c  \n"
    rc_a, out_a, _ = fw.run_asm([], stdin_data=data)
    rc_g, out_g, _ = fw.run_gnu([], stdin_data=data)
    fw.report_result(out_a == out_g, "tsort: whitespace handling matches GNU")

    # Duplicate edges
    data = b"a b\na b\na b\n"
    rc_a, out_a, _ = fw.run_asm([], stdin_data=data)
    rc_g, out_g, _ = fw.run_gnu([], stdin_data=data)
    fw.report_result(out_a == out_g, "tsort: duplicate edges matches GNU")

    # Large input (1000 nodes chain)
    pairs = "\n".join(f"{i} {i+1}" for i in range(999))
    data = (pairs + "\n").encode()
    rc_a, out_a, _ = fw.run_asm([], stdin_data=data, timeout=30)
    rc_g, out_g, _ = fw.run_gnu([], stdin_data=data, timeout=30)
    fw.report_result(out_a == out_g and rc_a == rc_g, "tsort: large chain (1000) matches GNU")

    # --help
    rc_a, out_a, _ = fw.run_asm(["--help"])
    fw.report_result(rc_a == 0 and len(out_a) > 0, "tsort: --help works")

    # --version
    rc_a, out_a, _ = fw.run_asm(["--version"])
    fw.report_result(rc_a == 0 and len(out_a) > 0, "tsort: --version works")

    # Tab-separated
    data = b"a\tb\nb\tc\n"
    rc_a, out_a, _ = fw.run_asm([], stdin_data=data)
    rc_g, out_g, _ = fw.run_gnu([], stdin_data=data)
    fw.report_result(out_a == out_g, "tsort: tab-separated matches GNU")


if __name__ == '__main__':
    fw = SecurityTestFramework(config)
    fw.run_all(tool_specific_fn=tool_specific_tests)
