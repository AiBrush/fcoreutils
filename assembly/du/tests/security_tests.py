#!/usr/bin/env python3
"""security_tests.py — Security & memory safety tests for fdu."""

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

TIMEOUT = 10
BIN = ""
GNU = "du"
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
    for name in ["fdu_release", "fdu"]:
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
        p = subprocess.Popen(cmd, stdin=subprocess.PIPE if stdin_data is not None else subprocess.DEVNULL,
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env, preexec_fn=preexec_fn)
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
    report_result(elf[4] == 2, "elf: 64-bit")
    report_result(len(elf) < 100000, f"elf: size {len(elf)} (<100KB)")

def check_memory_safety():
    log("\n=== 5. Memory Safety ===")
    with tempfile.TemporaryDirectory() as td:
        rc, out, err = run([BIN, "-s", td])
        report_result(rc == 0, "memory: normal run exit 0")
    def limit_stack():
        resource.setrlimit(resource.RLIMIT_STACK, (131072, 131072))
    with tempfile.TemporaryDirectory() as td:
        rc, out, err = run([BIN, "-s", td], preexec_fn=limit_stack)
        report_result(rc >= 0 and rc < 128, "memory: 128KB stack no crash")

def check_output_integrity():
    log("\n=== 10. Output Integrity ===")
    with tempfile.TemporaryDirectory() as td:
        Path(td, "file1").write_bytes(b"x" * 4096)
        Path(td, "file2").write_bytes(b"y" * 8192)
        rc, out, _ = run([BIN, "-s", td])
        report_result(rc == 0, "output: -s exit 0")
        # Should produce one line with number\tpath
        lines = out.decode().strip().split("\n")
        report_result(len(lines) == 1, "output: -s produces one line")
        parts = lines[0].split("\t")
        report_result(len(parts) == 2, "output: tab-separated size and path")

        # Deterministic
        outputs = []
        for _ in range(5):
            rc, out, _ = run([BIN, "-s", td])
            outputs.append(out)
        report_result(all(o == outputs[0] for o in outputs), "output: deterministic")

def check_tool_specific():
    log("\n=== 13. Tool-Specific: du ===")
    with tempfile.TemporaryDirectory() as td:
        os.makedirs(os.path.join(td, "sub"))
        Path(td, "file.txt").write_bytes(b"x" * 1024)
        Path(td, "sub", "nested.txt").write_bytes(b"y" * 2048)

        # -s summary
        rc, out, _ = run([BIN, "-s", td])
        report_result(rc == 0, "du: -s works")

        # -a shows files
        rc, out, _ = run([BIN, "-a", td])
        report_result(b"file.txt" in out, "du: -a shows files")

        # Nonexistent
        rc, out, err = run([BIN, os.path.join(td, "nope")])
        report_result(rc != 0, "du: nonexistent -> error")

        # Empty dir
        edir = os.path.join(td, "empty")
        os.makedirs(edir)
        rc, out, _ = run([BIN, "-s", edir])
        report_result(rc == 0, "du: empty dir -> exit 0")

def run_tests():
    find_binary()
    check_elf_properties()
    check_memory_safety()
    check_output_integrity()
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
