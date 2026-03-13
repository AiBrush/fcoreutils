#!/usr/bin/env python3
"""Security tests for frmdir — uses shared framework."""
import sys, os, tempfile
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', '..', 'tests'))
from security_framework import SecurityTestFramework

config = {
    'tool_name': 'rmdir',
    'bin_name': 'frmdir',
    'gnu_path': '/usr/bin/rmdir',
    'bss_size': 65536,
    'max_binary_size': 30000,
    'test_args': [],
    'test_stdin': None,
    'timeout': 5,
}

def tool_specific_tests(fw):
    """13. Tool-specific: rmdir directory removal behavior."""
    fw.log("\n=== Rmdir-Specific Tests ===")

    # Core rmdir behavior: remove empty directory
    with tempfile.TemporaryDirectory() as tmpdir:
        testdir = os.path.join(tmpdir, "basic_test")
        os.mkdir(testdir)
        rc, out, err = fw.run_asm([testdir])
        fw.report_result(rc == 0, "rmdir: remove empty directory -> exit 0")
        fw.report_result(not os.path.exists(testdir), "rmdir: directory actually removed")

    # Nonexistent directory
    rc, out, err = fw.run_asm(["/tmp/nonexistent_rmdir_specific_test"])
    fw.report_result(rc == 1, "rmdir: nonexistent directory -> exit 1")
    fw.report_result(b"No such file or directory" in err, "rmdir: ENOENT error message")

    # Non-empty directory
    with tempfile.TemporaryDirectory() as tmpdir:
        testdir = os.path.join(tmpdir, "notempty_test")
        os.makedirs(os.path.join(testdir, "child"))
        rc, out, err = fw.run_asm([testdir])
        fw.report_result(rc == 1, "rmdir: non-empty directory -> exit 1")
        fw.report_result(b"Directory not empty" in err, "rmdir: ENOTEMPTY error message")

    # Not a directory (file)
    with tempfile.TemporaryDirectory() as tmpdir:
        testfile = os.path.join(tmpdir, "afile")
        with open(testfile, "w") as f:
            f.write("x")
        rc, out, err = fw.run_asm([testfile])
        fw.report_result(rc == 1, "rmdir: file (not dir) -> exit 1")
        fw.report_result(b"Not a directory" in err, "rmdir: ENOTDIR error message")

    # Multiple directories
    with tempfile.TemporaryDirectory() as tmpdir:
        dirs = [os.path.join(tmpdir, f"multi_{i}") for i in range(3)]
        for d in dirs:
            os.mkdir(d)
        rc, out, err = fw.run_asm(dirs)
        fw.report_result(rc == 0, "rmdir: multiple dirs -> exit 0")
        fw.report_result(all(not os.path.exists(d) for d in dirs), "rmdir: all dirs removed")

    # --ignore-fail-on-non-empty
    with tempfile.TemporaryDirectory() as tmpdir:
        testdir = os.path.join(tmpdir, "ignore_test")
        os.makedirs(os.path.join(testdir, "child"))
        rc, out, err = fw.run_asm(["--ignore-fail-on-non-empty", testdir])
        fw.report_result(rc == 0, "rmdir: --ignore-fail-on-non-empty -> exit 0")
        fw.report_result(err == b"", "rmdir: --ignore-fail-on-non-empty -> no stderr")

    # -v verbose output
    with tempfile.TemporaryDirectory() as tmpdir:
        testdir = os.path.join(tmpdir, "verbose_test")
        os.mkdir(testdir)
        rc, out, err = fw.run_asm(["-v", testdir])
        fw.report_result(rc == 0, "rmdir: -v -> exit 0")
        fw.report_result(b"removing directory" in err, "rmdir: -v produces verbose output")

    # Error message format
    rc, out, err = fw.run_asm(["/tmp/nonexistent_format_specific"])
    fw.report_result(b"rmdir: failed to remove '" in err, "rmdir: error format correct")

    # --help and --version
    rc, out, err = fw.run_asm(["--help"])
    fw.report_result(rc == 0 and len(out) > 0, "rmdir: --help works")

    rc, out, err = fw.run_asm(["--version"])
    fw.report_result(rc == 0 and len(out) > 0, "rmdir: --version works")

if __name__ == '__main__':
    # rmdir needs --help for the framework's generic tests (no temp dir needed)
    config['test_args'] = ['--help']
    fw = SecurityTestFramework(config)
    fw.run_all(tool_specific_fn=tool_specific_tests)
