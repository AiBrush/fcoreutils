#!/usr/bin/env python3
"""Security tests for fchgrp — uses shared framework."""
import sys, os, subprocess, tempfile
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', '..', 'tests'))
from security_framework import SecurityTestFramework

config = {
    'tool_name': 'chgrp',
    'bin_name': 'fchgrp',
    'gnu_path': '/usr/bin/chgrp',
    'bss_size': 65536,
    'max_binary_size': 102400,
    'test_args': ['--help'],
    'test_stdin': None,
    'timeout': 5,
}

def tool_specific_tests(fw):
    """13. Tool-specific: chgrp group change tests."""
    fw.log("\n=== Chgrp-Specific Tests ===")
    gname = subprocess.check_output(["id", "-gn"]).decode().strip()
    gid = int(subprocess.check_output(["id", "-g"]).decode().strip())

    with tempfile.TemporaryDirectory() as td:
        tf = os.path.join(td, "chgrp_test")
        open(tf, "w").close()

        # By group name
        rc, _, _ = fw.run_asm([gname, tf])
        actual = os.stat(tf).st_gid
        fw.report_result(rc == 0 and actual == gid, f"chgrp: by name -> gid {actual}")

        # By numeric gid
        rc, _, _ = fw.run_asm([str(gid), tf])
        actual = os.stat(tf).st_gid
        fw.report_result(rc == 0 and actual == gid, f"chgrp: by gid -> gid {actual}")

        # Error on nonexistent file
        rc, _, err = fw.run_asm([gname, os.path.join(td, "no_such_file")])
        fw.report_result(rc != 0, "chgrp: nonexistent file -> error exit")

        # Invalid group
        rc, _, err = fw.run_asm(["totally_fake_group_xyz", tf])
        fw.report_result(rc != 0, "chgrp: invalid group -> error exit")

if __name__ == '__main__':
    fw = SecurityTestFramework(config)
    fw.run_all(tool_specific_fn=tool_specific_tests)
