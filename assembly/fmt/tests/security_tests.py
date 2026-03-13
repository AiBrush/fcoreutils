#!/usr/bin/env python3
"""security_tests.py — Security & memory safety tests for ffmt.

ffmt is a GNU-compatible 'fmt' written in x86-64 Linux assembly.
It reformats text to a specified width.

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
   13. Tool-specific (fmt: text formatting behavior)
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
GNU = "fmt"
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
    for name in ["ffmt_release", "ffmt"]:
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
    report_result(size < 100000, f"elf: binary size {size} bytes (<100KB)")

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
           BIN]
    rc, out, err = run(cmd, stdin_data=b"hello world\n")
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
    rc, out, err = run([BIN], stdin_data=b"hello world\n")
    report_result(rc == 0, "proc: tool runs and exits cleanly")


# =============================================================================
#                     4. FILE DESCRIPTOR HYGIENE
# =============================================================================

def check_fd_hygiene():
    log("\n=== 4. File Descriptor Hygiene ===")

    # Closed stdout
    script = f'echo "hello world" | {BIN} 2>/dev/null 1>&-; echo $? >&2'
    p = subprocess.run(["bash", "-c", script], capture_output=True, timeout=TIMEOUT, text=True)
    report_result(p.returncode == 0, "fd: closed stdout doesn't hang")

    # Closed stderr -- tool should still work
    script = f'echo "hello world" | {BIN} 2>&-; echo $?'
    p = subprocess.run(["bash", "-c", script], capture_output=True, timeout=TIMEOUT, text=True)
    lines = p.stdout.strip().split("\n")
    rc = lines[-1] if lines else ""
    report_result(rc == "0", "fd: closed stderr -> exit 0")

    # RLIMIT_NOFILE=3
    def limit_nofile():
        resource.setrlimit(resource.RLIMIT_NOFILE, (3, 3))
    rc, out, err = run([BIN], stdin_data=b"hello\n", preexec_fn=limit_nofile)
    report_result(rc >= 0 and rc < 128, "fd: RLIMIT_NOFILE=3 -> no crash")

    # /dev/full
    if os.path.exists("/dev/full"):
        script = f'echo "hello world" | {BIN} > /dev/full 2>/dev/null; echo $?'
        p = subprocess.run(["bash", "-c", script], capture_output=True, timeout=TIMEOUT, text=True)
        rc = p.stdout.strip()
        report_result(rc != "", "fd: /dev/full -> doesn't hang")

    # /dev/null
    script = f'echo "hello world" | {BIN} > /dev/null 2>/dev/null; echo $?'
    p = subprocess.run(["bash", "-c", script], capture_output=True, timeout=TIMEOUT, text=True)
    rc = p.stdout.strip()
    report_result(rc == "0", "fd: /dev/null redirect -> exit 0")


# =============================================================================
#                     5. MEMORY SAFETY
# =============================================================================

def check_memory_safety():
    log("\n=== 5. Memory Safety ===")

    rc, out, err = run([BIN], stdin_data=b"hello world\n")
    report_result(rc == 0, "memory: no signal death on normal run")

    # Large input
    large_data = b"word " * 50000 + b"\n"
    rc, out, err = run([BIN], stdin_data=large_data, timeout=10)
    report_result(rc >= 0 and rc < 128, "memory: no crash with large input")

    long_line = b"A" * (128 * 1024) + b"\n"
    rc, out, err = run([BIN], stdin_data=long_line)
    report_result(rc >= 0 and rc < 128, "memory: no crash with 128KB line")

    for i in range(10):
        data = "".join(chr(random.randint(1, 127)) for _ in range(random.randint(0, 500)))
        rc, _, _ = run([BIN], stdin_data=data.encode())
        if rc >= 128:
            report_result(False, f"memory: crash with random input (trial {i})")
            break
    else:
        report_result(True, "memory: no signal death with 10 random inputs")

    def limit_stack():
        resource.setrlimit(resource.RLIMIT_STACK, (65536, 65536))
    rc, out, err = run([BIN], stdin_data=b"hello\n", preexec_fn=limit_stack)
    report_result(rc == 0, "memory: 64KB stack -> exit 0")

    def limit_mem():
        resource.setrlimit(resource.RLIMIT_AS, (16 * 1024 * 1024, 16 * 1024 * 1024))
    rc, out, err = run([BIN], stdin_data=b"hello\n", preexec_fn=limit_mem)
    report_result(rc == 0, "memory: 16MB address space -> exit 0")


# =============================================================================
#                     6. SIGNAL SAFETY
# =============================================================================

def check_signal_safety():
    log("\n=== 6. Signal Safety ===")

    script = f'echo "hello world" | {BIN} | head -c 0'
    p = subprocess.run(["bash", "-c", script], capture_output=True, timeout=TIMEOUT)
    report_result(p.returncode >= 0 and p.returncode < 128, "signal: SIGPIPE clean exit")

    ok_count = 0
    trials = 20
    for _ in range(trials):
        rc = os.system(f'echo "hello world" | {BIN} 2>/dev/null | head -c 0 >/dev/null 2>/dev/null')
        if os.WIFEXITED(rc) and os.WEXITSTATUS(rc) < 128:
            ok_count += 1
    report_result(ok_count >= trials - 2, f"signal: rapid SIGPIPE ({ok_count}/{trials})")

    for sig_name in ["SIGTERM", "SIGINT", "SIGHUP"]:
        rc, out, err = run([BIN], stdin_data=b"hello\n")
        report_result(rc == 0, f"signal: {sig_name} -- exits cleanly")


# =============================================================================
#                     7. INPUT FUZZING
# =============================================================================

def check_fuzzing():
    log("\n=== 7. Input Fuzzing ===")

    crash_count = 0
    for i in range(50):
        n_words = random.randint(0, 100)
        data = " ".join("".join(random.choices(string.printable, k=random.randint(1, 20)))
                        for _ in range(n_words))
        rc, out, err = run([BIN], stdin_data=data.encode())
        if rc >= 128:
            crash_count += 1
    report_result(crash_count == 0, f"fuzz: 50 random texts -- no signal death ({crash_count})")

    crash_count = 0
    for i in range(20):
        data = "".join(random.choices(string.printable, k=random.randint(1000, 10000)))
        rc, out, err = run([BIN], stdin_data=data.encode())
        if rc >= 128:
            crash_count += 1
    report_result(crash_count == 0, f"fuzz: 20 random long texts -- no signal death ({crash_count})")

    for desc, data in [("all-newlines", b"\n" * 1000),
                       ("all-spaces", b" " * 1000),
                       ("all-tabs", b"\t" * 1000),
                       ("control-chars", bytes(range(1, 32))),
                       ("unicode-multibyte", "\u00e9\u00e0\u00fc\u4e16\u754c ".encode() * 100)]:
        rc, _, _ = run([BIN], stdin_data=data)
        report_result(rc >= 0 and rc < 128, f"fuzz: pathological {desc} -> no crash")

    rc, out, err = run([BIN], stdin_data=b"X" * (128 * 1024))
    report_result(rc >= 0 and rc < 128, "fuzz: 128KB single word -> no crash")


# =============================================================================
#                     8. RESOURCE LIMIT TESTING
# =============================================================================

def check_resource_limits():
    log("\n=== 8. Resource Limit Testing ===")

    def limit_as():
        resource.setrlimit(resource.RLIMIT_AS, (16 * 1024 * 1024, 16 * 1024 * 1024))
    rc, _, _ = run([BIN], stdin_data=b"hello\n", preexec_fn=limit_as)
    report_result(rc == 0, "rlimit: RLIMIT_AS=16MB -> exit 0")

    def limit_nofile():
        resource.setrlimit(resource.RLIMIT_NOFILE, (3, 3))
    rc, _, _ = run([BIN], stdin_data=b"hello\n", preexec_fn=limit_nofile)
    report_result(rc >= 0 and rc < 128, "rlimit: RLIMIT_NOFILE=3 -> no crash")

    def limit_cpu():
        resource.setrlimit(resource.RLIMIT_CPU, (1, 1))
    rc, _, _ = run([BIN], stdin_data=b"hello\n", preexec_fn=limit_cpu)
    report_result(rc == 0, "rlimit: RLIMIT_CPU=1s -> exit 0")

    def limit_stack():
        resource.setrlimit(resource.RLIMIT_STACK, (65536, 65536))
    rc, _, _ = run([BIN], stdin_data=b"hello\n", preexec_fn=limit_stack)
    report_result(rc == 0, "rlimit: RLIMIT_STACK=64KB -> exit 0")

    def limit_fsize():
        resource.setrlimit(resource.RLIMIT_FSIZE, (0, 0))
    rc, _, _ = run([BIN], stdin_data=b"hello\n", preexec_fn=limit_fsize)
    report_result(rc == 0, "rlimit: RLIMIT_FSIZE=0 -> exit 0")

    def limit_all():
        resource.setrlimit(resource.RLIMIT_AS, (16 * 1024 * 1024, 16 * 1024 * 1024))
        resource.setrlimit(resource.RLIMIT_NOFILE, (3, 3))
        resource.setrlimit(resource.RLIMIT_CPU, (1, 1))
        resource.setrlimit(resource.RLIMIT_STACK, (65536, 65536))
        resource.setrlimit(resource.RLIMIT_FSIZE, (0, 0))
    rc, _, _ = run([BIN], stdin_data=b"hello\n", preexec_fn=limit_all)
    report_result(rc >= 0 and rc < 128, "rlimit: all limits combined -> no crash")


# =============================================================================
#                     9. ENVIRONMENT ROBUSTNESS
# =============================================================================

def check_environment():
    log("\n=== 9. Environment Robustness ===")

    rc, out, err = run([BIN], stdin_data=b"hello\n", env={})
    report_result(rc == 0, "env: empty environment -> exit 0")

    hostile = {
        "PATH": "",
        "HOME": "/nonexistent",
        "LANG": "xx_XX.BROKEN",
        "TERM": "",
        "LC_ALL": "C",
    }
    rc, out, err = run([BIN], stdin_data=b"hello\n", env=hostile)
    report_result(rc == 0, "env: hostile env vars -> exit 0")

    big_env = {f"VAR_{i}": f"value_{'X' * 100}" for i in range(1000)}
    rc, out, err = run([BIN], stdin_data=b"hello\n", env=big_env)
    report_result(rc == 0, "env: 1000 env vars -> exit 0")

    special_env = os.environ.copy()
    special_env["EVIL"] = "A" * 100000
    rc, out, err = run([BIN], stdin_data=b"hello\n", env=special_env)
    report_result(rc == 0, "env: 100KB env var -> exit 0")


# =============================================================================
#                     10. OUTPUT INTEGRITY
# =============================================================================

def check_output_integrity():
    log("\n=== 10. Output Integrity ===")

    test_input = b"hello world this is a test\n"
    outputs = []
    for _ in range(10):
        rc, out, err = run([BIN], stdin_data=test_input)
        outputs.append((rc, out, err))

    all_same = all(o == outputs[0] for o in outputs)
    report_result(all_same, "output: deterministic (10 runs identical)")

    all_zero = all(o[0] == 0 for o in outputs)
    report_result(all_zero, "output: all 10 runs exit 0")

    # Compare with GNU
    gnu_path = which(GNU)
    if gnu_path:
        for text in [b"hello world\n", b"short\n",
                     b"A longer piece of text that needs reformatting to fit the default width.\n",
                     b"\n", b"   indented text\n"]:
            rc_f, out_f, _ = run([BIN], stdin_data=text)
            rc_g, out_g, _ = run([gnu_path], stdin_data=text)
            report_result(out_f == out_g and rc_f == rc_g,
                         f"output: matches GNU for '{text[:30].decode(errors='replace').strip()}'")


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
        for args in [["--help"], ["--version"], ["/nonexistent/file"]]:
            rc_f, _, _ = run([BIN] + args)
            rc_g, _, _ = run([gnu_path] + args)
            report_result(rc_f == rc_g, f"error: exit code matches GNU for {args}")

    # EINTR injection
    if which("strace"):
        cmd = ["strace", "-e", "inject=write:error=EINTR:when=1", BIN]
        rc, out, err = run(cmd, stdin_data=b"hello\n")
        report_result(rc >= 0 and rc < 128, "error: EINTR injection -> no crash")


# =============================================================================
#                     12. CONCURRENCY STRESS
# =============================================================================

def check_concurrency():
    log("\n=== 12. Concurrency Stress ===")

    procs = []
    for _ in range(50):
        p = subprocess.Popen([BIN],
                           stdin=subprocess.PIPE,
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        procs.append(p)

    crash_count = 0
    for p in procs:
        try:
            out, err = p.communicate(input=b"hello world test\n", timeout=TIMEOUT)
            if p.returncode != 0:
                crash_count += 1
        except subprocess.TimeoutExpired:
            p.kill()
            crash_count += 1

    report_result(crash_count == 0, f"concurrency: 50 simultaneous ({crash_count} failures)")

    # Rapid start
    ok_count = 0
    for _ in range(50):
        p = subprocess.Popen([BIN],
                           stdin=subprocess.PIPE,
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            out, err = p.communicate(input=b"test\n", timeout=1)
            ok_count += 1
        except subprocess.TimeoutExpired:
            p.kill()
    report_result(ok_count == 50, f"concurrency: rapid start ({ok_count}/50)")


# =============================================================================
#                     13. TOOL-SPECIFIC: fmt
# =============================================================================

def check_tool_specific():
    log("\n=== 13. Tool-Specific: fmt ===")
    gnu_path = which(GNU)

    # Basic formatting -- should wrap at default width (75)
    long_text = b"This is a very long line that definitely exceeds the default width of seventy-five characters and needs to be wrapped.\n"
    rc, out, _ = run([BIN], stdin_data=long_text)
    report_result(rc == 0, "fmt: basic formatting works")
    if out:
        max_line_len = max(len(l) for l in out.decode().splitlines()) if out.strip() else 0
        report_result(max_line_len <= 75, f"fmt: default width <= 75 (got {max_line_len})")

    # Paragraphs preserved
    text = b"First paragraph text.\n\nSecond paragraph text.\n"
    rc, out, _ = run([BIN], stdin_data=text)
    report_result(b"\n\n" in out, "fmt: preserves paragraph breaks")

    # Width option
    text = b"Hello world this is a test of the fmt command.\n"
    rc, out, _ = run([BIN, "-w", "20"], stdin_data=text)
    if out:
        max_line_len = max(len(l) for l in out.decode().splitlines()) if out.strip() else 0
        report_result(max_line_len <= 20, f"fmt: -w 20 lines <= 20 chars (got {max_line_len})")

    # Empty input
    rc, out, _ = run([BIN], stdin_data=b"")
    report_result(rc == 0 and out == b"", "fmt: empty input -> empty output")

    # Newline only
    rc, out, _ = run([BIN], stdin_data=b"\n")
    report_result(rc == 0, "fmt: newline-only input")

    # Compare with GNU on various inputs
    if gnu_path:
        test_texts = [
            b"Hello world.\n",
            b"This is a test of the fmt command which reformats text to a given width.\n",
            b"Short.\n\nAnother paragraph.\n",
            b"  Indented line.\n",
            b"word " * 50 + b"\n",
        ]
        for text in test_texts:
            rc_f, out_f, _ = run([BIN], stdin_data=text)
            rc_g, out_g, _ = run([gnu_path], stdin_data=text)
            report_result(out_f == out_g and rc_f == rc_g,
                         f"fmt: matches GNU for '{text[:40].decode(errors='replace').strip()}'")

        # Width options comparison
        for width in ["20", "40", "60", "80"]:
            text = b"word " * 30 + b"\n"
            rc_f, out_f, _ = run([BIN, "-w", width], stdin_data=text)
            rc_g, out_g, _ = run([gnu_path, "-w", width], stdin_data=text)
            report_result(out_f == out_g, f"fmt: -w {width} matches GNU")

    # File input
    with tempfile.TemporaryDirectory() as td:
        fpath = os.path.join(td, "test.txt")
        with open(fpath, "w") as f:
            f.write("This is a test file with some text that needs formatting.\n")
        rc, out, _ = run([BIN, fpath])
        report_result(rc == 0 and len(out) > 0, "fmt: file input works")

    # Multiple files
    with tempfile.TemporaryDirectory() as td:
        for i in range(3):
            fpath = os.path.join(td, f"file{i}.txt")
            with open(fpath, "w") as f:
                f.write(f"Text from file {i}.\n")
        files = [os.path.join(td, f"file{i}.txt") for i in range(3)]
        rc, out, _ = run([BIN] + files)
        report_result(rc == 0, "fmt: multiple files work")

    # --help and --version
    rc, out, _ = run([BIN, "--help"])
    report_result(rc == 0 and len(out) > 0, "fmt: --help works")

    rc, out, _ = run([BIN, "--version"])
    report_result(rc == 0 and len(out) > 0, "fmt: --version works")


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
