#!/usr/bin/env python3
"""Security tests for fdf — uses shared framework."""
import sys, os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', '..', 'tests'))
from security_framework import SecurityTestFramework

config = {
    'tool_name': 'df',
    'bin_name': 'fdf',
    'gnu_path': '/usr/bin/df',
    'bss_size': 65536,
    'max_binary_size': 100000,
    'test_args': [],
    'test_stdin': None,
    'timeout': 10,
}

def tool_specific_tests(fw):
    """13. Tool-specific: df filesystem tests."""
    fw.log("\n=== Df-Specific Tests ===")

    # -h flag
    rc, out, _ = fw.run_asm(["-h"])
    fw.report_result(rc == 0, "df: -h exit 0")

    # -i flag
    rc, out, _ = fw.run_asm(["-i"])
    fw.report_result(rc == 0, "df: -i exit 0")
    lines = out.decode().strip().split("\n")
    fw.report_result("Inodes" in lines[0] or "IUsed" in lines[0], "df: -i header has inode info")

    # Specific file
    rc, out, _ = fw.run_asm(["/"])
    fw.report_result(rc == 0, "df: / exit 0")
    lines = out.decode().strip().split("\n")
    fw.report_result(len(lines) >= 2, "df: / shows header + filesystem")

    # Nonexistent
    rc, out, err = fw.run_asm(["/nonexistent_path_xyz"])
    fw.report_result(rc != 0, "df: nonexistent -> error exit")

if __name__ == '__main__':
    fw = SecurityTestFramework(config)
    fw.run_all(tool_specific_fn=tool_specific_tests)
