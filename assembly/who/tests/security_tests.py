#!/usr/bin/env python3
"""Security tests for fwho — uses shared framework."""
import sys, os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', '..', 'tests'))
from security_framework import SecurityTestFramework
from shutil import which

config = {
    'tool_name': 'who',
    'bin_name': 'fwho',
    'gnu_path': '/usr/bin/who',
    'bss_size': 65536,
    'max_binary_size': 200000,
    'test_args': [],
    'test_stdin': None,
    'timeout': 5,
}

def tool_specific_tests(fw):
    """13. Tool-specific: who tests."""
    fw.log("\n=== Who-Specific Tests ===")
    gnu_path = which("who")

    # --help output
    rc, out, err = fw.run_asm(["--help"])
    text = out + err
    fw.report_result(b"Usage" in text or b"who" in text, "who: --help contains usage info")

    # --version output
    rc, out, err = fw.run_asm(["--version"])
    text = out + err
    fw.report_result(b"coreutils" in text or b"who" in text, "who: --version contains version info")

    # Compare exit codes with GNU
    if gnu_path:
        for args in [["--help"], ["--version"]]:
            rc_f, _, _ = fw.run_asm(args)
            rc_g, _, _ = fw.run_gnu(args)
            fw.report_result(rc_f == rc_g, f"who: exit code matches GNU for {args}")

if __name__ == '__main__':
    fw = SecurityTestFramework(config)
    fw.run_all(tool_specific_fn=tool_specific_tests)
