#!/usr/bin/env python3
"""security_tests.py -- Security & memory safety tests for fsum."""

import sys
import os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', '..', 'tests'))
from security_framework import SecurityTestFramework

import tempfile
from shutil import which

config = {
    'tool_name': 'sum',
    'bin_name': 'fsum',
    'gnu_path': '/usr/bin/sum',
    'bss_size': 65536,
    'max_binary_size': 30000,
    'test_args': ['/dev/null'],
    'test_stdin': None,
    'timeout': 5,
}


def tool_specific_tests(fw):
    """13. Tool-specific: sum checksum computation."""
    fw.log("\n=== Tool-Specific: sum ===")
    gnu_path = which("sum")

    tmpdir = tempfile.mkdtemp()
    try:
        # Create test files
        files = {}
        for name, content in [("hello.txt", b"hello"),
                               ("empty.txt", b""),
                               ("bytes.bin", bytes(range(256))),
                               ("1025.bin", b"\x00" * 1025),
                               ("big.bin", b"\xff" * 65536)]:
            path = os.path.join(tmpdir, name)
            with open(path, "wb") as f:
                f.write(content)
            files[name] = path

        if gnu_path:
            # BSD mode comparisons
            for name, path in files.items():
                rc_f, out_f, _ = fw.run_asm([path])
                rc_g, out_g, _ = fw.run_gnu([path])
                fw.report_result(out_f == out_g and rc_f == rc_g,
                                 f"sum: BSD matches GNU for {name}")

            # SysV mode comparisons
            for name, path in files.items():
                rc_f, out_f, _ = fw.run_asm(["-s", path])
                rc_g, out_g, _ = fw.run_gnu(["-s", path])
                fw.report_result(out_f == out_g and rc_f == rc_g,
                                 f"sum: SysV matches GNU for {name}")

            # Multiple files
            all_paths = list(files.values())
            rc_f, out_f, _ = fw.run_asm(all_paths)
            rc_g, out_g, _ = fw.run_gnu(all_paths)
            fw.report_result(out_f == out_g and rc_f == rc_g,
                             "sum: BSD multiple files matches GNU")

            rc_f, out_f, _ = fw.run_asm(["-s"] + all_paths)
            rc_g, out_g, _ = fw.run_gnu(["-s"] + all_paths)
            fw.report_result(out_f == out_g and rc_f == rc_g,
                             "sum: SysV multiple files matches GNU")

            # Stdin comparisons
            for data in [b"hello", b"", b"\x00" * 1000, bytes(range(256))]:
                rc_f, out_f, _ = fw.run_asm([], stdin_data=data)
                rc_g, out_g, _ = fw.run_gnu([], stdin_data=data)
                desc = f"stdin({len(data)}B)"
                fw.report_result(out_f == out_g and rc_f == rc_g,
                                 f"sum: BSD {desc} matches GNU")

                rc_f, out_f, _ = fw.run_asm(["-s"], stdin_data=data)
                rc_g, out_g, _ = fw.run_gnu(["-s"], stdin_data=data)
                fw.report_result(out_f == out_g and rc_f == rc_g,
                                 f"sum: SysV {desc} matches GNU")

            # Flag combinations
            rc_f, out_f, _ = fw.run_asm(["-r", files["hello.txt"]])
            rc_g, out_g, _ = fw.run_gnu(["-r", files["hello.txt"]])
            fw.report_result(out_f == out_g, "sum: -r explicit matches GNU")

            rc_f, out_f, _ = fw.run_asm(["-s", "-r", files["hello.txt"]])
            rc_g, out_g, _ = fw.run_gnu(["-s", "-r", files["hello.txt"]])
            fw.report_result(out_f == out_g, "sum: -s -r (last wins) matches GNU")

            rc_f, out_f, _ = fw.run_asm(["-r", "-s", files["hello.txt"]])
            rc_g, out_g, _ = fw.run_gnu(["-r", "-s", files["hello.txt"]])
            fw.report_result(out_f == out_g, "sum: -r -s (last wins) matches GNU")

            # Dash as stdin
            rc_f, out_f, _ = fw.run_asm(["-"], stdin_data=b"hello")
            rc_g, out_g, _ = fw.run_gnu(["-"], stdin_data=b"hello")
            fw.report_result(out_f == out_g, "sum: - (stdin) matches GNU")

        # Nonexistent file
        rc, out, err = fw.run_asm(["/nonexistent_file_xyz"])
        fw.report_result(rc == 1, "sum: nonexistent file -> exit 1")
    finally:
        import shutil
        shutil.rmtree(tmpdir)


if __name__ == '__main__':
    fw = SecurityTestFramework(config)
    fw.run_all(tool_specific_fn=tool_specific_tests)
