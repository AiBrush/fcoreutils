#!/usr/bin/env python3
"""security_tests.py -- Security & memory safety tests for fvdir.

Uses the shared SecurityTestFramework with tool-specific vdir tests.
"""

import os
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', '..', 'tests'))
from security_framework import SecurityTestFramework

config = {
    'tool_name': 'vdir',
    'bin_name': 'fvdir',
    'gnu_path': '/usr/bin/vdir',
    'bss_size': 65536,
    'max_binary_size': 100000,
    'test_args': ['/tmp'],
    'test_stdin': None,
    'timeout': 10,
}


def tool_specific_tests(fw):
    """Category 13: vdir-specific tests."""
    fw.log("\n=== Tool-Specific: vdir ===")

    with tempfile.TemporaryDirectory() as td:
        for name in ["aaa", "bbb", ".hidden"]:
            Path(td, name).touch()

        rc, out, _ = fw.run_asm([td])
        decoded = out.decode()
        lines = decoded.strip().split("\n")
        fw.report_result(len(lines) >= 3, "vdir: multiple lines (total + entries)")
        fw.report_result(".hidden" not in decoded, "vdir: hidden excluded by default")

        rc, out, _ = fw.run_asm(["-a", td])
        fw.report_result(b".hidden" in out, "vdir: -a shows hidden")

    with tempfile.TemporaryDirectory() as td:
        for name in ["alpha", "beta", "gamma"]:
            Path(td, name).touch()
        rc, out, _ = fw.run_asm([td])
        fw.report_result(rc == 0, "vdir: exit 0 on valid dir")
        lines = out.decode().strip().split("\n")
        fw.report_result(lines[0].startswith("total"), "vdir: starts with total line")


if __name__ == '__main__':
    fw = SecurityTestFramework(config)
    fw.run_all(tool_specific_fn=tool_specific_tests)
