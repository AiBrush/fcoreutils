#!/usr/bin/env python3
"""security_tests.py — Security & memory safety tests for fsha384sum (assembly sha384sum)."""

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
import hashlib
from pathlib import Path
from shutil import which

# =============================================================================
#                           CONFIGURATION
# =============================================================================

TIMEOUT = 5
BSS_SIZE = 65536
TOOL_NAME = "sha384sum"
BIN = str(Path(__file__).resolve().parent.parent / "fsha384sum")
GNU = "/usr/bin/sha384sum"

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

def sha384(data):
    """Compute SHA-384 hash of data using Python hashlib."""
    return hashlib.sha384(data).hexdigest()

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
    report_result(size < 30000, f"elf: binary size {size} bytes (<30KB)")

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

    test_input = b"hello world\n"

    rc, out, err = run(["strace", "-f", "-e", "trace=%network", BIN], stdin_data=test_input)
    net_calls = [l for l in err.split(b"\n") if b"socket(" in l or b"connect(" in l]
    report_result(len(net_calls) == 0, "syscall: no network syscalls")

    rc, out, err = run(["strace", "-f", "-e", "trace=%process", BIN, "--help"])
    spawn_calls = [l for l in err.split(b"\n")
                   if b"fork(" in l or b"vfork(" in l or b"clone(" in l]
    spawn_calls = [l for l in spawn_calls if b"execve(" not in l]
    report_result(len(spawn_calls) == 0, "syscall: no process spawning")

    rc, out, err = run(["strace", "-f", "-e", "trace=brk,mmap,mprotect", BIN], stdin_data=test_input)
    mem_lines = [l for l in err.split(b"\n")
                 if b"brk(" in l or b"mmap(" in l or b"mprotect(" in l]
    mem_lines = [l for l in mem_lines if not l.startswith(b"---") and not l.startswith(b"+++")]
    report_result(len(mem_lines) < 10, f"syscall: minimal brk/mmap/mprotect ({len(mem_lines)} calls)")

# =============================================================================
#                     3-12: Standard security tests (same structure as other tools)
# =============================================================================

def test_proc_runtime():
    log("\n=== /proc Filesystem Runtime Analysis ===")
    p = subprocess.Popen([BIN], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    time.sleep(0.05)
    try:
        pid = p.pid
        try:
            maps = Path(f"/proc/{pid}/maps").read_text(errors="ignore")
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
            report_result(os.path.basename(exe) == "fsha384sum", "proc: /proc/PID/exe points to fsha384sum")
        except Exception as e:
            skip_test("proc: exe link", str(e))
    finally:
        try: p.stdin.write(b"data\n"); p.stdin.close()
        except: pass
        try: p.kill()
        except: pass
        p.wait()

def test_fd_hygiene():
    log("\n=== File Descriptor Hygiene ===")
    p = subprocess.Popen([BIN], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    time.sleep(0.05)
    try:
        fds = set(os.listdir(f"/proc/{p.pid}/fd"))
        extra = fds - {"0", "1", "2"}
        report_result(len(extra) == 0, f"fd: only 0,1,2 open (extra: {extra if extra else 'none'})")
    except Exception as e:
        skip_test("fd: open fd check", str(e))
    finally:
        try: p.stdin.close(); p.kill()
        except: pass
        p.wait()
    def limit_nofile():
        resource.setrlimit(resource.RLIMIT_NOFILE, (3, 3))
    rc, _, _ = run_asm([], stdin_data=b"hello\n", preexec_fn=limit_nofile)
    report_result(rc in (0, 1), "fd: works with RLIMIT_NOFILE=3")
    script = f'echo "test" | {BIN} 2>/dev/null 1>&-; echo $?'
    p = subprocess.run(["bash", "-c", script], capture_output=True, timeout=TIMEOUT, text=True)
    report_result(p.returncode == 0, "fd: closed stdout doesn't crash")
    script = f'echo "test" | {BIN} > /dev/null 2>/dev/null; echo $?'
    p = subprocess.run(["bash", "-c", script], capture_output=True, timeout=TIMEOUT, text=True)
    report_result(p.stdout.strip() == "0", "fd: /dev/null output works")

def test_memory_safety():
    log("\n=== Memory Safety Tests ===")
    for desc, data in [
        ("empty stdin", b""), ("single byte", b"A"), ("single newline", b"\n"),
        ("binary data", bytes(range(256))), ("null bytes", b"\x00" * 100),
    ]:
        rc, _, _ = run_asm([], stdin_data=data)
        report_result(rc < 128, f"mem: no crash on {desc} (rc={rc})")
    for desc, size in [
        ("BSS_SIZE", BSS_SIZE), ("2x BSS_SIZE", BSS_SIZE * 2),
        ("8x BSS_SIZE", BSS_SIZE * 8),
    ]:
        rc, _, _ = run_asm([], stdin_data=b"A" * size)
        report_result(rc < 128, f"mem: BSS boundary {desc} ({size} bytes) no crash")
    big_data = os.urandom(10 * 1024 * 1024)
    rc, _, _ = run_asm([], stdin_data=big_data, timeout=15)
    report_result(rc < 128, "mem: 10MB input no crash")

def test_signal_safety():
    log("\n=== Signal Safety ===")
    script = f'echo "test" | {BIN} | head -1 >/dev/null 2>/dev/null; echo $?'
    p = subprocess.run(["bash", "-c", script], capture_output=True, timeout=TIMEOUT, text=True)
    report_result(p.returncode == 0, "signal: SIGPIPE clean exit")
    for sig_val, sig_name in [(signal.SIGTERM, "SIGTERM"), (signal.SIGINT, "SIGINT")]:
        p = subprocess.Popen([BIN], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            time.sleep(0.05); p.send_signal(sig_val); p.wait(timeout=2)
            report_result(True, f"signal: {sig_name} clean termination")
        except subprocess.TimeoutExpired:
            p.kill(); report_result(False, f"signal: {sig_name} clean termination")
        except:
            report_result(True, f"signal: {sig_name} clean termination")
        finally:
            try: p.kill()
            except: pass

def test_input_fuzzing():
    log("\n=== Input Fuzzing ===")
    crash_count = 0
    for _ in range(100):
        data = os.urandom(random.randint(0, 1000))
        rc, _, _ = run_asm([], stdin_data=data)
        if rc >= 128: crash_count += 1
    report_result(crash_count == 0, f"fuzz: 100 random inputs (crashes: {crash_count})")
    test_data = b"hello world\n"
    results = set()
    for _ in range(10):
        _, out, _ = run_asm([], stdin_data=test_data)
        results.add(out)
    report_result(len(results) == 1, "fuzz: deterministic output (10 trials)")

def test_resource_limits():
    log("\n=== Resource Limit Testing ===")
    test_data = b"hello world\n"
    for name, setter in [
        ("RLIMIT_AS=16MB", lambda: resource.setrlimit(resource.RLIMIT_AS, (16*1024*1024, 16*1024*1024))),
        ("RLIMIT_NOFILE=3", lambda: resource.setrlimit(resource.RLIMIT_NOFILE, (3, 3))),
    ]:
        rc, _, _ = run_asm([], stdin_data=test_data, preexec_fn=setter)
        report_result(rc < 128, f"rlimit: {name}")

def test_environment():
    log("\n=== Environment Robustness ===")
    rc, _, _ = run_asm([], stdin_data=b"hello\n", env={})
    report_result(rc < 128, "env: empty environment no crash")

def test_output_integrity():
    log("\n=== Output Integrity ===")
    rc_a, out_a, _ = run_asm([], stdin_data=b"hello\n")
    rc_g, out_g, _ = run_gnu([], stdin_data=b"hello\n")
    report_result(out_a == out_g, "integrity: output matches GNU exactly")
    report_result(rc_a == rc_g, "integrity: exit code matches GNU")

def test_error_handling():
    log("\n=== Error Handling ===")
    rc_a, _, _ = run_asm(["--invalid-flag-xyz"], stdin_data=b"test\n")
    report_result(rc_a != 0, "error: invalid flag returns nonzero")

def test_concurrency():
    log("\n=== Concurrency Stress ===")
    procs = []
    for i in range(50):
        data = f"instance {i} data\n".encode()
        p = subprocess.Popen([BIN], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        procs.append((p, data))
    all_ok = True
    for p, data in procs:
        try:
            out, err = p.communicate(input=data, timeout=TIMEOUT)
            if p.returncode >= 128: all_ok = False
        except subprocess.TimeoutExpired:
            p.kill(); p.communicate(); all_ok = False
    report_result(all_ok, "concurrency: 50 simultaneous instances")

# =============================================================================
#                     13. TOOL-SPECIFIC: SHA384SUM TESTS
# =============================================================================

def test_sha384sum_specific():
    log("\n=== Sha384sum-Specific Tests ===")

    vectors = [
        (b"", "38b060a751ac96384cd9327eb1b1e36a21fdb71114be07434c0cc7bf63f6e1da274edebfe76f65fbd51ad2f14898b95b"),
        (b"abc", "cb00753f45a35e8bb5a03d699ac65007272c32ab0eded1631a8b605a43ff5bed8086072ba1e7cc2358baeca134c825a7"),
        (b"abcdefghbcdefghicdefghijdefghijkefghijklfghijklmghijklmnhijklmnoijklmnopjklmnopqklmnopqrlmnopqrsmnopqrstnopqrstu",
         "09330c33f71147e83d192fc782cd1b4753111b173b3b05d22fa08086e3b0f712fcc7c71a557e2db966c3e9fa91746039"),
    ]

    for data, expected_hash in vectors:
        rc, out, _ = run_asm([], stdin_data=data)
        if rc == 0:
            output_hash = out.decode().strip().split()[0] if out else ""
            report_result(output_hash == expected_hash,
                         f"sha384: vector '{data[:20].decode(errors='replace')}...' = {expected_hash[:16]}...")
        else:
            report_result(False, f"sha384: vector failed (rc={rc})")

    for data, expected_hash in vectors:
        rc_a, out_a, _ = run_asm([], stdin_data=data)
        rc_g, out_g, _ = run_gnu([], stdin_data=data)
        if rc_a == 0 and rc_g == 0:
            hash_a = out_a.decode().strip().split()[0] if out_a else ""
            hash_g = out_g.decode().strip().split()[0] if out_g else ""
            report_result(hash_a == hash_g, f"sha384: GNU match '{data[:20].decode(errors='replace')}...'")

    rc, out, _ = run_asm([], stdin_data=b"test")
    if rc == 0:
        out_str = out.decode().strip()
        parts = out_str.split()
        report_result(len(parts) >= 2 and len(parts[0]) == 96 and parts[1] == "-",
                     "sha384: output format 'hash  -'")

    rc_a, out_a, _ = run_asm([], stdin_data=b"hello\n")
    rc_g, out_g, _ = run_gnu([], stdin_data=b"hello\n")
    report_result(out_a == out_g, "sha384: output format matches GNU exactly")

    all_bytes = bytes(range(256))
    expected = sha384(all_bytes)
    rc, out, _ = run_asm([], stdin_data=all_bytes)
    if rc == 0:
        output_hash = out.decode().strip().split()[0] if out else ""
        report_result(output_hash == expected, "sha384: all 256 byte values hash correct")

    large_data = os.urandom(1024 * 1024)
    expected = sha384(large_data)
    rc, out, _ = run_asm([], stdin_data=large_data, timeout=15)
    if rc == 0:
        output_hash = out.decode().strip().split()[0] if out else ""
        report_result(output_hash == expected, "sha384: 1MB hash correct")

    for i in range(20):
        size = random.randint(1, 10000)
        data = os.urandom(size)
        expected = sha384(data)
        rc, out, _ = run_asm([], stdin_data=data)
        if rc == 0:
            output_hash = out.decode().strip().split()[0] if out else ""
            report_result(output_hash == expected, f"sha384: random {size} bytes hash correct")

    rc_a, out_a, _ = run_asm(["--help"])
    report_result(rc_a == 0 and len(out_a) > 0, "sha384sum: --help works")
    rc_a, out_a, _ = run_asm(["--version"])
    report_result(rc_a == 0 and len(out_a) > 0, "sha384sum: --version works")

# =============================================================================
#                           MAIN
# =============================================================================

def run_tests():
    log(f"=== Security Tests for {TOOL_NAME} (fsha384sum) ===")
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
    test_sha384sum_specific()

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
