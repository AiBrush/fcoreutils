#!/usr/bin/env python3
"""Security tests for fstat — uses shared framework."""
import sys, os, tempfile
from pathlib import Path
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', '..', 'tests'))
from security_framework import SecurityTestFramework

config = {
    'tool_name': 'stat',
    'bin_name': 'fstat',
    'gnu_path': '/usr/bin/stat',
    'bss_size': 65536,
    'max_binary_size': 30000,
    'test_args': ['/etc/hosts'],
    'test_stdin': None,
    'timeout': 5,
}

def tool_specific_tests(fw):
    """13. Tool-specific: stat file status display tests."""
    fw.log("\n=== Stat-Specific Tests ===")

    with tempfile.TemporaryDirectory(prefix="fstat_test_") as tmpdir:
        # Setup fixtures
        testfile = os.path.join(tmpdir, "testfile")
        Path(testfile).touch()
        testdir = os.path.join(tmpdir, "testdir")
        os.makedirs(testdir, exist_ok=True)
        symlink = os.path.join(tmpdir, "symlink")
        os.symlink(testfile, symlink)

        # Basic format specifiers
        for spec in ["%n", "%s", "%b", "%i", "%h", "%u", "%g", "%a", "%o",
                     "%X", "%Y", "%Z", "%W", "%F"]:
            rc, out, _ = fw.run_asm(["-c", spec, testfile])
            fw.report_result(rc == 0 and len(out) > 0,
                            f"stat: -c {spec} produces output")

        # Compare with GNU for key specifiers
        gnu_path = fw.gnu_path
        if gnu_path and os.path.exists(gnu_path):
            for spec in ["%n", "%s", "%b", "%i", "%h", "%u", "%g", "%a",
                         "%X", "%Y", "%Z", "%W"]:
                rc_f, out_f, _ = fw.run_asm(["-c", spec, testfile])
                rc_g, out_g, _ = fw.run_gnu(["-c", spec, testfile])
                fw.report_result(out_f == out_g,
                                f"stat: -c {spec} matches GNU")

        # File type detection
        rc, out, _ = fw.run_asm(["-c", "%F", testfile])
        fw.report_result(b"regular" in out, "stat: detects regular file")

        rc, out, _ = fw.run_asm(["-c", "%F", testdir])
        fw.report_result(b"directory" in out, "stat: detects directory")

        rc, out, _ = fw.run_asm(["-c", "%F", symlink])
        fw.report_result(b"symbolic link" in out, "stat: detects symlink (no -L)")

        # -L follows symlinks
        rc, out, _ = fw.run_asm(["-L", "-c", "%F", symlink])
        fw.report_result(b"regular" in out, "stat: -L follows symlink")

        # Terse output
        rc, out, _ = fw.run_asm(["-t", testfile])
        fw.report_result(rc == 0 and len(out.split()) >= 10,
                        "stat: -t terse output has many fields")

        # Error on nonexistent
        rc, out, err = fw.run_asm([os.path.join(tmpdir, "nonexistent")])
        fw.report_result(rc == 1, "stat: nonexistent exits 1")
        fw.report_result(b"cannot stat" in err or b"No such" in err,
                        "stat: nonexistent produces error message")

if __name__ == '__main__':
    fw = SecurityTestFramework(config)
    fw.run_all(tool_specific_fn=tool_specific_tests)
