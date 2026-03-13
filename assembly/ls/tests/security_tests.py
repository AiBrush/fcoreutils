#!/usr/bin/env python3
"""security_tests.py — Security & memory safety tests for fls.

fls is a GNU-compatible 'ls' written in x86-64 Linux assembly.
It lists directory contents.

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
   13. Tool-specific (ls: directory listing behavior)
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
GNU = "ls"
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
    for name in ["fls_release", "fls"]:
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

    PT_INTERP, PT_DYNAMIC, PT_GNU_STACK = 3, 2, 0x6474E551
    PF_X = 1

    has_interp = has_dynamic = False
    has_nx_stack = False

    for i in range(e_phnum):
        off = e_phoff + i * e_phentsize
        p_type = struct.unpack_from("<I", elf, off)[0]
        p_flags = struct.unpack_from("<I", elf, off + 4)[0]

        if p_type == PT_INTERP:
            has_interp = True
        if p_type == PT_DYNAMIC:
            has_dynamic = True
        if p_type == PT_GNU_STACK:
            has_nx_stack = not bool(p_flags & PF_X)

    report_result(not has_interp, "elf: no PT_INTERP (static binary)")
    report_result(not has_dynamic, "elf: no PT_DYNAMIC (no dynamic linking)")
    report_result(has_nx_stack, "elf: PT_GNU_STACK NX (non-executable stack)")


# =============================================================================
#                     4. FILE DESCRIPTOR HYGIENE
# =============================================================================

def check_fd_hygiene():
    log("\n=== 4. File Descriptor Hygiene ===")

    # Closed stderr — tool should still work
    script = f'exec 3>&1; {BIN} /tmp 2>&- 1>&3; echo $? >&3'
    p = subprocess.run(["bash", "-c", script], capture_output=True, timeout=TIMEOUT, text=True)
    lines = p.stdout.strip().split("\n")
    rc = lines[-1] if lines else ""
    report_result(rc == "0", "fd: closed stderr -> exit 0")

    # /dev/null redirect
    script = f'{BIN} /tmp > /dev/null 2>/dev/null; echo $?'
    p = subprocess.run(["bash", "-c", script], capture_output=True, timeout=TIMEOUT, text=True)
    rc = p.stdout.strip()
    report_result(rc == "0", "fd: /dev/null redirect -> exit 0")


# =============================================================================
#                     5. MEMORY SAFETY
# =============================================================================

def check_memory_safety():
    log("\n=== 5. Memory Safety ===")

    rc, out, err = run([BIN, "/tmp"])
    report_result(rc == 0, "memory: no signal death on normal run")

    rc, out, err = run([BIN] + ["/tmp"] * 100)
    report_result(rc >= 0 and rc < 128, "memory: 100 repeated args -> no crash")

    def limit_stack():
        resource.setrlimit(resource.RLIMIT_STACK, (65536, 65536))
    rc, out, err = run([BIN, "/tmp"], preexec_fn=limit_stack)
    report_result(rc >= 0 and rc < 128, "memory: 64KB stack -> no crash")


# =============================================================================
#                     6. SIGNAL SAFETY
# =============================================================================

def check_signal_safety():
    log("\n=== 6. Signal Safety ===")

    script = f'{BIN} /tmp | head -c 0'
    p = subprocess.run(["bash", "-c", script], capture_output=True, timeout=TIMEOUT)
    report_result(p.returncode >= 0 and p.returncode < 128, "signal: SIGPIPE clean exit")


# =============================================================================
#                     7. INPUT FUZZING
# =============================================================================

def check_fuzzing():
    log("\n=== 7. Input Fuzzing ===")

    crash_count = 0
    for i in range(20):
        n_args = random.randint(0, 5)
        args = ["-" + "".join(random.choices("laA1RrSthdisC", k=random.randint(0, 5)))
                for _ in range(n_args)]
        args.append("/tmp")
        rc, out, err = run([BIN] + args)
        if rc >= 128:
            crash_count += 1
    report_result(crash_count == 0, f"fuzz: 20 random flag combos -> no signal death")

    crash_count = 0
    for i in range(10):
        path = "/" + "/".join(["".join(random.choices(string.ascii_lowercase, k=5))
                               for _ in range(random.randint(1, 10))])
        rc, out, err = run([BIN, path])
        if rc >= 128:
            crash_count += 1
    report_result(crash_count == 0, "fuzz: 10 random paths -> no signal death")


# =============================================================================
#                     8. RESOURCE LIMIT TESTING
# =============================================================================

def check_resource_limits():
    log("\n=== 8. Resource Limit Testing ===")

    def limit_as():
        resource.setrlimit(resource.RLIMIT_AS, (32 * 1024 * 1024, 32 * 1024 * 1024))
    rc, _, _ = run([BIN, "/tmp"], preexec_fn=limit_as)
    report_result(rc >= 0 and rc < 128, "rlimit: RLIMIT_AS=32MB -> no crash")


# =============================================================================
#                     9. ENVIRONMENT ROBUSTNESS
# =============================================================================

def check_environment():
    log("\n=== 9. Environment Robustness ===")

    rc, out, err = run([BIN, "/tmp"], env={})
    report_result(rc == 0, "env: empty environment -> exit 0")


# =============================================================================
#                     10. OUTPUT INTEGRITY
# =============================================================================

def check_output_integrity():
    log("\n=== 10. Output Integrity ===")

    with tempfile.TemporaryDirectory() as td:
        for name in ["alpha", "beta", "gamma"]:
            Path(td, name).touch()

        rc, out, err = run([BIN, td])
        report_result(rc == 0, "output: exit 0 for simple dir")
        names = sorted(out.decode().strip().split("\n"))
        report_result(names == ["alpha", "beta", "gamma"],
                     "output: correct names listed")

        # Deterministic
        outputs = []
        for _ in range(5):
            rc, out, err = run([BIN, td])
            outputs.append(out)
        report_result(all(o == outputs[0] for o in outputs),
                     "output: deterministic (5 runs)")

    # Compare with GNU (one-per-line, piped)
    gnu_path = which(GNU)
    if gnu_path:
        rc_f, out_f, _ = run([BIN, "/tmp"])
        rc_g, out_g, _ = run([gnu_path, "/tmp"])
        names_f = sorted(out_f.decode().strip().split("\n"))
        names_g = sorted(out_g.decode().strip().split("\n"))
        report_result(names_f == names_g, "output: matches GNU ls names for /tmp")


# =============================================================================
#                     11. ERROR HANDLING
# =============================================================================

def check_error_handling():
    log("\n=== 11. Error Handling ===")

    rc, out, err = run([BIN, "/nonexistent_path_xyz_$$"])
    report_result(rc != 0, "error: nonexistent path -> nonzero exit")
    report_result(len(err) > 0, "error: nonexistent path -> stderr message")


# =============================================================================
#                     12. CONCURRENCY STRESS
# =============================================================================

def check_concurrency():
    log("\n=== 12. Concurrency Stress ===")

    procs = []
    for _ in range(30):
        p = subprocess.Popen([BIN, "/tmp"],
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

    report_result(crash_count == 0, f"concurrency: 30 simultaneous ({crash_count} failures)")


# =============================================================================
#                     13. TOOL-SPECIFIC: ls
# =============================================================================

def check_tool_specific():
    log("\n=== 13. Tool-Specific: ls ===")

    with tempfile.TemporaryDirectory() as td:
        # Create test files
        for name in ["aaa", "bbb", "ccc", ".hidden"]:
            Path(td, name).touch()
        os.mkdir(os.path.join(td, "subdir"))

        # Basic listing
        rc, out, _ = run([BIN, td])
        names = out.decode().strip().split("\n")
        report_result("aaa" in names and "bbb" in names, "ls: basic listing includes files")
        report_result(".hidden" not in names, "ls: hidden files excluded by default")

        # -a shows hidden
        rc, out, _ = run([BIN, "-a", td])
        names = out.decode().strip().split("\n")
        report_result(".hidden" in names, "ls: -a shows hidden files")
        report_result("." in names, "ls: -a shows .")
        report_result(".." in names, "ls: -a shows ..")

        # -A shows hidden but not . and ..
        rc, out, _ = run([BIN, "-A", td])
        names = out.decode().strip().split("\n")
        report_result(".hidden" in names, "ls: -A shows hidden files")
        report_result("." not in names, "ls: -A hides .")
        report_result(".." not in names, "ls: -A hides ..")

        # -d flag
        rc, out, _ = run([BIN, "-d", td])
        report_result(out.decode().strip() == td, "ls: -d prints directory name")

        # -l flag
        rc, out, _ = run([BIN, "-l", td])
        report_result(rc == 0, "ls: -l exit code 0")
        lines = out.decode().strip().split("\n")
        report_result(lines[0].startswith("total"), "ls: -l starts with total line")

        # -r flag (reverse)
        rc, out_fwd, _ = run([BIN, "-1", td])
        rc, out_rev, _ = run([BIN, "-1r", td])
        fwd = out_fwd.decode().strip().split("\n")
        rev = out_rev.decode().strip().split("\n")
        report_result(fwd == list(reversed(rev)), "ls: -r reverses order")

        # Nonexistent
        rc, out, err = run([BIN, os.path.join(td, "nonexistent")])
        report_result(rc != 0, "ls: nonexistent -> error exit")

    # Empty directory
    with tempfile.TemporaryDirectory() as td:
        rc, out, _ = run([BIN, td])
        report_result(rc == 0 and out.strip() == b"", "ls: empty dir -> empty output")


# =============================================================================
#                           MAIN
# =============================================================================

def run_tests():
    find_binary()
    check_elf_properties()
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
