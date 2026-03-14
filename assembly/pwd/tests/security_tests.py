#!/usr/bin/env python3
"""security_tests.py -- Security & memory safety tests for fpwd (assembly pwd).

Uses shared SecurityTestFramework.
fpwd prints the current working directory using getcwd syscall.
"""

import os
import subprocess
import sys
import tempfile

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', '..', 'tests'))
from security_framework import SecurityTestFramework

config = {
    'tool_name': 'pwd',
    'bin_name': 'fpwd',
    'gnu_path': '/usr/bin/pwd',
    'bss_size': 65536,
    'max_binary_size': 30000,
    'test_args': [],
    'test_stdin': None,
    'timeout': 5,
}


def tool_specific_tests(fw):
    """13. pwd-specific tests: cwd output, deep paths, symlinks."""
    fw.log("\n=== 13. Tool-Specific: pwd ===")

    rc, out, err = fw.run_asm([])
    pwd_str = out.decode(errors="replace").strip()

    fw.report_result(rc == 0, "pwd: exit code 0")
    fw.report_result(len(pwd_str) > 0, "pwd: non-empty output")
    fw.report_result(out.endswith(b"\n"), "pwd: output ends with newline")
    fw.report_result(len(err) == 0, "pwd: no stderr output")

    # Must match os.getcwd()
    cwd = os.getcwd()
    fw.report_result(pwd_str == cwd, f"pwd: matches os.getcwd()")

    # Exactly one line
    lines = out.decode(errors="replace").split("\n")
    non_empty = [l for l in lines if l]
    fw.report_result(len(non_empty) == 1, "pwd: exactly one line of output")

    # Output is an absolute path
    fw.report_result(pwd_str.startswith("/"), "pwd: output is absolute path")

    # Compare with GNU pwd
    if os.path.exists(fw.gnu_path):
        rc_g, out_g, _ = fw.run_gnu([])
        fw.report_result(out == out_g, "pwd: output matches GNU pwd")

    # Deep nested directory
    with tempfile.TemporaryDirectory() as tmpdir:
        deep = tmpdir
        for i in range(20):
            deep = os.path.join(deep, f"level_{i}")
            os.makedirs(deep, exist_ok=True)
        p = subprocess.run([fw.bin_path], capture_output=True, timeout=5, cwd=deep)
        if p.returncode == 0:
            fw.report_result(p.stdout.decode().strip() == deep,
                             "pwd: deep path (20 levels) correct")

    # Symlink directory
    with tempfile.TemporaryDirectory() as tmpdir:
        real_dir = os.path.join(tmpdir, "real")
        link_dir = os.path.join(tmpdir, "link")
        os.makedirs(real_dir)
        os.symlink(real_dir, link_dir)
        p = subprocess.run([fw.bin_path], capture_output=True, timeout=5, cwd=link_dir)
        if p.returncode == 0:
            actual = p.stdout.decode().strip()
            fw.report_result(actual == link_dir or actual == real_dir,
                             f"pwd: symlink dir -> '{actual}'")

    # Ignores arguments
    rc, _, _ = fw.run_asm(["ignored"])
    fw.report_result(rc < 128, "pwd: with extra arg -> no signal death")

    # Multiple runs same result
    results = [fw.run_asm([])[1] for _ in range(10)]
    fw.report_result(all(r == results[0] for r in results), "pwd: 10 runs same output")

    # With -- separator
    rc, _, _ = fw.run_asm(["--"])
    fw.report_result(rc < 128, "pwd: -- -> no signal death")


if __name__ == '__main__':
    fw = SecurityTestFramework(config)
    fw.run_all(tool_specific_fn=tool_specific_tests)
