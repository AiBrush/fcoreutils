#!/usr/bin/env python3
"""security_tests.py — Security & memory safety tests for fcp."""

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
GNU = "cp"
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
    for name in ["fcp_release", "fcp"]:
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
    log("\n=== 13. Tool-Specific: cp ===")

    with tempfile.TemporaryDirectory() as tmpdir:
        # Basic copy
        src = os.path.join(tmpdir, "src")
        dst = os.path.join(tmpdir, "dst")
        with open(src, "w") as f:
            f.write("hello world")
        rc, out, err = run([BIN, src, dst])
        report_result(rc == 0, "cp: basic copy -> exit 0")
        report_result(os.path.exists(src), "cp: source preserved")
        report_result(os.path.exists(dst), "cp: dest created")
        if os.path.exists(dst):
            with open(dst) as f:
                report_result(f.read() == "hello world", "cp: content matches")
        else:
            report_result(False, "cp: content matches")

        # Recursive copy
        d = os.path.join(tmpdir, "dir")
        d2 = os.path.join(tmpdir, "dir2")
        os.makedirs(os.path.join(d, "sub"))
        with open(os.path.join(d, "f1"), "w") as f:
            f.write("a")
        with open(os.path.join(d, "sub", "f2"), "w") as f:
            f.write("b")
        rc, out, err = run([BIN, "-r", d, d2])
        report_result(rc == 0, "cp: -r recursive -> exit 0")
        report_result(os.path.isdir(d2), "cp: recursive dir created")
        if os.path.exists(os.path.join(d2, "f1")):
            with open(os.path.join(d2, "f1")) as f:
                report_result(f.read() == "a", "cp: recursive file content")
        else:
            report_result(False, "cp: recursive file content")

        # No-clobber
        f1 = os.path.join(tmpdir, "nc1")
        f2 = os.path.join(tmpdir, "nc2")
        with open(f1, "w") as fh:
            fh.write("original")
        with open(f2, "w") as fh:
            fh.write("new")
        rc, out, err = run([BIN, "-n", f2, f1])
        with open(f1) as fh:
            report_result(fh.read() == "original", "cp: -n preserved dest")

        # Hard link
        hl = os.path.join(tmpdir, "hl")
        rc, out, err = run([BIN, "-l", src, hl])
        report_result(rc == 0, "cp: -l hard link -> exit 0")
        if os.path.exists(hl):
            report_result(os.stat(src).st_ino == os.stat(hl).st_ino, "cp: -l same inode")
        else:
            report_result(False, "cp: -l same inode")

        # Dir without -r
        d3 = os.path.join(tmpdir, "dir3")
        os.makedirs(d3)
        rc, out, err = run([BIN, d3, os.path.join(tmpdir, "d3copy")])
        report_result(rc == 1, "cp: dir without -r -> exit 1")
        err_text = err.decode(errors="replace")
        report_result("omitting" in err_text, "cp: omitting directory message")

        # Nonexistent source
        rc, out, err = run([BIN, os.path.join(tmpdir, "nope"), os.path.join(tmpdir, "x")])
        report_result(rc == 1, "cp: nonexistent -> exit 1")

    # Large file
    with tempfile.TemporaryDirectory() as tmpdir:
        src = os.path.join(tmpdir, "large")
        dst = os.path.join(tmpdir, "large_dst")
        with open(src, "wb") as f:
            f.write(os.urandom(100000))
        rc, out, err = run([BIN, src, dst])
        report_result(rc == 0, "cp: 100KB file -> exit 0")
        if os.path.exists(dst):
            with open(src, "rb") as f1, open(dst, "rb") as f2:
                report_result(f1.read() == f2.read(), "cp: 100KB content matches")
        else:
            report_result(False, "cp: 100KB content matches")

    # --help
    rc, out, err = run([BIN, "--help"])
    report_result(rc == 0, "cp: --help -> exit 0")
    report_result(b"Usage:" in out, "cp: --help contains 'Usage:'")

    # --version
    rc, out, err = run([BIN, "--version"])
    report_result(rc == 0, "cp: --version -> exit 0")
    report_result(b"cp" in out, "cp: --version contains 'cp'")

    # Missing operand
    rc, out, err = run([BIN])
    report_result(rc == 1, "cp: no args -> exit 1")
    report_result(b"missing" in err, "cp: missing operand message")


def check_concurrency():
    log("\n=== 12. Concurrency Stress ===")
    with tempfile.TemporaryDirectory() as tmpdir:
        src = os.path.join(tmpdir, "src")
        with open(src, "w") as f:
            f.write("test content")

        procs = []
        for i in range(50):
            dst = os.path.join(tmpdir, f"dst_{i}")
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
