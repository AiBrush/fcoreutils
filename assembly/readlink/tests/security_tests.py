#!/usr/bin/env python3
"""security_tests.py -- Security & memory safety tests for freadlink.

Uses shared SecurityTestFramework + tool-specific readlink tests.
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
    TMPDIR = tempfile.mkdtemp(prefix="freadlink_test_")
    os.makedirs(f"{TMPDIR}/a/b", exist_ok=True)
    Path(f"{TMPDIR}/realfile").touch()
    Path(f"{TMPDIR}/a/b/deepfile").touch()
    os.symlink(f"{TMPDIR}/realfile", f"{TMPDIR}/symlink1")
    os.symlink("realfile", f"{TMPDIR}/relsymlink")
    os.symlink("../realfile", f"{TMPDIR}/a/upsymlink")
    os.symlink(f"{TMPDIR}/symlink1", f"{TMPDIR}/chainsymlink")
    os.symlink("nonexistent", f"{TMPDIR}/brokensymlink")


def cleanup_fixtures():
    if TMPDIR:
        import shutil
        shutil.rmtree(TMPDIR, ignore_errors=True)


def tool_specific_tests(fw):
    """Category 13: readlink-specific tests."""
    fw.log("\n=== 13. Tool-Specific: readlink ===")
    gnu_path = which("readlink")
    symlink = f"{TMPDIR}/symlink1"
    target = f"{TMPDIR}/realfile"

    # Simple readlink
    rc, out, _ = fw.run_asm([symlink])
    fw.report_result(out == target.encode() + b"\n", "readlink: simple symlink target")

    rc, out, _ = fw.run_asm([f"{TMPDIR}/relsymlink"])
    fw.report_result(out == b"realfile\n", "readlink: relative symlink target")

    rc, out, _ = fw.run_asm([f"{TMPDIR}/a/upsymlink"])
    fw.report_result(out == b"../realfile\n", "readlink: up-dir symlink target")

    # Non-symlink -> exit 1
    rc, out, _ = fw.run_asm([target])
    fw.report_result(rc == 1 and out == b"", "readlink: non-symlink exit 1")

    # Nonexistent -> exit 1
    rc, out, _ = fw.run_asm([f"{TMPDIR}/nosuchfile"])
    fw.report_result(rc == 1 and out == b"", "readlink: nonexistent exit 1")

    # Multiple files
    rc, out, _ = fw.run_asm([symlink, f"{TMPDIR}/relsymlink"])
    fw.report_result(rc == 0 and out == target.encode() + b"\nrealfile\n",
                     "readlink: multiple symlinks")

    # Mixed success/failure -> exit 1
    rc, out, _ = fw.run_asm([symlink, target])
    fw.report_result(rc == 1, "readlink: mixed success/failure exit 1")

    # -n flag
    rc, out, _ = fw.run_asm(["-n", symlink])
    fw.report_result(out == target.encode() and b"\n" not in out,
                     "readlink: -n no trailing newline")

    # -z flag
    rc, out, _ = fw.run_asm(["-z", symlink])
    fw.report_result(out == target.encode() + b"\x00",
                     "readlink: -z NUL terminator")

    # -f canonicalize
    rc, out, _ = fw.run_asm(["-f", symlink])
    fw.report_result(out == target.encode() + b"\n",
                     "readlink: -f canonical path")

    rc, out, _ = fw.run_asm(["-f", f"{TMPDIR}/relsymlink"])
    fw.report_result(out == target.encode() + b"\n",
                     "readlink: -f resolves relative symlink")

    rc, out, _ = fw.run_asm(["-f", f"{TMPDIR}/chainsymlink"])
    fw.report_result(out == target.encode() + b"\n",
                     "readlink: -f follows chain of symlinks")

    rc, out, _ = fw.run_asm(["-f", target])
    fw.report_result(out == target.encode() + b"\n",
                     "readlink: -f on regular file returns canonical path")

    rc, out, _ = fw.run_asm(["-f", f"{TMPDIR}/a/.."])
    fw.report_result(out == TMPDIR.encode() + b"\n",
                     "readlink: -f resolves ..")

    rc, out, _ = fw.run_asm(["-f", "/"])
    fw.report_result(out == b"/\n", "readlink: -f root")

    # -f with nonexistent last component (allowed)
    rc, out, _ = fw.run_asm(["-f", f"{TMPDIR}/nosuchfile"])
    fw.report_result(rc == 0 and out == f"{TMPDIR}/nosuchfile\n".encode(),
                     "readlink: -f nonexistent last component ok")

    # -f with nonexistent intermediate -> fail
    rc, out, _ = fw.run_asm(["-f", f"{TMPDIR}/nosuch/file"])
    fw.report_result(rc == 1, "readlink: -f nonexistent intermediate fails")

    # -e requires all components to exist
    rc, out, _ = fw.run_asm(["-e", target])
    fw.report_result(rc == 0 and out == target.encode() + b"\n",
                     "readlink: -e existing file")

    rc, out, _ = fw.run_asm(["-e", f"{TMPDIR}/nosuchfile"])
    fw.report_result(rc == 1, "readlink: -e nonexistent fails")

    # -m doesn't require any component
    rc, out, _ = fw.run_asm(["-m", f"{TMPDIR}/nosuch/deep/path"])
    fw.report_result(rc == 0 and out == f"{TMPDIR}/nosuch/deep/path\n".encode(),
                     "readlink: -m nonexistent deep path")

    # Broken symlink handling
    rc, out, _ = fw.run_asm([f"{TMPDIR}/brokensymlink"])
    fw.report_result(out == b"nonexistent\n", "readlink: broken symlink shows target")

    rc, out, _ = fw.run_asm(["-e", f"{TMPDIR}/brokensymlink"])
    fw.report_result(rc == 1, "readlink: -e broken symlink fails")

    # Combined flags
    rc, out, _ = fw.run_asm(["-nf", symlink])
    fw.report_result(out == target.encode() and b"\n" not in out,
                     "readlink: -nf combined")

    rc, out, _ = fw.run_asm(["-zf", symlink])
    fw.report_result(out == target.encode() + b"\x00",
                     "readlink: -zf combined")

    # GNU compatibility
    if gnu_path:
        for sym in [symlink, f"{TMPDIR}/relsymlink", f"{TMPDIR}/brokensymlink"]:
            rc_f, out_f, _ = fw.run_asm([sym])
            rc_g, out_g, _ = fw.run([gnu_path, sym])
            fw.report_result(out_f == out_g and rc_f == rc_g,
                             f"readlink: matches GNU for '{os.path.basename(sym)}'")

        for path in [symlink, target, f"{TMPDIR}/a", "/"]:
            rc_f, out_f, _ = fw.run_asm(["-f", path])
            rc_g, out_g, _ = fw.run([gnu_path, "-f", path])
            fw.report_result(out_f == out_g and rc_f == rc_g,
                             f"readlink: -f matches GNU for '{os.path.basename(path) or path}'")


# Create temp symlink for test_args (readlink needs a real symlink)
_td = tempfile.mkdtemp(prefix="freadlink_cfg_")
_real = os.path.join(_td, 'real')
Path(_real).touch()
_sym = os.path.join(_td, 'link')
os.symlink(_real, _sym)
import atexit, shutil as _shutil
atexit.register(_shutil.rmtree, _td, True)

config = {
    'tool_name': 'readlink',
    'bin_name': 'freadlink',
    'gnu_path': '/usr/bin/readlink',
    'bss_size': 65536,
    'max_binary_size': 30000,
    'test_args': [_sym],
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
