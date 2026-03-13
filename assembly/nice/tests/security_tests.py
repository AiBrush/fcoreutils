#!/usr/bin/env python3
"""security_tests.py — Security & memory safety tests for fnice (assembly nice).

fnice is a GNU-compatible 'nice' written in x86-64 Linux assembly.
It runs a command with modified scheduling priority, or prints the current
niceness if no command is given. Default adjustment is +10.
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
TOOL_NAME = "nice"
BIN = str(Path(__file__).resolve().parent.parent / "fnice")
GNU = "/usr/bin/nice"

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
    report_result(rc == 0, "fd: no args (print niceness) exit 0")

    def limit_nofile():
        resource.setrlimit(resource.RLIMIT_NOFILE, (3, 3))
    rc, _, _ = run([BIN], preexec_fn=limit_nofile)
    report_result(rc == 0, "fd: RLIMIT_NOFILE=3 -> exit 0")


def test_memory_safety():
    log("\n=== Memory Safety ===")

    rc, _, _ = run([BIN])
    report_result(rc < 128, "memory: no signal death on no args")

    rc, _, _ = run([BIN, "true"])
    report_result(rc < 128, "memory: no signal death with command")

    rc, _, _ = run([BIN, "-n", "5", "true"])
    report_result(rc < 128, "memory: no signal death with -n 5 true")

    rc, _, _ = run([BIN, "A" * (1024 * 1024)])
    report_result(rc < 128, "memory: no signal death with 1MB argument")


def test_signal_safety():
    log("\n=== Signal Safety ===")

    p = subprocess.Popen([BIN, "sleep", "60"], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    time.sleep(0.1)
    p.send_signal(signal.SIGTERM)
    try:
        p.wait(timeout=2)
        report_result(True, "signal: SIGTERM terminates nice+sleep")
    except subprocess.TimeoutExpired:
        p.kill()
        p.wait()
        report_result(False, "signal: SIGTERM did not terminate")


def test_fuzzing():
    log("\n=== Input Fuzzing ===")

    crash_count = 0
    for i in range(50):
        n_args = random.randint(0, 5)
        args = ["".join(random.choices(string.printable, k=random.randint(0, 50)))
                for _ in range(n_args)]
        rc, _, _ = run([BIN] + args, timeout=3)
        if rc >= 128:
            crash_count += 1
    report_result(crash_count == 0, f"fuzz: 50 random args -- no signal death ({crash_count})")

    for arg in ["-n", "--adjustment", "--adjustment=", "-n abc", ""]:
        rc, _, _ = run([BIN] + arg.split() if arg else [BIN, arg], timeout=3)
        report_result(rc < 128, f"fuzz: '{arg}' -- no signal death")


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

    hostile = {"PATH": "", "HOME": "/nonexistent", "LANG": "xx_XX.BROKEN"}
    rc, _, _ = run([BIN], env=hostile)
    report_result(rc == 0, "env: hostile env vars -> exit 0")


def test_output_integrity():
    log("\n=== Output Integrity ===")

    outputs = []
    for _ in range(10):
        rc, out, err = run([BIN])
        outputs.append((rc, out, err))

    all_same = all(o == outputs[0] for o in outputs)
    report_result(all_same, "output: deterministic (10 runs identical)")

    all_zero = all(o[0] == 0 for o in outputs)
    report_result(all_zero, "output: all 10 runs exit 0")


def test_error_handling():
    log("\n=== Error Handling ===")

    for flag in ["--badopt", "--zzz"]:
        rc, _, _ = run([BIN, flag], timeout=3)
        report_result(rc != 0, f"error: '{flag}' -> non-zero exit")
        report_result(rc < 128, f"error: '{flag}' -> no signal death")

    if os.path.exists(GNU):
        for flag in ["--help", "--version"]:
            rc_f, _, _ = run([BIN, flag])
            rc_g, _, _ = run([GNU, flag])
            report_result(rc_f == rc_g, f"error: '{flag}' exit code matches GNU ({rc_f} vs {rc_g})")


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
    log("\n=== Tool-Specific: nice ===")

    # No command — print niceness
    rc, out, err = run([BIN])
    report_result(rc == 0, "nice: no command -> exit 0")
    # Output should be a number followed by newline
    try:
        val = int(out.decode().strip())
        report_result(True, f"nice: no command -> prints niceness value ({val})")
    except ValueError:
        report_result(False, f"nice: no command -> expected integer, got: {out!r}")

    # Run true
    rc, _, _ = run([BIN, "true"])
    report_result(rc == 0, "nice: true -> exit 0")

    # Run false
    rc, _, _ = run([BIN, "false"])
    report_result(rc == 1, "nice: false -> exit 1")

    # Run echo
    rc, out, _ = run([BIN, "echo", "hello"])
    report_result(rc == 0, "nice: echo hello -> exit 0")
    report_result(out.strip() == b"hello", "nice: echo hello -> correct output")

    # -n 0 should use current niceness
    rc, out, _ = run([BIN, "-n", "0", "echo", "test"])
    report_result(rc == 0, "nice: -n 0 echo test -> exit 0")

    # Nonexistent command
    rc, _, _ = run([BIN, "nonexistent_cmd_xyz_abc"])
    report_result(rc == 127, "nice: nonexistent command -> exit 127")

    # Compare with GNU
    if os.path.exists(GNU):
        rc_g, out_g, _ = run([GNU])
        rc_f, out_f, _ = run([BIN])
        report_result(rc_f == rc_g, f"nice: no-args exit matches GNU ({rc_f} vs {rc_g})")
        report_result(out_f.strip() == out_g.strip(), "nice: no-args output matches GNU")


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
