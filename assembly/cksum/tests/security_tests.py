#!/usr/bin/env python3
"""security_tests.py -- Security & memory safety tests for fcksum (assembly cksum).

Uses shared SecurityTestFramework.
fcksum prints CRC checksum and byte count of each file.
"""

import os
import sys
import tempfile

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', '..', 'tests'))
from security_framework import SecurityTestFramework
from shutil import which

config = {
    'tool_name': 'cksum',
    'bin_name': 'fcksum',
    'gnu_path': '/usr/bin/cksum',
    'bss_size': 65536,
    'max_binary_size': 30000,
    'test_args': ['/dev/null'],
    'test_stdin': None,
    'timeout': 5,
}


def tool_specific_tests(fw):
    """13. cksum-specific tests: CRC checksum behavior."""
    fw.log("\n=== 13. Tool-Specific: cksum ===")

    GNU = '/usr/bin/cksum'

    # Known CRC values via stdin
    known_values = [
        (b"123456789", "930766865 9\n"),
        (b"", "4294967295 0\n"),
        (b"hello\n", "3015617425 6\n"),
    ]
    for data, expected in known_values:
        rc, out, err = fw.run_asm([], stdin_data=data)
        fw.report_result(
            out.decode(errors='replace') == expected,
            f"cksum: stdin '{data.decode(errors='replace')}' -> {expected.strip()}"
        )

    # /dev/null
    rc, out, err = fw.run_asm(['/dev/null'])
    fw.report_result(
        out == b"4294967295 0 /dev/null\n",
        "cksum: /dev/null -> 4294967295 0 /dev/null"
    )

    # Multiple files
    with tempfile.TemporaryDirectory() as td:
        f1 = os.path.join(td, "a.txt")
        f2 = os.path.join(td, "b.txt")
        with open(f1, "wb") as f:
            f.write(b"123456789")
        with open(f2, "wb") as f:
            f.write(b"hello\n")

        rc, out, err = fw.run_asm([f1, f2])
        lines = out.decode().strip().split("\n")
        fw.report_result(len(lines) == 2, "cksum: multiple files -> two output lines")
        if lines:
            fw.report_result(lines[0].startswith("930766865 9 "), "cksum: first file CRC correct")
        if len(lines) > 1:
            fw.report_result(lines[1].startswith("3015617425 6 "), "cksum: second file CRC correct")

    # Compare with GNU for various file contents
    gnu_path = which('cksum')
    if gnu_path:
        with tempfile.TemporaryDirectory() as td:
            for i, content in enumerate([b"test data\n", b"\x00" * 100,
                                          b"A" * 10000, bytes(range(256))]):
                fpath = os.path.join(td, f"test_{i}")
                with open(fpath, "wb") as f:
                    f.write(content)
                rc_f, out_f, _ = fw.run_asm([fpath])
                rc_g, out_g, _ = fw.run([gnu_path, fpath])
                fw.report_result(out_f == out_g, f"cksum: file content {i} matches GNU")

        # stdin comparison
        for data, desc in [(b"123456789", "stdin:123456789"), (b"", "stdin:empty"),
                           (b"hello\n", "stdin:hello+nl")]:
            rc_f, out_f, _ = fw.run_asm([], stdin_data=data)
            rc_g, out_g, _ = fw.run([gnu_path], stdin_data=data)
            fw.report_result(out_f == out_g and rc_f == rc_g,
                             f"cksum: {desc} matches GNU")

    # Large file
    with tempfile.TemporaryDirectory() as td:
        fpath = os.path.join(td, "large")
        with open(fpath, "wb") as f:
            f.write(b"X" * 100000)
        rc, out, err = fw.run_asm([fpath])
        fw.report_result(rc == 0 and len(out) > 0, "cksum: 100KB file -> no crash")

    # Error: nonexistent file
    rc, out, err = fw.run_asm(['/nonexistent/file'])
    fw.report_result(rc != 0, "cksum: nonexistent file -> non-zero exit")

    # Mixed valid + invalid
    with tempfile.TemporaryDirectory() as td:
        fpath = os.path.join(td, "valid.txt")
        with open(fpath, "wb") as f:
            f.write(b"hello")
        rc, out, err = fw.run_asm(['/nonexistent', fpath])
        fw.report_result(rc != 0, "cksum: mixed valid+invalid -> non-zero exit")
        fw.report_result(len(out) > 0, "cksum: mixed valid+invalid -> produces some output")


if __name__ == '__main__':
    fw = SecurityTestFramework(config)
    fw.run_all(tool_specific_fn=tool_specific_tests)
