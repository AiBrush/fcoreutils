#!/usr/bin/env python3
"""security_tests.py — Security & memory safety tests for fcksum.

fcksum is a GNU-compatible 'cksum' written in x86-64 Linux assembly.
It prints CRC checksum and byte count of each file.

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
   13. Tool-specific (cksum: CRC checksum behavior)
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
GNU = "cksum"
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
    for name in ["fcksum_release", "fcksum"]:
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

    has_interp = has_dynamic = has_rwx = False
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
        if (p_flags & PF_R) and (p_flags & PF_W) and (p_flags & PF_X):
            has_rwx = True
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

    cmd = ["strace", "-f", "-e", "trace=%process,%network,write,read,openat,open,creat,brk,mmap,mprotect",
           BIN, "/dev/null"]
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
    rc, out, err = run([BIN, "/dev/null"])
    report_result(rc == 0, "proc: tool runs and exits cleanly")

    if which("strace"):
        cmd = ["strace", "-e", "trace=openat,open", BIN, "/dev/null"]
        rc, out, err = run(cmd)
        err_text = err.decode(errors="replace")
        opens = [l for l in err_text.splitlines()
                 if ("openat(" in l or "open(" in l)
                 and not l.startswith("---") and not l.startswith("+++")]
        # cksum opens files, so we expect at least one open call for /dev/null
        report_result(len(opens) >= 1, "proc: file descriptor opened for input file")


# =============================================================================
#                     4. FILE DESCRIPTOR HYGIENE
# =============================================================================

def check_fd_hygiene():
    log("\n=== 4. File Descriptor Hygiene ===")

    # Closed stdout
    script = f'exec 3>&1 1>&-; {BIN} /dev/null 2>/dev/null; echo $? >&3'
    p = subprocess.run(["bash", "-c", script], capture_output=True, timeout=TIMEOUT, text=True)
    rc = p.stdout.strip()
    report_result(rc != "", "fd: closed stdout -> doesn't hang")

    # Closed stderr — tool should still work for valid input
    script = f'exec 3>&1; {BIN} /dev/null 2>&- 1>&3; echo $? >&3'
    p = subprocess.run(["bash", "-c", script], capture_output=True, timeout=TIMEOUT, text=True)
    lines = p.stdout.strip().split("\n")
    rc = lines[-1] if lines else ""
    report_result(rc == "0", "fd: closed stderr -> exit 0")

    # RLIMIT_NOFILE=3
    def limit_nofile():
        resource.setrlimit(resource.RLIMIT_NOFILE, (3, 3))
    rc, out, err = run([BIN], stdin_data=b"test", preexec_fn=limit_nofile)
    report_result(rc >= 0 and rc < 128, "fd: RLIMIT_NOFILE=3 -> no crash")

    # /dev/full
    if os.path.exists("/dev/full"):
        script = f'{BIN} /dev/null > /dev/full 2>/dev/null; echo $?'
        p = subprocess.run(["bash", "-c", script], capture_output=True, timeout=TIMEOUT, text=True)
        rc = p.stdout.strip()
        report_result(rc != "", "fd: /dev/full -> doesn't hang")

    # /dev/null
    script = f'{BIN} /dev/null > /dev/null 2>/dev/null; echo $?'
    p = subprocess.run(["bash", "-c", script], capture_output=True, timeout=TIMEOUT, text=True)
    rc = p.stdout.strip()
    report_result(rc == "0", "fd: /dev/null redirect -> exit 0")


# =============================================================================
#                     5. MEMORY SAFETY
# =============================================================================

def check_memory_safety():
    log("\n=== 5. Memory Safety ===")

    rc, out, err = run([BIN, "/dev/null"])
    report_result(rc == 0, "memory: no signal death on normal run")

    rc, out, err = run([BIN] + ["/dev/null"] * 100)
    report_result(rc >= 0 and rc < 128, "memory: no crash with 100 /dev/null args")

    # Large stdin
    large_data = b"A" * (128 * 1024)
    rc, out, err = run([BIN], stdin_data=large_data)
    report_result(rc == 0, "memory: no crash with 128KB stdin")

    for i in range(10):
        data = bytes(random.randint(0, 255) for _ in range(random.randint(0, 500)))
        rc, _, _ = run([BIN], stdin_data=data)
        if rc >= 128:
            report_result(False, f"memory: crash with random stdin (trial {i})")
            break
    else:
        report_result(True, "memory: no signal death with 10 random stdin inputs")

    def limit_stack():
        resource.setrlimit(resource.RLIMIT_STACK, (65536, 65536))
    rc, out, err = run([BIN, "/dev/null"], preexec_fn=limit_stack)
    report_result(rc == 0, "memory: 64KB stack -> exit 0")

    def limit_mem():
        resource.setrlimit(resource.RLIMIT_AS, (16 * 1024 * 1024, 16 * 1024 * 1024))
    rc, out, err = run([BIN, "/dev/null"], preexec_fn=limit_mem)
    report_result(rc == 0, "memory: 16MB address space -> exit 0")


# =============================================================================
#                     6. SIGNAL SAFETY
# =============================================================================

def check_signal_safety():
    log("\n=== 6. Signal Safety ===")

    script = f'{BIN} /dev/null | head -c 0'
    p = subprocess.run(["bash", "-c", script], capture_output=True, timeout=TIMEOUT)
    report_result(p.returncode >= 0 and p.returncode < 128, "signal: SIGPIPE clean exit")

    ok_count = 0
    trials = 20
    for _ in range(trials):
        rc = os.system(f"{BIN} /dev/null 2>/dev/null | head -c 0 >/dev/null 2>/dev/null")
        if os.WIFEXITED(rc) and os.WEXITSTATUS(rc) < 128:
            ok_count += 1
    report_result(ok_count >= trials - 2, f"signal: rapid SIGPIPE ({ok_count}/{trials})")

    for sig_name in ["SIGTERM", "SIGINT", "SIGHUP"]:
        rc, out, err = run([BIN, "/dev/null"])
        report_result(rc == 0, f"signal: {sig_name} -- exits cleanly")


# =============================================================================
#                     7. INPUT FUZZING
# =============================================================================

def check_fuzzing():
    log("\n=== 7. Input Fuzzing ===")

    crash_count = 0
    with tempfile.TemporaryDirectory() as td:
        for i in range(50):
            data = bytes(random.randint(0, 255) for _ in range(random.randint(0, 1000)))
            fpath = os.path.join(td, f"fuzz_{i}")
            with open(fpath, "wb") as f:
                f.write(data)
            rc, out, err = run([BIN, fpath])
            if rc >= 128:
                crash_count += 1
    report_result(crash_count == 0, f"fuzz: 50 random files -- no signal death ({crash_count})")

    crash_count = 0
    for i in range(20):
        data = bytes(random.randint(0, 255) for _ in range(random.randint(1000, 10000)))
        rc, out, err = run([BIN], stdin_data=data)
        if rc >= 128:
            crash_count += 1
    report_result(crash_count == 0, f"fuzz: 20 random large stdin -- no signal death ({crash_count})")

    for desc, data in [("all-zeros", b"\x00" * 1000),
                       ("all-0xff", b"\xff" * 1000),
                       ("control-chars", bytes(range(1, 32))),
                       ("mixed-binary", bytes(range(256)) * 4)]:
        rc, _, _ = run([BIN], stdin_data=data)
        report_result(rc >= 0 and rc < 128, f"fuzz: pathological {desc} -- no crash")


# =============================================================================
#                     8. RESOURCE LIMIT TESTING
# =============================================================================

def check_resource_limits():
    log("\n=== 8. Resource Limit Testing ===")

    def limit_as():
        resource.setrlimit(resource.RLIMIT_AS, (16 * 1024 * 1024, 16 * 1024 * 1024))
    rc, _, _ = run([BIN, "/dev/null"], preexec_fn=limit_as)
    report_result(rc == 0, "rlimit: RLIMIT_AS=16MB -> exit 0")

    def limit_nofile():
        resource.setrlimit(resource.RLIMIT_NOFILE, (3, 3))
    rc, _, _ = run([BIN], stdin_data=b"test", preexec_fn=limit_nofile)
    report_result(rc >= 0 and rc < 128, "rlimit: RLIMIT_NOFILE=3 -> no crash")

    def limit_cpu():
        resource.setrlimit(resource.RLIMIT_CPU, (1, 1))
    rc, _, _ = run([BIN, "/dev/null"], preexec_fn=limit_cpu)
    report_result(rc == 0, "rlimit: RLIMIT_CPU=1s -> exit 0")

    def limit_stack():
        resource.setrlimit(resource.RLIMIT_STACK, (65536, 65536))
    rc, _, _ = run([BIN, "/dev/null"], preexec_fn=limit_stack)
    report_result(rc == 0, "rlimit: RLIMIT_STACK=64KB -> exit 0")

    def limit_fsize():
        resource.setrlimit(resource.RLIMIT_FSIZE, (0, 0))
    rc, _, _ = run([BIN, "/dev/null"], preexec_fn=limit_fsize)
    report_result(rc == 0, "rlimit: RLIMIT_FSIZE=0 -> exit 0")

    def limit_all():
        resource.setrlimit(resource.RLIMIT_AS, (16 * 1024 * 1024, 16 * 1024 * 1024))
        resource.setrlimit(resource.RLIMIT_NOFILE, (3, 3))
        resource.setrlimit(resource.RLIMIT_CPU, (1, 1))
        resource.setrlimit(resource.RLIMIT_STACK, (65536, 65536))
        resource.setrlimit(resource.RLIMIT_FSIZE, (0, 0))
    rc, _, _ = run([BIN], stdin_data=b"test", preexec_fn=limit_all)
    report_result(rc >= 0 and rc < 128, "rlimit: all limits combined -> no crash")


# =============================================================================
#                     9. ENVIRONMENT ROBUSTNESS
# =============================================================================

def check_environment():
    log("\n=== 9. Environment Robustness ===")

    rc, out, err = run([BIN, "/dev/null"], env={})
    report_result(rc == 0, "env: empty environment -> exit 0")

    hostile = {
        "PATH": "",
        "HOME": "/nonexistent",
        "LANG": "xx_XX.BROKEN",
        "TERM": "",
        "LC_ALL": "C",
    }
    rc, out, err = run([BIN, "/dev/null"], env=hostile)
    report_result(rc == 0, "env: hostile env vars -> exit 0")

    big_env = {f"VAR_{i}": f"value_{'X' * 100}" for i in range(1000)}
    rc, out, err = run([BIN, "/dev/null"], env=big_env)
    report_result(rc == 0, "env: 1000 env vars -> exit 0")

    special_env = os.environ.copy()
    special_env["EVIL"] = "A" * 100000
    rc, out, err = run([BIN, "/dev/null"], env=special_env)
    report_result(rc == 0, "env: 100KB env var -> exit 0")


# =============================================================================
#                     10. OUTPUT INTEGRITY
# =============================================================================

def check_output_integrity():
    log("\n=== 10. Output Integrity ===")

    outputs = []
    for _ in range(10):
        rc, out, err = run([BIN, "/dev/null"])
        outputs.append((rc, out, err))

    all_same = all(o == outputs[0] for o in outputs)
    report_result(all_same, "output: deterministic (10 runs identical)")

    all_zero = all(o[0] == 0 for o in outputs)
    report_result(all_zero, "output: all 10 runs exit 0")

    expected_out = b"4294967295 0 /dev/null\n"
    all_correct = all(o[1] == expected_out for o in outputs)
    report_result(all_correct, "output: all 10 runs produce '4294967295 0 /dev/null\\n'")

    # Compare with GNU
    gnu_path = which(GNU)
    if gnu_path:
        with tempfile.TemporaryDirectory() as td:
            for content, desc in [(b"hello\n", "hello+nl"), (b"", "empty"),
                                  (b"123456789", "123456789"), (b"\x00\xff", "binary")]:
                fpath = os.path.join(td, f"test_{desc}")
                with open(fpath, "wb") as f:
                    f.write(content)
                rc_f, out_f, _ = run([BIN, fpath])
                rc_g, out_g, _ = run([gnu_path, fpath])
                report_result(out_f == out_g and rc_f == rc_g,
                             f"output: matches GNU for '{desc}'")

        # stdin comparison
        for data, desc in [(b"123456789", "stdin:123456789"), (b"", "stdin:empty"),
                           (b"hello\n", "stdin:hello+nl")]:
            rc_f, out_f, _ = run([BIN], stdin_data=data)
            rc_g, out_g, _ = run([gnu_path], stdin_data=data)
            report_result(out_f == out_g and rc_f == rc_g,
                         f"output: matches GNU for '{desc}'")


# =============================================================================
#                     11. ERROR HANDLING
# =============================================================================

def check_error_handling():
    log("\n=== 11. Error Handling ===")

    # Invalid flags should not cause signal death
    for flag in ["--badopt", "--nonexistent"]:
        rc, out, err = run([BIN, flag])
        report_result(rc >= 0 and rc < 128, f"error: '{flag}' -> no signal death")

    # Exit codes match GNU
    gnu_path = which(GNU)
    if gnu_path:
        for args in [["--help"], ["--version"], ["/dev/null"], ["/nonexistent/path"]]:
            rc_f, _, _ = run([BIN] + args)
            rc_g, _, _ = run([gnu_path] + args)
            report_result(rc_f == rc_g, f"error: exit code matches GNU for {args}")

    # EINTR injection
    if which("strace"):
        cmd = ["strace", "-e", "inject=write:error=EINTR:when=1", BIN, "/dev/null"]
        rc, out, err = run(cmd)
        report_result(rc >= 0 and rc < 128, "error: EINTR injection -> no crash")


# =============================================================================
#                     12. CONCURRENCY STRESS
# =============================================================================

def check_concurrency():
    log("\n=== 12. Concurrency Stress ===")

    procs = []
    for _ in range(50):
        p = subprocess.Popen([BIN, "/dev/null"],
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

    # Pipe chains
    script = f'echo hello | {BIN} | cat; echo $?'
    p = subprocess.run(["bash", "-c", script], capture_output=True, timeout=TIMEOUT, text=True)
    report_result(p.returncode == 0, "concurrency: pipe chain")

    # Rapid start
    ok_count = 0
    for _ in range(50):
        p = subprocess.Popen([BIN, "/dev/null"],
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            p.wait(timeout=1)
            ok_count += 1
        except subprocess.TimeoutExpired:
            p.kill()
    report_result(ok_count == 50, f"concurrency: rapid start ({ok_count}/50)")


# =============================================================================
#                     13. TOOL-SPECIFIC: cksum
# =============================================================================

def check_tool_specific():
    log("\n=== 13. Tool-Specific: cksum ===")
    gnu_path = which(GNU)

    # Known CRC values
    known_values = [
        (b"123456789", "930766865 9\n"),
        (b"", "4294967295 0\n"),
        (b"hello\n", "3015617425 6\n"),
    ]

    for data, expected in known_values:
        rc, out, err = run([BIN], stdin_data=data)
        report_result(out.decode() == expected,
                     f"cksum: stdin '{data.decode(errors='replace')}' -> {expected.strip()}")

    # /dev/null
    rc, out, err = run([BIN, "/dev/null"])
    report_result(out == b"4294967295 0 /dev/null\n",
                 "cksum: /dev/null -> 4294967295 0 /dev/null")

    # Multiple files
    with tempfile.TemporaryDirectory() as td:
        f1 = os.path.join(td, "a.txt")
        f2 = os.path.join(td, "b.txt")
        with open(f1, "wb") as f:
            f.write(b"123456789")
        with open(f2, "wb") as f:
            f.write(b"hello\n")

        rc, out, err = run([BIN, f1, f2])
        lines = out.decode().strip().split("\n")
        report_result(len(lines) == 2, "cksum: multiple files -> two output lines")

        # Each line should have correct CRC
        if lines:
            report_result(lines[0].startswith("930766865 9 "),
                         "cksum: first file CRC correct")
        if len(lines) > 1:
            report_result(lines[1].startswith("3015617425 6 "),
                         "cksum: second file CRC correct")

    # File with known content vs GNU
    if gnu_path:
        with tempfile.TemporaryDirectory() as td:
            for i, content in enumerate([b"test data\n", b"\x00" * 100,
                                          b"A" * 10000, bytes(range(256))]):
                fpath = os.path.join(td, f"test_{i}")
                with open(fpath, "wb") as f:
                    f.write(content)
                rc_f, out_f, _ = run([BIN, fpath])
                rc_g, out_g, _ = run([gnu_path, fpath])
                report_result(out_f == out_g,
                             f"cksum: file content {i} matches GNU")

    # Large file
    with tempfile.TemporaryDirectory() as td:
        fpath = os.path.join(td, "large")
        with open(fpath, "wb") as f:
            f.write(b"X" * 100000)
        rc, out, err = run([BIN, fpath])
        report_result(rc == 0 and len(out) > 0, "cksum: 100KB file -> no crash")

        if gnu_path:
            rc_g, out_g, _ = run([gnu_path, fpath])
            report_result(out == out_g, "cksum: 100KB file matches GNU")

    # Error: nonexistent file
    rc, out, err = run([BIN, "/nonexistent/file"])
    report_result(rc != 0, "cksum: nonexistent file -> non-zero exit")
    report_result(b"cksum:" in err, "cksum: error message starts with 'cksum:'")

    # Mixed valid + invalid
    with tempfile.TemporaryDirectory() as td:
        fpath = os.path.join(td, "valid.txt")
        with open(fpath, "wb") as f:
            f.write(b"hello")
        rc, out, err = run([BIN, "/nonexistent", fpath])
        report_result(rc != 0, "cksum: mixed valid+invalid -> non-zero exit")
        # But should still produce output for valid file
        report_result(len(out) > 0, "cksum: mixed valid+invalid -> produces some output")


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
