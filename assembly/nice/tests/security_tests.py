#!/usr/bin/env python3
"""Security tests for fnice — uses shared framework."""
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', '..', 'tests'))
from security_framework import SecurityTestFramework

config = {
    'tool_name': 'nice',
    'bin_name': 'fnice',
    'gnu_path': '/usr/bin/nice',
    'bss_size': 4096,
    'max_binary_size': 30000,
    'test_args': [],
    'test_stdin': None,
    'timeout': 10,
}


def tool_specific_tests(fw):
    """13. Tool-specific: nice — scheduling priority."""
    fw.log("\n=== Tool-Specific: nice ===")

    # No command — print niceness
    rc, out, err = fw.run_asm([])
    fw.report_result(rc == 0, "nice: no command -> exit 0")
    try:
        val = int(out.decode().strip())
        fw.report_result(True, f"nice: no command -> prints niceness value ({val})")
    except ValueError:
        fw.report_result(False, f"nice: no command -> expected integer, got: {out!r}")

    # Run true
    rc, _, _ = fw.run_asm(["true"])
    fw.report_result(rc == 0, "nice: true -> exit 0")

    # Run false
    rc, _, _ = fw.run_asm(["false"])
    fw.report_result(rc == 1, "nice: false -> exit 1")

    # Run echo
    rc, out, _ = fw.run_asm(["echo", "hello"])
    fw.report_result(rc == 0, "nice: echo hello -> exit 0")
    fw.report_result(out.strip() == b"hello", "nice: echo hello -> correct output")

    # -n 0 should use current niceness
    rc, out, _ = fw.run_asm(["-n", "0", "echo", "test"])
    fw.report_result(rc == 0, "nice: -n 0 echo test -> exit 0")

    # Nonexistent command
    rc, _, _ = fw.run_asm(["nonexistent_cmd_xyz_abc"])
    fw.report_result(rc == 127, "nice: nonexistent command -> exit 127")

    # Compare with GNU
    if os.path.exists(fw.gnu_path):
        rc_g, out_g, _ = fw.run_gnu([])
        rc_f, out_f, _ = fw.run_asm([])
        fw.report_result(rc_f == rc_g, f"nice: no-args exit matches GNU ({rc_f} vs {rc_g})")
        fw.report_result(out_f.strip() == out_g.strip(), "nice: no-args output matches GNU")


if __name__ == '__main__':
    fw = SecurityTestFramework(config)
    fw.run_all(tool_specific_fn=tool_specific_tests)
