#!/usr/bin/env python3
"""Security tests for fls — uses shared framework."""
import sys, os, tempfile
from pathlib import Path
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', '..', 'tests'))
from security_framework import SecurityTestFramework

config = {
    'tool_name': 'ls',
    'bin_name': 'fls',
    'gnu_path': '/usr/bin/ls',
    'bss_size': 65536,
    'max_binary_size': 100000,
    'test_args': ['/tmp'],
    'test_stdin': None,
    'timeout': 10,
}

def tool_specific_tests(fw):
    """13. Tool-specific: ls — directory listing behavior."""
    fw.log("\n=== Tool-Specific: ls ===")

    with tempfile.TemporaryDirectory() as td:
        for name in ["aaa", "bbb", "ccc", ".hidden"]:
            Path(td, name).touch()
        os.mkdir(os.path.join(td, "subdir"))

        # Basic listing
        rc, out, _ = fw.run_asm([td])
        names = out.decode().strip().split("\n")
        fw.report_result("aaa" in names and "bbb" in names, "ls: basic listing includes files")
        fw.report_result(".hidden" not in names, "ls: hidden files excluded by default")

        # -a shows hidden
        rc, out, _ = fw.run_asm(["-a", td])
        names = out.decode().strip().split("\n")
        fw.report_result(".hidden" in names, "ls: -a shows hidden files")
        fw.report_result("." in names, "ls: -a shows .")
        fw.report_result(".." in names, "ls: -a shows ..")

        # -A shows hidden but not . and ..
        rc, out, _ = fw.run_asm(["-A", td])
        names = out.decode().strip().split("\n")
        fw.report_result(".hidden" in names, "ls: -A shows hidden files")
        fw.report_result("." not in names, "ls: -A hides .")
        fw.report_result(".." not in names, "ls: -A hides ..")

        # -d flag
        rc, out, _ = fw.run_asm(["-d", td])
        fw.report_result(out.decode().strip() == td, "ls: -d prints directory name")

        # -l flag
        rc, out, _ = fw.run_asm(["-l", td])
        fw.report_result(rc == 0, "ls: -l exit code 0")
        lines = out.decode().strip().split("\n")
        fw.report_result(lines[0].startswith("total"), "ls: -l starts with total line")

        # -r flag (reverse)
        rc, out_fwd, _ = fw.run_asm(["-1", td])
        rc, out_rev, _ = fw.run_asm(["-1r", td])
        fwd = out_fwd.decode().strip().split("\n")
        rev = out_rev.decode().strip().split("\n")
        fw.report_result(fwd == list(reversed(rev)), "ls: -r reverses order")

        # Nonexistent
        rc, out, err = fw.run_asm([os.path.join(td, "nonexistent")])
        fw.report_result(rc != 0, "ls: nonexistent -> error exit")

    # Empty directory
    with tempfile.TemporaryDirectory() as td:
        rc, out, _ = fw.run_asm([td])
        fw.report_result(rc == 0 and out.strip() == b"", "ls: empty dir -> empty output")

    # Compare with GNU
    if os.path.exists(fw.gnu_path):
        rc_f, out_f, _ = fw.run_asm(["/tmp"])
        rc_g, out_g, _ = fw.run_gnu(["/tmp"])
        names_f = sorted(out_f.decode().strip().split("\n"))
        names_g = sorted(out_g.decode().strip().split("\n"))
        fw.report_result(names_f == names_g, "ls: output matches GNU ls names for /tmp")

if __name__ == '__main__':
    fw = SecurityTestFramework(config)
    fw.run_all(tool_specific_fn=tool_specific_tests)
