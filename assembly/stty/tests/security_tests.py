#!/usr/bin/env python3
"""Security tests for fstty — uses shared framework."""
import sys, os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', '..', 'tests'))
from security_framework import SecurityTestFramework

config = {
    'tool_name': 'stty',
    'bin_name': 'fstty',
    'gnu_path': '/usr/bin/stty',
    'bss_size': 65536,
    'max_binary_size': 50000,
    'test_args': ['--help'],
    'test_stdin': None,
    'timeout': 10,
}

def tool_specific_tests(fw):
    """13. Tool-specific: stty terminal settings tests."""
    fw.log("\n=== Stty-Specific Tests ===")

    # --help output
    rc, out, _ = fw.run_asm(["--help"])
    fw.report_result(rc == 0 and len(out) > 0, "stty: --help produces output")

    # --version output
    rc, out, _ = fw.run_asm(["--version"])
    fw.report_result(rc == 0 and len(out) > 0, "stty: --version produces output")

if __name__ == '__main__':
    fw = SecurityTestFramework(config)
    fw.run_all(tool_specific_fn=tool_specific_tests)
