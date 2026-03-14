#!/usr/bin/env python3
"""security_tests.py -- Security & memory safety tests for fchroot (assembly chroot).

Uses shared SecurityTestFramework. chroot requires root for actual operation,
so tests focus on --help/--version and error handling paths.
"""

import os
import sys
import subprocess
import random
import string

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', '..', 'tests'))
from security_framework import SecurityTestFramework

config = {
    'tool_name': 'chroot',
    'bin_name': 'fchroot',
    'gnu_path': '/usr/bin/chroot',
    'bss_size': 65536,
    'max_binary_size': 50000,
    'test_args': ['/nonexistent'],
    'test_stdin': None,
    'timeout': 10,
}


def tool_specific_tests(fw):
    """13. chroot-specific tests."""
    fw.log("\n=== 13. Tool-Specific: chroot ===")

    # --help should exit 0
    rc, out, err = fw.run_asm(['--help'])
    fw.report_result(rc == 0, "chroot: --help exits 0")

    # --version should exit 0
    rc, out, err = fw.run_asm(['--version'])
    fw.report_result(rc == 0, "chroot: --version exits 0")

    # No args should produce usage error
    rc, out, err = fw.run_asm([])
    fw.report_result(rc != 0, "chroot: no args -> nonzero exit")

    # Random long flags should not crash
    crash_count = 0
    for _ in range(20):
        flag = "--" + "".join(random.choices(string.ascii_lowercase + "-", k=random.randint(3, 30)))
        rc, _, _ = fw.run_asm([flag])
        if rc >= 128:
            crash_count += 1
    fw.report_result(crash_count == 0, f"chroot: 20 random flags no signal death ({crash_count})")

    # 50 simultaneous --help
    procs = []
    for _ in range(50):
        p = subprocess.Popen([fw.bin_path, "--help"],
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        procs.append(p)
    crash_count = 0
    for p in procs:
        try:
            p.communicate(timeout=fw.timeout)
            if p.returncode != 0:
                crash_count += 1
        except subprocess.TimeoutExpired:
            p.kill()
            crash_count += 1
    fw.report_result(crash_count == 0, f"chroot: 50 simultaneous --help ({crash_count} failures)")


if __name__ == '__main__':
    fw = SecurityTestFramework(config)
    fw.run_all(tool_specific_fn=tool_specific_tests)
