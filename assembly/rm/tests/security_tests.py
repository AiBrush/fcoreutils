#!/usr/bin/env python3
"""security_tests.py -- Security & memory safety tests for frm.

Uses shared SecurityTestFramework + tool-specific rm tests.
"""

import os
import sys
import tempfile

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', '..', 'tests'))
from security_framework import SecurityTestFramework

from shutil import which


def tool_specific_tests(fw):
    """Category 13: rm-specific tests."""
    fw.log("\n=== 13. Tool-Specific: rm ===")

    with tempfile.TemporaryDirectory() as tmpdir:
        # Remove file
        f = os.path.join(tmpdir, "f")
        with open(f, "w") as fh:
            fh.write("hello")
        rc, out, err = fw.run_asm([f])
        fw.report_result(rc == 0, "rm: remove file -> exit 0")
        fw.report_result(not os.path.exists(f), "rm: file actually gone")

        # Remove directory with -r
        d = os.path.join(tmpdir, "dir")
        os.makedirs(os.path.join(d, "sub"))
        with open(os.path.join(d, "f1"), "w") as fh:
            fh.write("a")
        with open(os.path.join(d, "sub", "f2"), "w") as fh:
            fh.write("b")
        rc, out, err = fw.run_asm(["-r", d])
        fw.report_result(rc == 0, "rm: -r recursive -> exit 0")
        fw.report_result(not os.path.exists(d), "rm: directory recursively removed")

        # -f nonexistent
        rc, out, err = fw.run_asm(["-f", os.path.join(tmpdir, "nope")])
        fw.report_result(rc == 0, "rm: -f nonexistent -> exit 0")
        fw.report_result(err == b"", "rm: -f nonexistent -> no stderr")

        # Remove dir without -r
        d2 = os.path.join(tmpdir, "dir2")
        os.makedirs(d2)
        rc, out, err = fw.run_asm([d2])
        fw.report_result(rc == 1, "rm: dir without -r -> exit 1")
        err_text = err.decode(errors="replace")
        fw.report_result("Is a directory" in err_text,
                         "rm: dir without -r -> 'Is a directory'")

        # -d for empty dir
        d3 = os.path.join(tmpdir, "dir3")
        os.makedirs(d3)
        rc, out, err = fw.run_asm(["-d", d3])
        fw.report_result(rc == 0, "rm: -d empty dir -> exit 0")
        fw.report_result(not os.path.exists(d3), "rm: -d empty dir removed")

    # --help
    rc, out, err = fw.run_asm(["--help"])
    fw.report_result(rc == 0, "rm: --help -> exit 0")
    fw.report_result(b"Usage:" in out, "rm: --help contains 'Usage:'")

    # --version
    rc, out, err = fw.run_asm(["--version"])
    fw.report_result(rc == 0, "rm: --version -> exit 0")
    fw.report_result(b"rm" in out, "rm: --version contains 'rm'")

    # Missing operand
    rc, out, err = fw.run_asm([])
    err_text = err.decode(errors="replace")
    fw.report_result(rc == 1, "rm: no args -> exit 1")
    fw.report_result("missing operand" in err_text, "rm: missing operand message")

    # Error on nonexistent without -f
    rc, out, err = fw.run_asm(["/nonexistent_xyz"])
    fw.report_result(rc == 1, "rm: nonexistent file -> exit 1")
    fw.report_result(b"cannot remove" in err, "rm: error message contains 'cannot remove'")

    # GNU exit code compatibility
    gnu_path = which("rm")
    if gnu_path:
        rc_f, _, _ = fw.run_asm([])
        rc_g, _, _ = fw.run([gnu_path])
        fw.report_result(rc_f == rc_g, "rm: exit code matches GNU for no args")

        rc_f, _, _ = fw.run_asm(["--help"])
        rc_g, _, _ = fw.run([gnu_path, "--help"])
        fw.report_result(rc_f == rc_g, "rm: exit code matches GNU for --help")

        rc_f, _, _ = fw.run_asm(["-f"])
        rc_g, _, _ = fw.run([gnu_path, "-f"])
        fw.report_result(rc_f == rc_g, "rm: exit code matches GNU for -f (no args)")


config = {
    'tool_name': 'rm',
    'bin_name': 'frm',
    'gnu_path': '/usr/bin/rm',
    'bss_size': 65536,
    'max_binary_size': 30000,
    'test_args': ['-f', '/nonexistent'],
    'test_stdin': None,
    'timeout': 5,
}

if __name__ == '__main__':
    fw = SecurityTestFramework(config)
    fw.run_all(tool_specific_fn=tool_specific_tests)
