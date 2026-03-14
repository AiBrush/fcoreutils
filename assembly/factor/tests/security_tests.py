#!/usr/bin/env python3
"""Security tests for ffactor — uses shared framework."""
import sys, os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', '..', 'tests'))
from security_framework import SecurityTestFramework

config = {
    'tool_name': 'factor',
    'bin_name': 'ffactor',
    'gnu_path': '/usr/bin/factor',
    'bss_size': 131072,
    'max_binary_size': 100000,
    'test_args': ['12'],
    'test_stdin': None,
    'timeout': 5,
}

def tool_specific_tests(fw):
    """13. Tool-specific: factor tests."""
    fw.log("\n=== Factor-Specific Tests ===")

    # Basic factorizations
    rc, out, _ = fw.run_asm(["12"])
    fw.report_result(rc == 0 and b"12: 2 2 3" in out, "factor: 12 = 2 2 3")

    rc, out, _ = fw.run_asm(["1"])
    fw.report_result(rc == 0 and b"1:" in out, "factor: 1 (no factors)")

    rc, out, _ = fw.run_asm(["0"])
    fw.report_result(rc == 0 and b"0:" in out, "factor: 0")

    # Large prime
    rc, out, _ = fw.run_asm(["999999937"])
    fw.report_result(rc == 0 and b"999999937: 999999937" in out, "factor: large prime 999999937")

    # 2^63-1
    rc, out, _ = fw.run_asm(["9223372036854775807"])
    fw.report_result(rc < 128, "factor: 2^63-1 no crash")

    # 2^64-1
    rc, out, _ = fw.run_asm(["18446744073709551615"])
    fw.report_result(rc < 128, "factor: 2^64-1 no crash")

    # stdin input
    big_input = "\n".join(str(i) for i in range(1, 10001)) + "\n"
    rc, out, _ = fw.run_asm([], stdin_data=big_input.encode(), timeout=10)
    lines = out.strip().split(b"\n")
    fw.report_result(rc < 128, "factor: stdin 10K numbers no crash")
    fw.report_result(len(lines) == 10000, f"factor: stdin 10K numbers all processed ({len(lines)} lines)")

    # Many args
    args = [str(i) for i in range(1, 101)]
    rc, out, _ = fw.run_asm(args)
    lines = out.strip().split(b"\n")
    fw.report_result(rc == 0 and len(lines) == 100, "factor: 100 args processed correctly")

    # Compare with GNU
    for num in ["12", "1", "0", "999999937", "100"]:
        rc_a, out_a, _ = fw.run_asm([num])
        rc_g, out_g, _ = fw.run_gnu([num])
        fw.report_result(out_a == out_g and rc_a == rc_g, f"factor: GNU match for {num}")

    # Leading zeros
    rc, out, _ = fw.run_asm(["0000012"])
    fw.report_result(rc == 0 and b"12: 2 2 3" in out, "factor: leading zeros")

    # Leading +
    rc, out, _ = fw.run_asm(["+12"])
    fw.report_result(rc == 0 and b"12: 2 2 3" in out, "factor: leading plus")

    # --help/--version
    rc, out, _ = fw.run_asm(["--help"])
    fw.report_result(rc == 0 and len(out) > 0, "factor: --help works")

    rc, out, _ = fw.run_asm(["--version"])
    fw.report_result(rc == 0 and len(out) > 0, "factor: --version works")

if __name__ == '__main__':
    fw = SecurityTestFramework(config)
    fw.run_all(tool_specific_fn=tool_specific_tests)
