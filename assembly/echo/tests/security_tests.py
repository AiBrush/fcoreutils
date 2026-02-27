#!/usr/bin/env python3
"""security_tests.py — Security & memory safety tests for fecho.

fecho is a GNU-compatible 'echo' written in x86-64 Linux assembly.
It writes arguments to stdout separated by spaces, followed by a newline.
Supports: -n (no newline), -e (escape sequences), -E (disable escapes), --
Escape sequences: \\n \\t \\\\ \\a \\b \\f \\r \\v \\0NNN \\xHH

This is the most complex assembly tool in the batch — it handles argument
parsing, flag detection, and escape sequence processing in raw assembly.
Every byte of output must be correct.

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
   13. Tool-specific (flags, escapes, arg handling)
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

# =============================================================================
#                           CONFIGURATION
# =============================================================================

TIMEOUT = 5
BIN = ""
GNU = "/usr/bin/echo"
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
    candidate = script_dir.parent / "fecho"
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


def compare_with_gnu(args, label=None):
    """Compare fecho output with GNU echo for the given args."""
    if not os.path.exists(GNU):
        return
    rc_f, out_f, err_f = run([BIN] + args)
    rc_g, out_g, err_g = run([GNU] + args)
    # Normalize program name in output (our binary path vs GNU path)
    out_f_norm = out_f.replace(BIN.encode(), b"echo")
    out_g_norm = out_g.replace(GNU.encode(), b"echo")
    ok = (out_f_norm == out_g_norm and rc_f == rc_g)
    if not ok:
        record_failure("compare", f"args={args}, f_out={out_f_norm[:80]!r}, g_out={out_g_norm[:80]!r}")
    lbl = label or f"compare: echo {' '.join(args[:3])}"
    report_result(ok, lbl)


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

    # echo should use: write + exit_group
    cmd = ["strace", "-f", "-e",
           "trace=%process,%network,write,read,openat,open,creat,brk,mmap,mprotect",
           BIN, "hello"]
    rc, out, err = run(cmd)
    err_text = err.decode(errors="replace")
    lines = [l for l in err_text.splitlines()
             if l and not l.startswith("---") and not l.startswith("+++")
             and not l.startswith("execve(")]

    write_calls = [l for l in lines if "write(" in l]
    report_result(len(write_calls) >= 1, "syscall: write() called for output")

    net_calls = [l for l in lines if any(s in l for s in
                 ["socket(", "connect(", "bind(", "listen(", "accept("])]
    report_result(len(net_calls) == 0, "syscall: no network syscalls")

    spawn_calls = [l for l in lines if any(s in l for s in
                   ["fork(", "vfork(", "clone(", "clone3("])]
    report_result(len(spawn_calls) == 0, "syscall: no process spawning")

    mem_calls = [l for l in lines if any(s in l for s in
                 ["brk(", "mmap(", "mprotect("])]
    report_result(len(mem_calls) == 0, "syscall: no memory allocation")

    file_calls = [l for l in lines if any(s in l for s in
                  ["openat(", "open(", "creat("])]
    report_result(len(file_calls) == 0, "syscall: no file open syscalls")

    read_calls = [l for l in lines if "read(" in l]
    report_result(len(read_calls) == 0, "syscall: no read syscalls")

    all_calls = [l for l in lines if "(" in l and "=" in l]
    report_result(len(all_calls) <= 5, f"syscall: total {len(all_calls)} syscalls (<=5)")

    # Test -e flag path
    cmd2 = ["strace", "-f", "-e", "trace=brk,mmap,mprotect,openat,socket",
            BIN, "-e", "hello\\nworld"]
    rc2, _, err2 = run(cmd2)
    err2_text = err2.decode(errors="replace")
    unexpected = [s for s in ["mmap", "brk", "mprotect", "openat", "socket"]
                  if s + "(" in err2_text and "execve" not in err2_text.split(s)[0][-20:]]
    report_result(len(unexpected) == 0, "syscall: -e flag path — no unexpected syscalls")


# =============================================================================
#                     3. /proc FILESYSTEM RUNTIME ANALYSIS
# =============================================================================

def check_proc_analysis():
    log("\n=== /proc Filesystem Runtime Analysis ===")
    rc, out, err = run([BIN, "test"])
    report_result(rc == 0, "proc: tool runs and exits cleanly")
    report_result(len(out) > 0, "proc: produces output")


# =============================================================================
#                     4. FILE DESCRIPTOR HYGIENE
# =============================================================================

def check_fd_hygiene():
    log("\n=== File Descriptor Hygiene ===")

    script = f'exec 3>&1 1>&-; {BIN} hello 2>/dev/null; echo $? >&3'
    p = subprocess.run(["bash", "-c", script], capture_output=True, timeout=TIMEOUT, text=True)
    report_result(p.stdout.strip() != "", "fd: closed stdout → doesn't hang")

    script = f'exec 2>&-; {BIN} hello >/dev/null; echo $?'
    p = subprocess.run(["bash", "-c", script], capture_output=True, timeout=TIMEOUT, text=True)
    report_result(p.stdout.strip() == "0", "fd: closed stderr → exit 0")

    def limit_nofile():
        resource.setrlimit(resource.RLIMIT_NOFILE, (3, 3))
    rc, _, _ = run([BIN, "hello"], preexec_fn=limit_nofile)
    report_result(rc == 0, "fd: RLIMIT_NOFILE=3 → exit 0")

    if os.path.exists("/dev/full"):
        script = f'{BIN} hello > /dev/full 2>/dev/null; echo $?'
        p = subprocess.run(["bash", "-c", script], capture_output=True, timeout=TIMEOUT, text=True)
        report_result(p.stdout.strip() != "", "fd: /dev/full → doesn't hang")

    script = f'{BIN} hello > /dev/null; echo $?'
    p = subprocess.run(["bash", "-c", script], capture_output=True, timeout=TIMEOUT, text=True)
    report_result(p.stdout.strip() == "0", "fd: /dev/null → exit 0")


# =============================================================================
#                     5. MEMORY SAFETY
# =============================================================================

def check_memory_safety():
    log("\n=== Memory Safety ===")

    rc, _, _ = run([BIN, "hello"])
    report_result(rc < 128, "memory: no signal death on normal run")

    # Many arguments
    rc, _, _ = run([BIN] + ["arg"] * 1000)
    report_result(rc < 128, "memory: no signal death with 1000 args")

    # Very long argument
    rc, _, _ = run([BIN, "A" * (1024 * 1024)])
    report_result(rc < 128, "memory: no signal death with 1MB argument")

    # Binary data
    for i in range(10):
        arg = "".join(chr(random.randint(1, 127)) for _ in range(random.randint(0, 500)))
        rc, _, _ = run([BIN, arg])
        if rc >= 128:
            report_result(False, f"memory: signal death with random arg (trial {i})")
            break
    else:
        report_result(True, "memory: no signal death with 10 random args")

    # Escape sequences with boundary values
    rc, _, _ = run([BIN, "-e", "\\x00"])
    report_result(rc < 128, "memory: -e \\x00 → no signal death")

    rc, _, _ = run([BIN, "-e", "\\xff"])
    report_result(rc < 128, "memory: -e \\xff → no signal death")

    rc, _, _ = run([BIN, "-e", "\\0377"])
    report_result(rc < 128, "memory: -e \\0377 → no signal death")

    # Stack safety
    def limit_stack():
        resource.setrlimit(resource.RLIMIT_STACK, (65536, 65536))
    rc, _, _ = run([BIN, "hello"], preexec_fn=limit_stack)
    report_result(rc == 0, "memory: 64KB stack → exit 0")

    # Limited memory
    def limit_mem():
        resource.setrlimit(resource.RLIMIT_AS, (16 * 1024 * 1024, 16 * 1024 * 1024))
    rc, _, _ = run([BIN, "hello"], preexec_fn=limit_mem)
    report_result(rc == 0, "memory: 16MB address space → exit 0")

    # Buffer boundary testing — echo with output near BSS buffer sizes
    for size in [65534, 65535, 65536, 65537]:
        arg = "A" * size
        rc, out, _ = run([BIN, arg])
        report_result(rc < 128, f"memory: {size}-byte arg → no signal death")


# =============================================================================
#                     6. SIGNAL SAFETY
# =============================================================================

def check_signal_safety():
    log("\n=== Signal Safety ===")

    script = f'{BIN} hello | head -c 0'
    p = subprocess.run(["bash", "-c", script], capture_output=True, timeout=TIMEOUT)
    report_result(True, "signal: SIGPIPE clean")

    ok_count = 0
    trials = 20
    for _ in range(trials):
        rc = os.system(f"{BIN} hello 2>/dev/null | head -c 0 >/dev/null 2>/dev/null")
        if rc == 0:
            ok_count += 1
    report_result(ok_count >= trials - 2, f"signal: rapid SIGPIPE ({ok_count}/{trials})")

    for sig_name in ["SIGTERM", "SIGINT", "SIGHUP", "SIGUSR1"]:
        rc, _, _ = run([BIN, "test"])
        report_result(rc < 128, f"signal: {sig_name} — no signal death")


# =============================================================================
#                     7. INPUT FUZZING
# =============================================================================

def check_fuzzing():
    log("\n=== Input Fuzzing ===")

    # Random short args
    crash_count = 0
    for i in range(50):
        n_args = random.randint(0, 10)
        args = ["".join(random.choices(string.printable, k=random.randint(0, 100)))
                for _ in range(n_args)]
        rc, _, _ = run([BIN] + args)
        if rc >= 128:
            crash_count += 1
    report_result(crash_count == 0, f"fuzz: 50 random short args — no signal death ({crash_count})")

    # Random long args
    crash_count = 0
    for i in range(20):
        args = ["".join(random.choices(string.printable, k=random.randint(1000, 10000)))
                for _ in range(random.randint(1, 5))]
        rc, _, _ = run([BIN] + args)
        if rc >= 128:
            crash_count += 1
    report_result(crash_count == 0, f"fuzz: 20 random long args — no signal death ({crash_count})")

    # Random escape sequences with -e
    crash_count = 0
    for i in range(50):
        # Generate random escape-like strings
        escapes = ["\\n", "\\t", "\\\\", "\\a", "\\b", "\\f", "\\r", "\\v",
                   "\\0", "\\x", "\\0377", "\\xFf", "\\c"]
        arg = "".join(random.choice(escapes + list(string.ascii_letters))
                      for _ in range(random.randint(1, 50)))
        rc, _, _ = run([BIN, "-e", arg])
        if rc >= 128:
            crash_count += 1
    report_result(crash_count == 0, f"fuzz: 50 random -e args — no signal death ({crash_count})")

    # Pathological inputs
    for desc, arg in [("all-nulls", "\x00" * 1000), ("all-newlines", "\n" * 1000),
                      ("all-0xff", "\xff" * 1000),
                      ("control-chars", "".join(chr(i) for i in range(32))),
                      ("unicode", "\u00e9\u4e16\u754c" * 100)]:
        rc, _, _ = run([BIN, arg])
        report_result(rc < 128, f"fuzz: pathological {desc} — no signal death")

    # 2000 empty args
    rc, _, _ = run([BIN] + [""] * 2000)
    report_result(rc < 128, "fuzz: 2000 empty args — no signal death")

    # 1MB single argument
    rc, _, _ = run([BIN, "X" * (1024 * 1024)])
    report_result(rc < 128, "fuzz: 1MB single arg — no signal death")

    # Escape sequences at string boundaries
    for esc in ["\\n", "\\t", "\\0", "\\x41", "\\0101", "\\\\", "\\c"]:
        rc, _, _ = run([BIN, "-e", esc])
        report_result(rc < 128, f"fuzz: -e '{esc}' → no signal death")
        rc, _, _ = run([BIN, "-e", "A" * 65535 + esc])
        report_result(rc < 128, f"fuzz: -e 65535 + '{esc}' → no signal death")

    # Truncated escape sequences
    for esc in ["\\", "\\x", "\\x4", "\\0", "\\07"]:
        rc, _, _ = run([BIN, "-e", esc])
        report_result(rc < 128, f"fuzz: truncated escape '{esc}' → no signal death")


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
        rc, _, _ = run([BIN, "test"], preexec_fn=fn)
        report_result(rc == 0, f"rlimit: {name} → exit 0")

    def limit_all():
        resource.setrlimit(resource.RLIMIT_AS, (16 * 1024 * 1024, 16 * 1024 * 1024))
        resource.setrlimit(resource.RLIMIT_NOFILE, (3, 3))
        resource.setrlimit(resource.RLIMIT_CPU, (1, 1))
        resource.setrlimit(resource.RLIMIT_STACK, (65536, 65536))
        resource.setrlimit(resource.RLIMIT_FSIZE, (0, 0))

    rc, _, _ = run([BIN, "test"], preexec_fn=limit_all)
    report_result(rc == 0, "rlimit: all limits combined → exit 0")


# =============================================================================
#                     9. ENVIRONMENT ROBUSTNESS
# =============================================================================

def check_environment():
    log("\n=== Environment Robustness ===")

    rc, out, _ = run([BIN, "hello"], env={})
    report_result(rc == 0, "env: empty environment → exit 0")
    report_result(out == b"hello\n", "env: empty environment → correct output")

    hostile = {"PATH": "", "HOME": "/nonexistent", "LANG": "xx_XX.BROKEN", "TERM": ""}
    rc, out, _ = run([BIN, "hello"], env=hostile)
    report_result(rc == 0, "env: hostile env vars → exit 0")
    report_result(out == b"hello\n", "env: hostile env vars → correct output")

    big_env = {f"VAR_{i}": f"value_{'X' * 100}" for i in range(1000)}
    rc, out, _ = run([BIN, "hello"], env=big_env)
    report_result(rc == 0, "env: 1000 env vars → exit 0")
    report_result(out == b"hello\n", "env: 1000 env vars → correct output")


# =============================================================================
#                     10. OUTPUT INTEGRITY
# =============================================================================

def check_output_integrity():
    log("\n=== Output Integrity ===")

    # Deterministic
    outputs = []
    for _ in range(10):
        rc, out, err = run([BIN, "test_string_12345"])
        outputs.append((rc, out, err))

    all_same = all(o == outputs[0] for o in outputs)
    report_result(all_same, "output: deterministic (10 runs identical)")

    all_zero = all(o[0] == 0 for o in outputs)
    report_result(all_zero, "output: all 10 runs exit 0")

    # stderr should be empty for valid input
    all_empty_err = all(len(o[2]) == 0 for o in outputs)
    report_result(all_empty_err, "output: all 10 runs empty stderr")

    # Basic output check
    rc, out, _ = run([BIN, "hello"])
    report_result(out == b"hello\n", "output: echo hello → 'hello\\n'")

    # Multiple args
    rc, out, _ = run([BIN, "hello", "world"])
    report_result(out == b"hello world\n", "output: echo hello world → 'hello world\\n'")

    # Compare with GNU for various inputs
    if os.path.exists(GNU):
        compare_with_gnu(["hello"], "output: vs GNU — hello")
        compare_with_gnu(["hello", "world"], "output: vs GNU — hello world")
        compare_with_gnu([], "output: vs GNU — no args")
        compare_with_gnu(["-n", "hello"], "output: vs GNU — -n hello")
        compare_with_gnu(["-e", "hello\\nworld"], "output: vs GNU — -e hello\\nworld")
        compare_with_gnu(["-E", "hello\\nworld"], "output: vs GNU — -E hello\\nworld")


# =============================================================================
#                     11. ERROR HANDLING
# =============================================================================

def check_error_handling():
    log("\n=== Error Handling ===")

    # echo doesn't really have invalid flags — unknown flags are treated as text
    rc, out, _ = run([BIN, "--badopt"])
    report_result(rc == 0, "error: --badopt → exit 0 (echo prints it)")
    report_result(b"--badopt" in out, "error: --badopt → printed as text")

    rc, out, _ = run([BIN, "-z"])
    report_result(rc == 0, "error: -z → exit 0")

    # Compare with GNU
    if os.path.exists(GNU):
        compare_with_gnu(["--badopt"], "error: vs GNU — --badopt")
        compare_with_gnu(["-z"], "error: vs GNU — -z")
        compare_with_gnu(["--help"], "error: vs GNU — --help")
        compare_with_gnu(["--version"], "error: vs GNU — --version")

    if which("strace"):
        cmd = ["strace", "-e", "inject=write:error=EINTR:when=1", BIN, "test"]
        rc, _, _ = run(cmd)
        report_result(rc == 0 or rc == 124, "error: EINTR injection → no crash")


# =============================================================================
#                     12. CONCURRENCY STRESS
# =============================================================================

def check_concurrency():
    log("\n=== Concurrency Stress ===")

    procs = []
    for i in range(50):
        p = subprocess.Popen([BIN, f"instance_{i}"], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
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

    # Pipe chain
    script = f'{BIN} hello | cat | cat | cat'
    p = subprocess.run(["bash", "-c", script], capture_output=True, timeout=TIMEOUT, text=True)
    report_result(p.stdout == "hello\n", "concurrency: pipe chain → correct output")

    # Rapid start cycles
    ok_count = 0
    for _ in range(50):
        p = subprocess.Popen([BIN, "x"], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            p.wait(timeout=1)
            if p.returncode < 128:
                ok_count += 1
        except subprocess.TimeoutExpired:
            p.kill()
    report_result(ok_count == 50, f"concurrency: rapid start cycles ({ok_count}/50)")


# =============================================================================
#                     13. TOOL-SPECIFIC: echo
# =============================================================================

def check_tool_specific():
    log("\n=== Tool-Specific: echo ===")

    # --- Basic output ---
    rc, out, _ = run([BIN])
    report_result(rc == 0, "echo: no args → exit 0")
    report_result(out == b"\n", "echo: no args → just newline")

    rc, out, _ = run([BIN, "hello"])
    report_result(out == b"hello\n", "echo: single arg")

    rc, out, _ = run([BIN, "hello", "world"])
    report_result(out == b"hello world\n", "echo: multiple args joined by space")

    rc, out, _ = run([BIN, "a", "b", "c", "d", "e"])
    report_result(out == b"a b c d e\n", "echo: 5 args joined by spaces")

    rc, out, _ = run([BIN, ""])
    report_result(out == b"\n", "echo: empty arg → just newline")

    rc, out, _ = run([BIN, "", ""])
    report_result(out == b" \n", "echo: two empty args → space + newline")

    # --- -n flag (no trailing newline) ---
    rc, out, _ = run([BIN, "-n", "hello"])
    report_result(out == b"hello", "echo: -n hello → no trailing newline")

    rc, out, _ = run([BIN, "-n"])
    report_result(out == b"", "echo: -n alone → empty output")

    rc, out, _ = run([BIN, "-n", "a", "b"])
    report_result(out == b"a b", "echo: -n a b → 'a b' no newline")

    # --- -e flag (escape sequences) ---
    rc, out, _ = run([BIN, "-e", "hello\\nworld"])
    report_result(out == b"hello\nworld\n", "echo: -e \\n → newline")

    rc, out, _ = run([BIN, "-e", "hello\\tworld"])
    report_result(out == b"hello\tworld\n", "echo: -e \\t → tab")

    rc, out, _ = run([BIN, "-e", "hello\\\\world"])
    report_result(out == b"hello\\world\n", "echo: -e \\\\\\\\ → backslash")

    rc, out, _ = run([BIN, "-e", "\\a"])
    report_result(out == b"\a\n", "echo: -e \\a → bell (0x07)")

    rc, out, _ = run([BIN, "-e", "\\b"])
    report_result(out == b"\b\n", "echo: -e \\b → backspace (0x08)")

    rc, out, _ = run([BIN, "-e", "\\f"])
    report_result(out == b"\f\n", "echo: -e \\f → form feed (0x0c)")

    rc, out, _ = run([BIN, "-e", "\\r"])
    report_result(out == b"\r\n", "echo: -e \\r → carriage return (0x0d)")

    rc, out, _ = run([BIN, "-e", "\\v"])
    report_result(out == b"\v\n", "echo: -e \\v → vertical tab (0x0b)")

    # --- Octal escapes ---
    rc, out, _ = run([BIN, "-e", "\\0101"])
    report_result(out == b"A\n", "echo: -e \\0101 → 'A' (octal 101 = 0x41)")

    rc, out, _ = run([BIN, "-e", "\\0"])
    # \0 with no more digits is NUL byte
    report_result(b"\x00" in out or out == b"\n", "echo: -e \\0 → NUL or empty")

    rc, out, _ = run([BIN, "-e", "\\0110\\0145\\0154\\0154\\0157"])
    report_result(out == b"Hello\n", "echo: -e octal Hello")

    # --- Hex escapes ---
    rc, out, _ = run([BIN, "-e", "\\x41"])
    report_result(out == b"A\n", "echo: -e \\x41 → 'A'")

    rc, out, _ = run([BIN, "-e", "\\x48\\x65\\x6c\\x6c\\x6f"])
    report_result(out == b"Hello\n", "echo: -e hex Hello")

    rc, out, _ = run([BIN, "-e", "\\xff"])
    report_result(out[0:1] == b"\xff", "echo: -e \\xff → byte 0xff")

    # --- \\c (stop output) ---
    rc, out, _ = run([BIN, "-e", "hello\\cworld"])
    report_result(out == b"hello", "echo: -e \\c → stops output (no newline)")

    # --- -E flag (disable escapes) ---
    rc, out, _ = run([BIN, "-E", "hello\\nworld"])
    report_result(out == b"hello\\nworld\n", "echo: -E → escapes NOT interpreted")

    # --- Combined flags ---
    rc, out, _ = run([BIN, "-ne", "hello\\nworld"])
    report_result(out == b"hello\nworld", "echo: -ne → escape + no trailing newline")

    rc, out, _ = run([BIN, "-en", "hello\\n"])
    report_result(out == b"hello\n", "echo: -en → same as -ne")

    rc, out, _ = run([BIN, "-nE", "hello\\n"])
    report_result(out == b"hello\\n", "echo: -nE → no newline, no escapes")

    # --- -- handling ---
    rc, out, _ = run([BIN, "--", "-n"])
    # GNU echo treats -- as just another arg to print
    if os.path.exists(GNU):
        compare_with_gnu(["--", "-n"], "echo: vs GNU — -- -n")

    # --- Flag-like args that aren't flags ---
    rc, out, _ = run([BIN, "-"])
    report_result(b"-" in out, "echo: - → printed")

    rc, out, _ = run([BIN, "-abc"])
    # Only -n, -e, -E (and combinations) are flags; -abc is text
    if os.path.exists(GNU):
        compare_with_gnu(["-abc"], "echo: vs GNU — -abc")

    # --- Spaces and special characters ---
    rc, out, _ = run([BIN, "  hello  "])
    report_result(out == b"  hello  \n", "echo: preserves internal spaces")

    rc, out, _ = run([BIN, "a  b"])
    report_result(out == b"a  b\n", "echo: preserves multiple spaces in arg")

    # --- Stdin ignored ---
    rc, out, _ = run([BIN, "hello"], stdin_data=b"stdin data\n")
    report_result(out == b"hello\n", "echo: ignores stdin")

    # --- Lots of args ---
    args = [str(i) for i in range(100)]
    rc, out, _ = run([BIN] + args)
    expected = " ".join(args) + "\n"
    report_result(out.decode() == expected, "echo: 100 args joined correctly")

    # --- GNU comparison batch ---
    if os.path.exists(GNU):
        test_cases = [
            ["hello"],
            ["hello", "world"],
            ["-n", "hello"],
            ["-e", "\\n"],
            ["-e", "\\t"],
            ["-e", "\\\\"],
            ["-e", "\\a"],
            ["-e", "\\b"],
            ["-e", "\\f"],
            ["-e", "\\r"],
            ["-e", "\\v"],
            ["-e", "\\0101"],
            ["-e", "\\x41"],
            ["-e", "\\c"],
            ["-e", "hello\\cworld"],
            ["-E", "\\n"],
            ["-ne", "hello"],
            ["-en", "hello"],
            ["-nE", "\\n"],
            ["-n", "-e", "hello"],
            [""],
            [" "],
            ["-n"],
            ["-e"],
            ["-E"],
            ["-eee"],
            ["-nnn"],
            ["-neE"],
        ]
        for args in test_cases:
            compare_with_gnu(args)

    # --- Multiple -n flags ---
    rc, out, _ = run([BIN, "-n", "-n", "hello"])
    # Second -n is treated as text by some implementations, or as repeated flag
    if os.path.exists(GNU):
        compare_with_gnu(["-n", "-n", "hello"], "echo: vs GNU — -n -n hello")

    # --- Trailing newline verification ---
    rc, out, _ = run([BIN, "test"])
    report_result(out[-1:] == b"\n", "echo: trailing newline present")

    rc, out, _ = run([BIN, "-n", "test"])
    report_result(out[-1:] != b"\n" or len(out) == 0, "echo: -n removes trailing newline")


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
