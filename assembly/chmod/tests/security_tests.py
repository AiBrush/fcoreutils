#!/usr/bin/env python3
"""security_tests.py -- Security & memory safety tests for fchmod (assembly chmod).

Uses shared SecurityTestFramework.
fchmod changes file mode bits (like GNU chmod).
"""

import os
import sys
import shutil
import subprocess
import tempfile

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', '..', 'tests'))
from security_framework import SecurityTestFramework

config = {
    'tool_name': 'chmod',
    'bin_name': 'fchmod',
    'gnu_path': '/usr/bin/chmod',
    'bss_size': 65536,
    'max_binary_size': 102400,
    'test_args': ['--help'],
    'test_stdin': None,
    'timeout': 5,
}


def tool_specific_tests(fw):
    """13. chmod-specific tests: permission changes."""
    fw.log("\n=== 13. Tool-Specific: chmod ===")

    tmpdir = tempfile.mkdtemp()
    try:
        tf = os.path.join(tmpdir, "chmod_test")
        open(tf, "w").close()
        os.chmod(tf, 0o644)

        # Octal mode change
        rc, _, _ = fw.run_asm(["755", tf])
        actual = oct(os.stat(tf).st_mode & 0o7777)
        fw.report_result(rc == 0 and actual == "0o755", f"chmod: 755 -> {actual}")

        os.chmod(tf, 0o644)
        rc, _, _ = fw.run_asm(["600", tf])
        actual = oct(os.stat(tf).st_mode & 0o7777)
        fw.report_result(rc == 0 and actual == "0o600", f"chmod: 600 -> {actual}")

        # Various modes
        for mode in ["644", "755", "600", "777", "000"]:
            os.chmod(tf, 0o644)
            rc, _, _ = fw.run_asm([mode, tf])
            fw.report_result(rc >= 0 and rc < 128, f"chmod: mode {mode} -> no crash")

        # Error on nonexistent file
        rc, _, err = fw.run_asm(["755", os.path.join(tmpdir, "no_such_file")])
        fw.report_result(rc != 0, "chmod: nonexistent file -> error exit")

        # No args -> nonzero exit
        rc, _, _ = fw.run_asm([])
        fw.report_result(rc != 0, "chmod: no args -> nonzero exit")

        # Multiple files
        os.chmod(tf, 0o644)
        rc, _, _ = fw.run_asm(["755", tf, tf, tf, tf, tf])
        fw.report_result(rc >= 0 and rc < 128, "chmod: multiple args -> no crash")

        # Long path
        long_path = os.path.join(tmpdir, "a" * 200)
        rc, _, _ = fw.run_asm(["755", long_path])
        fw.report_result(rc != 0 and rc < 128, "chmod: long path -> error, no crash")

        # Concurrency: 20 parallel chmod
        os.chmod(tf, 0o644)
        procs = []
        for _ in range(20):
            p = subprocess.Popen([fw.bin_path, "755", tf],
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            procs.append(p)
        all_ok = True
        for p in procs:
            p.wait()
            if p.returncode < 0 or p.returncode >= 128:
                all_ok = False
        fw.report_result(all_ok, "chmod: 20 parallel chmod -> no crashes")
    finally:
        shutil.rmtree(tmpdir, ignore_errors=True)


if __name__ == '__main__':
    fw = SecurityTestFramework(config)
    fw.run_all(tool_specific_fn=tool_specific_tests)
