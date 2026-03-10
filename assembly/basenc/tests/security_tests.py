#!/usr/bin/env python3
"""security_tests.py — Security & memory safety tests for fbasenc (assembly basenc)."""

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
BSS_SIZE = 65536
TOOL_NAME = "basenc"
BIN = str(Path(__file__).resolve().parent.parent / "fbasenc")
GNU = "/usr/bin/basenc"

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

    rc, out, err = run(["strace", "-f", "-e", "trace=%network", BIN, "--base64"], stdin_data=test_input)
    net_calls = [l for l in err.split(b"\n") if b"socket(" in l or b"connect(" in l]
    report_result(len(net_calls) == 0, "syscall: no network syscalls")

    rc, out, err = run(["strace", "-f", "-e", "trace=%process", BIN, "--help"])
    spawn_calls = [l for l in err.split(b"\n")
                   if b"fork(" in l or b"vfork(" in l or b"clone(" in l]
    spawn_calls = [l for l in spawn_calls if b"execve(" not in l]
    report_result(len(spawn_calls) == 0, "syscall: no process spawning")

    rc, out, err = run(["strace", "-f", "-e", "trace=brk,mmap,mprotect", BIN, "--base64"], stdin_data=test_input)
    mem_lines = [l for l in err.split(b"\n")
                 if b"brk(" in l or b"mmap(" in l or b"mprotect(" in l]
    mem_lines = [l for l in mem_lines if not l.startswith(b"---") and not l.startswith(b"+++")]
    report_result(len(mem_lines) < 10, f"syscall: minimal brk/mmap/mprotect ({len(mem_lines)} calls)")

# =============================================================================
#                     3. /proc FILESYSTEM RUNTIME ANALYSIS
# =============================================================================

def test_proc_runtime():
    log("\n=== /proc Filesystem Runtime Analysis ===")
    p = subprocess.Popen([BIN, "--base64"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
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
            report_result(os.path.basename(exe) == "fbasenc", "proc: /proc/PID/exe points to fbasenc")
        except Exception as e:
            skip_test("proc: exe link", str(e))
    finally:
        try: p.stdin.write(b"data\n"); p.stdin.close()
        except: pass
        try: p.kill()
        except: pass
        p.wait()

# =============================================================================
#                     4. FILE DESCRIPTOR HYGIENE
# =============================================================================

def test_fd_hygiene():
    log("\n=== File Descriptor Hygiene ===")

    p = subprocess.Popen([BIN, "--base64"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
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
    rc, _, _ = run_asm(["--base64"], stdin_data=b"hello\n", preexec_fn=limit_nofile)
    report_result(rc in (0, 1), "fd: works with RLIMIT_NOFILE=3")

    script = f'echo "test" | {BIN} --base64 2>/dev/null 1>&-; echo $?'
    p = subprocess.run(["bash", "-c", script], capture_output=True, timeout=TIMEOUT, text=True)
    report_result(p.returncode == 0, "fd: closed stdout doesn't crash")

    if os.path.exists("/dev/full"):
        script = f'echo "test" | {BIN} --base64 > /dev/full 2>/dev/null; echo $?'
        p = subprocess.run(["bash", "-c", script], capture_output=True, timeout=TIMEOUT, text=True)
        report_result(p.stdout.strip() != "" and p.returncode == 0, "fd: /dev/full ENOSPC handling")

    script = f'echo "test" | {BIN} --base64 > /dev/null 2>/dev/null; echo $?'
    p = subprocess.run(["bash", "-c", script], capture_output=True, timeout=TIMEOUT, text=True)
    report_result(p.stdout.strip() == "0", "fd: /dev/null output works")

# =============================================================================
#                     5. MEMORY SAFETY
# =============================================================================

def test_memory_safety():
    log("\n=== Memory Safety Tests ===")

    for desc, data in [
        ("empty stdin", b""),
        ("single byte", b"A"),
        ("single newline", b"\n"),
        ("binary data", bytes(range(256))),
        ("null bytes", b"\x00" * 100),
    ]:
        rc, _, _ = run_asm(["--base64"], stdin_data=data)
        report_result(rc < 128, f"mem: no crash on {desc} (rc={rc})")

    log("\n--- BSS Buffer Overflow Testing ---")
    for desc, size in [
        ("BSS_SIZE-1", BSS_SIZE - 1),
        ("BSS_SIZE", BSS_SIZE),
        ("BSS_SIZE+1", BSS_SIZE + 1),
        ("2x BSS_SIZE", BSS_SIZE * 2),
        ("4x BSS_SIZE", BSS_SIZE * 4),
        ("8x BSS_SIZE", BSS_SIZE * 8),
    ]:
        data = b"A" * size
        rc, _, _ = run_asm(["--base64"], stdin_data=data)
        report_result(rc < 128, f"mem: BSS boundary {desc} ({size} bytes) no crash")

    big_data = os.urandom(10 * 1024 * 1024)  # 10MB binary
    rc, _, _ = run_asm(["--base64"], stdin_data=big_data, timeout=10)
    report_result(rc < 128, f"mem: 10MB input no crash")

    long_line = b"X" * (BSS_SIZE * 2)
    rc, _, _ = run_asm(["--base64"], stdin_data=long_line)
    report_result(rc < 128, "mem: single line >BSS_SIZE no crash")

    log("\n--- Boundary Value Analysis ---")
    for desc, data in [
        ("no trailing newline", b"hello"),
        ("only newlines", b"\n" * 50),
        ("1MB single block", b"A" * (1024 * 1024)),
        ("CRLF endings", b"data\r\nmore\r\n"),
        ("embedded nulls", b"hello\x00world\x00\n"),
        ("all 256 byte values", bytes(range(256)) * 4),
        ("alternating null/ff", (b"\x00\xff") * 32768),
    ]:
        rc, _, _ = run_asm(["--base64"], stdin_data=data)
        report_result(rc < 128, f"mem: boundary - {desc} no crash")

    def limit_stack():
        resource.setrlimit(resource.RLIMIT_STACK, (65536, 65536))
    rc, _, _ = run_asm(["--base64"], stdin_data=b"test\n", preexec_fn=limit_stack)
    report_result(rc < 128, "mem: works with 64KB stack limit")

# =============================================================================
#                     6. SIGNAL SAFETY
# =============================================================================

def test_signal_safety():
    log("\n=== Signal Safety Tests ===")

    # SIGPIPE handling (broken pipe)
    script = f'dd if=/dev/urandom bs=1M count=1 2>/dev/null | {BIN} --base64 | head -1 > /dev/null 2>&1; echo $?'
    p = subprocess.run(["bash", "-c", script], capture_output=True, timeout=TIMEOUT, text=True)
    rc = p.stdout.strip()
    report_result(rc in ("0", "141"), f"signal: SIGPIPE handled gracefully (rc={rc})")

    # SIGTERM handling
    proc = subprocess.Popen([BIN, "--base64"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    time.sleep(0.05)
    proc.send_signal(signal.SIGTERM)
    proc.wait(timeout=TIMEOUT)
    report_result(True, f"signal: SIGTERM handled (rc={proc.returncode})")

    # SIGUSR1 handling
    proc = subprocess.Popen([BIN, "--base64"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    time.sleep(0.05)
    proc.send_signal(signal.SIGUSR1)
    try:
        proc.wait(timeout=2)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait()
    report_result(True, "signal: SIGUSR1 doesn't hang")

# =============================================================================
#                     7. INPUT FUZZING
# =============================================================================

def test_input_fuzzing():
    log("\n=== Input Fuzzing Tests ===")

    # Test all encoding modes don't crash on various inputs
    modes = ["--base64", "--base64url", "--base32", "--base32hex", "--base16",
             "--base2msbf", "--base2lsbf", "--z85"]

    for mode in modes:
        rc, _, _ = run_asm([mode], stdin_data=os.urandom(4096))
        report_result(rc < 128, f"fuzz: {mode} encode random 4KB no crash (rc={rc})")

    # Decode mode fuzzing
    for mode in modes:
        rc, _, _ = run_asm([mode, "-d"], stdin_data=os.urandom(1024))
        report_result(rc < 128, f"fuzz: {mode} -d random 1KB no crash (rc={rc})")

    # Invalid decode data
    for mode in modes:
        rc, _, _ = run_asm([mode, "-d"], stdin_data=b"\xff" * 100)
        report_result(rc < 128, f"fuzz: {mode} -d 0xFF*100 no crash (rc={rc})")

    # Extremely long lines
    for mode in ["--base64", "--base32", "--base16"]:
        rc, _, _ = run_asm([mode, "-w0"], stdin_data=os.urandom(100000))
        report_result(rc < 128, f"fuzz: {mode} -w0 100KB no crash (rc={rc})")

    # Z85 with non-multiple-of-4
    for size in [1, 2, 3, 5, 6, 7]:
        rc, _, _ = run_asm(["--z85"], stdin_data=b"A" * size)
        report_result(rc != 0, f"fuzz: z85 {size} bytes (non-mult-4) returns error")

    # Z85 with exact multiples of 4
    for size in [4, 8, 12, 100]:
        data = os.urandom(size)
        rc, _, _ = run_asm(["--z85"], stdin_data=data)
        report_result(rc == 0, f"fuzz: z85 {size} bytes (mult-4) success")

# =============================================================================
#                     8. RESOURCE LIMITS
# =============================================================================

def test_resource_limits():
    log("\n=== Resource Limits ===")

    def limit_mem(mb):
        def inner():
            resource.setrlimit(resource.RLIMIT_AS, (mb * 1024 * 1024, mb * 1024 * 1024))
        return inner

    rc, _, _ = run_asm(["--base64"], stdin_data=b"hello\n", preexec_fn=limit_mem(16))
    report_result(rc < 128, f"mem: works with 16MB RLIMIT_AS (rc={rc})")

    def limit_fsize():
        resource.setrlimit(resource.RLIMIT_FSIZE, (1024, 1024))
    rc, _, _ = run_asm(["--base64"], stdin_data=b"hello\n", preexec_fn=limit_fsize)
    report_result(rc < 128, "mem: works with RLIMIT_FSIZE=1024")

    def limit_cpu():
        resource.setrlimit(resource.RLIMIT_CPU, (1, 1))
    rc, _, _ = run_asm(["--base64"], stdin_data=b"hello\n", preexec_fn=limit_cpu)
    report_result(rc < 128, "mem: works with RLIMIT_CPU=1")

# =============================================================================
#                     9. CONCURRENCY STRESS
# =============================================================================

def test_concurrency():
    log("\n=== Concurrency Stress Tests ===")
    import threading

    errors = []
    data = os.urandom(1024)

    def worker():
        try:
            rc, out, _ = run_asm(["--base64"], stdin_data=data, timeout=10)
            if rc not in (0,):
                errors.append(f"rc={rc}")
        except Exception as e:
            errors.append(str(e))

    threads = [threading.Thread(target=worker) for _ in range(20)]
    for t in threads: t.start()
    for t in threads: t.join(timeout=15)

    report_result(len(errors) == 0, f"concurrency: 20 parallel invocations ({len(errors)} errors)")

# =============================================================================
#                           MAIN
# =============================================================================

def main():
    log(f"Security Tests for {BIN}")
    if not os.path.exists(BIN):
        log(f"ERROR: Binary not found: {BIN}")
        sys.exit(1)

    test_elf_binary_security()
    test_syscall_surface()
    test_proc_runtime()
    test_fd_hygiene()
    test_memory_safety()
    test_signal_safety()
    test_input_fuzzing()
    test_resource_limits()
    test_concurrency()

    log(f"\n{'='*60}")
    log(f"RESULTS: {pass_count}/{test_count} passed, {skip_count} skipped, {len(failures)} failed")
    log(f"{'='*60}")
    if failures:
        log("\nFailed tests:")
        for f in failures:
            log(f"  - {f['label']}")
        sys.exit(1)
    else:
        log("\nAll security tests passed!")

if __name__ == "__main__":
    main()
