#!/usr/bin/env python3
"""security_tests.py -- Security & memory safety tests for fsync."""

import sys
import os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', '..', 'tests'))
from security_framework import SecurityTestFramework

from shutil import which

config = {
    'tool_name': 'sync',
    'bin_name': 'fsync',
    'gnu_path': '/usr/bin/sync',
    'bss_size': 65536,
    'max_binary_size': 30000,
    'test_args': [],
    'test_stdin': None,
    'timeout': 10,
}


def tool_specific_tests(fw):
    """13. Tool-specific: sync syscall behavior."""
    fw.log("\n=== Tool-Specific: sync ===")

    # Basic: exit 0, no output
    rc, out, err = fw.run_asm([])
    fw.report_result(rc == 0, "sync: exit code 0")
    fw.report_result(len(out) == 0, "sync: no stdout")
    fw.report_result(len(err) == 0, "sync: no stderr")

    # Verify sync syscall is actually called (via strace)
    if which("strace"):
        rc, out, err = fw.run(
            ["strace", "-e", "trace=sync,fsync,fdatasync,syncfs", fw.bin_path])
        err_text = err.decode(errors="replace")
        has_sync = "sync()" in err_text or "sync(" in err_text
        fw.report_result(has_sync, "sync: actually calls sync() syscall")

    # sync with nonexistent file args gives error
    rc, out, err = fw.run_asm(["some", "random", "args"])
    fw.report_result(rc != 0, "sync: nonexistent file args -> error exit")
    fw.report_result(len(err) > 0, "sync: nonexistent file args -> stderr message")

    # Compare with GNU sync
    if os.path.exists(fw.gnu_path):
        rc_g, out_g, err_g = fw.run_gnu([])
        rc_f, out_f, err_f = fw.run_asm([])
        fw.report_result(rc_f == rc_g, "sync: exit code matches GNU")

    # Ignores stdin
    rc, out, err = fw.run_asm([], stdin_data=b"data\n")
    fw.report_result(rc == 0, "sync: ignores stdin -> exit 0")
    fw.report_result(len(out) == 0, "sync: ignores stdin -> no stdout")

    # Multiple sync calls don't cause issues
    for i in range(10):
        rc, _, _ = fw.run_asm([])
        if rc != 0:
            fw.report_result(False, f"sync: repeated call {i} failed")
            break
    else:
        fw.report_result(True, "sync: 10 repeated calls all exit 0")

    # With -- separator
    rc, _, _ = fw.run_asm(["--"])
    fw.report_result(rc < 128, "sync: -- -> no signal death")


if __name__ == '__main__':
    fw = SecurityTestFramework(config)
    fw.run_all(tool_specific_fn=tool_specific_tests)
