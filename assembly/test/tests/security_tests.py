#!/usr/bin/env python3
"""Security tests for ftest — uses shared framework."""
import sys, os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', '..', 'tests'))
from security_framework import SecurityTestFramework

config = {
    'tool_name': 'test',
    'bin_name': 'ftest',
    'gnu_path': '/usr/bin/test',
    'bss_size': 4096,
    'max_binary_size': 30000,
    'test_args': ['-f', '/etc/passwd'],
    'test_stdin': None,
}

def tool_specific_tests(fw):
    """13. Tool-specific: test — conditional expression tests."""
    fw.log("\n=== Tool-Specific: test ===")

    # File exists
    rc, _, _ = fw.run_asm(["-e", "/etc/passwd"])
    fw.report_result(rc == 0, "test: -e /etc/passwd is true")

    rc, _, _ = fw.run_asm(["-e", "/nonexistent"])
    fw.report_result(rc == 1, "test: -e /nonexistent is false")

    # Regular file
    rc, _, _ = fw.run_asm(["-f", "/etc/passwd"])
    fw.report_result(rc == 0, "test: -f /etc/passwd is true")

    # Directory
    rc, _, _ = fw.run_asm(["-d", "/tmp"])
    fw.report_result(rc == 0, "test: -d /tmp is true")

    rc, _, _ = fw.run_asm(["-d", "/etc/passwd"])
    fw.report_result(rc == 1, "test: -d /etc/passwd is false")

    # String tests
    rc, _, _ = fw.run_asm(["-n", "hello"])
    fw.report_result(rc == 0, "test: -n hello is true")

    rc, _, _ = fw.run_asm(["-z", ""])
    fw.report_result(rc == 0, "test: -z empty is true")

    rc, _, _ = fw.run_asm(["-z", "hello"])
    fw.report_result(rc == 1, "test: -z hello is false")

    # Integer comparison
    rc, _, _ = fw.run_asm(["5", "-eq", "5"])
    fw.report_result(rc == 0, "test: 5 -eq 5 is true")

    rc, _, _ = fw.run_asm(["3", "-lt", "5"])
    fw.report_result(rc == 0, "test: 3 -lt 5 is true")

    # No args = false
    rc, _, _ = fw.run_asm([])
    fw.report_result(rc == 1, "test: no args exits 1 (false)")

    # String equality
    rc, _, _ = fw.run_asm(["hello", "=", "hello"])
    fw.report_result(rc == 0, "test: string equality true")

    rc, _, _ = fw.run_asm(["hello", "!=", "world"])
    fw.report_result(rc == 0, "test: string inequality true")

if __name__ == '__main__':
    fw = SecurityTestFramework(config)
    fw.run_all(tool_specific_fn=tool_specific_tests)
