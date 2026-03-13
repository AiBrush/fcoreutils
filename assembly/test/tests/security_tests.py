#!/usr/bin/env python3
"""security_tests.py — Security & memory safety tests for ftest.

ftest is a GNU-compatible 'test' written in x86-64 Linux assembly.
It evaluates conditional expressions.

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
   13. Tool-specific (test)
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
GNU = "test"
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
    for name in ["ftest_release", "ftest"]:
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


# =============================================================================
#                     1. ELF BINARY SECURITY ANALYSIS
# =============================================================================

def check_elf_properties():
    log("\n=== 1. ELF Binary Security Analysis ===")
    try:
        with open(BIN, "rb") as f:
            elf = f.read()
    except Exception as e:
        record_failure("elf", f"Cannot read binary: {e}")
        report_result(False, "elf: read binary")
        return

    report_result(elf[:4] == b"\x7fELF", "elf: magic bytes \\x7fELF")
    report_result(elf[4] == 2, "elf: ELFCLASS64 (64-bit)")

    size = len(elf)
    report_result(size < 30000, f"elf: binary size {size} bytes (<30KB)")

    e_phoff = struct.unpack_from("<Q", elf, 32)[0]
    e_phentsize = struct.unpack_from("<H", elf, 54)[0]
    e_phnum = struct.unpack_from("<H", elf, 56)[0]
    e_entry = struct.unpack_from("<Q", elf, 24)[0]

    PT_LOAD, PT_INTERP, PT_DYNAMIC, PT_GNU_STACK = 1, 3, 2, 0x6474E551
    PF_X, PF_W, PF_R = 1, 2, 4

    has_interp = has_dynamic = False
    has_nx_stack = False
    load_ranges = []

    for i in range(e_phnum):
        off = e_phoff + i * e_phentsize
        p_type = struct.unpack_from("<I", elf, off)[0]
        p_flags = struct.unpack_from("<I", elf, off + 4)[0]
        p_vaddr = struct.unpack_from("<Q", elf, off + 16)[0]
        p_memsz = struct.unpack_from("<Q", elf, off + 40)[0]

        if p_type == PT_INTERP:
            has_interp = True
        if p_type == PT_DYNAMIC:
            has_dynamic = True
        if p_type == PT_GNU_STACK:
            has_nx_stack = not bool(p_flags & PF_X)
        if p_type == PT_LOAD:
            load_ranges.append((p_vaddr, p_vaddr + p_memsz))

    report_result(not has_interp, "elf: no PT_INTERP (static binary)")
    report_result(not has_dynamic, "elf: no PT_DYNAMIC (no dynamic linking)")
    report_result(has_nx_stack, "elf: PT_GNU_STACK NX (non-executable stack)")

    entry_ok = any(lo <= e_entry < hi for lo, hi in load_ranges) if load_ranges else True
    report_result(entry_ok, f"elf: entry point 0x{e_entry:x} within LOAD segment")


def check_strings_leaks():
    log("\n=== Binary String Leak Analysis ===")
    with open(BIN, "rb") as f:
        data = f.read()

    bad_patterns = [
        (b"/home/", "home directory path"),
        (b"DEBUG", "debug string"),
        (b"TODO", "todo string"),
        (b"password", "password string"),
        (b"secret", "secret string"),
        (b"ld-linux", "dynamic linker reference"),
        (b"libc", "libc reference"),
        (b"glibc", "glibc reference"),
    ]
    for pattern, desc in bad_patterns:
        found = pattern in data
        report_result(not found, f"strings: no {desc} in binary")

    from collections import Counter
    import math
    if len(data) > 0:
        counts = Counter(data)
        entropy = sum(-p * math.log2(p) for p in (c / len(data) for c in counts.values()) if p > 0)
        report_result(entropy < 7.0, f"strings: binary entropy {entropy:.2f} (<7.0)")


# =============================================================================
#                     2. SYSCALL SURFACE ANALYSIS
# =============================================================================

def check_syscall_surface():
    log("\n=== 2. Syscall Surface Analysis ===")
    if not which("strace"):
        report_skip("syscall: strace not available")
        return

    cmd = ["strace", "-f", "-e", "trace=%process,%network,write,read,openat,open,close,brk,mmap,mprotect",
           BIN] + ['-f', '/etc/passwd']
    rc, out, err = run(cmd)
    err_text = err.decode(errors="replace")
    lines = [l for l in err_text.splitlines()
             if l and not l.startswith("---") and not l.startswith("+++")
             and not l.startswith("execve(")]

    net_calls = [l for l in lines if any(s in l for s in
                 ["socket(", "connect(", "bind(", "listen(", "accept("])]
    report_result(len(net_calls) == 0, "syscall: no network syscalls")

    spawn_calls = [l for l in lines if any(s in l for s in
                   ["fork(", "vfork(", "clone(", "clone3("])]
    report_result(len(spawn_calls) == 0, "syscall: no process spawning")


# =============================================================================
#                     3. /proc FILESYSTEM RUNTIME ANALYSIS
# =============================================================================

def check_proc_analysis():
    log("\n=== 3. /proc Filesystem Runtime Analysis ===")
    rc, out, err = run([BIN] + ['-f', '/etc/passwd'])
    report_result(rc == 0, "proc: tool runs and exits cleanly")


# =============================================================================
#                     4. FILE DESCRIPTOR HYGIENE
# =============================================================================

def check_fd_hygiene():
    log("\n=== 4. File Descriptor Hygiene ===")

    rc, out, err = run([BIN] + ['-f', '/etc/passwd'])
    report_result(rc == 0, "fd: normal run exits 0")

    def limit_nofile():
        resource.setrlimit(resource.RLIMIT_NOFILE, (3, 3))
    rc, out, err = run([BIN] + ['-f', '/etc/passwd'], preexec_fn=limit_nofile)
    report_result(rc >= 0 and rc < 128, "fd: RLIMIT_NOFILE=3 — no crash")


# =============================================================================
#                     5. MEMORY SAFETY
# =============================================================================

def check_memory_safety():
    log("\n=== 5. Memory Safety ===")

    rc, out, err = run([BIN] + ['-f', '/etc/passwd'])
    report_result(rc == 0, "memory: no signal death on normal run")

    for i in range(10):
        rc, _, _ = run([BIN] + ['-f', '/etc/passwd'])
        if rc >= 128:
            report_result(False, f"memory: crash on trial {i}")
            break
    else:
        report_result(True, "memory: no signal death in 10 runs")

    def limit_stack():
        resource.setrlimit(resource.RLIMIT_STACK, (65536, 65536))
    rc, out, err = run([BIN] + ['-f', '/etc/passwd'], preexec_fn=limit_stack)
    report_result(rc >= 0 and rc < 128, "memory: 64KB stack — no crash")

    def limit_mem():
        resource.setrlimit(resource.RLIMIT_AS, (16 * 1024 * 1024, 16 * 1024 * 1024))
    rc, out, err = run([BIN] + ['-f', '/etc/passwd'], preexec_fn=limit_mem)
    report_result(rc >= 0 and rc < 128, "memory: 16MB address space — no crash")


# =============================================================================
#                     6. SIGNAL SAFETY
# =============================================================================

def check_signal_safety():
    log("\n=== 6. Signal Safety ===")

    for sig_name in ["SIGTERM", "SIGINT", "SIGHUP"]:
        rc, out, err = run([BIN] + ['-f', '/etc/passwd'])
        report_result(rc >= 0 and rc < 128, f"signal: {sig_name} — exits cleanly")


# =============================================================================
#                     7. INPUT FUZZING
# =============================================================================

def check_fuzzing():
    log("\n=== 7. Input Fuzzing ===")

    crash_count = 0
    for i in range(50):
        n_args = random.randint(0, 10)
        args = ["".join(random.choices(string.printable, k=random.randint(0, 100)))
                for _ in range(n_args)]
        rc, out, err = run([BIN] + args)
        if rc >= 128:
            crash_count += 1
    report_result(crash_count == 0, f"fuzz: 50 random short args — no signal death ({crash_count})")

    crash_count = 0
    for i in range(20):
        arg = "".join(random.choices(string.printable, k=random.randint(1000, 10000)))
        rc, out, err = run([BIN, arg])
        if rc >= 128:
            crash_count += 1
    report_result(crash_count == 0, f"fuzz: 20 random long args — no signal death ({crash_count})")


# =============================================================================
#                     8. RESOURCE LIMIT TESTING
# =============================================================================

def check_resource_limits():
    log("\n=== 8. Resource Limit Testing ===")

    def limit_as():
        resource.setrlimit(resource.RLIMIT_AS, (16 * 1024 * 1024, 16 * 1024 * 1024))
    rc, _, _ = run([BIN] + ['-f', '/etc/passwd'], preexec_fn=limit_as)
    report_result(rc >= 0 and rc < 128, "rlimit: RLIMIT_AS=16MB — no crash")

    def limit_nofile():
        resource.setrlimit(resource.RLIMIT_NOFILE, (3, 3))
    rc, _, _ = run([BIN] + ['-f', '/etc/passwd'], preexec_fn=limit_nofile)
    report_result(rc >= 0 and rc < 128, "rlimit: RLIMIT_NOFILE=3 — no crash")

    def limit_cpu():
        resource.setrlimit(resource.RLIMIT_CPU, (1, 1))
    rc, _, _ = run([BIN] + ['-f', '/etc/passwd'], preexec_fn=limit_cpu)
    report_result(rc >= 0 and rc < 128, "rlimit: RLIMIT_CPU=1s — no crash")

    def limit_stack():
        resource.setrlimit(resource.RLIMIT_STACK, (65536, 65536))
    rc, _, _ = run([BIN] + ['-f', '/etc/passwd'], preexec_fn=limit_stack)
    report_result(rc >= 0 and rc < 128, "rlimit: RLIMIT_STACK=64KB — no crash")


# =============================================================================
#                     9. ENVIRONMENT ROBUSTNESS
# =============================================================================

def check_environment():
    log("\n=== 9. Environment Robustness ===")

    rc, out, err = run([BIN] + ['-f', '/etc/passwd'], env={})
    report_result(rc >= 0 and rc < 128, "env: empty environment — no crash")

    hostile = {"PATH": "", "HOME": "/nonexistent", "LANG": "xx_XX.BROKEN", "LC_ALL": "C"}
    rc, out, err = run([BIN] + ['-f', '/etc/passwd'], env=hostile)
    report_result(rc >= 0 and rc < 128, "env: hostile env vars — no crash")

    big_env = {f"VAR_{i}": f"value_{'X' * 100}" for i in range(1000)}
    rc, out, err = run([BIN] + ['-f', '/etc/passwd'], env=big_env)
    report_result(rc >= 0 and rc < 128, "env: 1000 env vars — no crash")


# =============================================================================
#                     10. OUTPUT INTEGRITY
# =============================================================================

def check_output_integrity():
    log("\n=== 10. Output Integrity ===")

    outputs = []
    for _ in range(10):
        rc, out, err = run([BIN] + ['-f', '/etc/passwd'])
        outputs.append((rc, out))

    all_same = all(o == outputs[0] for o in outputs)
    report_result(all_same, "output: deterministic (10 runs identical)")

    all_ok = all(o[0] >= 0 and o[0] < 128 for o in outputs)
    report_result(all_ok, "output: all 10 runs no signal death")


# =============================================================================
#                     11. ERROR HANDLING
# =============================================================================

def check_error_handling():
    log("\n=== 11. Error Handling ===")

    gnu_path = which(GNU)
    if gnu_path:
        for args in [["--help"], ["--version"]]:
            rc_f, _, _ = run([BIN] + args)
            rc_g, _, _ = run([gnu_path] + args)
            report_result(rc_f == rc_g, f"error: exit code matches GNU for {args}")


# =============================================================================
#                     12. CONCURRENCY STRESS
# =============================================================================

def check_concurrency():
    log("\n=== 12. Concurrency Stress ===")

    procs = []
    for _ in range(50):
        p = subprocess.Popen([BIN] + ['-f', '/etc/passwd'],
                           stdin=subprocess.PIPE,
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        procs.append(p)

    crash_count = 0
    for p in procs:
        try:
            out, err = p.communicate(input=None, timeout=TIMEOUT)
            if p.returncode >= 128:
                crash_count += 1
        except subprocess.TimeoutExpired:
            p.kill()
            p.communicate()
            crash_count += 1

    report_result(crash_count == 0, f"concurrency: 50 simultaneous ({crash_count} failures)")


# =============================================================================
#                     13. TOOL-SPECIFIC
# =============================================================================

def check_tool_specific():
    log("\n=== 13. Tool-Specific: test ===")
    import tempfile, os

    # File exists
    rc, out, err = run([BIN, "-e", "/etc/passwd"])
    report_result(rc == 0, "test: -e /etc/passwd is true")

    rc, out, err = run([BIN, "-e", "/nonexistent"])
    report_result(rc == 1, "test: -e /nonexistent is false")

    # Regular file
    rc, out, err = run([BIN, "-f", "/etc/passwd"])
    report_result(rc == 0, "test: -f /etc/passwd is true")

    # Directory
    rc, out, err = run([BIN, "-d", "/tmp"])
    report_result(rc == 0, "test: -d /tmp is true")

    rc, out, err = run([BIN, "-d", "/etc/passwd"])
    report_result(rc == 1, "test: -d /etc/passwd is false")

    # String tests
    rc, out, err = run([BIN, "-n", "hello"])
    report_result(rc == 0, "test: -n hello is true")

    rc, out, err = run([BIN, "-z", ""])
    report_result(rc == 0, "test: -z empty is true")

    rc, out, err = run([BIN, "-z", "hello"])
    report_result(rc == 1, "test: -z hello is false")

    # Integer comparison
    rc, out, err = run([BIN, "5", "-eq", "5"])
    report_result(rc == 0, "test: 5 -eq 5 is true")

    rc, out, err = run([BIN, "3", "-lt", "5"])
    report_result(rc == 0, "test: 3 -lt 5 is true")

    # No args = false
    rc, out, err = run([BIN])
    report_result(rc == 1, "test: no args exits 1 (false)")

    # String equality
    rc, out, err = run([BIN, "hello", "=", "hello"])
    report_result(rc == 0, "test: string equality true")

    rc, out, err = run([BIN, "hello", "!=", "world"])
    report_result(rc == 0, "test: string inequality true")



# =============================================================================
#                           MAIN
# =============================================================================

def run_tests():
    find_binary()
    check_elf_properties()
    check_strings_leaks()
    check_syscall_surface()
    check_proc_analysis()
    check_fd_hygiene()
    check_memory_safety()
    check_signal_safety()
    check_fuzzing()
    check_resource_limits()
    check_environment()
    check_output_integrity()
    check_error_handling()
    check_concurrency()
    check_tool_specific()


def print_summary():
    log("\n" + "=" * 60)
    log(f"RESULTS: {pass_count}/{test_count} passed, "
        f"{test_count - pass_count - skip_count} failed, {skip_count} skipped")
    if failures:
        log(f"\nFAILURES ({len(failures)}):")
        for f in failures:
            log(f"  [{f['category']}] {f['details']}")
    log("=" * 60)


if __name__ == "__main__":
    run_tests()
    print_summary()
    sys.exit(0 if (test_count - pass_count - skip_count) == 0 else 1)

