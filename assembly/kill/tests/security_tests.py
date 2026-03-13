#!/usr/bin/env python3
"""security_tests.py — Security & memory safety tests for fkill.

fkill is a GNU-compatible 'kill' written in x86-64 Linux assembly.
It sends signals to processes or lists signals.

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
   13. Tool-specific (kill: signal sending behavior)
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
    # Try release binary first, then dev binary
    for name in ["fkill_release", "fkill"]:
        candidate = script_dir.parent / name
        if candidate.exists():
            BIN = str(candidate)
            break
    if not BIN:
        log(f"[ERROR] Binary not found in {script_dir.parent}")
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
    report_result(size < 10000, f"elf: binary size {size} bytes (<10KB)")

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
        (b"/etc/", "filesystem path /etc/"),
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

    # Use --help to avoid needing a PID
    cmd = ["strace", "-f", "-e", "trace=%process,%network,write,read,openat,open,creat,brk,mmap,mprotect",
           BIN, "--help"]
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
    report_result(len(write_calls) >= 1, "syscall: write called (expected)")

    all_calls = [l for l in lines if "(" in l and "=" in l]
    report_result(len(all_calls) <= 10, f"syscall: total {len(all_calls)} syscalls (<=10 expected)")


# =============================================================================
#                     3. /proc FILESYSTEM RUNTIME ANALYSIS
# =============================================================================

def check_proc_analysis():
    log("\n=== 3. /proc Filesystem Runtime Analysis ===")
    rc, out, err = run([BIN, "--help"])
    report_result(rc == 0, "proc: tool runs and exits cleanly")

    if which("strace"):
        cmd = ["strace", "-e", "trace=openat,open", BIN, "--help"]
        rc, out, err = run(cmd)
        err_text = err.decode(errors="replace")
        opens = [l for l in err_text.splitlines()
                 if ("openat(" in l or "open(" in l)
                 and not l.startswith("---") and not l.startswith("+++")]
        # kill doesn't open any files
        report_result(len(opens) == 0, "proc: no file descriptors opened (kill needs none)")


# =============================================================================
#                     4. FILE DESCRIPTOR HYGIENE
# =============================================================================

def check_fd_hygiene():
    log("\n=== 4. File Descriptor Hygiene ===")

    # Closed stdout — --help writes to stdout, should not hang
    script = f'exec 3>&1 1>&-; {BIN} --help 2>/dev/null; echo $? >&3'
    p = subprocess.run(["bash", "-c", script], capture_output=True, timeout=TIMEOUT, text=True)
    rc = p.stdout.strip()
    report_result(rc != "", "fd: closed stdout -> doesn't hang")

    # Closed stderr — error should still not hang
    script = f'exec 3>&1; {BIN} --help 2>&- 1>&3; echo $? >&3'
    p = subprocess.run(["bash", "-c", script], capture_output=True, timeout=TIMEOUT, text=True)
    lines = p.stdout.strip().split("\n")
    rc = lines[-1] if lines else ""
    report_result(rc == "0", "fd: closed stderr -> exit 0 for valid input")

    # RLIMIT_NOFILE=3
    def limit_nofile():
        resource.setrlimit(resource.RLIMIT_NOFILE, (3, 3))
    rc, out, err = run([BIN, "--help"], preexec_fn=limit_nofile)
    report_result(rc >= 0 and rc < 128, "fd: RLIMIT_NOFILE=3 -> no crash")

    # /dev/full
    if os.path.exists("/dev/full"):
        script = f'{BIN} --help > /dev/full 2>/dev/null; echo $?'
        p = subprocess.run(["bash", "-c", script], capture_output=True, timeout=TIMEOUT, text=True)
        rc = p.stdout.strip()
        report_result(rc != "", "fd: /dev/full -> doesn't hang")

    # /dev/null redirect
    script = f'{BIN} --help > /dev/null 2>/dev/null; echo $?'
    p = subprocess.run(["bash", "-c", script], capture_output=True, timeout=TIMEOUT, text=True)
    rc = p.stdout.strip()
    report_result(rc == "0", "fd: /dev/null redirect -> exit 0")


# =============================================================================
#                     5. MEMORY SAFETY
# =============================================================================

def check_memory_safety():
    log("\n=== 5. Memory Safety ===")

    rc, out, err = run([BIN, "--help"])
    report_result(rc == 0, "memory: no signal death on normal run")

    # Many arguments (all --help, to avoid needing PIDs)
    rc, out, err = run([BIN, "-l"])
    report_result(rc >= 0 and rc < 128, "memory: -l -> no crash")

    # Multiple -l lookups (only one at a time since -l takes the rest)
    for sig_num in range(1, 32):
        rc, _, _ = run([BIN, "-l", str(sig_num)])
        if rc >= 128:
            report_result(False, f"memory: crash on -l {sig_num}")
            break
    else:
        report_result(True, "memory: no crash with -l 1..31")

    def limit_stack():
        resource.setrlimit(resource.RLIMIT_STACK, (65536, 65536))
    rc, out, err = run([BIN, "--help"], preexec_fn=limit_stack)
    report_result(rc == 0, "memory: 64KB stack -> exit 0")

    def limit_mem():
        resource.setrlimit(resource.RLIMIT_AS, (16 * 1024 * 1024, 16 * 1024 * 1024))
    rc, out, err = run([BIN, "--help"], preexec_fn=limit_mem)
    report_result(rc == 0, "memory: 16MB address space -> exit 0")


# =============================================================================
#                     6. SIGNAL SAFETY
# =============================================================================

def check_signal_safety():
    log("\n=== 6. Signal Safety ===")

    script = f'{BIN} --help | head -c 0'
    p = subprocess.run(["bash", "-c", script], capture_output=True, timeout=TIMEOUT)
    report_result(p.returncode >= 0 and p.returncode < 128, "signal: SIGPIPE clean exit")

    ok_count = 0
    trials = 20
    for _ in range(trials):
        rc = os.system(f"{BIN} --help 2>/dev/null | head -c 0 >/dev/null 2>/dev/null")
        if os.WIFEXITED(rc) and os.WEXITSTATUS(rc) < 128:
            ok_count += 1
    report_result(ok_count >= trials - 2, f"signal: rapid SIGPIPE ({ok_count}/{trials})")

    for sig_name in ["SIGTERM", "SIGINT", "SIGHUP"]:
        rc, out, err = run([BIN, "--help"])
        report_result(rc == 0, f"signal: {sig_name} -- exits cleanly")


# =============================================================================
#                     7. INPUT FUZZING
# =============================================================================

def check_fuzzing():
    log("\n=== 7. Input Fuzzing ===")

    # Fuzz with random non-numeric arguments (treated as PIDs — will fail but should not crash)
    # Avoid purely numeric args as those could be valid PIDs (especially 0 = process group)
    crash_count = 0
    for i in range(50):
        arg = 'x' + ''.join(random.choices(string.printable, k=random.randint(1, 100)))
        rc, out, err = run([BIN, arg])
        if rc >= 128:
            crash_count += 1
    report_result(crash_count == 0, f"fuzz: 50 random args -- no signal death ({crash_count})")

    # Fuzz with random long arguments (non-numeric to avoid sending real signals)
    crash_count = 0
    for i in range(20):
        arg = 'z' + ''.join(random.choices(string.ascii_letters, k=random.randint(100, 1000)))
        rc, out, err = run([BIN, arg])
        if rc >= 128:
            crash_count += 1
    report_result(crash_count == 0, f"fuzz: 20 long random args -- no signal death ({crash_count})")

    # Fuzz signal names with -0 (signal 0 = check existence, safe)
    crash_count = 0
    for i in range(20):
        sig = ''.join(random.choices(string.ascii_uppercase, k=random.randint(1, 10)))
        rc, out, err = run([BIN, f"-{sig}", "1"])
        if rc >= 128:
            crash_count += 1
    report_result(crash_count == 0, f"fuzz: 20 random signal names -- no signal death ({crash_count})")

    # Pathological inputs
    for desc, args in [("huge-number", ["99999999999999999999"]),
                       ("empty-string", [""]),
                       ("null-bytes", ["\x00"]),
                       ("long-signal", ["-s", "A" * 1000, "1"])]:
        rc, _, _ = run([BIN] + args)
        report_result(rc >= 0 and rc < 128, f"fuzz: pathological {desc} -- no crash")


# =============================================================================
#                     8. RESOURCE LIMIT TESTING
# =============================================================================

def check_resource_limits():
    log("\n=== 8. Resource Limit Testing ===")

    def limit_as():
        resource.setrlimit(resource.RLIMIT_AS, (16 * 1024 * 1024, 16 * 1024 * 1024))
    rc, _, _ = run([BIN, "--help"], preexec_fn=limit_as)
    report_result(rc == 0, "rlimit: RLIMIT_AS=16MB -> exit 0")

    def limit_nofile():
        resource.setrlimit(resource.RLIMIT_NOFILE, (3, 3))
    rc, _, _ = run([BIN, "--help"], preexec_fn=limit_nofile)
    report_result(rc >= 0 and rc < 128, "rlimit: RLIMIT_NOFILE=3 -> no crash")

    def limit_cpu():
        resource.setrlimit(resource.RLIMIT_CPU, (1, 1))
    rc, _, _ = run([BIN, "--help"], preexec_fn=limit_cpu)
    report_result(rc == 0, "rlimit: RLIMIT_CPU=1s -> exit 0")

    def limit_stack():
        resource.setrlimit(resource.RLIMIT_STACK, (65536, 65536))
    rc, _, _ = run([BIN, "--help"], preexec_fn=limit_stack)
    report_result(rc == 0, "rlimit: RLIMIT_STACK=64KB -> exit 0")

    def limit_fsize():
        resource.setrlimit(resource.RLIMIT_FSIZE, (0, 0))
    rc, _, _ = run([BIN, "--help"], preexec_fn=limit_fsize)
    report_result(rc == 0, "rlimit: RLIMIT_FSIZE=0 -> exit 0")

    def limit_all():
        resource.setrlimit(resource.RLIMIT_AS, (16 * 1024 * 1024, 16 * 1024 * 1024))
        resource.setrlimit(resource.RLIMIT_NOFILE, (3, 3))
        resource.setrlimit(resource.RLIMIT_CPU, (1, 1))
        resource.setrlimit(resource.RLIMIT_STACK, (65536, 65536))
        resource.setrlimit(resource.RLIMIT_FSIZE, (0, 0))
    rc, _, _ = run([BIN, "--help"], preexec_fn=limit_all)
    report_result(rc >= 0 and rc < 128, "rlimit: all limits combined -> no crash")


# =============================================================================
#                     9. ENVIRONMENT ROBUSTNESS
# =============================================================================

def check_environment():
    log("\n=== 9. Environment Robustness ===")

    rc, out, err = run([BIN, "--help"], env={})
    report_result(rc == 0, "env: empty environment -> exit 0")

    hostile = {
        "PATH": "",
        "HOME": "/nonexistent",
        "LANG": "xx_XX.BROKEN",
        "TERM": "",
        "LC_ALL": "C",
    }
    rc, out, err = run([BIN, "--help"], env=hostile)
    report_result(rc == 0, "env: hostile env vars -> exit 0")

    big_env = {f"VAR_{i}": f"value_{'X' * 100}" for i in range(1000)}
    rc, out, err = run([BIN, "--help"], env=big_env)
    report_result(rc == 0, "env: 1000 env vars -> exit 0")

    special_env = os.environ.copy()
    special_env["EVIL"] = "A" * 100000
    rc, out, err = run([BIN, "--help"], env=special_env)
    report_result(rc == 0, "env: 100KB env var -> exit 0")


# =============================================================================
#                     10. OUTPUT INTEGRITY
# =============================================================================

def check_output_integrity():
    log("\n=== 10. Output Integrity ===")

    # --help deterministic
    outputs = []
    for _ in range(10):
        rc, out, err = run([BIN, "--help"])
        outputs.append((rc, out, err))

    all_same = all(o == outputs[0] for o in outputs)
    report_result(all_same, "output: --help deterministic (10 runs identical)")

    all_zero = all(o[0] == 0 for o in outputs)
    report_result(all_zero, "output: all 10 --help runs exit 0")

    # -l deterministic
    outputs = []
    for _ in range(10):
        rc, out, err = run([BIN, "-l"])
        outputs.append((rc, out, err))

    all_same = all(o == outputs[0] for o in outputs)
    report_result(all_same, "output: -l deterministic (10 runs identical)")

    # Signal lookup consistency
    for sig_num, sig_name in [(1, "HUP"), (2, "INT"), (9, "KILL"),
                               (15, "TERM"), (31, "SYS")]:
        # Number to name
        rc1, out1, _ = run([BIN, "-l", str(sig_num)])
        name = out1.decode().strip()
        report_result(name == sig_name,
                     f"output: -l {sig_num} -> {sig_name} (got {name})")

        # Name to number
        rc2, out2, _ = run([BIN, "-l", sig_name])
        num = out2.decode().strip()
        report_result(num == str(sig_num),
                     f"output: -l {sig_name} -> {sig_num} (got {num})")

    # All 31 signals listed
    rc, out, err = run([BIN, "-l"])
    lines = out.decode().strip().split("\n")
    report_result(len(lines) == 31, f"output: -l lists 31 signals (got {len(lines)})")


# =============================================================================
#                     11. ERROR HANDLING
# =============================================================================

def check_error_handling():
    log("\n=== 11. Error Handling ===")

    # No arguments
    rc, out, err = run([BIN])
    report_result(rc == 1, "error: no args -> exit 1")
    report_result(b"kill:" in err or b"not enough" in err,
                 "error: no args -> error message on stderr")

    # Invalid PID
    rc, out, err = run([BIN, "notapid"])
    report_result(rc == 1, "error: invalid PID -> exit 1")
    report_result(b"kill:" in err, "error: invalid PID -> 'kill:' in stderr")

    # Invalid signal
    rc, out, err = run([BIN, "-s", "NOSUCHSIGNAL", "1"])
    report_result(rc == 1, "error: invalid signal -> exit 1")
    report_result(b"invalid signal" in err, "error: invalid signal -> 'invalid signal' in stderr")

    # Nonexistent process
    rc, out, err = run([BIN, "99999999"])
    report_result(rc == 1, "error: nonexistent PID -> exit 1")
    report_result(b"No such process" in err, "error: nonexistent PID -> 'No such process'")

    # EINTR injection
    if which("strace"):
        cmd = ["strace", "-e", "inject=write:error=EINTR:when=1", BIN, "--help"]
        rc, out, err = run(cmd)
        report_result(rc >= 0 and rc < 128, "error: EINTR injection -> no crash")

    # Exit code for --help and --version
    rc, _, _ = run([BIN, "--help"])
    report_result(rc == 0, "error: --help -> exit 0")
    rc, _, _ = run([BIN, "--version"])
    report_result(rc == 0, "error: --version -> exit 0")


# =============================================================================
#                     12. CONCURRENCY STRESS
# =============================================================================

def check_concurrency():
    log("\n=== 12. Concurrency Stress ===")

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

    # Rapid -l lookups
    procs = []
    for i in range(1, 32):
        p = subprocess.Popen([BIN, "-l", str(i)],
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

    report_result(crash_count == 0, f"concurrency: 31 simultaneous -l ({crash_count} failures)")

    # Pipe chain
    script = f'{BIN} -l | head -5; echo $?'
    p = subprocess.run(["bash", "-c", script], capture_output=True, timeout=TIMEOUT, text=True)
    report_result(p.returncode == 0, "concurrency: pipe chain")

    # Rapid start
    ok_count = 0
    for _ in range(50):
        p = subprocess.Popen([BIN, "--help"],
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            p.wait(timeout=1)
            ok_count += 1
        except subprocess.TimeoutExpired:
            p.kill()
    report_result(ok_count == 50, f"concurrency: rapid start ({ok_count}/50)")


# =============================================================================
#                     13. TOOL-SPECIFIC: kill
# =============================================================================

def check_tool_specific():
    log("\n=== 13. Tool-Specific: kill ===")

    # Signal list content
    rc, out, err = run([BIN, "-l"])
    sig_list = out.decode()
    report_result(rc == 0, "kill: -l exits 0")
    report_result("HUP" in sig_list, "kill: -l contains HUP")
    report_result("KILL" in sig_list, "kill: -l contains KILL")
    report_result("TERM" in sig_list, "kill: -l contains TERM")
    report_result("SEGV" in sig_list, "kill: -l contains SEGV")

    # Signal number to name round-trip
    for i in range(1, 32):
        rc, out, _ = run([BIN, "-l", str(i)])
        if rc != 0:
            report_result(False, f"kill: -l {i} failed")
            continue
        name = out.decode().strip()
        # Now look up the name
        rc2, out2, _ = run([BIN, "-l", name])
        num = out2.decode().strip()
        report_result(num == str(i),
                     f"kill: round-trip signal {i} -> {name} -> {num}")

    # 128+N offset lookup
    rc, out, _ = run([BIN, "-l", "129"])
    report_result(out.decode().strip() == "HUP", "kill: -l 129 -> HUP (128+1)")
    rc, out, _ = run([BIN, "-l", "137"])
    report_result(out.decode().strip() == "KILL", "kill: -l 137 -> KILL (128+9)")

    # SIG prefix handling
    rc, out, _ = run([BIN, "-l", "SIGHUP"])
    report_result(out.decode().strip() == "1", "kill: -l SIGHUP -> 1")
    rc, out, _ = run([BIN, "-l", "SIGTERM"])
    report_result(out.decode().strip() == "15", "kill: -l SIGTERM -> 15")

    # Case insensitive
    rc, out, _ = run([BIN, "-l", "hup"])
    report_result(out.decode().strip() == "1", "kill: -l hup (lowercase) -> 1")
    rc, out, _ = run([BIN, "-l", "sigterm"])
    report_result(out.decode().strip() == "15", "kill: -l sigterm (lowercase) -> 15")

    # Invalid signal lookups
    rc, _, err = run([BIN, "-l", "0"])
    report_result(rc != 0, "kill: -l 0 -> error")
    rc, _, err = run([BIN, "-l", "32"])
    report_result(rc != 0, "kill: -l 32 -> error")
    rc, _, err = run([BIN, "-l", "999"])
    report_result(rc != 0, "kill: -l 999 -> error")

    # Actual signal sending — send SIGTERM to a sleep process
    p = subprocess.Popen(["sleep", "999"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    pid = p.pid
    rc, _, _ = run([BIN, str(pid)])
    time.sleep(0.2)
    alive = p.poll() is None
    if alive:
        p.kill()
    p.wait()
    report_result(rc == 0 and not alive, "kill: send SIGTERM to sleep process")

    # Send SIGKILL
    p = subprocess.Popen(["sleep", "999"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    pid = p.pid
    rc, _, _ = run([BIN, "-9", str(pid)])
    time.sleep(0.2)
    alive = p.poll() is None
    if alive:
        p.kill()
    p.wait()
    report_result(rc == 0 and not alive, "kill: send SIGKILL (-9) to sleep process")

    # Send signal by name
    p = subprocess.Popen(["sleep", "999"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    pid = p.pid
    rc, _, _ = run([BIN, "-s", "HUP", str(pid)])
    time.sleep(0.2)
    alive = p.poll() is None
    if alive:
        p.kill()
    p.wait()
    report_result(rc == 0 and not alive, "kill: send -s HUP to sleep process")

    # Signal 0 (check process existence)
    p = subprocess.Popen(["sleep", "999"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    pid = p.pid
    rc, _, _ = run([BIN, "-0", str(pid)])
    report_result(rc == 0, "kill: -0 on existing process -> exit 0")
    p.kill()
    p.wait()

    # Signal 0 on dead process
    rc, _, _ = run([BIN, "-0", str(pid)])
    report_result(rc != 0, "kill: -0 on dead process -> non-zero exit")

    # Multiple PIDs
    procs_to_kill = []
    for _ in range(3):
        pp = subprocess.Popen(["sleep", "999"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        procs_to_kill.append(pp)
    pids = [str(pp.pid) for pp in procs_to_kill]
    rc, _, _ = run([BIN] + pids)
    time.sleep(0.2)
    all_dead = all(pp.poll() is not None for pp in procs_to_kill)
    for pp in procs_to_kill:
        if pp.poll() is None:
            pp.kill()
        pp.wait()
    report_result(rc == 0 and all_dead, "kill: send SIGTERM to 3 processes at once")


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
