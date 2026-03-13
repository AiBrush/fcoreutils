#!/usr/bin/env python3
"""security_tests.py -- Security & memory safety tests for fwhoami.

Uses the shared SecurityTestFramework with tool-specific whoami tests.
"""

import os
import re
import subprocess
import sys
import pwd

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', '..', 'tests'))
from security_framework import SecurityTestFramework

config = {
    'tool_name': 'whoami',
    'bin_name': 'fwhoami',
    'gnu_path': '/usr/bin/whoami',
    'bss_size': 65536,
    'max_binary_size': 30000,
    'test_args': [],
    'test_stdin': None,
    'timeout': 5,
}


def tool_specific_tests(fw):
    """Category 13: whoami-specific tests."""
    fw.log("\n=== Tool-Specific: whoami ===")

    rc, out, err = fw.run_asm([])
    name = out.decode(errors="replace").strip()

    fw.report_result(rc == 0, "whoami: exit code 0")
    fw.report_result(len(name) > 0, f"whoami: non-empty output '{name}'")
    fw.report_result(out.endswith(b"\n"), "whoami: output ends with newline")

    # Should match effective user
    effective_user = pwd.getpwuid(os.geteuid()).pw_name
    fw.report_result(name == effective_user,
                     f"whoami: '{name}' matches effective user '{effective_user}'")

    # Should match $USER env var (usually)
    env_user = os.environ.get("USER", "")
    if env_user:
        fw.report_result(name == env_user,
                         f"whoami: '{name}' matches $USER '{env_user}'")

    # Should match id -un
    p = subprocess.run(["id", "-un"], capture_output=True, text=True, timeout=5)
    id_user = p.stdout.strip()
    fw.report_result(name == id_user,
                     f"whoami: '{name}' matches 'id -un' '{id_user}'")

    # Compare with GNU whoami
    if os.path.exists(fw.gnu_path):
        rc_g, out_g, _ = fw.run_gnu([])
        gnu_name = out_g.decode(errors="replace").strip()
        fw.report_result(name == gnu_name,
                         f"whoami: '{name}' matches GNU '{gnu_name}'")

    # Exactly one line
    lines = out.decode(errors="replace").split("\n")
    non_empty = [l for l in lines if l]
    fw.report_result(len(non_empty) == 1, "whoami: exactly one line of output")

    # No stderr
    fw.report_result(len(err) == 0, "whoami: no stderr output")

    # Valid username format
    valid = re.match(r'^[a-zA-Z0-9_][\-a-zA-Z0-9_.]*$', name)
    fw.report_result(valid is not None, f"whoami: '{name}' is valid username format")

    # Ignores arguments
    rc, out2, _ = fw.run_asm(["ignored"])
    fw.report_result(rc < 128, "whoami: with extra arg -- no signal death")

    # Multiple runs same result
    results = [fw.run_asm([])[1] for _ in range(10)]
    fw.report_result(all(r == results[0] for r in results), "whoami: 10 runs same output")

    # With -- separator
    rc, _, _ = fw.run_asm(["--"])
    fw.report_result(rc < 128, "whoami: -- -- no signal death")

    # Not affected by USER env var (uses geteuid, not env)
    env = os.environ.copy()
    env["USER"] = "fake_user_12345"
    rc, out, _ = fw.run_asm([], env=env)
    if rc == 0:
        fw.report_result(out.decode().strip() == effective_user,
                         "whoami: ignores $USER, uses effective UID")


if __name__ == '__main__':
    fw = SecurityTestFramework(config)
    fw.run_all(tool_specific_fn=tool_specific_tests)
