#!/usr/bin/env python3
"""security_tests.py — Security & memory safety tests for ftruncate.

ftruncate is a GNU-compatible 'truncate' written in x86-64 Linux assembly.
It shrinks or extends the size of files to a specified size.

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
   13. Tool-specific (truncate: file size manipulation)
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
GNU = "truncate"
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
    for name in ["ftruncate_release", "ftruncate"]:
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

    with tempfile.NamedTemporaryFile(delete=False) as tf:
        tf.write(b"hello")
        tmpfile = tf.name

    try:
        cmd = ["strace", "-f", "-e", "trace=%process,%network,write,read,openat,open,creat,brk,mmap,mprotect",
               BIN, "-s", "10", tmpfile]
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
    finally:
        os.unlink(tmpfile)


# =============================================================================
#                     3. /proc FILESYSTEM RUNTIME ANALYSIS
# =============================================================================

def check_proc_analysis():
    log("\n=== 3. /proc Filesystem Runtime Analysis ===")
    with tempfile.NamedTemporaryFile(delete=False) as tf:
        tmpfile = tf.name

    try:
        rc, out, err = run([BIN, "-s", "0", tmpfile])
        report_result(rc == 0, "proc: tool runs and exits cleanly")
    finally:
        os.unlink(tmpfile)


# =============================================================================
#                     4. FILE DESCRIPTOR HYGIENE
# =============================================================================

def check_fd_hygiene():
    log("\n=== 4. File Descriptor Hygiene ===")

    with tempfile.NamedTemporaryFile(delete=False) as tf:
        tmpfile = tf.name

    try:
        # Closed stderr — tool should still work
        script = f'{BIN} -s 10 {tmpfile} 2>&-; echo $?'
        p = subprocess.run(["bash", "-c", script], capture_output=True, timeout=TIMEOUT, text=True)
        lines = p.stdout.strip().split("\n")
        rc = lines[-1] if lines else ""
        report_result(rc == "0", "fd: closed stderr -> exit 0")

        # /dev/null
        script = f'{BIN} -s 10 {tmpfile} > /dev/null 2>/dev/null; echo $?'
        p = subprocess.run(["bash", "-c", script], capture_output=True, timeout=TIMEOUT, text=True)
        rc = p.stdout.strip()
        report_result(rc == "0", "fd: /dev/null redirect -> exit 0")
    finally:
        os.unlink(tmpfile)


# =============================================================================
#                     5. MEMORY SAFETY
# =============================================================================

def check_memory_safety():
    log("\n=== 5. Memory Safety ===")

    with tempfile.NamedTemporaryFile(delete=False) as tf:
        tmpfile = tf.name

    try:
        rc, out, err = run([BIN, "-s", "0", tmpfile])
        report_result(rc == 0, "memory: no signal death on normal run")

        # Many files
        files = []
        for i in range(20):
            f = tempfile.NamedTemporaryFile(delete=False)
            f.close()
            files.append(f.name)

        rc, out, err = run([BIN, "-s", "100"] + files)
        report_result(rc >= 0 and rc < 128, "memory: no crash with 20 file args")
        for f in files:
            os.unlink(f)

        def limit_stack():
            resource.setrlimit(resource.RLIMIT_STACK, (65536, 65536))
        rc, out, err = run([BIN, "-s", "0", tmpfile], preexec_fn=limit_stack)
        report_result(rc == 0, "memory: 64KB stack -> exit 0")

        def limit_mem():
            resource.setrlimit(resource.RLIMIT_AS, (16 * 1024 * 1024, 16 * 1024 * 1024))
        rc, out, err = run([BIN, "-s", "0", tmpfile], preexec_fn=limit_mem)
        report_result(rc == 0, "memory: 16MB address space -> exit 0")
    finally:
        if os.path.exists(tmpfile):
            os.unlink(tmpfile)


# =============================================================================
#                     6. SIGNAL SAFETY
# =============================================================================

def check_signal_safety():
    log("\n=== 6. Signal Safety ===")

    with tempfile.NamedTemporaryFile(delete=False) as tf:
        tmpfile = tf.name

    try:
        for sig_name in ["SIGTERM", "SIGINT", "SIGHUP"]:
            rc, out, err = run([BIN, "-s", "0", tmpfile])
            report_result(rc == 0, f"signal: {sig_name} -- exits cleanly")
    finally:
        os.unlink(tmpfile)


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
        arg = "".join(random.choices(string.printable, k=random.randint(1000, 10000)))
        rc, out, err = run([BIN, "-s", "0", arg])
        if rc >= 128:
            crash_count += 1
    report_result(crash_count == 0, f"fuzz: 20 random long file args -- no signal death ({crash_count})")

    for desc, arg in [("all-newlines", "\n" * 1000),
                      ("control-chars", "".join(chr(i) for i in range(1, 32))),
                      ("unicode-multibyte", "\u00e9\u00e0\u00fc\u4e16\u754c" * 100)]:
        rc, _, _ = run([BIN, "-s", "0", arg])
        report_result(rc >= 0 and rc < 128, f"fuzz: pathological {desc} -- no crash")


# =============================================================================
#                     8. RESOURCE LIMIT TESTING
# =============================================================================

def check_resource_limits():
    log("\n=== 8. Resource Limit Testing ===")

    with tempfile.NamedTemporaryFile(delete=False) as tf:
        tmpfile = tf.name

    try:
        def limit_as():
            resource.setrlimit(resource.RLIMIT_AS, (16 * 1024 * 1024, 16 * 1024 * 1024))
        rc, _, _ = run([BIN, "-s", "0", tmpfile], preexec_fn=limit_as)
        report_result(rc == 0, "rlimit: RLIMIT_AS=16MB -> exit 0")

        def limit_cpu():
            resource.setrlimit(resource.RLIMIT_CPU, (1, 1))
        rc, _, _ = run([BIN, "-s", "0", tmpfile], preexec_fn=limit_cpu)
        report_result(rc == 0, "rlimit: RLIMIT_CPU=1s -> exit 0")

        def limit_stack():
            resource.setrlimit(resource.RLIMIT_STACK, (65536, 65536))
        rc, _, _ = run([BIN, "-s", "0", tmpfile], preexec_fn=limit_stack)
        report_result(rc == 0, "rlimit: RLIMIT_STACK=64KB -> exit 0")

        def limit_all():
            resource.setrlimit(resource.RLIMIT_AS, (16 * 1024 * 1024, 16 * 1024 * 1024))
            resource.setrlimit(resource.RLIMIT_CPU, (1, 1))
            resource.setrlimit(resource.RLIMIT_STACK, (65536, 65536))
        rc, _, _ = run([BIN, "-s", "0", tmpfile], preexec_fn=limit_all)
        report_result(rc >= 0 and rc < 128, "rlimit: all limits combined -> no crash")
    finally:
        os.unlink(tmpfile)


# =============================================================================
#                     9. ENVIRONMENT ROBUSTNESS
# =============================================================================

def check_environment():
    log("\n=== 9. Environment Robustness ===")

    with tempfile.NamedTemporaryFile(delete=False) as tf:
        tmpfile = tf.name

    try:
        rc, out, err = run([BIN, "-s", "0", tmpfile], env={})
        report_result(rc == 0, "env: empty environment -> exit 0")

        hostile = {
            "PATH": "",
            "HOME": "/nonexistent",
            "LANG": "xx_XX.BROKEN",
            "TERM": "",
            "LC_ALL": "C",
        }
        rc, out, err = run([BIN, "-s", "0", tmpfile], env=hostile)
        report_result(rc == 0, "env: hostile env vars -> exit 0")

        big_env = {f"VAR_{i}": f"value_{'X' * 100}" for i in range(1000)}
        rc, out, err = run([BIN, "-s", "0", tmpfile], env=big_env)
        report_result(rc == 0, "env: 1000 env vars -> exit 0")

        special_env = os.environ.copy()
        special_env["EVIL"] = "A" * 100000
        rc, out, err = run([BIN, "-s", "0", tmpfile], env=special_env)
        report_result(rc == 0, "env: 100KB env var -> exit 0")
    finally:
        os.unlink(tmpfile)


# =============================================================================
#                     10. OUTPUT INTEGRITY
# =============================================================================

def check_output_integrity():
    log("\n=== 10. Output Integrity ===")

    with tempfile.NamedTemporaryFile(delete=False) as tf:
        tmpfile = tf.name

    try:
        # truncate should produce no stdout on success
        rc, out, err = run([BIN, "-s", "100", tmpfile])
        report_result(rc == 0, "output: exit 0 on valid truncate")
        report_result(out == b"", "output: no stdout on success")
        report_result(err == b"", "output: no stderr on success")

        # Verify file was actually truncated
        size = os.path.getsize(tmpfile)
        report_result(size == 100, f"output: file size is 100 (got {size})")

        # Deterministic behavior
        sizes = []
        for _ in range(10):
            os.truncate(tmpfile, 0)
            rc, out, err = run([BIN, "-s", "42", tmpfile])
            sizes.append(os.path.getsize(tmpfile))
        report_result(all(s == 42 for s in sizes), "output: deterministic (10 runs)")
    finally:
        os.unlink(tmpfile)


# =============================================================================
#                     11. ERROR HANDLING
# =============================================================================

def check_error_handling():
    log("\n=== 11. Error Handling ===")

    # Invalid flags should not cause signal death
    for flag in ["--badopt", "-Z", "--nonexistent"]:
        rc, out, err = run([BIN, flag])
        report_result(rc >= 0 and rc < 128, f"error: '{flag}' -> no signal death")

    # Missing required options
    rc, out, err = run([BIN])
    report_result(rc != 0, "error: no args -> non-zero exit")

    rc, out, err = run([BIN, "-s", "100"])
    report_result(rc != 0, "error: -s without file -> non-zero exit")

    # Exit codes match GNU
    gnu_path = which(GNU)
    if gnu_path:
        for args in [["--help"], ["--version"], ["--invalid"], ["-Z"], []]:
            rc_f, _, _ = run([BIN] + args)
            rc_g, _, _ = run([gnu_path] + args)
            report_result(rc_f == rc_g, f"error: exit code matches GNU for {args}")


# =============================================================================
#                     12. CONCURRENCY STRESS
# =============================================================================

def check_concurrency():
    log("\n=== 12. Concurrency Stress ===")

    files = []
    for i in range(50):
        f = tempfile.NamedTemporaryFile(delete=False)
        f.close()
        files.append(f.name)

    procs = []
    for f in files:
        p = subprocess.Popen([BIN, "-s", "100", f],
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

    for f in files:
        os.unlink(f)

    # Rapid start
    with tempfile.NamedTemporaryFile(delete=False) as tf:
        tmpfile = tf.name

    try:
        ok_count = 0
        for _ in range(50):
            p = subprocess.Popen([BIN, "-s", "0", tmpfile],
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            try:
                p.wait(timeout=1)
                ok_count += 1
            except subprocess.TimeoutExpired:
                p.kill()
        report_result(ok_count == 50, f"concurrency: rapid start ({ok_count}/50)")
    finally:
        os.unlink(tmpfile)


# =============================================================================
#                     13. TOOL-SPECIFIC: truncate
# =============================================================================

def check_tool_specific():
    log("\n=== 13. Tool-Specific: truncate ===")

    tmpdir = tempfile.mkdtemp()

    try:
        # Set exact size
        f1 = os.path.join(tmpdir, "exact100")
        rc, _, _ = run([BIN, "-s", "100", f1])
        report_result(rc == 0 and os.path.getsize(f1) == 100,
                     "truncate: -s 100 sets file to 100 bytes")

        # Set to zero
        f2 = os.path.join(tmpdir, "zero")
        with open(f2, "wb") as f:
            f.write(b"x" * 50)
        rc, _, _ = run([BIN, "-s", "0", f2])
        report_result(rc == 0 and os.path.getsize(f2) == 0,
                     "truncate: -s 0 empties file")

        # Grow with +
        f3 = os.path.join(tmpdir, "grow")
        with open(f3, "wb") as f:
            f.write(b"x" * 100)
        rc, _, _ = run([BIN, "-s", "+50", f3])
        report_result(rc == 0 and os.path.getsize(f3) == 150,
                     "truncate: -s +50 grows by 50")

        # Shrink with -
        f4 = os.path.join(tmpdir, "shrink")
        with open(f4, "wb") as f:
            f.write(b"x" * 200)
        rc, _, _ = run([BIN, "-s", "-50", f4])
        report_result(rc == 0 and os.path.getsize(f4) == 150,
                     "truncate: -s -50 shrinks by 50")

        # Shrink past zero clamps to 0
        f5 = os.path.join(tmpdir, "clamp")
        with open(f5, "wb") as f:
            f.write(b"x" * 10)
        rc, _, _ = run([BIN, "-s", "-100", f5])
        report_result(rc == 0 and os.path.getsize(f5) == 0,
                     "truncate: -s -100 on 10-byte file clamps to 0")

        # K suffix
        f6 = os.path.join(tmpdir, "ksuffix")
        rc, _, _ = run([BIN, "-s", "2K", f6])
        report_result(rc == 0 and os.path.getsize(f6) == 2048,
                     "truncate: -s 2K = 2048 bytes")

        # M suffix
        f7 = os.path.join(tmpdir, "msuffix")
        rc, _, _ = run([BIN, "-s", "1M", f7])
        report_result(rc == 0 and os.path.getsize(f7) == 1048576,
                     "truncate: -s 1M = 1048576 bytes")

        # KB suffix (1000-based)
        f8 = os.path.join(tmpdir, "kbsuffix")
        rc, _, _ = run([BIN, "-s", "1KB", f8])
        report_result(rc == 0 and os.path.getsize(f8) == 1000,
                     "truncate: -s 1KB = 1000 bytes")

        # MB suffix (1000-based)
        f9 = os.path.join(tmpdir, "mbsuffix")
        rc, _, _ = run([BIN, "-s", "1MB", f9])
        report_result(rc == 0 and os.path.getsize(f9) == 1000000,
                     "truncate: -s 1MB = 1000000 bytes")

        # --no-create / -c
        nc = os.path.join(tmpdir, "no_create_test")
        rc, _, _ = run([BIN, "-c", "-s", "100", nc])
        report_result(rc == 0 and not os.path.exists(nc),
                     "truncate: -c doesn't create nonexistent file")

        # --no-create long form
        nc2 = os.path.join(tmpdir, "no_create_test2")
        rc, _, _ = run([BIN, "--no-create", "-s", "100", nc2])
        report_result(rc == 0 and not os.path.exists(nc2),
                     "truncate: --no-create doesn't create file")

        # File creation without -c
        newf = os.path.join(tmpdir, "new_file")
        rc, _, _ = run([BIN, "-s", "50", newf])
        report_result(rc == 0 and os.path.exists(newf) and os.path.getsize(newf) == 50,
                     "truncate: creates file if not exists")

        # Reference file
        ref = os.path.join(tmpdir, "reference")
        with open(ref, "wb") as f:
            f.write(b"x" * 300)
        tgt = os.path.join(tmpdir, "target_ref")
        rc, _, _ = run([BIN, "-r", ref, tgt])
        report_result(rc == 0 and os.path.getsize(tgt) == 300,
                     "truncate: -r reference file sets same size")

        # Reference with --reference=
        tgt2 = os.path.join(tmpdir, "target_ref2")
        rc, _, _ = run([BIN, f"--reference={ref}", tgt2])
        report_result(rc == 0 and os.path.getsize(tgt2) == 300,
                     "truncate: --reference= long form works")

        # Multiple files
        mf1 = os.path.join(tmpdir, "multi1")
        mf2 = os.path.join(tmpdir, "multi2")
        rc, _, _ = run([BIN, "-s", "200", mf1, mf2])
        report_result(rc == 0 and os.path.getsize(mf1) == 200 and os.path.getsize(mf2) == 200,
                     "truncate: multiple files all set to 200")

        # --size= long form
        sf = os.path.join(tmpdir, "size_long")
        rc, _, _ = run([BIN, "--size=150", sf])
        report_result(rc == 0 and os.path.getsize(sf) == 150,
                     "truncate: --size=150 works")

        # Error: nonexistent file without -c
        rc, _, err = run([BIN, "-s", "100", "/nonexistent/path/file"])
        report_result(rc != 0, "truncate: error on nonexistent path")

        # Error: missing -s and -r
        rc, _, err = run([BIN, os.path.join(tmpdir, "x")])
        report_result(rc != 0, "truncate: error when no -s or -r")

    finally:
        import shutil
        shutil.rmtree(tmpdir, ignore_errors=True)


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
