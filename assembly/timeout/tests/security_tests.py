#!/usr/bin/env python3
"""Security tests for ftimeout — uses shared framework."""
import sys, os, time
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', '..', 'tests'))
from security_framework import SecurityTestFramework

config = {
    'tool_name': 'timeout',
    'bin_name': 'ftimeout',
    'gnu_path': '/usr/bin/timeout',
    'bss_size': 4096,
    'max_binary_size': 30000,
    'test_args': ['5', 'true'],
    'test_stdin': None,
    'timeout': 15,
}

def tool_specific_tests(fw):
    """13. Tool-specific: timeout — command timeout tests."""
    fw.log("\n=== Tool-Specific: timeout ===")

    # Command completes before timeout
    rc, out, _ = fw.run_asm(["5", "echo", "hello"])
    fw.report_result(rc == 0, "timeout: echo completes -> exit 0")
    fw.report_result(out.strip() == b"hello", "timeout: echo output correct")

    # Command times out
    start = time.monotonic()
    rc, _, _ = fw.run_asm(["1", "sleep", "60"], timeout=5)
    elapsed = time.monotonic() - start
    fw.report_result(rc == 124, f"timeout: timeout fires -> exit 124 (got {rc})")
    fw.report_result(0.5 < elapsed < 4, f"timeout: elapsed {elapsed:.1f}s")

    # Exit code passthrough
    rc, _, _ = fw.run_asm(["5", "true"])
    fw.report_result(rc == 0, "timeout: true -> exit 0")

    rc, _, _ = fw.run_asm(["5", "false"])
    fw.report_result(rc == 1, "timeout: false -> exit 1")

    # Nonexistent command
    rc, _, _ = fw.run_asm(["5", "nonexistent_cmd_xyz"])
    fw.report_result(rc == 127, f"timeout: nonexistent -> exit 127 (got {rc})")

    # -s option
    rc, _, _ = fw.run_asm(["-s", "KILL", "1", "sleep", "60"], timeout=5)
    fw.report_result(rc in (124, 137), f"timeout: -s KILL -> exit {rc}")

    # --foreground
    rc, _, _ = fw.run_asm(["--foreground", "1", "sleep", "60"], timeout=5)
    fw.report_result(rc == 124, f"timeout: --foreground -> exit 124 (got {rc})")

    # Compare with GNU
    if os.path.exists(fw.gnu_path):
        rc_g, out_g, _ = fw.run_gnu(["5", "echo", "compare"])
        rc_f, out_f, _ = fw.run_asm(["5", "echo", "compare"])
        fw.report_result(rc_f == rc_g, f"timeout: exit code matches GNU ({rc_f} vs {rc_g})")
        fw.report_result(out_f == out_g, "timeout: output matches GNU")

if __name__ == '__main__':
    fw = SecurityTestFramework(config)
    fw.run_all(tool_specific_fn=tool_specific_tests)
