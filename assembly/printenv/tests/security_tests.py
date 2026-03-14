#!/usr/bin/env python3
"""security_tests.py -- Security & memory safety tests for fprintenv (assembly printenv).

Uses shared SecurityTestFramework.
fprintenv prints all or part of the environment.
"""

import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', '..', 'tests'))
from security_framework import SecurityTestFramework

config = {
    'tool_name': 'printenv',
    'bin_name': 'fprintenv',
    'gnu_path': '/usr/bin/printenv',
    'bss_size': 65536,
    'max_binary_size': 30000,
    'test_args': ['HOME'],
    'test_stdin': None,
    'timeout': 5,
}


def tool_specific_tests(fw):
    """13. printenv-specific tests: env var printing, -0, exit codes."""
    fw.log("\n=== 13. Tool-Specific: printenv ===")

    home = os.environ.get("HOME", "")

    # Core printenv behavior: single var
    rc, out, _ = fw.run_asm(["HOME"])
    fw.report_result(rc == 0 and out == home.encode() + b"\n",
                     f"printenv: HOME -> {home}")

    # Multiple vars
    path = os.environ.get("PATH", "")
    rc, out, _ = fw.run_asm(["HOME", "PATH"])
    expected = home.encode() + b"\n" + path.encode() + b"\n"
    fw.report_result(rc == 0 and out == expected, "printenv: HOME PATH -> both values")

    # Nonexistent var
    rc, out, _ = fw.run_asm(["NONEXISTENT_VAR_XYZ_12345"])
    fw.report_result(rc == 1 and out == b"", "printenv: nonexistent var -> exit 1, no output")

    # Mix of existing and nonexistent
    rc, out, _ = fw.run_asm(["HOME", "NONEXISTENT_VAR_XYZ_12345"])
    fw.report_result(rc == 1, "printenv: mixed existing/nonexistent -> exit 1")
    fw.report_result(out == home.encode() + b"\n",
                     "printenv: mixed -> prints existing var value")

    # No args: prints all env vars
    rc, out, _ = fw.run_asm([])
    fw.report_result(rc == 0, "printenv: no args -> exit 0")
    lines = out.decode(errors="replace").strip().split("\n")
    has_eq = all("=" in l for l in lines if l)
    fw.report_result(has_eq, "printenv: no args -> all lines contain '='")

    # Compare no-args output with GNU (sorted)
    if os.path.exists(fw.gnu_path):
        rc_f, out_f, _ = fw.run_asm([])
        rc_g, out_g, _ = fw.run_gnu([])
        f_sorted = sorted(out_f.split(b"\n"))
        g_sorted = sorted(out_g.split(b"\n"))
        fw.report_result(f_sorted == g_sorted, "printenv: no args matches GNU (sorted)")

    # -0 produces NUL byte
    rc, out, _ = fw.run_asm(["-0", "HOME"])
    fw.report_result(out == home.encode() + b"\x00", "printenv: -0 produces NUL byte")
    fw.report_result(b"\n" not in out, "printenv: -0 no trailing newline")

    # --null long form
    rc, out, _ = fw.run_asm(["--null", "HOME"])
    fw.report_result(out == home.encode() + b"\x00", "printenv: --null produces NUL byte")

    # -0 with no args (all env)
    rc, out, _ = fw.run_asm(["-0"])
    fw.report_result(rc == 0, "printenv: -0 no args -> exit 0")
    fw.report_result(b"\x00" in out, "printenv: -0 no args -> contains NUL bytes")
    fw.report_result(not out.endswith(b"\n"), "printenv: -0 no args -> doesn't end with newline")

    # Exit codes
    rc, _, _ = fw.run_asm(["HOME"])
    fw.report_result(rc == 0, "printenv: existing var -> exit 0")

    rc, _, _ = fw.run_asm(["NONEXISTENT_VAR_XYZ"])
    fw.report_result(rc == 1, "printenv: nonexistent var -> exit 1")

    rc, _, _ = fw.run_asm(["--invalid-opt-xyz"])
    fw.report_result(rc == 2, "printenv: invalid option -> exit 2")

    rc, _, _ = fw.run_asm(["-Z"])
    fw.report_result(rc == 2, "printenv: invalid short option -> exit 2")

    # Custom env: verify correct lookup
    custom_env = {"MY_TEST_VAR": "hello_world_123", "ANOTHER": "value"}
    rc, out, _ = fw.run_asm(["MY_TEST_VAR"], env=custom_env)
    fw.report_result(rc == 0 and out == b"hello_world_123\n",
                     "printenv: custom env var lookup")

    # Var with = in value
    eq_env = {"HAS_EQUALS": "key=value=more"}
    rc, out, _ = fw.run_asm(["HAS_EQUALS"], env=eq_env)
    fw.report_result(rc == 0 and out == b"key=value=more\n",
                     "printenv: var with = in value")

    # Empty value
    empty_env = {"EMPTY_VAR": ""}
    rc, out, _ = fw.run_asm(["EMPTY_VAR"], env=empty_env)
    fw.report_result(rc == 0 and out == b"\n",
                     "printenv: empty value -> just newline")

    # -- separator
    rc, out, _ = fw.run_asm(["--", "HOME"])
    fw.report_result(rc == 0 and out == home.encode() + b"\n",
                     "printenv: -- separator works")


if __name__ == '__main__':
    fw = SecurityTestFramework(config)
    fw.run_all(tool_specific_fn=tool_specific_tests)
