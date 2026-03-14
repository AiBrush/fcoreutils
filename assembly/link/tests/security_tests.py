#!/usr/bin/env python3
"""Security tests for flink — uses shared framework."""
import sys, os, tempfile
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', '..', 'tests'))
from security_framework import SecurityTestFramework

config = {
    'tool_name': 'link',
    'bin_name': 'flink',
    'gnu_path': '/usr/bin/link',
    'bss_size': 4096,
    'max_binary_size': 30000,
    # Use nonexistent source so link fails idempotently (exit 1 every time).
    # This avoids issues with test_args creating filesystem objects that persist
    # across repeated runs by the framework (determinism checks, concurrency).
    'test_args': ['/nonexistent/__flink_test_src__', '/tmp/_flink_test_dst'],
    'test_stdin': None,
}

def tool_specific_tests(fw):
    """13. Tool-specific: link — hard link creation behavior."""
    fw.log("\n=== Tool-Specific: link ===")

    with tempfile.TemporaryDirectory() as tmpdir:
        src = os.path.join(tmpdir, "src")
        dst = os.path.join(tmpdir, "dst")
        with open(src, "w") as f:
            f.write("hello world")

        # Basic hard link
        rc, out, err = fw.run_asm([src, dst])
        fw.report_result(rc == 0, "link: basic hard link creation exits 0")
        fw.report_result(out == b"", "link: no stdout on success")
        fw.report_result(err == b"", "link: no stderr on success")

        try:
            src_stat = os.stat(src)
            dst_stat = os.stat(dst)
            fw.report_result(src_stat.st_ino == dst_stat.st_ino, "link: same inode (hard link)")
            fw.report_result(src_stat.st_nlink >= 2, "link: link count >= 2")
            with open(dst) as f:
                fw.report_result(f.read() == "hello world", "link: content matches")
        except FileNotFoundError:
            fw.report_result(False, "link: destination created")

        # EEXIST
        os.unlink(dst)
        with open(dst, "w") as f:
            f.write("existing")
        rc, out, err = fw.run_asm([src, dst])
        fw.report_result(rc == 1, "link: EEXIST exits 1")
        fw.report_result(b"File exists" in err, "link: EEXIST error message")

        # ENOENT
        os.unlink(dst)
        rc, out, err = fw.run_asm([os.path.join(tmpdir, "nosuch"), dst])
        fw.report_result(rc == 1, "link: ENOENT exits 1")
        fw.report_result(b"No such file" in err, "link: ENOENT error message")

    # Missing operand
    rc, out, err = fw.run_asm([])
    fw.report_result(b"missing operand" in err, "link: missing operand message")

    # --help
    rc, out, err = fw.run_asm(['--help'])
    fw.report_result(rc == 0, "link: --help exits 0")
    fw.report_result(b"Usage:" in out, "link: --help contains Usage:")

    # --version
    rc, out, err = fw.run_asm(['--version'])
    fw.report_result(rc == 0, "link: --version exits 0")

    # Cleanup (test_args dst may have been created by framework runs)
    try:
        os.unlink('/tmp/_flink_test_dst')
    except OSError:
        pass

if __name__ == '__main__':
    fw = SecurityTestFramework(config)
    fw.run_all(tool_specific_fn=tool_specific_tests)
