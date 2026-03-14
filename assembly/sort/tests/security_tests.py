#!/usr/bin/env python3
"""Security tests for fsort — uses shared framework."""
import sys, os, random, tempfile
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', '..', 'tests'))
from security_framework import SecurityTestFramework

config = {
    'tool_name': 'sort',
    'bin_name': 'fsort',
    'gnu_path': '/usr/bin/sort',
    'bss_size': 65536,
    'max_binary_size': 100000,
    'test_args': [],
    'test_stdin': b'cherry\napple\nbanana\n',
    'timeout': 5,
}

def tool_specific_tests(fw):
    """13. Tool-specific: sort tests."""
    fw.log("\n=== Sort-Specific Tests ===")

    # Basic sort
    data = b"cherry\napple\nbanana\n"
    rc_a, out_a, _ = fw.run_asm([], stdin_data=data)
    rc_g, out_g, _ = fw.run_gnu([], stdin_data=data)
    fw.report_result(out_a == out_g, "sort: basic sort matches GNU")
    fw.report_result(out_a == b"apple\nbanana\ncherry\n", "sort: basic sort correct output")

    # Already sorted
    data = b"apple\nbanana\ncherry\n"
    rc_a, out_a, _ = fw.run_asm([], stdin_data=data)
    rc_g, out_g, _ = fw.run_gnu([], stdin_data=data)
    fw.report_result(out_a == out_g, "sort: already sorted matches GNU")

    # Reverse sorted
    data = b"cherry\nbanana\napple\n"
    rc_a, out_a, _ = fw.run_asm([], stdin_data=data)
    rc_g, out_g, _ = fw.run_gnu([], stdin_data=data)
    fw.report_result(out_a == out_g, "sort: reverse order matches GNU")

    # Single line
    data = b"only\n"
    rc_a, out_a, _ = fw.run_asm([], stdin_data=data)
    rc_g, out_g, _ = fw.run_gnu([], stdin_data=data)
    fw.report_result(out_a == out_g, "sort: single line matches GNU")

    # Empty input
    rc_a, out_a, _ = fw.run_asm([], stdin_data=b"")
    rc_g, out_g, _ = fw.run_gnu([], stdin_data=b"")
    fw.report_result(out_a == out_g, "sort: empty input matches GNU")

    # -r (reverse)
    data = b"apple\ncherry\nbanana\n"
    rc_a, out_a, _ = fw.run_asm(["-r"], stdin_data=data)
    rc_g, out_g, _ = fw.run_gnu(["-r"], stdin_data=data)
    fw.report_result(out_a == out_g, "sort: -r (reverse) matches GNU")

    # -n (numeric)
    data = b"10\n2\n1\n20\n3\n"
    rc_a, out_a, _ = fw.run_asm(["-n"], stdin_data=data)
    rc_g, out_g, _ = fw.run_gnu(["-n"], stdin_data=data)
    fw.report_result(out_a == out_g, "sort: -n (numeric) matches GNU")

    # -n -r (numeric reverse)
    data = b"10\n2\n1\n20\n3\n"
    rc_a, out_a, _ = fw.run_asm(["-n", "-r"], stdin_data=data)
    rc_g, out_g, _ = fw.run_gnu(["-n", "-r"], stdin_data=data)
    fw.report_result(out_a == out_g, "sort: -n -r (numeric reverse) matches GNU")

    # -u (unique)
    data = b"apple\nbanana\napple\ncherry\nbanana\n"
    rc_a, out_a, _ = fw.run_asm(["-u"], stdin_data=data)
    rc_g, out_g, _ = fw.run_gnu(["-u"], stdin_data=data)
    fw.report_result(out_a == out_g, "sort: -u (unique) matches GNU")

    # -k (key field)
    data = b"3 cherry\n1 apple\n2 banana\n"
    rc_a, out_a, _ = fw.run_asm(["-k", "1,1"], stdin_data=data)
    rc_g, out_g, _ = fw.run_gnu(["-k", "1,1"], stdin_data=data)
    fw.report_result(out_a == out_g, "sort: -k 1,1 (key) matches GNU")

    # -k with numeric
    data = b"3 cherry\n1 apple\n2 banana\n"
    rc_a, out_a, _ = fw.run_asm(["-k", "1,1", "-n"], stdin_data=data)
    rc_g, out_g, _ = fw.run_gnu(["-k", "1,1", "-n"], stdin_data=data)
    fw.report_result(out_a == out_g, "sort: -k 1,1 -n (numeric key) matches GNU")

    # -t (delimiter)
    data = b"cherry:3\napple:1\nbanana:2\n"
    rc_a, out_a, _ = fw.run_asm(["-t", ":", "-k", "2,2", "-n"], stdin_data=data)
    rc_g, out_g, _ = fw.run_gnu(["-t", ":", "-k", "2,2", "-n"], stdin_data=data)
    fw.report_result(out_a == out_g, "sort: -t : -k 2,2 -n (delimiter) matches GNU")

    # -o (output file)
    with tempfile.NamedTemporaryFile(mode='wb', suffix='.txt', delete=False) as f:
        f.write(b"cherry\napple\nbanana\n")
        infile = f.name
    outfile_a = infile + ".out_a"
    outfile_g = infile + ".out_g"
    try:
        fw.run_asm(["-o", outfile_a, infile])
        fw.run_gnu(["-o", outfile_g, infile])
        if os.path.exists(outfile_a) and os.path.exists(outfile_g):
            content_a = open(outfile_a, 'rb').read()
            content_g = open(outfile_g, 'rb').read()
            fw.report_result(content_a == content_g, "sort: -o (output file) matches GNU")
        else:
            fw.report_result(False, "sort: -o (output file) matches GNU")
    finally:
        for path in [infile, outfile_a, outfile_g]:
            try: os.unlink(path)
            except: pass

    # -c (check sorted)
    data = b"apple\nbanana\ncherry\n"
    rc_a, _, _ = fw.run_asm(["-c"], stdin_data=data)
    rc_g, _, _ = fw.run_gnu(["-c"], stdin_data=data)
    fw.report_result(rc_a == rc_g, "sort: -c sorted input matches GNU exit code")

    # -c unsorted
    data = b"cherry\napple\nbanana\n"
    rc_a, _, _ = fw.run_asm(["-c"], stdin_data=data)
    rc_g, _, _ = fw.run_gnu(["-c"], stdin_data=data)
    fw.report_result(rc_a == rc_g, "sort: -c unsorted input matches GNU exit code")

    # File argument
    with tempfile.NamedTemporaryFile(mode='wb', suffix='.txt', delete=False) as f:
        f.write(b"cherry\napple\nbanana\n")
        tmpfile = f.name
    try:
        rc_a, out_a, _ = fw.run_asm([tmpfile])
        rc_g, out_g, _ = fw.run_gnu([tmpfile])
        fw.report_result(out_a == out_g, "sort: file argument matches GNU")
    finally:
        os.unlink(tmpfile)

    # Stdin via -
    data = b"cherry\napple\nbanana\n"
    rc_a, out_a, _ = fw.run_asm(["-"], stdin_data=data)
    rc_g, out_g, _ = fw.run_gnu(["-"], stdin_data=data)
    fw.report_result(out_a == out_g, "sort: stdin via '-' matches GNU")

    # Duplicate lines
    data = b"bbb\naaa\nbbb\naaa\nccc\n"
    rc_a, out_a, _ = fw.run_asm([], stdin_data=data)
    rc_g, out_g, _ = fw.run_gnu([], stdin_data=data)
    fw.report_result(out_a == out_g, "sort: duplicate lines matches GNU")

    # Case sensitivity
    data = b"Banana\napple\nCherry\n"
    rc_a, out_a, _ = fw.run_asm([], stdin_data=data)
    rc_g, out_g, _ = fw.run_gnu([], stdin_data=data)
    fw.report_result(out_a == out_g, "sort: case sensitivity matches GNU")

    # Spaces and tabs
    data = b"  cherry\n\tapple\n banana\n"
    rc_a, out_a, _ = fw.run_asm([], stdin_data=data)
    rc_g, out_g, _ = fw.run_gnu([], stdin_data=data)
    fw.report_result(out_a == out_g, "sort: spaces and tabs matches GNU")

    # Numbers with leading zeros
    data = b"010\n2\n001\n20\n"
    rc_a, out_a, _ = fw.run_asm(["-n"], stdin_data=data)
    rc_g, out_g, _ = fw.run_gnu(["-n"], stdin_data=data)
    fw.report_result(out_a == out_g, "sort: -n leading zeros matches GNU")

    # Negative numbers
    data = b"-5\n3\n-1\n10\n0\n"
    rc_a, out_a, _ = fw.run_asm(["-n"], stdin_data=data)
    rc_g, out_g, _ = fw.run_gnu(["-n"], stdin_data=data)
    fw.report_result(out_a == out_g, "sort: -n negative numbers matches GNU")

    # No trailing newline
    data = b"cherry\napple\nbanana"
    rc_a, out_a, _ = fw.run_asm([], stdin_data=data)
    rc_g, out_g, _ = fw.run_gnu([], stdin_data=data)
    fw.report_result(out_a == out_g, "sort: no trailing newline matches GNU")

    # Empty lines
    data = b"\n\nhello\n\nworld\n\n"
    rc_a, out_a, _ = fw.run_asm([], stdin_data=data)
    rc_g, out_g, _ = fw.run_gnu([], stdin_data=data)
    fw.report_result(out_a == out_g, "sort: empty lines matches GNU")

    # Large input (10K lines)
    lines = [f"line{i:06d}" for i in range(10000)]
    random.shuffle(lines)
    large = "\n".join(lines).encode() + b"\n"
    rc_a, out_a, _ = fw.run_asm([], stdin_data=large, timeout=30)
    rc_g, out_g, _ = fw.run_gnu([], stdin_data=large, timeout=30)
    fw.report_result(out_a == out_g, "sort: large input (10K lines) matches GNU")

    # Very long lines
    data = b"B" * 10000 + b"\n" + b"A" * 10000 + b"\n"
    rc_a, out_a, _ = fw.run_asm([], stdin_data=data)
    rc_g, out_g, _ = fw.run_gnu([], stdin_data=data)
    fw.report_result(out_a == out_g, "sort: very long lines (10KB each) matches GNU")

    # Special characters
    data = b"!@#$\n[]{}\n<>||\n~`\n"
    rc_a, out_a, _ = fw.run_asm([], stdin_data=data)
    rc_g, out_g, _ = fw.run_gnu([], stdin_data=data)
    fw.report_result(out_a == out_g, "sort: special characters matches GNU")

    # --help
    rc_a, out_a, _ = fw.run_asm(["--help"])
    fw.report_result(rc_a == 0 and len(out_a) > 0, "sort: --help works")

    # --version
    rc_a, out_a, _ = fw.run_asm(["--version"])
    fw.report_result(rc_a == 0 and len(out_a) > 0, "sort: --version works")

    # Numeric with non-numeric data
    data = b"abc\n10\n2\nxyz\n1\n"
    rc_a, out_a, _ = fw.run_asm(["-n"], stdin_data=data)
    rc_g, out_g, _ = fw.run_gnu(["-n"], stdin_data=data)
    fw.report_result(out_a == out_g, "sort: -n with non-numeric lines matches GNU")

    # -u -r combined
    data = b"cherry\napple\nbanana\napple\ncherry\n"
    rc_a, out_a, _ = fw.run_asm(["-u", "-r"], stdin_data=data)
    rc_g, out_g, _ = fw.run_gnu(["-u", "-r"], stdin_data=data)
    fw.report_result(out_a == out_g, "sort: -u -r combined matches GNU")

    # -k second field sort
    data = b"a 3\nb 1\nc 2\n"
    rc_a, out_a, _ = fw.run_asm(["-k", "2,2"], stdin_data=data)
    rc_g, out_g, _ = fw.run_gnu(["-k", "2,2"], stdin_data=data)
    fw.report_result(out_a == out_g, "sort: -k 2,2 (second field) matches GNU")

    # Binary-ish data in lines
    data = bytes(range(1, 10)) + b"\n" + bytes(range(11, 20)) + b"\n" + bytes(range(1, 5)) + b"\n"
    rc_a, out_a, _ = fw.run_asm([], stdin_data=data)
    rc_g, out_g, _ = fw.run_gnu([], stdin_data=data)
    fw.report_result(out_a == out_g, "sort: binary data lines matches GNU")

if __name__ == '__main__':
    fw = SecurityTestFramework(config)
    fw.run_all(tool_specific_fn=tool_specific_tests)
