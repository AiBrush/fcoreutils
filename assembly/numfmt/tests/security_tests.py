#!/usr/bin/env python3
"""security_tests.py — Security & memory safety tests for fnumfmt (assembly numfmt).

Uses the shared SecurityTestFramework for categories 1-12,
with numfmt-specific tests in category 13.
"""

import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', '..', 'tests'))
from security_framework import SecurityTestFramework

config = {
    'tool_name': 'numfmt',
    'bin_name': 'fnumfmt',
    'gnu_path': '/usr/bin/numfmt',
    'bss_size': 65536,
    'max_binary_size': 50000,
    'test_args': ['--help'],
    'test_stdin': None,
    'timeout': 10,
}


def tool_specific_tests(fw):
    """Category 13: numfmt-specific tests (placeholder)."""
    fw.log("\n=== Numfmt-Specific Tests ===")

    # --help
    rc, out, _ = fw.run_asm(["--help"])
    fw.report_result(rc == 0 and len(out) > 0, "numfmt: --help works")

    # --version
    rc, out, _ = fw.run_asm(["--version"])
    fw.report_result(rc == 0 and len(out) > 0, "numfmt: --version works")


if __name__ == '__main__':
    fw = SecurityTestFramework(config)
    fw.run_all(tool_specific_fn=tool_specific_tests)
