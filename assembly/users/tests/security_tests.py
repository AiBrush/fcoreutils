#!/usr/bin/env python3
"""Security tests for fusers — uses shared framework."""
import sys, os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', '..', 'tests'))
from security_framework import SecurityTestFramework
from shutil import which

config = {
    'tool_name': 'users',
    'bin_name': 'fusers',
    'gnu_path': '/usr/bin/users',
    'bss_size': 65536,
    'max_binary_size': 100000,
    'test_args': [],
    'test_stdin': None,
    'timeout': 5,
}

def tool_specific_tests(fw):
    """13. Tool-specific: users tests."""
    fw.log("\n=== Users-Specific Tests ===")
    gnu_path = which("users")

    # Default output: either empty or space-separated usernames
    rc, out, err = fw.run_asm([])
    out_str = out.decode(errors="replace").strip()
    fw.report_result(rc == 0, "users: default invocation exits 0")

    # Output should be space-separated words (usernames) or empty
    if out_str:
        parts = out_str.split()
        all_alpha = all(p.isalnum() or "_" in p or "-" in p or "." in p for p in parts)
        fw.report_result(all_alpha, "users: output is space-separated usernames")
        # Should be sorted
        fw.report_result(parts == sorted(parts), "users: output is sorted")
    else:
        fw.report_result(True, "users: output is space-separated usernames (empty -- no users)")
        fw.report_result(True, "users: output is sorted (empty)")

    # Explicit utmp file
    if os.path.exists("/var/run/utmp"):
        rc, out2, err = fw.run_asm(["/var/run/utmp"])
        fw.report_result(rc == 0, "users: /var/run/utmp argument exits 0")
        fw.report_result(out == out2, "users: explicit /var/run/utmp matches default")

    # wtmp file (may or may not exist)
    if os.path.exists("/var/log/wtmp"):
        rc, out, err = fw.run_asm(["/var/log/wtmp"])
        fw.report_result(rc == 0, "users: /var/log/wtmp argument exits 0")
    else:
        fw.skip_test("users: /var/log/wtmp not available", "file not found")

    # Compare with GNU
    if gnu_path:
        rc_f, out_f, _ = fw.run_asm([])
        rc_g, out_g, _ = fw.run_gnu([])
        # Compare stripped (assembly may emit trailing newline on empty output)
        fw.report_result(out_f.strip() == out_g.strip(), "users: output matches GNU (stripped)")

    # Extra operand (too many args)
    rc, out, err = fw.run_asm(["/var/run/utmp", "extra"])
    fw.report_result(rc != 0, f"users: extra operand exits non-zero (got {rc})")

    # Output ends with newline (or is completely empty)
    rc, out, _ = fw.run_asm([])
    fw.report_result(out == b"" or out.endswith(b"\n"), "users: output ends with newline")

if __name__ == '__main__':
    fw = SecurityTestFramework(config)
    fw.run_all(tool_specific_fn=tool_specific_tests)
