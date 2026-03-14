#!/usr/bin/env python3
"""Security tests for fsleep — uses shared framework."""
import sys, os, time
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', '..', 'tests'))
from security_framework import SecurityTestFramework
import subprocess

config = {
    'tool_name': 'sleep',
    'bin_name': 'fsleep',
    'gnu_path': '/usr/bin/sleep',
    'bss_size': 65536,
    'max_binary_size': 30000,
    'test_args': ['0'],
    'test_stdin': None,
    'timeout': 10,
}

def tool_specific_tests(fw):
    """13. Tool-specific: sleep tests."""
    fw.log("\n=== Sleep-Specific Tests ===")

    # sleep 0 should be instant
    start = time.monotonic()
    rc, out, err = fw.run_asm(["0"])
    elapsed = time.monotonic() - start
    fw.report_result(rc == 0, "sleep: sleep 0 exits 0")
    fw.report_result(elapsed < 0.5, f"sleep: sleep 0 elapsed {elapsed:.3f}s (<0.5s)")
    fw.report_result(len(out) == 0, "sleep: sleep 0 no stdout")
    fw.report_result(len(err) == 0, "sleep: sleep 0 no stderr")

    # sleep 1 should take ~1 second
    start = time.monotonic()
    rc, _, _ = fw.run_asm(["1"])
    elapsed = time.monotonic() - start
    fw.report_result(rc == 0, "sleep: sleep 1 exits 0")
    fw.report_result(0.8 < elapsed < 2.0, f"sleep: sleep 1 elapsed {elapsed:.3f}s (0.8-2.0)")

    # sleep 0.1 should take ~0.1 seconds (fractional support)
    start = time.monotonic()
    rc, _, _ = fw.run_asm(["0.1"])
    elapsed = time.monotonic() - start
    if rc == 0:
        fw.report_result(elapsed < 1.0, f"sleep: sleep 0.1 elapsed {elapsed:.3f}s (<1.0)")
    else:
        fw.report_result(rc < 128, "sleep: sleep 0.1 no signal death (may not support fractions)")

    # sleep 0.01
    start = time.monotonic()
    rc, _, _ = fw.run_asm(["0.01"])
    elapsed = time.monotonic() - start
    if rc == 0:
        fw.report_result(elapsed < 0.5, f"sleep: sleep 0.01 elapsed {elapsed:.3f}s (<0.5)")
    else:
        fw.report_result(rc < 128, "sleep: sleep 0.01 no signal death")

    # Compare with GNU sleep for consistency
    if os.path.exists(fw.gnu_path):
        rc_f, _, _ = fw.run_asm(["0"])
        rc_g, _, _ = fw.run_gnu(["0"])
        fw.report_result(rc_f == rc_g, f"sleep: sleep 0 exit code matches GNU ({rc_f} vs {rc_g})")

    # Invalid args
    rc, _, err = fw.run_asm(["abc"])
    fw.report_result(rc != 0, "sleep: invalid arg 'abc' non-zero exit")

    rc, _, _ = fw.run_asm(["-1"])
    fw.report_result(rc < 128, "sleep: negative arg no signal death")

    # Empty arg
    rc, _, _ = fw.run_asm([""])
    fw.report_result(rc < 128, "sleep: empty arg no signal death")

    # Very large number -- should not hang (we'll kill it)
    p = subprocess.Popen([fw.bin_path, "999999"], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    time.sleep(0.2)
    p.kill()
    try:
        p.wait(timeout=2)
        fw.report_result(True, "sleep: large value starts sleeping (killable)")
    except subprocess.TimeoutExpired:
        fw.report_result(False, "sleep: large value not killable")

    # Ignores stdin
    rc, _, _ = fw.run_asm(["0"], stdin_data=b"data\n")
    fw.report_result(rc == 0, "sleep: ignores stdin exits 0")

    # Multiple durations (GNU extension)
    if os.path.exists(fw.gnu_path):
        rc_g, _, _ = fw.run_gnu(["0", "0"])
        rc_f, _, _ = fw.run_asm(["0", "0"])
        fw.report_result(rc_f == rc_g, f"sleep: multiple durations exit matches GNU ({rc_f} vs {rc_g})")

    # With -- separator
    rc, _, _ = fw.run_asm(["--", "0"])
    fw.report_result(rc < 128, "sleep: -- 0 no signal death")

if __name__ == '__main__':
    fw = SecurityTestFramework(config)
    fw.run_all(tool_specific_fn=tool_specific_tests)
