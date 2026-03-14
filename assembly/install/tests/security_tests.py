#!/usr/bin/env python3
"""security_tests.py -- Security & memory safety tests for finstall.

Uses the shared SecurityTestFramework for categories 1-12,
plus tool-specific tests for install behavior.
"""

import sys
import os
import tempfile

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', '..', 'tests'))
from security_framework import SecurityTestFramework

config = {
    'tool_name': 'install',
    'bin_name': 'finstall',
    'gnu_path': '/usr/bin/install',
    'bss_size': 65536,
    'max_binary_size': 30000,
    'test_args': ['--help'],
    'test_stdin': None,
    'timeout': 5,
}


def tool_specific_tests(fw):
    """Category 13: install-specific tests."""
    fw.log("\n=== Tool-Specific: install ===")

    # --help
    rc, out, err = fw.run_asm(["--help"])
    fw.report_result(rc == 0 and len(out) > 0, "install: --help works")

    # Basic file copy
    with tempfile.NamedTemporaryFile(mode="w", delete=False) as sf:
        sf.write("test content\n")
        src = sf.name
    with tempfile.NamedTemporaryFile(delete=False) as df:
        dst = df.name
    try:
        _ = fw.run_asm([src, dst])
        with open(dst, "r") as f:
            content = f.read()
        fw.report_result(content == "test content\n", "install: basic file copy")

        # Check permissions (should be 755)
        mode = oct(os.stat(dst).st_mode)[-3:]
        fw.report_result(mode == "755", f"install: default mode 755 (got {mode})")
    finally:
        os.unlink(src)
        os.unlink(dst)

    # Create directory
    with tempfile.TemporaryDirectory() as td:
        new_dir = os.path.join(td, "testdir")
        rc, out, err = fw.run_asm(["-d", new_dir])
        fw.report_result(os.path.isdir(new_dir), "install: -d creates directory")

    # Missing operand
    rc, out, err = fw.run_asm([])
    fw.report_result(rc != 0, "install: missing operand exits non-zero")


if __name__ == '__main__':
    fw = SecurityTestFramework(config)
    fw.run_all(tool_specific_fn=tool_specific_tests)
