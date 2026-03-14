#!/usr/bin/env python3
"""Security tests for fmkfifo — uses shared framework."""
import sys, os, tempfile, stat
from shutil import which
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', '..', 'tests'))
from security_framework import SecurityTestFramework

config = {
    'tool_name': 'mkfifo',
    'bin_name': 'fmkfifo',
    'gnu_path': '/usr/bin/mkfifo',
    'bss_size': 4096,
    'max_binary_size': 30000,
    # Use nonexistent parent so mkfifo fails idempotently (exit 1 every time).
    # This avoids issues with test_args creating filesystem objects that persist
    # across repeated runs by the framework (determinism checks, concurrency).
    'test_args': ['/nonexistent/__fmkfifo_test__'],
    'test_stdin': None,
}

def tool_specific_tests(fw):
    """13. Tool-specific: mkfifo — FIFO creation behavior."""
    fw.log("\n=== Tool-Specific: mkfifo ===")

    # Create FIFO
    with tempfile.TemporaryDirectory() as tmpdir:
        testfifo = os.path.join(tmpdir, "basic_fifo")
        rc, out, err = fw.run_asm([testfifo])
        fw.report_result(rc == 0, "mkfifo: create fifo -> exit 0")
        fw.report_result(os.path.exists(testfifo) and stat.S_ISFIFO(os.stat(testfifo).st_mode),
                         "mkfifo: file is actually a FIFO")

    # Already exists
    with tempfile.TemporaryDirectory() as tmpdir:
        testfifo = os.path.join(tmpdir, "exist_fifo")
        os.mkfifo(testfifo)
        rc, out, err = fw.run_asm([testfifo])
        fw.report_result(rc == 1, "mkfifo: already exists -> exit 1")
        fw.report_result(b"File exists" in err, "mkfifo: EEXIST error message")

    # Nonexistent parent
    with tempfile.TemporaryDirectory() as tmpdir:
        testfifo = os.path.join(tmpdir, "noparent", "fifo")
        rc, out, err = fw.run_asm([testfifo])
        fw.report_result(rc == 1, "mkfifo: no parent -> exit 1")
        fw.report_result(b"No such file or directory" in err, "mkfifo: ENOENT error message")

    # Multiple FIFOs
    with tempfile.TemporaryDirectory() as tmpdir:
        fifos = [os.path.join(tmpdir, f"multi_{i}") for i in range(3)]
        rc, out, err = fw.run_asm(fifos)
        fw.report_result(rc == 0, "mkfifo: multiple fifos -> exit 0")
        fw.report_result(all(stat.S_ISFIFO(os.stat(f).st_mode) for f in fifos),
                         "mkfifo: all are FIFOs")

    # -m mode
    with tempfile.TemporaryDirectory() as tmpdir:
        testfifo = os.path.join(tmpdir, "mode_fifo")
        rc, out, err = fw.run_asm(["-m", "644", testfifo])
        fw.report_result(rc == 0, "mkfifo: -m 644 -> exit 0")
        if os.path.exists(testfifo):
            perms = oct(os.stat(testfifo).st_mode & 0o777)
            fw.report_result(perms == "0o644", f"mkfifo: -m 644 permissions correct ({perms})")
        else:
            fw.report_result(False, "mkfifo: -m 644 fifo not created")

    # Error format
    rc, out, err = fw.run_asm(["/tmp/nonexistent_parent_fmt/fifo"])
    fw.report_result(b"mkfifo: cannot create fifo '" in err, "mkfifo: error format correct")

    # mknod syscall (strace)
    if which("strace"):
        with tempfile.TemporaryDirectory() as tmpdir:
            testfifo = os.path.join(tmpdir, "strace_fifo")
            cmd = ["strace", "-e", "trace=mknod,mknodat", fw.bin_path, testfifo]
            rc, out, err = fw.run(cmd)
            err_text = err.decode(errors="replace")
            fw.report_result("mknod(" in err_text or "mknodat(" in err_text,
                             "mkfifo: uses mknod() syscall")

if __name__ == '__main__':
    fw = SecurityTestFramework(config)
    fw.run_all(tool_specific_fn=tool_specific_tests)
