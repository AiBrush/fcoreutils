#!/usr/bin/env python3
"""security_tests.py — Security & memory safety tests for fcp.

Uses shared SecurityTestFramework with tool-specific cp tests.
"""

import atexit
import os
import sys
import tempfile

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', '..', 'tests'))
from security_framework import SecurityTestFramework

# Create temp files for test_args (cp needs src + dst)
_src = tempfile.NamedTemporaryFile(delete=False)
_src.write(b"test\n")
_src.close()
_dst = tempfile.NamedTemporaryFile(delete=False)
_dst.close()
atexit.register(os.unlink, _src.name)
atexit.register(os.unlink, _dst.name)

config = {
    'tool_name': 'cp',
    'bin_name': 'fcp',
    'gnu_path': '/usr/bin/cp',
    'bss_size': 65536,
    'max_binary_size': 30000,
    'test_args': [_src.name, _dst.name],
    'test_stdin': None,
    'timeout': 5,
}


def tool_specific_tests(fw):
    """Category 13: cp-specific tests."""
    fw.log("\n=== 13. Tool-Specific: cp ===")

    with tempfile.TemporaryDirectory() as tmpdir:
        # Basic copy
        src = os.path.join(tmpdir, "src")
        dst = os.path.join(tmpdir, "dst")
        with open(src, "w") as f:
            f.write("hello world")
        rc, out, err = fw.run_asm([src, dst])
        fw.report_result(rc == 0, "cp: basic copy -> exit 0")
        fw.report_result(os.path.exists(src), "cp: source preserved")
        fw.report_result(os.path.exists(dst), "cp: dest created")
        if os.path.exists(dst):
            with open(dst) as f:
                fw.report_result(f.read() == "hello world", "cp: content matches")
        else:
            fw.report_result(False, "cp: content matches")

        # Recursive copy
        d = os.path.join(tmpdir, "dir")
        d2 = os.path.join(tmpdir, "dir2")
        os.makedirs(os.path.join(d, "sub"))
        with open(os.path.join(d, "f1"), "w") as f:
            f.write("a")
        with open(os.path.join(d, "sub", "f2"), "w") as f:
            f.write("b")
        rc, out, err = fw.run_asm(["-r", d, d2])
        fw.report_result(rc == 0, "cp: -r recursive -> exit 0")
        fw.report_result(os.path.isdir(d2), "cp: recursive dir created")
        if os.path.exists(os.path.join(d2, "f1")):
            with open(os.path.join(d2, "f1")) as f:
                fw.report_result(f.read() == "a", "cp: recursive file content")
        else:
            fw.report_result(False, "cp: recursive file content")

        # No-clobber
        f1 = os.path.join(tmpdir, "nc1")
        f2 = os.path.join(tmpdir, "nc2")
        with open(f1, "w") as fh:
            fh.write("original")
        with open(f2, "w") as fh:
            fh.write("new")
        _ = fw.run_asm(["-n", f2, f1])
        with open(f1) as fh:
            fw.report_result(fh.read() == "original", "cp: -n preserved dest")

        # Hard link
        hl = os.path.join(tmpdir, "hl")
        rc, out, err = fw.run_asm(["-l", src, hl])
        fw.report_result(rc == 0, "cp: -l hard link -> exit 0")
        if os.path.exists(hl):
            fw.report_result(os.stat(src).st_ino == os.stat(hl).st_ino, "cp: -l same inode")
        else:
            fw.report_result(False, "cp: -l same inode")

        # Dir without -r
        d3 = os.path.join(tmpdir, "dir3")
        os.makedirs(d3)
        rc, out, err = fw.run_asm([d3, os.path.join(tmpdir, "d3copy")])
        fw.report_result(rc == 1, "cp: dir without -r -> exit 1")
        err_text = err.decode(errors="replace")
        fw.report_result("omitting" in err_text, "cp: omitting directory message")

        # Nonexistent source
        rc, out, err = fw.run_asm([os.path.join(tmpdir, "nope"), os.path.join(tmpdir, "x")])
        fw.report_result(rc == 1, "cp: nonexistent -> exit 1")

    # Large file
    with tempfile.TemporaryDirectory() as tmpdir:
        src = os.path.join(tmpdir, "large")
        dst = os.path.join(tmpdir, "large_dst")
        with open(src, "wb") as f:
            f.write(os.urandom(100000))
        rc, out, err = fw.run_asm([src, dst])
        fw.report_result(rc == 0, "cp: 100KB file -> exit 0")
        if os.path.exists(dst):
            with open(src, "rb") as f1, open(dst, "rb") as f2:
                fw.report_result(f1.read() == f2.read(), "cp: 100KB content matches")
        else:
            fw.report_result(False, "cp: 100KB content matches")

    # --help
    rc, out, err = fw.run_asm(["--help"])
    fw.report_result(rc == 0, "cp: --help -> exit 0")
    fw.report_result(b"Usage:" in out, "cp: --help contains 'Usage:'")

    # --version
    rc, out, err = fw.run_asm(["--version"])
    fw.report_result(rc == 0, "cp: --version -> exit 0")
    fw.report_result(b"cp" in out, "cp: --version contains 'cp'")

    # Missing operand
    rc, out, err = fw.run_asm([])
    fw.report_result(rc == 1, "cp: no args -> exit 1")
    fw.report_result(b"missing" in err, "cp: missing operand message")


if __name__ == '__main__':
    fw = SecurityTestFramework(config)
    fw.run_all(tool_specific_fn=tool_specific_tests)
