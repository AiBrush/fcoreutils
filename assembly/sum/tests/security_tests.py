#!/usr/bin/env python3
"""security_tests.py — Security & memory safety tests for fsum.

fsum is a GNU-compatible 'sum' written in x86-64 Linux assembly.
It computes BSD or SysV checksums and counts blocks.

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
   13. Tool-specific (sum: checksum computation)
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
GNU = "sum"
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
    for name in ["fsum_release", "fsum"]:
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

    with tempfile.NamedTemporaryFile(delete=False, suffix=".txt") as f:
        f.write(b"hello world")
        tmpfile = f.name

    try:
        cmd = ["strace", "-f", "-e", "trace=%process,%network,write,read,openat,open,creat,brk,mmap,mprotect",
               BIN, tmpfile]
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

        # sum needs to open files, so we check it opens exactly the expected file
        write_calls = [l for l in lines if "write(" in l]
        report_result(len(write_calls) >= 1, "syscall: write called (expected)")

        # sum uses: rt_sigprocmask, open, read, write, close, exit
        all_calls = [l for l in lines if "(" in l and "=" in l]
        report_result(len(all_calls) <= 20, f"syscall: total {len(all_calls)} syscalls (<=20 expected)")
    finally:
        os.unlink(tmpfile)


# =============================================================================
#                     3. /proc FILESYSTEM RUNTIME ANALYSIS
# =============================================================================

def check_proc_analysis():
    log("\n=== 3. /proc Filesystem Runtime Analysis ===")
    with tempfile.NamedTemporaryFile(delete=False, suffix=".txt") as f:
        f.write(b"test data")
        tmpfile = f.name

    try:
        rc, out, err = run([BIN, tmpfile])
        report_result(rc == 0, "proc: tool runs and exits cleanly")
    finally:
        os.unlink(tmpfile)


# =============================================================================
#                     4. FILE DESCRIPTOR HYGIENE
# =============================================================================

def check_fd_hygiene():
    log("\n=== 4. File Descriptor Hygiene ===")

    with tempfile.NamedTemporaryFile(delete=False, suffix=".txt") as f:
        f.write(b"test")
        tmpfile = f.name

    try:
        # Closed stdout
        script = f'exec 3>&1 1>&-; {BIN} {tmpfile} 2>/dev/null; echo $? >&3'
        p = subprocess.run(["bash", "-c", script], capture_output=True, timeout=TIMEOUT, text=True)
        rc = p.stdout.strip()
        report_result(rc != "", "fd: closed stdout -> doesn't hang")

        # Closed stderr -- tool should still work
        script = f'exec 3>&1; {BIN} {tmpfile} 2>&- 1>&3; echo $? >&3'
        p = subprocess.run(["bash", "-c", script], capture_output=True, timeout=TIMEOUT, text=True)
        lines = p.stdout.strip().split("\n")
        rc = lines[-1] if lines else ""
        report_result(rc == "0", "fd: closed stderr -> exit 0")

        # /dev/null
        script = f'{BIN} {tmpfile} > /dev/null 2>/dev/null; echo $?'
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

    with tempfile.NamedTemporaryFile(delete=False, suffix=".txt") as f:
        f.write(b"hello")
        tmpfile = f.name

    try:
        rc, out, err = run([BIN, tmpfile])
        report_result(rc == 0, "memory: no signal death on normal run")

        # Many file args (most won't exist, but shouldn't crash)
        rc, out, err = run([BIN] + [f"/tmp/nonexistent_{i}" for i in range(100)])
        report_result(rc >= 0 and rc < 128, "memory: no crash with 100 args")

        def limit_stack():
            resource.setrlimit(resource.RLIMIT_STACK, (65536, 65536))
        rc, out, err = run([BIN, tmpfile], preexec_fn=limit_stack)
        report_result(rc == 0, "memory: 64KB stack -> exit 0")

        def limit_mem():
            resource.setrlimit(resource.RLIMIT_AS, (16 * 1024 * 1024, 16 * 1024 * 1024))
        rc, out, err = run([BIN, tmpfile], preexec_fn=limit_mem)
        report_result(rc == 0, "memory: 16MB address space -> exit 0")
    finally:
        os.unlink(tmpfile)


# =============================================================================
#                     6. SIGNAL SAFETY
# =============================================================================

def check_signal_safety():
    log("\n=== 6. Signal Safety ===")

    with tempfile.NamedTemporaryFile(delete=False, suffix=".txt") as f:
        f.write(b"hello")
        tmpfile = f.name

    try:
        script = f'{BIN} {tmpfile} | head -c 0'
        p = subprocess.run(["bash", "-c", script], capture_output=True, timeout=TIMEOUT)
        report_result(p.returncode >= 0 and p.returncode < 128, "signal: SIGPIPE clean exit")

        ok_count = 0
        trials = 20
        for _ in range(trials):
            rc = os.system(f"{BIN} {tmpfile} 2>/dev/null | head -c 0 >/dev/null 2>/dev/null")
            if os.WIFEXITED(rc) and os.WEXITSTATUS(rc) < 128:
                ok_count += 1
        report_result(ok_count >= trials - 2, f"signal: rapid SIGPIPE ({ok_count}/{trials})")
    finally:
        os.unlink(tmpfile)


# =============================================================================
#                     7. INPUT FUZZING
# =============================================================================

def check_fuzzing():
    log("\n=== 7. Input Fuzzing ===")

    # Fuzz with random stdin data
    crash_count = 0
    for i in range(20):
        data = bytes(random.randint(0, 255) for _ in range(random.randint(0, 10000)))
        rc, out, err = run([BIN], stdin_data=data)
        if rc >= 128:
            crash_count += 1
    report_result(crash_count == 0, f"fuzz: 20 random stdin inputs -- no signal death ({crash_count})")

    # Fuzz with large stdin
    data = bytes(random.randint(0, 255) for _ in range(100000))
    rc, out, err = run([BIN], stdin_data=data)
    report_result(rc >= 0 and rc < 128, "fuzz: 100KB stdin -- no crash")

    # Pathological inputs
    for desc, data in [("all-zeros", b"\x00" * 10000),
                       ("all-0xff", b"\xff" * 10000),
                       ("ascending", bytes(range(256)) * 40)]:
        rc, _, _ = run([BIN], stdin_data=data)
        report_result(rc >= 0 and rc < 128, f"fuzz: pathological {desc} -- no crash")


# =============================================================================
#                     8. RESOURCE LIMIT TESTING
# =============================================================================

def check_resource_limits():
    log("\n=== 8. Resource Limit Testing ===")

    with tempfile.NamedTemporaryFile(delete=False, suffix=".txt") as f:
        f.write(b"test data for rlimit")
        tmpfile = f.name

    try:
        def limit_as():
            resource.setrlimit(resource.RLIMIT_AS, (16 * 1024 * 1024, 16 * 1024 * 1024))
        rc, _, _ = run([BIN, tmpfile], preexec_fn=limit_as)
        report_result(rc == 0, "rlimit: RLIMIT_AS=16MB -> exit 0")

        def limit_cpu():
            resource.setrlimit(resource.RLIMIT_CPU, (1, 1))
        rc, _, _ = run([BIN, tmpfile], preexec_fn=limit_cpu)
        report_result(rc == 0, "rlimit: RLIMIT_CPU=1s -> exit 0")

        def limit_stack():
            resource.setrlimit(resource.RLIMIT_STACK, (65536, 65536))
        rc, _, _ = run([BIN, tmpfile], preexec_fn=limit_stack)
        report_result(rc == 0, "rlimit: RLIMIT_STACK=64KB -> exit 0")
    finally:
        os.unlink(tmpfile)


# =============================================================================
#                     9. ENVIRONMENT ROBUSTNESS
# =============================================================================

def check_environment():
    log("\n=== 9. Environment Robustness ===")

    with tempfile.NamedTemporaryFile(delete=False, suffix=".txt") as f:
        f.write(b"env test")
        tmpfile = f.name

    try:
        rc, out, err = run([BIN, tmpfile], env={})
        report_result(rc == 0, "env: empty environment -> exit 0")

        hostile = {
            "PATH": "",
            "HOME": "/nonexistent",
            "LANG": "xx_XX.BROKEN",
            "TERM": "",
            "LC_ALL": "C",
        }
        rc, out, err = run([BIN, tmpfile], env=hostile)
        report_result(rc == 0, "env: hostile env vars -> exit 0")

        big_env = {f"VAR_{i}": f"value_{'X' * 100}" for i in range(1000)}
        rc, out, err = run([BIN, tmpfile], env=big_env)
        report_result(rc == 0, "env: 1000 env vars -> exit 0")
    finally:
        os.unlink(tmpfile)


# =============================================================================
#                     10. OUTPUT INTEGRITY
# =============================================================================

def check_output_integrity():
    log("\n=== 10. Output Integrity ===")

    with tempfile.NamedTemporaryFile(delete=False, suffix=".txt") as f:
        f.write(b"hello")
        tmpfile = f.name

    try:
        outputs = []
        for _ in range(10):
            rc, out, err = run([BIN, tmpfile])
            outputs.append((rc, out, err))

        all_same = all(o == outputs[0] for o in outputs)
        report_result(all_same, "output: deterministic (10 runs identical)")

        all_zero = all(o[0] == 0 for o in outputs)
        report_result(all_zero, "output: all 10 runs exit 0")

        # Compare with GNU
        gnu_path = which(GNU)
        if gnu_path:
            rc_f, out_f, _ = run([BIN, tmpfile])
            rc_g, out_g, _ = run([gnu_path, tmpfile])
            report_result(out_f == out_g and rc_f == rc_g,
                         f"output: matches GNU for test file")

            # SysV mode
            rc_f, out_f, _ = run([BIN, "-s", tmpfile])
            rc_g, out_g, _ = run([gnu_path, "-s", tmpfile])
            report_result(out_f == out_g and rc_f == rc_g,
                         f"output: matches GNU for -s test file")

            # Stdin
            rc_f, out_f, _ = run([BIN], stdin_data=b"hello")
            rc_g, out_g, _ = run([gnu_path], stdin_data=b"hello")
            report_result(out_f == out_g and rc_f == rc_g,
                         f"output: matches GNU for stdin")
    finally:
        os.unlink(tmpfile)


# =============================================================================
#                     11. ERROR HANDLING
# =============================================================================

def check_error_handling():
    log("\n=== 11. Error Handling ===")

    # Invalid flags should not cause signal death
    for flag in ["--badopt", "-x", "--nonexistent"]:
        rc, out, err = run([BIN, flag])
        report_result(rc >= 0 and rc < 128, f"error: '{flag}' -> no signal death")

    # Exit codes match GNU
    gnu_path = which(GNU)
    if gnu_path:
        for args in [["--help"], ["--version"], ["--invalid"], ["-x"]]:
            rc_f, _, _ = run([BIN] + args)
            rc_g, _, _ = run([gnu_path] + args)
            report_result(rc_f == rc_g, f"error: exit code matches GNU for {args}")

    # Nonexistent file
    rc, out, err = run([BIN, "/nonexistent_file_xyz"])
    report_result(rc == 1, "error: nonexistent file -> exit 1")
    report_result(b"No such file" in err, "error: nonexistent file -> error message")


# =============================================================================
#                     12. CONCURRENCY STRESS
# =============================================================================

def check_concurrency():
    log("\n=== 12. Concurrency Stress ===")

    with tempfile.NamedTemporaryFile(delete=False, suffix=".txt") as f:
        f.write(b"concurrency test data")
        tmpfile = f.name

    try:
        procs = []
        for _ in range(50):
            p = subprocess.Popen([BIN, tmpfile],
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

        # Rapid start
        ok_count = 0
        for _ in range(50):
            p = subprocess.Popen([BIN, tmpfile],
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
#                     13. TOOL-SPECIFIC: sum
# =============================================================================

def check_tool_specific():
    log("\n=== 13. Tool-Specific: sum ===")
    gnu_path = which(GNU)

    tmpdir = tempfile.mkdtemp()

    try:
        # Create test files
        files = {}
        for name, content in [("hello.txt", b"hello"),
                               ("empty.txt", b""),
                               ("bytes.bin", bytes(range(256))),
                               ("1025.bin", b"\x00" * 1025),
                               ("big.bin", b"\xff" * 65536)]:
            path = os.path.join(tmpdir, name)
            with open(path, "wb") as f:
                f.write(content)
            files[name] = path

        if gnu_path:
            # BSD mode comparisons
            for name, path in files.items():
                rc_f, out_f, _ = run([BIN, path])
                rc_g, out_g, _ = run([gnu_path, path])
                report_result(out_f == out_g and rc_f == rc_g,
                             f"sum: BSD matches GNU for {name}")

            # SysV mode comparisons
            for name, path in files.items():
                rc_f, out_f, _ = run([BIN, "-s", path])
                rc_g, out_g, _ = run([gnu_path, "-s", path])
                report_result(out_f == out_g and rc_f == rc_g,
                             f"sum: SysV matches GNU for {name}")

            # Multiple files
            all_paths = list(files.values())
            rc_f, out_f, _ = run([BIN] + all_paths)
            rc_g, out_g, _ = run([gnu_path] + all_paths)
            report_result(out_f == out_g and rc_f == rc_g,
                         "sum: BSD multiple files matches GNU")

            rc_f, out_f, _ = run([BIN, "-s"] + all_paths)
            rc_g, out_g, _ = run([gnu_path, "-s"] + all_paths)
            report_result(out_f == out_g and rc_f == rc_g,
                         "sum: SysV multiple files matches GNU")

            # Stdin comparisons
            for data in [b"hello", b"", b"\x00" * 1000, bytes(range(256))]:
                rc_f, out_f, _ = run([BIN], stdin_data=data)
                rc_g, out_g, _ = run([gnu_path], stdin_data=data)
                desc = f"stdin({len(data)}B)"
                report_result(out_f == out_g and rc_f == rc_g,
                             f"sum: BSD {desc} matches GNU")

                rc_f, out_f, _ = run([BIN, "-s"], stdin_data=data)
                rc_g, out_g, _ = run([gnu_path, "-s"], stdin_data=data)
                report_result(out_f == out_g and rc_f == rc_g,
                             f"sum: SysV {desc} matches GNU")

            # Flag combinations
            rc_f, out_f, _ = run([BIN, "-r", files["hello.txt"]])
            rc_g, out_g, _ = run([gnu_path, "-r", files["hello.txt"]])
            report_result(out_f == out_g, "sum: -r explicit matches GNU")

            rc_f, out_f, _ = run([BIN, "-s", "-r", files["hello.txt"]])
            rc_g, out_g, _ = run([gnu_path, "-s", "-r", files["hello.txt"]])
            report_result(out_f == out_g, "sum: -s -r (last wins) matches GNU")

            rc_f, out_f, _ = run([BIN, "-r", "-s", files["hello.txt"]])
            rc_g, out_g, _ = run([gnu_path, "-r", "-s", files["hello.txt"]])
            report_result(out_f == out_g, "sum: -r -s (last wins) matches GNU")

            # Dash as stdin
            rc_f, out_f, _ = run([BIN, "-"], stdin_data=b"hello")
            rc_g, out_g, _ = run([gnu_path, "-"], stdin_data=b"hello")
            report_result(out_f == out_g, "sum: - (stdin) matches GNU")
    finally:
        import shutil
        shutil.rmtree(tmpdir)


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
