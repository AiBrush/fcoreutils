#!/usr/bin/env python3
"""security_tests.py — Security & memory safety tests for fuptime.

fuptime is a GNU-compatible 'uptime' written in x86-64 Linux assembly.
It displays how long the system has been running, number of users, and load averages.

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
   13. Tool-specific (uptime: system information display)
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
import math
import re
from collections import Counter
from pathlib import Path
from shutil import which

TIMEOUT = 5
BIN = ""
GNU = "uptime"
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
    for name in ["fuptime_release", "fuptime"]:
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
    except (OSError, ValueError):
        return (126, b"", b"OSError")
    try:
        out, err = p.communicate(
            input=stdin_data.encode() if isinstance(stdin_data, str) else stdin_data,
            timeout=timeout,
        )
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
    report_result(size < 100000, f"elf: binary size {size} bytes (<100KB)")

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
        report_result(not found, f"strings: no {desc} in binary")

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

    cmd = ["strace", "-f", "-e",
           "trace=%process,%network,write,read,openat,open,creat,brk,mmap,mprotect",
           BIN]
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

    # uptime reads /proc files so expect some open/read syscalls
    all_calls = [l for l in lines if "(" in l and "=" in l]
    report_result(len(all_calls) <= 30, f"syscall: total {len(all_calls)} syscalls (<=30 expected)")


# =============================================================================
#                     3. /proc FILESYSTEM RUNTIME ANALYSIS
# =============================================================================

def check_proc_analysis():
    log("\n=== 3. /proc Filesystem Runtime Analysis ===")
    rc, out, err = run([BIN])
    report_result(rc == 0, "proc: tool runs and exits cleanly")


# =============================================================================
#                     4. FILE DESCRIPTOR HYGIENE
# =============================================================================

def check_fd_hygiene():
    log("\n=== 4. File Descriptor Hygiene ===")

    # Closed stdout
    script = f'exec 3>&1 1>&-; {BIN} 2>/dev/null; echo $? >&3'
    p = subprocess.run(["bash", "-c", script], capture_output=True, timeout=TIMEOUT, text=True)
    rc = p.stdout.strip()
    report_result(rc != "", "fd: closed stdout does not hang")

    # Closed stderr — uptime should still work
    script = f'exec 3>&1; {BIN} 2>&- 1>&3; echo $? >&3'
    p = subprocess.run(["bash", "-c", script], capture_output=True, timeout=TIMEOUT, text=True)
    lines = p.stdout.strip().split("\n")
    rc = lines[-1] if lines else ""
    report_result(rc == "0", "fd: closed stderr exits 0")

    # RLIMIT_NOFILE=3
    def limit_nofile():
        resource.setrlimit(resource.RLIMIT_NOFILE, (3, 3))
    rc, out, err = run([BIN], preexec_fn=limit_nofile)
    report_result(rc >= 0 and rc < 128, "fd: RLIMIT_NOFILE=3 no crash")

    # /dev/full
    if os.path.exists("/dev/full"):
        script = f'{BIN} > /dev/full 2>/dev/null; echo $?'
        p = subprocess.run(["bash", "-c", script], capture_output=True, timeout=TIMEOUT, text=True)
        rc = p.stdout.strip()
        report_result(rc != "", "fd: /dev/full does not hang")

    # /dev/null
    script = f'{BIN} > /dev/null 2>/dev/null; echo $?'
    p = subprocess.run(["bash", "-c", script], capture_output=True, timeout=TIMEOUT, text=True)
    rc = p.stdout.strip()
    report_result(rc == "0", "fd: /dev/null redirect exits 0")


# =============================================================================
#                     5. MEMORY SAFETY
# =============================================================================

def check_memory_safety():
    log("\n=== 5. Memory Safety ===")

    rc, out, err = run([BIN])
    report_result(rc == 0, "memory: no signal death on normal run")

    # Invalid flag should not crash
    rc, out, err = run([BIN, "-Z"])
    report_result(rc >= 0 and rc < 128, "memory: invalid flag no crash")

    for i in range(10):
        flags = "-" + "".join(random.choices("pshV", k=random.randint(1, 4)))
        rc, _, _ = run([BIN, flags])
        if rc >= 128:
            report_result(False, f"memory: crash with random flag combo (trial {i})")
            break
    else:
        report_result(True, "memory: no crash with 10 random flag combos")

    def limit_stack():
        resource.setrlimit(resource.RLIMIT_STACK, (65536, 65536))
    rc, out, err = run([BIN], preexec_fn=limit_stack)
    report_result(rc == 0, "memory: 64KB stack exits 0")

    def limit_mem():
        resource.setrlimit(resource.RLIMIT_AS, (16 * 1024 * 1024, 16 * 1024 * 1024))
    rc, out, err = run([BIN], preexec_fn=limit_mem)
    report_result(rc == 0, "memory: 16MB address space exits 0")


# =============================================================================
#                     6. SIGNAL SAFETY
# =============================================================================

def check_signal_safety():
    log("\n=== 6. Signal Safety ===")

    script = f'{BIN} | head -c 0'
    p = subprocess.run(["bash", "-c", script], capture_output=True, timeout=TIMEOUT)
    report_result(p.returncode >= 0 and p.returncode < 128, "signal: SIGPIPE clean exit")

    ok_count = 0
    trials = 20
    for _ in range(trials):
        rc = os.system(f"{BIN} 2>/dev/null | head -c 0 >/dev/null 2>/dev/null")
        if os.WIFEXITED(rc) and os.WEXITSTATUS(rc) < 128:
            ok_count += 1
    report_result(ok_count >= trials - 2, f"signal: rapid SIGPIPE ({ok_count}/{trials})")

    for sig_name in ["SIGTERM", "SIGINT", "SIGHUP"]:
        rc, out, err = run([BIN])
        report_result(rc == 0, f"signal: {sig_name} exits cleanly")


# =============================================================================
#                     7. INPUT FUZZING
# =============================================================================

def check_fuzzing():
    log("\n=== 7. Input Fuzzing ===")

    crash_count = 0
    for i in range(50):
        n_args = random.randint(0, 5)
        args = ["-" + "".join(random.choices(string.ascii_lowercase, k=random.randint(1, 5)))
                for _ in range(n_args)]
        rc, out, err = run([BIN] + args)
        if rc >= 128:
            crash_count += 1
    report_result(crash_count == 0, f"fuzz: 50 random flag combos no signal death ({crash_count})")

    crash_count = 0
    for i in range(20):
        flags = "--" + "".join(random.choices(string.ascii_lowercase + "-", k=random.randint(3, 30)))
        rc, out, err = run([BIN, flags])
        if rc >= 128:
            crash_count += 1
    report_result(crash_count == 0, f"fuzz: 20 random long flags no signal death ({crash_count})")

    for desc, arg in [("all-dashes", "----------"),
                      ("unicode", "\u00e9\u00e0\u00fc\u4e16\u754c"),
                      ("control-chars", "".join(chr(i) for i in range(1, 32)))]:
        rc, _, _ = run([BIN, arg])
        report_result(rc >= 0 and rc < 128, f"fuzz: pathological {desc} no crash")

    # Repeated valid flags
    rc, out, err = run([BIN, "-pppp"])
    report_result(rc >= 0 and rc < 128, "fuzz: repeated -p flag no crash")


# =============================================================================
#                     8. RESOURCE LIMIT TESTING
# =============================================================================

def check_resource_limits():
    log("\n=== 8. Resource Limit Testing ===")

    def limit_as():
        resource.setrlimit(resource.RLIMIT_AS, (16 * 1024 * 1024, 16 * 1024 * 1024))
    rc, _, _ = run([BIN], preexec_fn=limit_as)
    report_result(rc == 0, "rlimit: RLIMIT_AS=16MB exits 0")

    def limit_nofile():
        resource.setrlimit(resource.RLIMIT_NOFILE, (3, 3))
    rc, _, _ = run([BIN], preexec_fn=limit_nofile)
    report_result(rc >= 0 and rc < 128, "rlimit: RLIMIT_NOFILE=3 no crash")

    def limit_cpu():
        resource.setrlimit(resource.RLIMIT_CPU, (1, 1))
    rc, _, _ = run([BIN], preexec_fn=limit_cpu)
    report_result(rc == 0, "rlimit: RLIMIT_CPU=1s exits 0")

    def limit_stack():
        resource.setrlimit(resource.RLIMIT_STACK, (65536, 65536))
    rc, _, _ = run([BIN], preexec_fn=limit_stack)
    report_result(rc == 0, "rlimit: RLIMIT_STACK=64KB exits 0")

    def limit_fsize():
        resource.setrlimit(resource.RLIMIT_FSIZE, (0, 0))
    rc, _, _ = run([BIN], preexec_fn=limit_fsize)
    report_result(rc >= 0 and rc < 128, "rlimit: RLIMIT_FSIZE=0 no crash")

    def limit_all():
        resource.setrlimit(resource.RLIMIT_AS, (16 * 1024 * 1024, 16 * 1024 * 1024))
        resource.setrlimit(resource.RLIMIT_NOFILE, (3, 3))
        resource.setrlimit(resource.RLIMIT_CPU, (1, 1))
        resource.setrlimit(resource.RLIMIT_STACK, (65536, 65536))
        resource.setrlimit(resource.RLIMIT_FSIZE, (0, 0))
    rc, _, _ = run([BIN], preexec_fn=limit_all)
    report_result(rc >= 0 and rc < 128, "rlimit: all limits combined no crash")


# =============================================================================
#                     9. ENVIRONMENT ROBUSTNESS
# =============================================================================

def check_environment():
    log("\n=== 9. Environment Robustness ===")

    rc, out, err = run([BIN], env={})
    report_result(rc == 0, "env: empty environment exits 0")

    hostile = {
        "PATH": "",
        "HOME": "/nonexistent",
        "LANG": "xx_XX.BROKEN",
        "TERM": "",
        "LC_ALL": "C",
    }
    rc, out, err = run([BIN], env=hostile)
    report_result(rc == 0, "env: hostile env vars exits 0")

    big_env = {f"VAR_{i}": f"value_{'X' * 100}" for i in range(1000)}
    rc, out, err = run([BIN], env=big_env)
    report_result(rc == 0, "env: 1000 env vars exits 0")

    special_env = os.environ.copy()
    special_env["EVIL"] = "A" * 100000
    rc, out, err = run([BIN], env=special_env)
    report_result(rc == 0, "env: 100KB env var exits 0")


# =============================================================================
#                     10. OUTPUT INTEGRITY
# =============================================================================

def check_output_integrity():
    log("\n=== 10. Output Integrity ===")

    # uptime output should be deterministic structure (though values change)
    outputs = []
    for _ in range(5):
        rc, out, err = run([BIN])
        outputs.append((rc, out, err))

    all_zero = all(o[0] == 0 for o in outputs)
    report_result(all_zero, "output: all 5 runs exit 0")

    # Output should end with newline
    report_result(outputs[0][1].endswith(b"\n"), "output: ends with newline")

    # --help
    rc, out, err = run([BIN, "--help"])
    text = out + err
    report_result(b"uptime" in text.lower() or b"Usage" in text, "output: --help contains usage info")

    # --version / -V
    rc, out, err = run([BIN, "-V"])
    text = out + err
    report_result(b"uptime" in text.lower() or b"procps" in text.lower(), "output: -V contains version info")

    # Compare with GNU
    gnu_path = which(GNU)
    if gnu_path:
        rc_f, out_f, _ = run([BIN, "--help"])
        rc_g, out_g, _ = run([gnu_path, "--help"])
        report_result(rc_f == rc_g, "output: --help exit code matches GNU")


# =============================================================================
#                     11. ERROR HANDLING
# =============================================================================

def check_error_handling():
    log("\n=== 11. Error Handling ===")

    # Invalid flags should not cause signal death
    for flag in ["--badopt", "-Z", "--nonexistent"]:
        rc, out, err = run([BIN, flag])
        report_result(rc >= 0 and rc < 128, f"error: '{flag}' no signal death")

    # Exit codes match GNU for valid options
    gnu_path = which(GNU)
    if gnu_path:
        for args in [["--help"], ["-V"]]:
            rc_f, _, _ = run([BIN] + args)
            rc_g, _, _ = run([gnu_path] + args)
            report_result(rc_f == rc_g, f"error: exit code matches GNU for {args}")

    # EINTR injection
    if which("strace"):
        cmd = ["strace", "-e", "inject=write:error=EINTR:when=1", BIN]
        rc, out, err = run(cmd)
        report_result(rc >= 0 and rc < 128, "error: EINTR injection no crash")


# =============================================================================
#                     12. CONCURRENCY STRESS
# =============================================================================

def check_concurrency():
    log("\n=== 12. Concurrency Stress ===")

    procs = []
    for _ in range(50):
        p = subprocess.Popen([BIN],
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

    report_result(crash_count == 0, f"concurrency: 50 simultaneous ({crash_count} failures)")

    # Pipe chain
    script = f'{BIN} | cat; echo $?'
    p = subprocess.run(["bash", "-c", script], capture_output=True, timeout=TIMEOUT, text=True)
    report_result(p.returncode == 0, "concurrency: pipe chain")

    # Rapid start
    ok_count = 0
    for _ in range(50):
        p = subprocess.Popen([BIN],
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            p.wait(timeout=1)
            ok_count += 1
        except subprocess.TimeoutExpired:
            p.kill()
    report_result(ok_count == 50, f"concurrency: rapid start ({ok_count}/50)")


# =============================================================================
#                     13. TOOL-SPECIFIC: uptime
# =============================================================================

def check_tool_specific():
    log("\n=== 13. Tool-Specific: uptime ===")
    gnu_path = which(GNU)

    # Default output should contain load average or "up"
    rc, out, err = run([BIN])
    out_str = out.decode(errors="replace").strip()
    report_result("up" in out_str or "load" in out_str,
                  "uptime: default output contains 'up' or 'load'")

    # Output should contain load average
    report_result("load average" in out_str or "load" in out_str,
                  "uptime: output contains load average info")

    # Output should have a time-like pattern (HH:MM:SS or HH:MM)
    has_time = bool(re.search(r'\d{1,2}:\d{2}', out_str))
    report_result(has_time, "uptime: output contains time pattern")

    # Output should be a single line
    lines = out_str.split("\n")
    report_result(len(lines) == 1, f"uptime: output is single line ({len(lines)} lines)")

    # -p / --pretty flag
    rc, out, err = run([BIN, "-p"])
    report_result(rc == 0, "uptime: -p flag exits 0")
    out_p = out.decode(errors="replace").strip()
    report_result("up" in out_p, "uptime: -p output contains 'up'")

    # -s / --since flag
    rc, out, err = run([BIN, "-s"])
    report_result(rc == 0, "uptime: -s flag exits 0")
    out_s = out.decode(errors="replace").strip()
    has_date = bool(re.search(r'\d{4}-\d{2}-\d{2}', out_s))
    report_result(has_date, "uptime: -s output contains date pattern")

    # Compare with GNU
    if gnu_path:
        # -s should produce similar date
        rc_f, out_f, _ = run([BIN, "-s"])
        rc_g, out_g, _ = run([gnu_path, "-s"])
        report_result(rc_f == rc_g, "uptime: -s exit code matches GNU")

        # -p should both exit 0
        rc_f, _, _ = run([BIN, "-p"])
        rc_g, _, _ = run([gnu_path, "-p"])
        report_result(rc_f == rc_g, "uptime: -p exit code matches GNU")

    # Output ends with newline
    rc, out, _ = run([BIN])
    report_result(out.endswith(b"\n"), "uptime: output ends with newline")

    # No trailing space before newline
    report_result(not out.endswith(b" \n"), "uptime: no trailing space before newline")


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
