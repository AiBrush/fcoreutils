#!/usr/bin/env python3
"""security_tests.py -- Security & memory safety tests for fprintf (assembly printf).

Uses shared SecurityTestFramework.
fprintf formats and prints data according to a format string.
"""

import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', '..', 'tests'))
from security_framework import SecurityTestFramework

config = {
    'tool_name': 'printf',
    'bin_name': 'fprintf',
    'gnu_path': '/usr/bin/printf',
    'bss_size': 65536,
    'max_binary_size': 30000,
    'test_args': ['hello'],
    'test_stdin': None,
    'timeout': 5,
}


def tool_specific_tests(fw):
    """13. printf-specific tests: format string processing."""
    fw.log("\n=== 13. Tool-Specific: printf ===")

    # Basic string
    rc, out, _ = fw.run_asm(["hello"])
    fw.report_result(rc == 0 and out == b"hello", "printf: literal string")

    # %s format
    rc, out, _ = fw.run_asm(["%s", "world"])
    fw.report_result(rc == 0 and out == b"world", "printf: %s format")

    # %d format
    rc, out, _ = fw.run_asm(["%d", "42"])
    fw.report_result(rc == 0 and out == b"42", "printf: %d format")

    rc, out, _ = fw.run_asm(["%d", "-7"])
    fw.report_result(rc == 0 and out == b"-7", "printf: %d negative")

    # %u format
    rc, out, _ = fw.run_asm(["%u", "42"])
    fw.report_result(rc == 0 and out == b"42", "printf: %u format")

    # %o format
    rc, out, _ = fw.run_asm(["%o", "8"])
    fw.report_result(rc == 0 and out == b"10", "printf: %o format")

    # %x format
    rc, out, _ = fw.run_asm(["%x", "255"])
    fw.report_result(rc == 0 and out == b"ff", "printf: %x format")

    # %X format
    rc, out, _ = fw.run_asm(["%X", "255"])
    fw.report_result(rc == 0 and out == b"FF", "printf: %X format")

    # %c format
    rc, out, _ = fw.run_asm(["%c", "A"])
    fw.report_result(rc == 0 and out == b"A", "printf: %c format")

    # %% literal
    rc, out, _ = fw.run_asm(["100%%"])
    fw.report_result(rc == 0 and out == b"100%", "printf: %% literal")

    # Escape sequences
    rc, out, _ = fw.run_asm(["a\\nb"])
    fw.report_result(rc == 0 and out == b"a\nb", "printf: \\n escape")

    rc, out, _ = fw.run_asm(["a\\tb"])
    fw.report_result(rc == 0 and out == b"a\tb", "printf: \\t escape")

    # Argument recycling
    rc, out, _ = fw.run_asm(["%s\\n", "a", "b", "c"])
    fw.report_result(rc == 0 and out == b"a\nb\nc\n", "printf: argument recycling")

    # Character value with quote prefix
    rc, out, _ = fw.run_asm(["%d", "'A"])
    fw.report_result(rc == 0 and out == b"65", "printf: char value 'A = 65")

    # Escape sequence produces newline
    rc, out, _ = fw.run_asm(["hello\\n"])
    fw.report_result(out == b"hello\n", "printf: \\n produces newline")

    # GNU comparison
    if os.path.exists(fw.gnu_path):
        for args in [["hello"], ["%s", "test"], ["%d", "42"],
                     ["%o", "8"], ["%x", "255"]]:
            rc_f, out_f, _ = fw.run_asm(args)
            rc_g, out_g, _ = fw.run_gnu(args)
            label = " ".join(args[:2])
            fw.report_result(out_f == out_g,
                             f"printf: '{label}' matches GNU")


if __name__ == '__main__':
    fw = SecurityTestFramework(config)
    fw.run_all(tool_specific_fn=tool_specific_tests)
