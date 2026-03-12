#!/usr/bin/env python3
"""security_tests.py — Security & memory safety tests for fmv."""

import os
import sys
import subprocess
import struct
import random
import string
import tempfile
import resource
from pathlib import Path
from shutil import which

TIMEOUT = 5
BIN = ""
GNU = "mv"
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
    for name in ["fmv_release", "fmv"]:
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
    report_result(len(elf) < 30000, f"elf: binary size {len(elf)} bytes (<30KB)")

    e_phoff = struct.unpack_from("<Q", elf, 32)[0]
    e_phentsize = struct.unpack_from("<H", elf, 54)[0]
    e_phnum = struct.unpack_from("<H", elf, 56)[0]

    has_nx_stack = False
    has_interp = False
    for i in range(e_phnum):
        off = e_phoff + i * e_phentsize
        p_type = struct.unpack_from("<I", elf, off)[0]
        p_flags = struct.unpack_from("<I", elf, off + 4)[0]
        if p_type == 3:
            has_interp = True
        if p_type == 0x6474E551:
            has_nx_stack = not bool(p_flags & 1)

    report_result(not has_interp, "elf: no PT_INTERP (static binary)")
    report_result(has_nx_stack, "elf: PT_GNU_STACK NX")


def check_strings_leaks():
    log("\n=== Binary String Leak Analysis ===")
    with open(BIN, "rb") as f:
        data = f.read()

    bad_patterns = [
        (b"/etc/", "filesystem path /etc/"),
        (b"/home/", "home directory path"),
        (b"DEBUG", "debug string"),
        (b"password", "password string"),
        (b".so", "shared library reference"),
        (b"ld-linux", "dynamic linker reference"),
    ]
    for pattern, desc in bad_patterns:
        report_result(pattern not in data, f"strings: no {desc} in binary")


def check_memory_safety():
    log("\n=== 5. Memory Safety ===")

    rc, out, err = run([BIN] + [f"arg{i}" for i in range(100)] + ["/tmp"])
    report_result(rc >= 0 and rc < 128, "memory: no crash with 100 args")

    long_arg = "A" * (128 * 1024)
    rc, out, err = run([BIN, long_arg, "/tmp/x"])
    report_result(rc >= 0 and rc < 128, "memory: no crash with 128KB argument")

    def limit_stack():
        resource.setrlimit(resource.RLIMIT_STACK, (65536, 65536))
    rc, out, err = run([BIN, "/nonexistent", "/tmp/x"], preexec_fn=limit_stack)
    report_result(rc >= 0 and rc < 128, "memory: 64KB stack -> no crash")


def check_signal_safety():
    log("\n=== 6. Signal Safety ===")
    with tempfile.TemporaryDirectory() as tmpdir:
        src = os.path.join(tmpdir, "src")
        dst = os.path.join(tmpdir, "dst")
        with open(src, "w") as f:
            f.write("test")
        script = f'{BIN} {src} {dst} | head -c 0'
        p = subprocess.run(["bash", "-c", script], capture_output=True, timeout=TIMEOUT)
        report_result(p.returncode >= 0 and p.returncode < 128, "signal: SIGPIPE clean exit")


def check_fuzzing():
    log("\n=== 7. Input Fuzzing ===")

    crash_count = 0
    for i in range(30):
        n_args = random.randint(0, 10)
        args = ["".join(random.choices(string.printable, k=random.randint(0, 100)))
                for _ in range(n_args)]
        rc, _, _ = run([BIN] + args)
        if rc >= 128:
            crash_count += 1
    report_result(crash_count == 0, f"fuzz: 30 random args -- no signal death")


def check_resource_limits():
    log("\n=== 8. Resource Limit Testing ===")

    def limit_as():
        resource.setrlimit(resource.RLIMIT_AS, (16 * 1024 * 1024, 16 * 1024 * 1024))
    rc, _, _ = run([BIN, "/nonexistent", "/tmp/x"], preexec_fn=limit_as)
    report_result(rc >= 0 and rc < 128, "rlimit: RLIMIT_AS=16MB -> no crash")


def check_environment():
    log("\n=== 9. Environment Robustness ===")
    with tempfile.TemporaryDirectory() as tmpdir:
        src = os.path.join(tmpdir, "src")
        dst = os.path.join(tmpdir, "dst")
        with open(src, "w") as f:
            f.write("test")
        rc, out, err = run([BIN, src, dst], env={})
        report_result(rc == 0, "env: empty environment -> exit 0")


def check_tool_specific():
    log("\n=== 13. Tool-Specific: mv ===")

    with tempfile.TemporaryDirectory() as tmpdir:
        # Basic move
        src = os.path.join(tmpdir, "src")
        dst = os.path.join(tmpdir, "dst")
        with open(src, "w") as f:
            f.write("hello world")
        rc, out, err = run([BIN, src, dst])
        report_result(rc == 0, "mv: basic move -> exit 0")
        report_result(not os.path.exists(src), "mv: source removed")
        report_result(os.path.exists(dst), "mv: dest created")
        if os.path.exists(dst):
            with open(dst) as f:
                report_result(f.read() == "hello world", "mv: content preserved")
        else:
            report_result(False, "mv: content preserved")

        # Move into directory
        src2 = os.path.join(tmpdir, "src2")
        d = os.path.join(tmpdir, "dir")
        os.makedirs(d)
        with open(src2, "w") as f:
            f.write("test")
        rc, out, err = run([BIN, src2, d])
        report_result(rc == 0, "mv: move into dir -> exit 0")
        report_result(os.path.exists(os.path.join(d, "src2")), "mv: file in dir")

        # No-clobber
        f1 = os.path.join(tmpdir, "nc1")
        f2 = os.path.join(tmpdir, "nc2")
        with open(f1, "w") as fh:
            fh.write("original")
        with open(f2, "w") as fh:
            fh.write("new")
        rc, out, err = run([BIN, "-n", f2, f1])
        report_result(rc == 0, "mv: -n no-clobber -> exit 0")
        with open(f1) as fh:
            report_result(fh.read() == "original", "mv: -n preserved dest")

        # Move nonexistent
        rc, out, err = run([BIN, os.path.join(tmpdir, "nope"), os.path.join(tmpdir, "dst2")])
        report_result(rc == 1, "mv: nonexistent -> exit 1")

    # --help
    rc, out, err = run([BIN, "--help"])
    report_result(rc == 0, "mv: --help -> exit 0")
    report_result(b"Usage:" in out, "mv: --help contains 'Usage:'")

    # --version
    rc, out, err = run([BIN, "--version"])
    report_result(rc == 0, "mv: --version -> exit 0")
    report_result(b"mv" in out, "mv: --version contains 'mv'")

    # Missing operand
    rc, out, err = run([BIN])
    report_result(rc == 1, "mv: no args -> exit 1")
    report_result(b"missing" in err, "mv: missing operand message")


def check_concurrency():
    log("\n=== 12. Concurrency Stress ===")
    with tempfile.TemporaryDirectory() as tmpdir:
        procs = []
        for i in range(50):
            src = os.path.join(tmpdir, f"src_{i}")
            dst = os.path.join(tmpdir, f"dst_{i}")
            with open(src, "w") as f:
                f.write("test")
            p = subprocess.Popen([BIN, src, dst],
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            procs.append(p)

        crash_count = 0
        for p in procs:
            try:
                p.communicate(timeout=TIMEOUT)
                if p.returncode >= 128:
                    crash_count += 1
            except subprocess.TimeoutExpired:
                p.kill()
                crash_count += 1

        report_result(crash_count == 0, f"concurrency: 50 simultaneous ({crash_count} crashes)")


def run_tests():
    find_binary()
    check_elf_properties()
    check_strings_leaks()
    check_memory_safety()
    check_signal_safety()
    check_fuzzing()
    check_resource_limits()
    check_environment()
    check_tool_specific()
    check_concurrency()


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
