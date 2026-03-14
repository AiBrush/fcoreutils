#!/usr/bin/env python3
"""Security tests for fmkdir — uses shared framework."""
import sys, os, tempfile
from shutil import which
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', '..', 'tests'))
from security_framework import SecurityTestFramework

config = {
    'tool_name': 'mkdir',
    'bin_name': 'fmkdir',
    'gnu_path': '/usr/bin/mkdir',
    'bss_size': 4096,
    'max_binary_size': 30000,
    # Use nonexistent parent so mkdir fails idempotently (exit 1 every time).
    # This avoids issues with test_args creating filesystem objects that persist
    # across repeated runs by the framework (determinism checks, concurrency).
    'test_args': ['/nonexistent/__fmkdir_test__/child'],
    'test_stdin': None,
}

def tool_specific_tests(fw):
    """13. Tool-specific: mkdir — directory creation behavior."""
    fw.log("\n=== Tool-Specific: mkdir ===")

    # Core mkdir behavior
    with tempfile.TemporaryDirectory() as tmpdir:
        testdir = os.path.join(tmpdir, "basic_test")
        rc, out, err = fw.run_asm([testdir])
        fw.report_result(rc == 0, "mkdir: create directory -> exit 0")
        fw.report_result(os.path.isdir(testdir), "mkdir: directory actually created")

    # Already exists
    with tempfile.TemporaryDirectory() as tmpdir:
        testdir = os.path.join(tmpdir, "exists_test")
        os.mkdir(testdir)
        rc, out, err = fw.run_asm([testdir])
        fw.report_result(rc == 1, "mkdir: already exists -> exit 1")
        fw.report_result(b"File exists" in err, "mkdir: EEXIST error message")

    # Nonexistent parent
    with tempfile.TemporaryDirectory() as tmpdir:
        testdir = os.path.join(tmpdir, "noparent", "child")
        rc, out, err = fw.run_asm([testdir])
        fw.report_result(rc == 1, "mkdir: no parent -> exit 1")
        fw.report_result(b"No such file or directory" in err, "mkdir: ENOENT error message")

    # Multiple directories
    with tempfile.TemporaryDirectory() as tmpdir:
        dirs = [os.path.join(tmpdir, f"multi_{i}") for i in range(3)]
        rc, out, err = fw.run_asm(dirs)
        fw.report_result(rc == 0, "mkdir: multiple dirs -> exit 0")
        fw.report_result(all(os.path.isdir(d) for d in dirs), "mkdir: all dirs created")

    # -p creates parent chain
    with tempfile.TemporaryDirectory() as tmpdir:
        testdir = os.path.join(tmpdir, "p_test", "a", "b", "c")
        rc, out, err = fw.run_asm(["-p", testdir])
        fw.report_result(rc == 0, "mkdir: -p parent chain -> exit 0")
        fw.report_result(os.path.isdir(testdir), "mkdir: -p created all parents")

    # -p no error if exists
    with tempfile.TemporaryDirectory() as tmpdir:
        testdir = os.path.join(tmpdir, "p_exists")
        os.mkdir(testdir)
        rc, out, err = fw.run_asm(["-p", testdir])
        fw.report_result(rc == 0, "mkdir: -p existing dir -> exit 0")

    # --parents long form
    with tempfile.TemporaryDirectory() as tmpdir:
        testdir = os.path.join(tmpdir, "parents_test", "x", "y")
        rc, out, err = fw.run_asm(["--parents", testdir])
        fw.report_result(rc == 0, "mkdir: --parents long form -> exit 0")
        fw.report_result(os.path.isdir(testdir), "mkdir: --parents created dirs")

    # -v verbose
    with tempfile.TemporaryDirectory() as tmpdir:
        testdir = os.path.join(tmpdir, "verbose_test")
        rc, out, err = fw.run_asm(["-v", testdir])
        fw.report_result(rc == 0, "mkdir: -v -> exit 0")
        fw.report_result(b"created directory" in err, "mkdir: -v produces verbose output")
        expected_msg = f"mkdir: created directory '{testdir}'".encode()
        fw.report_result(expected_msg in err, "mkdir: -v format matches GNU")

    # -m mode
    with tempfile.TemporaryDirectory() as tmpdir:
        testdir = os.path.join(tmpdir, "mode_test")
        rc, out, err = fw.run_asm(["-m", "755", testdir])
        fw.report_result(rc == 0, "mkdir: -m 755 -> exit 0")
        if os.path.isdir(testdir):
            perms = oct(os.stat(testdir).st_mode & 0o777)
            fw.report_result(perms == "0o755", f"mkdir: -m 755 permissions correct ({perms})")
        else:
            fw.report_result(False, "mkdir: -m 755 dir not created")

    # Error message format
    rc, out, err = fw.run_asm(["/tmp/nonexistent_format_specific/child"])
    fw.report_result(b"mkdir: cannot create directory '" in err, "mkdir: error format correct")

    # mkdir syscall (strace)
    if which("strace"):
        with tempfile.TemporaryDirectory() as tmpdir:
            testdir = os.path.join(tmpdir, "strace_mkdir")
            cmd = ["strace", "-e", "trace=mkdir", fw.bin_path, testdir]
            rc, out, err = fw.run(cmd)
            err_text = err.decode(errors="replace")
            fw.report_result("mkdir(" in err_text, "mkdir: uses mkdir() syscall")

if __name__ == '__main__':
    fw = SecurityTestFramework(config)
    fw.run_all(tool_specific_fn=tool_specific_tests)
