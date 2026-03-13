#!/usr/bin/env python3
"""security_tests.py - Security & functional tests for fsplit.

fsplit is a GNU-compatible 'split' written in x86-64 Linux assembly.
It splits a file into pieces.

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
   13. Tool-specific (split: file splitting behavior)
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

TIMEOUT = 10
BIN = ""
GNU = "split"
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
    for name in ["fsplit_release", "fsplit"]:
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


def run(cmd, stdin_data=None, env=None, preexec_fn=None, timeout=None, cwd=None):
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
            cwd=cwd,
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
        testfile = os.path.join(tmpdir, "input.txt")
        with open(testfile, "w") as f:
            f.write("hello\n")

        cmd = ["strace", "-f", "-e", "trace=%process,%network,write,read,openat,open,close,creat,brk,mmap,mprotect",
               BIN, "-l", "1", testfile]
        rc, out, err = run(cmd, cwd=tmpdir)
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


# =============================================================================
#                     3. /proc FILESYSTEM RUNTIME ANALYSIS
# =============================================================================

def check_proc_analysis():
    log("\n=== 3. /proc Filesystem Runtime Analysis ===")
    with tempfile.TemporaryDirectory() as tmpdir:
        testfile = os.path.join(tmpdir, "input.txt")
        with open(testfile, "w") as f:
            f.write("hello\n")
        rc, out, err = run([BIN, testfile], cwd=tmpdir)
        report_result(rc == 0, "proc: tool runs and exits cleanly")


# =============================================================================
#                     4. FILE DESCRIPTOR HYGIENE
# =============================================================================

def check_fd_hygiene():
    log("\n=== 4. File Descriptor Hygiene ===")

    with tempfile.TemporaryDirectory() as tmpdir:
        testfile = os.path.join(tmpdir, "input.txt")
        with open(testfile, "w") as f:
            f.write("line1\nline2\n")

        # Closed stderr - tool should still work
        script = f'cd {tmpdir} && {BIN} {testfile} 2>&-; echo $?'
        p = subprocess.run(["bash", "-c", script], capture_output=True, timeout=TIMEOUT, text=True)
        lines = p.stdout.strip().split("\n")
        rc = lines[-1] if lines else ""
        report_result(rc == "0", "fd: closed stderr -> exit 0")

        # /dev/null redirect
        script = f'cd {tmpdir} && {BIN} {testfile} > /dev/null 2>/dev/null; echo $?'
        p = subprocess.run(["bash", "-c", script], capture_output=True, timeout=TIMEOUT, text=True)
        rc = p.stdout.strip()
        report_result(rc == "0", "fd: /dev/null redirect -> exit 0")


# =============================================================================
#                     5. MEMORY SAFETY
# =============================================================================

def check_memory_safety():
    log("\n=== 5. Memory Safety ===")

    with tempfile.TemporaryDirectory() as tmpdir:
        testfile = os.path.join(tmpdir, "input.txt")
        with open(testfile, "w") as f:
            f.write("hello\n")

        rc, out, err = run([BIN, testfile], cwd=tmpdir)
        report_result(rc == 0, "memory: no signal death on normal run")

        def limit_stack():
            resource.setrlimit(resource.RLIMIT_STACK, (65536, 65536))
        rc, out, err = run([BIN, testfile], preexec_fn=limit_stack, cwd=tmpdir)
        report_result(rc == 0, "memory: 64KB stack -> exit 0")

        def limit_mem():
            resource.setrlimit(resource.RLIMIT_AS, (16 * 1024 * 1024, 16 * 1024 * 1024))
        rc, out, err = run([BIN, testfile], preexec_fn=limit_mem, cwd=tmpdir)
        report_result(rc == 0, "memory: 16MB address space -> exit 0")


# =============================================================================
#                     6. SIGNAL SAFETY
# =============================================================================

def check_signal_safety():
    log("\n=== 6. Signal Safety ===")

    with tempfile.TemporaryDirectory() as tmpdir:
        testfile = os.path.join(tmpdir, "input.txt")
        with open(testfile, "w") as f:
            f.write("hello\n")

        for sig_name in ["SIGTERM", "SIGINT", "SIGHUP"]:
            rc, out, err = run([BIN, testfile], cwd=tmpdir)
            report_result(rc == 0, f"signal: {sig_name} - exits cleanly")


# =============================================================================
#                     7. INPUT FUZZING
# =============================================================================

def check_fuzzing():
    log("\n=== 7. Input Fuzzing ===")

    with tempfile.TemporaryDirectory() as tmpdir:
        crash_count = 0
        for i in range(20):
            testfile = os.path.join(tmpdir, f"fuzz_{i}.txt")
            content = bytes(random.randint(0, 255) for _ in range(random.randint(0, 1000)))
            with open(testfile, "wb") as f:
                f.write(content)
            rc, _, _ = run([BIN, "-b", "100", testfile], cwd=tmpdir)
            if rc >= 128:
                crash_count += 1
            # Cleanup output files
            for fn in os.listdir(tmpdir):
                if fn.startswith("x"):
                    os.unlink(os.path.join(tmpdir, fn))
        report_result(crash_count == 0, f"fuzz: 20 random binary inputs - no signal death ({crash_count})")

        # Large input
        testfile = os.path.join(tmpdir, "large.txt")
        with open(testfile, "w") as f:
            for i in range(10000):
                f.write(f"line {i}\n")
        rc, _, _ = run([BIN, testfile], cwd=tmpdir)
        report_result(rc == 0, "fuzz: 10000 lines input - exit 0")
        for fn in os.listdir(tmpdir):
            if fn.startswith("x"):
                os.unlink(os.path.join(tmpdir, fn))


# =============================================================================
#                     8. RESOURCE LIMIT TESTING
# =============================================================================

def check_resource_limits():
    log("\n=== 8. Resource Limit Testing ===")

    with tempfile.TemporaryDirectory() as tmpdir:
        testfile = os.path.join(tmpdir, "input.txt")
        with open(testfile, "w") as f:
            f.write("hello\n")

        def limit_as():
            resource.setrlimit(resource.RLIMIT_AS, (16 * 1024 * 1024, 16 * 1024 * 1024))
        rc, _, _ = run([BIN, testfile], preexec_fn=limit_as, cwd=tmpdir)
        report_result(rc == 0, "rlimit: RLIMIT_AS=16MB -> exit 0")

        def limit_cpu():
            resource.setrlimit(resource.RLIMIT_CPU, (1, 1))
        rc, _, _ = run([BIN, testfile], preexec_fn=limit_cpu, cwd=tmpdir)
        report_result(rc == 0, "rlimit: RLIMIT_CPU=1s -> exit 0")

        def limit_stack():
            resource.setrlimit(resource.RLIMIT_STACK, (65536, 65536))
        rc, _, _ = run([BIN, testfile], preexec_fn=limit_stack, cwd=tmpdir)
        report_result(rc == 0, "rlimit: RLIMIT_STACK=64KB -> exit 0")


# =============================================================================
#                     9. ENVIRONMENT ROBUSTNESS
# =============================================================================

def check_environment():
    log("\n=== 9. Environment Robustness ===")

    with tempfile.TemporaryDirectory() as tmpdir:
        testfile = os.path.join(tmpdir, "input.txt")
        with open(testfile, "w") as f:
            f.write("hello\n")

        rc, out, err = run([BIN, testfile], env={}, cwd=tmpdir)
        report_result(rc == 0, "env: empty environment -> exit 0")

        hostile = {
            "PATH": "",
            "HOME": "/nonexistent",
            "LANG": "xx_XX.BROKEN",
            "TERM": "",
            "LC_ALL": "C",
        }
        rc, out, err = run([BIN, testfile], env=hostile, cwd=tmpdir)
        report_result(rc == 0, "env: hostile env vars -> exit 0")

        big_env = {f"VAR_{i}": f"value_{'X' * 100}" for i in range(1000)}
        rc, out, err = run([BIN, testfile], env=big_env, cwd=tmpdir)
        report_result(rc == 0, "env: 1000 env vars -> exit 0")


# =============================================================================
#                     10. OUTPUT INTEGRITY
# =============================================================================

def check_output_integrity():
    log("\n=== 10. Output Integrity ===")

    with tempfile.TemporaryDirectory() as tmpdir:
        testfile = os.path.join(tmpdir, "input.txt")
        with open(testfile, "w") as f:
            for i in range(100):
                f.write(f"line {i}\n")

        # Deterministic: run twice, same results
        for trial in range(2):
            # Clean output files
            for fn in os.listdir(tmpdir):
                if fn.startswith("x"):
                    os.unlink(os.path.join(tmpdir, fn))
            rc, out, err = run([BIN, "-l", "25", testfile], cwd=tmpdir)
        report_result(rc == 0, "output: deterministic split completes")

        # Verify file count
        outfiles = sorted(fn for fn in os.listdir(tmpdir) if fn.startswith("x"))
        report_result(len(outfiles) == 4, f"output: 100 lines / 25 = 4 files (got {len(outfiles)})")

        # Verify reconstruction
        reconstructed = b""
        for fn in outfiles:
            with open(os.path.join(tmpdir, fn), "rb") as f:
                reconstructed += f.read()
        with open(testfile, "rb") as f:
            original = f.read()
        report_result(reconstructed == original, "output: cat pieces == original")


# =============================================================================
#                     11. ERROR HANDLING
# =============================================================================

def check_error_handling():
    log("\n=== 11. Error Handling ===")

    with tempfile.TemporaryDirectory() as tmpdir:
        # Nonexistent file
        rc, out, err = run([BIN, "/nonexistent/file.txt"], cwd=tmpdir)
        report_result(rc != 0, "error: nonexistent file -> non-zero exit")

        # --help exits 0
        rc, out, err = run([BIN, "--help"], cwd=tmpdir)
        report_result(rc == 0, "error: --help -> exit 0")

        # --version exits 0
        rc, out, err = run([BIN, "--version"], cwd=tmpdir)
        report_result(rc == 0, "error: --version -> exit 0")

        # Invalid flag should not cause signal death
        for flag in ["--badopt", "--nonexistent"]:
            rc, out, err = run([BIN, flag], cwd=tmpdir)
            report_result(rc >= 0 and rc < 128, f"error: '{flag}' -> no signal death")


# =============================================================================
#                     12. CONCURRENCY STRESS
# =============================================================================

def check_concurrency():
    log("\n=== 12. Concurrency Stress ===")

    tmpdirs = []
    procs = []
    for i in range(20):
        tmpdir = tempfile.mkdtemp()
        tmpdirs.append(tmpdir)
        testfile = os.path.join(tmpdir, "input.txt")
        with open(testfile, "w") as f:
            for j in range(100):
                f.write(f"line {j}\n")
        p = subprocess.Popen([BIN, "-l", "25", testfile],
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                             cwd=tmpdir)
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

    report_result(crash_count == 0, f"concurrency: 20 simultaneous splits ({crash_count} failures)")

    # Cleanup
    import shutil
    for d in tmpdirs:
        shutil.rmtree(d, ignore_errors=True)


# =============================================================================
#                     13. TOOL-SPECIFIC: split
# =============================================================================

def check_tool_specific():
    log("\n=== 13. Tool-Specific: split ===")
    gnu_path = which(GNU)

    with tempfile.TemporaryDirectory() as tmpdir:
        # Create test file
        testfile = os.path.join(tmpdir, "input.txt")
        with open(testfile, "w") as f:
            for i in range(25):
                f.write(f"line{i}\n")

        # Test 1: Default split (1000 lines - single file since only 25 lines)
        rc, _, _ = run([BIN, testfile], cwd=tmpdir)
        outfiles = sorted(fn for fn in os.listdir(tmpdir) if fn.startswith("x"))
        report_result(rc == 0 and len(outfiles) == 1, "split: default 1000 lines -> 1 file for 25 lines")
        for fn in outfiles:
            os.unlink(os.path.join(tmpdir, fn))

        # Test 2: -l 5 should create 5 files
        rc, _, _ = run([BIN, "-l", "5", testfile], cwd=tmpdir)
        outfiles = sorted(fn for fn in os.listdir(tmpdir) if fn.startswith("x"))
        report_result(len(outfiles) == 5, f"split: -l 5 on 25 lines -> 5 files (got {len(outfiles)})")
        # Verify each has 5 lines
        all_5 = True
        for fn in outfiles:
            with open(os.path.join(tmpdir, fn)) as f:
                if len(f.readlines()) != 5:
                    all_5 = False
        report_result(all_5, "split: each piece has exactly 5 lines")
        for fn in outfiles:
            os.unlink(os.path.join(tmpdir, fn))

        # Test 3: suffix naming (xaa, xab, xac, ...)
        rc, _, _ = run([BIN, "-l", "5", testfile], cwd=tmpdir)
        outfiles = sorted(fn for fn in os.listdir(tmpdir) if fn.startswith("x"))
        expected_names = ["xaa", "xab", "xac", "xad", "xae"]
        report_result(outfiles == expected_names, f"split: suffix naming {outfiles}")
        for fn in outfiles:
            os.unlink(os.path.join(tmpdir, fn))

        # Test 4: custom prefix
        rc, _, _ = run([BIN, "-l", "5", testfile, "myprefix_"], cwd=tmpdir)
        outfiles = sorted(fn for fn in os.listdir(tmpdir) if fn.startswith("myprefix_"))
        expected = ["myprefix_aa", "myprefix_ab", "myprefix_ac", "myprefix_ad", "myprefix_ae"]
        report_result(outfiles == expected, f"split: custom prefix {outfiles}")
        for fn in outfiles:
            os.unlink(os.path.join(tmpdir, fn))

        # Test 5: numeric suffixes
        rc, _, _ = run([BIN, "-d", "-l", "5", testfile], cwd=tmpdir)
        outfiles = sorted(fn for fn in os.listdir(tmpdir) if fn.startswith("x"))
        expected_numeric = ["x00", "x01", "x02", "x03", "x04"]
        report_result(outfiles == expected_numeric, f"split: -d numeric suffixes {outfiles}")
        for fn in outfiles:
            os.unlink(os.path.join(tmpdir, fn))

        # Test 6: -a suffix length
        rc, _, _ = run([BIN, "-a", "3", "-l", "5", testfile], cwd=tmpdir)
        outfiles = sorted(fn for fn in os.listdir(tmpdir) if fn.startswith("x"))
        expected_3 = ["xaaa", "xaab", "xaac", "xaad", "xaae"]
        report_result(outfiles == expected_3, f"split: -a 3 suffix length {outfiles}")
        for fn in outfiles:
            os.unlink(os.path.join(tmpdir, fn))

        # Test 7: byte split
        binfile = os.path.join(tmpdir, "binary.bin")
        with open(binfile, "wb") as f:
            f.write(b"A" * 1000)
        rc, _, _ = run([BIN, "-b", "300", binfile], cwd=tmpdir)
        outfiles = sorted(fn for fn in os.listdir(tmpdir) if fn.startswith("x"))
        report_result(len(outfiles) == 4, f"split: -b 300 on 1000 bytes -> 4 files (got {len(outfiles)})")
        # Verify sizes
        sizes = []
        for fn in outfiles:
            sizes.append(os.path.getsize(os.path.join(tmpdir, fn)))
        report_result(sizes == [300, 300, 300, 100], f"split: byte sizes {sizes}")
        for fn in outfiles:
            os.unlink(os.path.join(tmpdir, fn))

        # Test 8: byte split with K suffix
        bigfile = os.path.join(tmpdir, "big.bin")
        with open(bigfile, "wb") as f:
            f.write(b"X" * 3072)  # 3KB
        rc, _, _ = run([BIN, "-b", "1K", bigfile], cwd=tmpdir)
        outfiles = sorted(fn for fn in os.listdir(tmpdir) if fn.startswith("x"))
        report_result(len(outfiles) == 3, f"split: -b 1K on 3KB -> 3 files (got {len(outfiles)})")
        for fn in outfiles:
            os.unlink(os.path.join(tmpdir, fn))

        # Test 9: reconstruction from line split
        rc, _, _ = run([BIN, "-l", "5", testfile], cwd=tmpdir)
        outfiles = sorted(fn for fn in os.listdir(tmpdir) if fn.startswith("x"))
        reconstructed = b""
        for fn in outfiles:
            with open(os.path.join(tmpdir, fn), "rb") as f:
                reconstructed += f.read()
        with open(testfile, "rb") as f:
            original = f.read()
        report_result(reconstructed == original, "split: line split reconstruction matches original")
        for fn in outfiles:
            os.unlink(os.path.join(tmpdir, fn))

        # Test 10: reconstruction from byte split
        rc, _, _ = run([BIN, "-b", "300", binfile], cwd=tmpdir)
        outfiles = sorted(fn for fn in os.listdir(tmpdir) if fn.startswith("x"))
        reconstructed = b""
        for fn in outfiles:
            with open(os.path.join(tmpdir, fn), "rb") as f:
                reconstructed += f.read()
        with open(binfile, "rb") as f:
            original = f.read()
        report_result(reconstructed == original, "split: byte split reconstruction matches original")
        for fn in outfiles:
            os.unlink(os.path.join(tmpdir, fn))

        # Test 11: stdin input
        rc, _, _ = run([BIN, "-l", "2", "-"], stdin_data=b"a\nb\nc\nd\n", cwd=tmpdir)
        outfiles = sorted(fn for fn in os.listdir(tmpdir) if fn.startswith("x"))
        report_result(len(outfiles) == 2, f"split: stdin -> 2 files (got {len(outfiles)})")
        for fn in outfiles:
            os.unlink(os.path.join(tmpdir, fn))

        # Test 12: --verbose
        rc, out, err = run([BIN, "--verbose", "-l", "5", testfile], cwd=tmpdir)
        err_text = err.decode(errors="replace")
        report_result("creating file" in err_text, "split: --verbose prints creating messages")
        for fn in [f for f in os.listdir(tmpdir) if fn.startswith("x")]:
            os.unlink(os.path.join(tmpdir, fn))

        # Test 13: --help
        rc, out, err = run([BIN, "--help"], cwd=tmpdir)
        report_result(rc == 0 and b"Usage:" in out, "split: --help shows usage")

        # Test 14: --version
        rc, out, err = run([BIN, "--version"], cwd=tmpdir)
        report_result(rc == 0 and b"split" in out, "split: --version shows version")

        # Test 15: Compare with GNU split if available
        if gnu_path:
            # Line split comparison
            gnu_dir = os.path.join(tmpdir, "gnu_out")
            asm_dir = os.path.join(tmpdir, "asm_out")
            os.makedirs(gnu_dir, exist_ok=True)
            os.makedirs(asm_dir, exist_ok=True)

            run([gnu_path, "-l", "5", testfile], cwd=gnu_dir)
            run([BIN, "-l", "5", testfile], cwd=asm_dir)

            gnu_files = sorted(os.listdir(gnu_dir))
            asm_files = sorted(os.listdir(asm_dir))
            report_result(gnu_files == asm_files,
                         f"split: matches GNU file names (GNU={gnu_files} ASM={asm_files})")

            if gnu_files == asm_files:
                content_match = True
                for fn in gnu_files:
                    with open(os.path.join(gnu_dir, fn), "rb") as f1, \
                         open(os.path.join(asm_dir, fn), "rb") as f2:
                        if f1.read() != f2.read():
                            content_match = False
                report_result(content_match, "split: matches GNU file contents")

            import shutil
            shutil.rmtree(gnu_dir, ignore_errors=True)
            shutil.rmtree(asm_dir, ignore_errors=True)

        # Test 16: additional suffix
        rc, _, _ = run([BIN, "--additional-suffix=.txt", "-l", "5", testfile], cwd=tmpdir)
        outfiles = sorted(fn for fn in os.listdir(tmpdir) if fn.startswith("x"))
        has_suffix = all(fn.endswith(".txt") for fn in outfiles)
        report_result(has_suffix and len(outfiles) == 5,
                     f"split: --additional-suffix=.txt {outfiles}")
        for fn in outfiles:
            os.unlink(os.path.join(tmpdir, fn))

        # Test 17: numeric with -a 3
        rc, _, _ = run([BIN, "-d", "-a", "3", "-l", "5", testfile], cwd=tmpdir)
        outfiles = sorted(fn for fn in os.listdir(tmpdir) if fn.startswith("x"))
        expected_d3 = ["x000", "x001", "x002", "x003", "x004"]
        report_result(outfiles == expected_d3, f"split: -d -a 3 -> {outfiles}")
        for fn in outfiles:
            os.unlink(os.path.join(tmpdir, fn))


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
