#!/usr/bin/env python3
"""Security tests for fexpr — uses shared framework."""
import sys, os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', '..', 'tests'))
from security_framework import SecurityTestFramework

config = {
    'tool_name': 'expr',
    'bin_name': 'fexpr',
    'gnu_path': '/usr/bin/expr',
    'bss_size': 65536,
    'max_binary_size': 30000,
    'test_args': ['1', '+', '1'],
    'test_stdin': None,
    'timeout': 5,
}

def tool_specific_tests(fw):
    """13. Tool-specific: expr tests."""
    fw.log("\n=== Expr-Specific Tests ===")

    # Basic arithmetic
    rc, out, err = fw.run_asm(["1", "+", "1"])
    fw.report_result(out.strip() == b"2" and rc == 0, "expr: 1 + 1 = 2")

    rc, out, err = fw.run_asm(["10", "-", "3"])
    fw.report_result(out.strip() == b"7", "expr: 10 - 3 = 7")

    rc, out, err = fw.run_asm(["3", "*", "4"])
    fw.report_result(out.strip() == b"12", "expr: 3 * 4 = 12")

    rc, out, err = fw.run_asm(["10", "/", "3"])
    fw.report_result(out.strip() == b"3", "expr: 10 / 3 = 3")

    rc, out, err = fw.run_asm(["10", "%", "3"])
    fw.report_result(out.strip() == b"1", "expr: 10 % 3 = 1")

    # String length
    rc, out, err = fw.run_asm(["length", "hello"])
    fw.report_result(out.strip() == b"5", "expr: length hello = 5")

    # Comparison
    rc, out, err = fw.run_asm(["5", "=", "5"])
    fw.report_result(out.strip() == b"1" and rc == 0, "expr: 5 = 5 is true")

    rc, out, err = fw.run_asm(["5", "=", "6"])
    fw.report_result(rc == 1, "expr: 5 = 6 is false (exit 1)")

    # Zero result
    rc, out, err = fw.run_asm(["0"])
    fw.report_result(rc == 1, "expr: 0 exits 1")

    # Missing operand
    rc, out, err = fw.run_asm([])
    fw.report_result(rc != 0, "expr: missing operand exits non-zero")

if __name__ == '__main__':
    fw = SecurityTestFramework(config)
    fw.run_all(tool_specific_fn=tool_specific_tests)
