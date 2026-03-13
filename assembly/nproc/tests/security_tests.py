#!/usr/bin/env python3
"""security_tests.py — Security & memory safety tests for fnproc (assembly nproc).

Uses the shared SecurityTestFramework for categories 1-12,
with nproc-specific tests in category 13.
"""

import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', '..', 'tests'))
from security_framework import SecurityTestFramework

config = {
    'tool_name': 'nproc',
    'bin_name': 'fnproc',
    'gnu_path': '/usr/bin/nproc',
    'bss_size': 65536,
    'max_binary_size': 30000,
    'test_args': [],
    'test_stdin': None,
    'timeout': 5,
}


def tool_specific_tests(fw):
    """Category 13: nproc-specific tests."""
    fw.log("\n=== Nproc-Specific Tests ===")

    # Basic output is a positive integer
    rc, out, err = fw.run_asm([])
    cpu_count = int(out.strip()) if out.strip().isdigit() else 0
    fw.report_result(rc == 0 and cpu_count >= 1, f"nproc: outputs valid CPU count ({cpu_count})")

    # --all flag
    rc, out, err = fw.run_asm(["--all"])
    all_count = int(out.strip()) if out.strip().isdigit() else 0
    fw.report_result(rc == 0 and all_count >= 1, f"nproc: --all outputs valid count ({all_count})")
    fw.report_result(all_count >= cpu_count, "nproc: --all >= default count")

    # --ignore=N
    rc, out, err = fw.run_asm(["--ignore=1"])
    ign1 = int(out.strip()) if out.strip().isdigit() else 0
    fw.report_result(rc == 0 and ign1 >= 1, f"nproc: --ignore=1 outputs {ign1}")

    # --ignore with large N should clamp to 1
    rc, out, err = fw.run_asm(["--ignore=99999"])
    fw.report_result(out.strip() == b"1", "nproc: --ignore=99999 clamps to 1")

    # --ignore=0 same as no flag
    rc, out, err = fw.run_asm(["--ignore=0"])
    ign0 = int(out.strip()) if out.strip().isdigit() else 0
    fw.report_result(ign0 == cpu_count, "nproc: --ignore=0 same as default")

    # Output format: just a number and newline
    rc, out, err = fw.run_asm([])
    fw.report_result(out == str(cpu_count).encode() + b"\n", "nproc: output format is NUMBER\\n")

    # No extra output on stderr
    rc, out, err = fw.run_asm([])
    fw.report_result(err == b"", "nproc: no stderr output on success")

    # Compare with GNU for various flags
    if os.path.exists(fw.gnu_path):
        for args in [[], ["--all"], ["--ignore=0"], ["--ignore=1"], ["--ignore=2"]]:
            rc_f, out_f, _ = fw.run_asm(args)
            rc_g, out_g, _ = fw.run_gnu(args)
            fw.report_result(out_f == out_g, f"nproc: matches GNU for {args or '(no args)'}")


if __name__ == '__main__':
    fw = SecurityTestFramework(config)
    fw.run_all(tool_specific_fn=tool_specific_tests)
