#!/usr/bin/env python3
"""Security tests for fmktemp — uses shared framework."""
import os
import sys
import tempfile

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', '..', 'tests'))
from security_framework import SecurityTestFramework

config = {
    'tool_name': 'mktemp',
    'bin_name': 'fmktemp',
    'gnu_path': '/usr/bin/mktemp',
    'bss_size': 4096,
    'max_binary_size': 100000,
    'test_args': ['-u'],
    'test_stdin': None,
    'timeout': 5,
}


def _cleanup(rc, out):
    """Clean up any temp file/dir created by mktemp from its stdout."""
    if rc == 0 and out:
        path = out.decode(errors="replace").strip()
        if path and os.path.exists(path):
            try:
                if os.path.isdir(path):
                    os.rmdir(path)
                else:
                    os.unlink(path)
            except OSError:
                pass


def tool_specific_tests(fw):
    """13. Tool-specific: mktemp — temp file/dir creation behavior."""
    fw.log("\n=== Tool-Specific: mktemp ===")

    # Default temp file creation
    rc, out, err = fw.run_asm([])
    path = out.decode(errors="replace").strip()
    fw.report_result(rc == 0, "mktemp: default -> exit 0")
    fw.report_result(os.path.isfile(path), "mktemp: default creates a file")
    if os.path.isfile(path):
        perms = oct(os.stat(path).st_mode & 0o777)
        fw.report_result(perms == "0o600", f"mktemp: file permissions 0600 ({perms})")
        os.unlink(path)
    else:
        fw.report_result(False, "mktemp: file permissions (file not created)")

    # Output path starts with /tmp/
    rc, out, err = fw.run_asm([])
    path = out.decode(errors="replace").strip()
    fw.report_result(path.startswith("/tmp/"), f"mktemp: output starts with /tmp/")
    _cleanup(rc, out)

    # -d creates a directory
    rc, out, err = fw.run_asm(["-d"])
    path = out.decode(errors="replace").strip()
    fw.report_result(rc == 0, "mktemp: -d -> exit 0")
    fw.report_result(os.path.isdir(path), "mktemp: -d creates a directory")
    if os.path.isdir(path):
        perms = oct(os.stat(path).st_mode & 0o777)
        fw.report_result(perms == "0o700", f"mktemp: dir permissions 0700 ({perms})")
        os.rmdir(path)
    else:
        fw.report_result(False, "mktemp: dir permissions (dir not created)")

    # -u dry-run (no file created)
    rc, out, err = fw.run_asm(["-u"])
    path = out.decode(errors="replace").strip()
    fw.report_result(rc == 0, "mktemp: -u -> exit 0")
    fw.report_result(not os.path.exists(path), "mktemp: -u does not create file")

    # -p DIR (creates in specified directory)
    with tempfile.TemporaryDirectory() as tmpdir:
        rc, out, err = fw.run_asm(["-p", tmpdir])
        path = out.decode(errors="replace").strip()
        fw.report_result(rc == 0, "mktemp: -p DIR -> exit 0")
        fw.report_result(path.startswith(tmpdir + "/"), "mktemp: -p file in correct dir")
        _cleanup(rc, out)

    # --tmpdir=DIR
    with tempfile.TemporaryDirectory() as tmpdir:
        rc, out, err = fw.run_asm([f"--tmpdir={tmpdir}"])
        path = out.decode(errors="replace").strip()
        fw.report_result(rc == 0, "mktemp: --tmpdir=DIR -> exit 0")
        fw.report_result(path.startswith(tmpdir + "/"), "mktemp: --tmpdir file in correct dir")
        _cleanup(rc, out)

    # Custom template
    with tempfile.TemporaryDirectory() as tmpdir:
        template = os.path.join(tmpdir, "myfileXXXXXX")
        rc, out, err = fw.run_asm([template])
        path = out.decode(errors="replace").strip()
        fw.report_result(rc == 0, "mktemp: custom template -> exit 0")
        fw.report_result(
            path.startswith(os.path.join(tmpdir, "myfile")),
            "mktemp: custom template prefix preserved")
        _cleanup(rc, out)

    # --suffix=.txt
    rc, out, err = fw.run_asm(["--suffix=.txt"])
    path = out.decode(errors="replace").strip()
    fw.report_result(rc == 0, "mktemp: --suffix=.txt -> exit 0")
    fw.report_result(path.endswith(".txt"), "mktemp: --suffix produces .txt suffix")
    _cleanup(rc, out)

    # -q suppresses error messages
    rc, out, err = fw.run_asm(["-q", "/nonexistent_dir/testXXXXXX"])
    fw.report_result(rc == 1, "mktemp: -q error -> exit 1")
    fw.report_result(err == b"", "mktemp: -q suppresses stderr")

    # Error on nonexistent directory (without -q)
    rc, out, err = fw.run_asm(["/nonexistent_dir/testXXXXXX"])
    fw.report_result(rc == 1, "mktemp: nonexistent dir -> exit 1")
    fw.report_result(len(err) > 0, "mktemp: nonexistent dir -> stderr message")

    # TMPDIR env var
    with tempfile.TemporaryDirectory() as tmpdir:
        env = os.environ.copy()
        env["TMPDIR"] = tmpdir
        rc, out, err = fw.run_asm([], env=env)
        path = out.decode(errors="replace").strip()
        fw.report_result(rc == 0, "mktemp: TMPDIR env -> exit 0")
        fw.report_result(path.startswith(tmpdir + "/"), "mktemp: TMPDIR env respected")
        _cleanup(rc, out)

    # Combined -du (dry-run directory)
    rc, out, err = fw.run_asm(["-du"])
    path = out.decode(errors="replace").strip()
    fw.report_result(rc == 0, "mktemp: -du -> exit 0")
    fw.report_result(not os.path.exists(path), "mktemp: -du does not create dir")

    # Uniqueness under rapid creation (100 files)
    with tempfile.TemporaryDirectory() as tmpdir:
        paths = []
        all_ok = True
        for i in range(100):
            rc, out, err = fw.run_asm(["-p", tmpdir])
            if rc == 0:
                path = out.decode(errors="replace").strip()
                paths.append(path)
            else:
                all_ok = False
                break
        unique_count = len(set(paths))
        fw.report_result(
            unique_count == 100 and all_ok,
            f"mktemp: 100 files all unique ({unique_count} unique)")
        for p in paths:
            try:
                os.unlink(p)
            except OSError:
                pass


if __name__ == '__main__':
    fw = SecurityTestFramework(config)
    fw.run_all(tool_specific_fn=tool_specific_tests)
