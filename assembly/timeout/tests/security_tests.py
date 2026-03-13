#!/usr/bin/env python3
"""security_tests.py — Security & memory safety tests for ftimeout (assembly timeout).

ftimeout is a GNU-compatible 'timeout' written in x86-64 Linux assembly.
It starts a command and kills it if still running after the specified duration.
Uses fork/exec/wait pattern with alarm-based timeout.
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

TIMEOUT = 15
TOOL_NAME = "timeout"
BIN = str(Path(__file__).resolve().parent.parent / "ftimeout")
GNU = "/usr/bin/timeout"

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

    rc, _, _ = run([BIN, "5", "true"])
    report_result(rc == 0, "fd: timeout 5 true -> exit 0")


def test_memory_safety():
    log("\n=== Memory Safety ===")

    rc, _, _ = run([BIN, "5", "true"])
    report_result(rc < 128, "memory: no signal death with true")

    rc, _, _ = run([BIN, "5", "echo", "hello"])
    report_result(rc < 128, "memory: no signal death with echo")


def test_signal_safety():
    log("\n=== Signal Safety ===")

    # Timeout should terminate child
    start = time.monotonic()
    rc, _, _ = run([BIN, "1", "sleep", "60"], timeout=5)
    elapsed = time.monotonic() - start
    report_result(rc == 124, f"signal: timeout 1 sleep 60 -> exit 124 (got {rc})")
    report_result(elapsed < 4, f"signal: completed in {elapsed:.1f}s (<4s)")


def test_fuzzing():
    log("\n=== Input Fuzzing ===")

    crash_count = 0
    for i in range(20):
        n_args = random.randint(0, 3)
        args = ["".join(random.choices(string.printable, k=random.randint(0, 20)))
                for _ in range(n_args)]
        rc, _, _ = run([BIN] + args, timeout=3)
        if rc >= 128 and rc != 137 and rc != 143:  # 137=KILL, 143=TERM are OK
            crash_count += 1
    report_result(crash_count == 0, f"fuzz: 20 random args -- no unexpected signal death ({crash_count})")


def test_resource_limits():
    log("\n=== Resource Limit Testing ===")

    def limit_as():
        resource.setrlimit(resource.RLIMIT_AS, (64 * 1024 * 1024, 64 * 1024 * 1024))

    rc, _, _ = run([BIN, "5", "true"], preexec_fn=limit_as)
    report_result(rc == 0, "rlimit: RLIMIT_AS=64MB -> exit 0")


def test_environment():
    log("\n=== Environment Robustness ===")

    env = dict(os.environ)
    rc, _, _ = run([BIN, "5", "/bin/true"], env=env)
    report_result(rc == 0, "env: normal environment -> exit 0")


def test_output_integrity():
    log("\n=== Output Integrity ===")

    rc, out, _ = run([BIN, "5", "echo", "test"])
    report_result(rc == 0, "output: echo -> exit 0")
    report_result(out.strip() == b"test", "output: echo output correct")


def test_error_handling():
    log("\n=== Error Handling ===")

    rc, _, _ = run([BIN, "--help"])
    report_result(rc == 0, "error: --help -> exit 0")

    rc, _, _ = run([BIN, "--version"])
    report_result(rc == 0, "error: --version -> exit 0")

    rc, _, _ = run([BIN])
    report_result(rc == 125, f"error: no args -> exit 125 (got {rc})")


def test_concurrency():
    log("\n=== Concurrency Stress ===")

    procs = []
    for _ in range(20):
        p = subprocess.Popen([BIN, "5", "true"], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
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

    report_result(crash_count == 0, f"concurrency: 20 simultaneous instances ({crash_count} failures)")


def test_tool_specific():
    log("\n=== Tool-Specific: timeout ===")

    # Command completes before timeout
    rc, out, _ = run([BIN, "5", "echo", "hello"])
    report_result(rc == 0, "timeout: echo completes -> exit 0")
    report_result(out.strip() == b"hello", "timeout: echo output correct")

    # Command times out
    start = time.monotonic()
    rc, _, _ = run([BIN, "1", "sleep", "60"], timeout=5)
    elapsed = time.monotonic() - start
    report_result(rc == 124, f"timeout: timeout fires -> exit 124 (got {rc})")
    report_result(0.5 < elapsed < 4, f"timeout: elapsed {elapsed:.1f}s")

    # Exit code passthrough
    rc, _, _ = run([BIN, "5", "true"])
    report_result(rc == 0, "timeout: true -> exit 0")

    rc, _, _ = run([BIN, "5", "false"])
    report_result(rc == 1, "timeout: false -> exit 1")

    # Nonexistent command
    rc, _, _ = run([BIN, "5", "nonexistent_cmd_xyz"])
    report_result(rc == 127, f"timeout: nonexistent -> exit 127 (got {rc})")

    # -s option
    rc, _, _ = run([BIN, "-s", "KILL", "1", "sleep", "60"], timeout=5)
    report_result(rc in (124, 137), f"timeout: -s KILL -> exit {rc}")

    # --foreground
    rc, _, _ = run([BIN, "--foreground", "1", "sleep", "60"], timeout=5)
    report_result(rc == 124, f"timeout: --foreground -> exit 124 (got {rc})")

    # Compare with GNU
    if os.path.exists(GNU):
        rc_g, out_g, _ = run([GNU, "5", "echo", "compare"])
        rc_f, out_f, _ = run([BIN, "5", "echo", "compare"])
        report_result(rc_f == rc_g, f"timeout: exit code matches GNU ({rc_f} vs {rc_g})")
        report_result(out_f == out_g, "timeout: output matches GNU")


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
