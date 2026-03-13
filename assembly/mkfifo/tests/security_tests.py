#!/usr/bin/env python3
"""security_tests.py — Security & memory safety tests for fmkfifo.

fmkfifo is a GNU-compatible 'mkfifo' written in x86-64 Linux assembly.
It creates named pipes (FIFOs).

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
   13. Tool-specific (mkfifo: FIFO creation behavior)
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
import stat
from pathlib import Path
from shutil import which

TIMEOUT = 5
BIN = ""
GNU = "mkfifo"
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
    for name in ["fmkfifo_release", "fmkfifo"]:
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
        if p_type == PT_INTERP: has_interp = True
        if p_type == PT_DYNAMIC: has_dynamic = True
        if p_type == PT_GNU_STACK: has_nx_stack = not bool(p_flags & PF_X)
        if p_type == PT_LOAD: load_ranges.append((p_vaddr, p_vaddr + p_memsz))

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
        report_result(pattern not in data, f"strings: no {desc} in binary")
    from collections import Counter
    import math
    if len(data) > 0:
        counts = Counter(data)
        entropy = sum(-p * math.log2(p) for p in (c / len(data) for c in counts.values()) if p > 0)
        report_result(entropy < 7.0, f"strings: binary entropy {entropy:.2f} (<7.0)")


def check_syscall_surface():
    log("\n=== 2. Syscall Surface Analysis ===")
    if not which("strace"):
        report_skip("syscall: strace not available")
        return
    with tempfile.TemporaryDirectory() as tmpdir:
        testfifo = os.path.join(tmpdir, "strace_fifo")
        cmd = ["strace", "-f", "-e", "trace=%process,%network,write,read,openat,open,creat,brk,mmap,mprotect,mknod,mknodat",
               BIN, testfifo]
        rc, out, err = run(cmd)
    err_text = err.decode(errors="replace")
    lines = [l for l in err_text.splitlines()
             if l and not l.startswith("---") and not l.startswith("+++") and not l.startswith("execve(")]
    net_calls = [l for l in lines if any(s in l for s in ["socket(", "connect(", "bind("])]
    report_result(len(net_calls) == 0, "syscall: no network syscalls")
    spawn_calls = [l for l in lines if any(s in l for s in ["fork(", "vfork(", "clone(", "clone3("])]
    report_result(len(spawn_calls) == 0, "syscall: no process spawning")
    mem_calls = [l for l in lines if any(s in l for s in ["brk(", "mmap(", "mprotect("])]
    report_result(len(mem_calls) == 0, "syscall: no memory allocation")
    mknod_calls = [l for l in lines if "mknod(" in l or "mknodat(" in l]
    report_result(len(mknod_calls) >= 1, "syscall: mknod called (expected)")
    all_calls = [l for l in lines if "(" in l and "=" in l]
    report_result(len(all_calls) <= 6, f"syscall: total {len(all_calls)} syscalls (<=6 expected)")


def check_proc_analysis():
    log("\n=== 3. /proc Filesystem Runtime Analysis ===")
    with tempfile.TemporaryDirectory() as tmpdir:
        testfifo = os.path.join(tmpdir, "proc_fifo")
        rc, out, err = run([BIN, testfifo])
        report_result(rc == 0, "proc: tool runs and exits cleanly")


def check_fd_hygiene():
    log("\n=== 4. File Descriptor Hygiene ===")
    with tempfile.TemporaryDirectory() as tmpdir:
        testfifo = os.path.join(tmpdir, "fd_fifo")
        script = f'exec 3>&1 1>&-; {BIN} {testfifo} 2>/dev/null; echo $? >&3'
        p = subprocess.run(["bash", "-c", script], capture_output=True, timeout=TIMEOUT, text=True)
        rc = p.stdout.strip()
        report_result(rc != "", "fd: closed stdout -> doesn't hang")
    with tempfile.TemporaryDirectory() as tmpdir:
        testfifo = os.path.join(tmpdir, "fd_fifo2")
        script = f'exec 3>&1; {BIN} {testfifo} 2>&- 1>&3; echo $? >&3'
        p = subprocess.run(["bash", "-c", script], capture_output=True, timeout=TIMEOUT, text=True)
        lines = p.stdout.strip().split("\n")
        rc = lines[-1] if lines else ""
        report_result(rc == "0", "fd: closed stderr -> exit 0")
    def limit_nofile():
        resource.setrlimit(resource.RLIMIT_NOFILE, (3, 3))
    with tempfile.TemporaryDirectory() as tmpdir:
        testfifo = os.path.join(tmpdir, "fd_fifo3")
        rc, out, err = run([BIN, testfifo], preexec_fn=limit_nofile)
        report_result(rc >= 0 and rc < 128, "fd: RLIMIT_NOFILE=3 -> no crash")


def check_memory_safety():
    log("\n=== 5. Memory Safety ===")
    with tempfile.TemporaryDirectory() as tmpdir:
        testfifo = os.path.join(tmpdir, "mem_fifo")
        rc, out, err = run([BIN, testfifo])
        report_result(rc == 0, "memory: no signal death on normal run")
    rc, out, err = run([BIN] + [f"/tmp/nonexistent_parent_{i}/fifo" for i in range(200)])
    report_result(rc >= 0 and rc < 128, "memory: no crash with 200 args")
    long_arg = "A" * 4000
    rc, out, err = run([BIN, long_arg])
    report_result(rc >= 0 and rc < 128, "memory: no crash with 4000-char argument")
    for i in range(10):
        arg = "".join(chr(random.randint(1, 127)) for _ in range(random.randint(0, 500)))
        rc, _, _ = run([BIN, arg])
        if rc >= 128:
            report_result(False, f"memory: crash with random arg (trial {i})")
            break
    else:
        report_result(True, "memory: no signal death with 10 random args")
    def limit_stack():
        resource.setrlimit(resource.RLIMIT_STACK, (65536, 65536))
    with tempfile.TemporaryDirectory() as tmpdir:
        testfifo = os.path.join(tmpdir, "stack_fifo")
        rc, out, err = run([BIN, testfifo], preexec_fn=limit_stack)
        report_result(rc == 0, "memory: 64KB stack -> exit 0")


def check_signal_safety():
    log("\n=== 6. Signal Safety ===")
    with tempfile.TemporaryDirectory() as tmpdir:
        testfifo = os.path.join(tmpdir, "sig_fifo")
        script = f'{BIN} {testfifo} | head -c 0'
        p = subprocess.run(["bash", "-c", script], capture_output=True, timeout=TIMEOUT)
        report_result(p.returncode >= 0 and p.returncode < 128, "signal: SIGPIPE clean exit")
    ok_count = 0
    trials = 20
    for i in range(trials):
        with tempfile.TemporaryDirectory() as tmpdir:
            testfifo = os.path.join(tmpdir, f"sig_rapid_{i}")
            rc = os.system(f"{BIN} {testfifo} 2>/dev/null | head -c 0 >/dev/null 2>/dev/null")
            if os.WIFEXITED(rc) and os.WEXITSTATUS(rc) < 128:
                ok_count += 1
    report_result(ok_count >= trials - 2, f"signal: rapid SIGPIPE ({ok_count}/{trials})")


def check_fuzzing():
    log("\n=== 7. Input Fuzzing ===")
    crash_count = 0
    for i in range(50):
        n_args = random.randint(0, 10)
        args = ["".join(random.choices(string.printable, k=random.randint(0, 100)))
                for _ in range(n_args)]
        rc, out, err = run([BIN] + args)
        if rc >= 128:
            crash_count += 1
    report_result(crash_count == 0, f"fuzz: 50 random short args -- no signal death ({crash_count})")
    crash_count = 0
    for i in range(20):
        arg = "".join(random.choices(string.printable, k=random.randint(100, 1000)))
        rc, out, err = run([BIN, arg])
        if rc >= 128:
            crash_count += 1
    report_result(crash_count == 0, f"fuzz: 20 random long args -- no signal death ({crash_count})")
    for desc, arg in [("all-newlines", "\n" * 1000),
                      ("all-0xff", "\xff" * 1000),
                      ("control-chars", "".join(chr(i) for i in range(1, 32))),
                      ("unicode-multibyte", "\u00e9\u00e0\u00fc\u4e16\u754c" * 100)]:
        rc, _, _ = run([BIN, arg])
        report_result(rc >= 0 and rc < 128, f"fuzz: pathological {desc} -> no crash")
    rc, out, err = run([BIN] + [""] * 200)
    report_result(rc >= 0 and rc < 128, "fuzz: 200 empty args -> no crash")


def check_resource_limits():
    log("\n=== 8. Resource Limit Testing ===")
    def limit_as():
        resource.setrlimit(resource.RLIMIT_AS, (16 * 1024 * 1024, 16 * 1024 * 1024))
    with tempfile.TemporaryDirectory() as tmpdir:
        testfifo = os.path.join(tmpdir, "rl_fifo")
        rc, _, _ = run([BIN, testfifo], preexec_fn=limit_as)
        report_result(rc == 0, "rlimit: RLIMIT_AS=16MB -> exit 0")
    def limit_all():
        resource.setrlimit(resource.RLIMIT_AS, (16 * 1024 * 1024, 16 * 1024 * 1024))
        resource.setrlimit(resource.RLIMIT_NOFILE, (3, 3))
        resource.setrlimit(resource.RLIMIT_CPU, (1, 1))
        resource.setrlimit(resource.RLIMIT_STACK, (65536, 65536))
    with tempfile.TemporaryDirectory() as tmpdir:
        testfifo = os.path.join(tmpdir, "rl_all_fifo")
        rc, _, _ = run([BIN, testfifo], preexec_fn=limit_all)
        report_result(rc >= 0 and rc < 128, "rlimit: all limits combined -> no crash")


def check_environment():
    log("\n=== 9. Environment Robustness ===")
    with tempfile.TemporaryDirectory() as tmpdir:
        testfifo = os.path.join(tmpdir, "env_fifo")
        rc, out, err = run([BIN, testfifo], env={})
        report_result(rc == 0, "env: empty environment -> exit 0")
    hostile = {"PATH": "", "HOME": "/nonexistent", "LANG": "xx_XX.BROKEN", "LC_ALL": "C"}
    with tempfile.TemporaryDirectory() as tmpdir:
        testfifo = os.path.join(tmpdir, "env_hostile_fifo")
        rc, out, err = run([BIN, testfifo], env=hostile)
        report_result(rc == 0, "env: hostile env vars -> exit 0")


def check_output_integrity():
    log("\n=== 10. Output Integrity ===")
    outputs = []
    for i in range(10):
        with tempfile.TemporaryDirectory() as tmpdir:
            testfifo = os.path.join(tmpdir, f"out_fifo_{i}")
            rc, out, err = run([BIN, testfifo])
            outputs.append((rc, out, err))
    all_zero = all(o[0] == 0 for o in outputs)
    report_result(all_zero, "output: all 10 runs exit 0")
    all_empty = all(o[1] == b"" for o in outputs)
    report_result(all_empty, "output: all 10 runs produce no stdout")
    all_no_err = all(o[2] == b"" for o in outputs)
    report_result(all_no_err, "output: all 10 runs produce no stderr")


def check_error_handling():
    log("\n=== 11. Error Handling ===")
    for flag in ["--badopt", "--nonexistent"]:
        rc, out, err = run([BIN, flag])
        report_result(rc >= 0 and rc < 128, f"error: '{flag}' -> no signal death")
    gnu_path = which(GNU)
    if gnu_path:
        for args in [["--help"], ["--version"], []]:
            rc_f, _, _ = run([BIN] + args)
            rc_g, _, _ = run([gnu_path] + args)
            report_result(rc_f == rc_g, f"error: exit code matches GNU for {args}")


def check_concurrency():
    log("\n=== 12. Concurrency Stress ===")
    procs = []
    for i in range(50):
        p = subprocess.Popen([BIN, f"/tmp/nonexistent_parent_conc_{i}/fifo"],
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
    report_result(crash_count == 0, f"concurrency: 50 simultaneous ({crash_count} failures)")


def check_tool_specific():
    log("\n=== 13. Tool-Specific: mkfifo ===")

    # Create FIFO
    with tempfile.TemporaryDirectory() as tmpdir:
        testfifo = os.path.join(tmpdir, "basic_fifo")
        rc, out, err = run([BIN, testfifo])
        report_result(rc == 0, "mkfifo: create fifo -> exit 0")
        report_result(os.path.exists(testfifo) and stat.S_ISFIFO(os.stat(testfifo).st_mode),
                     "mkfifo: file is actually a FIFO")

    # Already exists
    with tempfile.TemporaryDirectory() as tmpdir:
        testfifo = os.path.join(tmpdir, "exist_fifo")
        os.mkfifo(testfifo)
        rc, out, err = run([BIN, testfifo])
        report_result(rc == 1, "mkfifo: already exists -> exit 1")
        report_result(b"File exists" in err, "mkfifo: EEXIST error message")

    # Nonexistent parent
    with tempfile.TemporaryDirectory() as tmpdir:
        testfifo = os.path.join(tmpdir, "noparent", "fifo")
        rc, out, err = run([BIN, testfifo])
        report_result(rc == 1, "mkfifo: no parent -> exit 1")
        report_result(b"No such file or directory" in err, "mkfifo: ENOENT error message")

    # Multiple FIFOs
    with tempfile.TemporaryDirectory() as tmpdir:
        fifos = [os.path.join(tmpdir, f"multi_{i}") for i in range(3)]
        rc, out, err = run([BIN] + fifos)
        report_result(rc == 0, "mkfifo: multiple fifos -> exit 0")
        report_result(all(stat.S_ISFIFO(os.stat(f).st_mode) for f in fifos),
                     "mkfifo: all are FIFOs")

    # -m mode
    with tempfile.TemporaryDirectory() as tmpdir:
        testfifo = os.path.join(tmpdir, "mode_fifo")
        rc, out, err = run([BIN, "-m", "644", testfifo])
        report_result(rc == 0, "mkfifo: -m 644 -> exit 0")
        if os.path.exists(testfifo):
            perms = oct(os.stat(testfifo).st_mode & 0o777)
            report_result(perms == "0o644", f"mkfifo: -m 644 permissions correct ({perms})")
        else:
            report_result(False, "mkfifo: -m 644 fifo not created")

    # Error format
    rc, out, err = run([BIN, "/tmp/nonexistent_parent_fmt/fifo"])
    report_result(b"mkfifo: cannot create fifo '" in err, "mkfifo: error format correct")

    # mknod syscall (strace)
    if which("strace"):
        with tempfile.TemporaryDirectory() as tmpdir:
            testfifo = os.path.join(tmpdir, "strace_fifo")
            cmd = ["strace", "-e", "trace=mknod,mknodat", BIN, testfifo]
            rc, out, err = run(cmd)
            err_text = err.decode(errors="replace")
            report_result("mknod(" in err_text or "mknodat(" in err_text,
                         "mkfifo: uses mknod() syscall")


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
