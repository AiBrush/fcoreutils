#!/usr/bin/env python3
"""security_tests.py -- Security & memory safety tests for ftrue (assembly true).

Uses shared SecurityTestFramework. true must always exit 0, produce no output
on normal args, and ignore all arguments. Any crash is a security vulnerability.
"""

import os
import sys
import subprocess

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', '..', 'tests'))
from security_framework import SecurityTestFramework

config = {
    'tool_name': 'true',
    'bin_name': 'ftrue',
    'gnu_path': '/usr/bin/true',
    'bss_size': 4096,
    'max_binary_size': 30000,
    'test_args': [],
    'test_stdin': None,
    'timeout': 5,
}


def tool_specific_tests(fw):
    """13. true-specific tests."""
    fw.log("\n=== 13. Tool-Specific: true ===")

    # MUST exit 0 always, no matter what
    for desc, args in [
        ("bare invocation", []),
        ("empty arg", [""]),
        ("'hello' arg", ["hello"]),
        ("--help", ["--help"]),
        ("--version", ["--version"]),
        ("-- separator", ["--"]),
        ("-n flag", ["-n"]),
        ("'false' arg", ["false"]),
    ]:
        rc, _, _ = fw.run_asm(args)
        fw.report_result(rc == 0, f"true: {desc} -> exit 0")

    # No stdout for normal args
    for args in [[], ["hello"], ["a", "b", "c"]]:
        rc, out, err = fw.run_asm(args)
        fw.report_result(len(out) == 0, f"true: no stdout with args {args}")

    # --help and --version SHOULD produce output
    for args in [["--help"], ["--version"]]:
        rc, out, err = fw.run_asm(args)
        fw.report_result(len(out) > 0, f"true: has stdout with args {args}")

    # Ignores stdin completely
    rc, out, err = fw.run_asm([], stdin_data=b"some input data\n")
    fw.report_result(rc == 0, "true: ignores stdin -> exit 0")
    fw.report_result(len(out) == 0, "true: ignores stdin -> no stdout")

    # Pipeline behavior
    p = subprocess.run(
        ["bash", "-c", f'echo hello | {fw.bin_path} | cat'],
        capture_output=True, timeout=fw.timeout, text=True,
    )
    fw.report_result(p.returncode == 0, "true: in pipeline -> exit 0")
    fw.report_result(p.stdout == "", "true: in pipeline -> no output forwarded")

    # Pipe chain
    p = subprocess.run(
        ["bash", "-c", f'{fw.bin_path} | {fw.bin_path} | {fw.bin_path}; echo $?'],
        capture_output=True, timeout=fw.timeout, text=True,
    )
    fw.report_result(p.stdout.strip() == "0", "true: pipe chain -> exit 0")


if __name__ == '__main__':
    fw = SecurityTestFramework(config)
    fw.run_all(tool_specific_fn=tool_specific_tests)
