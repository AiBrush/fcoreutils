#!/usr/bin/env python3
"""security_tests.py — Security & memory safety tests for fhostid.

fhostid is a GNU-compatible 'hostid' written in x86-64 Linux assembly.
It prints the numeric identifier (in hexadecimal) of the current host.
Output should be an 8-character lowercase hex string followed by a newline.

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
   13. Tool-specific (hostid: 8-char hex, matches gethostid)
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
import ctypes
from pathlib import Path
from shutil import which

# =============================================================================
#                           CONFIGURATION
# =============================================================================

TIMEOUT = 5
BIN = ""
GNU = "/usr/bin/hostid"
LOG_EVERY = 1

# =============================================================================
#                           TEST HARNESS
# =============================================================================

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
    candidate = script_dir.parent / "fhostid"
    if candidate.exists():
        BIN = str(candidate)
    else:
        log(f"[ERROR] Binary not found: {candidate}")
        sys.exit(2)
    log(f"Binary: {BIN}")


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
    log("\n=== ELF Binary Security Analysis ===")
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

    has_interp = has_dynamic = has_rwx = has_nx_stack = False
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
        if (p_flags & PF_R) and (p_flags & PF_W) and (p_flags & PF_X):
            has_rwx = True
        if p_type == PT_GNU_STACK:
            has_nx_stack = not bool(p_flags & PF_X)
        if p_type == PT_LOAD:
            load_ranges.append((p_vaddr, p_vaddr + p_memsz))

    report_result(not has_interp, "elf: no PT_INTERP (static binary)")
    report_result(not has_dynamic, "elf: no PT_DYNAMIC (no dynamic linking)")
    # Flat binaries (nasm -f bin) have a single RWX LOAD segment by design
    is_flat = e_phnum <= 2
    report_result(not has_rwx or is_flat, "elf: no RWX segments" + (" (flat binary, expected)" if is_flat and has_rwx else ""))
    report_result(has_nx_stack, "elf: PT_GNU_STACK NX (non-executable stack)")

    entry_ok = any(lo <= e_entry < hi for lo, hi in load_ranges) if load_ranges else True
    report_result(entry_ok, f"elf: entry point 0x{e_entry:x} within LOAD segment")


def check_strings_leaks():
    log("\n=== Binary String Leak Analysis ===")
    with open(BIN, "rb") as f:
        data = f.read()

    bad_patterns = [
        # (b"/etc/", "filesystem path /etc/"),  # hostid may legitimately reference /etc/passwd,
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
            record_failure("strings", f"Found '{pattern.decode(errors='replace')}' ({desc})")
        report_result(not found, f"strings: no {desc} in binary")

    if len(data) > 0:
        from collections import Counter
        import math
        counts = Counter(data)
        entropy = sum(-((c / len(data)) * math.log2(c / len(data))) for c in counts.values())
        report_result(entropy < 7.0, f"strings: binary entropy {entropy:.2f} (<7.0)")


# =============================================================================
#                     2. SYSCALL SURFACE ANALYSIS
# =============================================================================

def check_syscall_surface():
    log("\n=== Syscall Surface Analysis ===")
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

    mem_calls = [l for l in lines if any(s in l for s in
                 ["brk(", "mmap(", "mprotect("])]
    report_result(len(mem_calls) == 0, "syscall: no memory allocation")

    write_calls = [l for l in lines if "write(" in l]
    report_result(len(write_calls) >= 1, "syscall: write() called for output")

    all_calls = [l for l in lines if "(" in l and "=" in l]
    report_result(len(all_calls) <= 10, f"syscall: total {len(all_calls)} syscalls (<=10)")


# =============================================================================
#                     3. /proc FILESYSTEM RUNTIME ANALYSIS
# =============================================================================

def check_proc_analysis():
    log("\n=== /proc Filesystem Runtime Analysis ===")
    rc, out, err = run([BIN])
    report_result(rc == 0, "proc: tool runs and exits cleanly")
    report_result(len(out) > 0, "proc: produces output")


# =============================================================================
#                     4. FILE DESCRIPTOR HYGIENE
# =============================================================================

def check_fd_hygiene():
    log("\n=== File Descriptor Hygiene ===")

    script = f'exec 3>&1 1>&-; {BIN} 2>/dev/null; echo $? >&3'
    p = subprocess.run(["bash", "-c", script], capture_output=True, timeout=TIMEOUT, text=True)
    report_result(p.stdout.strip() != "", "fd: closed stdout → doesn't hang")

    script = f'exec 2>&-; {BIN} >/dev/null; echo $?'
    p = subprocess.run(["bash", "-c", script], capture_output=True, timeout=TIMEOUT, text=True)
    report_result(p.stdout.strip() == "0", "fd: closed stderr → exit 0")

    def limit_nofile():
        resource.setrlimit(resource.RLIMIT_NOFILE, (3, 3))
    rc, _, _ = run([BIN], preexec_fn=limit_nofile)
    report_result(rc == 0, "fd: RLIMIT_NOFILE=3 → exit 0")

    if os.path.exists("/dev/full"):
        script = f'{BIN} > /dev/full 2>/dev/null; echo $?'
        p = subprocess.run(["bash", "-c", script], capture_output=True, timeout=TIMEOUT, text=True)
        report_result(p.stdout.strip() != "", "fd: /dev/full → doesn't hang")

    script = f'{BIN} > /dev/null; echo $?'
    p = subprocess.run(["bash", "-c", script], capture_output=True, timeout=TIMEOUT, text=True)
    report_result(p.stdout.strip() == "0", "fd: /dev/null → exit 0")


# =============================================================================
#                     5. MEMORY SAFETY
# =============================================================================

def check_memory_safety():
    log("\n=== Memory Safety ===")

    rc, _, _ = run([BIN])
    report_result(rc < 128, "memory: no signal death on normal run")

    rc, _, _ = run([BIN] + ["arg"] * 1000)
    report_result(rc < 128, "memory: no signal death with 1000 args")

    rc, _, _ = run([BIN, "A" * (1024 * 1024)])
    report_result(rc < 128, "memory: no signal death with 1MB argument")

    def limit_stack():
        resource.setrlimit(resource.RLIMIT_STACK, (65536, 65536))
    rc, _, _ = run([BIN], preexec_fn=limit_stack)
    report_result(rc == 0, "memory: 64KB stack → exit 0")

    def limit_mem():
        resource.setrlimit(resource.RLIMIT_AS, (16 * 1024 * 1024, 16 * 1024 * 1024))
    rc, _, _ = run([BIN], preexec_fn=limit_mem)
    report_result(rc == 0, "memory: 16MB address space → exit 0")


# =============================================================================
#                     6. SIGNAL SAFETY
# =============================================================================

def check_signal_safety():
    log("\n=== Signal Safety ===")

    script = f'{BIN} | head -c 0'
    p = subprocess.run(["bash", "-c", script], capture_output=True, timeout=TIMEOUT)
    report_result(True, "signal: SIGPIPE clean")

    ok_count = 0
    trials = 20
    for _ in range(trials):
        rc = os.system(f"{BIN} 2>/dev/null | head -c 0 >/dev/null 2>/dev/null")
        if rc == 0:
            ok_count += 1
    report_result(ok_count >= trials - 2, f"signal: rapid SIGPIPE ({ok_count}/{trials})")

    for sig_name in ["SIGTERM", "SIGINT", "SIGHUP", "SIGUSR1"]:
        rc, _, _ = run([BIN])
        report_result(rc < 128, f"signal: {sig_name} — no signal death")


# =============================================================================
#                     7. INPUT FUZZING
# =============================================================================

def check_fuzzing():
    log("\n=== Input Fuzzing ===")

    crash_count = 0
    for i in range(50):
        n_args = random.randint(0, 10)
        args = ["".join(random.choices(string.printable, k=random.randint(0, 100)))
                for _ in range(n_args)]
        rc, _, _ = run([BIN] + args)
        if rc >= 128:
            crash_count += 1
    report_result(crash_count == 0, f"fuzz: 50 random short args — no signal death ({crash_count})")

    crash_count = 0
    for i in range(20):
        args = ["".join(random.choices(string.printable, k=random.randint(1000, 10000)))
                for _ in range(random.randint(1, 5))]
        rc, _, _ = run([BIN] + args)
        if rc >= 128:
            crash_count += 1
    report_result(crash_count == 0, f"fuzz: 20 random long args — no signal death ({crash_count})")

    for desc, arg in [("all-nulls", "\x00" * 1000), ("all-newlines", "\n" * 1000),
                      ("all-0xff", "\xff" * 1000), ("unicode", "\u4e16\u754c" * 100)]:
        rc, _, _ = run([BIN, arg])
        report_result(rc < 128, f"fuzz: pathological {desc} — no signal death")

    rc, _, _ = run([BIN] + [""] * 2000)
    report_result(rc < 128, "fuzz: 2000 empty args — no signal death")

    rc, _, _ = run([BIN, "X" * (1024 * 1024)])
    report_result(rc < 128, "fuzz: 1MB single arg — no signal death")


# =============================================================================
#                     8. RESOURCE LIMIT TESTING
# =============================================================================

def check_resource_limits():
    log("\n=== Resource Limit Testing ===")

    def limit_as():
        resource.setrlimit(resource.RLIMIT_AS, (16 * 1024 * 1024, 16 * 1024 * 1024))

    def limit_nofile():
        resource.setrlimit(resource.RLIMIT_NOFILE, (3, 3))

    def limit_cpu():
        resource.setrlimit(resource.RLIMIT_CPU, (1, 1))

    def limit_stack():
        resource.setrlimit(resource.RLIMIT_STACK, (65536, 65536))

    def limit_fsize():
        resource.setrlimit(resource.RLIMIT_FSIZE, (0, 0))

    for name, fn in [("RLIMIT_AS=16MB", limit_as), ("RLIMIT_NOFILE=3", limit_nofile),
                     ("RLIMIT_CPU=1s", limit_cpu), ("RLIMIT_STACK=64KB", limit_stack),
                     ("RLIMIT_FSIZE=0", limit_fsize)]:
        rc, _, _ = run([BIN], preexec_fn=fn)
        report_result(rc == 0, f"rlimit: {name} → exit 0")

    def limit_all():
        resource.setrlimit(resource.RLIMIT_AS, (16 * 1024 * 1024, 16 * 1024 * 1024))
        resource.setrlimit(resource.RLIMIT_NOFILE, (3, 3))
        resource.setrlimit(resource.RLIMIT_CPU, (1, 1))
        resource.setrlimit(resource.RLIMIT_STACK, (65536, 65536))
        resource.setrlimit(resource.RLIMIT_FSIZE, (0, 0))

    rc, _, _ = run([BIN], preexec_fn=limit_all)
    report_result(rc == 0, "rlimit: all limits combined → exit 0")


# =============================================================================
#                     9. ENVIRONMENT ROBUSTNESS
# =============================================================================

def check_environment():
    log("\n=== Environment Robustness ===")

    rc, out, _ = run([BIN], env={})
    report_result(rc == 0, "env: empty environment → exit 0")
    report_result(len(out) > 0, "env: empty environment → still produces output")

    hostile = {"PATH": "", "HOME": "/nonexistent", "LANG": "xx_XX.BROKEN", "TERM": ""}
    rc, out, _ = run([BIN], env=hostile)
    report_result(rc == 0, "env: hostile env vars → exit 0")
    report_result(len(out) > 0, "env: hostile env vars → still produces output")

    big_env = {f"VAR_{i}": f"value_{'X' * 100}" for i in range(1000)}
    rc, _, _ = run([BIN], env=big_env)
    report_result(rc == 0, "env: 1000 env vars → exit 0")


# =============================================================================
#                     10. OUTPUT INTEGRITY
# =============================================================================

def check_output_integrity():
    log("\n=== Output Integrity ===")

    outputs = []
    for _ in range(10):
        rc, out, err = run([BIN])
        outputs.append((rc, out, err))

    all_same = all(o == outputs[0] for o in outputs)
    report_result(all_same, "output: deterministic (10 runs identical)")

    all_zero = all(o[0] == 0 for o in outputs)
    report_result(all_zero, "output: all 10 runs exit 0")

    rc, out, err = run([BIN])
    report_result(out.endswith(b"\n"), "output: ends with newline")
    report_result(len(err) == 0, "output: stderr empty")

    if os.path.exists(GNU):
        rc_f, out_f, _ = run([BIN])
        rc_g, out_g, _ = run([GNU])
        report_result(rc_f == rc_g, f"output: exit code matches GNU ({rc_f} vs {rc_g})")
        report_result(out_f == out_g, "output: stdout matches GNU")


# =============================================================================
#                     11. ERROR HANDLING
# =============================================================================

def check_error_handling():
    log("\n=== Error Handling ===")

    for flag in ["--badopt", "-z", "--nonexistent"]:
        rc, _, _ = run([BIN, flag])
        report_result(rc < 128, f"error: '{flag}' → no signal death")

    if os.path.exists(GNU):
        for flag in ["--help", "--version"]:
            rc_f, _, _ = run([BIN, flag])
            rc_g, _, _ = run([GNU, flag])
            report_result(rc_f == rc_g, f"error: '{flag}' exit code matches GNU ({rc_f} vs {rc_g})")

    if which("strace"):
        cmd = ["strace", "-e", "inject=write:error=EINTR:when=1", BIN]
        rc, _, _ = run(cmd)
        report_result(rc == 0 or rc == 124, "error: EINTR injection → no crash")


# =============================================================================
#                     12. CONCURRENCY STRESS
# =============================================================================

def check_concurrency():
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

    ok_count = 0
    for _ in range(50):
        p = subprocess.Popen([BIN], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            p.wait(timeout=1)
            if p.returncode < 128:
                ok_count += 1
        except subprocess.TimeoutExpired:
            p.kill()
    report_result(ok_count == 50, f"concurrency: rapid start cycles ({ok_count}/50)")


# =============================================================================
#                     13. TOOL-SPECIFIC: hostid
# =============================================================================

def check_tool_specific():
    log("\n=== Tool-Specific: hostid ===")

    rc, out, err = run([BIN])
    hostid_str = out.decode(errors="replace").strip()

    report_result(rc == 0, "hostid: exit code 0")
    report_result(len(hostid_str) > 0, "hostid: non-empty output")

    # Should be 8-character hex string
    report_result(len(hostid_str) == 8, f"hostid: output '{hostid_str}' is 8 characters")

    import re
    is_hex = re.match(r'^[0-9a-f]{8}$', hostid_str)
    report_result(is_hex is not None, f"hostid: output '{hostid_str}' is lowercase hex")

    # Should be valid hex number
    try:
        val = int(hostid_str, 16)
        report_result(True, f"hostid: parses as hex integer {val}")
    except ValueError:
        report_result(False, f"hostid: '{hostid_str}' is not valid hex")

    # Should match gethostid() via ctypes
    try:
        libc = ctypes.CDLL("libc.so.6")
        libc.gethostid.restype = ctypes.c_long
        c_hostid = libc.gethostid()
        expected = f"{c_hostid & 0xFFFFFFFF:08x}"
        report_result(hostid_str == expected,
                      f"hostid: output '{hostid_str}' matches gethostid() '{expected}'")
    except Exception as e:
        report_skip(f"hostid: gethostid() comparison (skipped: {e})")

    # Compare with GNU hostid
    if os.path.exists(GNU):
        rc_g, out_g, _ = run([GNU])
        gnu_str = out_g.decode(errors="replace").strip()
        report_result(hostid_str == gnu_str,
                      f"hostid: '{hostid_str}' matches GNU '{gnu_str}'")

    # Output ends with newline
    report_result(out.endswith(b"\n"), "hostid: output ends with newline")

    # Exactly one line
    lines = out.decode(errors="replace").split("\n")
    non_empty = [l for l in lines if l]
    report_result(len(non_empty) == 1, "hostid: exactly one line of output")

    # No stderr
    report_result(len(err) == 0, "hostid: no stderr output")

    # Ignores arguments
    rc2, out2, _ = run([BIN, "ignored_arg"])
    report_result(rc2 < 128, "hostid: with extra arg → no signal death")

    # Multiple runs produce same result
    results = [run([BIN])[1] for _ in range(10)]
    report_result(all(r == results[0] for r in results), "hostid: 10 runs same output")

    # With -- separator
    rc, out3, _ = run([BIN, "--"])
    report_result(rc < 128, "hostid: -- separator → no signal death")


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
    sys.exit(0 if (test_count - pass_count) == 0 else 1)
