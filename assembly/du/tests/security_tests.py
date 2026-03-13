#!/usr/bin/env python3
"""Security tests for fdu — uses shared framework."""
import sys, os, tempfile
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', '..', 'tests'))
from security_framework import SecurityTestFramework
from pathlib import Path


def tool_specific_tests(fw):
    """13. Tool-specific: du — disk usage reporting."""
    fw.log("\n=== Tool-Specific: du ===")

    with tempfile.TemporaryDirectory() as td:
        os.makedirs(os.path.join(td, "sub"))
        Path(td, "file.txt").write_bytes(b"x" * 1024)
        Path(td, "sub", "nested.txt").write_bytes(b"y" * 2048)

        # -s summary
        rc, out, _ = fw.run_asm(["-s", td])
        fw.report_result(rc == 0, "du: -s works")
        lines = out.decode().strip().split("\n")
        fw.report_result(len(lines) == 1, "du: -s produces one line")
        parts = lines[0].split("\t")
        fw.report_result(len(parts) == 2, "du: tab-separated size and path")

        # -a shows files
        rc, out, _ = fw.run_asm(["-a", td])
        fw.report_result(b"file.txt" in out, "du: -a shows files")

        # Nonexistent
        rc, out, err = fw.run_asm([os.path.join(td, "nope")])
        fw.report_result(rc != 0, "du: nonexistent -> error")

        # Empty dir
        edir = os.path.join(td, "empty")
        os.makedirs(edir)
        rc, out, _ = fw.run_asm(["-s", edir])
        fw.report_result(rc == 0, "du: empty dir -> exit 0")

        # Deterministic
        outputs = []
        for _ in range(5):
            rc, out, _ = fw.run_asm(["-s", td])
            outputs.append(out)
        fw.report_result(all(o == outputs[0] for o in outputs), "du: deterministic output")


if __name__ == '__main__':
    # du needs a temp dir for default test args
    _td = tempfile.mkdtemp()
    try:
        config = {
            'tool_name': 'du',
            'bin_name': 'fdu',
            'gnu_path': '/usr/bin/du',
            'bss_size': 65536,
            'max_binary_size': 100000,
            'test_args': ['-s', _td],
            'test_stdin': None,
            'timeout': 10,
        }
        fw = SecurityTestFramework(config)
        fw.run_all(tool_specific_fn=tool_specific_tests)
    finally:
        import shutil
        shutil.rmtree(_td, ignore_errors=True)
