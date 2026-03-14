#!/usr/bin/env python3
"""Security tests for fnohup — uses shared framework."""
import sys, os, subprocess, tempfile
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', '..', 'tests'))
from security_framework import SecurityTestFramework

config = {
    'tool_name': 'nohup',
    'bin_name': 'fnohup',
    'gnu_path': '/usr/bin/nohup',
    'bss_size': 65536,
    'max_binary_size': 100000,
    'test_args': ['true'],
    'test_stdin': None,
    'timeout': 5,
}

def tool_specific_tests(fw):
    """13. Tool-specific: nohup tests."""
    fw.log("\n=== Nohup-Specific Tests ===")

    # nohup runs command and captures output
    rc, out, err = fw.run_asm(["echo", "hello_nohup"])
    text = (out + err).decode(errors="replace")
    fw.report_result("hello_nohup" in text, "nohup: echo — output contains expected text")

    # Exit code passthrough
    rc, out, err = fw.run_asm(["sh", "-c", "exit 42"])
    fw.report_result(rc == 42, f"nohup: exit code passthrough — got {rc}, expected 42")

    # Nonexistent command
    rc, out, err = fw.run_asm(["nonexistent_cmd_xyz"])
    fw.report_result(rc == 127, f"nohup: nonexistent command — exit code {rc} (expected 127)")

    # Non-executable file
    with tempfile.NamedTemporaryFile(suffix=".txt", delete=False) as f:
        f.write(b"not a script")
        f.flush()
        os.chmod(f.name, 0o644)
        rc, out, err = fw.run_asm([f.name])
        os.unlink(f.name)
    fw.report_result(rc in (126, 127), f"nohup: non-executable file — exit code {rc}")

    # nohup with non-tty stdout
    with tempfile.TemporaryDirectory() as d:
        env = os.environ.copy()
        env["HOME"] = d
        rc, out, err = fw.run_asm(["echo", "test"], env=env)
        fw.report_result(rc == 0, f"nohup: with non-tty stdout — exit {rc}")

    # --help
    rc, out, err = fw.run_asm(["--help"])
    text = out + err
    fw.report_result(b"Usage" in text or b"nohup" in text, "nohup: --help output contains usage info")

    # --version
    rc, out, err = fw.run_asm(["--version"])
    text = out + err
    fw.report_result(b"nohup" in text or b"coreutils" in text, "nohup: --version output contains version info")

    # No arguments — returns error
    rc, out, err = fw.run_asm([])
    fw.report_result(rc != 0, "nohup: no arguments — returns error")

    # Empty command
    rc, out, err = fw.run_asm([""])
    fw.report_result(rc != 0, "nohup: empty command — returns error")

    # Many arguments
    rc, out, err = fw.run_asm(["echo"] + ["arg"] * 1000)
    fw.report_result(rc == 0, "nohup: many arguments — handled")

    # Special chars in arguments
    rc, out, err = fw.run_asm(["echo", "hello\nworld\ttest"])
    fw.report_result(rc == 0, "nohup: special chars in arguments")

    # SIGHUP handling — child runs
    rc, out, err = fw.run_asm(["sh", "-c", "trap '' HUP; echo alive"])
    alive = b"alive" in out or b"alive" in err
    fw.report_result(alive or rc == 0, "nohup: SIGHUP handling — child runs")

if __name__ == '__main__':
    fw = SecurityTestFramework(config)
    fw.run_all(tool_specific_fn=tool_specific_tests)
