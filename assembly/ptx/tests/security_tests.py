#!/usr/bin/env python3
"""security_tests.py -- Security & memory safety tests for fptx (assembly ptx).

Uses shared SecurityTestFramework.
fptx produces a permuted index.
"""

import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', '..', 'tests'))
from security_framework import SecurityTestFramework

config = {
    'tool_name': 'ptx',
    'bin_name': 'fptx',
    'gnu_path': '/usr/bin/ptx',
    'bss_size': 65536,
    'max_binary_size': 102400,
    'test_args': ['--help'],
    'test_stdin': None,
    'timeout': 10,
}


def tool_specific_tests(fw):
    """13. ptx-specific tests."""
    fw.log("\n=== 13. Tool-Specific: ptx ===")

    # --help
    rc, out, _ = fw.run_asm(["--help"])
    fw.report_result(rc == 0 and len(out) > 50, f"ptx: --help (rc={rc})")

    # --version
    rc, out, _ = fw.run_asm(["--version"])
    fw.report_result(rc == 0 and len(out) > 5, f"ptx: --version (rc={rc})")


if __name__ == '__main__':
    fw = SecurityTestFramework(config)
    fw.run_all(tool_specific_fn=tool_specific_tests)
