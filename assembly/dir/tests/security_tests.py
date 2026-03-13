#!/usr/bin/env python3
"""security_tests.py — Security & memory safety tests for fdir."""

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
GNU = "dir"
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
    for name in ["fdir_release", "fdir"]:
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
    rc, out, err = run([BIN, "/tmp"])
    report_result(rc == 0, "memory: normal run exit 0")
    def limit_stack():
        resource.setrlimit(resource.RLIMIT_STACK, (65536, 65536))
    rc, out, err = run([BIN, "/tmp"], preexec_fn=limit_stack)
    report_result(rc >= 0 and rc < 128, "memory: 64KB stack no crash")

def check_fuzzing():
    log("\n=== 7. Input Fuzzing ===")
    crash_count = 0
    for i in range(20):
        args = ["-" + "".join(random.choices("laA1RrSthdisC", k=random.randint(0, 5)))]
        args.append("/tmp")
        rc, out, err = run([BIN] + args)
        if rc >= 128:
            crash_count += 1
    report_result(crash_count == 0, "fuzz: 20 random flag combos no crash")

def check_output_integrity():
    log("\n=== 10. Output Integrity ===")
    with tempfile.TemporaryDirectory() as td:
        for name in ["alpha", "beta", "gamma"]:
            Path(td, name).touch()
        outputs = []
        for _ in range(5):
            rc, out, err = run([BIN, "-1", td])
            outputs.append(out)
        report_result(all(o == outputs[0] for o in outputs), "output: deterministic")
        names = sorted(outputs[0].decode().strip().split("\n"))
        report_result(names == ["alpha", "beta", "gamma"], "output: correct names")

def check_tool_specific():
    log("\n=== 13. Tool-Specific: dir ===")
    with tempfile.TemporaryDirectory() as td:
        for name in ["aaa", "bbb", ".hidden"]:
            Path(td, name).touch()
        # dir default is multi-column, but -1 gives one per line
        rc, out, _ = run([BIN, "-1", td])
        names = out.decode().strip().split("\n")
        report_result("aaa" in names, "dir: -1 lists files")
        report_result(".hidden" not in names, "dir: hidden excluded by default")
        rc, out, _ = run([BIN, "-1a", td])
        names = out.decode().strip().split("\n")
        report_result(".hidden" in names, "dir: -a shows hidden")

def run_tests():
    find_binary()
    check_elf_properties()
    check_memory_safety()
    check_fuzzing()
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
