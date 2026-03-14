#!/usr/bin/env python3
"""Security tests for fshuf — uses shared framework."""
import sys, os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', '..', 'tests'))
from security_framework import SecurityTestFramework
import tempfile

config = {
    'tool_name': 'shuf',
    'bin_name': 'fshuf',
    'gnu_path': '/usr/bin/shuf',
    'bss_size': 65536,
    'max_binary_size': 100000,
    'test_args': [],
    'test_stdin': b'cherry\napple\nbanana\n',
    'timeout': 5,
}

def tool_specific_tests(fw):
    """13. Tool-specific: shuf tests."""
    fw.log("\n=== Shuf-Specific Tests ===")

    # Basic shuffle preserves elements
    data = b"cherry\napple\nbanana\n"
    rc, out, _ = fw.run_asm([], stdin_data=data)
    out_sorted = sorted(out.strip().split(b"\n"))
    exp_sorted = sorted(data.strip().split(b"\n"))
    fw.report_result(out_sorted == exp_sorted, "shuf: basic shuffle preserves elements")
    fw.report_result(rc == 0, "shuf: basic shuffle exit 0")

    # Echo mode
    rc, out, _ = fw.run_asm(["-e", "x", "y", "z"])
    out_sorted = sorted(out.strip().split(b"\n"))
    fw.report_result(out_sorted == [b"x", b"y", b"z"], "shuf: -e preserves elements")

    # Input range
    rc, out, _ = fw.run_asm(["-i", "1-10"])
    nums = sorted(int(x) for x in out.strip().split(b"\n"))
    fw.report_result(nums == list(range(1, 11)), "shuf: -i 1-10 all elements")

    # Head count
    rc, out, _ = fw.run_asm(["-n", "3", "-i", "1-100"])
    lines = out.strip().split(b"\n")
    fw.report_result(len(lines) == 3, "shuf: -n 3 produces 3 lines")

    # Repeat mode
    rc, out, _ = fw.run_asm(["-r", "-n", "20", "-e", "a", "b"])
    lines = out.strip().split(b"\n")
    fw.report_result(len(lines) == 20, "shuf: -r -n 20 produces 20 lines")
    fw.report_result(all(x in (b"a", b"b") for x in lines), "shuf: -r elements in set")

    # Zero-terminated
    rc, out, _ = fw.run_asm(["-z", "-e", "a", "b", "c"])
    items = sorted(out.split(b"\x00"))
    items = [x for x in items if x]
    fw.report_result(sorted(items) == [b"a", b"b", b"c"], "shuf: -z null termination")

    # Output file
    with tempfile.NamedTemporaryFile(delete=False) as f:
        tmpfile = f.name
    try:
        rc, _, _ = fw.run_asm(["-i", "1-5", "-o", tmpfile])
        with open(tmpfile, "r") as f:
            content = f.read()
        nums = sorted(int(x) for x in content.strip().split("\n"))
        fw.report_result(nums == [1, 2, 3, 4, 5], "shuf: -o output file correct")
    finally:
        os.unlink(tmpfile)

    # Empty echo
    rc, out, _ = fw.run_asm(["-e"])
    fw.report_result(rc == 0 and out == b"", "shuf: -e no args = empty output")

    # Empty stdin
    rc, out, _ = fw.run_asm([], stdin_data=b"")
    fw.report_result(rc == 0 and out == b"", "shuf: empty stdin = empty output")

    # Multiple -n uses minimum
    rc, out, _ = fw.run_asm(["-n", "5", "-n", "2", "-i", "1-100"])
    lines = out.strip().split(b"\n")
    fw.report_result(len(lines) == 2, "shuf: multiple -n uses minimum")

    # Randomness: at least 2 different outputs in 10 runs
    outputs = set()
    for _ in range(10):
        _, out, _ = fw.run_asm(["-i", "1-10"])
        outputs.add(out)
    fw.report_result(len(outputs) >= 2, f"shuf: randomness ({len(outputs)} unique outputs in 10 runs)")

    # Large range
    rc, out, _ = fw.run_asm(["-i", "1-10000"], timeout=10)
    nums = sorted(int(x) for x in out.strip().split(b"\n"))
    fw.report_result(nums == list(range(1, 10001)), "shuf: -i 1-10000 all elements")

    # File input
    with tempfile.NamedTemporaryFile(mode="w", suffix=".txt", delete=False) as f:
        for i in range(100):
            f.write(f"line{i:04d}\n")
        tmpfile = f.name
    try:
        rc, out, _ = fw.run_asm([tmpfile])
        lines = sorted(out.strip().split(b"\n"))
        expected = sorted(f"line{i:04d}".encode() for i in range(100))
        fw.report_result(lines == expected, "shuf: file input preserves all lines")
    finally:
        os.unlink(tmpfile)

if __name__ == '__main__':
    fw = SecurityTestFramework(config)
    fw.run_all(tool_specific_fn=tool_specific_tests)
