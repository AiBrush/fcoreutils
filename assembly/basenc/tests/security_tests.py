#!/usr/bin/env python3
"""security_tests.py -- Security & memory safety tests for fbasenc."""

import os
import sys
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', '..', 'tests'))
from security_framework import SecurityTestFramework

config = {
    'tool_name': 'basenc',
    'bin_name': 'fbasenc',
    'gnu_path': '/usr/bin/basenc',
    'bss_size': 65536,
    'max_binary_size': 30000,
    'test_args': ['--base64'],
    'test_stdin': b'hello world\n',
    'timeout': 5,
}


def tool_specific_tests(fw):
    """13. Tool-specific: basenc encoding/decoding tests."""
    fw.log("\n=== Tool-Specific: basenc ===")

    # Test all encoding modes don't crash on various inputs
    modes = ["--base64", "--base64url", "--base32", "--base32hex", "--base16",
             "--base2msbf", "--base2lsbf", "--z85"]

    for mode in modes:
        rc, _, _ = fw.run_asm([mode], stdin_data=os.urandom(4096))
        fw.report_result(rc < 128, f"basenc: {mode} encode random 4KB no crash (rc={rc})")

    # Decode mode fuzzing
    for mode in modes:
        rc, _, _ = fw.run_asm([mode, "-d"], stdin_data=os.urandom(1024))
        fw.report_result(rc < 128, f"basenc: {mode} -d random 1KB no crash (rc={rc})")

    # Z85 with non-multiple-of-4
    for size in [1, 2, 3, 5, 6, 7]:
        rc, _, _ = fw.run_asm(["--z85"], stdin_data=b"A" * size)
        fw.report_result(rc != 0, f"basenc: z85 {size} bytes (non-mult-4) returns error")

    # Z85 with exact multiples of 4
    for size in [4, 8, 12, 100]:
        data = os.urandom(size)
        rc, _, _ = fw.run_asm(["--z85"], stdin_data=data)
        fw.report_result(rc == 0, f"basenc: z85 {size} bytes (mult-4) success")


if __name__ == '__main__':
    fw = SecurityTestFramework(config)
    fw.run_all(tool_specific_fn=tool_specific_tests)
