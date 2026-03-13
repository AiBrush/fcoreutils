#!/usr/bin/env python3
"""Security tests for fmknod — uses shared framework."""
import os
import sys
import stat
import tempfile

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', '..', 'tests'))
from security_framework import SecurityTestFramework

config = {
    'tool_name': 'mknod',
    'bin_name': 'fmknod',
    'gnu_path': '/usr/bin/mknod',
    'bss_size': 4096,
    'max_binary_size': 30000,
    'test_args': ['--help'],
    'test_stdin': None,
    'timeout': 5,
}


def tool_specific_tests(fw):
    """13. Tool-specific: mknod — special file creation."""
    fw.log("\n=== Tool-Specific: mknod ===")

    # Create pipe
    with tempfile.TemporaryDirectory() as tmpdir:
        testnode = os.path.join(tmpdir, "basic_pipe")
        rc, out, err = fw.run_asm([testnode, "p"])
        fw.report_result(rc == 0, "mknod: create pipe -> exit 0")
        fw.report_result(
            os.path.exists(testnode) and stat.S_ISFIFO(os.stat(testnode).st_mode),
            "mknod: file is actually a FIFO")

    # Already exists
    with tempfile.TemporaryDirectory() as tmpdir:
        testnode = os.path.join(tmpdir, "exist_pipe")
        os.mkfifo(testnode)
        rc, out, err = fw.run_asm([testnode, "p"])
        fw.report_result(rc == 1, "mknod: already exists -> exit 1")
        fw.report_result(b"File exists" in err, "mknod: EEXIST error message")

    # Nonexistent parent
    with tempfile.TemporaryDirectory() as tmpdir:
        testnode = os.path.join(tmpdir, "noparent", "node")
        rc, out, err = fw.run_asm([testnode, "p"])
        fw.report_result(rc == 1, "mknod: no parent -> exit 1")
        fw.report_result(b"No such file or directory" in err, "mknod: ENOENT error message")

    # Invalid type
    with tempfile.TemporaryDirectory() as tmpdir:
        testnode = os.path.join(tmpdir, "bad_type")
        rc, out, err = fw.run_asm([testnode, "x"])
        fw.report_result(rc == 1, "mknod: invalid type -> exit 1")

    # Missing type
    with tempfile.TemporaryDirectory() as tmpdir:
        testnode = os.path.join(tmpdir, "no_type")
        rc, out, err = fw.run_asm([testnode])
        fw.report_result(rc == 1, "mknod: missing type -> exit 1")

    # Block device (requires root, should fail with EPERM)
    with tempfile.TemporaryDirectory() as tmpdir:
        testnode = os.path.join(tmpdir, "block_dev")
        rc, out, err = fw.run_asm([testnode, "b", "1", "0"])
        fw.report_result(rc == 1, "mknod: block dev without root -> exit 1")
        fw.report_result(
            b"Operation not permitted" in err or b"Permission denied" in err,
            "mknod: block dev EPERM/EACCES message")

    # Char device (requires root)
    with tempfile.TemporaryDirectory() as tmpdir:
        testnode = os.path.join(tmpdir, "char_dev")
        rc, out, err = fw.run_asm([testnode, "c", "1", "0"])
        fw.report_result(rc == 1, "mknod: char dev without root -> exit 1")

    # -m mode for pipe
    with tempfile.TemporaryDirectory() as tmpdir:
        testnode = os.path.join(tmpdir, "mode_pipe")
        rc, out, err = fw.run_asm(["-m", "644", testnode, "p"])
        fw.report_result(rc == 0, "mknod: -m 644 pipe -> exit 0")
        if os.path.exists(testnode):
            perms = oct(os.stat(testnode).st_mode & 0o777)
            fw.report_result(perms == "0o644", f"mknod: -m 644 permissions correct ({perms})")
        else:
            fw.report_result(False, "mknod: -m 644 pipe not created")

    # Error format
    rc, out, err = fw.run_asm(["/tmp/nonexistent_parent_fmt/node", "p"])
    fw.report_result(b"mknod:" in err, "mknod: error has tool prefix")


if __name__ == '__main__':
    fw = SecurityTestFramework(config)
    fw.run_all(tool_specific_fn=tool_specific_tests)
