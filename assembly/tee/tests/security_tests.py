#!/usr/bin/env python3
"""Security tests for ftee — uses shared framework."""
import sys, os, tempfile
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', '..', 'tests'))
from security_framework import SecurityTestFramework

config = {
    'tool_name': 'tee',
    'bin_name': 'ftee',
    'gnu_path': '/usr/bin/tee',
    'bss_size': 131072,
    'max_binary_size': 30000,
    'test_args': [],
    'test_stdin': b'hello world\n',
}

def tool_specific_tests(fw):
    """13. Tool-specific: tee — stdin multiplexing tests."""
    fw.log("\n=== Tool-Specific: tee ===")

    # Basic stdin -> stdout passthrough
    rc, out, err = fw.run_asm([], stdin_data=b"hello world\n")
    fw.report_result(out == b"hello world\n", "tee: stdin passes through to stdout")

    # Write to file
    with tempfile.NamedTemporaryFile(delete=False) as tf:
        tmp = tf.name
    try:
        rc, out, err = fw.run_asm([tmp], stdin_data=b"file content\n")
        with open(tmp, 'rb') as f:
            content = f.read()
        fw.report_result(content == b"file content\n", "tee: file output matches stdin")
        fw.report_result(out == b"file content\n", "tee: stdout also gets content")
    finally:
        os.unlink(tmp)

    # Append mode
    with tempfile.NamedTemporaryFile(delete=False, mode='w') as tf:
        tf.write("first\n")
        tmp = tf.name
    try:
        fw.run_asm(["-a", tmp], stdin_data=b"second\n")
        with open(tmp, 'rb') as f:
            content = f.read()
        fw.report_result(content == b"first\nsecond\n", "tee: -a append mode works")
    finally:
        os.unlink(tmp)

    # Multiple output files
    with tempfile.NamedTemporaryFile(delete=False) as tf1, \
         tempfile.NamedTemporaryFile(delete=False) as tf2:
        tmp1, tmp2 = tf1.name, tf2.name
    try:
        fw.run_asm([tmp1, tmp2], stdin_data=b"multi\n")
        with open(tmp1, 'rb') as f:
            c1 = f.read()
        with open(tmp2, 'rb') as f:
            c2 = f.read()
        fw.report_result(c1 == b"multi\n" and c2 == b"multi\n",
                         "tee: multiple output files all get content")
    finally:
        os.unlink(tmp1)
        os.unlink(tmp2)

    # Empty input
    rc, out, err = fw.run_asm([], stdin_data=b"")
    fw.report_result(out == b"" and rc == 0, "tee: empty input -> empty output")

    # Binary data passthrough
    data = bytes(range(256))
    rc, out, err = fw.run_asm([], stdin_data=data)
    fw.report_result(out == data, "tee: binary data passthrough")

    # Large data
    data = b"X" * 100000
    rc, out, err = fw.run_asm([], stdin_data=data)
    fw.report_result(out == data, "tee: 100KB passthrough")

    # GNU comparison
    if os.path.exists(fw.gnu_path):
        for data in [b"hello\n", b"multi\nline\n", b"", b"no newline"]:
            rc_f, out_f, _ = fw.run_asm([], stdin_data=data)
            rc_g, out_g, _ = fw.run_gnu([], stdin_data=data)
            fw.report_result(out_f == out_g and rc_f == rc_g,
                             f"tee: matches GNU for {repr(data[:20])}")

if __name__ == '__main__':
    fw = SecurityTestFramework(config)
    fw.run_all(tool_specific_fn=tool_specific_tests)
