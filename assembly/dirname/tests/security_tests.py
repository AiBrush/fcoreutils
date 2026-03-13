#!/usr/bin/env python3
"""Security tests for fdirname — uses shared framework."""
import sys, os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', '..', 'tests'))
from security_framework import SecurityTestFramework

config = {
    'tool_name': 'dirname',
    'bin_name': 'fdirname',
    'gnu_path': '/usr/bin/dirname',
    'bss_size': 65536,
    'max_binary_size': 30000,
    'test_args': ['/usr/bin/sort'],
    'test_stdin': None,
    'timeout': 5,
}


def tool_specific_tests(fw):
    """13. Tool-specific: dirname — directory stripping behavior."""
    fw.log("\n=== Tool-Specific: dirname ===")

    # Core dirname behavior
    test_cases = [
        (["/usr/bin/sort"], b"/usr/bin\n"),
        (["include/stdio.h"], b"include\n"),
        (["/usr/bin/sort///"], b"/usr/bin\n"),
        (["/"], b"/\n"),
        (["sort"], b".\n"),
        (["."], b".\n"),
        ([".."], b".\n"),
        (["/sort"], b"/\n"),
        (["////"], b"/\n"),
        (["/usr/bin/"], b"/usr\n"),
        (["/usr/bin/sort", "/usr/bin/head"], b"/usr/bin\n/usr/bin\n"),
        (["///usr///bin///sort"], b"///usr///bin\n"),
        (["-"], b".\n"),
    ]

    for args, expected in test_cases:
        rc, out, err = fw.run_asm(args)
        fw.report_result(out == expected,
                         f"dirname: {' '.join(args)} -> {expected.rstrip().decode()}")

    # -z produces actual NUL byte terminator
    rc, out, err = fw.run_asm(["-z", "/usr/bin/sort"])
    fw.report_result(out == b"/usr/bin\x00", "dirname: -z produces NUL byte")
    fw.report_result(b"\n" not in out, "dirname: -z no trailing newline")

    # Extremely long path
    long_path = "/" + "/".join(["a" * 200] * 10)
    rc, out, err = fw.run_asm([long_path])
    expected_dir = "/" + "/".join(["a" * 200] * 9)
    fw.report_result(rc == 0 and out == expected_dir.encode() + b"\n",
                     "dirname: extremely long path -> no crash")

    # Path with embedded newlines
    if os.path.exists(fw.gnu_path):
        rc, out, err = fw.run_asm(["hello\nworld"])
        rc_g, out_g, _ = fw.run_gnu(["hello\nworld"])
        fw.report_result(out == out_g, "dirname: path with embedded newlines matches GNU")

    # Multiple consecutive slashes
    rc, out, err = fw.run_asm(["///usr///bin///sort"])
    fw.report_result(out == b"///usr///bin\n", "dirname: multiple consecutive slashes handled")

    # Simple paths
    rc, out, err = fw.run_asm(["a/b"])
    fw.report_result(out == b"a\n", "dirname: simple two-component path")

    rc, out, err = fw.run_asm(["a"])
    fw.report_result(out == b".\n", "dirname: single component -> dot")

    # // matches GNU
    if os.path.exists(fw.gnu_path):
        rc, out, err = fw.run_asm(["//"])
        rc_g, out_g, _ = fw.run_gnu(["//"])
        fw.report_result(out == out_g, "dirname: // matches GNU")

    # -z with multiple args
    rc, out, err = fw.run_asm(["-z", "/usr/bin/sort", "/usr/bin/head"])
    fw.report_result(b"\x00" in out, "dirname: -z with multiple args produces NUL")

    # Empty string
    if os.path.exists(fw.gnu_path):
        rc, out, err = fw.run_asm([""])
        rc_g, out_g, _ = fw.run_gnu([""])
        fw.report_result(out == out_g, "dirname: empty string matches GNU")

    # GNU comparison for various paths
    if os.path.exists(fw.gnu_path):
        for path in ["/usr/bin/sort", "include/stdio.h", "/", "sort", "/usr/bin/sort///", "."]:
            rc_f, out_f, _ = fw.run_asm([path])
            rc_g, out_g, _ = fw.run_gnu([path])
            fw.report_result(out_f == out_g and rc_f == rc_g,
                             f"dirname: matches GNU for '{path}'")

    # Deterministic output
    results = [fw.run_asm(["/usr/bin/sort"])[1] for _ in range(10)]
    fw.report_result(all(r == results[0] for r in results),
                     "dirname: 10 invocations same output")


if __name__ == '__main__':
    fw = SecurityTestFramework(config)
    fw.run_all(tool_specific_fn=tool_specific_tests)
