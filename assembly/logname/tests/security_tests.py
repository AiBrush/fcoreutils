#!/usr/bin/env python3
"""Security tests for flogname — uses shared framework."""
import sys, os, re
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', '..', 'tests'))
from security_framework import SecurityTestFramework

config = {
    'tool_name': 'logname',
    'bin_name': 'flogname',
    'gnu_path': '/usr/bin/logname',
    'bss_size': 4096,
    'max_binary_size': 30000,
    'test_args': [],
    'test_stdin': None,
}

def tool_specific_tests(fw):
    """13. Tool-specific: logname — prints login name."""
    fw.log("\n=== Tool-Specific: logname ===")

    rc, out, err = fw.run_asm([])

    if rc == 0:
        name = out.decode(errors="replace").strip()
        fw.report_result(len(name) > 0, f"logname: non-empty output '{name}'")
        fw.report_result(out.endswith(b"\n"), "logname: output ends with newline")

        valid = re.match(r'^[a-zA-Z0-9_][\-a-zA-Z0-9_.]*$', name)
        fw.report_result(valid is not None, f"logname: '{name}' is valid username format")

        current_user = os.environ.get("LOGNAME", os.environ.get("USER", ""))
        if current_user:
            fw.report_result(name == current_user,
                             f"logname: '{name}' matches $LOGNAME/USER '{current_user}'")

        if os.path.exists(fw.gnu_path):
            rc_g, out_g, _ = fw.run_gnu([])
            if rc_g == 0:
                fw.report_result(out == out_g, "logname: output matches GNU logname")

        fw.report_result(len(err) == 0, "logname: no stderr on success")
    else:
        fw.log(f"  [NOTE] logname exited {rc} (may not have a login terminal)")
        fw.report_result(rc == 1, "logname: non-tty exit code is 1")
        fw.report_result(len(err) > 0, "logname: prints error on failure")

    # Ignores stdin
    rc, out, err = fw.run_asm([], stdin_data=b"fake input\n")
    fw.report_result(rc < 128, "logname: ignores stdin")

    # -- separator
    rc, _, _ = fw.run_asm(["--"])
    fw.report_result(rc < 128, "logname: -- separator no crash")

if __name__ == '__main__':
    fw = SecurityTestFramework(config)
    fw.run_all(tool_specific_fn=tool_specific_tests)
