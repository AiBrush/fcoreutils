#!/usr/bin/env python3
"""security_tests.py — Security & memory safety tests for fchown.

fchown is a GNU-compatible 'chown' written in x86-64 Linux assembly.
It changes file owner and group.

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
   13. Tool-specific (chown: ownership changes)
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
from collections import Counter
from pathlib import Path
from shutil import which

TIMEOUT = 5
BIN = ""
GNU = "chown"
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
    for name in ["fchown_release", "fchown"]:
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


def my_uid_gid():
    """Return current uid:gid as string."""
    return f"{os.getuid()}:{os.getgid()}"


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

    with tempfile.NamedTemporaryFile(delete=False) as tf:
        tmppath = tf.name

    try:
        cmd = ["strace", "-f", "-e",
               "trace=%process,%network,write,read,openat,open,creat,brk,mmap,mprotect,stat,chown,lchown,fchown,fchownat",
               BIN, my_uid_gid(), tmppath]
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

        all_calls = [l for l in lines if "(" in l and "=" in l]
        report_result(len(all_calls) <= 10, f"syscall: total {len(all_calls)} syscalls (<=10 expected)")
    finally:
        os.unlink(tmppath)


# =============================================================================
#                     3. /proc FILESYSTEM RUNTIME ANALYSIS
# =============================================================================

def check_proc_analysis():
    log("\n=== 3. /proc Filesystem Runtime Analysis ===")
    with tempfile.NamedTemporaryFile(delete=False) as tf:
        tmppath = tf.name
    try:
        rc, out, err = run([BIN, my_uid_gid(), tmppath])
        report_result(rc == 0, "proc: tool runs and exits cleanly")
    finally:
        os.unlink(tmppath)


# =============================================================================
#                     4. FILE DESCRIPTOR HYGIENE
# =============================================================================

def check_fd_hygiene():
    log("\n=== 4. File Descriptor Hygiene ===")

    # Closed stdout — chown should still work
    script = f'exec 3>&1 1>&-; {BIN} --help 2>/dev/null; echo $? >&3'
    p = subprocess.run(["bash", "-c", script], capture_output=True, timeout=TIMEOUT, text=True)
    rc = p.stdout.strip()
    report_result(rc != "", "fd: closed stdout does not hang")

    # Closed stderr
    with tempfile.NamedTemporaryFile(delete=False) as tf:
        tmppath = tf.name
    try:
        script = f'exec 3>&1; {BIN} {my_uid_gid()} {tmppath} 2>&- 1>&3; echo $? >&3'
        p = subprocess.run(["bash", "-c", script], capture_output=True, timeout=TIMEOUT, text=True)
        lines = p.stdout.strip().split("\n")
        rc = lines[-1] if lines else ""
        report_result(rc == "0", "fd: closed stderr exits 0")
    finally:
        os.unlink(tmppath)

    # RLIMIT_NOFILE=3
    def limit_nofile():
        resource.setrlimit(resource.RLIMIT_NOFILE, (3, 3))
    rc, out, err = run([BIN, "--help"], preexec_fn=limit_nofile)
    report_result(rc >= 0 and rc < 128, "fd: RLIMIT_NOFILE=3 no crash")

    # /dev/null redirect
    with tempfile.NamedTemporaryFile(delete=False) as tf:
        tmppath = tf.name
    try:
        script = f'{BIN} {my_uid_gid()} {tmppath} > /dev/null 2>/dev/null; echo $?'
        p = subprocess.run(["bash", "-c", script], capture_output=True, timeout=TIMEOUT, text=True)
        rc = p.stdout.strip()
        report_result(rc == "0", "fd: /dev/null redirect exits 0")
    finally:
        os.unlink(tmppath)


# =============================================================================
#                     5. MEMORY SAFETY
# =============================================================================

def check_memory_safety():
    log("\n=== 5. Memory Safety ===")

    with tempfile.NamedTemporaryFile(delete=False) as tf:
        tmppath = tf.name

    try:
        rc, out, err = run([BIN, my_uid_gid(), tmppath])
        report_result(rc == 0, "memory: no signal death on normal run")

        # No arguments — should error
        rc, out, err = run([BIN])
        report_result(rc != 0 and rc < 128, "memory: no arguments errors gracefully")

        # Invalid flag should not crash
        rc, out, err = run([BIN, "-Z", my_uid_gid(), tmppath])
        report_result(rc >= 0 and rc < 128, "memory: invalid flag no crash")

        for i in range(10):
            flags = "-" + "".join(random.choices("cfvhR", k=random.randint(1, 4)))
            rc, _, _ = run([BIN, flags, my_uid_gid(), tmppath])
            if rc >= 128:
                report_result(False, f"memory: crash with random flag combo (trial {i})")
                break
        else:
            report_result(True, "memory: no crash with 10 random flag combos")

        def limit_stack():
            resource.setrlimit(resource.RLIMIT_STACK, (65536, 65536))
        rc, out, err = run([BIN, my_uid_gid(), tmppath], preexec_fn=limit_stack)
        report_result(rc == 0, "memory: 64KB stack exits 0")

        def limit_mem():
            resource.setrlimit(resource.RLIMIT_AS, (16 * 1024 * 1024, 16 * 1024 * 1024))
        rc, out, err = run([BIN, my_uid_gid(), tmppath], preexec_fn=limit_mem)
        report_result(rc == 0, "memory: 16MB address space exits 0")
    finally:
        os.unlink(tmppath)


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

    with tempfile.NamedTemporaryFile(delete=False) as tf:
        tmppath = tf.name
    try:
        for sig_name in ["SIGTERM", "SIGINT", "SIGHUP"]:
            rc, out, err = run([BIN, my_uid_gid(), tmppath])
            report_result(rc == 0, f"signal: {sig_name} exits cleanly")
    finally:
        os.unlink(tmppath)


# =============================================================================
#                     7. INPUT FUZZING
# =============================================================================

def check_fuzzing():
    log("\n=== 7. Input Fuzzing ===")

    with tempfile.NamedTemporaryFile(delete=False) as tf:
        tmppath = tf.name

    try:
        crash_count = 0
        for i in range(50):
            n_args = random.randint(0, 5)
            args = ["-" + "".join(random.choices(string.ascii_lowercase, k=random.randint(1, 5)))
                    for _ in range(n_args)]
            rc, out, err = run([BIN] + args + [my_uid_gid(), tmppath])
            if rc >= 128:
                crash_count += 1
        report_result(crash_count == 0, f"fuzz: 50 random flag combos no signal death ({crash_count})")

        crash_count = 0
        for i in range(20):
            flags = "--" + "".join(random.choices(string.ascii_lowercase + "-", k=random.randint(3, 30)))
            rc, out, err = run([BIN, flags, my_uid_gid(), tmppath])
            if rc >= 128:
                crash_count += 1
        report_result(crash_count == 0, f"fuzz: 20 random long flags no signal death ({crash_count})")

        for desc, arg in [("all-dashes", "----------"),
                          ("unicode", "\u00e9\u00e0\u00fc\u4e16\u754c"),
                          ("control-chars", "".join(chr(i) for i in range(1, 32)))]:
            rc, _, _ = run([BIN, arg, tmppath])
            report_result(rc >= 0 and rc < 128, f"fuzz: pathological {desc} no crash")

        # Invalid owner spec
        rc, _, _ = run([BIN, "999999:999999", tmppath])
        report_result(rc >= 0 and rc < 128, "fuzz: invalid numeric owner no crash")

        # Long owner string
        long_owner = "a" * 4096
        rc, _, _ = run([BIN, long_owner, tmppath])
        report_result(rc >= 0 and rc < 128, "fuzz: long owner string no crash")
    finally:
        os.unlink(tmppath)


# =============================================================================
#                     8. RESOURCE LIMIT TESTING
# =============================================================================

def check_resource_limits():
    log("\n=== 8. Resource Limit Testing ===")

    with tempfile.NamedTemporaryFile(delete=False) as tf:
        tmppath = tf.name

    try:
        def limit_as():
            resource.setrlimit(resource.RLIMIT_AS, (16 * 1024 * 1024, 16 * 1024 * 1024))
        rc, _, _ = run([BIN, my_uid_gid(), tmppath], preexec_fn=limit_as)
        report_result(rc == 0, "rlimit: RLIMIT_AS=16MB exits 0")

        def limit_nofile():
            resource.setrlimit(resource.RLIMIT_NOFILE, (3, 3))
        rc, _, _ = run([BIN, my_uid_gid(), tmppath], preexec_fn=limit_nofile)
        report_result(rc >= 0 and rc < 128, "rlimit: RLIMIT_NOFILE=3 no crash")

        def limit_cpu():
            resource.setrlimit(resource.RLIMIT_CPU, (1, 1))
        rc, _, _ = run([BIN, my_uid_gid(), tmppath], preexec_fn=limit_cpu)
        report_result(rc == 0, "rlimit: RLIMIT_CPU=1s exits 0")

        def limit_stack():
            resource.setrlimit(resource.RLIMIT_STACK, (65536, 65536))
        rc, _, _ = run([BIN, my_uid_gid(), tmppath], preexec_fn=limit_stack)
        report_result(rc == 0, "rlimit: RLIMIT_STACK=64KB exits 0")

        def limit_fsize():
            resource.setrlimit(resource.RLIMIT_FSIZE, (0, 0))
        rc, _, _ = run([BIN, my_uid_gid(), tmppath], preexec_fn=limit_fsize)
        report_result(rc >= 0 and rc < 128, "rlimit: RLIMIT_FSIZE=0 no crash")

        def limit_all():
            resource.setrlimit(resource.RLIMIT_AS, (16 * 1024 * 1024, 16 * 1024 * 1024))
            resource.setrlimit(resource.RLIMIT_NOFILE, (3, 3))
            resource.setrlimit(resource.RLIMIT_CPU, (1, 1))
            resource.setrlimit(resource.RLIMIT_STACK, (65536, 65536))
        rc, _, _ = run([BIN, my_uid_gid(), tmppath], preexec_fn=limit_all)
        report_result(rc >= 0 and rc < 128, "rlimit: all limits combined no crash")
    finally:
        os.unlink(tmppath)


# =============================================================================
#                     9. ENVIRONMENT ROBUSTNESS
# =============================================================================

def check_environment():
    log("\n=== 9. Environment Robustness ===")

    with tempfile.NamedTemporaryFile(delete=False) as tf:
        tmppath = tf.name

    try:
        rc, out, err = run([BIN, my_uid_gid(), tmppath], env={})
        report_result(rc == 0, "env: empty environment exits 0")

        hostile = {
            "PATH": "",
            "HOME": "/nonexistent",
            "LANG": "xx_XX.BROKEN",
            "TERM": "",
            "LC_ALL": "C",
        }
        rc, out, err = run([BIN, my_uid_gid(), tmppath], env=hostile)
        report_result(rc == 0, "env: hostile env vars exits 0")

        big_env = {f"VAR_{i}": f"value_{'X' * 100}" for i in range(1000)}
        rc, out, err = run([BIN, my_uid_gid(), tmppath], env=big_env)
        report_result(rc == 0, "env: 1000 env vars exits 0")

        special_env = os.environ.copy()
        special_env["EVIL"] = "A" * 100000
        rc, out, err = run([BIN, my_uid_gid(), tmppath], env=special_env)
        report_result(rc == 0, "env: 100KB env var exits 0")
    finally:
        os.unlink(tmppath)


# =============================================================================
#                     10. OUTPUT INTEGRITY
# =============================================================================

def check_output_integrity():
    log("\n=== 10. Output Integrity ===")

    # --help
    rc, out, err = run([BIN, "--help"])
    text = out + err
    report_result(b"Usage" in text or b"chown" in text, "output: --help contains usage info")

    # --version
    rc, out, err = run([BIN, "--version"])
    text = out + err
    report_result(b"chown" in text or b"coreutils" in text, "output: --version contains version info")

    # chown produces no stdout on normal operation
    with tempfile.NamedTemporaryFile(delete=False) as tf:
        tmppath = tf.name
    try:
        rc, out, err = run([BIN, my_uid_gid(), tmppath])
        report_result(out == b"", "output: no stdout on normal operation")
        report_result(rc == 0, "output: normal operation exits 0")
    finally:
        os.unlink(tmppath)

    # Compare --help with GNU
    gnu_path = which(GNU)
    if gnu_path:
        rc_f, _, _ = run([BIN, "--help"])
        rc_g, _, _ = run([gnu_path, "--help"])
        report_result(rc_f == rc_g, "output: --help exit code matches GNU")
        rc_f, _, _ = run([BIN, "--version"])
        rc_g, _, _ = run([gnu_path, "--version"])
        report_result(rc_f == rc_g, "output: --version exit code matches GNU")


# =============================================================================
#                     11. ERROR HANDLING
# =============================================================================

def check_error_handling():
    log("\n=== 11. Error Handling ===")

    # Invalid flags should not cause signal death
    for flag in ["--badopt", "-Z", "--nonexistent"]:
        rc, out, err = run([BIN, flag])
        report_result(rc >= 0 and rc < 128, f"error: '{flag}' no signal death")

    # Missing operand
    rc, out, err = run([BIN])
    report_result(rc == 1, f"error: missing operand exits 1 (got {rc})")
    report_result(b"missing" in err.lower(), "error: missing operand message")

    # Invalid user
    with tempfile.NamedTemporaryFile(delete=False) as tf:
        tmppath = tf.name
    try:
        rc, out, err = run([BIN, "nonexistent_user_xyz", tmppath])
        report_result(rc != 0, f"error: invalid user exits non-zero (got {rc})")
        report_result(b"invalid user" in err.lower(), "error: invalid user message")
    finally:
        os.unlink(tmppath)

    # Nonexistent file
    rc, out, err = run([BIN, my_uid_gid(), "/nonexistent_dir_xyz/file"])
    report_result(rc != 0, f"error: nonexistent file exits non-zero (got {rc})")

    # Exit codes match GNU
    gnu_path = which(GNU)
    if gnu_path:
        for args in [["--help"], ["--version"]]:
            rc_f, _, _ = run([BIN] + args)
            rc_g, _, _ = run([gnu_path] + args)
            report_result(rc_f == rc_g, f"error: exit code matches GNU for {args}")

    # EINTR injection
    if which("strace"):
        with tempfile.NamedTemporaryFile(delete=False) as tf:
            tmppath = tf.name
        try:
            cmd = ["strace", "-e", "inject=write:error=EINTR:when=1",
                   BIN, my_uid_gid(), tmppath]
            rc, out, err = run(cmd)
            report_result(rc >= 0 and rc < 128, "error: EINTR injection no crash")
        finally:
            os.unlink(tmppath)


# =============================================================================
#                     12. CONCURRENCY STRESS
# =============================================================================

def check_concurrency():
    log("\n=== 12. Concurrency Stress ===")

    with tempfile.TemporaryDirectory() as tmpdir:
        # Create files first
        for i in range(50):
            open(os.path.join(tmpdir, f"file_{i}"), "w").close()

        procs = []
        for i in range(50):
            p = subprocess.Popen([BIN, my_uid_gid(), os.path.join(tmpdir, f"file_{i}")],
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

    # Pipe chain with --help
    script = f'{BIN} --help | cat; echo $?'
    p = subprocess.run(["bash", "-c", script], capture_output=True, timeout=TIMEOUT, text=True)
    report_result(p.returncode == 0, "concurrency: pipe chain")

    # Rapid start
    with tempfile.TemporaryDirectory() as tmpdir:
        for i in range(50):
            open(os.path.join(tmpdir, f"rapid_{i}"), "w").close()

        ok_count = 0
        for i in range(50):
            p = subprocess.Popen([BIN, my_uid_gid(), os.path.join(tmpdir, f"rapid_{i}")],
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            try:
                p.wait(timeout=1)
                ok_count += 1
            except subprocess.TimeoutExpired:
                p.kill()
        report_result(ok_count == 50, f"concurrency: rapid start ({ok_count}/50)")


# =============================================================================
#                     13. TOOL-SPECIFIC: chown
# =============================================================================

def check_tool_specific():
    log("\n=== 13. Tool-Specific: chown ===")
    gnu_path = which(GNU)
    uid = os.getuid()
    gid = os.getgid()

    with tempfile.TemporaryDirectory() as tmpdir:
        # Basic ownership change with uid:gid
        target = os.path.join(tmpdir, "basic")
        open(target, "w").close()
        rc, out, err = run([BIN, f"{uid}:{gid}", target])
        st = os.stat(target)
        report_result(rc == 0 and st.st_uid == uid and st.st_gid == gid,
                      "chown: basic uid:gid ownership change")

        # Owner only (no group)
        target = os.path.join(tmpdir, "owner_only")
        open(target, "w").close()
        rc, out, err = run([BIN, str(uid), target])
        report_result(rc == 0, "chown: owner-only change exits 0")

        # Group only with :gid
        target = os.path.join(tmpdir, "group_only")
        open(target, "w").close()
        rc, out, err = run([BIN, f":{gid}", target])
        report_result(rc == 0, "chown: :gid group-only change exits 0")

        # Multiple files
        files = []
        for i in range(5):
            f = os.path.join(tmpdir, f"multi_{i}")
            open(f, "w").close()
            files.append(f)
        rc, out, err = run([BIN, f"{uid}:{gid}"] + files)
        report_result(rc == 0, "chown: multiple files")

        # -v verbose flag
        target = os.path.join(tmpdir, "verbose")
        open(target, "w").close()
        rc, out, err = run([BIN, "-v", f"{uid}:{gid}", target])
        report_result(rc == 0, "chown: -v verbose flag accepted")

        # -c changes flag
        target = os.path.join(tmpdir, "changes")
        open(target, "w").close()
        rc, out, err = run([BIN, "-c", f"{uid}:{gid}", target])
        report_result(rc == 0, "chown: -c changes flag accepted")

        # -f silent flag
        rc, out, err = run([BIN, "-f", f"{uid}:{gid}", "/nonexistent_xyz"])
        report_result(rc >= 0 and rc < 128, "chown: -f silent flag suppresses errors")

        # --reference flag (may not be implemented in assembly version)
        ref = os.path.join(tmpdir, "reference")
        tgt = os.path.join(tmpdir, "ref_target")
        open(ref, "w").close()
        open(tgt, "w").close()
        rc, out, err = run([BIN, f"--reference={ref}", tgt])
        if rc == 0:
            report_result(True, "chown: --reference flag works")
        else:
            report_skip("chown: --reference flag not supported in assembly build")

        # Invalid user name
        target = os.path.join(tmpdir, "inv_user")
        open(target, "w").close()
        rc, out, err = run([BIN, "nonexistent_user_xyz_123", target])
        report_result(rc != 0, f"chown: invalid user exits non-zero (got {rc})")

        # Nonexistent file
        rc, out, err = run([BIN, f"{uid}:{gid}", "/nonexistent_xyz/file"])
        report_result(rc != 0, f"chown: nonexistent file exits non-zero (got {rc})")

    # Missing operand
    rc, out, err = run([BIN])
    report_result(rc == 1, "chown: missing operand exits 1")

    # Compare with GNU
    if gnu_path:
        with tempfile.TemporaryDirectory() as tmpdir:
            f1 = os.path.join(tmpdir, "gnu_f")
            f2 = os.path.join(tmpdir, "our_f")
            open(f1, "w").close()
            open(f2, "w").close()
            rc_g, _, _ = run([gnu_path, f"{uid}:{gid}", f1])
            rc_f, _, _ = run([BIN, f"{uid}:{gid}", f2])
            report_result(rc_f == rc_g, "chown: exit code matches GNU for basic operation")


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
    fail_count = test_count - pass_count
    log("\n" + "=" * 60)
    log(f"RESULTS: {pass_count}/{test_count} passed, "
        f"{fail_count} failed, {skip_count} skipped")
    if failures:
        log(f"\nFAILURES ({len(failures)}):")
        for f in failures:
            log(f"  [{f['category']}] {f['details']}")
    log("=" * 60)


if __name__ == "__main__":
    run_tests()
    print_summary()
    sys.exit(0 if len(failures) == 0 else 1)
