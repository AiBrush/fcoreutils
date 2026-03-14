#!/usr/bin/env python3
"""Security tests for fdir — uses shared framework."""
import sys, os, tempfile
from pathlib import Path
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', '..', 'tests'))
from security_framework import SecurityTestFramework

config = {
    'tool_name': 'dir',
    'bin_name': 'fdir',
    'gnu_path': '/usr/bin/dir',
    'bss_size': 65536,
    'max_binary_size': 100000,
    'test_args': ['/tmp'],
    'test_stdin': None,
    'timeout': 10,
}

def tool_specific_tests(fw):
    """13. Tool-specific: dir listing tests."""
    fw.log("\n=== Dir-Specific Tests ===")
    with tempfile.TemporaryDirectory() as td:
        for name in ["aaa", "bbb", ".hidden"]:
            Path(td, name).touch()
        # dir default is multi-column, but -1 gives one per line
        rc, out, _ = fw.run_asm(["-1", td])
        names = out.decode().strip().split("\n")
        fw.report_result("aaa" in names, "dir: -1 lists files")
        fw.report_result(".hidden" not in names, "dir: hidden excluded by default")
        rc, out, _ = fw.run_asm(["-1a", td])
        names = out.decode().strip().split("\n")
        fw.report_result(".hidden" in names, "dir: -a shows hidden")

if __name__ == '__main__':
    fw = SecurityTestFramework(config)
    fw.run_all(tool_specific_fn=tool_specific_tests)
