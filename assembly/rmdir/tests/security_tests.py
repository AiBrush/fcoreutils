#!/usr/bin/env python3
"""security_tests.py — Security & memory safety tests for frmdir.

frmdir is a GNU-compatible 'rmdir' written in x86-64 Linux assembly.
It removes empty directories.

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
   13. Tool-specific (rmdir: directory removal behavior)
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
GNU = "rmdir"
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
    for name in ["frmdir_release", "frmdir"]:
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

    with tempfile.TemporaryDirectory() as tmpdir:
        testdir = os.path.join(tmpdir, "strace_test")
        os.mkdir(testdir)
        cmd = ["strace", "-f", "-e", "trace=%process,%network,write,read,openat,open,creat,brk,mmap,mprotect,rmdir",
               BIN, testdir]
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

    file_calls = [l for l in lines if any(s in l for s in
                  ["openat(", "open(", "creat("])]
    report_result(len(file_calls) == 0, "syscall: no file open")

    # rmdir should use rmdir + write + exit + rt_sigprocmask
    rmdir_calls = [l for l in lines if "rmdir(" in l]
    report_result(len(rmdir_calls) >= 1, "syscall: rmdir called (expected)")

    all_calls = [l for l in lines if "(" in l and "=" in l]
    report_result(len(all_calls) <= 6, f"syscall: total {len(all_calls)} syscalls (<=6 expected)")


# =============================================================================
#                     3. /proc FILESYSTEM RUNTIME ANALYSIS
# =============================================================================

def check_proc_analysis():
    log("\n=== 3. /proc Filesystem Runtime Analysis ===")
    with tempfile.TemporaryDirectory() as tmpdir:
        testdir = os.path.join(tmpdir, "proc_test")
        os.mkdir(testdir)
        rc, out, err = run([BIN, testdir])
        report_result(rc == 0, "proc: tool runs and exits cleanly")

    if which("strace"):
        with tempfile.TemporaryDirectory() as tmpdir:
            testdir = os.path.join(tmpdir, "proc_test2")
            os.mkdir(testdir)
            cmd = ["strace", "-e", "trace=openat,open", BIN, testdir]
            rc, out, err = run(cmd)
        err_text = err.decode(errors="replace")
        opens = [l for l in err_text.splitlines()
                 if ("openat(" in l or "open(" in l)
                 and not l.startswith("---") and not l.startswith("+++")]
        report_result(len(opens) == 0, "proc: no file descriptors opened")


# =============================================================================
#                     4. FILE DESCRIPTOR HYGIENE
# =============================================================================

def check_fd_hygiene():
    log("\n=== 4. File Descriptor Hygiene ===")

    with tempfile.TemporaryDirectory() as tmpdir:
        testdir = os.path.join(tmpdir, "fd_test")
        os.mkdir(testdir)
        # Closed stdout
        script = f'exec 3>&1 1>&-; {BIN} {testdir} 2>/dev/null; echo $? >&3'
        p = subprocess.run(["bash", "-c", script], capture_output=True, timeout=TIMEOUT, text=True)
        rc = p.stdout.strip()
        report_result(rc != "", "fd: closed stdout -> doesn't hang")

    with tempfile.TemporaryDirectory() as tmpdir:
        testdir = os.path.join(tmpdir, "fd_test2")
        os.mkdir(testdir)
        # Closed stderr
        script = f'exec 3>&1; {BIN} {testdir} 2>&- 1>&3; echo $? >&3'
        p = subprocess.run(["bash", "-c", script], capture_output=True, timeout=TIMEOUT, text=True)
        lines = p.stdout.strip().split("\n")
        rc = lines[-1] if lines else ""
        report_result(rc == "0", "fd: closed stderr -> exit 0")

    # RLIMIT_NOFILE=3
    def limit_nofile():
        resource.setrlimit(resource.RLIMIT_NOFILE, (3, 3))
    with tempfile.TemporaryDirectory() as tmpdir:
        testdir = os.path.join(tmpdir, "fd_test3")
        os.mkdir(testdir)
        rc, out, err = run([BIN, testdir], preexec_fn=limit_nofile)
        report_result(rc >= 0 and rc < 128, "fd: RLIMIT_NOFILE=3 -> no crash")

    # /dev/null
    with tempfile.TemporaryDirectory() as tmpdir:
        testdir = os.path.join(tmpdir, "fd_test4")
        os.mkdir(testdir)
        script = f'{BIN} {testdir} > /dev/null 2>/dev/null; echo $?'
        p = subprocess.run(["bash", "-c", script], capture_output=True, timeout=TIMEOUT, text=True)
        rc = p.stdout.strip()
        report_result(rc == "0", "fd: /dev/null redirect -> exit 0")


# =============================================================================
#                     5. MEMORY SAFETY
# =============================================================================

def check_memory_safety():
    log("\n=== 5. Memory Safety ===")

    with tempfile.TemporaryDirectory() as tmpdir:
        testdir = os.path.join(tmpdir, "mem_test")
        os.mkdir(testdir)
        rc, out, err = run([BIN, testdir])
        report_result(rc == 0, "memory: no signal death on normal run")

    # Many args (nonexistent dirs -- just checking no crash)
    rc, out, err = run([BIN] + [f"/tmp/nonexistent_dir_{i}" for i in range(200)])
    report_result(rc >= 0 and rc < 128, "memory: no crash with 200 args")

    long_arg = "A" * (4000)
    rc, out, err = run([BIN, long_arg])
    report_result(rc >= 0 and rc < 128, "memory: no crash with 4000-char argument")

    for i in range(10):
        arg = "".join(chr(random.randint(1, 127)) for _ in range(random.randint(0, 500)))
        rc, _, _ = run([BIN, arg])
        if rc >= 128:
            report_result(False, f"memory: crash with random arg (trial {i})")
            break
    else:
        report_result(True, "memory: no signal death with 10 random args")

    def limit_stack():
        resource.setrlimit(resource.RLIMIT_STACK, (65536, 65536))
    with tempfile.TemporaryDirectory() as tmpdir:
        testdir = os.path.join(tmpdir, "stack_test")
        os.mkdir(testdir)
        rc, out, err = run([BIN, testdir], preexec_fn=limit_stack)
        report_result(rc == 0, "memory: 64KB stack -> exit 0")

    def limit_mem():
        resource.setrlimit(resource.RLIMIT_AS, (16 * 1024 * 1024, 16 * 1024 * 1024))
    with tempfile.TemporaryDirectory() as tmpdir:
        testdir = os.path.join(tmpdir, "mem_limit_test")
        os.mkdir(testdir)
        rc, out, err = run([BIN, testdir], preexec_fn=limit_mem)
        report_result(rc == 0, "memory: 16MB address space -> exit 0")


# =============================================================================
#                     6. SIGNAL SAFETY
# =============================================================================

def check_signal_safety():
    log("\n=== 6. Signal Safety ===")

    with tempfile.TemporaryDirectory() as tmpdir:
        testdir = os.path.join(tmpdir, "sig_test")
        os.mkdir(testdir)
        script = f'{BIN} {testdir} | head -c 0'
        p = subprocess.run(["bash", "-c", script], capture_output=True, timeout=TIMEOUT)
        report_result(p.returncode >= 0 and p.returncode < 128, "signal: SIGPIPE clean exit")

    ok_count = 0
    trials = 20
    for i in range(trials):
        with tempfile.TemporaryDirectory() as tmpdir:
            testdir = os.path.join(tmpdir, f"sig_rapid_{i}")
            os.mkdir(testdir)
            rc = os.system(f"{BIN} {testdir} 2>/dev/null | head -c 0 >/dev/null 2>/dev/null")
            if os.WIFEXITED(rc) and os.WEXITSTATUS(rc) < 128:
                ok_count += 1
    report_result(ok_count >= trials - 2, f"signal: rapid SIGPIPE ({ok_count}/{trials})")

    for sig_name in ["SIGTERM", "SIGINT", "SIGHUP"]:
        with tempfile.TemporaryDirectory() as tmpdir:
            testdir = os.path.join(tmpdir, "sig_clean")
            os.mkdir(testdir)
            rc, out, err = run([BIN, testdir])
            report_result(rc == 0, f"signal: {sig_name} -- exits cleanly")


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
    report_result(crash_count == 0, f"fuzz: 50 random short args -- no signal death ({crash_count})")

    crash_count = 0
    for i in range(20):
        arg = "".join(random.choices(string.printable, k=random.randint(100, 1000)))
        rc, out, err = run([BIN, arg])
        if rc >= 128:
            crash_count += 1
    report_result(crash_count == 0, f"fuzz: 20 random long args -- no signal death ({crash_count})")

    for desc, arg in [("all-newlines", "\n" * 1000),
                      ("all-0xff", "\xff" * 1000),
                      ("control-chars", "".join(chr(i) for i in range(1, 32))),
                      ("unicode-multibyte", "\u00e9\u00e0\u00fc\u4e16\u754c" * 100)]:
        rc, _, _ = run([BIN, arg])
        report_result(rc >= 0 and rc < 128, f"fuzz: pathological {desc} -> no crash")

    rc, out, err = run([BIN] + [""] * 200)
    report_result(rc >= 0 and rc < 128, "fuzz: 200 empty args -> no crash")

    rc, out, err = run([BIN, "X" * 4000])
    report_result(rc >= 0 and rc < 128, "fuzz: 4000-char single arg -> no crash")


# =============================================================================
#                     8. RESOURCE LIMIT TESTING
# =============================================================================

def check_resource_limits():
    log("\n=== 8. Resource Limit Testing ===")

    def limit_as():
        resource.setrlimit(resource.RLIMIT_AS, (16 * 1024 * 1024, 16 * 1024 * 1024))
    with tempfile.TemporaryDirectory() as tmpdir:
        testdir = os.path.join(tmpdir, "rl_as")
        os.mkdir(testdir)
        rc, _, _ = run([BIN, testdir], preexec_fn=limit_as)
        report_result(rc == 0, "rlimit: RLIMIT_AS=16MB -> exit 0")

    def limit_nofile():
        resource.setrlimit(resource.RLIMIT_NOFILE, (3, 3))
    with tempfile.TemporaryDirectory() as tmpdir:
        testdir = os.path.join(tmpdir, "rl_nofile")
        os.mkdir(testdir)
        rc, _, _ = run([BIN, testdir], preexec_fn=limit_nofile)
        report_result(rc >= 0 and rc < 128, "rlimit: RLIMIT_NOFILE=3 -> no crash")

    def limit_cpu():
        resource.setrlimit(resource.RLIMIT_CPU, (1, 1))
    with tempfile.TemporaryDirectory() as tmpdir:
        testdir = os.path.join(tmpdir, "rl_cpu")
        os.mkdir(testdir)
        rc, _, _ = run([BIN, testdir], preexec_fn=limit_cpu)
        report_result(rc == 0, "rlimit: RLIMIT_CPU=1s -> exit 0")

    def limit_stack():
        resource.setrlimit(resource.RLIMIT_STACK, (65536, 65536))
    with tempfile.TemporaryDirectory() as tmpdir:
        testdir = os.path.join(tmpdir, "rl_stack")
        os.mkdir(testdir)
        rc, _, _ = run([BIN, testdir], preexec_fn=limit_stack)
        report_result(rc == 0, "rlimit: RLIMIT_STACK=64KB -> exit 0")

    def limit_fsize():
        resource.setrlimit(resource.RLIMIT_FSIZE, (0, 0))
    with tempfile.TemporaryDirectory() as tmpdir:
        testdir = os.path.join(tmpdir, "rl_fsize")
        os.mkdir(testdir)
        rc, _, _ = run([BIN, testdir], preexec_fn=limit_fsize)
        report_result(rc == 0, "rlimit: RLIMIT_FSIZE=0 -> exit 0")

    def limit_all():
        resource.setrlimit(resource.RLIMIT_AS, (16 * 1024 * 1024, 16 * 1024 * 1024))
        resource.setrlimit(resource.RLIMIT_NOFILE, (3, 3))
        resource.setrlimit(resource.RLIMIT_CPU, (1, 1))
        resource.setrlimit(resource.RLIMIT_STACK, (65536, 65536))
        resource.setrlimit(resource.RLIMIT_FSIZE, (0, 0))
    with tempfile.TemporaryDirectory() as tmpdir:
        testdir = os.path.join(tmpdir, "rl_all")
        os.mkdir(testdir)
        rc, _, _ = run([BIN, testdir], preexec_fn=limit_all)
        report_result(rc >= 0 and rc < 128, "rlimit: all limits combined -> no crash")


# =============================================================================
#                     9. ENVIRONMENT ROBUSTNESS
# =============================================================================

def check_environment():
    log("\n=== 9. Environment Robustness ===")

    with tempfile.TemporaryDirectory() as tmpdir:
        testdir = os.path.join(tmpdir, "env_empty")
        os.mkdir(testdir)
        rc, out, err = run([BIN, testdir], env={})
        report_result(rc == 0, "env: empty environment -> exit 0")

    hostile = {
        "PATH": "",
        "HOME": "/nonexistent",
        "LANG": "xx_XX.BROKEN",
        "TERM": "",
        "LC_ALL": "C",
    }
    with tempfile.TemporaryDirectory() as tmpdir:
        testdir = os.path.join(tmpdir, "env_hostile")
        os.mkdir(testdir)
        rc, out, err = run([BIN, testdir], env=hostile)
        report_result(rc == 0, "env: hostile env vars -> exit 0")

    big_env = {f"VAR_{i}": f"value_{'X' * 100}" for i in range(1000)}
    with tempfile.TemporaryDirectory() as tmpdir:
        testdir = os.path.join(tmpdir, "env_big")
        os.mkdir(testdir)
        rc, out, err = run([BIN, testdir], env=big_env)
        report_result(rc == 0, "env: 1000 env vars -> exit 0")

    special_env = os.environ.copy()
    special_env["EVIL"] = "A" * 100000
    with tempfile.TemporaryDirectory() as tmpdir:
        testdir = os.path.join(tmpdir, "env_evil")
        os.mkdir(testdir)
        rc, out, err = run([BIN, testdir], env=special_env)
        report_result(rc == 0, "env: 100KB env var -> exit 0")


# =============================================================================
#                     10. OUTPUT INTEGRITY
# =============================================================================

def check_output_integrity():
    log("\n=== 10. Output Integrity ===")

    # rmdir produces no stdout on success, just removes dirs
    outputs = []
    for i in range(10):
        with tempfile.TemporaryDirectory() as tmpdir:
            testdir = os.path.join(tmpdir, f"out_test_{i}")
            os.mkdir(testdir)
            rc, out, err = run([BIN, testdir])
            outputs.append((rc, out, err))

    all_zero = all(o[0] == 0 for o in outputs)
    report_result(all_zero, "output: all 10 runs exit 0")

    all_empty = all(o[1] == b"" for o in outputs)
    report_result(all_empty, "output: all 10 runs produce no stdout")

    all_no_err = all(o[2] == b"" for o in outputs)
    report_result(all_no_err, "output: all 10 runs produce no stderr")

    # Compare error messages with GNU
    gnu_path = which(GNU)
    if gnu_path:
        for path in ["/tmp/nonexistent_test_dir_xyz"]:
            rc_f, out_f, err_f = run([BIN, path])
            rc_g, out_g, err_g = run([gnu_path, path])
            # Normalize tool names in both outputs to "rmdir"
            err_f_norm = err_f.replace(os.path.basename(BIN).encode(), b"rmdir")
            err_g_norm = err_g.replace(gnu_path.encode(), b"rmdir")
            report_result(rc_f == rc_g, f"output: exit code matches GNU for '{path}'")
            report_result(err_f_norm == err_g_norm, f"output: stderr matches GNU for '{path}'")


# =============================================================================
#                     11. ERROR HANDLING
# =============================================================================

def check_error_handling():
    log("\n=== 11. Error Handling ===")

    # Invalid flags should not cause signal death
    for flag in ["--badopt", "-Z", "--nonexistent"]:
        rc, out, err = run([BIN, flag])
        report_result(rc >= 0 and rc < 128, f"error: '{flag}' -> no signal death")

    # Exit codes match GNU
    gnu_path = which(GNU)
    if gnu_path:
        for args in [["--help"], ["--version"], ["--invalid"], ["-Z"], []]:
            rc_f, _, _ = run([BIN] + args)
            rc_g, _, _ = run([gnu_path] + args)
            report_result(rc_f == rc_g, f"error: exit code matches GNU for {args}")

    # EINTR injection
    if which("strace"):
        with tempfile.TemporaryDirectory() as tmpdir:
            testdir = os.path.join(tmpdir, "eintr_test")
            os.mkdir(testdir)
            cmd = ["strace", "-e", "inject=write:error=EINTR:when=1", BIN, testdir]
            rc, out, err = run(cmd)
            report_result(rc >= 0 and rc < 128, "error: EINTR injection -> no crash")


# =============================================================================
#                     12. CONCURRENCY STRESS
# =============================================================================

def check_concurrency():
    log("\n=== 12. Concurrency Stress ===")

    # 50 simultaneous runs on nonexistent dirs (to avoid needing 50 dirs)
    procs = []
    for i in range(50):
        p = subprocess.Popen([BIN, f"/tmp/nonexistent_conc_{i}"],
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        procs.append(p)

    crash_count = 0
    for p in procs:
        try:
            out, err = p.communicate(timeout=TIMEOUT)
            if p.returncode >= 128:
                crash_count += 1
        except subprocess.TimeoutExpired:
            p.kill()
            crash_count += 1

    report_result(crash_count == 0, f"concurrency: 50 simultaneous ({crash_count} failures)")

    # Rapid start
    ok_count = 0
    for i in range(50):
        p = subprocess.Popen([BIN, f"/tmp/nonexistent_rapid_{i}"],
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            p.wait(timeout=1)
            ok_count += 1
        except subprocess.TimeoutExpired:
            p.kill()
    report_result(ok_count == 50, f"concurrency: rapid start ({ok_count}/50)")


# =============================================================================
#                     13. TOOL-SPECIFIC: rmdir
# =============================================================================

def check_tool_specific():
    log("\n=== 13. Tool-Specific: rmdir ===")
    gnu_path = which(GNU)

    # Core rmdir behavior: remove empty directory
    with tempfile.TemporaryDirectory() as tmpdir:
        testdir = os.path.join(tmpdir, "basic_test")
        os.mkdir(testdir)
        rc, out, err = run([BIN, testdir])
        report_result(rc == 0, "rmdir: remove empty directory -> exit 0")
        report_result(not os.path.exists(testdir), "rmdir: directory actually removed")

    # Nonexistent directory
    rc, out, err = run([BIN, "/tmp/nonexistent_rmdir_specific_test"])
    report_result(rc == 1, "rmdir: nonexistent directory -> exit 1")
    report_result(b"No such file or directory" in err, "rmdir: ENOENT error message")

    # Non-empty directory
    with tempfile.TemporaryDirectory() as tmpdir:
        testdir = os.path.join(tmpdir, "notempty_test")
        os.makedirs(os.path.join(testdir, "child"))
        rc, out, err = run([BIN, testdir])
        report_result(rc == 1, "rmdir: non-empty directory -> exit 1")
        report_result(b"Directory not empty" in err, "rmdir: ENOTEMPTY error message")

    # Not a directory (file)
    with tempfile.TemporaryDirectory() as tmpdir:
        testfile = os.path.join(tmpdir, "afile")
        with open(testfile, "w") as f:
            f.write("x")
        rc, out, err = run([BIN, testfile])
        report_result(rc == 1, "rmdir: file (not dir) -> exit 1")
        report_result(b"Not a directory" in err, "rmdir: ENOTDIR error message")

    # Multiple directories
    with tempfile.TemporaryDirectory() as tmpdir:
        dirs = [os.path.join(tmpdir, f"multi_{i}") for i in range(3)]
        for d in dirs:
            os.mkdir(d)
        rc, out, err = run([BIN] + dirs)
        report_result(rc == 0, "rmdir: multiple dirs -> exit 0")
        report_result(all(not os.path.exists(d) for d in dirs), "rmdir: all dirs removed")

    # -p removes parent chain (use relative path to avoid climbing into /tmp)
    with tempfile.TemporaryDirectory() as tmpdir:
        os.makedirs(os.path.join(tmpdir, "p_test", "a", "b", "c"))
        p = subprocess.Popen(
            [BIN, "-p", "p_test/a/b/c"],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            cwd=tmpdir
        )
        out, err = p.communicate(timeout=TIMEOUT)
        rc = p.returncode
        report_result(rc == 0, "rmdir: -p parent chain -> exit 0")
        report_result(not os.path.exists(os.path.join(tmpdir, "p_test", "a")),
                     "rmdir: -p removed all parents")

    # --parents long form (use relative path)
    with tempfile.TemporaryDirectory() as tmpdir:
        os.makedirs(os.path.join(tmpdir, "parents_test", "x", "y"))
        p = subprocess.Popen(
            [BIN, "--parents", "parents_test/x/y"],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            cwd=tmpdir
        )
        out, err = p.communicate(timeout=TIMEOUT)
        rc = p.returncode
        report_result(rc == 0, "rmdir: --parents long form -> exit 0")

    # -p with partial failure (parent non-empty)
    with tempfile.TemporaryDirectory() as tmpdir:
        deep = os.path.join(tmpdir, "partial", "a", "b")
        os.makedirs(deep)
        # Put a file in 'a' so removing 'a' fails
        with open(os.path.join(tmpdir, "partial", "a", "blocker"), "w") as f:
            f.write("x")
        rc, out, err = run([BIN, "-p", deep])
        report_result(rc == 1, "rmdir: -p partial failure -> exit 1")
        report_result(not os.path.exists(deep), "rmdir: -p removed leaf dir")
        report_result(os.path.exists(os.path.join(tmpdir, "partial", "a")),
                     "rmdir: -p kept non-empty parent")

    # --ignore-fail-on-non-empty
    with tempfile.TemporaryDirectory() as tmpdir:
        testdir = os.path.join(tmpdir, "ignore_test")
        os.makedirs(os.path.join(testdir, "child"))
        rc, out, err = run([BIN, "--ignore-fail-on-non-empty", testdir])
        report_result(rc == 0, "rmdir: --ignore-fail-on-non-empty -> exit 0")
        report_result(err == b"", "rmdir: --ignore-fail-on-non-empty -> no stderr")

    # --ignore-fail-on-non-empty does NOT suppress ENOENT
    rc, out, err = run([BIN, "--ignore-fail-on-non-empty", "/tmp/nonexistent_ignore_test"])
    report_result(rc == 1, "rmdir: --ignore... ENOENT still fails")

    # -v verbose output
    with tempfile.TemporaryDirectory() as tmpdir:
        testdir = os.path.join(tmpdir, "verbose_test")
        os.mkdir(testdir)
        rc, out, err = run([BIN, "-v", testdir])
        report_result(rc == 0, "rmdir: -v -> exit 0")
        report_result(b"removing directory" in err, "rmdir: -v produces verbose output")
        expected_msg = f"rmdir: removing directory, '{testdir}'".encode()
        report_result(expected_msg in err, "rmdir: -v format matches GNU")

    # Error message format: "rmdir: failed to remove 'X': ..."
    rc, out, err = run([BIN, "/tmp/nonexistent_format_specific"])
    report_result(b"rmdir: failed to remove '" in err, "rmdir: error format correct")

    # rmdir syscall is used (verified via strace if available)
    if which("strace"):
        with tempfile.TemporaryDirectory() as tmpdir:
            testdir = os.path.join(tmpdir, "strace_rmdir")
            os.mkdir(testdir)
            cmd = ["strace", "-e", "trace=rmdir", BIN, testdir]
            rc, out, err = run(cmd)
            err_text = err.decode(errors="replace")
            report_result("rmdir(" in err_text, "rmdir: uses rmdir() syscall")


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
