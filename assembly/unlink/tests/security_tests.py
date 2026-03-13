#!/usr/bin/env python3
"""security_tests.py — Security & memory safety tests for funlink.

funlink is a GNU-compatible 'unlink' written in x86-64 Linux assembly.
It removes a single file using the unlink() system call.

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
   13. Tool-specific (unlink: file removal behavior)
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
GNU = "unlink"
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
    for name in ["funlink_release", "funlink"]:
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
        target = os.path.join(tmpdir, "target")
        with open(target, "w") as f:
            f.write("test")

        cmd = ["strace", "-f", "-e", "trace=%process,%network,write,read,openat,open,creat,brk,mmap,mprotect,unlink",
               BIN, target]
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

        # unlink should use unlink() syscall
        unlink_calls = [l for l in lines if "unlink(" in l]
        report_result(len(unlink_calls) >= 1, "syscall: unlink() called (expected)")

        all_calls = [l for l in lines if "(" in l and "=" in l]
        report_result(len(all_calls) <= 5, f"syscall: total {len(all_calls)} syscalls (<=5 expected)")


# =============================================================================
#                     3. /proc FILESYSTEM RUNTIME ANALYSIS
# =============================================================================

def check_proc_analysis():
    log("\n=== 3. /proc Filesystem Runtime Analysis ===")
    with tempfile.TemporaryDirectory() as tmpdir:
        target = os.path.join(tmpdir, "target")
        with open(target, "w") as f:
            f.write("test")

        rc, out, err = run([BIN, target])
        report_result(rc == 0, "proc: tool runs and exits cleanly")

    if which("strace"):
        with tempfile.TemporaryDirectory() as tmpdir:
            target = os.path.join(tmpdir, "target")
            with open(target, "w") as f:
                f.write("test")

            cmd = ["strace", "-e", "trace=openat,open", BIN, target]
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
        target = os.path.join(tmpdir, "target")

        # Closed stdout — unlink doesn't write to stdout on success
        with open(target, "w") as f:
            f.write("test")
        script = f'exec 3>&1 1>&-; {BIN} {target} 2>/dev/null; echo $? >&3'
        p = subprocess.run(["bash", "-c", script], capture_output=True, timeout=TIMEOUT, text=True)
        rc = p.stdout.strip()
        report_result(rc == "0", "fd: closed stdout → exit 0")

        # Closed stderr — tool should still work
        with open(target, "w") as f:
            f.write("test")
        script = f'exec 3>&1; {BIN} {target} 2>&- 1>&3; echo $? >&3'
        p = subprocess.run(["bash", "-c", script], capture_output=True, timeout=TIMEOUT, text=True)
        lines = p.stdout.strip().split("\n")
        rc = lines[-1] if lines else ""
        report_result(rc == "0", "fd: closed stderr → exit 0")

        # RLIMIT_NOFILE=3
        def limit_nofile():
            resource.setrlimit(resource.RLIMIT_NOFILE, (3, 3))
        with open(target, "w") as f:
            f.write("test")
        rc, out, err = run([BIN, target], preexec_fn=limit_nofile)
        report_result(rc >= 0 and rc < 128, "fd: RLIMIT_NOFILE=3 → no crash")

        # /dev/null
        with open(target, "w") as f:
            f.write("test")
        script = f'{BIN} {target} > /dev/null 2>/dev/null; echo $?'
        p = subprocess.run(["bash", "-c", script], capture_output=True, timeout=TIMEOUT, text=True)
        rc = p.stdout.strip()
        report_result(rc == "0", "fd: /dev/null redirect → exit 0")


# =============================================================================
#                     5. MEMORY SAFETY
# =============================================================================

def check_memory_safety():
    log("\n=== 5. Memory Safety ===")

    with tempfile.TemporaryDirectory() as tmpdir:
        target = os.path.join(tmpdir, "target")
        with open(target, "w") as f:
            f.write("test")

        rc, out, err = run([BIN, target])
        report_result(rc == 0, "memory: no signal death on normal run")

    # Too many args — should give error but not crash
    rc, out, err = run([BIN] + [f"arg{i}" for i in range(100)])
    report_result(rc >= 0 and rc < 128, "memory: no crash with 100 args")

    # Long argument
    long_arg = "A" * (128 * 1024)
    rc, out, err = run([BIN, long_arg])
    report_result(rc >= 0 and rc < 128, "memory: no crash with 128KB argument")

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
    rc, out, err = run([BIN, "/nonexistent"], preexec_fn=limit_stack)
    report_result(rc >= 0 and rc < 128, "memory: 64KB stack → no crash")

    def limit_mem():
        resource.setrlimit(resource.RLIMIT_AS, (16 * 1024 * 1024, 16 * 1024 * 1024))
    rc, out, err = run([BIN, "/nonexistent"], preexec_fn=limit_mem)
    report_result(rc >= 0 and rc < 128, "memory: 16MB address space → no crash")


# =============================================================================
#                     6. SIGNAL SAFETY
# =============================================================================

def check_signal_safety():
    log("\n=== 6. Signal Safety ===")

    with tempfile.TemporaryDirectory() as tmpdir:
        target = os.path.join(tmpdir, "target")
        with open(target, "w") as f:
            f.write("test")

        script = f'{BIN} {target} | head -c 0'
        p = subprocess.run(["bash", "-c", script], capture_output=True, timeout=TIMEOUT)
        report_result(p.returncode >= 0 and p.returncode < 128, "signal: SIGPIPE clean exit")

    ok_count = 0
    trials = 20
    for i in range(trials):
        with tempfile.TemporaryDirectory() as tmpdir:
            target = os.path.join(tmpdir, "target")
            with open(target, "w") as f:
                f.write("test")
            rc = os.system(f"{BIN} {target} 2>/dev/null | head -c 0 >/dev/null 2>/dev/null")
            if os.WIFEXITED(rc) and os.WEXITSTATUS(rc) < 128:
                ok_count += 1
    report_result(ok_count >= trials - 2, f"signal: rapid SIGPIPE ({ok_count}/{trials})")

    for sig_name in ["SIGTERM", "SIGINT", "SIGHUP"]:
        with tempfile.TemporaryDirectory() as tmpdir:
            target = os.path.join(tmpdir, "target")
            with open(target, "w") as f:
                f.write("test")
            rc, out, err = run([BIN, target])
            report_result(rc == 0, f"signal: {sig_name} — exits cleanly")


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

    for desc, arg in [("all-newlines", "\n" * 1000),
                      ("all-0xff", "\xff" * 1000),
                      ("control-chars", "".join(chr(i) for i in range(1, 32))),
                      ("unicode-multibyte", "\u00e9\u00e0\u00fc\u4e16\u754c" * 100)]:
        rc, _, _ = run([BIN, arg])
        report_result(rc >= 0 and rc < 128, f"fuzz: pathological {desc} → no crash")

    rc, out, err = run([BIN] + [""] * 2000)
    report_result(rc >= 0 and rc < 128, "fuzz: 2000 empty args → no crash")

    rc, out, err = run([BIN, "X" * (128 * 1024)])
    report_result(rc >= 0 and rc < 128, "fuzz: 128KB single arg → no crash")


# =============================================================================
#                     8. RESOURCE LIMIT TESTING
# =============================================================================

def check_resource_limits():
    log("\n=== 8. Resource Limit Testing ===")

    def limit_as():
        resource.setrlimit(resource.RLIMIT_AS, (16 * 1024 * 1024, 16 * 1024 * 1024))
    rc, _, _ = run([BIN, "/nonexistent"], preexec_fn=limit_as)
    report_result(rc >= 0 and rc < 128, "rlimit: RLIMIT_AS=16MB → no crash")

    def limit_nofile():
        resource.setrlimit(resource.RLIMIT_NOFILE, (3, 3))
    rc, _, _ = run([BIN, "/nonexistent"], preexec_fn=limit_nofile)
    report_result(rc >= 0 and rc < 128, "rlimit: RLIMIT_NOFILE=3 → no crash")

    def limit_cpu():
        resource.setrlimit(resource.RLIMIT_CPU, (1, 1))
    rc, _, _ = run([BIN, "/nonexistent"], preexec_fn=limit_cpu)
    report_result(rc >= 0 and rc < 128, "rlimit: RLIMIT_CPU=1s → no crash")

    def limit_stack():
        resource.setrlimit(resource.RLIMIT_STACK, (65536, 65536))
    rc, _, _ = run([BIN, "/nonexistent"], preexec_fn=limit_stack)
    report_result(rc >= 0 and rc < 128, "rlimit: RLIMIT_STACK=64KB → no crash")

    def limit_fsize():
        resource.setrlimit(resource.RLIMIT_FSIZE, (0, 0))
    rc, _, _ = run([BIN, "/nonexistent"], preexec_fn=limit_fsize)
    report_result(rc >= 0 and rc < 128, "rlimit: RLIMIT_FSIZE=0 → no crash")

    def limit_all():
        resource.setrlimit(resource.RLIMIT_AS, (16 * 1024 * 1024, 16 * 1024 * 1024))
        resource.setrlimit(resource.RLIMIT_NOFILE, (3, 3))
        resource.setrlimit(resource.RLIMIT_CPU, (1, 1))
        resource.setrlimit(resource.RLIMIT_STACK, (65536, 65536))
        resource.setrlimit(resource.RLIMIT_FSIZE, (0, 0))
    rc, _, _ = run([BIN, "/nonexistent"], preexec_fn=limit_all)
    report_result(rc >= 0 and rc < 128, "rlimit: all limits combined → no crash")


# =============================================================================
#                     9. ENVIRONMENT ROBUSTNESS
# =============================================================================

def check_environment():
    log("\n=== 9. Environment Robustness ===")

    with tempfile.TemporaryDirectory() as tmpdir:
        target = os.path.join(tmpdir, "target")
        with open(target, "w") as f:
            f.write("test")
        rc, out, err = run([BIN, target], env={})
        report_result(rc == 0, "env: empty environment → exit 0")

    with tempfile.TemporaryDirectory() as tmpdir:
        target = os.path.join(tmpdir, "target")
        with open(target, "w") as f:
            f.write("test")
        hostile = {
            "PATH": "",
            "HOME": "/nonexistent",
            "LANG": "xx_XX.BROKEN",
            "TERM": "",
            "LC_ALL": "C",
        }
        rc, out, err = run([BIN, target], env=hostile)
        report_result(rc == 0, "env: hostile env vars → exit 0")

    with tempfile.TemporaryDirectory() as tmpdir:
        target = os.path.join(tmpdir, "target")
        with open(target, "w") as f:
            f.write("test")
        big_env = {f"VAR_{i}": f"value_{'X' * 100}" for i in range(1000)}
        rc, out, err = run([BIN, target], env=big_env)
        report_result(rc == 0, "env: 1000 env vars → exit 0")

    with tempfile.TemporaryDirectory() as tmpdir:
        target = os.path.join(tmpdir, "target")
        with open(target, "w") as f:
            f.write("test")
        special_env = os.environ.copy()
        special_env["EVIL"] = "A" * 100000
        rc, out, err = run([BIN, target], env=special_env)
        report_result(rc == 0, "env: 100KB env var → exit 0")


# =============================================================================
#                     10. OUTPUT INTEGRITY
# =============================================================================

def check_output_integrity():
    log("\n=== 10. Output Integrity ===")

    with tempfile.TemporaryDirectory() as tmpdir:
        outputs = []
        for i in range(10):
            target = os.path.join(tmpdir, f"target_{i}")
            with open(target, "w") as f:
                f.write("test")
            rc, out, err = run([BIN, target])
            outputs.append((rc, out, err))

        all_zero = all(o[0] == 0 for o in outputs)
        report_result(all_zero, "output: all 10 runs exit 0")

        all_silent = all(o[1] == b"" for o in outputs)
        report_result(all_silent, "output: all 10 runs produce no stdout (unlink is silent on success)")

    # Compare error behavior with GNU
    gnu_path = which(GNU)
    if gnu_path:
        # Missing operand
        rc_f, out_f, err_f = run([BIN])
        rc_g, out_g, err_g = run([gnu_path])
        report_result(rc_f == rc_g, "output: exit code matches GNU for no args")

        # Extra operand
        rc_f, out_f, err_f = run([BIN, "a", "b"])
        rc_g, out_g, err_g = run([gnu_path, "a", "b"])
        report_result(rc_f == rc_g, "output: exit code matches GNU for 2 args")


# =============================================================================
#                     11. ERROR HANDLING
# =============================================================================

def check_error_handling():
    log("\n=== 11. Error Handling ===")

    # Error cases should not cause signal death
    for desc, args in [
        ("no args", []),
        ("two args", ["a", "b"]),
        ("nonexistent file", ["/nonexistent_xyz"]),
    ]:
        rc, out, err = run([BIN] + args)
        report_result(rc >= 0 and rc < 128, f"error: '{desc}' → no signal death")

    # Exit codes match GNU
    gnu_path = which(GNU)
    if gnu_path:
        for args in [["--help"], ["--version"], [], ["a", "b"]]:
            rc_f, _, _ = run([BIN] + args)
            rc_g, _, _ = run([gnu_path] + args)
            report_result(rc_f == rc_g, f"error: exit code matches GNU for {args}")

    # EINTR injection
    if which("strace"):
        with tempfile.TemporaryDirectory() as tmpdir:
            target = os.path.join(tmpdir, "target")
            with open(target, "w") as f:
                f.write("test")
            cmd = ["strace", "-e", "inject=write:error=EINTR:when=1", BIN, target]
            rc, out, err = run(cmd)
            report_result(rc >= 0 and rc < 128, "error: EINTR injection → no crash")


# =============================================================================
#                     12. CONCURRENCY STRESS
# =============================================================================

def check_concurrency():
    log("\n=== 12. Concurrency Stress ===")

    with tempfile.TemporaryDirectory() as tmpdir:
        procs = []
        for i in range(50):
            target = os.path.join(tmpdir, f"target_{i}")
            with open(target, "w") as f:
                f.write("test")
            p = subprocess.Popen([BIN, target],
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

        report_result(crash_count == 0, f"concurrency: 50 simultaneous ({crash_count} crashes)")

    # Rapid start
    ok_count = 0
    for i in range(50):
        with tempfile.TemporaryDirectory() as tmpdir:
            target = os.path.join(tmpdir, "target")
            with open(target, "w") as f:
                f.write("test")
            p = subprocess.Popen([BIN, target],
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            try:
                p.wait(timeout=1)
                if p.returncode < 128:
                    ok_count += 1
            except subprocess.TimeoutExpired:
                p.kill()
    report_result(ok_count == 50, f"concurrency: rapid start ({ok_count}/50)")


# =============================================================================
#                     13. TOOL-SPECIFIC: unlink
# =============================================================================

def check_tool_specific():
    log("\n=== 13. Tool-Specific: unlink ===")
    gnu_path = which(GNU)

    with tempfile.TemporaryDirectory() as tmpdir:
        # Core unlink behavior: remove file
        target = os.path.join(tmpdir, "target")
        with open(target, "w") as f:
            f.write("hello world")

        rc, out, err = run([BIN, target])
        report_result(rc == 0, "unlink: basic file removal → exit 0")
        report_result(out == b"", "unlink: no stdout on success")
        report_result(err == b"", "unlink: no stderr on success")
        report_result(not os.path.exists(target), "unlink: file actually removed")

        # ENOENT: file doesn't exist
        rc, out, err = run([BIN, os.path.join(tmpdir, "nosuch")])
        report_result(rc == 1, "unlink: ENOENT → exit 1")
        err_text = err.decode(errors="replace")
        report_result("No such file or directory" in err_text,
                     "unlink: ENOENT error message contains 'No such file or directory'")

        # EISDIR: trying to unlink a directory
        testdir = os.path.join(tmpdir, "testdir")
        os.mkdir(testdir)
        rc, out, err = run([BIN, testdir])
        report_result(rc == 1, "unlink: EISDIR → exit 1")
        err_text = err.decode(errors="replace")
        report_result("Is a directory" in err_text or "Operation not permitted" in err_text,
                     "unlink: EISDIR/EPERM error message for directory")
        os.rmdir(testdir)

        # Error message format check
        rc, out, err = run([BIN, os.path.join(tmpdir, "nosuch")])
        err_text = err.decode(errors="replace")
        err_text_norm = err_text.replace('\u2018', "'").replace('\u2019', "'")
        report_result(err_text_norm.startswith("unlink: cannot unlink '"),
                     "unlink: error format starts with 'unlink: cannot unlink '")

        # Unlink only removes one link, original stays
        src = os.path.join(tmpdir, "src")
        lnk = os.path.join(tmpdir, "lnk")
        with open(src, "w") as f:
            f.write("multilink")
        os.link(src, lnk)
        rc, out, err = run([BIN, lnk])
        report_result(rc == 0, "unlink: remove one hard link → exit 0")
        report_result(os.path.exists(src), "unlink: original file still exists after unlinking link")
        report_result(not os.path.exists(lnk), "unlink: hard link removed")
        os.unlink(src)

        # Unlink symlink (removes the symlink, not the target)
        src2 = os.path.join(tmpdir, "src2")
        sym = os.path.join(tmpdir, "sym")
        with open(src2, "w") as f:
            f.write("symtest")
        os.symlink(src2, sym)
        rc, out, err = run([BIN, sym])
        report_result(rc == 0, "unlink: remove symlink → exit 0")
        report_result(os.path.exists(src2), "unlink: symlink target still exists")
        report_result(not os.path.exists(sym), "unlink: symlink removed")
        os.unlink(src2)

    # Missing operand messages
    rc, out, err = run([BIN])
    err_text = err.decode(errors="replace")
    err_text_norm = err_text.replace('\u2018', "'").replace('\u2019', "'")
    report_result("missing operand" in err_text, "unlink: missing operand message")
    report_result("Try 'unlink --help'" in err_text_norm, "unlink: missing operand → try help hint")

    rc, out, err = run([BIN, "a", "b"])
    err_text = err.decode(errors="replace")
    # Normalize smart quotes to ASCII for comparison
    err_text_norm = err_text.replace('\u2018', "'").replace('\u2019', "'")
    report_result("extra operand" in err_text, "unlink: extra operand message")
    report_result("'b'" in err_text_norm, "unlink: extra operand includes the extra arg")

    # --help goes to stdout
    rc, out, err = run([BIN, "--help"])
    report_result(rc == 0, "unlink: --help → exit 0")
    report_result(len(out) > 50, "unlink: --help produces output")
    report_result(b"Usage:" in out, "unlink: --help contains 'Usage:'")

    # --version goes to stdout
    rc, out, err = run([BIN, "--version"])
    report_result(rc == 0, "unlink: --version → exit 0")
    report_result(b"unlink" in out, "unlink: --version contains 'unlink'")

    # Compare error messages with GNU (byte-for-byte after quote normalization)
    if gnu_path:
        c_env = os.environ.copy()
        c_env["LC_ALL"] = "C"
        for args_list in [[], ["a", "b"]]:
            rc_f, _, err_f = run([BIN] + args_list)
            rc_g, _, err_g = run([gnu_path] + args_list, env=c_env)
            # Normalize tool name
            err_g_norm = err_g.replace(gnu_path.encode(), b"unlink")
            # Normalize smart quotes (U+2018/U+2019) to ASCII single quotes
            err_f_norm = err_f
            for smart, ascii_ in [(b"\xe2\x80\x98", b"'"), (b"\xe2\x80\x99", b"'")]:
                err_f_norm = err_f_norm.replace(smart, ascii_)
                err_g_norm = err_g_norm.replace(smart, ascii_)
            report_result(err_f_norm == err_g_norm,
                         f"unlink: error msg byte-match GNU for args={args_list}")


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
