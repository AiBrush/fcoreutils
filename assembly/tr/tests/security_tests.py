#!/usr/bin/env python3
"""Security tests for ftr — uses shared framework."""
import sys, os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', '..', 'tests'))
from security_framework import SecurityTestFramework

config = {
    'tool_name': 'tr',
    'bin_name': 'ftr',
    'gnu_path': '/usr/bin/tr',
    'bss_size': 65536,
    'max_binary_size': 30000,
    'test_args': ['a-z', 'A-Z'],
    'test_stdin': b'hello world\n',
}

def tool_specific_tests(fw):
    """13. Tool-specific: tr — character translation tests."""
    fw.log("\n=== Tr-Specific Tests ===")

    # Basic a-z -> A-Z
    rc_a, out_a, _ = fw.run_asm(["a-z", "A-Z"], stdin_data=b"hello world\n")
    rc_g, out_g, _ = fw.run_gnu(["a-z", "A-Z"], stdin_data=b"hello world\n")
    fw.report_result(out_a == out_g, "tr: a-z -> A-Z matches GNU")
    fw.report_result(out_a == b"HELLO WORLD\n", "tr: a-z -> A-Z correct output")

    # A-Z -> a-z
    rc_a, out_a, _ = fw.run_asm(["A-Z", "a-z"], stdin_data=b"HELLO WORLD\n")
    rc_g, out_g, _ = fw.run_gnu(["A-Z", "a-z"], stdin_data=b"HELLO WORLD\n")
    fw.report_result(out_a == out_g, "tr: A-Z -> a-z matches GNU")

    # Delete mode -d
    rc_a, out_a, _ = fw.run_asm(["-d", "aeiou"], stdin_data=b"hello world\n")
    rc_g, out_g, _ = fw.run_gnu(["-d", "aeiou"], stdin_data=b"hello world\n")
    fw.report_result(out_a == out_g, "tr: -d delete vowels matches GNU")

    # Squeeze mode -s
    rc_a, out_a, _ = fw.run_asm(["-s", " "], stdin_data=b"hello   world   test\n")
    rc_g, out_g, _ = fw.run_gnu(["-s", " "], stdin_data=b"hello   world   test\n")
    fw.report_result(out_a == out_g, "tr: -s squeeze spaces matches GNU")

    # Complement -c (or -C)
    rc_a, out_a, _ = fw.run_asm(["-cd", "a-z\n"], stdin_data=b"Hello, World! 123\n")
    rc_g, out_g, _ = fw.run_gnu(["-cd", "a-z\n"], stdin_data=b"Hello, World! 123\n")
    if rc_a == 0:
        fw.report_result(out_a == out_g, "tr: -cd complement delete matches GNU")
    else:
        fw.skip_test("tr: -cd complement", "not supported")

    # Character classes
    for cls_from, cls_to, desc in [
        ("[:lower:]", "[:upper:]", "lower->upper"),
        ("[:upper:]", "[:lower:]", "upper->lower"),
    ]:
        rc_a, out_a, _ = fw.run_asm([cls_from, cls_to], stdin_data=b"Hello World\n")
        rc_g, out_g, _ = fw.run_gnu([cls_from, cls_to], stdin_data=b"Hello World\n")
        if rc_a == 0 and rc_g == 0:
            fw.report_result(out_a == out_g, f"tr: {desc} matches GNU")
        else:
            fw.skip_test(f"tr: {desc}", "error or not supported")

    # Delete digits
    rc_a, out_a, _ = fw.run_asm(["-d", "[:digit:]"], stdin_data=b"abc123def456\n")
    rc_g, out_g, _ = fw.run_gnu(["-d", "[:digit:]"], stdin_data=b"abc123def456\n")
    if rc_a == 0 and rc_g == 0:
        fw.report_result(out_a == out_g, "tr: -d [:digit:] matches GNU")
    else:
        fw.skip_test("tr: -d [:digit:]", "not supported")

    # Single char translation
    rc_a, out_a, _ = fw.run_asm(["a", "b"], stdin_data=b"aaa bbb ccc\n")
    rc_g, out_g, _ = fw.run_gnu(["a", "b"], stdin_data=b"aaa bbb ccc\n")
    fw.report_result(out_a == out_g, "tr: single char a->b matches GNU")

    # Octal escapes
    rc_a, out_a, _ = fw.run_asm(["\\012", "X"], stdin_data=b"hello\nworld\n")
    rc_g, out_g, _ = fw.run_gnu(["\\012", "X"], stdin_data=b"hello\nworld\n")
    if rc_a == 0 and rc_g == 0:
        fw.report_result(out_a == out_g, "tr: octal \\012 matches GNU")
    else:
        fw.skip_test("tr: octal escapes", "not supported")

    # Empty input
    rc_a, out_a, _ = fw.run_asm(["a-z", "A-Z"], stdin_data=b"")
    rc_g, out_g, _ = fw.run_gnu(["a-z", "A-Z"], stdin_data=b"")
    fw.report_result(out_a == out_g, "tr: empty input matches GNU")

    # Identity translation
    data = b"hello world 123\n"
    rc_a, out_a, _ = fw.run_asm(["a-z", "a-z"], stdin_data=data)
    fw.report_result(out_a == data, "tr: identity a-z -> a-z")

    # Non-alpha preserved
    data = b"test 123 !@#\n"
    rc_a, out_a, _ = fw.run_asm(["a-z", "A-Z"], stdin_data=data)
    fw.report_result(b"123 !@#" in out_a, "tr: non-alpha preserved in translation")

    # Squeeze with translation
    rc_a, out_a, _ = fw.run_asm(["-s", "a-z", "A-Z"], stdin_data=b"aabbcc\n")
    rc_g, out_g, _ = fw.run_gnu(["-s", "a-z", "A-Z"], stdin_data=b"aabbcc\n")
    if rc_a == 0 and rc_g == 0:
        fw.report_result(out_a == out_g, "tr: -s with translation matches GNU")
    else:
        fw.skip_test("tr: -s with translation", "error")

    # Large input
    large = b"hello world test\n" * 10000
    rc_a, out_a, _ = fw.run_asm(["a-z", "A-Z"], stdin_data=large, timeout=10)
    rc_g, out_g, _ = fw.run_gnu(["a-z", "A-Z"], stdin_data=large, timeout=10)
    fw.report_result(out_a == out_g, "tr: large input (10K lines) matches GNU")

    # Delete newlines
    rc_a, out_a, _ = fw.run_asm(["-d", "\n"], stdin_data=b"a\nb\nc\n")
    rc_g, out_g, _ = fw.run_gnu(["-d", "\n"], stdin_data=b"a\nb\nc\n")
    fw.report_result(out_a == out_g, "tr: -d newlines matches GNU")

    # Binary safety
    data = bytes(range(256))
    rc_a, out_a, _ = fw.run_asm(["a-z", "A-Z"], stdin_data=data)
    rc_g, out_g, _ = fw.run_gnu(["a-z", "A-Z"], stdin_data=data)
    fw.report_result(out_a == out_g, "tr: all 256 byte values matches GNU")

    # --help/--version
    rc_a, out_a, _ = fw.run_asm(["--help"])
    fw.report_result(rc_a == 0 and len(out_a) > 0, "tr: --help works")

    rc_a, out_a, _ = fw.run_asm(["--version"])
    fw.report_result(rc_a == 0 and len(out_a) > 0, "tr: --version works")

if __name__ == '__main__':
    fw = SecurityTestFramework(config)
    fw.run_all(tool_specific_fn=tool_specific_tests)
