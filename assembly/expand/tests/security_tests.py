#!/usr/bin/env python3
"""Security tests for fexpand — uses shared framework."""
import sys, os, tempfile
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', '..', 'tests'))
from security_framework import SecurityTestFramework

config = {
    'tool_name': 'expand',
    'bin_name': 'fexpand',
    'gnu_path': '/usr/bin/expand',
    'bss_size': 65536,
    'max_binary_size': 100000,
    'test_args': [],
    'test_stdin': b"\thello\n\tworld\n",
    'timeout': 5,
}

def tool_specific_tests(fw):
    """13. Tool-specific: expand tab expansion tests."""
    fw.log("\n=== Expand-Specific Tests ===")

    # Basic tab expansion (default 8 spaces)
    data = b"\thello\n"
    rc_a, out_a, _ = fw.run_asm([], stdin_data=data)
    rc_g, out_g, _ = fw.run_gnu([], stdin_data=data)
    fw.report_result(out_a == out_g, "expand: basic tab expansion matches GNU")
    fw.report_result(b"\t" not in out_a, "expand: tabs removed from output")

    # Default 8-space tab stops
    data = b"\thello\n"
    rc_a, out_a, _ = fw.run_asm([], stdin_data=data)
    fw.report_result(out_a == b"        hello\n", "expand: default 8-space tab stop")

    # Tab at different column positions
    data = b"ab\tcd\n"
    rc_a, out_a, _ = fw.run_asm([], stdin_data=data)
    rc_g, out_g, _ = fw.run_gnu([], stdin_data=data)
    fw.report_result(out_a == out_g, "expand: tab at col 2 matches GNU")

    # Multiple tabs
    data = b"\t\thello\n"
    rc_a, out_a, _ = fw.run_asm([], stdin_data=data)
    rc_g, out_g, _ = fw.run_gnu([], stdin_data=data)
    fw.report_result(out_a == out_g, "expand: double tab matches GNU")

    # Tab after text at various positions
    data = b"a\tb\tc\n"
    rc_a, out_a, _ = fw.run_asm([], stdin_data=data)
    rc_g, out_g, _ = fw.run_gnu([], stdin_data=data)
    fw.report_result(out_a == out_g, "expand: tabs at mixed positions matches GNU")

    # -t N custom tab stop
    data = b"\thello\n"
    rc_a, out_a, _ = fw.run_asm(["-t", "4"], stdin_data=data)
    rc_g, out_g, _ = fw.run_gnu(["-t", "4"], stdin_data=data)
    fw.report_result(out_a == out_g, "expand: -t 4 matches GNU")
    fw.report_result(out_a == b"    hello\n", "expand: -t 4 gives 4 spaces")

    # -t 2
    data = b"\thello\n"
    rc_a, out_a, _ = fw.run_asm(["-t", "2"], stdin_data=data)
    rc_g, out_g, _ = fw.run_gnu(["-t", "2"], stdin_data=data)
    fw.report_result(out_a == out_g, "expand: -t 2 matches GNU")

    # -t 1 (every column)
    data = b"\thello\n"
    rc_a, out_a, _ = fw.run_asm(["-t", "1"], stdin_data=data)
    rc_g, out_g, _ = fw.run_gnu(["-t", "1"], stdin_data=data)
    fw.report_result(out_a == out_g, "expand: -t 1 matches GNU")

    # -t 16 (wide tab stops)
    data = b"\thello\n"
    rc_a, out_a, _ = fw.run_asm(["-t", "16"], stdin_data=data)
    rc_g, out_g, _ = fw.run_gnu(["-t", "16"], stdin_data=data)
    fw.report_result(out_a == out_g, "expand: -t 16 matches GNU")

    # -t list (comma-separated tab stops)
    data = b"\t\t\thello\n"
    rc_a, out_a, _ = fw.run_asm(["-t", "4,8,12"], stdin_data=data)
    rc_g, out_g, _ = fw.run_gnu(["-t", "4,8,12"], stdin_data=data)
    fw.report_result(out_a == out_g, "expand: -t 4,8,12 (list) matches GNU")

    # -i (initial tabs only -- tabs after non-blank not expanded)
    data = b"\thello\tworld\n"
    rc_a, out_a, _ = fw.run_asm(["-i"], stdin_data=data)
    rc_g, out_g, _ = fw.run_gnu(["-i"], stdin_data=data)
    fw.report_result(out_a == out_g, "expand: -i (initial only) matches GNU")

    # -i with leading tabs then text then tab
    data = b"\t\thello\tworld\n"
    rc_a, out_a, _ = fw.run_asm(["-i"], stdin_data=data)
    rc_g, out_g, _ = fw.run_gnu(["-i"], stdin_data=data)
    fw.report_result(out_a == out_g, "expand: -i multiple leading tabs matches GNU")

    # No tabs in input -- passthrough
    data = b"hello world\n"
    rc_a, out_a, _ = fw.run_asm([], stdin_data=data)
    rc_g, out_g, _ = fw.run_gnu([], stdin_data=data)
    fw.report_result(out_a == out_g, "expand: no-tab passthrough matches GNU")
    fw.report_result(out_a == data, "expand: no-tab input unchanged")

    # Empty input
    rc_a, out_a, _ = fw.run_asm([], stdin_data=b"")
    rc_g, out_g, _ = fw.run_gnu([], stdin_data=b"")
    fw.report_result(out_a == out_g, "expand: empty input matches GNU")

    # Only newlines
    data = b"\n\n\n"
    rc_a, out_a, _ = fw.run_asm([], stdin_data=data)
    rc_g, out_g, _ = fw.run_gnu([], stdin_data=data)
    fw.report_result(out_a == out_g, "expand: only newlines matches GNU")

    # Only tabs
    data = b"\t\t\t\n"
    rc_a, out_a, _ = fw.run_asm([], stdin_data=data)
    rc_g, out_g, _ = fw.run_gnu([], stdin_data=data)
    fw.report_result(out_a == out_g, "expand: only tabs matches GNU")

    # Multiple lines with tabs
    data = b"\thello\n\tworld\n\tfoo\n"
    rc_a, out_a, _ = fw.run_asm([], stdin_data=data)
    rc_g, out_g, _ = fw.run_gnu([], stdin_data=data)
    fw.report_result(out_a == out_g, "expand: multiple lines matches GNU")

    # Stdin processing
    data = b"\talpha\n\tbeta\n\tgamma\n"
    rc_a, out_a, _ = fw.run_asm([], stdin_data=data)
    rc_g, out_g, _ = fw.run_gnu([], stdin_data=data)
    fw.report_result(out_a == out_g, "expand: stdin processing matches GNU")

    # File argument
    with tempfile.NamedTemporaryFile(mode='wb', suffix='.txt', delete=False) as f:
        f.write(b"\tfile line 1\n\tfile line 2\n\tfile line 3\n")
        tmpfile = f.name
    try:
        rc_a, out_a, _ = fw.run_asm([tmpfile])
        rc_g, out_g, _ = fw.run_gnu([tmpfile])
        fw.report_result(out_a == out_g, "expand: file argument matches GNU")
    finally:
        os.unlink(tmpfile)

    # Multiple file arguments
    with tempfile.NamedTemporaryFile(mode='wb', suffix='.txt', delete=False) as f1:
        f1.write(b"\talpha\n")
        tmpfile1 = f1.name
    with tempfile.NamedTemporaryFile(mode='wb', suffix='.txt', delete=False) as f2:
        f2.write(b"\tbeta\n")
        tmpfile2 = f2.name
    try:
        rc_a, out_a, _ = fw.run_asm([tmpfile1, tmpfile2])
        rc_g, out_g, _ = fw.run_gnu([tmpfile1, tmpfile2])
        fw.report_result(out_a == out_g, "expand: multiple files matches GNU")
    finally:
        os.unlink(tmpfile1)
        os.unlink(tmpfile2)

    # Nonexistent file
    rc_a, _, err_a = fw.run_asm(["/nonexistent/file.txt"])
    fw.report_result(rc_a != 0, "expand: nonexistent file returns nonzero")

    # Binary data with tabs
    data = bytes(range(256)).replace(b"\n", b"X") + b"\n"
    rc_a, out_a, _ = fw.run_asm([], stdin_data=data)
    rc_g, out_g, _ = fw.run_gnu([], stdin_data=data)
    fw.report_result(out_a == out_g, "expand: binary data with tabs matches GNU")

    # CRLF with tabs
    data = b"\thello\r\n\tworld\r\n"
    rc_a, out_a, _ = fw.run_asm([], stdin_data=data)
    rc_g, out_g, _ = fw.run_gnu([], stdin_data=data)
    fw.report_result(out_a == out_g, "expand: CRLF with tabs matches GNU")

    # Very long line with tabs
    data = b"A" * 100 + b"\t" + b"B" * 100 + b"\n"
    rc_a, out_a, _ = fw.run_asm([], stdin_data=data)
    rc_g, out_g, _ = fw.run_gnu([], stdin_data=data)
    fw.report_result(out_a == out_g, "expand: long line with tab matches GNU")

    # Many lines
    many = b"".join(f"\tline{i:06d}\n".encode() for i in range(1000))
    rc_a, out_a, _ = fw.run_asm([], stdin_data=many, timeout=10)
    rc_g, out_g, _ = fw.run_gnu([], stdin_data=many, timeout=10)
    fw.report_result(out_a == out_g, "expand: 1000 lines matches GNU")

    # Tab at end of line
    data = b"hello\t\n"
    rc_a, out_a, _ = fw.run_asm([], stdin_data=data)
    rc_g, out_g, _ = fw.run_gnu([], stdin_data=data)
    fw.report_result(out_a == out_g, "expand: tab at end of line matches GNU")

    # Only tab characters per line
    data = b"\t\t\t\t\n"
    rc_a, out_a, _ = fw.run_asm([], stdin_data=data)
    rc_g, out_g, _ = fw.run_gnu([], stdin_data=data)
    fw.report_result(out_a == out_g, "expand: multiple tabs per line matches GNU")

    # Special characters with tabs
    data = b"\t!@#$%^&*()\n\t[]{}<>|\\~`\n"
    rc_a, out_a, _ = fw.run_asm([], stdin_data=data)
    rc_g, out_g, _ = fw.run_gnu([], stdin_data=data)
    fw.report_result(out_a == out_g, "expand: special characters matches GNU")

    # Single line no newline
    data = b"\thello"
    rc_a, out_a, _ = fw.run_asm([], stdin_data=data)
    rc_g, out_g, _ = fw.run_gnu([], stdin_data=data)
    fw.report_result(out_a == out_g, "expand: no trailing newline matches GNU")

    # Combined: -i -t 4
    data = b"\t\thello\tworld\n"
    rc_a, out_a, _ = fw.run_asm(["-i", "-t", "4"], stdin_data=data)
    rc_g, out_g, _ = fw.run_gnu(["-i", "-t", "4"], stdin_data=data)
    fw.report_result(out_a == out_g, "expand: combined -i -t 4 matches GNU")

    # --help/--version
    rc_a, out_a, _ = fw.run_asm(["--help"])
    fw.report_result(rc_a == 0 and len(out_a) > 0, "expand: --help works")

    rc_a, out_a, _ = fw.run_asm(["--version"])
    fw.report_result(rc_a == 0 and len(out_a) > 0, "expand: --version works")

if __name__ == '__main__':
    fw = SecurityTestFramework(config)
    fw.run_all(tool_specific_fn=tool_specific_tests)
