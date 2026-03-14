#!/usr/bin/env python3
"""security_tests.py -- Security & memory safety tests for ftruncate (assembly truncate).

Uses shared SecurityTestFramework. truncate shrinks or extends file sizes.
"""

import os
import sys
import tempfile

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', '..', 'tests'))
from security_framework import SecurityTestFramework

config = {
    'tool_name': 'truncate',
    'bin_name': 'ftruncate_release',
    'gnu_path': '/usr/bin/truncate',
    'bss_size': 65536,
    'max_binary_size': 30000,
    'test_args': ['-s', '0', '/tmp/_ftruncate_test_file'],
    'test_stdin': None,
    'timeout': 5,
}

def tool_specific_tests(fw):
    """13. truncate-specific tests."""
    fw.log("\n=== 13. Tool-Specific: truncate ===")

    tmpdir = tempfile.mkdtemp()

    try:
        # Set exact size
        f1 = os.path.join(tmpdir, "exact100")
        rc, _, _ = fw.run_asm(["-s", "100", f1])
        fw.report_result(rc == 0 and os.path.getsize(f1) == 100,
                         "truncate: -s 100 sets file to 100 bytes")

        # Set to zero
        f2 = os.path.join(tmpdir, "zero")
        with open(f2, "wb") as f:
            f.write(b"x" * 50)
        rc, _, _ = fw.run_asm(["-s", "0", f2])
        fw.report_result(rc == 0 and os.path.getsize(f2) == 0,
                         "truncate: -s 0 empties file")

        # Grow with +
        f3 = os.path.join(tmpdir, "grow")
        with open(f3, "wb") as f:
            f.write(b"x" * 100)
        rc, _, _ = fw.run_asm(["-s", "+50", f3])
        fw.report_result(rc == 0 and os.path.getsize(f3) == 150,
                         "truncate: -s +50 grows by 50")

        # Shrink with -
        f4 = os.path.join(tmpdir, "shrink")
        with open(f4, "wb") as f:
            f.write(b"x" * 200)
        rc, _, _ = fw.run_asm(["-s", "-50", f4])
        fw.report_result(rc == 0 and os.path.getsize(f4) == 150,
                         "truncate: -s -50 shrinks by 50")

        # Shrink past zero clamps to 0
        f5 = os.path.join(tmpdir, "clamp")
        with open(f5, "wb") as f:
            f.write(b"x" * 10)
        rc, _, _ = fw.run_asm(["-s", "-100", f5])
        fw.report_result(rc == 0 and os.path.getsize(f5) == 0,
                         "truncate: -s -100 on 10-byte file clamps to 0")

        # K suffix
        f6 = os.path.join(tmpdir, "ksuffix")
        rc, _, _ = fw.run_asm(["-s", "2K", f6])
        fw.report_result(rc == 0 and os.path.getsize(f6) == 2048,
                         "truncate: -s 2K = 2048 bytes")

        # M suffix
        f7 = os.path.join(tmpdir, "msuffix")
        rc, _, _ = fw.run_asm(["-s", "1M", f7])
        fw.report_result(rc == 0 and os.path.getsize(f7) == 1048576,
                         "truncate: -s 1M = 1048576 bytes")

        # --no-create / -c
        nc = os.path.join(tmpdir, "no_create_test")
        rc, _, _ = fw.run_asm(["-c", "-s", "100", nc])
        fw.report_result(rc == 0 and not os.path.exists(nc),
                         "truncate: -c doesn't create nonexistent file")

        # File creation without -c
        newf = os.path.join(tmpdir, "new_file")
        rc, _, _ = fw.run_asm(["-s", "50", newf])
        fw.report_result(rc == 0 and os.path.exists(newf) and os.path.getsize(newf) == 50,
                         "truncate: creates file if not exists")

        # Reference file
        ref = os.path.join(tmpdir, "reference")
        with open(ref, "wb") as f:
            f.write(b"x" * 300)
        tgt = os.path.join(tmpdir, "target_ref")
        rc, _, _ = fw.run_asm(["-r", ref, tgt])
        fw.report_result(rc == 0 and os.path.getsize(tgt) == 300,
                         "truncate: -r reference file sets same size")

        # Multiple files
        mf1 = os.path.join(tmpdir, "multi1")
        mf2 = os.path.join(tmpdir, "multi2")
        rc, _, _ = fw.run_asm(["-s", "200", mf1, mf2])
        fw.report_result(rc == 0 and os.path.getsize(mf1) == 200 and os.path.getsize(mf2) == 200,
                         "truncate: multiple files all set to 200")

        # --size= long form
        sf = os.path.join(tmpdir, "size_long")
        rc, _, _ = fw.run_asm(["--size=150", sf])
        fw.report_result(rc == 0 and os.path.getsize(sf) == 150,
                         "truncate: --size=150 works")

        # Error: nonexistent path
        rc, _, err = fw.run_asm(["-s", "100", "/nonexistent/path/file"])
        fw.report_result(rc != 0, "truncate: error on nonexistent path")

        # Error: missing -s and -r
        rc, _, err = fw.run_asm([os.path.join(tmpdir, "x")])
        fw.report_result(rc != 0, "truncate: error when no -s or -r")

    finally:
        import shutil
        shutil.rmtree(tmpdir, ignore_errors=True)


if __name__ == '__main__':
    # Create the temp file that test_args references
    open('/tmp/_ftruncate_test_file', 'a').close()
    fw = SecurityTestFramework(config)
    fw.run_all(tool_specific_fn=tool_specific_tests)
