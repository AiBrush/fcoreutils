#!/usr/bin/env python3
"""Security tests for fseq — uses shared framework."""
import sys, os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', '..', 'tests'))
from security_framework import SecurityTestFramework

config = {
    'tool_name': 'seq',
    'bin_name': 'fseq',
    'gnu_path': '/usr/bin/seq',
    'bss_size': 131072,
    'max_binary_size': 100000,
    'test_args': ['5'],
    'test_stdin': None,
    'timeout': 5,
}

def tool_specific_tests(fw):
    """13. Tool-specific: seq number sequence tests."""
    fw.log("\n=== Seq-Specific Tests ===")

    # Basic: seq LAST
    rc_a, out_a, _ = fw.run_asm(["5"])
    rc_g, out_g, _ = fw.run_gnu(["5"])
    fw.report_result(out_a == out_g, "seq: seq 5 matches GNU")
    fw.report_result(out_a == b"1\n2\n3\n4\n5\n", "seq: seq 5 correct output")

    # seq FIRST LAST
    rc_a, out_a, _ = fw.run_asm(["3", "7"])
    rc_g, out_g, _ = fw.run_gnu(["3", "7"])
    fw.report_result(out_a == out_g, "seq: seq 3 7 matches GNU")

    # seq FIRST INCREMENT LAST
    rc_a, out_a, _ = fw.run_asm(["1", "2", "10"])
    rc_g, out_g, _ = fw.run_gnu(["1", "2", "10"])
    fw.report_result(out_a == out_g, "seq: seq 1 2 10 matches GNU")
    fw.report_result(out_a == b"1\n3\n5\n7\n9\n", "seq: seq 1 2 10 correct output")

    # seq 1 (single number)
    rc_a, out_a, _ = fw.run_asm(["1"])
    rc_g, out_g, _ = fw.run_gnu(["1"])
    fw.report_result(out_a == out_g, "seq: seq 1 matches GNU")

    # seq 0 (zero)
    rc_a, out_a, _ = fw.run_asm(["0"])
    rc_g, out_g, _ = fw.run_gnu(["0"])
    fw.report_result(out_a == out_g, "seq: seq 0 matches GNU")

    # Empty range: FIRST > LAST
    rc_a, out_a, _ = fw.run_asm(["5", "1"])
    rc_g, out_g, _ = fw.run_gnu(["5", "1"])
    fw.report_result(out_a == out_g, "seq: empty range (5 1) matches GNU")
    fw.report_result(out_a == b"", "seq: empty range produces no output")

    # Negative numbers
    rc_a, out_a, _ = fw.run_asm(["-3", "3"])
    rc_g, out_g, _ = fw.run_gnu(["-3", "3"])
    fw.report_result(out_a == out_g, "seq: negative start (-3 3) matches GNU")

    # Counting down
    rc_a, out_a, _ = fw.run_asm(["5", "-1", "1"])
    rc_g, out_g, _ = fw.run_gnu(["5", "-1", "1"])
    fw.report_result(out_a == out_g, "seq: counting down (5 -1 1) matches GNU")
    fw.report_result(out_a == b"5\n4\n3\n2\n1\n", "seq: counting down correct output")

    # Counting down to negative
    rc_a, out_a, _ = fw.run_asm(["2", "-1", "-2"])
    rc_g, out_g, _ = fw.run_gnu(["2", "-1", "-2"])
    fw.report_result(out_a == out_g, "seq: counting down to negative matches GNU")

    # -w (equal width / zero padding)
    rc_a, out_a, _ = fw.run_asm(["-w", "1", "10"])
    rc_g, out_g, _ = fw.run_gnu(["-w", "1", "10"])
    fw.report_result(out_a == out_g, "seq: -w zero padding matches GNU")
    first_line = out_a.split(b"\n")[0]
    fw.report_result(first_line == b"01", "seq: -w pads '1' to '01'")

    # -s (custom separator)
    rc_a, out_a, _ = fw.run_asm(["-s", ",", "5"])
    rc_g, out_g, _ = fw.run_gnu(["-s", ",", "5"])
    fw.report_result(out_a == out_g, "seq: -s comma separator matches GNU")
    fw.report_result(out_a == b"1,2,3,4,5\n", "seq: -s comma correct output")

    # -s with space separator
    rc_a, out_a, _ = fw.run_asm(["-s", " ", "3"])
    rc_g, out_g, _ = fw.run_gnu(["-s", " ", "3"])
    fw.report_result(out_a == out_g, "seq: -s space separator matches GNU")

    # Float: seq 0.5
    rc_a, out_a, _ = fw.run_asm(["0.5"])
    rc_g, out_g, _ = fw.run_gnu(["0.5"])
    fw.report_result(out_a == out_g, "seq: float seq 0.5 matches GNU")

    # Float: seq 0.1 0.1 0.5
    rc_a, out_a, _ = fw.run_asm(["0.1", "0.1", "0.5"])
    rc_g, out_g, _ = fw.run_gnu(["0.1", "0.1", "0.5"])
    fw.report_result(out_a == out_g, "seq: float seq 0.1 0.1 0.5 matches GNU")

    # Large integer range (verify count)
    rc_a, out_a, _ = fw.run_asm(["1", "1000"], timeout=10)
    rc_g, out_g, _ = fw.run_gnu(["1", "1000"], timeout=10)
    fw.report_result(out_a == out_g, "seq: seq 1 1000 matches GNU")
    fw.report_result(len(out_a.strip().split(b"\n")) == 1000, "seq: seq 1 1000 has 1000 lines")

    # Error: no arguments
    rc_a, _, _ = fw.run_asm([])
    fw.report_result(rc_a != 0, "seq: no args returns nonzero")

    # Error: invalid number
    rc_a, _, _ = fw.run_asm(["abc"])
    fw.report_result(rc_a != 0, "seq: invalid number returns nonzero")

    # Error: too many arguments
    rc_a, _, _ = fw.run_asm(["1", "2", "3", "4"])
    fw.report_result(rc_a != 0, "seq: too many args returns nonzero")

    # --help
    rc_a, out_a, _ = fw.run_asm(["--help"])
    fw.report_result(rc_a == 0 and len(out_a) > 0, "seq: --help works")

    # --version
    rc_a, out_a, _ = fw.run_asm(["--version"])
    fw.report_result(rc_a == 0 and len(out_a) > 0, "seq: --version works")

    # Step 0 (should error)
    rc_a, _, _ = fw.run_asm(["1", "0", "5"])
    fw.report_result(rc_a != 0, "seq: step 0 returns nonzero")

    # Large output integrity
    rc_a, out_a, _ = fw.run_asm(["1", "10000"], timeout=10)
    rc_g, out_g, _ = fw.run_gnu(["1", "10000"], timeout=10)
    fw.report_result(out_a == out_g, "seq: seq 1 10000 matches GNU exactly")

if __name__ == '__main__':
    fw = SecurityTestFramework(config)
    fw.run_all(tool_specific_fn=tool_specific_tests)
