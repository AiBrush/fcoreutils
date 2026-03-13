#!/usr/bin/env python3
"""security_tests.py — Security & memory safety tests for fstty (assembly stty).

fstty is a GNU-compatible 'stty' written in x86-64 Linux assembly.
change and print terminal settings.
"""

import os
import sys
import subprocess
import struct
import signal
import time
import random
import string
import resource
from pathlib import Path
from shutil import which

TIMEOUT = 10
TOOL_NAME = "stty"
BIN = str(Path(__file__).resolve().parent.parent / "fstty")
GNU = "/usr/bin/stty"

failures = []
test_count = 0
pass_count = 0
skip_count = 0

def log(msg):
    print(msg, flush=True)

def record_failure(label, note=""):
    failures.append({"label": label, "note": note})

def report_result(ok, label):
    global test_count, pass_count
    test_count += 1
    if ok:
        pass_count += 1
        log(f"[PASS] {label}")
    else:
        log(f"[FAIL] {label}")
        record_failure(label)

def skip_test(label, reason=""):
    global test_count, skip_count, pass_count
    test_count += 1
    skip_count += 1
    pass_count += 1
    log(f"[SKIP] {label} ({reason})")

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
    except (OSError, ValueError):
        return (126, b'', b'OSError')
    try:
        out, err = p.communicate(input=stdin_data, timeout=timeout)
    except subprocess.TimeoutExpired:
        p.kill()
        out, err = p.communicate()
        return (124, out, err)
    return (p.returncode, out, err)


def find_binary():
    global BIN
    script_dir = Path(__file__).resolve().parent
    for name in ["fstty_release", "fstty"]:
        candidate = script_dir.parent / name
        if candidate.exists():
            BIN = str(candidate)
            break
    if not os.path.exists(BIN):
        log(f"[ERROR] Binary not found: {BIN}")
        sys.exit(2)
    log(f"Binary: {BIN}")
    gnu_path = which("stty")
    if gnu_path:
        log(f"GNU reference: {gnu_path}")


# =============================================================================
#                     1. ELF BINARY SECURITY ANALYSIS
# =============================================================================

def check_elf_properties():
    log("\n=== 1. ELF Binary Security Analysis ===")
    try:
        with open(BIN, "rb") as f:
            elf = f.read()
    except Exception as e:
        record_failure(f"elf: Cannot read binary: {e}")
        report_result(False, "elf: read binary")
        return

    report_result(elf[:4] == b"\x7fELF", "elf: magic bytes \x7fELF")
    report_result(elf[4] == 2, "elf: ELFCLASS64 (64-bit)")

    size = len(elf)
    report_result(size < 50000, f"elf: binary size {size} bytes (<50KB)")

    e_phoff = struct.unpack_from("<Q", elf, 32)[0]
    e_phentsize = struct.unpack_from("<H", elf, 54)[0]
    e_phnum = struct.unpack_from("<H", elf, 56)[0]

    PT_INTERP, PT_DYNAMIC, PT_GNU_STACK = 3, 2, 0x6474E551
    PF_X = 1

    has_interp = has_dynamic = False
    has_nx_stack = False

    for i in range(e_phnum):
        off = e_phoff + i * e_phentsize
        p_type = struct.unpack_from("<I", elf, off)[0]
        p_flags = struct.unpack_from("<I", elf, off + 4)[0]
        if p_type == PT_INTERP:
            has_interp = True
        if p_type == PT_DYNAMIC:
            has_dynamic = True
        if p_type == PT_GNU_STACK:
            has_nx_stack = not bool(p_flags & PF_X)

    report_result(not has_interp, "elf: no PT_INTERP (static binary)")
    report_result(not has_dynamic, "elf: no PT_DYNAMIC (no dynamic linking)")
    report_result(has_nx_stack, "elf: PT_GNU_STACK NX (non-executable stack)")


# =============================================================================
#                     2. SIGNAL SAFETY
# =============================================================================

def check_signal_safety():
    log("\n=== 2. Signal Safety ===")
    rc, out, err = run([BIN, "--help"])
    report_result(rc == 0, "signal: --help clean exit")

    script = f'{BIN} --help | head -c 0'
    p = subprocess.run(["bash", "-c", script], capture_output=True, timeout=TIMEOUT)
    report_result(p.returncode >= 0 and p.returncode < 128, "signal: SIGPIPE clean exit")


# =============================================================================
#                     3. MEMORY SAFETY
# =============================================================================

def check_memory_safety():
    log("\n=== 3. Memory Safety ===")
    rc, out, err = run([BIN, "--help"])
    report_result(rc == 0 and rc < 128, "memory: --help no crash")

    rc, out, err = run([BIN, "--version"])
    report_result(rc == 0 and rc < 128, "memory: --version no crash")

    def limit_stack():
        resource.setrlimit(resource.RLIMIT_STACK, (65536, 65536))
    rc, out, err = run([BIN, "--help"], preexec_fn=limit_stack)
    report_result(rc == 0, "memory: 64KB stack --help exits 0")

    def limit_mem():
        resource.setrlimit(resource.RLIMIT_AS, (16 * 1024 * 1024, 16 * 1024 * 1024))
    rc, out, err = run([BIN, "--help"], preexec_fn=limit_mem)
    report_result(rc == 0, "memory: 16MB address space --help exits 0")


# =============================================================================
#                     4. ENVIRONMENT ROBUSTNESS
# =============================================================================

def check_environment():
    log("\n=== 4. Environment Robustness ===")
    rc, out, err = run([BIN, "--help"], env={})
    report_result(rc == 0, "env: empty environment --help exits 0")

    hostile = {"PATH": "", "HOME": "/nonexistent", "LANG": "xx_XX.BROKEN"}
    rc, out, err = run([BIN, "--help"], env=hostile)
    report_result(rc == 0, "env: hostile env --help exits 0")

    big_env = {f"VAR_{i}": f"value_{'X' * 100}" for i in range(1000)}
    rc, out, err = run([BIN, "--help"], env=big_env)
    report_result(rc == 0, "env: 1000 env vars --help exits 0")


# =============================================================================
#                     5. FILE DESCRIPTOR HYGIENE
# =============================================================================

def check_fd_hygiene():
    log("\n=== 5. File Descriptor Hygiene ===")

    script = f'exec 3>&1 1>&-; {BIN} --help 2>/dev/null; echo $? >&3'
    p = subprocess.run(["bash", "-c", script], capture_output=True, timeout=TIMEOUT, text=True)
    rc = p.stdout.strip()
    report_result(rc != "", "fd: closed stdout does not hang")

    script = f'{BIN} --help > /dev/null 2>/dev/null; echo $?'
    p = subprocess.run(["bash", "-c", script], capture_output=True, timeout=TIMEOUT, text=True)
    rc = p.stdout.strip()
    report_result(rc == "0", "fd: /dev/null redirect exits 0")


# =============================================================================
#                     6. RESOURCE LIMIT TESTING
# =============================================================================

def check_resource_limits():
    log("\n=== 6. Resource Limit Testing ===")

    def limit_nofile():
        resource.setrlimit(resource.RLIMIT_NOFILE, (3, 3))
    rc, _, _ = run([BIN, "--help"], preexec_fn=limit_nofile)
    report_result(rc >= 0 and rc < 128, "rlimit: RLIMIT_NOFILE=3 no crash")

    def limit_cpu():
        resource.setrlimit(resource.RLIMIT_CPU, (1, 1))
    rc, _, _ = run([BIN, "--help"], preexec_fn=limit_cpu)
    report_result(rc == 0, "rlimit: RLIMIT_CPU=1s exits 0")


# =============================================================================
#                     7. INPUT FUZZING
# =============================================================================

def check_fuzzing():
    log("\n=== 7. Input Fuzzing ===")

    crash_count = 0
    for i in range(20):
        flags = "--" + "".join(random.choices(string.ascii_lowercase + "-", k=random.randint(3, 30)))
        rc, out, err = run([BIN, flags])
        if rc >= 128:
            crash_count += 1
    report_result(crash_count == 0, f"fuzz: 20 random long flags no signal death ({crash_count})")


# =============================================================================
#                     8. CONCURRENCY STRESS
# =============================================================================

def check_concurrency():
    log("\n=== 8. Concurrency Stress ===")

    procs = []
    for _ in range(50):
        p = subprocess.Popen([BIN, "--help"],
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        procs.append(p)

    crash_count = 0
    for p in procs:
        try:
            out, err = p.communicate(timeout=TIMEOUT)
            if p.returncode != 0:
                crash_count += 1
        except subprocess.TimeoutExpired:
            p.kill()
            crash_count += 1

    report_result(crash_count == 0, f"concurrency: 50 simultaneous --help ({crash_count} failures)")


# =============================================================================
#                           MAIN
# =============================================================================

def run_tests():
    find_binary()
    check_elf_properties()
    check_signal_safety()
    check_memory_safety()
    check_environment()
    check_fd_hygiene()
    check_resource_limits()
    check_fuzzing()
    check_concurrency()


def print_summary():
    log("\n" + "=" * 60)
    log(f"RESULTS: {pass_count}/{test_count} passed, "
        f"{test_count - pass_count - skip_count} failed, {skip_count} skipped")
    if failures:
        log(f"\nFAILURES ({len(failures)}):")
        for f in failures:
            log(f"  [{f['label']}] {f.get('note', '')}")
    log("=" * 60)


if __name__ == "__main__":
    run_tests()
    print_summary()
    sys.exit(0 if (test_count - pass_count - skip_count) == 0 else 1)
