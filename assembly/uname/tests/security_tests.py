#!/usr/bin/env python3
"""security_tests.py -- Security & memory safety tests for funame (assembly uname).

Uses shared SecurityTestFramework.
funame prints system information using the uname() syscall.
"""

import os
import sys
import random

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', '..', 'tests'))
from security_framework import SecurityTestFramework
from shutil import which

config = {
    'tool_name': 'uname',
    'bin_name': 'funame',
    'gnu_path': '/usr/bin/uname',
    'bss_size': 65536,
    'max_binary_size': 30000,
    'test_args': [],
    'test_stdin': None,
    'timeout': 5,
}


def tool_specific_tests(fw):
    """13. uname-specific tests: system information output."""
    fw.log("\n=== 13. Tool-Specific: uname ===")

    GNU = '/usr/bin/uname'
    gnu_path = which('uname')

    # Default output (no flags) should be same as -s
    rc_def, out_def, _ = fw.run_asm([])
    rc_s, out_s, _ = fw.run_asm(["-s"])
    fw.report_result(out_def == out_s, "uname: default output equals -s")

    # -a should contain all individual fields
    rc, out_a, _ = fw.run_asm(["-a"])
    out_a_str = out_a.decode().strip()

    for flag in ["-s", "-n", "-r", "-v", "-m"]:
        _, out_f, _ = fw.run_asm([flag])
        field = out_f.decode().strip()
        fw.report_result(field in out_a_str,
                         f"uname: -a contains {flag} field '{field}'")

    # -o should output "GNU/Linux"
    rc, out, _ = fw.run_asm(["-o"])
    fw.report_result(out == b"GNU/Linux\n", "uname: -o outputs GNU/Linux")

    # Combined flags produce space-separated output
    rc, out, _ = fw.run_asm(["-sn"])
    parts = out.decode().strip().split(" ")
    fw.report_result(len(parts) >= 2, "uname: -sn produces at least 2 space-separated fields")

    # Repeated flag should match GNU behavior
    if gnu_path:
        _, gnu_double, _ = fw.run_gnu(["-ss"])
        _, out_double, _ = fw.run_asm(["-ss"])
        fw.report_result(out_double == gnu_double, "uname: -ss matches GNU behavior")

    # All long flags work
    long_flags = [
        ("--kernel-name", "-s"),
        ("--nodename", "-n"),
        ("--kernel-release", "-r"),
        ("--kernel-version", "-v"),
        ("--machine", "-m"),
        ("--processor", "-p"),
        ("--hardware-platform", "-i"),
        ("--operating-system", "-o"),
        ("--all", "-a"),
    ]
    for long_flag, short_flag in long_flags:
        rc_l, out_l, _ = fw.run_asm([long_flag])
        rc_s, out_s, _ = fw.run_asm([short_flag])
        fw.report_result(out_l == out_s and rc_l == rc_s,
                         f"uname: {long_flag} equals {short_flag}")

    # Output ends with newline
    rc, out, _ = fw.run_asm(["-a"])
    fw.report_result(out.endswith(b"\n"), "uname: -a output ends with newline")

    # No trailing space before newline
    fw.report_result(not out.endswith(b" \n"), "uname: no trailing space before newline")

    # Compare with GNU
    if gnu_path:
        for flags in [[], ["-s"], ["-n"], ["-r"], ["-v"], ["-m"], ["-a"],
                      ["-p"], ["-i"], ["-o"], ["-snrvm"], ["-snrvmpio"]]:
            rc_f, out_f, _ = fw.run_asm(flags)
            rc_g, out_g, _ = fw.run_gnu(flags)
            flag_str = " ".join(flags) if flags else "(default)"
            fw.report_result(out_f == out_g and rc_f == rc_g,
                             f"uname: output matches GNU for '{flag_str}'")

        # -a exact match
        rc_f, out_f, _ = fw.run_asm(["-a"])
        rc_g, out_g, _ = fw.run_gnu(["-a"])
        fw.report_result(out_f == out_g, "uname: -a output matches GNU exactly")

    # Extra operand error
    rc, out, err = fw.run_asm(["foo"])
    fw.report_result(rc == 1, "uname: extra operand exits 1")
    fw.report_result(b"extra operand" in err, "uname: extra operand error message")

    # Invalid option error
    rc, out, err = fw.run_asm(["-Z"])
    fw.report_result(rc == 1, "uname: invalid option exits 1")
    fw.report_result(b"invalid option" in err, "uname: invalid option error message")

    # Random flag combos no crash
    for i in range(10):
        flags = "-" + "".join(random.choices("snrvmpioa", k=random.randint(1, 8)))
        rc, _, _ = fw.run_asm([flags])
        if rc >= 128:
            fw.report_result(False, f"uname: crash with random flag combo (trial {i})")
            break
    else:
        fw.report_result(True, "uname: no crash with 10 random flag combos")


if __name__ == '__main__':
    fw = SecurityTestFramework(config)
    fw.run_all(tool_specific_fn=tool_specific_tests)
