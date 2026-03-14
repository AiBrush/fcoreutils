#!/usr/bin/env python3
"""security_tests.py -- Security & memory safety tests for fchcon."""

import sys
import os
import random
import string
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', '..', 'tests'))
from security_framework import SecurityTestFramework

config = {
    'tool_name': 'chcon',
    'bin_name': 'fchcon',
    'gnu_path': '/usr/bin/chcon',
    'bss_size': 65536,
    'max_binary_size': 50000,
    'test_args': ['system_u:object_r:tmp_t:s0', '/nonexistent'],
    'test_stdin': None,
    'timeout': 10,
}


def tool_specific_tests(fw):
    """13. Tool-specific: chcon tests."""
    fw.log("\n=== Tool-Specific: chcon ===")

    # --help exits cleanly
    rc, out, err = fw.run_asm(["--help"])
    fw.report_result(rc == 0, "chcon: --help exits 0")
    fw.report_result(len(out) > 0, "chcon: --help produces output")

    # --version exits cleanly
    rc, out, err = fw.run_asm(["--version"])
    fw.report_result(rc == 0, "chcon: --version exits 0")
    fw.report_result(len(out) > 0, "chcon: --version produces output")

    # Random long flags should not crash
    crash_count = 0
    for i in range(20):
        flags = "--" + "".join(random.choices(string.ascii_lowercase + "-",
                                               k=random.randint(3, 30)))
        rc, out, err = fw.run_asm([flags])
        if rc >= 128:
            crash_count += 1
    fw.report_result(crash_count == 0,
                     f"chcon: 20 random long flags no signal death ({crash_count})")


if __name__ == '__main__':
    fw = SecurityTestFramework(config)
    fw.run_all(tool_specific_fn=tool_specific_tests)
