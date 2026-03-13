#!/usr/bin/env python3
"""security_tests.py -- Security & memory safety tests for frealpath.

Uses shared SecurityTestFramework + tool-specific realpath tests.
"""

import os
import sys
import tempfile

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', '..', 'tests'))
from security_framework import SecurityTestFramework

from pathlib import Path
from shutil import which

TMPDIR = None


def setup_fixtures():
    global TMPDIR
    TMPDIR = tempfile.mkdtemp(prefix="frealpath_test_")
    os.makedirs(f"{TMPDIR}/a/b", exist_ok=True)
    Path(f"{TMPDIR}/realfile").touch()
    Path(f"{TMPDIR}/a/b/deepfile").touch()
    os.symlink(f"{TMPDIR}/realfile", f"{TMPDIR}/symlink")
    os.symlink("realfile", f"{TMPDIR}/relsym")
    os.symlink("nonexistent", f"{TMPDIR}/brokensym")


def cleanup_fixtures():
    if TMPDIR:
        import shutil
        shutil.rmtree(TMPDIR, ignore_errors=True)


def tool_specific_tests(fw):
    """Category 13: realpath-specific tests."""
    fw.log("\n=== 13. Tool-Specific: realpath ===")
    gnu_path = which("realpath")

    # Basic resolution
    rc, out, _ = fw.run_asm([f"{TMPDIR}/realfile"])
    fw.report_result(rc == 0 and out.strip() == f"{TMPDIR}/realfile".encode(),
                     "realpath: resolves regular file")

    rc, out, _ = fw.run_asm([f"{TMPDIR}/symlink"])
    fw.report_result(rc == 0 and out.strip() == f"{TMPDIR}/realfile".encode(),
                     "realpath: resolves symlink")

    # Dotdot resolution
    rc, out, _ = fw.run_asm([f"{TMPDIR}/a/.."])
    fw.report_result(rc == 0 and out.strip() == TMPDIR.encode(),
                     "realpath: resolves dotdot")

    # Root
    rc, out, _ = fw.run_asm(["/"])
    fw.report_result(out.strip() == b"/", "realpath: root resolves to /")

    # -e mode (must exist)
    rc, _, _ = fw.run_asm(["-e", f"{TMPDIR}/nonexistent"])
    fw.report_result(rc == 1, "realpath: -e nonexistent exits 1")

    # -m mode (doesn't need to exist)
    rc, out, _ = fw.run_asm(["-m", f"{TMPDIR}/nosuch/deep/path"])
    fw.report_result(rc == 0 and len(out) > 0,
                     "realpath: -m nonexistent produces output")

    # -s mode (no symlinks)
    rc, out, _ = fw.run_asm(["-s", f"{TMPDIR}/a/.."])
    fw.report_result(rc == 0 and out.strip() == TMPDIR.encode(),
                     "realpath: -s resolves dotdot without symlinks")

    # Multiple files
    rc, out, _ = fw.run_asm([f"{TMPDIR}/realfile", f"{TMPDIR}/a"])
    lines = out.strip().split(b"\n")
    fw.report_result(len(lines) == 2, "realpath: multiple files produce multiple lines")

    # GNU compatibility
    if gnu_path:
        for path in [f"{TMPDIR}/realfile", f"{TMPDIR}/symlink",
                     f"{TMPDIR}/a/b/deepfile", "/"]:
            rc_f, out_f, _ = fw.run_asm([path])
            rc_g, out_g, _ = fw.run([gnu_path, path])
            fw.report_result(out_f == out_g,
                             f"realpath: matches GNU for {os.path.basename(path) or '/'}")


config = {
    'tool_name': 'realpath',
    'bin_name': 'frealpath',
    'gnu_path': '/usr/bin/realpath',
    'bss_size': 65536,
    'max_binary_size': 30000,
    'test_args': ['/etc/hosts'],
    'test_stdin': None,
    'timeout': 5,
}

if __name__ == '__main__':
    setup_fixtures()
    try:
        fw = SecurityTestFramework(config)
        fw.run_all(tool_specific_fn=tool_specific_tests)
    finally:
        cleanup_fixtures()
