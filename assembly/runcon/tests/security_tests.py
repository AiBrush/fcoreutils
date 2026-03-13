#!/usr/bin/env python3
"""Security tests for fruncon — uses shared framework."""
import sys, os, random, string
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', '..', 'tests'))
from security_framework import SecurityTestFramework

config = {
    'tool_name': 'runcon',
    'bin_name': 'fruncon',
    'gnu_path': '/usr/bin/runcon',
    'bss_size': 65536,
    'max_binary_size': 50000,
    'test_args': ['--help'],
    'test_stdin': None,
    'timeout': 10,
}

def tool_specific_tests(fw):
    """13. Tool-specific: runcon behavior tests."""
    fw.log("\n=== Runcon-Specific Tests ===")

    # --help produces output
    rc, out, err = fw.run_asm(["--help"])
    fw.report_result(rc == 0 and len(out) > 0, "runcon: --help works")

    # --version produces output
    rc, out, err = fw.run_asm(["--version"])
    fw.report_result(rc == 0 and len(out) > 0, "runcon: --version works")

    # Random long flags should not crash
    crash_count = 0
    for i in range(20):
        flags = "--" + "".join(random.choices(string.ascii_lowercase + "-", k=random.randint(3, 30)))
        rc, out, err = fw.run_asm([flags])
        if rc >= 128:
            crash_count += 1
    fw.report_result(crash_count == 0, f"runcon: 20 random long flags no signal death ({crash_count})")

if __name__ == '__main__':
    fw = SecurityTestFramework(config)
    fw.run_all(tool_specific_fn=tool_specific_tests)
