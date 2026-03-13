#!/usr/bin/env python3
"""security_tests.py -- Security & memory safety tests for fcat."""

import os
import sys
import tempfile
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', '..', 'tests'))
from security_framework import SecurityTestFramework

config = {
    'tool_name': 'cat',
    'bin_name': 'fcat',
    'gnu_path': '/usr/bin/cat',
    'bss_size': 131072,
    'max_binary_size': 100000,
    'test_args': [],
    'test_stdin': b'hello\nworld\n',
    'timeout': 5,
}


def tool_specific_tests(fw):
    """13. Tool-specific: cat tests."""
    fw.log("\n=== Tool-Specific: cat ===")

    # --- Stdin passthrough ---
    rc_a, out_a, _ = fw.run_asm([], stdin_data=b"hello\n")
    rc_g, out_g, _ = fw.run_gnu([], stdin_data=b"hello\n")
    fw.report_result(out_a == out_g, "cat: stdin passthrough matches GNU")
    fw.report_result(out_a == b"hello\n", "cat: stdin passthrough correct")

    # --- Empty stdin ---
    rc_a, out_a, _ = fw.run_asm([], stdin_data=b"")
    rc_g, out_g, _ = fw.run_gnu([], stdin_data=b"")
    fw.report_result(out_a == out_g, "cat: empty stdin matches GNU")
    fw.report_result(out_a == b"", "cat: empty stdin produces no output")

    # --- Multiple lines via stdin ---
    data = b"line1\nline2\nline3\n"
    rc_a, out_a, _ = fw.run_asm([], stdin_data=data)
    rc_g, out_g, _ = fw.run_gnu([], stdin_data=data)
    fw.report_result(out_a == out_g, "cat: multiple lines matches GNU")

    # --- File reading ---
    with tempfile.NamedTemporaryFile(mode='wb', suffix='.txt', delete=False) as f:
        f.write(b"file content\nsecond line\n")
        tmpfile = f.name
    try:
        rc_a, out_a, _ = fw.run_asm([tmpfile])
        rc_g, out_g, _ = fw.run_gnu([tmpfile])
        fw.report_result(out_a == out_g, "cat: file reading matches GNU")
        fw.report_result(out_a == b"file content\nsecond line\n", "cat: file content correct")
    finally:
        os.unlink(tmpfile)

    # --- Multiple files ---
    files = []
    try:
        for i in range(3):
            with tempfile.NamedTemporaryFile(mode='wb', suffix='.txt', delete=False) as f:
                f.write(f"file{i}\n".encode())
                files.append(f.name)
        rc_a, out_a, _ = fw.run_asm(files)
        rc_g, out_g, _ = fw.run_gnu(files)
        fw.report_result(out_a == out_g, "cat: multiple files matches GNU")
        fw.report_result(out_a == b"file0\nfile1\nfile2\n", "cat: multiple files concatenated")
    finally:
        for f in files:
            os.unlink(f)

    # --- Binary data passthrough ---
    binary_data = bytes(range(256))
    rc_a, out_a, _ = fw.run_asm([], stdin_data=binary_data)
    rc_g, out_g, _ = fw.run_gnu([], stdin_data=binary_data)
    fw.report_result(out_a == out_g, "cat: binary data passthrough matches GNU")

    # --- -n (number all lines) ---
    data = b"alpha\nbeta\ngamma\n"
    rc_a, out_a, _ = fw.run_asm(["-n"], stdin_data=data)
    rc_g, out_g, _ = fw.run_gnu(["-n"], stdin_data=data)
    fw.report_result(out_a == out_g, "cat: -n number lines matches GNU")

    # --- -b (number non-blank lines) ---
    data = b"alpha\n\nbeta\n\ngamma\n"
    rc_a, out_a, _ = fw.run_asm(["-b"], stdin_data=data)
    rc_g, out_g, _ = fw.run_gnu(["-b"], stdin_data=data)
    fw.report_result(out_a == out_g, "cat: -b number non-blank matches GNU")

    # --- -s (squeeze blank lines) ---
    data = b"line1\n\n\n\nline2\n\n\nline3\n"
    rc_a, out_a, _ = fw.run_asm(["-s"], stdin_data=data)
    rc_g, out_g, _ = fw.run_gnu(["-s"], stdin_data=data)
    fw.report_result(out_a == out_g, "cat: -s squeeze blank matches GNU")

    # --- -E (show ends) ---
    data = b"hello\nworld\n"
    rc_a, out_a, _ = fw.run_asm(["-E"], stdin_data=data)
    rc_g, out_g, _ = fw.run_gnu(["-E"], stdin_data=data)
    fw.report_result(out_a == out_g, "cat: -E show ends matches GNU")

    # --- -T (show tabs) ---
    data = b"no\ttab\there\n"
    rc_a, out_a, _ = fw.run_asm(["-T"], stdin_data=data)
    rc_g, out_g, _ = fw.run_gnu(["-T"], stdin_data=data)
    fw.report_result(out_a == out_g, "cat: -T show tabs matches GNU")

    # --- -v (show non-printing) ---
    data = b"\x01\x02\x03\x7f\n"
    rc_a, out_a, _ = fw.run_asm(["-v"], stdin_data=data)
    rc_g, out_g, _ = fw.run_gnu(["-v"], stdin_data=data)
    fw.report_result(out_a == out_g, "cat: -v show non-printing matches GNU")

    # --- -A (= -vET) ---
    data = b"\thello\x01\n"
    rc_a, out_a, _ = fw.run_asm(["-A"], stdin_data=data)
    rc_g, out_g, _ = fw.run_gnu(["-A"], stdin_data=data)
    fw.report_result(out_a == out_g, "cat: -A (show-all) matches GNU")

    # --- Combined flags -n -s ---
    data = b"line1\n\n\n\nline2\n"
    rc_a, out_a, _ = fw.run_asm(["-ns"], stdin_data=data)
    rc_g, out_g, _ = fw.run_gnu(["-ns"], stdin_data=data)
    fw.report_result(out_a == out_g, "cat: -ns combined matches GNU")

    # --- /dev/null ---
    rc_a, out_a, _ = fw.run_asm(["/dev/null"])
    rc_g, out_g, _ = fw.run_gnu(["/dev/null"])
    fw.report_result(out_a == out_g, "cat: /dev/null produces no output")
    fw.report_result(rc_a == 0, "cat: /dev/null exits 0")

    # --- Nonexistent file ---
    rc_a, _, _ = fw.run_asm(["/nonexistent/file/path"])
    rc_g, _, _ = fw.run_gnu(["/nonexistent/file/path"])
    fw.report_result(rc_a != 0, "cat: nonexistent file returns nonzero")
    fw.report_result(rc_a == rc_g, "cat: nonexistent file exit code matches GNU")

    # --- --help ---
    rc_a, out_a, _ = fw.run_asm(["--help"])
    fw.report_result(rc_a == 0 and len(out_a) > 0, "cat: --help works")

    # --- --version ---
    rc_a, out_a, _ = fw.run_asm(["--version"])
    fw.report_result(rc_a == 0 and len(out_a) > 0, "cat: --version works")


if __name__ == '__main__':
    fw = SecurityTestFramework(config)
    fw.run_all(tool_specific_fn=tool_specific_tests)
