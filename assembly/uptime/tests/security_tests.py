#!/usr/bin/env python3
"""Security tests for fuptime — uses shared framework."""
import sys, os, re
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', '..', 'tests'))
from security_framework import SecurityTestFramework
from shutil import which

config = {
    'tool_name': 'uptime',
    'bin_name': 'fuptime',
    'gnu_path': '/usr/bin/uptime',
    'bss_size': 65536,
    'max_binary_size': 100000,
    'test_args': [],
    'test_stdin': None,
    'timeout': 5,
}

def tool_specific_tests(fw):
    """13. Tool-specific: uptime tests."""
    fw.log("\n=== Uptime-Specific Tests ===")
    gnu_path = which("uptime")

    # Default output should contain load average or "up"
    rc, out, err = fw.run_asm([])
    out_str = out.decode(errors="replace").strip()
    fw.report_result("up" in out_str or "load" in out_str,
                     "uptime: default output contains 'up' or 'load'")

    # Output should contain load average
    fw.report_result("load average" in out_str or "load" in out_str,
                     "uptime: output contains load average info")

    # Output should have a time-like pattern (HH:MM:SS or HH:MM)
    has_time = bool(re.search(r'\d{1,2}:\d{2}', out_str))
    fw.report_result(has_time, "uptime: output contains time pattern")

    # Output should be a single line
    lines = out_str.split("\n")
    fw.report_result(len(lines) == 1, f"uptime: output is single line ({len(lines)} lines)")

    # -p / --pretty flag
    rc, out, err = fw.run_asm(["-p"])
    fw.report_result(rc == 0, "uptime: -p flag exits 0")
    out_p = out.decode(errors="replace").strip()
    fw.report_result("up" in out_p, "uptime: -p output contains 'up'")

    # -s / --since flag
    rc, out, err = fw.run_asm(["-s"])
    fw.report_result(rc == 0, "uptime: -s flag exits 0")
    out_s = out.decode(errors="replace").strip()
    has_date = bool(re.search(r'\d{4}-\d{2}-\d{2}', out_s))
    fw.report_result(has_date, "uptime: -s output contains date pattern")

    # Compare with GNU
    if gnu_path:
        # -s should produce similar date
        rc_f, out_f, _ = fw.run_asm(["-s"])
        rc_g, out_g, _ = fw.run_gnu(["-s"])
        fw.report_result(rc_f == rc_g, "uptime: -s exit code matches GNU")

        # -p should both exit 0
        rc_f, _, _ = fw.run_asm(["-p"])
        rc_g, _, _ = fw.run_gnu(["-p"])
        fw.report_result(rc_f == rc_g, "uptime: -p exit code matches GNU")

    # Output ends with newline
    rc, out, _ = fw.run_asm([])
    fw.report_result(out.endswith(b"\n"), "uptime: output ends with newline")

    # No trailing space before newline
    fw.report_result(not out.endswith(b" \n"), "uptime: no trailing space before newline")

if __name__ == '__main__':
    fw = SecurityTestFramework(config)
    fw.run_all(tool_specific_fn=tool_specific_tests)
