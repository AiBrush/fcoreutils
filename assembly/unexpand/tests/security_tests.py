#!/usr/bin/env python3
"""security_tests.py -- Security & memory safety tests for funexpand (assembly unexpand).

Uses shared SecurityTestFramework.
funexpand converts spaces to tabs, matching GNU unexpand behavior.
"""

import os
import sys
import tempfile

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', '..', 'tests'))
from security_framework import SecurityTestFramework

config = {
    'tool_name': 'unexpand',
    'bin_name': 'funexpand',
    'gnu_path': '/usr/bin/unexpand',
    'bss_size': 65536,
    'max_binary_size': 100000,
    'test_args': [],
    'test_stdin': b"        hello\n        world\n",
    'timeout': 5,
}


def tool_specific_tests(fw):
    """13. unexpand-specific tests: space-to-tab conversion."""
    fw.log("\n=== 13. Tool-Specific: unexpand ===")

    # Basic unexpand — default converts initial spaces to tabs (8-space tab stops)
    data = b"        hello\n"
    rc_a, out_a, _ = fw.run_asm([], stdin_data=data)
    rc_g, out_g, _ = fw.run_gnu([], stdin_data=data)
    fw.report_result(out_a == out_g, "unexpand: basic unexpand matches GNU")
    fw.report_result(b"\t" in out_a, "unexpand: spaces converted to tab")

    # Default behavior: only initial (leading) spaces converted
    data = b"        hello        world\n"
    rc_a, out_a, _ = fw.run_asm([], stdin_data=data)
    rc_g, out_g, _ = fw.run_gnu([], stdin_data=data)
    fw.report_result(out_a == out_g, "unexpand: default initial-only matches GNU")

    # -a (convert all spaces, not just initial)
    data = b"        hello        world\n"
    rc_a, out_a, _ = fw.run_asm(["-a"], stdin_data=data)
    rc_g, out_g, _ = fw.run_gnu(["-a"], stdin_data=data)
    fw.report_result(out_a == out_g, "unexpand: -a (all spaces) matches GNU")

    # -t N custom tab stop
    data = b"    hello\n"
    rc_a, out_a, _ = fw.run_asm(["-t", "4"], stdin_data=data)
    rc_g, out_g, _ = fw.run_gnu(["-t", "4"], stdin_data=data)
    fw.report_result(out_a == out_g, "unexpand: -t 4 matches GNU")

    # -t 2
    data = b"  hello\n"
    rc_a, out_a, _ = fw.run_asm(["-t", "2"], stdin_data=data)
    rc_g, out_g, _ = fw.run_gnu(["-t", "2"], stdin_data=data)
    fw.report_result(out_a == out_g, "unexpand: -t 2 matches GNU")

    # -t 16 (wide tab stops)
    data = b"                hello\n"
    rc_a, out_a, _ = fw.run_asm(["-t", "16"], stdin_data=data)
    rc_g, out_g, _ = fw.run_gnu(["-t", "16"], stdin_data=data)
    fw.report_result(out_a == out_g, "unexpand: -t 16 matches GNU")

    # Fewer spaces than tab stop (should not convert)
    data = b"   hello\n"
    rc_a, out_a, _ = fw.run_asm([], stdin_data=data)
    rc_g, out_g, _ = fw.run_gnu([], stdin_data=data)
    fw.report_result(out_a == out_g, "unexpand: fewer spaces than tab stop matches GNU")

    # Exactly one tab stop worth of spaces
    data = b"        hello\n"
    rc_a, out_a, _ = fw.run_asm([], stdin_data=data)
    rc_g, out_g, _ = fw.run_gnu([], stdin_data=data)
    fw.report_result(out_a == out_g, "unexpand: exactly 8 spaces matches GNU")

    # Multiple tab stops
    data = b"                hello\n"
    rc_a, out_a, _ = fw.run_asm([], stdin_data=data)
    rc_g, out_g, _ = fw.run_gnu([], stdin_data=data)
    fw.report_result(out_a == out_g, "unexpand: 16 spaces (2 tabs) matches GNU")

    # --first-only (same as default, only initial spaces)
    data = b"        hello        world\n"
    rc_a, out_a, _ = fw.run_asm(["--first-only"], stdin_data=data)
    rc_g, out_g, _ = fw.run_gnu(["--first-only"], stdin_data=data)
    fw.report_result(out_a == out_g, "unexpand: --first-only matches GNU")

    # No spaces in input — passthrough
    data = b"hello world\n"
    rc_a, out_a, _ = fw.run_asm([], stdin_data=data)
    rc_g, out_g, _ = fw.run_gnu([], stdin_data=data)
    fw.report_result(out_a == out_g, "unexpand: no-convert passthrough matches GNU")

    # Input already has tabs — should pass through
    data = b"\thello\n"
    rc_a, out_a, _ = fw.run_asm([], stdin_data=data)
    rc_g, out_g, _ = fw.run_gnu([], stdin_data=data)
    fw.report_result(out_a == out_g, "unexpand: existing tabs passthrough matches GNU")

    # Empty input
    rc_a, out_a, _ = fw.run_asm([], stdin_data=b"")
    rc_g, out_g, _ = fw.run_gnu([], stdin_data=b"")
    fw.report_result(out_a == out_g, "unexpand: empty input matches GNU")

    # Only newlines
    data = b"\n\n\n"
    rc_a, out_a, _ = fw.run_asm([], stdin_data=data)
    rc_g, out_g, _ = fw.run_gnu([], stdin_data=data)
    fw.report_result(out_a == out_g, "unexpand: only newlines matches GNU")

    # Only spaces
    data = b"        \n"
    rc_a, out_a, _ = fw.run_asm([], stdin_data=data)
    rc_g, out_g, _ = fw.run_gnu([], stdin_data=data)
    fw.report_result(out_a == out_g, "unexpand: only spaces matches GNU")

    # Mixed content: spaces, tabs, text
    data = b"        \thello\n"
    rc_a, out_a, _ = fw.run_asm([], stdin_data=data)
    rc_g, out_g, _ = fw.run_gnu([], stdin_data=data)
    fw.report_result(out_a == out_g, "unexpand: mixed spaces/tabs matches GNU")

    # Multiple lines
    data = b"        hello\n        world\n        foo\n"
    rc_a, out_a, _ = fw.run_asm([], stdin_data=data)
    rc_g, out_g, _ = fw.run_gnu([], stdin_data=data)
    fw.report_result(out_a == out_g, "unexpand: multiple lines matches GNU")

    # File argument
    with tempfile.NamedTemporaryFile(mode='wb', suffix='.txt', delete=False) as f:
        f.write(b"        file line 1\n        file line 2\n        file line 3\n")
        tmpfile = f.name
    try:
        rc_a, out_a, _ = fw.run_asm([tmpfile])
        rc_g, out_g, _ = fw.run_gnu([tmpfile])
        fw.report_result(out_a == out_g, "unexpand: file argument matches GNU")
    finally:
        os.unlink(tmpfile)

    # Multiple file arguments
    with tempfile.NamedTemporaryFile(mode='wb', suffix='.txt', delete=False) as f1:
        f1.write(b"        alpha\n")
        tmpfile1 = f1.name
    with tempfile.NamedTemporaryFile(mode='wb', suffix='.txt', delete=False) as f2:
        f2.write(b"        beta\n")
        tmpfile2 = f2.name
    try:
        rc_a, out_a, _ = fw.run_asm([tmpfile1, tmpfile2])
        rc_g, out_g, _ = fw.run_gnu([tmpfile1, tmpfile2])
        fw.report_result(out_a == out_g, "unexpand: multiple files matches GNU")
    finally:
        os.unlink(tmpfile1)
        os.unlink(tmpfile2)

    # Nonexistent file
    rc_a, _, err_a = fw.run_asm(["/nonexistent/file.txt"])
    fw.report_result(rc_a != 0, "unexpand: nonexistent file returns nonzero")

    # Roundtrip: expand | unexpand should recover tabs
    data = b"\thello\n\tworld\n"
    rc1, expanded, _ = fw.run(["/usr/bin/expand"], stdin_data=data)
    rc_a, out_a, _ = fw.run_asm([], stdin_data=expanded)
    rc_g, out_g, _ = fw.run_gnu([], stdin_data=expanded)
    fw.report_result(out_a == out_g, "unexpand: expand|unexpand roundtrip matches GNU")

    # -a with tabs at various positions
    data = b"hello        world        foo\n"
    rc_a, out_a, _ = fw.run_asm(["-a"], stdin_data=data)
    rc_g, out_g, _ = fw.run_gnu(["-a"], stdin_data=data)
    fw.report_result(out_a == out_g, "unexpand: -a mid-line spaces matches GNU")

    # CRLF with spaces
    data = b"        hello\r\n        world\r\n"
    rc_a, out_a, _ = fw.run_asm([], stdin_data=data)
    rc_g, out_g, _ = fw.run_gnu([], stdin_data=data)
    fw.report_result(out_a == out_g, "unexpand: CRLF with spaces matches GNU")

    # Very long line with spaces
    data = b" " * 100 + b"hello" + b" " * 100 + b"world\n"
    rc_a, out_a, _ = fw.run_asm(["-a"], stdin_data=data)
    rc_g, out_g, _ = fw.run_gnu(["-a"], stdin_data=data)
    fw.report_result(out_a == out_g, "unexpand: long line with spaces matches GNU")

    # Many lines
    many = b"".join(f"        line{i:06d}\n".encode() for i in range(1000))
    rc_a, out_a, _ = fw.run_asm([], stdin_data=many, timeout=10)
    rc_g, out_g, _ = fw.run_gnu([], stdin_data=many, timeout=10)
    fw.report_result(out_a == out_g, "unexpand: 1000 lines matches GNU")

    # Special characters with leading spaces
    data = b"        !@#$%^&*()\n        []{}<>|\\~`\n"
    rc_a, out_a, _ = fw.run_asm([], stdin_data=data)
    rc_g, out_g, _ = fw.run_gnu([], stdin_data=data)
    fw.report_result(out_a == out_g, "unexpand: special characters matches GNU")

    # Single line no newline
    data = b"        hello"
    rc_a, out_a, _ = fw.run_asm([], stdin_data=data)
    rc_g, out_g, _ = fw.run_gnu([], stdin_data=data)
    fw.report_result(out_a == out_g, "unexpand: no trailing newline matches GNU")

    # Partial tab stop (7 spaces with 8-space tabs)
    data = b"       hello\n"
    rc_a, out_a, _ = fw.run_asm([], stdin_data=data)
    rc_g, out_g, _ = fw.run_gnu([], stdin_data=data)
    fw.report_result(out_a == out_g, "unexpand: 7 spaces (partial) matches GNU")

    # 9 spaces (1 tab + 1 space)
    data = b"         hello\n"
    rc_a, out_a, _ = fw.run_asm([], stdin_data=data)
    rc_g, out_g, _ = fw.run_gnu([], stdin_data=data)
    fw.report_result(out_a == out_g, "unexpand: 9 spaces matches GNU")

    # Combined: -a -t 4
    data = b"    hello    world\n"
    rc_a, out_a, _ = fw.run_asm(["-a", "-t", "4"], stdin_data=data)
    rc_g, out_g, _ = fw.run_gnu(["-a", "-t", "4"], stdin_data=data)
    fw.report_result(out_a == out_g, "unexpand: combined -a -t 4 matches GNU")

    # --help/--version
    rc_a, out_a, _ = fw.run_asm(["--help"])
    fw.report_result(rc_a == 0 and len(out_a) > 0, "unexpand: --help works")

    rc_a, out_a, _ = fw.run_asm(["--version"])
    fw.report_result(rc_a == 0 and len(out_a) > 0, "unexpand: --version works")


if __name__ == '__main__':
    fw = SecurityTestFramework(config)
    fw.run_all(tool_specific_fn=tool_specific_tests)
