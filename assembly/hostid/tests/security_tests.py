#!/usr/bin/env python3
"""security_tests.py -- Security & memory safety tests for fhostid.

Uses the shared SecurityTestFramework for categories 1-12,
plus tool-specific tests for hostid (8-char hex, matches gethostid).
"""

import sys
import os
import ctypes
import re

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', '..', 'tests'))
from security_framework import SecurityTestFramework

config = {
    'tool_name': 'hostid',
    'bin_name': 'fhostid',
    'gnu_path': '/usr/bin/hostid',
    'bss_size': 65536,
    'max_binary_size': 30000,
    'test_args': [],
    'test_stdin': None,
    'timeout': 5,
}


def tool_specific_tests(fw):
    """Category 13: hostid-specific tests."""
    fw.log("\n=== Tool-Specific: hostid ===")

    rc, out, err = fw.run_asm([])
    hostid_str = out.decode(errors="replace").strip()

    fw.report_result(rc == 0, "hostid: exit code 0")
    fw.report_result(len(hostid_str) > 0, "hostid: non-empty output")
    fw.report_result(len(hostid_str) == 8, f"hostid: output '{hostid_str}' is 8 characters")

    is_hex = re.match(r'^[0-9a-f]{8}$', hostid_str)
    fw.report_result(is_hex is not None, f"hostid: output '{hostid_str}' is lowercase hex")

    try:
        val = int(hostid_str, 16)
        fw.report_result(True, f"hostid: parses as hex integer {val}")
    except ValueError:
        fw.report_result(False, f"hostid: '{hostid_str}' is not valid hex")

    # Match gethostid() via ctypes
    try:
        libc = ctypes.CDLL("libc.so.6")
        libc.gethostid.restype = ctypes.c_long
        c_hostid = libc.gethostid()
        expected = f"{c_hostid & 0xFFFFFFFF:08x}"
        fw.report_result(hostid_str == expected,
                         f"hostid: output '{hostid_str}' matches gethostid() '{expected}'")
    except Exception as e:
        fw.skip_test(f"hostid: gethostid() comparison", str(e))

    # Compare with GNU hostid
    if os.path.exists(fw.gnu_path):
        rc_g, out_g, _ = fw.run_gnu([])
        gnu_str = out_g.decode(errors="replace").strip()
        fw.report_result(hostid_str == gnu_str,
                         f"hostid: '{hostid_str}' matches GNU '{gnu_str}'")

    fw.report_result(out.endswith(b"\n"), "hostid: output ends with newline")

    lines = out.decode(errors="replace").split("\n")
    non_empty = [l for l in lines if l]
    fw.report_result(len(non_empty) == 1, "hostid: exactly one line of output")
    fw.report_result(len(err) == 0, "hostid: no stderr output")

    # Ignores arguments
    rc2, _, _ = fw.run_asm(["ignored_arg"])
    fw.report_result(rc2 < 128, "hostid: with extra arg no crash")

    # Multiple runs produce same result
    results = [fw.run_asm([])[1] for _ in range(10)]
    fw.report_result(all(r == results[0] for r in results), "hostid: 10 runs same output")

    # With -- separator
    rc, _, _ = fw.run_asm(["--"])
    fw.report_result(rc < 128, "hostid: -- separator no crash")


if __name__ == '__main__':
    fw = SecurityTestFramework(config)
    fw.run_all(tool_specific_fn=tool_specific_tests)
