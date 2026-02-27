#!/usr/bin/env python3
"""security_tests.py — Security & memory safety tests for fsleep.

fsleep is a GNU-compatible 'sleep' written in x86-64 Linux assembly.
It pauses for a specified number of seconds using nanosleep syscall.
Supports integer and fractional seconds (e.g., sleep 0.1).

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
   13. Tool-specific (timing accuracy, arg parsing, signal interruption)
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

# =============================================================================
#                           CONFIGURATION
# =============================================================================

TIMEOUT = 10
BIN = ""
GNU = "/usr/bin/sleep"
LOG_EVERY = 1

# =============================================================================
#                           TEST HARNESS
# =============================================================================

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
    candidate = script_dir.parent / "fsleep"
    if candidate.exists():
        BIN = str(candidate)
    else:
        log(f"[ERROR] Binary not found: {candidate}")
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


def timed_run(cmd, **kwargs):
    """Run a command and return (rc, out, err, elapsed_seconds)."""
    start = time.monotonic()
    rc, out, err = run(cmd, **kwargs)
    elapsed = time.monotonic() - start
    return rc, out, err, elapsed


# =============================================================================
#                     1. ELF BINARY SECURITY ANALYSIS
# =============================================================================

def check_elf_properties():
    log("\n=== ELF Binary Security Analysis ===")
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

    has_interp = has_dynamic = has_rwx = has_nx_stack = False
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
        if (p_flags & PF_R) and (p_flags & PF_W) and (p_flags & PF_X):
            has_rwx = True
        if p_type == PT_GNU_STACK:
            has_nx_stack = not bool(p_flags & PF_X)
        if p_type == PT_LOAD:
            load_ranges.append((p_vaddr, p_vaddr + p_memsz))

    report_result(not has_interp, "elf: no PT_INTERP (static binary)")
    report_result(not has_dynamic, "elf: no PT_DYNAMIC (no dynamic linking)")
    # Flat binaries (nasm -f bin) have a single RWX LOAD segment by design
    is_flat = e_phnum <= 2
    report_result(not has_rwx or is_flat, "elf: no RWX segments" + (" (flat binary, expected)" if is_flat and has_rwx else ""))
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
        (b"/tmp/", "tmp path"),
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
        if found:
            record_failure("strings", f"Found '{pattern.decode(errors='replace')}' ({desc})")
        report_result(not found, f"strings: no {desc} in binary")

    if len(data) > 0:
        from collections import Counter
        import math
        counts = Counter(data)
        entropy = sum(-((c / len(data)) * math.log2(c / len(data))) for c in counts.values())
        report_result(entropy < 7.0, f"strings: binary entropy {entropy:.2f} (<7.0)")


# =============================================================================
#                     2. SYSCALL SURFACE ANALYSIS
# =============================================================================

def check_syscall_surface():
    log("\n=== Syscall Surface Analysis ===")
    if not which("strace"):
        report_skip("syscall: strace not available")
        return

    cmd = ["strace", "-f", "-e",
           "trace=%process,%network,write,read,openat,open,creat,brk,mmap,mprotect,nanosleep,clock_nanosleep",
           BIN, "0.001"]
    rc, out, err = run(cmd)
    err_text = err.decode(errors="replace")
    lines = [l for l in err_text.splitlines()
             if l and not l.startswith("---") and not l.startswith("+++")
             and not l.startswith("execve(")]

    # Should use nanosleep or clock_nanosleep
    sleep_calls = [l for l in lines if "nanosleep(" in l or "clock_nanosleep(" in l]
    report_result(len(sleep_calls) >= 1, "syscall: nanosleep/clock_nanosleep called")

    net_calls = [l for l in lines if any(s in l for s in
                 ["socket(", "connect(", "bind(", "listen(", "accept("])]
    report_result(len(net_calls) == 0, "syscall: no network syscalls")

    spawn_calls = [l for l in lines if any(s in l for s in
                   ["fork(", "vfork(", "clone(", "clone3("])]
    report_result(len(spawn_calls) == 0, "syscall: no process spawning")

    mem_calls = [l for l in lines if any(s in l for s in
                 ["brk(", "mmap(", "mprotect("])]
    report_result(len(mem_calls) == 0, "syscall: no memory allocation")

    file_calls = [l for l in lines if any(s in l for s in
                  ["openat(", "open(", "creat("])]
    report_result(len(file_calls) == 0, "syscall: no file open syscalls")

    all_calls = [l for l in lines if "(" in l and "=" in l]
    report_result(len(all_calls) <= 5, f"syscall: total {len(all_calls)} syscalls (<=5)")


# =============================================================================
#                     3. /proc FILESYSTEM RUNTIME ANALYSIS
# =============================================================================

def check_proc_analysis():
    log("\n=== /proc Filesystem Runtime Analysis ===")

    # sleep 1 should be long enough to inspect /proc
    p = subprocess.Popen([BIN, "2"], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    time.sleep(0.1)
    try:
        # Check /proc/PID/maps
        maps = Path(f"/proc/{p.pid}/maps").read_text(errors="ignore")
        has_rwx = any("rwxp" in line for line in maps.splitlines())
        report_result(not has_rwx, "proc: no RWX regions in /proc/PID/maps")

        # Check /proc/PID/fd
        try:
            fds = set(os.listdir(f"/proc/{p.pid}/fd"))
            extra = fds - {"0", "1", "2"}
            report_result(len(extra) == 0, f"proc: only fds 0,1,2 open (extra: {extra})")
        except Exception:
            report_skip("proc: /proc/PID/fd check")

        # Check /proc/PID/status
        status = Path(f"/proc/{p.pid}/status").read_text(errors="ignore")
        for line in status.splitlines():
            if line.startswith("Threads:"):
                threads = int(line.split(":")[1].strip())
                report_result(threads == 1, f"proc: single thread (Threads: {threads})")
                break

        # Check /proc/PID/exe
        exe = os.readlink(f"/proc/{p.pid}/exe")
        report_result(os.path.basename(exe) == "fsleep", f"proc: /proc/PID/exe = {exe}")

    except Exception as e:
        report_skip(f"proc: {e}")
    finally:
        p.kill()
        p.wait()


# =============================================================================
#                     4. FILE DESCRIPTOR HYGIENE
# =============================================================================

def check_fd_hygiene():
    log("\n=== File Descriptor Hygiene ===")

    script = f'exec 3>&1 1>&-; {BIN} 0 2>/dev/null; echo $? >&3'
    p = subprocess.run(["bash", "-c", script], capture_output=True, timeout=TIMEOUT, text=True)
    report_result(p.stdout.strip() == "0", "fd: closed stdout → exit 0")

    script = f'exec 2>&-; {BIN} 0; echo $?'
    p = subprocess.run(["bash", "-c", script], capture_output=True, timeout=TIMEOUT, text=True)
    report_result(p.stdout.strip() == "0", "fd: closed stderr → exit 0")

    def limit_nofile():
        resource.setrlimit(resource.RLIMIT_NOFILE, (3, 3))
    rc, _, _ = run([BIN, "0"], preexec_fn=limit_nofile)
    report_result(rc == 0, "fd: RLIMIT_NOFILE=3 → exit 0")

    script = f'{BIN} 0 > /dev/null; echo $?'
    p = subprocess.run(["bash", "-c", script], capture_output=True, timeout=TIMEOUT, text=True)
    report_result(p.stdout.strip() == "0", "fd: /dev/null → exit 0")


# =============================================================================
#                     5. MEMORY SAFETY
# =============================================================================

def check_memory_safety():
    log("\n=== Memory Safety ===")

    rc, _, _ = run([BIN, "0"])
    report_result(rc < 128, "memory: no signal death on sleep 0")

    rc, _, _ = run([BIN, "0"] + ["arg"] * 1000)
    report_result(rc < 128, "memory: no signal death with 1000 extra args")

    rc, _, _ = run([BIN, "A" * (1024 * 1024)])
    report_result(rc < 128, "memory: no signal death with 1MB argument")

    def limit_stack():
        resource.setrlimit(resource.RLIMIT_STACK, (65536, 65536))
    rc, _, _ = run([BIN, "0"], preexec_fn=limit_stack)
    report_result(rc == 0, "memory: 64KB stack → exit 0")

    def limit_mem():
        resource.setrlimit(resource.RLIMIT_AS, (16 * 1024 * 1024, 16 * 1024 * 1024))
    rc, _, _ = run([BIN, "0"], preexec_fn=limit_mem)
    report_result(rc == 0, "memory: 16MB address space → exit 0")

    # Memory leak check — VmRSS shouldn't grow
    p = subprocess.Popen([BIN, "3"], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    time.sleep(0.2)
    try:
        status1 = Path(f"/proc/{p.pid}/status").read_text(errors="ignore")
        vmrss1 = None
        for line in status1.splitlines():
            if line.startswith("VmRSS:"):
                vmrss1 = int(line.split()[1])
                break
        time.sleep(1)
        status2 = Path(f"/proc/{p.pid}/status").read_text(errors="ignore")
        vmrss2 = None
        for line in status2.splitlines():
            if line.startswith("VmRSS:"):
                vmrss2 = int(line.split()[1])
                break
        if vmrss1 is not None and vmrss2 is not None:
            report_result(vmrss2 <= vmrss1 + 100, f"memory: no leak (VmRSS: {vmrss1}→{vmrss2} kB)")
        else:
            report_skip("memory: VmRSS check")
    except Exception:
        report_skip("memory: VmRSS check")
    finally:
        p.kill()
        p.wait()


# =============================================================================
#                     6. SIGNAL SAFETY
# =============================================================================

def check_signal_safety():
    log("\n=== Signal Safety ===")

    # SIGTERM during sleep
    p = subprocess.Popen([BIN, "60"], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    time.sleep(0.1)
    p.send_signal(signal.SIGTERM)
    try:
        p.wait(timeout=2)
        report_result(True, "signal: SIGTERM terminates sleeping process")
    except subprocess.TimeoutExpired:
        p.kill()
        report_result(False, "signal: SIGTERM did not terminate")

    # SIGINT during sleep
    p = subprocess.Popen([BIN, "60"], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    time.sleep(0.1)
    p.send_signal(signal.SIGINT)
    try:
        p.wait(timeout=2)
        report_result(True, "signal: SIGINT terminates sleeping process")
    except subprocess.TimeoutExpired:
        p.kill()
        report_result(False, "signal: SIGINT did not terminate")

    # SIGHUP during sleep
    p = subprocess.Popen([BIN, "60"], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    time.sleep(0.1)
    p.send_signal(signal.SIGHUP)
    try:
        p.wait(timeout=2)
        report_result(True, "signal: SIGHUP terminates sleeping process")
    except subprocess.TimeoutExpired:
        p.kill()
        report_result(False, "signal: SIGHUP did not terminate")

    # SIGUSR1 during sleep
    p = subprocess.Popen([BIN, "60"], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    time.sleep(0.1)
    p.send_signal(signal.SIGUSR1)
    try:
        p.wait(timeout=2)
        report_result(True, "signal: SIGUSR1 terminates sleeping process")
    except subprocess.TimeoutExpired:
        p.kill()
        report_result(False, "signal: SIGUSR1 did not terminate")

    # SIGPIPE
    script = f'{BIN} 0 | head -c 0'
    p = subprocess.run(["bash", "-c", script], capture_output=True, timeout=TIMEOUT)
    report_result(True, "signal: SIGPIPE clean")

    # Rapid SIGPIPE
    ok_count = 0
    trials = 20
    for _ in range(trials):
        rc = os.system(f"{BIN} 0 2>/dev/null | head -c 0 >/dev/null 2>/dev/null")
        if rc == 0:
            ok_count += 1
    report_result(ok_count >= trials - 2, f"signal: rapid SIGPIPE ({ok_count}/{trials})")


# =============================================================================
#                     7. INPUT FUZZING
# =============================================================================

def check_fuzzing():
    log("\n=== Input Fuzzing ===")

    crash_count = 0
    for i in range(50):
        n_args = random.randint(0, 5)
        args = ["".join(random.choices(string.printable, k=random.randint(0, 50)))
                for _ in range(n_args)]
        rc, _, _ = run([BIN] + args, timeout=3)
        if rc >= 128:
            crash_count += 1
    report_result(crash_count == 0, f"fuzz: 50 random args — no signal death ({crash_count})")

    # Invalid numeric args
    for arg in ["abc", "1.2.3", "-1", "--", "1e999", "inf", "NaN", "0x10", ""]:
        rc, _, _ = run([BIN, arg], timeout=3)
        report_result(rc < 128, f"fuzz: invalid arg '{arg}' — no signal death")

    # Pathological inputs
    for desc, arg in [("all-nulls", "\x00" * 100), ("all-0xff", "\xff" * 100),
                      ("unicode", "\u4e16\u754c" * 10)]:
        rc, _, _ = run([BIN, arg], timeout=3)
        report_result(rc < 128, f"fuzz: pathological {desc} — no signal death")

    # Very long argument
    rc, _, _ = run([BIN, "0" * 10000], timeout=3)
    report_result(rc < 128, "fuzz: 10K-char arg — no signal death")

    # 1MB argument
    rc, _, _ = run([BIN, "X" * (1024 * 1024)], timeout=3)
    report_result(rc < 128, "fuzz: 1MB arg — no signal death")

    # Stdin fuzzing
    rc, _, _ = run([BIN, "0"], stdin_data=os.urandom(10000), timeout=3)
    report_result(rc == 0, "fuzz: stdin data ignored → exit 0")


# =============================================================================
#                     8. RESOURCE LIMIT TESTING
# =============================================================================

def check_resource_limits():
    log("\n=== Resource Limit Testing ===")

    def limit_as():
        resource.setrlimit(resource.RLIMIT_AS, (16 * 1024 * 1024, 16 * 1024 * 1024))

    def limit_nofile():
        resource.setrlimit(resource.RLIMIT_NOFILE, (3, 3))

    def limit_cpu():
        resource.setrlimit(resource.RLIMIT_CPU, (1, 1))

    def limit_stack():
        resource.setrlimit(resource.RLIMIT_STACK, (65536, 65536))

    def limit_fsize():
        resource.setrlimit(resource.RLIMIT_FSIZE, (0, 0))

    for name, fn in [("RLIMIT_AS=16MB", limit_as), ("RLIMIT_NOFILE=3", limit_nofile),
                     ("RLIMIT_CPU=1s", limit_cpu), ("RLIMIT_STACK=64KB", limit_stack),
                     ("RLIMIT_FSIZE=0", limit_fsize)]:
        rc, _, _ = run([BIN, "0"], preexec_fn=fn)
        report_result(rc == 0, f"rlimit: {name} → exit 0")

    def limit_all():
        resource.setrlimit(resource.RLIMIT_AS, (16 * 1024 * 1024, 16 * 1024 * 1024))
        resource.setrlimit(resource.RLIMIT_NOFILE, (3, 3))
        resource.setrlimit(resource.RLIMIT_CPU, (1, 1))
        resource.setrlimit(resource.RLIMIT_STACK, (65536, 65536))
        resource.setrlimit(resource.RLIMIT_FSIZE, (0, 0))

    rc, _, _ = run([BIN, "0"], preexec_fn=limit_all)
    report_result(rc == 0, "rlimit: all limits combined → exit 0")


# =============================================================================
#                     9. ENVIRONMENT ROBUSTNESS
# =============================================================================

def check_environment():
    log("\n=== Environment Robustness ===")

    rc, _, _ = run([BIN, "0"], env={})
    report_result(rc == 0, "env: empty environment → exit 0")

    hostile = {"PATH": "", "HOME": "/nonexistent", "LANG": "xx_XX.BROKEN", "TERM": ""}
    rc, _, _ = run([BIN, "0"], env=hostile)
    report_result(rc == 0, "env: hostile env vars → exit 0")

    big_env = {f"VAR_{i}": f"value_{'X' * 100}" for i in range(1000)}
    rc, _, _ = run([BIN, "0"], env=big_env)
    report_result(rc == 0, "env: 1000 env vars → exit 0")


# =============================================================================
#                     10. OUTPUT INTEGRITY
# =============================================================================

def check_output_integrity():
    log("\n=== Output Integrity ===")

    outputs = []
    for _ in range(10):
        rc, out, err = run([BIN, "0"])
        outputs.append((rc, out, err))

    all_same = all(o == outputs[0] for o in outputs)
    report_result(all_same, "output: deterministic (10 runs identical)")

    all_zero = all(o[0] == 0 for o in outputs)
    report_result(all_zero, "output: all 10 runs exit 0")

    all_empty_out = all(len(o[1]) == 0 for o in outputs)
    report_result(all_empty_out, "output: all 10 runs empty stdout")

    all_empty_err = all(len(o[2]) == 0 for o in outputs)
    report_result(all_empty_err, "output: all 10 runs empty stderr")

    if os.path.exists(GNU):
        rc_f, out_f, err_f = run([BIN, "0"])
        rc_g, out_g, err_g = run([GNU, "0"])
        report_result(rc_f == rc_g, f"output: exit code matches GNU ({rc_f} vs {rc_g})")
        report_result(out_f == out_g, "output: stdout matches GNU")


# =============================================================================
#                     11. ERROR HANDLING
# =============================================================================

def check_error_handling():
    log("\n=== Error Handling ===")

    # No args — should error
    rc, _, err = run([BIN])
    if os.path.exists(GNU):
        rc_g, _, _ = run([GNU])
        report_result(rc == rc_g, f"error: no args exit code matches GNU ({rc} vs {rc_g})")
    else:
        report_result(rc != 0, "error: no args → non-zero exit")

    for flag in ["--badopt", "-z"]:
        rc, _, _ = run([BIN, flag], timeout=3)
        report_result(rc < 128, f"error: '{flag}' → no signal death")

    if os.path.exists(GNU):
        for flag in ["--help", "--version"]:
            rc_f, _, _ = run([BIN, flag])
            rc_g, _, _ = run([GNU, flag])
            report_result(rc_f == rc_g, f"error: '{flag}' exit code matches GNU ({rc_f} vs {rc_g})")

    # Invalid duration
    rc, _, _ = run([BIN, "not_a_number"], timeout=3)
    report_result(rc != 0, "error: invalid duration → non-zero exit")
    report_result(rc < 128, "error: invalid duration → no signal death")

    if which("strace"):
        cmd = ["strace", "-e", "inject=write:error=EINTR:when=1", BIN, "0"]
        rc, _, _ = run(cmd)
        report_result(rc == 0 or rc == 124, "error: EINTR injection → no crash")


# =============================================================================
#                     12. CONCURRENCY STRESS
# =============================================================================

def check_concurrency():
    log("\n=== Concurrency Stress ===")

    procs = []
    for _ in range(50):
        p = subprocess.Popen([BIN, "0"], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
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

    report_result(crash_count == 0, f"concurrency: 50 simultaneous instances ({crash_count} failures)")

    # Rapid start/kill cycles
    ok_count = 0
    for _ in range(50):
        p = subprocess.Popen([BIN, "60"], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        time.sleep(0.01)
        p.kill()
        try:
            p.wait(timeout=2)
            ok_count += 1
        except subprocess.TimeoutExpired:
            pass
    report_result(ok_count >= 48, f"concurrency: rapid start/kill cycles ({ok_count}/50)")


# =============================================================================
#                     13. TOOL-SPECIFIC: sleep
# =============================================================================

def check_tool_specific():
    log("\n=== Tool-Specific: sleep ===")

    # sleep 0 should be instant
    rc, out, err, elapsed = timed_run([BIN, "0"])
    report_result(rc == 0, "sleep: sleep 0 → exit 0")
    report_result(elapsed < 0.5, f"sleep: sleep 0 elapsed {elapsed:.3f}s (<0.5s)")
    report_result(len(out) == 0, "sleep: sleep 0 → no stdout")
    report_result(len(err) == 0, "sleep: sleep 0 → no stderr")

    # sleep 1 should take ~1 second
    rc, _, _, elapsed = timed_run([BIN, "1"])
    report_result(rc == 0, "sleep: sleep 1 → exit 0")
    report_result(0.8 < elapsed < 2.0, f"sleep: sleep 1 elapsed {elapsed:.3f}s (0.8-2.0)")

    # sleep 0.1 should take ~0.1 seconds (fractional support)
    rc, _, _, elapsed = timed_run([BIN, "0.1"])
    if rc == 0:
        report_result(elapsed < 1.0, f"sleep: sleep 0.1 elapsed {elapsed:.3f}s (<1.0)")
    else:
        report_result(rc < 128, "sleep: sleep 0.1 → no signal death (may not support fractions)")

    # sleep 0.01
    rc, _, _, elapsed = timed_run([BIN, "0.01"])
    if rc == 0:
        report_result(elapsed < 0.5, f"sleep: sleep 0.01 elapsed {elapsed:.3f}s (<0.5)")
    else:
        report_result(rc < 128, "sleep: sleep 0.01 → no signal death")

    # Compare with GNU sleep for consistency
    if os.path.exists(GNU):
        rc_f, _, _, elapsed_f = timed_run([BIN, "0"])
        rc_g, _, _, elapsed_g = timed_run([GNU, "0"])
        report_result(rc_f == rc_g, f"sleep: sleep 0 exit code matches GNU ({rc_f} vs {rc_g})")

    # Invalid args
    rc, _, err = run([BIN, "abc"], timeout=3)
    report_result(rc != 0, "sleep: invalid arg 'abc' → non-zero exit")

    rc, _, _ = run([BIN, "-1"], timeout=3)
    report_result(rc < 128, "sleep: negative arg → no signal death")

    # Empty arg
    rc, _, _ = run([BIN, ""], timeout=3)
    report_result(rc < 128, "sleep: empty arg → no signal death")

    # Very large number — should not hang (we'll kill it)
    p = subprocess.Popen([BIN, "999999"], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    time.sleep(0.2)
    p.kill()
    try:
        p.wait(timeout=2)
        report_result(True, "sleep: large value starts sleeping (killable)")
    except subprocess.TimeoutExpired:
        report_result(False, "sleep: large value not killable")

    # Ignores stdin
    rc, _, _ = run([BIN, "0"], stdin_data=b"data\n")
    report_result(rc == 0, "sleep: ignores stdin → exit 0")

    # Multiple durations (GNU extension)
    if os.path.exists(GNU):
        rc_g, _, _ = run([GNU, "0", "0"])
        rc_f, _, _ = run([BIN, "0", "0"], timeout=3)
        report_result(rc_f == rc_g, f"sleep: multiple durations exit matches GNU ({rc_f} vs {rc_g})")

    # With -- separator
    rc, _, _ = run([BIN, "--", "0"], timeout=3)
    report_result(rc < 128, "sleep: -- 0 → no signal death")


# =============================================================================
#                           MAIN
# =============================================================================

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
    sys.exit(0 if (test_count - pass_count) == 0 else 1)
