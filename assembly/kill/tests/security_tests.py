#!/usr/bin/env python3
"""Security tests for fkill — uses shared framework."""
import sys, os, tempfile, subprocess
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', '..', 'tests'))
from security_framework import SecurityTestFramework

config = {
    'tool_name': 'kill',
    'bin_name': 'fkill',
    'gnu_path': '/usr/bin/kill',
    'bss_size': 4096,
    'max_binary_size': 30000,
    'test_args': ['-l'],
    'test_stdin': None,
}

def tool_specific_tests(fw):
    """13. Tool-specific: kill — signal sending and listing."""
    fw.log("\n=== Tool-Specific: kill ===")

    # -l lists signals
    rc, out, err = fw.run_asm(['-l'])
    fw.report_result(rc == 0, "kill: -l exits 0")
    out_text = out.decode(errors="replace")
    fw.report_result("HUP" in out_text, "kill: -l lists HUP")
    fw.report_result("KILL" in out_text, "kill: -l lists KILL")
    fw.report_result("TERM" in out_text, "kill: -l lists TERM")

    # Send signal to own process (using a subprocess)
    with tempfile.TemporaryDirectory() as tmpdir:
        # Start a sleep process to send signal to
        sleeper = subprocess.Popen(
            ["sleep", "60"],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )
        try:
            pid = str(sleeper.pid)
            rc, out, err = fw.run_asm(['-0', pid])
            fw.report_result(rc == 0, "kill: -0 (null signal) to live process exits 0")

            rc, out, err = fw.run_asm([pid])
            fw.report_result(rc == 0, "kill: SIGTERM to process exits 0")
        finally:
            try:
                sleeper.kill()
            except Exception:
                pass
            sleeper.wait()

    # Invalid PID
    rc, out, err = fw.run_asm(['99999999'])
    fw.report_result(rc != 0, "kill: invalid PID returns nonzero")

    # --help
    rc, out, err = fw.run_asm(['--help'])
    fw.report_result(rc == 0, "kill: --help exits 0")
    fw.report_result(len(out) > 0, "kill: --help produces output")

    # --version
    rc, out, err = fw.run_asm(['--version'])
    fw.report_result(rc == 0, "kill: --version exits 0")

if __name__ == '__main__':
    fw = SecurityTestFramework(config)
    fw.run_all(tool_specific_fn=tool_specific_tests)
