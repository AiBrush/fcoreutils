#!/usr/bin/env python3
"""Security tests for fecho — uses shared framework."""
import sys, os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', '..', 'tests'))
from security_framework import SecurityTestFramework

config = {
    'tool_name': 'echo',
    'bin_name': 'fecho',
    'gnu_path': '/usr/bin/echo',
    'bss_size': 65536,
    'max_binary_size': 30000,
    'test_args': ['hello'],
    'test_stdin': None,
    'timeout': 5,
}


def _compare_with_gnu(fw, args, label=None):
    """Compare fecho output with GNU echo for the given args."""
    if not os.path.exists(fw.gnu_path):
        return
    rc_f, out_f, _ = fw.run_asm(args)
    rc_g, out_g, _ = fw.run_gnu(args)
    out_f_norm = out_f.replace(fw.bin_path.encode(), b"echo")
    out_g_norm = out_g.replace(fw.gnu_path.encode(), b"echo")
    ok = (out_f_norm == out_g_norm and rc_f == rc_g)
    lbl = label or f"compare: echo {' '.join(args[:3])}"
    fw.report_result(ok, lbl)


def tool_specific_tests(fw):
    """13. Tool-specific: echo — flags, escapes, arg handling."""
    fw.log("\n=== Tool-Specific: echo ===")

    # Basic output
    rc, out, _ = fw.run_asm([])
    fw.report_result(rc == 0, "echo: no args -> exit 0")
    fw.report_result(out == b"\n", "echo: no args -> just newline")

    rc, out, _ = fw.run_asm(["hello"])
    fw.report_result(out == b"hello\n", "echo: single arg")

    rc, out, _ = fw.run_asm(["hello", "world"])
    fw.report_result(out == b"hello world\n", "echo: multiple args joined by space")

    rc, out, _ = fw.run_asm(["a", "b", "c", "d", "e"])
    fw.report_result(out == b"a b c d e\n", "echo: 5 args joined by spaces")

    rc, out, _ = fw.run_asm([""])
    fw.report_result(out == b"\n", "echo: empty arg -> just newline")

    rc, out, _ = fw.run_asm(["", ""])
    fw.report_result(out == b" \n", "echo: two empty args -> space + newline")

    # -n flag (no trailing newline)
    rc, out, _ = fw.run_asm(["-n", "hello"])
    fw.report_result(out == b"hello", "echo: -n hello -> no trailing newline")

    rc, out, _ = fw.run_asm(["-n"])
    fw.report_result(out == b"", "echo: -n alone -> empty output")

    rc, out, _ = fw.run_asm(["-n", "a", "b"])
    fw.report_result(out == b"a b", "echo: -n a b -> 'a b' no newline")

    # -e flag (escape sequences)
    rc, out, _ = fw.run_asm(["-e", "hello\\nworld"])
    fw.report_result(out == b"hello\nworld\n", "echo: -e \\n -> newline")

    rc, out, _ = fw.run_asm(["-e", "hello\\tworld"])
    fw.report_result(out == b"hello\tworld\n", "echo: -e \\t -> tab")

    rc, out, _ = fw.run_asm(["-e", "hello\\\\world"])
    fw.report_result(out == b"hello\\world\n", "echo: -e \\\\\\\\ -> backslash")

    rc, out, _ = fw.run_asm(["-e", "\\a"])
    fw.report_result(out == b"\a\n", "echo: -e \\a -> bell")

    rc, out, _ = fw.run_asm(["-e", "\\b"])
    fw.report_result(out == b"\b\n", "echo: -e \\b -> backspace")

    rc, out, _ = fw.run_asm(["-e", "\\f"])
    fw.report_result(out == b"\f\n", "echo: -e \\f -> form feed")

    rc, out, _ = fw.run_asm(["-e", "\\r"])
    fw.report_result(out == b"\r\n", "echo: -e \\r -> carriage return")

    rc, out, _ = fw.run_asm(["-e", "\\v"])
    fw.report_result(out == b"\v\n", "echo: -e \\v -> vertical tab")

    # Octal escapes
    rc, out, _ = fw.run_asm(["-e", "\\0101"])
    fw.report_result(out == b"A\n", "echo: -e \\0101 -> 'A'")

    rc, out, _ = fw.run_asm(["-e", "\\0"])
    fw.report_result(b"\x00" in out or out == b"\n", "echo: -e \\0 -> NUL or empty")

    rc, out, _ = fw.run_asm(["-e", "\\0110\\0145\\0154\\0154\\0157"])
    fw.report_result(out == b"Hello\n", "echo: -e octal Hello")

    # Hex escapes
    rc, out, _ = fw.run_asm(["-e", "\\x41"])
    fw.report_result(out == b"A\n", "echo: -e \\x41 -> 'A'")

    rc, out, _ = fw.run_asm(["-e", "\\x48\\x65\\x6c\\x6c\\x6f"])
    fw.report_result(out == b"Hello\n", "echo: -e hex Hello")

    rc, out, _ = fw.run_asm(["-e", "\\xff"])
    fw.report_result(out[0:1] == b"\xff", "echo: -e \\xff -> byte 0xff")

    # \c (stop output)
    rc, out, _ = fw.run_asm(["-e", "hello\\cworld"])
    fw.report_result(out == b"hello", "echo: -e \\c -> stops output")

    # -E flag (disable escapes)
    rc, out, _ = fw.run_asm(["-E", "hello\\nworld"])
    fw.report_result(out == b"hello\\nworld\n", "echo: -E -> escapes NOT interpreted")

    # Combined flags
    rc, out, _ = fw.run_asm(["-ne", "hello\\nworld"])
    fw.report_result(out == b"hello\nworld", "echo: -ne -> escape + no trailing newline")

    rc, out, _ = fw.run_asm(["-en", "hello\\n"])
    fw.report_result(out == b"hello\n", "echo: -en -> same as -ne")

    rc, out, _ = fw.run_asm(["-nE", "hello\\n"])
    fw.report_result(out == b"hello\\n", "echo: -nE -> no newline, no escapes")

    # -- handling
    if os.path.exists(fw.gnu_path):
        _compare_with_gnu(fw, ["--", "-n"], "echo: vs GNU -- -- -n")

    # Flag-like args that aren't flags
    rc, out, _ = fw.run_asm(["-"])
    fw.report_result(b"-" in out, "echo: - -> printed")

    if os.path.exists(fw.gnu_path):
        _compare_with_gnu(fw, ["-abc"], "echo: vs GNU -- -abc")

    # Spaces
    rc, out, _ = fw.run_asm(["  hello  "])
    fw.report_result(out == b"  hello  \n", "echo: preserves internal spaces")

    # Stdin ignored
    rc, out, _ = fw.run([fw.bin_path, "hello"], stdin_data=b"stdin data\n")
    fw.report_result(out == b"hello\n", "echo: ignores stdin")

    # Lots of args
    args = [str(i) for i in range(100)]
    rc, out, _ = fw.run_asm(args)
    expected = " ".join(args) + "\n"
    fw.report_result(out.decode() == expected, "echo: 100 args joined correctly")

    # GNU comparison batch
    if os.path.exists(fw.gnu_path):
        test_cases = [
            ["hello"], ["hello", "world"], ["-n", "hello"],
            ["-e", "\\n"], ["-e", "\\t"], ["-e", "\\\\"],
            ["-e", "\\a"], ["-e", "\\b"], ["-e", "\\f"],
            ["-e", "\\r"], ["-e", "\\v"], ["-e", "\\0101"],
            ["-e", "\\x41"], ["-e", "\\c"], ["-e", "hello\\cworld"],
            ["-E", "\\n"], ["-ne", "hello"], ["-en", "hello"],
            ["-nE", "\\n"], ["-n", "-e", "hello"],
            [""], [" "], ["-n"], ["-e"], ["-E"],
            ["-eee"], ["-nnn"], ["-neE"],
        ]
        for tc in test_cases:
            _compare_with_gnu(fw, tc)

    # Multiple -n flags
    if os.path.exists(fw.gnu_path):
        _compare_with_gnu(fw, ["-n", "-n", "hello"], "echo: vs GNU -- -n -n hello")

    # Trailing newline verification
    rc, out, _ = fw.run_asm(["test"])
    fw.report_result(out[-1:] == b"\n", "echo: trailing newline present")

    rc, out, _ = fw.run_asm(["-n", "test"])
    fw.report_result(out[-1:] != b"\n" or len(out) == 0, "echo: -n removes trailing newline")

    # Deterministic
    results = [fw.run_asm(["hello"])[1] for _ in range(10)]
    fw.report_result(all(r == results[0] for r in results), "echo: 10 invocations same output")


if __name__ == '__main__':
    fw = SecurityTestFramework(config)
    fw.run_all(tool_specific_fn=tool_specific_tests)
