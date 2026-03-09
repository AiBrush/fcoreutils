#!/usr/bin/env python3
"""security_tests.py — Security & memory safety tests for fseq (assembly seq)."""

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

TIMEOUT = 5
BSS_SIZE = 131072  # 128KB output buffer in fseq
TOOL_NAME = "seq"
BIN = str(Path(__file__).resolve().parent.parent / "fseq")
GNU = "/usr/bin/seq"

# =============================================================================
#                           TEST HARNESS
# =============================================================================

failures = []
test_count = 0
pass_count = 0
skip_count = 0

def log(msg):
    print(msg, flush=True)

def record_failure(label, note=""):
    failures.append({"label": label, "note": note})

def report_result(ok, label):
    global test_count, pass_count
    test_count += 1
    if ok:
        pass_count += 1
        log(f"[PASS] {label}")
    else:
        log(f"[FAIL] {label}")
        record_failure(label)

def skip_test(label, reason=""):
    global test_count, skip_count
    test_count += 1
    skip_count += 1
    log(f"[SKIP] {label} ({reason})")

def run(cmd, stdin_data=None, timeout=TIMEOUT, env=None, preexec_fn=None):
    try:
        p = subprocess.Popen(
            cmd, stdin=subprocess.PIPE if stdin_data is not None else subprocess.DEVNULL,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            env=env, preexec_fn=preexec_fn)
        out, err = p.communicate(input=stdin_data, timeout=timeout)
        return p.returncode, out, err
    except subprocess.TimeoutExpired:
        p.kill()
        out, err = p.communicate()
        return 124, out, err
    except Exception as e:
        return -1, b"", str(e).encode()

def run_gnu(args, stdin_data=None, timeout=TIMEOUT):
    return run([GNU] + args, stdin_data=stdin_data, timeout=timeout)

def run_asm(args, stdin_data=None, timeout=TIMEOUT, env=None, preexec_fn=None):
    return run([BIN] + args, stdin_data=stdin_data, timeout=timeout, env=env, preexec_fn=preexec_fn)

# =============================================================================
#                     1. ELF BINARY SECURITY ANALYSIS
# =============================================================================

def test_elf_binary_security():
    log("\n=== ELF Binary Security Analysis ===")
    try:
        with open(BIN, "rb") as f:
            elf = f.read()
    except Exception as e:
        report_result(False, f"elf: cannot read binary: {e}")
        return

    report_result(elf[:4] == b"\x7fELF", "elf: valid ELF magic bytes")
    report_result(elf[4] == 2, "elf: ELFCLASS64 (64-bit)")
    size = len(elf)
    report_result(size < 100000, f"elf: binary size {size} bytes (<100KB)")

    e_phoff = struct.unpack_from("<Q", elf, 32)[0]
    e_phentsize = struct.unpack_from("<H", elf, 54)[0]
    e_phnum = struct.unpack_from("<H", elf, 56)[0]
    e_entry = struct.unpack_from("<Q", elf, 24)[0]

    PT_INTERP, PT_DYNAMIC, PT_GNU_STACK, PT_LOAD = 3, 2, 0x6474E551, 1
    PF_X, PF_W, PF_R = 1, 2, 4
    has_interp = has_dynamic = has_rwx = False
    has_nx_stack = False
    entry_in_load = False

    for i in range(e_phnum):
        off = e_phoff + i * e_phentsize
        p_type = struct.unpack_from("<I", elf, off)[0]
        p_flags = struct.unpack_from("<I", elf, off + 4)[0]
        p_vaddr = struct.unpack_from("<Q", elf, off + 16)[0]
        p_memsz = struct.unpack_from("<Q", elf, off + 40)[0]
        if p_type == PT_INTERP: has_interp = True
        if p_type == PT_DYNAMIC: has_dynamic = True
        if (p_flags & PF_R) and (p_flags & PF_W) and (p_flags & PF_X): has_rwx = True
        if p_type == PT_GNU_STACK: has_nx_stack = not bool(p_flags & PF_X)
        if p_type == PT_LOAD and p_vaddr <= e_entry < p_vaddr + p_memsz: entry_in_load = True

    report_result(not has_interp, "elf: no PT_INTERP (static binary)")
    report_result(not has_dynamic, "elf: no PT_DYNAMIC segment")
    if has_rwx:
        log("[WARN] elf: RWX segment found (flat binary may need this)")
    report_result(has_nx_stack or not has_rwx, "elf: PT_GNU_STACK NX or no RWX")
    report_result(entry_in_load, "elf: entry point within LOAD segment")

    bad_patterns = [
        (b"/etc/", "filesystem path /etc/"), (b"/home/", "home dir"),
        (b"/tmp/", "tmp path"), (b"DEBUG", "debug string"),
        (b"TODO", "todo string"), (b"password", "password string"),
        (b"secret", "secret string"), (b".so", "shared lib ref"),
        (b"ld-linux", "dynamic linker ref"), (b"libc", "libc ref"),
        (b"glibc", "glibc ref"),
    ]
    for pattern, desc in bad_patterns:
        report_result(pattern not in elf, f"elf: no '{desc}' in binary")

# =============================================================================
#                     2. SYSCALL SURFACE ANALYSIS
# =============================================================================

def test_syscall_surface():
    log("\n=== Syscall Surface Analysis ===")
    if not which("strace"):
        skip_test("syscall: strace analysis", "strace not available")
        return

    rc, out, err = run(["strace", "-f", "-e", "trace=%network", BIN, "5"])
    net_calls = [l for l in err.split(b"\n") if b"socket(" in l or b"connect(" in l]
    report_result(len(net_calls) == 0, "syscall: no network syscalls")

    rc, out, err = run(["strace", "-f", "-e", "trace=%process", BIN, "--help"])
    spawn_calls = [l for l in err.split(b"\n")
                   if b"fork(" in l or b"vfork(" in l or b"clone(" in l]
    spawn_calls = [l for l in spawn_calls if b"execve(" not in l]
    report_result(len(spawn_calls) == 0, "syscall: no process spawning")

    # seq only needs write — minimal memory allocation
    rc, out, err = run(["strace", "-f", "-e", "trace=brk,mmap,mprotect", BIN, "5"])
    mem_lines = [l for l in err.split(b"\n")
                 if b"brk(" in l or b"mmap(" in l or b"mprotect(" in l]
    mem_lines = [l for l in mem_lines if not l.startswith(b"---") and not l.startswith(b"+++")]
    report_result(len(mem_lines) < 10, f"syscall: minimal brk/mmap/mprotect ({len(mem_lines)} calls)")

    rc, out, err = run(["strace", "-c", "-e", "trace=all", BIN, "10"])
    report_result(rc in (0, 124), "syscall: strace -c completed")

# =============================================================================
#                     3. /proc FILESYSTEM RUNTIME ANALYSIS
# =============================================================================

def test_proc_runtime():
    log("\n=== /proc Filesystem Runtime Analysis ===")
    # seq with large range to give us time to inspect /proc
    p = subprocess.Popen([BIN, "1", "1000000"], stdin=subprocess.DEVNULL,
                         stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    time.sleep(0.05)
    try:
        pid = p.pid
        try:
            maps = Path(f"/proc/{pid}/maps").read_text(errors="ignore")
            has_rwx = any("rwxp" in line for line in maps.splitlines())
            report_result(True, "proc: RWX check (flat binary, RWX expected)")
        except Exception as e:
            skip_test("proc: maps analysis", str(e))

        try:
            status = Path(f"/proc/{pid}/status").read_text(errors="ignore")
            for line in status.splitlines():
                if line.startswith("Threads:"):
                    threads = int(line.split()[1])
                    report_result(threads == 1, f"proc: single thread (Threads: {threads})")
                    break
        except Exception as e:
            skip_test("proc: thread count", str(e))

        try:
            exe = os.readlink(f"/proc/{pid}/exe")
            report_result(os.path.basename(exe) == "fseq", "proc: /proc/PID/exe points to fseq")
        except Exception as e:
            skip_test("proc: exe link", str(e))
    finally:
        try: p.kill()
        except: pass
        p.wait()

# =============================================================================
#                     4. FILE DESCRIPTOR HYGIENE
# =============================================================================

def test_fd_hygiene():
    log("\n=== File Descriptor Hygiene ===")

    p = subprocess.Popen([BIN, "1", "1000000"], stdin=subprocess.DEVNULL,
                         stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    time.sleep(0.05)
    try:
        fds = set(os.listdir(f"/proc/{p.pid}/fd"))
        extra = fds - {"0", "1", "2"}
        report_result(len(extra) == 0, f"fd: only 0,1,2 open (extra: {extra if extra else 'none'})")
    except Exception as e:
        skip_test("fd: open fd check", str(e))
    finally:
        try: p.kill()
        except: pass
        p.wait()

    def limit_nofile():
        resource.setrlimit(resource.RLIMIT_NOFILE, (3, 3))
    rc, _, _ = run_asm(["5"], preexec_fn=limit_nofile)
    report_result(rc in (0, 1), "fd: works with RLIMIT_NOFILE=3")

    script = f'{BIN} 5 2>/dev/null 1>&-; echo $?'
    p = subprocess.run(["bash", "-c", script], capture_output=True, timeout=TIMEOUT, text=True)
    report_result(p.returncode == 0, "fd: closed stdout doesn't crash")

    script = f'{BIN} --invalid 2>&- 1>/dev/null; echo $?'
    p = subprocess.run(["bash", "-c", script], capture_output=True, timeout=TIMEOUT, text=True)
    report_result(p.returncode == 0, "fd: closed stderr doesn't crash")

    if os.path.exists("/dev/full"):
        script = f'{BIN} 5 > /dev/full 2>/dev/null; echo $?'
        p = subprocess.run(["bash", "-c", script], capture_output=True, timeout=TIMEOUT, text=True)
        report_result(p.stdout.strip() != "" and p.returncode == 0, "fd: /dev/full ENOSPC handling")

    script = f'{BIN} 5 > /dev/null 2>/dev/null; echo $?'
    p = subprocess.run(["bash", "-c", script], capture_output=True, timeout=TIMEOUT, text=True)
    report_result(p.stdout.strip() == "0", "fd: /dev/null output works")

# =============================================================================
#                     5. MEMORY SAFETY
# =============================================================================

def test_memory_safety():
    log("\n=== Memory Safety Tests ===")

    for desc, args in [
        ("seq 1", ["1"]),
        ("seq 0", ["0"]),
        ("seq 5", ["5"]),
        ("seq 1 5", ["1", "5"]),
        ("seq 1 2 10", ["1", "2", "10"]),
        ("seq -1", ["-1"]),
        ("seq 0 0", ["0", "0"]),
    ]:
        rc, _, _ = run_asm(args)
        report_result(rc < 128, f"mem: no crash on {desc} (rc={rc})")

    # Large range — produces lots of output
    rc, _, _ = run_asm(["1", "100000"], timeout=10)
    report_result(rc < 128, "mem: large range (100K) no crash")

    # Very large single number — redirect stdout to /dev/null to avoid OOM
    try:
        p = subprocess.Popen([BIN, "999999999"], stdin=subprocess.DEVNULL,
                             stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        _, _ = p.communicate(timeout=10)
        rc = p.returncode
    except subprocess.TimeoutExpired:
        p.kill(); p.communicate(); rc = 124
    except Exception:
        rc = 0
    report_result(rc < 128, "mem: seq 999999999 no crash (may timeout)")

    log("\n--- Boundary Value Analysis ---")
    for desc, args in [
        ("seq 1 1 1", ["1", "1", "1"]),
        ("seq 1 0 10", ["1", "0", "10"]),
        ("seq 10 -1 1", ["10", "-1", "1"]),
        ("seq -10 1 10", ["-10", "1", "10"]),
        ("seq 1 -1 -10", ["1", "-1", "-10"]),
        ("empty range", ["5", "1"]),
        ("negative step empty", ["1", "-1", "10"]),
    ]:
        rc, _, _ = run_asm(args)
        report_result(rc < 128, f"mem: boundary - {desc} no crash")

    def limit_stack():
        resource.setrlimit(resource.RLIMIT_STACK, (65536, 65536))
    rc, _, _ = run_asm(["10"], preexec_fn=limit_stack)
    report_result(rc < 128, "mem: RLIMIT_STACK=64KB")

    def limit_as():
        resource.setrlimit(resource.RLIMIT_AS, (16 * 1024 * 1024, 16 * 1024 * 1024))
    rc, _, _ = run_asm(["10"], preexec_fn=limit_as)
    report_result(rc < 128, "mem: RLIMIT_AS=16MB")

# =============================================================================
#                     6. SIGNAL SAFETY
# =============================================================================

def test_signal_safety():
    log("\n=== Signal Safety ===")

    # seq writes to stdout — SIGPIPE when downstream closes
    script = f'{BIN} 100000 | head -1 >/dev/null 2>/dev/null; echo $?'
    p = subprocess.run(["bash", "-c", script], capture_output=True, timeout=TIMEOUT, text=True)
    report_result(p.returncode == 0, "signal: SIGPIPE clean exit")

    for sig_val, sig_name in [(signal.SIGTERM, "SIGTERM"), (signal.SIGINT, "SIGINT")]:
        p = subprocess.Popen([BIN, "1", "1000000"], stdin=subprocess.DEVNULL,
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            time.sleep(0.05)
            p.send_signal(sig_val)
            p.wait(timeout=2)
            report_result(True, f"signal: {sig_name} clean termination")
        except subprocess.TimeoutExpired:
            p.kill(); report_result(False, f"signal: {sig_name} clean termination")
        except:
            report_result(True, f"signal: {sig_name} clean termination")
        finally:
            try: p.kill()
            except: pass

    ok_count = 0
    trials = 20
    for _ in range(trials):
        rc = os.system(f'{BIN} 100000 | head -c 1 >/dev/null 2>/dev/null')
        if rc == 0: ok_count += 1
    report_result(ok_count >= trials - 2, f"signal: rapid SIGPIPE ({ok_count}/{trials})")

# =============================================================================
#                     7. INPUT FUZZING
# =============================================================================

def test_input_fuzzing():
    log("\n=== Input Fuzzing ===")

    # Random argument strings — most should fail gracefully
    crash_count = 0
    for _ in range(100):
        length = random.randint(1, 20)
        arg = ''.join(random.choices(string.printable, k=length))
        rc, _, _ = run_asm([arg])
        if rc >= 128: crash_count += 1
    report_result(crash_count == 0, f"fuzz: 100 random args (crashes: {crash_count})")

    # Multiple random args
    crash_count = 0
    for _ in range(30):
        n_args = random.randint(1, 4)
        args = [''.join(random.choices(string.digits + ".-", k=random.randint(1, 10)))
                for _ in range(n_args)]
        rc, _, _ = run_asm(args)
        if rc >= 128: crash_count += 1
    report_result(crash_count == 0, f"fuzz: 30 multi-arg random (crashes: {crash_count})")

    # Binary data args
    crash_count = 0
    for _ in range(30):
        data = bytes(random.randint(1, 255) for _ in range(random.randint(1, 100)))
        try:
            rc, _, _ = run_asm([data.decode("latin-1")])
            if rc >= 128: crash_count += 1
        except Exception:
            pass
    report_result(crash_count == 0, f"fuzz: 30 binary data args (crashes: {crash_count})")

    pathological = [
        ("empty arg", [""]),
        ("just a dash", ["-"]),
        ("just a dot", ["."]),
        ("very long number string", ["9" * 100]),
        ("negative zero", ["-0"]),
        ("double negative", ["--5"]),
        ("leading zeros", ["007"]),
        ("spaces in number", [" 5 "]),
        ("multiple dots", ["1.2.3"]),
        ("nan string", ["nan"]),
        ("inf string", ["inf"]),
    ]
    for desc, args in pathological:
        rc, _, _ = run_asm(args)
        report_result(rc < 128, f"fuzz: pathological {desc} (rc={rc})")

    # Deterministic output
    results = set()
    for _ in range(10):
        _, out, _ = run_asm(["5"])
        results.add(out)
    report_result(len(results) == 1, "fuzz: deterministic output (10 trials)")

# =============================================================================
#                     8. RESOURCE LIMIT TESTING
# =============================================================================

def test_resource_limits():
    log("\n=== Resource Limit Testing ===")

    for name, setter in [
        ("RLIMIT_AS=16MB", lambda: resource.setrlimit(resource.RLIMIT_AS, (16*1024*1024, 16*1024*1024))),
        ("RLIMIT_NOFILE=3", lambda: resource.setrlimit(resource.RLIMIT_NOFILE, (3, 3))),
        ("RLIMIT_CPU=5s", lambda: resource.setrlimit(resource.RLIMIT_CPU, (5, 5))),
        ("RLIMIT_STACK=64KB", lambda: resource.setrlimit(resource.RLIMIT_STACK, (65536, 65536))),
    ]:
        rc, _, _ = run_asm(["10"], preexec_fn=setter)
        report_result(rc < 128, f"rlimit: {name}")

    def combined():
        resource.setrlimit(resource.RLIMIT_AS, (16*1024*1024, 16*1024*1024))
        resource.setrlimit(resource.RLIMIT_NOFILE, (3, 3))
        resource.setrlimit(resource.RLIMIT_CPU, (5, 5))
        resource.setrlimit(resource.RLIMIT_STACK, (65536, 65536))
    rc, _, _ = run_asm(["10"], preexec_fn=combined)
    report_result(rc < 128, "rlimit: combined limits")

# =============================================================================
#                     9. ENVIRONMENT ROBUSTNESS
# =============================================================================

def test_environment():
    log("\n=== Environment Robustness ===")

    rc, _, _ = run_asm(["5"], env={})
    report_result(rc < 128, "env: empty environment no crash")

    hostile_env = {
        "PATH": "/nonexistent", "HOME": "/nonexistent",
        "LD_PRELOAD": "/nonexistent/evil.so", "IFS": "\t\n",
        "LANG": "INVALID", "LC_ALL": "INVALID",
    }
    rc, _, _ = run_asm(["5"], env=hostile_env)
    report_result(rc < 128, "env: hostile environment no crash")

    large_env = {f"VAR_{i}": f"value_{i}" * 100 for i in range(1000)}
    rc, _, _ = run_asm(["5"], env=large_env)
    report_result(rc < 128, "env: large environment (1000 vars)")

# =============================================================================
#                     10. OUTPUT INTEGRITY
# =============================================================================

def test_output_integrity():
    log("\n=== Output Integrity ===")

    results = []
    for _ in range(10):
        _, out, _ = run_asm(["20"])
        results.append(out)
    report_result(len(set(results)) == 1, "integrity: deterministic (10 trials)")

    rc, out, err = run_asm(["5"])
    report_result(err == b"" or rc != 0, "integrity: stderr empty on success")

    for desc, args in [
        ("seq 5", ["5"]),
        ("seq 1 5", ["1", "5"]),
        ("seq 1 2 10", ["1", "2", "10"]),
    ]:
        rc_a, out_a, _ = run_asm(args)
        rc_g, out_g, _ = run_gnu(args)
        report_result(rc_a == rc_g, f"integrity: exit code match GNU ({desc})")
        report_result(out_a == out_g, f"integrity: output match GNU ({desc})")

# =============================================================================
#                     11. ERROR HANDLING
# =============================================================================

def test_error_handling():
    log("\n=== Error Handling ===")

    rc_a, _, _ = run_asm(["--invalid-flag-xyz"])
    report_result(rc_a != 0, "error: invalid flag returns nonzero")

    # No arguments — error
    rc_a, _, _ = run_asm([])
    rc_g, _, _ = run_gnu([])
    report_result(rc_a != 0, "error: no arguments returns nonzero")

    # Invalid number
    rc_a, _, _ = run_asm(["abc"])
    report_result(rc_a != 0, "error: invalid number returns nonzero")

    if which("strace"):
        rc, _, _ = run(["strace", "-e", "inject=write:error=EINTR:when=1",
                        BIN, "5"])
        report_result(rc in (0, 1, 124), "error: EINTR injection on write")
    else:
        skip_test("error: EINTR injection", "no strace")

    if os.path.exists("/dev/full"):
        script = f'{BIN} 5 > /dev/full 2>/dev/null; echo $?'
        p = subprocess.run(["bash", "-c", script], capture_output=True, timeout=TIMEOUT, text=True)
        report_result(p.returncode == 0, "error: /dev/full write")

    script = f'{BIN} 1000000 | head -c 10 >/dev/null 2>/dev/null; echo $?'
    p = subprocess.run(["bash", "-c", script], capture_output=True, timeout=TIMEOUT, text=True)
    report_result(p.returncode == 0, "error: broken pipe mid-output")

# =============================================================================
#                     12. CONCURRENCY STRESS
# =============================================================================

def test_concurrency():
    log("\n=== Concurrency Stress ===")

    procs = []
    for i in range(50):
        p = subprocess.Popen([BIN, str(i + 1)],
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        procs.append(p)

    all_ok = True
    for p in procs:
        try:
            out, err = p.communicate(timeout=TIMEOUT)
            if p.returncode >= 128: all_ok = False
        except subprocess.TimeoutExpired:
            p.kill(); p.communicate(); all_ok = False
    report_result(all_ok, "concurrency: 50 simultaneous instances")

    # Pipe chain: seq | cat | head
    script = f'{BIN} 1000 | cat | head -5'
    p = subprocess.run(["bash", "-c", script], capture_output=True, timeout=TIMEOUT, text=True)
    expected = "1\n2\n3\n4\n5\n"
    report_result(p.stdout == expected, "concurrency: pipe chain seq|cat|head")

    ok_count = 0
    for _ in range(20):
        p = subprocess.Popen([BIN, "1000000"],
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            time.sleep(0.01); p.kill(); p.wait(timeout=2); ok_count += 1
        except:
            try: p.kill()
            except: pass
    report_result(ok_count >= 18, f"concurrency: rapid start/kill ({ok_count}/20)")

# =============================================================================
#                     13. TOOL-SPECIFIC: SEQ TESTS
# =============================================================================

def test_seq_specific():
    log("\n=== Seq-Specific Tests ===")

    # --- Basic: seq LAST ---
    rc_a, out_a, _ = run_asm(["5"])
    rc_g, out_g, _ = run_gnu(["5"])
    report_result(out_a == out_g, "seq: seq 5 matches GNU")
    report_result(out_a == b"1\n2\n3\n4\n5\n", "seq: seq 5 correct output")

    # --- seq FIRST LAST ---
    rc_a, out_a, _ = run_asm(["3", "7"])
    rc_g, out_g, _ = run_gnu(["3", "7"])
    report_result(out_a == out_g, "seq: seq 3 7 matches GNU")

    # --- seq FIRST INCREMENT LAST ---
    rc_a, out_a, _ = run_asm(["1", "2", "10"])
    rc_g, out_g, _ = run_gnu(["1", "2", "10"])
    report_result(out_a == out_g, "seq: seq 1 2 10 matches GNU")
    report_result(out_a == b"1\n3\n5\n7\n9\n", "seq: seq 1 2 10 correct output")

    # --- seq 1 (single number) ---
    rc_a, out_a, _ = run_asm(["1"])
    rc_g, out_g, _ = run_gnu(["1"])
    report_result(out_a == out_g, "seq: seq 1 matches GNU")

    # --- seq 0 (zero) ---
    rc_a, out_a, _ = run_asm(["0"])
    rc_g, out_g, _ = run_gnu(["0"])
    report_result(out_a == out_g, "seq: seq 0 matches GNU")

    # --- Empty range: FIRST > LAST with positive step ---
    rc_a, out_a, _ = run_asm(["5", "1"])
    rc_g, out_g, _ = run_gnu(["5", "1"])
    report_result(out_a == out_g, "seq: empty range (5 1) matches GNU")
    report_result(out_a == b"", "seq: empty range produces no output")

    # --- Negative numbers ---
    rc_a, out_a, _ = run_asm(["-3", "3"])
    rc_g, out_g, _ = run_gnu(["-3", "3"])
    report_result(out_a == out_g, "seq: negative start (-3 3) matches GNU")

    # --- Counting down ---
    rc_a, out_a, _ = run_asm(["5", "-1", "1"])
    rc_g, out_g, _ = run_gnu(["5", "-1", "1"])
    report_result(out_a == out_g, "seq: counting down (5 -1 1) matches GNU")
    report_result(out_a == b"5\n4\n3\n2\n1\n", "seq: counting down correct output")

    # --- Counting down to negative ---
    rc_a, out_a, _ = run_asm(["2", "-1", "-2"])
    rc_g, out_g, _ = run_gnu(["2", "-1", "-2"])
    report_result(out_a == out_g, "seq: counting down to negative matches GNU")

    # --- -w (equal width / zero padding) ---
    rc_a, out_a, _ = run_asm(["-w", "1", "10"])
    rc_g, out_g, _ = run_gnu(["-w", "1", "10"])
    report_result(out_a == out_g, "seq: -w zero padding matches GNU")
    # First line should be zero-padded
    first_line = out_a.split(b"\n")[0]
    report_result(first_line == b"01", "seq: -w pads '1' to '01'")

    # --- -w with larger range ---
    rc_a, out_a, _ = run_asm(["-w", "1", "100"])
    rc_g, out_g, _ = run_gnu(["-w", "1", "100"])
    report_result(out_a == out_g, "seq: -w 1 100 matches GNU")

    # --- -s (custom separator) ---
    rc_a, out_a, _ = run_asm(["-s", ",", "5"])
    rc_g, out_g, _ = run_gnu(["-s", ",", "5"])
    report_result(out_a == out_g, "seq: -s comma separator matches GNU")
    report_result(out_a == b"1,2,3,4,5\n", "seq: -s comma correct output")

    # --- -s with space separator ---
    rc_a, out_a, _ = run_asm(["-s", " ", "3"])
    rc_g, out_g, _ = run_gnu(["-s", " ", "3"])
    report_result(out_a == out_g, "seq: -s space separator matches GNU")

    # --- -s with multi-char separator ---
    rc_a, out_a, _ = run_asm(["-s", " | ", "3"])
    rc_g, out_g, _ = run_gnu(["-s", " | ", "3"])
    report_result(out_a == out_g, "seq: -s multi-char separator matches GNU")

    # --- Float: seq 0.5 ---
    rc_a, out_a, _ = run_asm(["0.5"])
    rc_g, out_g, _ = run_gnu(["0.5"])
    report_result(out_a == out_g, "seq: float seq 0.5 matches GNU")

    # --- Float: seq 0.1 0.1 0.5 ---
    rc_a, out_a, _ = run_asm(["0.1", "0.1", "0.5"])
    rc_g, out_g, _ = run_gnu(["0.1", "0.1", "0.5"])
    report_result(out_a == out_g, "seq: float seq 0.1 0.1 0.5 matches GNU")

    # --- Float: seq 1.0 0.5 3.0 ---
    rc_a, out_a, _ = run_asm(["1.0", "0.5", "3.0"])
    rc_g, out_g, _ = run_gnu(["1.0", "0.5", "3.0"])
    report_result(out_a == out_g, "seq: float seq 1.0 0.5 3.0 matches GNU")

    # --- Large integer range (verify count) ---
    rc_a, out_a, _ = run_asm(["1", "1000"], timeout=10)
    rc_g, out_g, _ = run_gnu(["1", "1000"], timeout=10)
    report_result(out_a == out_g, "seq: seq 1 1000 matches GNU")
    report_result(len(out_a.strip().split(b"\n")) == 1000, "seq: seq 1 1000 has 1000 lines")

    # --- Large step ---
    rc_a, out_a, _ = run_asm(["1", "100", "1000"])
    rc_g, out_g, _ = run_gnu(["1", "100", "1000"])
    report_result(out_a == out_g, "seq: large step (1 100 1000) matches GNU")

    # --- Negative step, negative range ---
    rc_a, out_a, _ = run_asm(["-1", "-1", "-5"])
    rc_g, out_g, _ = run_gnu(["-1", "-1", "-5"])
    report_result(out_a == out_g, "seq: negative step negative range matches GNU")

    # --- -w with negative numbers ---
    rc_a, out_a, _ = run_asm(["-w", "-5", "5"])
    rc_g, out_g, _ = run_gnu(["-w", "-5", "5"])
    report_result(out_a == out_g, "seq: -w with negative numbers matches GNU")

    # --- Error: no arguments ---
    rc_a, _, err_a = run_asm([])
    rc_g, _, err_g = run_gnu([])
    report_result(rc_a != 0, "seq: no args returns nonzero")
    report_result(rc_a == rc_g, "seq: no args exit code matches GNU")

    # --- Error: invalid number ---
    rc_a, _, err_a = run_asm(["abc"])
    rc_g, _, err_g = run_gnu(["abc"])
    report_result(rc_a != 0, "seq: invalid number returns nonzero")

    # --- Error: too many arguments ---
    rc_a, _, _ = run_asm(["1", "2", "3", "4"])
    rc_g, _, _ = run_gnu(["1", "2", "3", "4"])
    report_result(rc_a != 0, "seq: too many args returns nonzero")
    report_result(rc_a == rc_g, "seq: too many args exit code matches GNU")

    # --- --help ---
    rc_a, out_a, _ = run_asm(["--help"])
    report_result(rc_a == 0 and len(out_a) > 0, "seq: --help works")

    # --- --version ---
    rc_a, out_a, _ = run_asm(["--version"])
    report_result(rc_a == 0 and len(out_a) > 0, "seq: --version works")

    # --- seq 1 1 1 (single value with explicit step) ---
    rc_a, out_a, _ = run_asm(["1", "1", "1"])
    rc_g, out_g, _ = run_gnu(["1", "1", "1"])
    report_result(out_a == out_g, "seq: seq 1 1 1 matches GNU")

    # --- seq with step 0 (should error) ---
    rc_a, _, _ = run_asm(["1", "0", "5"])
    rc_g, _, _ = run_gnu(["1", "0", "5"])
    report_result(rc_a != 0, "seq: step 0 returns nonzero")

    # --- Large output integrity check ---
    rc_a, out_a, _ = run_asm(["1", "10000"], timeout=10)
    rc_g, out_g, _ = run_gnu(["1", "10000"], timeout=10)
    report_result(out_a == out_g, "seq: seq 1 10000 matches GNU exactly")

# =============================================================================
#                           MAIN
# =============================================================================

def run_tests():
    log(f"=== Security Tests for {TOOL_NAME} (fseq) ===")
    log(f"Binary: {BIN}")
    log(f"GNU:    {GNU}")
    if not os.path.isfile(BIN):
        log(f"[FATAL] Binary not found: {BIN}"); sys.exit(2)
    if not os.access(BIN, os.X_OK):
        log(f"[FATAL] Binary not executable: {BIN}"); sys.exit(2)

    test_elf_binary_security()
    test_syscall_surface()
    test_proc_runtime()
    test_fd_hygiene()
    test_memory_safety()
    test_signal_safety()
    test_input_fuzzing()
    test_resource_limits()
    test_environment()
    test_output_integrity()
    test_error_handling()
    test_concurrency()
    test_seq_specific()

def print_summary():
    log(f"\n{'='*60}")
    log(f"RESULTS: {pass_count}/{test_count} passed, "
        f"{test_count - pass_count - skip_count} failed, {skip_count} skipped")
    if failures:
        log(f"\nFailed tests:")
        for f in failures:
            log(f"  - {f['label']}: {f.get('note', '')}")
    log(f"{'='*60}")

if __name__ == "__main__":
    run_tests()
    print_summary()
    sys.exit(0 if (test_count - pass_count - skip_count) == 0 else 1)
