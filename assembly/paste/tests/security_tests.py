#!/usr/bin/env python3
"""security_tests.py -- Security & memory safety tests for fpaste (assembly paste).

Uses shared SecurityTestFramework.
"""

import os
import sys
import tempfile

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', '..', 'tests'))
from security_framework import SecurityTestFramework

config = {
    'tool_name': 'paste',
    'bin_name': 'fpaste',
    'gnu_path': '/usr/bin/paste',
    'bss_size': 262144,
    'max_binary_size': 30000,
    'test_args': ['-'],
    'test_stdin': b'a\nb\nc\n',
    'timeout': 5,
}


def tool_specific_tests(fw):
    """13. paste-specific tests: file merging, delimiters, serial mode."""
    fw.log("\n=== 13. Tool-Specific: paste ===")

    with tempfile.TemporaryDirectory() as tmpdir:
        fa = os.path.join(tmpdir, "a.txt")
        fb = os.path.join(tmpdir, "b.txt")
        fc = os.path.join(tmpdir, "c.txt")
        fempty = os.path.join(tmpdir, "empty.txt")

        with open(fa, "w") as f: f.write("1\n2\n3\n")
        with open(fb, "w") as f: f.write("a\nb\nc\n")
        with open(fc, "w") as f: f.write("x\ny\nz\n")
        with open(fempty, "w") as f: pass

        # Basic paste
        rc_a, out_a, _ = fw.run_asm([fa, fb])
        rc_g, out_g, _ = fw.run_gnu([fa, fb])
        fw.report_result(out_a == out_g, "paste: two files matches GNU")

        # Three files
        rc_a, out_a, _ = fw.run_asm([fa, fb, fc])
        rc_g, out_g, _ = fw.run_gnu([fa, fb, fc])
        fw.report_result(out_a == out_g, "paste: three files matches GNU")

        # Custom delimiter
        rc_a, out_a, _ = fw.run_asm(["-d", ":", fa, fb])
        rc_g, out_g, _ = fw.run_gnu(["-d", ":", fa, fb])
        fw.report_result(out_a == out_g, "paste: -d : matches GNU")

        # Multi-char delimiter
        rc_a, out_a, _ = fw.run_asm(["-d", ":,", fa, fb, fc])
        rc_g, out_g, _ = fw.run_gnu(["-d", ":,", fa, fb, fc])
        fw.report_result(out_a == out_g, "paste: -d :, matches GNU")

        # Empty delimiter
        rc_a, out_a, _ = fw.run_asm(["-d", "", fa, fb])
        rc_g, out_g, _ = fw.run_gnu(["-d", "", fa, fb])
        fw.report_result(out_a == out_g, "paste: empty delimiter matches GNU")

        # Serial mode
        rc_a, out_a, _ = fw.run_asm(["-s", fa])
        rc_g, out_g, _ = fw.run_gnu(["-s", fa])
        fw.report_result(out_a == out_g, "paste: -s matches GNU")

        # Serial multiple
        rc_a, out_a, _ = fw.run_asm(["-s", fa, fb])
        rc_g, out_g, _ = fw.run_gnu(["-s", fa, fb])
        fw.report_result(out_a == out_g, "paste: -s multiple matches GNU")

        # Serial empty
        rc_a, out_a, _ = fw.run_asm(["-s", fempty])
        rc_g, out_g, _ = fw.run_gnu(["-s", fempty])
        fw.report_result(out_a == out_g, "paste: -s empty matches GNU")

        # Empty file
        rc_a, out_a, _ = fw.run_asm([fempty])
        rc_g, out_g, _ = fw.run_gnu([fempty])
        fw.report_result(out_a == out_g, "paste: empty file matches GNU")

        # Unequal files
        fshort = os.path.join(tmpdir, "short.txt")
        with open(fshort, "w") as f: f.write("a\n")
        rc_a, out_a, _ = fw.run_asm([fa, fshort])
        rc_g, out_g, _ = fw.run_gnu([fa, fshort])
        fw.report_result(out_a == out_g, "paste: unequal files matches GNU")

        # Stdin
        rc_a, out_a, _ = fw.run_asm(["-"], stdin_data=b"hello\nworld\n")
        rc_g, out_g, _ = fw.run_gnu(["-"], stdin_data=b"hello\nworld\n")
        fw.report_result(out_a == out_g, "paste: stdin matches GNU")

        # Stdin paired
        rc_a, out_a, _ = fw.run_asm(["-", "-"], stdin_data=b"1\n2\n3\n4\n")
        rc_g, out_g, _ = fw.run_gnu(["-", "-"], stdin_data=b"1\n2\n3\n4\n")
        fw.report_result(out_a == out_g, "paste: stdin paired matches GNU")

        # Nonexistent file
        rc_a, _, _ = fw.run_asm(["/nonexistent_xyz_paste"])
        rc_g, _, _ = fw.run_gnu(["/nonexistent_xyz_paste"])
        fw.report_result(rc_a == rc_g, "paste: nonexistent file exit code matches GNU")

        # Large input
        flarge = os.path.join(tmpdir, "large.txt")
        with open(flarge, "w") as f:
            for i in range(10000):
                f.write(f"line{i:06d}\n")
        rc_a, out_a, _ = fw.run_asm([flarge, flarge], timeout=10)
        rc_g, out_g, _ = fw.run_gnu([flarge, flarge], timeout=10)
        fw.report_result(out_a == out_g, "paste: large input matches GNU")

        # --help/--version
        rc_a, out_a, _ = fw.run_asm(["--help"])
        fw.report_result(rc_a == 0 and len(out_a) > 0, "paste: --help works")

        rc_a, out_a, _ = fw.run_asm(["--version"])
        fw.report_result(rc_a == 0 and len(out_a) > 0, "paste: --version works")


if __name__ == '__main__':
    fw = SecurityTestFramework(config)
    fw.run_all(tool_specific_fn=tool_specific_tests)
