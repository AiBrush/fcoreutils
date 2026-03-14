#!/usr/bin/env python3
"""Security tests for fmv — uses shared framework."""
import os
import sys
import tempfile

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', '..', 'tests'))
from security_framework import SecurityTestFramework

config = {
    'tool_name': 'mv',
    'bin_name': 'fmv',
    'gnu_path': '/usr/bin/mv',
    'bss_size': 4096,
    'max_binary_size': 30000,
    'test_args': ['--help'],
    'test_stdin': None,
    'timeout': 5,
}


def tool_specific_tests(fw):
    """13. Tool-specific: mv — file move operations."""
    fw.log("\n=== Tool-Specific: mv ===")

    with tempfile.TemporaryDirectory() as tmpdir:
        # Basic move
        src = os.path.join(tmpdir, "src")
        dst = os.path.join(tmpdir, "dst")
        with open(src, "w") as f:
            f.write("hello world")
        rc, out, err = fw.run_asm([src, dst])
        fw.report_result(rc == 0, "mv: basic move -> exit 0")
        fw.report_result(not os.path.exists(src), "mv: source removed")
        fw.report_result(os.path.exists(dst), "mv: dest created")
        if os.path.exists(dst):
            with open(dst) as f:
                fw.report_result(f.read() == "hello world", "mv: content preserved")
        else:
            fw.report_result(False, "mv: content preserved")

        # Move into directory
        src2 = os.path.join(tmpdir, "src2")
        d = os.path.join(tmpdir, "dir")
        os.makedirs(d)
        with open(src2, "w") as f:
            f.write("test")
        rc, out, err = fw.run_asm([src2, d])
        fw.report_result(rc == 0, "mv: move into dir -> exit 0")
        fw.report_result(os.path.exists(os.path.join(d, "src2")), "mv: file in dir")

        # No-clobber
        f1 = os.path.join(tmpdir, "nc1")
        f2 = os.path.join(tmpdir, "nc2")
        with open(f1, "w") as fh:
            fh.write("original")
        with open(f2, "w") as fh:
            fh.write("new")
        rc, out, err = fw.run_asm(["-n", f2, f1])
        fw.report_result(rc == 0, "mv: -n no-clobber -> exit 0")
        with open(f1) as fh:
            fw.report_result(fh.read() == "original", "mv: -n preserved dest")

        # Move nonexistent
        rc, out, err = fw.run_asm([os.path.join(tmpdir, "nope"), os.path.join(tmpdir, "dst2")])
        fw.report_result(rc == 1, "mv: nonexistent -> exit 1")

    # --help
    rc, out, err = fw.run_asm(["--help"])
    fw.report_result(rc == 0, "mv: --help -> exit 0")
    fw.report_result(b"Usage:" in out, "mv: --help contains 'Usage:'")

    # --version
    rc, out, err = fw.run_asm(["--version"])
    fw.report_result(rc == 0, "mv: --version -> exit 0")
    fw.report_result(b"mv" in out, "mv: --version contains 'mv'")

    # Missing operand
    rc, out, err = fw.run_asm([])
    fw.report_result(rc == 1, "mv: no args -> exit 1")
    fw.report_result(b"missing" in err, "mv: missing operand message")


if __name__ == '__main__':
    fw = SecurityTestFramework(config)
    fw.run_all(tool_specific_fn=tool_specific_tests)
