#!/usr/bin/env python3
"""security_tests.py -- Security & memory safety tests for fid.

Uses the shared SecurityTestFramework for categories 1-12,
plus tool-specific tests for id behavior.
"""

import sys
import os
import pwd
import grp

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', '..', 'tests'))
from security_framework import SecurityTestFramework

config = {
    'tool_name': 'id',
    'bin_name': 'fid',
    'gnu_path': '/usr/bin/id',
    'bss_size': 65536,
    'max_binary_size': 30000,
    'test_args': [],
    'test_stdin': None,
    'timeout': 5,
}


def tool_specific_tests(fw):
    """Category 13: id-specific tests."""
    fw.log("\n=== Tool-Specific: id ===")

    # Basic invocation
    rc, out, err = fw.run_asm([])
    output = out.decode(errors="replace").strip()
    fw.report_result(rc == 0, "id: no args exit 0")
    fw.report_result("uid=" in output, "id: output contains uid=")
    fw.report_result("gid=" in output, "id: output contains gid=")
    fw.report_result("groups=" in output, "id: output contains groups=")

    # -u
    rc, out, _ = fw.run_asm(["-u"])
    uid_str = out.decode().strip()
    euid = os.geteuid()
    fw.report_result(rc == 0 and uid_str == str(euid),
                     f"id -u: '{uid_str}' matches euid {euid}")

    # -g
    rc, out, _ = fw.run_asm(["-g"])
    gid_str = out.decode().strip()
    egid = os.getegid()
    fw.report_result(rc == 0 and gid_str == str(egid),
                     f"id -g: '{gid_str}' matches egid {egid}")

    # -un
    rc, out, _ = fw.run_asm(["-un"])
    uname = out.decode().strip()
    expected_name = pwd.getpwuid(euid).pw_name
    fw.report_result(rc == 0 and uname == expected_name,
                     f"id -un: '{uname}' matches '{expected_name}'")

    # -gn
    rc, out, _ = fw.run_asm(["-gn"])
    gname = out.decode().strip()
    expected_gname = grp.getgrgid(egid).gr_name
    fw.report_result(rc == 0 and gname == expected_gname,
                     f"id -gn: '{gname}' matches '{expected_gname}'")

    # -G
    rc, out, _ = fw.run_asm(["-G"])
    fw.report_result(rc == 0, "id -G: exit 0")
    gids = out.decode().strip().split()
    fw.report_result(len(gids) >= 1, f"id -G: at least 1 group ({len(gids)} found)")

    # -Gn
    rc, out, _ = fw.run_asm(["-Gn"])
    fw.report_result(rc == 0, "id -Gn: exit 0")
    names = out.decode().strip().split()
    fw.report_result(len(names) >= 1, f"id -Gn: at least 1 group name ({len(names)} found)")

    # Compare with GNU
    if os.path.exists(fw.gnu_path):
        rc_f, out_f, _ = fw.run_asm([])
        rc_g, out_g, _ = fw.run_gnu([])
        fw.report_result(rc_f == rc_g and out_f == out_g,
                         "id: full output matches GNU")

        # -G comparison (as sets since order may differ)
        rc_f, out_f, _ = fw.run_asm(["-G"])
        rc_g, out_g, _ = fw.run_gnu(["-G"])
        f_gids = set(out_f.decode().strip().split())
        g_gids = set(out_g.decode().strip().split())
        fw.report_result(f_gids == g_gids, "id -G: group ID sets match GNU")

    # With username
    username = pwd.getpwuid(os.getuid()).pw_name
    rc, out, _ = fw.run_asm([username])
    fw.report_result(rc == 0, f"id '{username}': exit 0")

    # Nonexistent user
    rc, _, err = fw.run_asm(["nonexistent_user_xyz"])
    fw.report_result(rc == 1, "id nonexistent: exit 1")
    fw.report_result(len(err) > 0, "id nonexistent: stderr output")

    # --help
    rc, out, _ = fw.run_asm(["--help"])
    fw.report_result(rc == 0, "id --help: exit 0")
    fw.report_result(b"Usage:" in out, "id --help: contains Usage:")

    # --version
    rc, out, _ = fw.run_asm(["--version"])
    fw.report_result(rc == 0, "id --version: exit 0")
    fw.report_result(b"id" in out, "id --version: contains 'id'")

    # Multiple runs same result
    results = [fw.run_asm([])[1] for _ in range(10)]
    fw.report_result(all(r == results[0] for r in results), "id: 10 runs same output")


if __name__ == '__main__':
    fw = SecurityTestFramework(config)
    fw.run_all(tool_specific_fn=tool_specific_tests)
