#!/usr/bin/env python3
"""security_tests.py — Security & memory safety tests for fdate.

Uses shared SecurityTestFramework with tool-specific date tests.
"""

import os
import sys
import time
import datetime

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', '..', 'tests'))
from security_framework import SecurityTestFramework

config = {
    'tool_name': 'date',
    'bin_name': 'fdate',
    'gnu_path': '/usr/bin/date',
    'bss_size': 65536,
    'max_binary_size': 30000,
    'test_args': [],
    'test_stdin': None,
    'timeout': 10,
}


def tool_specific_tests(fw):
    """Category 13: date-specific tests."""
    fw.log("\n=== 13. Tool-Specific: date ===")

    now = datetime.datetime.utcnow()

    # Default output should contain current year
    rc, out, _ = fw.run_asm([])
    fw.report_result(rc == 0, "date: default -> exit 0")
    out_str = out.decode().strip()
    fw.report_result(str(now.year) in out_str, f"date: output contains current year ({now.year})")
    fw.report_result("UTC" in out_str, "date: output contains 'UTC'")

    # +%Y should match
    rc, out, _ = fw.run_asm(["+%Y"])
    fw.report_result(out.decode().strip() == str(now.year), f"date: +%Y = {now.year}")

    # +%m should match
    rc, out, _ = fw.run_asm(["+%m"])
    fw.report_result(out.decode().strip() == f"{now.month:02d}", f"date: +%m = {now.month:02d}")

    # +%s epoch
    rc, out, _ = fw.run_asm(["+%s"])
    epoch = int(out.decode().strip())
    real_epoch = int(time.time())
    fw.report_result(abs(epoch - real_epoch) <= 2, f"date: +%s epoch within 2s ({epoch} vs {real_epoch})")

    # -R format check
    rc, out, _ = fw.run_asm(["-R"])
    fw.report_result("+0000" in out.decode(), "date: -R contains +0000")

    # -I format check
    rc, out, _ = fw.run_asm(["-I"])
    iso = out.decode().strip()
    fw.report_result(len(iso) == 10 and iso[4] == '-' and iso[7] == '-', f"date: -I is YYYY-MM-DD ({iso})")


if __name__ == '__main__':
    fw = SecurityTestFramework(config)
    fw.run_all(tool_specific_fn=tool_specific_tests)
