#!/usr/bin/env python3
"""Security tests for fstdbuf — uses shared framework."""
import sys, os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', '..', 'tests'))
from security_framework import SecurityTestFramework

config = {
    'tool_name': 'stdbuf',
    'bin_name': 'fstdbuf',
    'gnu_path': '/usr/bin/stdbuf',
    'bss_size': 65536,
    'max_binary_size': 50000,
    'test_args': ['-oL', 'true'],
    'test_stdin': None,
    'timeout': 10,
}

def tool_specific_tests(fw):
    """13. Tool-specific: stdbuf buffering tests."""
    fw.log("\n=== Stdbuf-Specific Tests ===")

    # --help output
    rc, out, _ = fw.run_asm(["--help"])
    fw.report_result(rc == 0 and len(out) > 0, "stdbuf: --help produces output")

    # --version output
    rc, out, _ = fw.run_asm(["--version"])
    fw.report_result(rc == 0 and len(out) > 0, "stdbuf: --version produces output")

    # No args should produce error
    rc, out, err = fw.run_asm([])
    fw.report_result(rc != 0, "stdbuf: no args returns error")

if __name__ == '__main__':
    fw = SecurityTestFramework(config)
    fw.run_all(tool_specific_fn=tool_specific_tests)
