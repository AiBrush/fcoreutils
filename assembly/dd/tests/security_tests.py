#!/usr/bin/env python3
"""Security tests for fdd — uses shared framework."""
import sys, os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', '..', 'tests'))
from security_framework import SecurityTestFramework

config = {
    'tool_name': 'dd',
    'bin_name': 'fdd',
    'gnu_path': '/usr/bin/dd',
    'bss_size': 65536,
    'max_binary_size': 30000,
    'test_args': ['if=/dev/null'],
    'test_stdin': b"test",
    'timeout': 5,
}

def tool_specific_tests(fw):
    """13. Tool-specific: dd copy/convert tests."""
    fw.log("\n=== Dd-Specific Tests ===")

    # Basic copy
    rc, out, err = fw.run_asm(["if=/dev/null"], stdin_data=b"hello\n")
    fw.report_result(rc == 0, "dd: if=/dev/null exits 0")

    # Stats output to stderr
    rc, out, err = fw.run_asm([], stdin_data=b"hello\n")
    fw.report_result(b"records in" in err or b"records" in err, "dd: stats written to stderr")

    # status=none suppresses stderr
    rc, out, err = fw.run_asm(["status=none"], stdin_data=b"hello\n")
    fw.report_result(err == b"" or len(err) == 0, "dd: status=none suppresses stderr")

    # Copy stdin to stdout
    rc, out, err = fw.run_asm(["status=none"], stdin_data=b"test data\n")
    fw.report_result(out == b"test data\n", "dd: stdin passes to stdout")

    # Empty input
    rc, out, err = fw.run_asm(["status=none"], stdin_data=b"")
    fw.report_result(out == b"" and rc == 0, "dd: empty input")

    # Large data
    data = b"X" * 100000
    rc, out, err = fw.run_asm(["status=none"], stdin_data=data)
    fw.report_result(out == data, "dd: 100KB passthrough")

if __name__ == '__main__':
    fw = SecurityTestFramework(config)
    fw.run_all(tool_specific_fn=tool_specific_tests)
