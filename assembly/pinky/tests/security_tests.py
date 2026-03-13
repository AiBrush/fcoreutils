#!/usr/bin/env python3
"""security_tests.py -- Security & memory safety tests for fpinky (assembly pinky).

Uses shared SecurityTestFramework.
fpinky is a lightweight finger information lookup tool.
"""

import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', '..', 'tests'))
from security_framework import SecurityTestFramework

config = {
    'tool_name': 'pinky',
    'bin_name': 'fpinky',
    'gnu_path': '/usr/bin/pinky',
    'bss_size': 4096,
    'max_binary_size': 50000,
    'test_args': ['--help'],
    'test_stdin': None,
    'timeout': 10,
}


def tool_specific_tests(fw):
    """13. pinky-specific tests."""
    fw.log("\n=== 13. Tool-Specific: pinky ===")

    # --help should produce output
    rc, out, err = fw.run_asm(["--help"])
    fw.report_result(rc == 0 and len(out) > 0, "pinky: --help produces output")

    # --version should produce output
    rc, out, err = fw.run_asm(["--version"])
    fw.report_result(rc == 0 and len(out) > 0, "pinky: --version produces output")

    # No args should work (lists logged-in users)
    rc, out, err = fw.run_asm([])
    fw.report_result(rc < 128, "pinky: no args does not crash")

    # Compare with GNU if available
    if os.path.exists(fw.gnu_path):
        rc_g, out_g, _ = fw.run_gnu(["--help"])
        rc_f, out_f, _ = fw.run_asm(["--help"])
        fw.report_result(rc_f == rc_g, "pinky: --help exit code matches GNU")


if __name__ == '__main__':
    fw = SecurityTestFramework(config)
    fw.run_all(tool_specific_fn=tool_specific_tests)
