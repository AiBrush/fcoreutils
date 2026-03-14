#!/usr/bin/env python3
"""Security tests for ffalse — uses shared framework."""
import sys, os, subprocess
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', '..', 'tests'))
from security_framework import SecurityTestFramework

config = {
    'tool_name': 'false',
    'bin_name': 'ffalse',
    'gnu_path': '/usr/bin/false',
    'bss_size': 65536,
    'max_binary_size': 30000,
    'test_args': [],
    'test_stdin': None,
    'timeout': 5,
}

def tool_specific_tests(fw):
    """13. Tool-specific: false tests."""
    fw.log("\n=== False-Specific Tests ===")

    # MUST exit 1 always, no matter what
    fw.report_result(fw.run_asm([])[0] == 1, "false: bare invocation -> exit 1")
    fw.report_result(fw.run_asm([""])[0] == 1, "false: empty arg -> exit 1")
    fw.report_result(fw.run_asm(["hello"])[0] == 1, "false: 'hello' arg -> exit 1")
    fw.report_result(fw.run_asm(["--help"])[0] == 1, "false: --help -> exit 1")
    fw.report_result(fw.run_asm(["--version"])[0] == 1, "false: --version -> exit 1")
    fw.report_result(fw.run_asm(["--"])[0] == 1, "false: -- -> exit 1")
    fw.report_result(fw.run_asm(["-n"])[0] == 1, "false: -n -> exit 1")
    fw.report_result(fw.run_asm(["true"])[0] == 1, "false: 'true' arg -> exit 1")

    # No output for ANY args (GNU false produces no output at all)
    for args in [[], ["hello"], ["a", "b", "c"], ["--help"], ["--version"]]:
        rc, out, err = fw.run_asm(args)
        fw.report_result(len(out) == 0, f"false: no stdout with args {args}")
        fw.report_result(len(err) == 0, f"false: no stderr with args {args}")

    # Ignores stdin completely
    rc, out, err = fw.run_asm([], stdin_data=b"some input data\n")
    fw.report_result(rc == 1, "false: ignores stdin -> exit 1")
    fw.report_result(len(out) == 0, "false: ignores stdin -> no stdout")

    # Pipeline behavior
    BIN = fw.bin_path
    script = f'echo hello | {BIN} | cat'
    p = subprocess.run(["bash", "-c", script], capture_output=True, timeout=fw.timeout, text=True)
    fw.report_result(p.stdout == "", "false: in pipeline -> no output forwarded")

    # Contrast with true — opposite exit code
    rc_false, _, _ = fw.run_asm([])
    if os.path.exists("/usr/bin/true"):
        rc_true, _, _ = fw.run(["/usr/bin/true"])
        fw.report_result(rc_false != rc_true, f"false: exit code differs from true ({rc_false} vs {rc_true})")
        fw.report_result(rc_false == 1 and rc_true == 0, "false: exit 1 vs true exit 0")

    # GNU compatibility — exact match on exit codes
    if os.path.exists(fw.gnu_path):
        for args in [[], ["--help"], ["--version"], ["--badopt"], ["hello"]]:
            rc_a, out_a, err_a = fw.run_asm(args)
            rc_g, out_g, err_g = fw.run_gnu(args)
            fw.report_result(rc_a == rc_g, f"false: GNU compat exit code for args {args} ({rc_a} vs {rc_g})")

if __name__ == '__main__':
    fw = SecurityTestFramework(config)
    fw.run_all(tool_specific_fn=tool_specific_tests)
