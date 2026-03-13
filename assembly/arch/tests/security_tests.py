#!/usr/bin/env python3
"""Security tests for farch — uses shared framework."""
import sys, os, platform, subprocess
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', '..', 'tests'))
from security_framework import SecurityTestFramework

config = {
    'tool_name': 'arch',
    'bin_name': 'farch',
    'gnu_path': '/usr/bin/arch',
    'bss_size': 4096,
    'max_binary_size': 30000,
    'test_args': [],
    'test_stdin': None,
}

def tool_specific_tests(fw):
    """13. Tool-specific: arch — valid arch string, matches uname -m."""
    fw.log("\n=== Tool-Specific: arch ===")

    rc, out, err = fw.run_asm([])
    arch_str = out.decode(errors="replace").strip()

    fw.report_result(rc == 0, "arch: exit code 0")
    fw.report_result(len(arch_str) > 0, "arch: produces non-empty output")

    valid_archs = ["x86_64", "i686", "i386", "aarch64", "armv7l", "armv6l",
                   "ppc64le", "ppc64", "s390x", "riscv64", "mips64", "mips"]
    fw.report_result(arch_str in valid_archs,
                     f"arch: output '{arch_str}' is valid architecture string")

    uname_m = platform.machine()
    fw.report_result(arch_str == uname_m,
                     f"arch: output '{arch_str}' matches uname -m '{uname_m}'")

    p = subprocess.run(["uname", "-m"], capture_output=True, text=True, timeout=5)
    uname_cmd = p.stdout.strip()
    fw.report_result(arch_str == uname_cmd,
                     f"arch: output matches 'uname -m' command ('{uname_cmd}')")

    lines = out.decode(errors="replace").split("\n")
    non_empty = [l for l in lines if l]
    fw.report_result(len(non_empty) == 1, "arch: exactly one line of output")
    fw.report_result(out.endswith(b"\n"), "arch: output ends with newline")
    fw.report_result(arch_str == arch_str.strip(), "arch: no trailing/leading whitespace")

    if os.path.exists(fw.gnu_path):
        rc_g, out_g, _ = fw.run_gnu([])
        rc_f, out_f, _ = fw.run_asm([])
        fw.report_result(out_f == out_g, "arch: output matches GNU arch")

    rc, out, err = fw.run_asm(["--"])
    fw.report_result(rc == 0, "arch: -- separator exits 0")

    results = [fw.run_asm([])[1] for _ in range(10)]
    fw.report_result(all(r == results[0] for r in results), "arch: 10 invocations same output")

if __name__ == '__main__':
    fw = SecurityTestFramework(config)
    fw.run_all(tool_specific_fn=tool_specific_tests)
