#!/usr/bin/env python3
"""Security tests for fdircolors — uses shared framework."""
import sys, os
from shutil import which
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', '..', 'tests'))
from security_framework import SecurityTestFramework

config = {
    'tool_name': 'dircolors',
    'bin_name': 'fdircolors',
    'gnu_path': '/usr/bin/dircolors',
    'bss_size': 65536,
    'max_binary_size': 30000,
    'test_args': ['-b'],
    'test_stdin': None,
    'timeout': 5,
}

def tool_specific_tests(fw):
    """13. Tool-specific: dircolors LS_COLORS tests."""
    fw.log("\n=== Dircolors-Specific Tests ===")
    gnu_path = which("dircolors")

    # Bourne shell output
    rc, out, _ = fw.run_asm(["-b"])
    out_text = out.decode(errors="replace")
    fw.report_result(rc == 0 and "LS_COLORS=" in out_text,
                     "dircolors: -b produces LS_COLORS=")
    fw.report_result("export LS_COLORS" in out_text,
                     "dircolors: -b contains export LS_COLORS")

    # C shell output
    rc, out, _ = fw.run_asm(["-c"])
    out_text = out.decode(errors="replace")
    fw.report_result(rc == 0 and "setenv LS_COLORS" in out_text,
                     "dircolors: -c produces setenv LS_COLORS")

    # Print database
    rc, out, _ = fw.run_asm(["-p"])
    out_text = out.decode(errors="replace")
    fw.report_result(rc == 0 and len(out) > 100,
                     "dircolors: -p produces database output")
    for keyword in ["DIR", "LINK", "EXEC"]:
        fw.report_result(keyword in out_text,
                         f"dircolors: -p contains {keyword}")

    # Key LS_COLORS entries
    rc, out, _ = fw.run_asm(["-b"])
    out_text = out.decode(errors="replace")
    for entry in ["di=", "ln=", "ex="]:
        fw.report_result(entry in out_text,
                         f"dircolors: LS_COLORS contains {entry}")

    # GNU comparison
    if gnu_path:
        rc_f, out_f, _ = fw.run_asm(["-b"])
        rc_g, out_g, _ = fw.run_gnu(["-b"])
        fw.report_result(rc_f == rc_g, "dircolors: -b exit code matches GNU")

        rc_f, out_f, _ = fw.run_asm(["-c"])
        rc_g, out_g, _ = fw.run_gnu(["-c"])
        fw.report_result(rc_f == rc_g, "dircolors: -c exit code matches GNU")

if __name__ == '__main__':
    fw = SecurityTestFramework(config)
    fw.run_all(tool_specific_fn=tool_specific_tests)
