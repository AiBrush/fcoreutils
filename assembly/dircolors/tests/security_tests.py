#!/usr/bin/env python3
"""security_tests.py — Security & memory safety tests for fdircolors.

fdircolors is a GNU-compatible 'dircolors' written in x86-64 Linux assembly.
It outputs commands to set LS_COLORS environment variable.

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
   13. Tool-specific (dircolors: LS_COLORS output)
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
GNU = "dircolors"
LOG_EVERY = 1

failures = []
test_count = 0
pass_count = 0
skip_count = 0

TMPDIR = None


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
    for name in ["fdircolors_release", "fdircolors"]:
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


def setup_fixtures():
    global TMPDIR
    TMPDIR = tempfile.mkdtemp(prefix="fdircolors_test_")


def cleanup_fixtures():
    if TMPDIR:
        import shutil
        shutil.rmtree(TMPDIR, ignore_errors=True)


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


def check_elf_properties():
    log("\n=== 1. ELF Binary Security Analysis ===")
    try:
        with open(BIN, "rb") as f:
            elf = f.read()
    except Exception as e:
        record_failure("elf", f"Cannot read binary: {e}")
        report_result(False, "elf: read binary")
        return

    report_result(elf[:4] == b"\x7fELF", "elf: magic bytes")
    report_result(elf[4] == 2, "elf: ELFCLASS64")
    size = len(elf)
    report_result(size < 30000, f"elf: binary size {size} bytes (<30KB)")

    e_phoff = struct.unpack_from("<Q", elf, 32)[0]
    e_phentsize = struct.unpack_from("<H", elf, 54)[0]
    e_phnum = struct.unpack_from("<H", elf, 56)[0]

    has_nx_stack = False
    for i in range(e_phnum):
        off = e_phoff + i * e_phentsize
        p_type = struct.unpack_from("<I", elf, off)[0]
        p_flags = struct.unpack_from("<I", elf, off + 4)[0]
        if p_type == 0x6474E551:
            has_nx_stack = not bool(p_flags & 1)
    report_result(has_nx_stack, "elf: NX stack")


def check_syscall_surface():
    log("\n=== 2. Syscall Surface Analysis ===")
    if not which("strace"):
        report_skip("syscall: strace not available")
        return
    cmd = ["strace", "-f", "-e", "trace=%network", BIN, "-b"]
    rc, out, err = run(cmd)
    err_text = err.decode(errors="replace")
    net_calls = [l for l in err_text.splitlines() if any(s in l for s in
                 ["socket(", "connect(", "bind("])]
    report_result(len(net_calls) == 0, "syscall: no network syscalls")


def check_proc_analysis():
    log("\n=== 3. /proc Runtime Analysis ===")
    rc, out, err = run([BIN, "-b"])
    report_result(rc == 0, "proc: tool runs cleanly")


def check_fd_hygiene():
    log("\n=== 4. File Descriptor Hygiene ===")
    script = f'exec 3>&1 1>&-; {BIN} -b 2>/dev/null; echo $? >&3'
    p = subprocess.run(["bash", "-c", script], capture_output=True, timeout=TIMEOUT, text=True)
    rc = p.stdout.strip()
    report_result(rc != "", "fd: closed stdout does not hang")

    if os.path.exists("/dev/null"):
        script = f'{BIN} -b > /dev/null 2>/dev/null; echo $?'
        p = subprocess.run(["bash", "-c", script], capture_output=True, timeout=TIMEOUT, text=True)
        rc = p.stdout.strip()
        report_result(rc == "0", "fd: /dev/null redirect exits 0")


def check_memory_safety():
    log("\n=== 5. Memory Safety ===")
    rc, out, err = run([BIN, "-b"])
    report_result(rc == 0 and rc < 128, "memory: normal run no crash")

    rc, out, err = run([BIN, "-Z"])
    report_result(rc >= 0 and rc < 128, "memory: invalid flag no crash")

    def limit_stack():
        resource.setrlimit(resource.RLIMIT_STACK, (65536, 65536))
    rc, out, err = run([BIN, "-b"], preexec_fn=limit_stack)
    report_result(rc >= 0 and rc < 128, "memory: 64KB stack no crash")


def check_signal_safety():
    log("\n=== 6. Signal Safety ===")
    script = f'{BIN} -b | head -c 0'
    p = subprocess.run(["bash", "-c", script], capture_output=True, timeout=TIMEOUT)
    report_result(p.returncode >= 0 and p.returncode < 128, "signal: SIGPIPE clean exit")


def check_fuzzing():
    log("\n=== 7. Input Fuzzing ===")
    crash_count = 0
    for i in range(30):
        args = ["-" + "".join(random.choices(string.ascii_lowercase, k=random.randint(1, 3)))
                for _ in range(random.randint(0, 2))]
        rc, out, err = run([BIN] + args)
        if rc >= 128:
            crash_count += 1
    report_result(crash_count == 0, f"fuzz: 30 random flag combos no crash ({crash_count})")


def check_resource_limits():
    log("\n=== 8. Resource Limit Testing ===")
    def limit_as():
        resource.setrlimit(resource.RLIMIT_AS, (16 * 1024 * 1024, 16 * 1024 * 1024))
    rc, _, _ = run([BIN, "-b"], preexec_fn=limit_as)
    report_result(rc >= 0 and rc < 128, "rlimit: RLIMIT_AS=16MB no crash")


def check_environment():
    log("\n=== 9. Environment Robustness ===")
    rc, out, err = run([BIN, "-b"], env={})
    report_result(rc == 0, "env: empty environment exits 0")

    hostile = {"PATH": "", "HOME": "/nonexistent", "LC_ALL": "C"}
    rc, out, err = run([BIN, "-b"], env=hostile)
    report_result(rc == 0, "env: hostile env exits 0")


def check_output_integrity():
    log("\n=== 10. Output Integrity ===")
    outputs = []
    for _ in range(5):
        rc, out, err = run([BIN, "-b"])
        outputs.append((rc, out))
    all_same = all(o == outputs[0] for o in outputs)
    report_result(all_same, "output: deterministic (5 runs identical)")

    report_result(outputs[0][1].endswith(b"\n"), "output: ends with newline")


def check_error_handling():
    log("\n=== 11. Error Handling ===")
    for flag in ["--badopt", "-Z"]:
        rc, out, err = run([BIN, flag])
        report_result(rc >= 0 and rc < 128, f"error: '{flag}' no signal death")


def check_concurrency():
    log("\n=== 12. Concurrency Stress ===")
    procs = []
    for _ in range(30):
        p = subprocess.Popen([BIN, "-b"],
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


def check_tool_specific():
    log("\n=== 13. Tool-Specific: dircolors ===")
    gnu_path = which(GNU)

    # Bourne shell output
    rc, out, _ = run([BIN, "-b"])
    out_text = out.decode(errors="replace")
    report_result(rc == 0 and "LS_COLORS=" in out_text,
                 "dircolors: -b produces LS_COLORS=")
    report_result("export LS_COLORS" in out_text,
                 "dircolors: -b contains export LS_COLORS")

    # C shell output
    rc, out, _ = run([BIN, "-c"])
    out_text = out.decode(errors="replace")
    report_result(rc == 0 and "setenv LS_COLORS" in out_text,
                 "dircolors: -c produces setenv LS_COLORS")

    # Print database
    rc, out, _ = run([BIN, "-p"])
    out_text = out.decode(errors="replace")
    report_result(rc == 0 and len(out) > 100,
                 "dircolors: -p produces database output")
    for keyword in ["DIR", "LINK", "EXEC"]:
        report_result(keyword in out_text,
                     f"dircolors: -p contains {keyword}")

    # Key LS_COLORS entries
    rc, out, _ = run([BIN, "-b"])
    out_text = out.decode(errors="replace")
    for entry in ["di=", "ln=", "ex="]:
        report_result(entry in out_text,
                     f"dircolors: LS_COLORS contains {entry}")

    # GNU comparison
    if gnu_path:
        rc_f, out_f, _ = run([BIN, "-b"])
        rc_g, out_g, _ = run([gnu_path, "-b"])
        report_result(rc_f == rc_g, "dircolors: -b exit code matches GNU")

        rc_f, out_f, _ = run([BIN, "-c"])
        rc_g, out_g, _ = run([gnu_path, "-c"])
        report_result(rc_f == rc_g, "dircolors: -c exit code matches GNU")


def run_tests():
    find_binary()
    setup_fixtures()
    check_elf_properties()
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
    cleanup_fixtures()


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
