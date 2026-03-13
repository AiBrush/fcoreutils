#!/usr/bin/env python3
"""security_tests.py -- Security & memory safety tests for fpr (assembly pr).

Uses shared SecurityTestFramework.
fpr paginates and columnates files for printing.
"""

import os
import subprocess
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', '..', 'tests'))
from security_framework import SecurityTestFramework

config = {
    'tool_name': 'pr',
    'bin_name': 'fpr',
    'gnu_path': '/usr/bin/pr',
    'bss_size': 524288,
    'max_binary_size': 200000,
    'test_args': ['-t'],
    'test_stdin': b'hello\nworld\n',
    'timeout': 5,
}


def tool_specific_tests(fw):
    """13. pr-specific tests: pagination, input validation, binary data."""
    fw.log("\n=== 13. Tool-Specific: pr ===")

    # Input validation
    rc, _, err = fw.run_asm(["--invalid-option"])
    fw.report_result(rc != 0, "pr: rejects --invalid-option")

    rc, _, err = fw.run_asm(["/nonexistent/file/path"])
    fw.report_result(rc != 0, "pr: rejects missing file")

    # -l 0 doesn't crash
    rc, _, _ = fw.run_asm(["-t", "-l", "0"], stdin_data=b"test\n")
    fw.report_result(rc < 128, "pr: -l 0 doesn't crash")

    # --columns=0
    rc, _, _ = fw.run_asm(["-t", "--columns=0"], stdin_data=b"test\n")
    fw.report_result(rc < 128, "pr: --columns=0 doesn't crash")

    # Very large page width
    rc, _, _ = fw.run_asm(["-t", "-w", "999999"], stdin_data=b"test\n")
    fw.report_result(rc < 128, "pr: -w 999999 doesn't crash")

    # Binary data handling
    data = bytes(range(256)) + b"\n"
    rc, _, _ = fw.run_asm(["-t"], stdin_data=data)
    fw.report_result(rc < 128, "pr: all 256 byte values")

    data = b"hello\x00world\n"
    rc, _, _ = fw.run_asm(["-t"], stdin_data=data)
    fw.report_result(rc < 128, "pr: NUL bytes in lines")

    data = bytes(range(256)) * 100 + b"\n"
    rc, _, _ = fw.run_asm(["-t"], stdin_data=data)
    fw.report_result(rc < 128, "pr: long binary line")

    # Large input
    data = (b"A" * 100 + b"\n") * 10000
    rc, _, _ = fw.run_asm(["-t"], stdin_data=data)
    fw.report_result(rc < 128, "pr: 10000 lines no crash")

    # Long lines
    data = b"X" * 65536 + b"\n"
    rc, _, _ = fw.run_asm(["-t"], stdin_data=data)
    fw.report_result(rc < 128, "pr: 64KB line no crash")

    # SIGPIPE with large output
    script = f'seq 1 100000 | {fw.bin_path} -t | head -1 > /dev/null 2>&1; echo $?'
    p = subprocess.run(["bash", "-c", script], capture_output=True, timeout=fw.timeout, text=True)
    rc = int(p.stdout.strip()) if p.stdout.strip().isdigit() else -1
    fw.report_result(rc in (0, 141), f"pr: SIGPIPE large output (rc={rc})")


if __name__ == '__main__':
    fw = SecurityTestFramework(config)
    fw.run_all(tool_specific_fn=tool_specific_tests)
