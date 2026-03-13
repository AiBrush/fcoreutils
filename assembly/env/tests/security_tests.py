#!/usr/bin/env python3
"""Security tests for fenv — uses shared framework."""
import sys, os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', '..', 'tests'))
from security_framework import SecurityTestFramework
from shutil import which

config = {
    'tool_name': 'env',
    'bin_name': 'fenv',
    'gnu_path': '/usr/bin/env',
    'bss_size': 65536,
    'max_binary_size': 30000,
    'test_args': [],
    'test_stdin': None,
    'timeout': 5,
}


def tool_specific_tests(fw):
    """13. Tool-specific: env — environment variable handling."""
    fw.log("\n=== Tool-Specific: env ===")

    # No args: prints all env vars
    rc, out, _ = fw.run_asm([])
    fw.report_result(rc == 0, "env: no args -> exit 0")
    lines = out.decode(errors="replace").strip().split("\n")
    has_eq = all("=" in l for l in lines if l)
    fw.report_result(has_eq, "env: no args -> all lines contain '='")

    # -i: empty env
    rc, out, _ = fw.run_asm(["-i"])
    fw.report_result(rc == 0 and out == b"", "env: -i -> empty output")

    # -i with VAR=VALUE
    rc, out, _ = fw.run_asm(["-i", "FOO=bar", "/usr/bin/printenv", "FOO"])
    if which("printenv"):
        fw.report_result(rc == 0 and out.strip() == b"bar",
                         "env: -i FOO=bar printenv FOO -> bar")
    else:
        fw.skip_test("env: -i FOO=bar", "printenv not found")

    # Command execution
    rc, _, _ = fw.run_asm(["/usr/bin/true"])
    fw.report_result(rc == 0, "env: /usr/bin/true -> exit 0")

    rc, _, _ = fw.run_asm(["/usr/bin/false"])
    fw.report_result(rc == 1, "env: /usr/bin/false -> exit 1")

    # Nonexistent command
    rc, _, _ = fw.run_asm(["/nonexistent/command"])
    fw.report_result(rc == 127, "env: nonexistent command -> exit 127")

    # -u flag
    custom_env = os.environ.copy()
    custom_env["MY_TEST_UNSET"] = "should_be_gone"
    rc, out, _ = fw.run_asm(
        ["-u", "MY_TEST_UNSET", "/usr/bin/printenv", "MY_TEST_UNSET"],
        env=custom_env,
    )
    fw.report_result(rc == 1, "env: -u removes var (printenv returns 1)")

    # VAR=VALUE override
    rc, out, _ = fw.run_asm(["HOME=/fake", "/usr/bin/printenv", "HOME"])
    if which("printenv"):
        fw.report_result(rc == 0 and out.strip() == b"/fake",
                         "env: HOME=/fake printenv HOME -> /fake")
    else:
        fw.skip_test("env: HOME=/fake", "printenv not found")

    # --help and --version
    rc, out, _ = fw.run_asm(["--help"])
    fw.report_result(rc == 0, "env: --help -> exit 0")
    fw.report_result(b"Usage:" in out, "env: --help contains Usage:")

    rc, out, _ = fw.run_asm(["--version"])
    fw.report_result(rc == 0, "env: --version -> exit 0")
    fw.report_result(b"env" in out, "env: --version contains 'env'")

    # GNU comparison (sorted, ignoring _=)
    if os.path.exists(fw.gnu_path):
        rc_f, out_f, _ = fw.run_asm([])
        rc_g, out_g, _ = fw.run_gnu([])
        f_sorted = sorted(l for l in out_f.split(b"\n") if not l.startswith(b"_="))
        g_sorted = sorted(l for l in out_g.split(b"\n") if not l.startswith(b"_="))
        fw.report_result(f_sorted == g_sorted,
                         "env: no-args matches GNU (sorted, ignoring _=)")

    # Deterministic
    results = [fw.run_asm([])[1] for _ in range(10)]
    fw.report_result(all(r == results[0] for r in results),
                     "env: 10 invocations same output")


if __name__ == '__main__':
    fw = SecurityTestFramework(config)
    fw.run_all(tool_specific_fn=tool_specific_tests)
