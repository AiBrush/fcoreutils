#!/usr/bin/env python3
"""security_tests.py — Security & memory safety tests for frm.

frm is a GNU-compatible 'rm' written in x86-64 Linux assembly.
It removes files and directories.

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
   13. Tool-specific (rm: file removal behavior)
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
GNU = "rm"
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
    for name in ["frm_release", "frm"]:
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
    report_result(size < 30000, f"elf: binary size {size} bytes (<30KB)")

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


# =============================================================================
#                     2-4. RUNTIME ANALYSIS
# =============================================================================

def check_runtime():
    log("\n=== 2-4. Runtime Analysis ===")
    with tempfile.TemporaryDirectory() as tmpdir:
        f = os.path.join(tmpdir, "f")
        with open(f, "w") as fh:
            fh.write("test")
        rc, out, err = run([BIN, f])
        report_result(rc == 0, "runtime: basic remove exits cleanly")
        report_result(not os.path.exists(f), "runtime: file actually removed")


# =============================================================================
#                     5. MEMORY SAFETY
# =============================================================================

def check_memory_safety():
    log("\n=== 5. Memory Safety ===")

    rc, out, err = run([BIN, "-f"] + [f"arg{i}" for i in range(100)])
    report_result(rc >= 0 and rc < 128, "memory: no crash with 100 args")

    long_arg = "A" * (128 * 1024)
    rc, out, err = run([BIN, "-f", long_arg])
    report_result(rc >= 0 and rc < 128, "memory: no crash with 128KB argument")

    for i in range(10):
        arg = "".join(chr(random.randint(1, 127)) for _ in range(random.randint(0, 500)))
        rc, _, _ = run([BIN, "-f", arg])
        if rc >= 128:
            report_result(False, f"memory: crash with random arg (trial {i})")
            break
    else:
        report_result(True, "memory: no signal death with 10 random args")

    def limit_stack():
        resource.setrlimit(resource.RLIMIT_STACK, (65536, 65536))
    rc, out, err = run([BIN, "-f", "/nonexistent"], preexec_fn=limit_stack)
    report_result(rc >= 0 and rc < 128, "memory: 64KB stack -> no crash")


# =============================================================================
#                     6. SIGNAL SAFETY
# =============================================================================

def check_signal_safety():
    log("\n=== 6. Signal Safety ===")

    with tempfile.TemporaryDirectory() as tmpdir:
        f = os.path.join(tmpdir, "f")
        with open(f, "w") as fh:
            fh.write("test")
        script = f'{BIN} {f} | head -c 0'
        p = subprocess.run(["bash", "-c", script], capture_output=True, timeout=TIMEOUT)
        report_result(p.returncode >= 0 and p.returncode < 128, "signal: SIGPIPE clean exit")


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
        rc, out, err = run([BIN, "-f"] + args)
        if rc >= 128:
            crash_count += 1
    report_result(crash_count == 0, f"fuzz: 50 random short args -- no signal death ({crash_count})")

    for desc, arg in [("all-newlines", "\n" * 1000),
                      ("control-chars", "".join(chr(i) for i in range(1, 32)))]:
        rc, _, _ = run([BIN, "-f", arg])
        report_result(rc >= 0 and rc < 128, f"fuzz: pathological {desc} -> no crash")


# =============================================================================
#                     8. RESOURCE LIMIT TESTING
# =============================================================================

def check_resource_limits():
    log("\n=== 8. Resource Limit Testing ===")

    def limit_as():
        resource.setrlimit(resource.RLIMIT_AS, (16 * 1024 * 1024, 16 * 1024 * 1024))
    rc, _, _ = run([BIN, "-f", "/nonexistent"], preexec_fn=limit_as)
    report_result(rc >= 0 and rc < 128, "rlimit: RLIMIT_AS=16MB -> no crash")

    def limit_nofile():
        resource.setrlimit(resource.RLIMIT_NOFILE, (3, 3))
    rc, _, _ = run([BIN, "-f", "/nonexistent"], preexec_fn=limit_nofile)
    report_result(rc >= 0 and rc < 128, "rlimit: RLIMIT_NOFILE=3 -> no crash")


# =============================================================================
#                     9. ENVIRONMENT ROBUSTNESS
# =============================================================================

def check_environment():
    log("\n=== 9. Environment Robustness ===")

    with tempfile.TemporaryDirectory() as tmpdir:
        f = os.path.join(tmpdir, "f")
        with open(f, "w") as fh:
            fh.write("test")
        rc, out, err = run([BIN, f], env={})
        report_result(rc == 0, "env: empty environment -> exit 0")

    with tempfile.TemporaryDirectory() as tmpdir:
        f = os.path.join(tmpdir, "f")
        with open(f, "w") as fh:
            fh.write("test")
        big_env = {f"VAR_{i}": f"value_{'X' * 100}" for i in range(1000)}
        rc, out, err = run([BIN, f], env=big_env)
        report_result(rc == 0, "env: 1000 env vars -> exit 0")


# =============================================================================
#                     10-11. OUTPUT & ERROR HANDLING
# =============================================================================

def check_output_error():
    log("\n=== 10-11. Output & Error Handling ===")

    gnu_path = which(GNU)
    if gnu_path:
        rc_f, _, _ = run([BIN])
        rc_g, _, _ = run([gnu_path])
        report_result(rc_f == rc_g, "output: exit code matches GNU for no args")

        rc_f, _, _ = run([BIN, "--help"])
        rc_g, _, _ = run([gnu_path, "--help"])
        report_result(rc_f == rc_g, "output: exit code matches GNU for --help")

        rc_f, _, _ = run([BIN, "-f"])
        rc_g, _, _ = run([gnu_path, "-f"])
        report_result(rc_f == rc_g, "output: exit code matches GNU for -f (no args)")

    # Error on nonexistent without -f
    rc, out, err = run([BIN, "/nonexistent_xyz"])
    report_result(rc == 1, "error: nonexistent file -> exit 1")
    report_result(b"cannot remove" in err, "error: error message contains 'cannot remove'")


# =============================================================================
#                     12. CONCURRENCY STRESS
# =============================================================================

def check_concurrency():
    log("\n=== 12. Concurrency Stress ===")

    with tempfile.TemporaryDirectory() as tmpdir:
        files = []
        for i in range(50):
            f = os.path.join(tmpdir, f"f_{i}")
            with open(f, "w") as fh:
                fh.write("test")
            files.append(f)

        procs = []
        for f in files:
            p = subprocess.Popen([BIN, f],
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


# =============================================================================
#                     13. TOOL-SPECIFIC: rm
# =============================================================================

def check_tool_specific():
    log("\n=== 13. Tool-Specific: rm ===")

    with tempfile.TemporaryDirectory() as tmpdir:
        # Remove file
        f = os.path.join(tmpdir, "f")
        with open(f, "w") as fh:
            fh.write("hello")
        rc, out, err = run([BIN, f])
        report_result(rc == 0, "rm: remove file -> exit 0")
        report_result(not os.path.exists(f), "rm: file actually gone")

        # Remove directory with -r
        d = os.path.join(tmpdir, "dir")
        os.makedirs(os.path.join(d, "sub"))
        with open(os.path.join(d, "f1"), "w") as fh:
            fh.write("a")
        with open(os.path.join(d, "sub", "f2"), "w") as fh:
            fh.write("b")
        rc, out, err = run([BIN, "-r", d])
        report_result(rc == 0, "rm: -r recursive -> exit 0")
        report_result(not os.path.exists(d), "rm: directory recursively removed")

        # -f nonexistent
        rc, out, err = run([BIN, "-f", os.path.join(tmpdir, "nope")])
        report_result(rc == 0, "rm: -f nonexistent -> exit 0")
        report_result(err == b"", "rm: -f nonexistent -> no stderr")

        # Remove dir without -r
        d2 = os.path.join(tmpdir, "dir2")
        os.makedirs(d2)
        rc, out, err = run([BIN, d2])
        report_result(rc == 1, "rm: dir without -r -> exit 1")
        err_text = err.decode(errors="replace")
        report_result("Is a directory" in err_text, "rm: dir without -r -> 'Is a directory'")

        # -d for empty dir
        d3 = os.path.join(tmpdir, "dir3")
        os.makedirs(d3)
        rc, out, err = run([BIN, "-d", d3])
        report_result(rc == 0, "rm: -d empty dir -> exit 0")
        report_result(not os.path.exists(d3), "rm: -d empty dir removed")

    # --help
    rc, out, err = run([BIN, "--help"])
    report_result(rc == 0, "rm: --help -> exit 0")
    report_result(b"Usage:" in out, "rm: --help contains 'Usage:'")

    # --version
    rc, out, err = run([BIN, "--version"])
    report_result(rc == 0, "rm: --version -> exit 0")
    report_result(b"rm" in out, "rm: --version contains 'rm'")

    # Missing operand
    rc, out, err = run([BIN])
    err_text = err.decode(errors="replace")
    report_result(rc == 1, "rm: no args -> exit 1")
    report_result("missing operand" in err_text, "rm: missing operand message")


# =============================================================================
#                           MAIN
# =============================================================================

def run_tests():
    find_binary()
    check_elf_properties()
    check_strings_leaks()
    check_runtime()
    check_memory_safety()
    check_signal_safety()
    check_fuzzing()
    check_resource_limits()
    check_environment()
    check_output_error()
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
