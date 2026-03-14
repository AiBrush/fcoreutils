#!/usr/bin/env python3
"""security_tests.py -- Security & memory safety tests for funiq (assembly uniq).

Uses shared SecurityTestFramework.
funiq filters adjacent matching lines from input, matching GNU uniq behavior.
"""

import os
import sys
import tempfile
import random

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', '..', 'tests'))
from security_framework import SecurityTestFramework

config = {
    'tool_name': 'uniq',
    'bin_name': 'funiq',
    'gnu_path': '/usr/bin/uniq',
    'bss_size': 65536,
    'max_binary_size': 100000,
    'test_args': [],
    'test_stdin': b"hello\nhello\nworld\n",
    'timeout': 5,
}


def tool_specific_tests(fw):
    """13. uniq-specific tests: duplicate line filtering."""
    fw.log("\n=== 13. Tool-Specific: uniq ===")

    # Basic dedup
    data = b"aaa\naaa\nbbb\nccc\nccc\n"
    rc_a, out_a, _ = fw.run_asm([], stdin_data=data)
    rc_g, out_g, _ = fw.run_gnu([], stdin_data=data)
    fw.report_result(out_a == out_g, "uniq: basic dedup matches GNU")
    fw.report_result(out_a == b"aaa\nbbb\nccc\n", "uniq: basic dedup correct output")

    # No duplicates
    data = b"aaa\nbbb\nccc\n"
    rc_a, out_a, _ = fw.run_asm([], stdin_data=data)
    rc_g, out_g, _ = fw.run_gnu([], stdin_data=data)
    fw.report_result(out_a == out_g, "uniq: no duplicates matches GNU")

    # All duplicates
    data = b"aaa\naaa\naaa\n"
    rc_a, out_a, _ = fw.run_asm([], stdin_data=data)
    rc_g, out_g, _ = fw.run_gnu([], stdin_data=data)
    fw.report_result(out_a == out_g, "uniq: all duplicates matches GNU")

    # -c (count)
    data = b"aaa\naaa\nbbb\nccc\nccc\nccc\n"
    rc_a, out_a, _ = fw.run_asm(["-c"], stdin_data=data)
    rc_g, out_g, _ = fw.run_gnu(["-c"], stdin_data=data)
    fw.report_result(out_a == out_g, "uniq: -c (count) matches GNU")

    # -d (duplicates only)
    data = b"aaa\naaa\nbbb\nccc\nccc\n"
    rc_a, out_a, _ = fw.run_asm(["-d"], stdin_data=data)
    rc_g, out_g, _ = fw.run_gnu(["-d"], stdin_data=data)
    fw.report_result(out_a == out_g, "uniq: -d (duplicates only) matches GNU")

    # -u (unique only)
    data = b"aaa\naaa\nbbb\nccc\nccc\n"
    rc_a, out_a, _ = fw.run_asm(["-u"], stdin_data=data)
    rc_g, out_g, _ = fw.run_gnu(["-u"], stdin_data=data)
    fw.report_result(out_a == out_g, "uniq: -u (unique only) matches GNU")

    # -i (case insensitive)
    data = b"Hello\nhello\nHELLO\nWorld\n"
    rc_a, out_a, _ = fw.run_asm(["-i"], stdin_data=data)
    rc_g, out_g, _ = fw.run_gnu(["-i"], stdin_data=data)
    fw.report_result(out_a == out_g, "uniq: -i (case insensitive) matches GNU")

    # -f N (skip fields)
    data = b"field1 aaa\nfield2 aaa\nfield1 bbb\n"
    rc_a, out_a, _ = fw.run_asm(["-f", "1"], stdin_data=data)
    rc_g, out_g, _ = fw.run_gnu(["-f", "1"], stdin_data=data)
    fw.report_result(out_a == out_g, "uniq: -f 1 (skip fields) matches GNU")

    # -s N (skip chars)
    data = b"XXXaaa\nYYYaaa\nZZZbbb\n"
    rc_a, out_a, _ = fw.run_asm(["-s", "3"], stdin_data=data)
    rc_g, out_g, _ = fw.run_gnu(["-s", "3"], stdin_data=data)
    fw.report_result(out_a == out_g, "uniq: -s 3 (skip chars) matches GNU")

    # -w N (check chars)
    data = b"aaaxxx\naaayyy\nbbbxxx\n"
    rc_a, out_a, _ = fw.run_asm(["-w", "3"], stdin_data=data)
    rc_g, out_g, _ = fw.run_gnu(["-w", "3"], stdin_data=data)
    fw.report_result(out_a == out_g, "uniq: -w 3 (check chars) matches GNU")

    # -c -d combined
    data = b"aaa\naaa\nbbb\nccc\nccc\n"
    rc_a, out_a, _ = fw.run_asm(["-c", "-d"], stdin_data=data)
    rc_g, out_g, _ = fw.run_gnu(["-c", "-d"], stdin_data=data)
    fw.report_result(out_a == out_g, "uniq: -c -d combined matches GNU")

    # -c -u combined
    data = b"aaa\naaa\nbbb\nccc\nccc\n"
    rc_a, out_a, _ = fw.run_asm(["-c", "-u"], stdin_data=data)
    rc_g, out_g, _ = fw.run_gnu(["-c", "-u"], stdin_data=data)
    fw.report_result(out_a == out_g, "uniq: -c -u combined matches GNU")

    # Empty input
    rc_a, out_a, _ = fw.run_asm([], stdin_data=b"")
    rc_g, out_g, _ = fw.run_gnu([], stdin_data=b"")
    fw.report_result(out_a == out_g, "uniq: empty input matches GNU")

    # Single line
    data = b"only\n"
    rc_a, out_a, _ = fw.run_asm([], stdin_data=data)
    rc_g, out_g, _ = fw.run_gnu([], stdin_data=data)
    fw.report_result(out_a == out_g, "uniq: single line matches GNU")

    # Single newline
    rc_a, out_a, _ = fw.run_asm([], stdin_data=b"\n")
    rc_g, out_g, _ = fw.run_gnu([], stdin_data=b"\n")
    fw.report_result(out_a == out_g, "uniq: single newline matches GNU")

    # No trailing newline
    data = b"hello\nhello"
    rc_a, out_a, _ = fw.run_asm([], stdin_data=data)
    rc_g, out_g, _ = fw.run_gnu([], stdin_data=data)
    fw.report_result(out_a == out_g, "uniq: no trailing newline matches GNU")

    # Input file argument
    with tempfile.NamedTemporaryFile(mode='wb', suffix='.txt', delete=False) as f:
        f.write(b"aaa\naaa\nbbb\nccc\nccc\n")
        tmpfile = f.name
    try:
        rc_a, out_a, _ = fw.run_asm([tmpfile])
        rc_g, out_g, _ = fw.run_gnu([tmpfile])
        fw.report_result(out_a == out_g, "uniq: input file argument matches GNU")
    finally:
        os.unlink(tmpfile)

    # Output file argument
    with tempfile.NamedTemporaryFile(mode='wb', suffix='.txt', delete=False) as f:
        f.write(b"aaa\naaa\nbbb\nccc\nccc\n")
        infile = f.name
    outfile_a = infile + ".out_a"
    outfile_g = infile + ".out_g"
    try:
        fw.run_asm([infile, outfile_a])
        fw.run_gnu([infile, outfile_g])
        if os.path.exists(outfile_a) and os.path.exists(outfile_g):
            content_a = open(outfile_a, 'rb').read()
            content_g = open(outfile_g, 'rb').read()
            fw.report_result(content_a == content_g, "uniq: output file argument matches GNU")
        else:
            fw.report_result(False, "uniq: output file argument matches GNU")
    finally:
        for path in [infile, outfile_a, outfile_g]:
            try:
                os.unlink(path)
            except Exception:
                pass

    # Many duplicate runs
    data = b"".join(f"line{i}\n".encode() * random.randint(1, 5) for i in range(100))
    rc_a, out_a, _ = fw.run_asm([], stdin_data=data)
    rc_g, out_g, _ = fw.run_gnu([], stdin_data=data)
    fw.report_result(out_a == out_g, "uniq: many duplicate runs matches GNU")

    # Large input (10K lines with duplicates)
    large = b"".join(f"line{i // 3:06d}\n".encode() for i in range(10000))
    rc_a, out_a, _ = fw.run_asm([], stdin_data=large, timeout=10)
    rc_g, out_g, _ = fw.run_gnu([], stdin_data=large, timeout=10)
    fw.report_result(out_a == out_g, "uniq: large input (10K lines) matches GNU")

    # Spaces and tabs
    data = b"  hello  \n  hello  \n\tworld\t\n\tworld\t\n"
    rc_a, out_a, _ = fw.run_asm([], stdin_data=data)
    rc_g, out_g, _ = fw.run_gnu([], stdin_data=data)
    fw.report_result(out_a == out_g, "uniq: spaces and tabs matches GNU")

    # Empty lines as duplicates
    data = b"\n\n\nhello\n\n\n"
    rc_a, out_a, _ = fw.run_asm([], stdin_data=data)
    rc_g, out_g, _ = fw.run_gnu([], stdin_data=data)
    fw.report_result(out_a == out_g, "uniq: empty lines as duplicates matches GNU")

    # --help
    rc_a, out_a, _ = fw.run_asm(["--help"])
    fw.report_result(rc_a == 0 and len(out_a) > 0, "uniq: --help works")

    # --version
    rc_a, out_a, _ = fw.run_asm(["--version"])
    fw.report_result(rc_a == 0 and len(out_a) > 0, "uniq: --version works")

    # -f and -s combined
    data = b"X field aaa\nY field aaa\nZ field bbb\n"
    rc_a, out_a, _ = fw.run_asm(["-f", "1", "-s", "1"], stdin_data=data)
    rc_g, out_g, _ = fw.run_gnu(["-f", "1", "-s", "1"], stdin_data=data)
    fw.report_result(out_a == out_g, "uniq: -f 1 -s 1 combined matches GNU")

    # -i -c combined
    data = b"Hello\nhello\nWorld\nworld\nWORLD\n"
    rc_a, out_a, _ = fw.run_asm(["-i", "-c"], stdin_data=data)
    rc_g, out_g, _ = fw.run_gnu(["-i", "-c"], stdin_data=data)
    fw.report_result(out_a == out_g, "uniq: -i -c combined matches GNU")

    # Binary data per line
    binary_data = bytes(range(1, 10)) + b"\n" + bytes(range(1, 10)) + b"\n" + bytes(range(11, 20)) + b"\n"
    rc_a, out_a, _ = fw.run_asm([], stdin_data=binary_data)
    rc_g, out_g, _ = fw.run_gnu([], stdin_data=binary_data)
    fw.report_result(out_a == out_g, "uniq: binary data lines matches GNU")


if __name__ == '__main__':
    fw = SecurityTestFramework(config)
    fw.run_all(tool_specific_fn=tool_specific_tests)
