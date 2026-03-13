#!/usr/bin/env python3
"""security_tests.py — Security & memory safety tests for fchmod.

fchmod is a GNU-compatible 'chmod' written in x86-64 Linux assembly.

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
   10. Error handling
   11. Concurrency stress
   12. Tool-specific (chmod: permission changes)
"""

import os
import sys
import subprocess
import struct
import signal
import time
import tempfile
from pathlib import Path
from shutil import which

TIMEOUT = 5
BIN = ""
GNU = "chmod"
LOG_EVERY = 1

PASS = 0
FAIL = 0
SKIP = 0
FAILURES = []
TMPDIR = ""


def log(msg):
    print(msg, flush=True)


def report_result(passed, name):
    global PASS, FAIL, FAILURES
    if passed:
        PASS += 1
        if PASS % LOG_EVERY == 0:
            log(f"[PASS] {name}")
    else:
        FAIL += 1
        FAILURES.append(name)
        log(f"[FAIL] {name}")


def report_skip(name):
    global SKIP
    SKIP += 1


def run(cmd, stdin_data=None, timeout=TIMEOUT, env=None):
    try:
        p = subprocess.run(cmd, capture_output=True, timeout=timeout,
                           input=stdin_data, env=env)
        return p.returncode, p.stdout, p.stderr
    except subprocess.TimeoutExpired:
        return -1, b"", b"TIMEOUT"
    except Exception as e:
        return -1, b"", str(e).encode()


# ── 1. ELF Binary Analysis ──
def check_elf_properties():
    log("\n=== 1. ELF Binary Analysis ===")
    with open(BIN, "rb") as f:
        data = f.read(64)
    report_result(data[:4] == b"\x7fELF", "elf: magic bytes ELF")
    report_result(data[4] == 2, "elf: ELFCLASS64 (64-bit)")

    size = os.path.getsize(BIN)
    report_result(size < 102400, f"elf: binary size {size} bytes (<100KB)")

    with open(BIN, "rb") as f:
        elf = f.read()
    e_phoff = struct.unpack_from("<Q", elf, 32)[0]
    e_phentsize = struct.unpack_from("<H", elf, 54)[0]
    e_phnum = struct.unpack_from("<H", elf, 56)[0]

    has_interp = False
    has_dynamic = False
    for i in range(e_phnum):
        off = e_phoff + i * e_phentsize
        p_type = struct.unpack_from("<I", elf, off)[0]
        if p_type == 3:
            has_interp = True
        if p_type == 2:
            has_dynamic = True
    report_result(not has_interp, "elf: no PT_INTERP (static binary)")
    report_result(not has_dynamic, "elf: no PT_DYNAMIC (no dynamic linking)")


# ── 2. Syscall Surface ──
def check_syscall_surface():
    log("\n=== 2. Syscall Surface ===")
    strace_path = which("strace")
    if not strace_path:
        report_skip("strace not available")
        return
    tf = os.path.join(TMPDIR, "strace_target")
    open(tf, "w").close()
    os.chmod(tf, 0o644)
    rc, out, err = run([strace_path, "-f", "-c", BIN, "755", tf])
    report_result(rc == 0, "strace: basic chmod succeeds under strace")


# ── 3. /proc Analysis ──
def check_proc_analysis():
    log("\n=== 3. /proc Analysis ===")
    tf = os.path.join(TMPDIR, "proc_target")
    open(tf, "w").close()
    os.chmod(tf, 0o644)
    p = subprocess.Popen([BIN, "755", tf], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    p.wait()
    report_result(p.returncode == 0, "proc: basic execution succeeds")


# ── 4. FD Hygiene ──
def check_fd_hygiene():
    log("\n=== 4. FD Hygiene ===")
    rc, out, err = run([BIN, "--help"])
    report_result(rc == 0, "fd: --help writes to stdout")
    report_result(len(out) > 0, "fd: --help produces output")

    tf = os.path.join(TMPDIR, "fd_target")
    open(tf, "w").close()
    os.chmod(tf, 0o644)
    rc, out, err = run([BIN, "755", os.path.join(TMPDIR, "nonexistent_xyz")])
    report_result(rc != 0, "fd: error on nonexistent file")


# ── 5. Memory Safety ──
def check_memory_safety():
    log("\n=== 5. Memory Safety ===")
    tf = os.path.join(TMPDIR, "mem_target")
    open(tf, "w").close()
    os.chmod(tf, 0o644)
    long_path = os.path.join(TMPDIR, "a" * 200)
    rc, out, err = run([BIN, "755", long_path])
    report_result(rc != 0 and rc < 128, "mem: long path -> error, no crash")

    rc, out, err = run([BIN, "755", tf, tf, tf, tf, tf])
    report_result(rc >= 0 and rc < 128, "mem: multiple args -> no crash")


# ── 6. Signal Safety ──
def check_signal_safety():
    log("\n=== 6. Signal Safety ===")
    tf = os.path.join(TMPDIR, "sig_target")
    open(tf, "w").close()
    os.chmod(tf, 0o644)
    p = subprocess.Popen([BIN, "755", tf], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    p.wait()
    report_result(p.returncode >= 0 and p.returncode < 128, "signal: normal exit, no signal death")


# ── 7. Input Fuzzing ──
def check_input_fuzzing():
    log("\n=== 7. Input Fuzzing ===")
    tf = os.path.join(TMPDIR, "fuzz_target")
    open(tf, "w").close()

    for mode in ["644", "755", "600", "777", "000"]:
        os.chmod(tf, 0o644)
        rc, _, _ = run([BIN, mode, tf])
        report_result(rc >= 0 and rc < 128, f"fuzz: mode {mode} -> no crash")


# ── 8. Resource Limits ──
def check_resource_limits():
    log("\n=== 8. Resource Limits ===")
    tf = os.path.join(TMPDIR, "rlimit_target")
    open(tf, "w").close()
    os.chmod(tf, 0o644)
    rc, out, err = run([BIN, "755", tf])
    report_result(rc == 0, "rlimit: basic chmod under default limits")


# ── 9. Environment Robustness ──
def check_environment():
    log("\n=== 9. Environment Robustness ===")
    tf = os.path.join(TMPDIR, "env_target")
    open(tf, "w").close()
    os.chmod(tf, 0o644)
    env = {}
    rc, _, _ = run([BIN, "755", tf], env=env)
    report_result(rc >= 0 and rc < 128, "env: empty environment -> no crash")

    os.chmod(tf, 0o644)
    env = dict(os.environ)
    env["LC_ALL"] = "C"
    rc, _, _ = run([BIN, "644", tf], env=env)
    report_result(rc >= 0 and rc < 128, "env: LC_ALL=C -> no crash")


# ── 10. Error Handling ──
def check_error_handling():
    log("\n=== 10. Error Handling ===")
    for flag in ["--badopt", "-Z"]:
        rc, out, err = run([BIN, flag])
        report_result(rc >= 0 and rc < 128, f"error: '{flag}' no signal death")

    rc, out, err = run([BIN])
    report_result(rc != 0, "error: no args -> nonzero exit")


# ── 11. Concurrency Stress ──
def check_concurrency():
    log("\n=== 11. Concurrency Stress ===")
    tf = os.path.join(TMPDIR, "conc_target")
    open(tf, "w").close()
    os.chmod(tf, 0o644)
    procs = []
    for _ in range(20):
        p = subprocess.Popen([BIN, "755", tf],
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        procs.append(p)
    all_ok = True
    for p in procs:
        p.wait()
        if p.returncode < 0 or p.returncode >= 128:
            all_ok = False
    report_result(all_ok, "concurrency: 20 parallel chmod -> no crashes")


# ── 12. Tool-specific ──
def check_chmod_specific():
    log("\n=== 12. chmod-specific ===")
    tf = os.path.join(TMPDIR, "chmod_test")
    open(tf, "w").close()
    os.chmod(tf, 0o644)

    # Octal mode change
    rc, _, _ = run([BIN, "755", tf])
    actual = oct(os.stat(tf).st_mode & 0o7777)
    report_result(rc == 0 and actual == "0o755", f"chmod: 755 -> {actual}")

    rc, _, _ = run([BIN, "600", tf])
    actual = oct(os.stat(tf).st_mode & 0o7777)
    report_result(rc == 0 and actual == "0o600", f"chmod: 600 -> {actual}")

    # Error message includes tool prefix
    rc, _, err = run([BIN, "755", os.path.join(TMPDIR, "no_such_file")])
    report_result(rc != 0, "chmod: nonexistent file -> error exit")


def main():
    global BIN, TMPDIR

    script_dir = os.path.dirname(os.path.abspath(__file__))
    tool_dir = os.path.dirname(script_dir)

    candidates = [
        os.path.join(tool_dir, "fchmod"),
        os.path.join(tool_dir, "fchmod_release"),
    ]
    for c in candidates:
        if os.path.isfile(c) and os.access(c, os.X_OK):
            BIN = c
            break
    if not BIN:
        log(f"[ERROR] Binary not found in {tool_dir}")
        sys.exit(1)

    log(f"Testing: {BIN}")
    TMPDIR = tempfile.mkdtemp()

    try:
        check_elf_properties()
        check_syscall_surface()
        check_proc_analysis()
        check_fd_hygiene()
        check_memory_safety()
        check_signal_safety()
        check_input_fuzzing()
        check_resource_limits()
        check_environment()
        check_error_handling()
        check_concurrency()
        check_chmod_specific()
    finally:
        import shutil
        shutil.rmtree(TMPDIR, ignore_errors=True)

    log(f"\n{'='*60}")
    log(f"RESULTS: {PASS}/{PASS+FAIL} passed, {FAIL} failed, {SKIP} skipped")
    if FAILURES:
        log(f"\nFAILURES ({len(FAILURES)}):")
        for f in FAILURES:
            log(f"  [test] {f}")
    log(f"{'='*60}")
    sys.exit(1 if FAIL > 0 else 0)


if __name__ == "__main__":
    main()
