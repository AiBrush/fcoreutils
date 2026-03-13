#!/usr/bin/env python3
"""security_tests.py -- Security & memory safety tests for ftty (assembly tty).

Uses shared SecurityTestFramework. tty prints the terminal name connected
to stdin. When stdin is not a terminal, prints "not a tty" and exits 1.
"""

import os
import sys
import subprocess
import tempfile

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', '..', 'tests'))
from security_framework import SecurityTestFramework

config = {
    'tool_name': 'tty',
    'bin_name': 'ftty',
    'gnu_path': '/usr/bin/tty',
    'bss_size': 4096,
    'max_binary_size': 30000,
    'test_args': [],
    'test_stdin': b'',
    'timeout': 5,
}


def tool_specific_tests(fw):
    """13. tty-specific tests."""
    fw.log("\n=== 13. Tool-Specific: tty ===")

    # When stdin is a pipe (not a tty), should print "not a tty" and exit 1
    rc, out, err = fw.run_asm([])
    tty_str = out.decode(errors="replace").strip()

    fw.report_result(rc == 1, "tty: piped stdin -> exit 1")
    fw.report_result(tty_str == "not a tty", f"tty: piped stdin -> output '{tty_str}' = 'not a tty'")

    # Output ends with newline
    fw.report_result(out.endswith(b"\n"), "tty: output ends with newline")

    # Compare with GNU tty
    if os.path.exists(fw.gnu_path):
        rc_g, out_g, _ = fw.run_gnu([])
        fw.report_result(out == out_g, f"tty: output matches GNU")
        fw.report_result(rc == rc_g, f"tty: exit code matches GNU ({rc} vs {rc_g})")

    # -s (silent) flag
    if os.path.exists(fw.gnu_path):
        rc_g, out_g, _ = fw.run_gnu(["-s"])
        rc_f, out_f, _ = fw.run_asm(["-s"])
        fw.report_result(rc_f == rc_g, f"tty: -s exit code matches GNU ({rc_f} vs {rc_g})")

    # Stdin from /dev/null -- not a tty
    script = f'{fw.bin_path} < /dev/null'
    p = subprocess.run(["bash", "-c", script], capture_output=True, timeout=fw.timeout, text=True)
    fw.report_result(p.stdout.strip() == "not a tty", "tty: stdin from /dev/null -> 'not a tty'")
    fw.report_result(p.returncode == 1, "tty: stdin from /dev/null -> exit 1")

    # Stdin from a file -- not a tty
    with tempfile.NamedTemporaryFile(mode='w', delete=False) as f:
        f.write("test\n")
        tmpfile = f.name
    try:
        script = f'{fw.bin_path} < {tmpfile}'
        p = subprocess.run(["bash", "-c", script], capture_output=True, timeout=fw.timeout, text=True)
        fw.report_result(p.stdout.strip() == "not a tty", "tty: stdin from file -> 'not a tty'")
        fw.report_result(p.returncode == 1, "tty: stdin from file -> exit 1")
    finally:
        os.unlink(tmpfile)

    # No stderr on normal operation
    rc, out, err = fw.run_asm([])
    fw.report_result(len(err) == 0, "tty: no stderr on normal operation")

    # Ignores stdin content
    rc, out, _ = fw.run_asm([], stdin_data=b"fake data\n")
    fw.report_result(rc < 128, "tty: ignores stdin content -> no signal death")

    # With -- separator
    rc, _, _ = fw.run_asm(["--"])
    fw.report_result(rc < 128, "tty: -- -> no signal death")

    # Multiple runs produce same result
    results = [fw.run_asm([])[1] for _ in range(10)]
    fw.report_result(all(r == results[0] for r in results), "tty: 10 runs same output")


if __name__ == '__main__':
    fw = SecurityTestFramework(config)
    fw.run_all(tool_specific_fn=tool_specific_tests)
