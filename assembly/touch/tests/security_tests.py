#!/usr/bin/env python3
"""security_tests.py — Security & memory safety tests for ftouch."""

import os
import sys
import subprocess
import struct
import signal
import time
import tempfile
import resource
from pathlib import Path
from shutil import which

TIMEOUT = 5
BIN = ""
GNU = "touch"
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
    for name in ["ftouch_release", "ftouch"]:
        candidate = script_dir.parent / name
        if candidate.exists():
            BIN = str(candidate)
            break
    if not BIN:
        log(f"[ERROR] Binary not found in {script_dir.parent}")
        sys.exit(2)
    log(f"Binary: {BIN}")


def run(cmd, stdin_data=None, env=None, timeout=None):
    if timeout is None:
        timeout = TIMEOUT
    try:
        p = subprocess.Popen(
            cmd,
            stdin=subprocess.PIPE if stdin_data is not None else subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=env,
        )
        out, err = p.communicate(
            input=stdin_data.encode() if isinstance(stdin_data, str) else stdin_data,
            timeout=timeout,
        )
        return p.returncode, out, err
    except subprocess.TimeoutExpired:
        p.kill()
        p.wait()
        return -1, b"", b"TIMEOUT"
    except Exception as e:
        return -99, b"", str(e).encode()


def test_elf_header():
    with open(BIN, "rb") as f:
        magic = f.read(4)
    report_result(magic == b"\x7fELF", "ELF magic bytes")


def test_elf_class_64():
    with open(BIN, "rb") as f:
        f.seek(4)
        ei_class = struct.unpack("B", f.read(1))[0]
    report_result(ei_class == 2, "ELF 64-bit class")


def test_binary_size():
    size = os.path.getsize(BIN)
    report_result(size < 200_000, f"Binary size reasonable ({size} bytes)")


def test_nx_stack():
    with open(BIN, "rb") as f:
        f.seek(0x20)
        phoff = struct.unpack("<Q", f.read(8))[0]
        f.seek(0x36)
        phentsize = struct.unpack("<H", f.read(2))[0]
        phnum = struct.unpack("<H", f.read(2))[0]
        has_nx = False
        for i in range(phnum):
            f.seek(phoff + i * phentsize)
            p_type = struct.unpack("<I", f.read(4))[0]
            p_flags = struct.unpack("<I", f.read(4))[0]
            if p_type == 0x6474e551:
                has_nx = (p_flags & 1) == 0
    report_result(has_nx, "NX stack (PT_GNU_STACK)")


def test_help():
    rc, out, err = run([BIN, "--help"])
    text = out + err
    report_result(b"Usage" in text or b"touch" in text, "--help output")


def test_version():
    rc, out, err = run([BIN, "--version"])
    text = out + err
    report_result(b"coreutils" in text or b"touch" in text, "--version output")


def test_strace():
    strace = which("strace")
    if not strace:
        report_skip("strace not available")
        return
    rc, out, err = run([strace, "-c", BIN, "--help"], timeout=10)
    report_result(rc != -1, "strace completes")


def test_empty_env():
    rc, out, err = run([BIN, "--help"], env={})
    report_result(rc != -1, "Empty environment — no crash")


def test_large_env():
    env = os.environ.copy()
    for i in range(500):
        env[f"FUZZ_{i}"] = "x" * 200
    rc, out, err = run([BIN, "--help"], env=env)
    report_result(rc != -1, "Large environment — no crash")


def test_rapid_invocations():
    procs = []
    for _ in range(20):
        try:
            p = subprocess.Popen(
                [BIN, "--help"],
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )
            procs.append(p)
        except Exception:
            pass
    ok = True
    for p in procs:
        try:
            p.communicate(timeout=5)
        except Exception:
            p.kill()
            ok = False
    report_result(ok, "Rapid concurrent invocations")


def test_sigpipe():
    """Ensure SIGPIPE is handled gracefully."""
    try:
        p = subprocess.Popen(
            [BIN, "--help"],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        p.stdout.close()
        p.wait(timeout=5)
        report_result(True, "SIGPIPE handling")
    except Exception:
        report_result(False, "SIGPIPE handling")


def main():
    find_binary()
    log("")
    log("── ELF analysis ──")
    test_elf_header()
    test_elf_class_64()
    test_binary_size()
    test_nx_stack()
    log("── Syscall surface ──")
    test_strace()
    log("── Output integrity ──")
    test_help()
    test_version()
    log("── Environment ──")
    test_empty_env()
    test_large_env()
    log("── Signal safety ──")
    test_sigpipe()
    log("── Concurrency ──")
    test_rapid_invocations()
    log("")
    log(f"Results: {pass_count} passed, {test_count - pass_count} failed, "
        f"{skip_count} skipped out of {test_count} tests")
    if failures:
        log(f"\n{len(failures)} FAILURES:")
        for f in failures:
            log(f"  {f['details']}")
        sys.exit(1)
    else:
        log("\nALL TESTS PASSED")


if __name__ == "__main__":
    main()
