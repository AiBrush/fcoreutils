#!/usr/bin/env python3
"""security_tests.py — Security & memory safety tests for fcsplit.

Uses shared SecurityTestFramework with tool-specific csplit tests.
"""

import atexit
import os
import sys
import tempfile

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', '..', 'tests'))
from security_framework import SecurityTestFramework

# Create temp file with content for test_args (csplit needs file + pattern)
_tf = tempfile.NamedTemporaryFile(mode='w', delete=False, suffix='.txt')
_tf.write("line1\nline2\nline3\n")
_tf.close()
atexit.register(os.unlink, _tf.name)

config = {
    'tool_name': 'csplit',
    'bin_name': 'fcsplit',
    'gnu_path': '/usr/bin/csplit',
    'bss_size': 65536,
    'max_binary_size': 30000,
    'test_args': [_tf.name, '2'],
    'test_stdin': None,
    'timeout': 5,
}


def tool_specific_tests(fw):
    """Category 13: csplit-specific tests."""
    fw.log("\n=== 13. Tool-Specific: csplit ===")

    # --help exits 0
    rc, out, err = fw.run_asm(["--help"])
    fw.report_result(rc == 0 and len(out) > 0, "csplit: --help works")

    # Missing operand
    rc, out, err = fw.run_asm([])
    fw.report_result(rc != 0, "csplit: missing operand exits non-zero")

    # Basic split
    import subprocess
    with tempfile.NamedTemporaryFile(mode="w", delete=False, suffix=".txt") as f:
        for i in range(1, 11):
            f.write(f"{i}\n")
        tmp = f.name
    try:
        with tempfile.TemporaryDirectory() as td:
            p = subprocess.run(
                [fw.bin_path, "-f", os.path.join(td, "out"), tmp, "5"],
                capture_output=True, timeout=5,
            )
            files = sorted([f for f in os.listdir(td) if f.startswith("out")])
            fw.report_result(len(files) >= 1, f"csplit: created output files ({len(files)})")
    finally:
        os.unlink(tmp)


if __name__ == '__main__':
    fw = SecurityTestFramework(config)
    fw.run_all(tool_specific_fn=tool_specific_tests)
