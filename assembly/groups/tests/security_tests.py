#!/usr/bin/env python3
"""security_tests.py — Security & memory safety tests for fgroups (assembly groups).

Uses the shared SecurityTestFramework plus groups-specific tests.
"""

import os
import sys
import pwd

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', '..', 'tests'))
from security_framework import SecurityTestFramework
from shutil import which

config = {
    'tool_name': 'groups',
    'bin_name': 'fgroups',
    'gnu_path': '/usr/bin/groups',
    'bss_size': 65536,
    'max_binary_size': 30000,
    'test_args': [],
    'test_stdin': None,
    'timeout': 5,
}


def tool_specific_tests(fw):
    """Category 13: groups-specific tests."""
    fw.log("\n=== Groups-Specific Tests ===")

    # Basic invocation
    rc, out, err = fw.run_asm([])
    fw.report_result(rc == 0, "groups: no args -> exit 0")
    fw.report_result(len(out) > 0, "groups: produces output")
    fw.report_result(out.endswith(b"\n"), "groups: ends with newline")

    # Output should contain at least one group name
    groups_str = out.decode(errors="replace").strip()
    group_names = groups_str.split()
    fw.report_result(len(group_names) >= 1, f"groups: at least one group ({len(group_names)} found)")

    # Compare with GNU
    gnu_path = which("groups")
    if gnu_path:
        rc_g, out_g, _ = fw.run_gnu([])
        if rc_g == 0:
            g_groups = set(out_g.decode().strip().split())
            f_groups = set(groups_str.split())
            fw.report_result(f_groups == g_groups, "groups: matches GNU groups")

    # With username argument
    username = pwd.getpwuid(os.getuid()).pw_name
    rc, out, _ = fw.run_asm([username])
    fw.report_result(rc == 0, f"groups: '{username}' -> exit 0")
    if rc == 0:
        output = out.decode(errors="replace").strip()
        fw.report_result(username in output, f"groups: output contains username '{username}'")
        fw.report_result(" : " in output, "groups: output contains ' : ' separator")

    # Nonexistent user
    rc, out, err = fw.run_asm(["nonexistent_user_xyz_12345"])
    fw.report_result(rc == 1, "groups: nonexistent user -> exit 1")
    fw.report_result(len(err) > 0, "groups: nonexistent user -> stderr output")

    # Multiple runs same result
    results = [fw.run_asm([])[1] for _ in range(10)]
    fw.report_result(all(r == results[0] for r in results), "groups: 10 runs same output")

    # --help
    rc, out, _ = fw.run_asm(["--help"])
    fw.report_result(rc == 0, "groups: --help -> exit 0")
    fw.report_result(b"Usage:" in out, "groups: --help contains Usage:")

    # --version
    rc, out, _ = fw.run_asm(["--version"])
    fw.report_result(rc == 0, "groups: --version -> exit 0")
    fw.report_result(b"groups" in out, "groups: --version contains 'groups'")


if __name__ == '__main__':
    fw = SecurityTestFramework(config)
    fw.run_all(tool_specific_fn=tool_specific_tests)
