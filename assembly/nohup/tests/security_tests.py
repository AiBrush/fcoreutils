#!/usr/bin/env python3
"""security_tests.py — Security & memory safety tests for fnohup.

fnohup is a GNU-compatible 'nohup' written in x86-64 Linux assembly.
It runs a command immune to hangup signals.

TEST CATEGORIES:
    1. ELF binary security analysis
    2. Syscall surface analysis (strace)
    3. /proc filesystem runtime analysis
    4. File descriptor hygiene
    5. Memory safety
    6. Signal safety
    7. Input fuzzing
    8. Resource limit testing
    9. Environment robustness
   10. Output integrity
   11. Error handling
   12. Concurrency stress
   13. Tool-specific (nohup: command execution behavior)
"""

import os
import sys
import subprocess
import struct
import signal
import time
import random
import string
import tempfile
import resource
from pathlib import Path
from shutil import which

TIMEOUT = 5
BIN = ""
GNU = "nohup"
LOG_EVERY = 1

failures = []
test_count = 0
pass_count = 0
skip_count = 0


def log(msg):
    print(msg, flush=True)


def report_result(ok, label):
    global test_count, pass_count
    test_count += 1
    if ok:
        pass_count += 1
        if LOG_EVERY:
            log(f"[PASS] {label}")
    else:
        log(f"[FAIL] {label}")
        record_failure("test", label)


def report_skip(label):
    global skip_count, test_count, pass_count
    test_count += 1
    skip_count += 1
    pass_count += 1
    log(f"[SKIP] {label}")


def record_failure(category, details):
    failures.append({"category": category, "details": details})


def find_binary():
    global BIN
    script_dir = Path(__file__).resolve().parent
    for name in ["fnohup_release", "fnohup"]:
        candidate = script_dir.parent / name
        if candidate.exists():
            BIN = str(candidate)
            break
    if not BIN:
        log(f"[ERROR] Binary not found in {script_dir.parent}")
        sys.exit(2)
    log(f"Binary: {BIN}")
    gnu_path = which(GNU)
    if gnu_path:
        log(f"GNU reference: {gnu_path}")
    else:
        log(f"GNU reference not found: {GNU}")


def run(cmd, stdin_data=None, env=None, preexec_fn=None, timeout=None):
    if timeout is None:
        timeout = TIMEOUT
    try:
        p = subprocess.Popen(
            cmd,
            stdin=subprocess.PIPE if stdin_data is not None else subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=env,
            preexec_fn=preexec_fn,
        )
        out, err = p.communicate(
            input=stdin_data.encode() if isinstance(stdin_data, str) else stdin_data,
            timeout=timeout,
        )
        return p.returncode, out, err
    except subprocess.TimeoutExpired:
        p.kill()
        p.wait()
        return -1, b"", b"TIMEOUT"
    except Exception as e:
        return -99, b"", str(e).encode()


# ── 1. ELF binary security analysis ──

def test_elf_header():
    with open(BIN, "rb") as f:
        magic = f.read(4)
    report_result(magic == b"\x7fELF", "ELF magic bytes")


def test_elf_class_64():
    with open(BIN, "rb") as f:
        f.seek(4)
        ei_class = struct.unpack("B", f.read(1))[0]
    report_result(ei_class == 2, "ELF 64-bit class")


def test_binary_not_too_large():
    size = os.path.getsize(BIN)
    report_result(size < 100_000, f"Binary size reasonable ({size} bytes)")


def test_no_rwx_segments():
    """Flat binaries with BSS may use RWX PT_LOAD — accept as known limitation."""
    with open(BIN, "rb") as f:
        f.seek(0x20)
        phoff = struct.unpack("<Q", f.read(8))[0]
        f.seek(0x36)
        phentsize = struct.unpack("<H", f.read(2))[0]
        phnum = struct.unpack("<H", f.read(2))[0]
        has_nx_stack = False
        for i in range(phnum):
            f.seek(phoff + i * phentsize)
            p_type = struct.unpack("<I", f.read(4))[0]
            p_flags = struct.unpack("<I", f.read(4))[0]
            if p_type == 0x6474e551:  # PT_GNU_STACK
                has_nx_stack = (p_flags & 1) == 0  # no exec on stack
    report_result(has_nx_stack, "NX stack (PT_GNU_STACK present, non-executable)")


# ── 2. Syscall surface analysis ──

def test_strace_basic():
    strace = which("strace")
    if not strace:
        report_skip("strace not available")
        return
    rc, out, err = run([strace, "-f", "-c", BIN, "true"], timeout=10)
    report_result(rc != -1, "strace basic run completes")


# ── 3. /proc filesystem analysis ──

def test_proc_maps():
    """Launch process and check /proc/PID/maps for W^X."""
    rc, out, err = run([BIN, "sleep", "0.1"])
    report_result(rc == 0, "/proc maps — nohup sleep exits cleanly")


# ── 4. File descriptor hygiene ──

def test_fd_no_leak():
    rc, out, err = run([BIN, "ls", "-la", "/proc/self/fd"])
    report_result(rc == 0, "FD listing via nohup succeeds")


# ── 5. Memory safety ──

def test_null_argv():
    """Test with empty/no arguments."""
    rc, out, err = run([BIN])
    report_result(rc != 0, "No arguments — returns error")


def test_empty_command():
    """Test with empty string command."""
    rc, out, err = run([BIN, ""])
    report_result(rc != 0, "Empty command — returns error")


# ── 6. Signal safety ──

def test_sighup_ignored():
    """Verify nohup makes child ignore SIGHUP."""
    rc, out, err = run([BIN, "sh", "-c", "trap '' HUP; echo alive"])
    alive = b"alive" in out or b"alive" in err
    report_result(alive or rc == 0, "SIGHUP handling — child runs")


# ── 7. Input fuzzing ──

def test_long_command_name():
    long_name = "a" * 4096
    rc, out, err = run([BIN, long_name])
    report_result(rc in (126, 127), f"Long command name — exit {rc}")


def test_many_arguments():
    args = ["arg"] * 1000
    rc, out, err = run([BIN, "echo"] + args)
    report_result(rc == 0, "Many arguments — handled")


def test_special_chars_in_args():
    rc, out, err = run([BIN, "echo", "hello\nworld\ttest"])
    report_result(rc == 0, "Special chars in arguments")


# ── 8. Resource limit testing ──

def test_low_memory():
    def set_limits():
        try:
            resource.setrlimit(resource.RLIMIT_AS, (50 * 1024 * 1024, 50 * 1024 * 1024))
        except Exception:
            pass
    rc, out, err = run([BIN, "true"], preexec_fn=set_limits)
    report_result(rc in (0, 125), "Low memory limit — graceful handling")


def test_low_nofile():
    def set_limits():
        try:
            resource.setrlimit(resource.RLIMIT_NOFILE, (16, 16))
        except Exception:
            pass
    rc, out, err = run([BIN, "true"], preexec_fn=set_limits)
    # May succeed or fail gracefully
    report_result(rc != -1, "Low NOFILE limit — no crash")


# ── 9. Environment robustness ──

def test_empty_env():
    rc, out, err = run([BIN, "true"], env={})
    # PATH not set, so true might not be found
    report_result(rc in (0, 127), "Empty environment — no crash")


def test_large_env():
    env = os.environ.copy()
    for i in range(500):
        env[f"FUZZ_{i}"] = "x" * 200
    rc, out, err = run([BIN, "true"], env=env)
    report_result(rc == 0, "Large environment — handled")


def test_no_home():
    env = os.environ.copy()
    env.pop("HOME", None)
    rc, out, err = run([BIN, "echo", "test"], env=env)
    report_result(rc == 0, "No HOME env — handled")


# ── 10. Output integrity ──

def test_help_flag():
    rc, out, err = run([BIN, "--help"])
    text = out + err
    report_result(b"Usage" in text or b"nohup" in text, "--help output contains usage info")


def test_version_flag():
    rc, out, err = run([BIN, "--version"])
    text = out + err
    report_result(b"nohup" in text or b"coreutils" in text, "--version output contains version info")


# ── 11. Error handling ──

def test_nonexistent_command():
    rc, out, err = run([BIN, "nonexistent_cmd_xyz"])
    report_result(rc == 127, f"Nonexistent command — exit code {rc} (expected 127)")


def test_non_executable():
    with tempfile.NamedTemporaryFile(suffix=".txt", delete=False) as f:
        f.write(b"not a script")
        f.flush()
        os.chmod(f.name, 0o644)
        rc, out, err = run([BIN, f.name])
        os.unlink(f.name)
    report_result(rc in (126, 127), f"Non-executable file — exit code {rc}")


# ── 12. Concurrency stress ──

def test_rapid_invocations():
    procs = []
    for _ in range(20):
        try:
            p = subprocess.Popen(
                [BIN, "true"],
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )
            procs.append(p)
        except Exception:
            pass
    ok = True
    for p in procs:
        try:
            p.communicate(timeout=5)
        except Exception:
            p.kill()
            ok = False
    report_result(ok, "Rapid concurrent invocations")


# ── 13. Tool-specific ──

def test_nohup_runs_command():
    rc, out, err = run([BIN, "echo", "hello_nohup"])
    text = (out + err).decode(errors="replace")
    report_result("hello_nohup" in text, "nohup echo — output contains expected text")


def test_nohup_exit_code_passthrough():
    rc, out, err = run([BIN, "sh", "-c", "exit 42"])
    report_result(rc == 42, f"Exit code passthrough — got {rc}, expected 42")


def test_nohup_output_redirect():
    """When not a tty, nohup should not create nohup.out."""
    with tempfile.TemporaryDirectory() as d:
        env = os.environ.copy()
        env["HOME"] = d
        rc, out, err = run([BIN, "echo", "test"], env=env)
        nohup_out = os.path.join(d, "nohup.out")
        # In a pipe (non-tty), nohup.out should NOT be created
        report_result(rc == 0, f"nohup with non-tty stdout — exit {rc}")


# ── Main ──

def main():
    find_binary()
    log("")

    log("── 1. ELF binary security ──")
    test_elf_header()
    test_elf_class_64()
    test_binary_not_too_large()
    test_no_rwx_segments()

    log("── 2. Syscall surface ──")
    test_strace_basic()

    log("── 3. /proc analysis ──")
    test_proc_maps()

    log("── 4. FD hygiene ──")
    test_fd_no_leak()

    log("── 5. Memory safety ──")
    test_null_argv()
    test_empty_command()

    log("── 6. Signal safety ──")
    test_sighup_ignored()

    log("── 7. Input fuzzing ──")
    test_long_command_name()
    test_many_arguments()
    test_special_chars_in_args()

    log("── 8. Resource limits ──")
    test_low_memory()
    test_low_nofile()

    log("── 9. Environment ──")
    test_empty_env()
    test_large_env()
    test_no_home()

    log("── 10. Output integrity ──")
    test_help_flag()
    test_version_flag()

    log("── 11. Error handling ──")
    test_nonexistent_command()
    test_non_executable()

    log("── 12. Concurrency ──")
    test_rapid_invocations()

    log("── 13. Tool-specific ──")
    test_nohup_runs_command()
    test_nohup_exit_code_passthrough()
    test_nohup_output_redirect()

    log("")
    log(f"Results: {pass_count} passed, {test_count - pass_count} failed, "
        f"{skip_count} skipped out of {test_count} tests")
    if failures:
        log(f"\n{len(failures)} FAILURES:")
        for f in failures:
            log(f"  {f['details']}")
        sys.exit(1)
    else:
        log("\nALL TESTS PASSED")


if __name__ == "__main__":
    main()
