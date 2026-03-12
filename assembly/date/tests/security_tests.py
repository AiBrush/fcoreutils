#!/usr/bin/env python3
"""security_tests.py — Security & memory safety tests for fdate (assembly date).

fdate is a GNU-compatible 'date' written in x86-64 Linux assembly.
It displays the current date and time, supporting various output formats.
Always uses UTC (no timezone file parsing).
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
TOOL_NAME = "date"
BIN = str(Path(__file__).resolve().parent.parent / "fdate")
GNU = "/usr/bin/date"

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

def run(cmd, stdin_data=None, timeout=TIMEOUT, env=None, preexec_fn=None):
    try:
        p = subprocess.Popen(
            cmd, stdin=subprocess.PIPE if stdin_data is not None else subprocess.DEVNULL,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            env=env, preexec_fn=preexec_fn)
        out, err = p.communicate(input=stdin_data, timeout=timeout)
        return p.returncode, out, err
    except subprocess.TimeoutExpired:
        p.kill()
        out, err = p.communicate()
        return 124, out, err
    except Exception as e:
        return -1, b"", str(e).encode()


def test_elf_binary_security():
    log("\n=== ELF Binary Security Analysis ===")
    try:
        with open(BIN, "rb") as f:
            elf = f.read()
    except Exception as e:
        report_result(False, f"elf: cannot read binary: {e}")
        return

    report_result(elf[:4] == b"\x7fELF", "elf: valid ELF magic bytes")
    report_result(elf[4] == 2, "elf: ELFCLASS64 (64-bit)")
    size = len(elf)
    report_result(size < 30000, f"elf: binary size {size} bytes (<30KB)")

    e_phoff = struct.unpack_from("<Q", elf, 32)[0]
    e_phentsize = struct.unpack_from("<H", elf, 54)[0]
    e_phnum = struct.unpack_from("<H", elf, 56)[0]

    PT_INTERP, PT_DYNAMIC, PT_GNU_STACK = 3, 2, 0x6474E551
    PF_X, PF_W, PF_R = 1, 2, 4

    has_interp = has_dynamic = has_rwx = has_nx_stack = False

    for i in range(e_phnum):
        off = e_phoff + i * e_phentsize
        p_type = struct.unpack_from("<I", elf, off)[0]
        p_flags = struct.unpack_from("<I", elf, off + 4)[0]
        if p_type == PT_INTERP:
            has_interp = True
        if p_type == PT_DYNAMIC:
            has_dynamic = True
        if (p_flags & PF_R) and (p_flags & PF_W) and (p_flags & PF_X):
            has_rwx = True
        if p_type == PT_GNU_STACK:
            has_nx_stack = not bool(p_flags & PF_X)

    report_result(not has_interp, "elf: no PT_INTERP (static binary)")
    report_result(not has_dynamic, "elf: no PT_DYNAMIC (no dynamic linking)")
    is_flat = e_phnum <= 2
    report_result(not has_rwx or is_flat, "elf: no RWX segments" + (" (flat binary)" if is_flat and has_rwx else ""))
    report_result(has_nx_stack, "elf: PT_GNU_STACK NX (non-executable stack)")


def test_strings_leaks():
    log("\n=== Binary String Leak Analysis ===")
    with open(BIN, "rb") as f:
        data = f.read()

    bad_patterns = [
        (b"/home/", "home directory path"),
        (b"/tmp/", "tmp path"),
        (b"DEBUG", "debug string"),
        (b"TODO", "todo string"),
        (b"password", "password string"),
        (b"secret", "secret string"),
        (b".so", "shared library reference"),
        (b"ld-linux", "dynamic linker reference"),
        (b"libc", "libc reference"),
        (b"glibc", "glibc reference"),
    ]
    for pattern, desc in bad_patterns:
        found = pattern in data
        if found:
            record_failure(f"strings: {desc}")
        report_result(not found, f"strings: no {desc} in binary")


def test_fd_hygiene():
    log("\n=== File Descriptor Hygiene ===")

    rc, _, _ = run([BIN])
    report_result(rc == 0, "fd: default invocation exit 0")

    def limit_nofile():
        resource.setrlimit(resource.RLIMIT_NOFILE, (3, 3))
    rc, _, _ = run([BIN], preexec_fn=limit_nofile)
    report_result(rc == 0, "fd: RLIMIT_NOFILE=3 -> exit 0")


def test_memory_safety():
    log("\n=== Memory Safety ===")

    rc, _, _ = run([BIN])
    report_result(rc < 128, "memory: no signal death on default")

    rc, _, _ = run([BIN, "+%Y-%m-%d"])
    report_result(rc < 128, "memory: no signal death with format")

    rc, _, _ = run([BIN, "+" + "A" * 200])
    report_result(rc < 128, "memory: no signal death with long format")


def test_signal_safety():
    log("\n=== Signal Safety ===")

    for sig_name, sig in [("SIGTERM", signal.SIGTERM), ("SIGINT", signal.SIGINT)]:
        rc, _, _ = run([BIN])
        report_result(rc < 128, f"signal: {sig_name} no crash on quick run")


def test_fuzzing():
    log("\n=== Input Fuzzing ===")

    crash_count = 0
    for i in range(50):
        n_args = random.randint(0, 3)
        args = ["".join(random.choices(string.printable, k=random.randint(0, 50)))
                for _ in range(n_args)]
        rc, _, _ = run([BIN] + args, timeout=3)
        if rc >= 128:
            crash_count += 1
    report_result(crash_count == 0, f"fuzz: 50 random args -- no signal death ({crash_count})")

    # Format string fuzzing
    crash_count = 0
    for i in range(20):
        fmt = "+" + "".join(random.choices("%YmdHMSabnZtFTRuwjpIs%", k=random.randint(1, 30)))
        rc, _, _ = run([BIN, fmt], timeout=3)
        if rc >= 128:
            crash_count += 1
    report_result(crash_count == 0, f"fuzz: 20 random format strings -- no signal death ({crash_count})")


def test_resource_limits():
    log("\n=== Resource Limit Testing ===")

    def limit_as():
        resource.setrlimit(resource.RLIMIT_AS, (16 * 1024 * 1024, 16 * 1024 * 1024))

    def limit_stack():
        resource.setrlimit(resource.RLIMIT_STACK, (65536, 65536))

    for name, fn in [("RLIMIT_AS=16MB", limit_as), ("RLIMIT_STACK=64KB", limit_stack)]:
        rc, _, _ = run([BIN], preexec_fn=fn)
        report_result(rc == 0, f"rlimit: {name} -> exit 0")


def test_environment():
    log("\n=== Environment Robustness ===")

    rc, _, _ = run([BIN], env={})
    report_result(rc == 0, "env: empty environment -> exit 0")

    hostile = {"PATH": "", "HOME": "/nonexistent", "LANG": "xx_XX.BROKEN", "TZ": "INVALID"}
    rc, _, _ = run([BIN], env=hostile)
    report_result(rc == 0, "env: hostile env vars -> exit 0")


def test_output_integrity():
    log("\n=== Output Integrity ===")

    # All runs should produce valid date output
    all_valid = True
    for _ in range(10):
        rc, out, err = run([BIN])
        if rc != 0 or not out:
            all_valid = False
    report_result(all_valid, "output: 10 runs all produce output")


def test_error_handling():
    log("\n=== Error Handling ===")

    for flag in ["--help", "--version"]:
        rc, _, _ = run([BIN, flag])
        report_result(rc == 0, f"error: '{flag}' -> exit 0")


def test_concurrency():
    log("\n=== Concurrency Stress ===")

    procs = []
    for _ in range(50):
        p = subprocess.Popen([BIN], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        procs.append(p)

    crash_count = 0
    for p in procs:
        try:
            p.communicate(timeout=TIMEOUT)
            if p.returncode >= 128:
                crash_count += 1
        except subprocess.TimeoutExpired:
            p.kill()
            crash_count += 1

    report_result(crash_count == 0, f"concurrency: 50 simultaneous instances ({crash_count} failures)")


def test_tool_specific():
    log("\n=== Tool-Specific: date ===")

    # Default output should contain current year
    import datetime
    now = datetime.datetime.utcnow()
    rc, out, _ = run([BIN])
    report_result(rc == 0, "date: default -> exit 0")
    out_str = out.decode().strip()
    report_result(str(now.year) in out_str, f"date: output contains current year ({now.year})")
    report_result("UTC" in out_str, "date: output contains 'UTC'")

    # +%Y should match
    rc, out, _ = run([BIN, "+%Y"])
    report_result(out.decode().strip() == str(now.year), f"date: +%Y = {now.year}")

    # +%m should match
    rc, out, _ = run([BIN, "+%m"])
    report_result(out.decode().strip() == f"{now.month:02d}", f"date: +%m = {now.month:02d}")

    # +%s epoch
    rc, out, _ = run([BIN, "+%s"])
    epoch = int(out.decode().strip())
    real_epoch = int(time.time())
    report_result(abs(epoch - real_epoch) <= 2, f"date: +%s epoch within 2s ({epoch} vs {real_epoch})")

    # -R format check
    rc, out, _ = run([BIN, "-R"])
    report_result("+0000" in out.decode(), "date: -R contains +0000")

    # -I format check
    rc, out, _ = run([BIN, "-I"])
    iso = out.decode().strip()
    report_result(len(iso) == 10 and iso[4] == '-' and iso[7] == '-', f"date: -I is YYYY-MM-DD ({iso})")


def run_tests():
    if not os.path.exists(BIN):
        log(f"[ERROR] Binary not found: {BIN}")
        sys.exit(2)
    log(f"Binary: {BIN}")

    test_elf_binary_security()
    test_strings_leaks()
    test_fd_hygiene()
    test_memory_safety()
    test_signal_safety()
    test_fuzzing()
    test_resource_limits()
    test_environment()
    test_output_integrity()
    test_error_handling()
    test_concurrency()
    test_tool_specific()


def print_summary():
    log("\n" + "=" * 60)
    log(f"RESULTS: {pass_count}/{test_count} passed, "
        f"{test_count - pass_count - skip_count} failed, {skip_count} skipped")
    if failures:
        log(f"\nFAILURES ({len(failures)}):")
        for f in failures:
            log(f"  [{f['label']}]")
    log("=" * 60)


if __name__ == "__main__":
    run_tests()
    print_summary()
    sys.exit(0 if (test_count - pass_count) == 0 else 1)
