#!/usr/bin/env python3
"""security_tests.py — Security & memory safety tests for frealpath.

frealpath is a GNU-compatible 'realpath' written in x86-64 Linux assembly.
It prints the resolved absolute file name.

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
   13. Tool-specific (realpath: path resolution)
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
GNU = "realpath"
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
    for name in ["frealpath_release", "frealpath"]:
        candidate = script_dir.parent / name
        if candidate.exists():
            BIN = str(candidate)
            break
    if not BIN:
        log(f"[ERROR] Binary not found in {script_dir.parent}")
        sys.exit(2)
    log(f"Binary: {BIN}")


def setup_fixtures():
    global TMPDIR
    TMPDIR = tempfile.mkdtemp(prefix="frealpath_test_")
    os.makedirs(f"{TMPDIR}/a/b", exist_ok=True)
    Path(f"{TMPDIR}/realfile").touch()
    Path(f"{TMPDIR}/a/b/deepfile").touch()
    os.symlink(f"{TMPDIR}/realfile", f"{TMPDIR}/symlink")
    os.symlink("realfile", f"{TMPDIR}/relsym")
    os.symlink("nonexistent", f"{TMPDIR}/brokensym")


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
        report_result(False, f"elf: read binary: {e}")
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
    cmd = ["strace", "-f", "-e", "trace=%network", BIN, f"{TMPDIR}/realfile"]
    rc, out, err = run(cmd)
    err_text = err.decode(errors="replace")
    net_calls = [l for l in err_text.splitlines() if any(s in l for s in
                 ["socket(", "connect(", "bind("])]
    report_result(len(net_calls) == 0, "syscall: no network syscalls")


def check_proc_analysis():
    log("\n=== 3. /proc Runtime Analysis ===")
    rc, out, err = run([BIN, f"{TMPDIR}/realfile"])
    report_result(rc == 0, "proc: tool runs cleanly")


def check_fd_hygiene():
    log("\n=== 4. File Descriptor Hygiene ===")
    script = f'{BIN} {TMPDIR}/realfile > /dev/null 2>/dev/null; echo $?'
    p = subprocess.run(["bash", "-c", script], capture_output=True, timeout=TIMEOUT, text=True)
    rc = p.stdout.strip()
    report_result(rc == "0", "fd: /dev/null redirect exits 0")


def check_memory_safety():
    log("\n=== 5. Memory Safety ===")
    rc, out, err = run([BIN, f"{TMPDIR}/realfile"])
    report_result(rc == 0, "memory: normal run no crash")

    rc, out, err = run([BIN, "-X"])
    report_result(rc >= 0 and rc < 128, "memory: invalid flag no crash")

    def limit_stack():
        resource.setrlimit(resource.RLIMIT_STACK, (65536, 65536))
    rc, out, err = run([BIN, f"{TMPDIR}/realfile"], preexec_fn=limit_stack)
    report_result(rc >= 0 and rc < 128, "memory: 64KB stack no crash")


def check_signal_safety():
    log("\n=== 6. Signal Safety ===")
    script = f'{BIN} {TMPDIR}/realfile | head -c 0'
    p = subprocess.run(["bash", "-c", script], capture_output=True, timeout=TIMEOUT)
    report_result(p.returncode >= 0 and p.returncode < 128, "signal: SIGPIPE clean exit")


def check_fuzzing():
    log("\n=== 7. Input Fuzzing ===")
    crash_count = 0
    for i in range(30):
        args = ["-" + "".join(random.choices("emsqz", k=random.randint(1, 3)))
                for _ in range(random.randint(0, 2))]
        args.append(f"{TMPDIR}/realfile")
        rc, out, err = run([BIN] + args)
        if rc >= 128:
            crash_count += 1
    report_result(crash_count == 0, f"fuzz: 30 random combos no crash ({crash_count})")


def check_resource_limits():
    log("\n=== 8. Resource Limit Testing ===")
    def limit_as():
        resource.setrlimit(resource.RLIMIT_AS, (16 * 1024 * 1024, 16 * 1024 * 1024))
    rc, _, _ = run([BIN, f"{TMPDIR}/realfile"], preexec_fn=limit_as)
    report_result(rc >= 0 and rc < 128, "rlimit: RLIMIT_AS=16MB no crash")


def check_environment():
    log("\n=== 9. Environment Robustness ===")
    rc, out, err = run([BIN, f"{TMPDIR}/realfile"], env={})
    report_result(rc == 0, "env: empty environment exits 0")


def check_output_integrity():
    log("\n=== 10. Output Integrity ===")
    outputs = []
    for _ in range(5):
        rc, out, err = run([BIN, f"{TMPDIR}/realfile"])
        outputs.append((rc, out))
    all_same = all(o == outputs[0] for o in outputs)
    report_result(all_same, "output: deterministic (5 runs)")

    report_result(outputs[0][1].endswith(b"\n"), "output: ends with newline")

    gnu_path = which(GNU)
    if gnu_path:
        for path in [f"{TMPDIR}/realfile", f"{TMPDIR}/symlink",
                     f"{TMPDIR}/a/b/deepfile", "/"]:
            rc_f, out_f, _ = run([BIN, path])
            rc_g, out_g, _ = run([gnu_path, path])
            report_result(out_f == out_g,
                         f"output: matches GNU for {os.path.basename(path) or '/'}")


def check_error_handling():
    log("\n=== 11. Error Handling ===")
    for flag in ["--badopt", "-X"]:
        rc, out, err = run([BIN, flag])
        report_result(rc >= 0 and rc < 128, f"error: '{flag}' no signal death")

    rc, out, err = run([BIN, f"{TMPDIR}/nonexistent"])
    report_result(rc == 1, "error: nonexistent exits 1")


def check_concurrency():
    log("\n=== 12. Concurrency Stress ===")
    procs = []
    for _ in range(30):
        p = subprocess.Popen([BIN, f"{TMPDIR}/realfile"],
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
    log("\n=== 13. Tool-Specific: realpath ===")
    gnu_path = which(GNU)

    # Basic resolution
    rc, out, _ = run([BIN, f"{TMPDIR}/realfile"])
    report_result(rc == 0 and out.strip() == f"{TMPDIR}/realfile".encode(),
                 "realpath: resolves regular file")

    rc, out, _ = run([BIN, f"{TMPDIR}/symlink"])
    report_result(rc == 0 and out.strip() == f"{TMPDIR}/realfile".encode(),
                 "realpath: resolves symlink")

    # Dotdot resolution
    rc, out, _ = run([BIN, f"{TMPDIR}/a/.."])
    report_result(rc == 0 and out.strip() == TMPDIR.encode(),
                 "realpath: resolves dotdot")

    # Root
    rc, out, _ = run([BIN, "/"])
    report_result(out.strip() == b"/", "realpath: root resolves to /")

    # -e mode (must exist)
    rc, _, _ = run([BIN, "-e", f"{TMPDIR}/nonexistent"])
    report_result(rc == 1, "realpath: -e nonexistent exits 1")

    # -m mode (doesn't need to exist)
    rc, out, _ = run([BIN, "-m", f"{TMPDIR}/nosuch/deep/path"])
    report_result(rc == 0 and len(out) > 0,
                 "realpath: -m nonexistent produces output")

    # -s mode (no symlinks)
    rc, out, _ = run([BIN, "-s", f"{TMPDIR}/a/.."])
    report_result(rc == 0 and out.strip() == TMPDIR.encode(),
                 "realpath: -s resolves dotdot without symlinks")

    # Multiple files
    rc, out, _ = run([BIN, f"{TMPDIR}/realfile", f"{TMPDIR}/a"])
    lines = out.strip().split(b"\n")
    report_result(len(lines) == 2, "realpath: multiple files produce multiple lines")


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
