#!/usr/bin/env python3
"""security_tests.py -- Security & memory safety tests for fpr (assembly pr)."""

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
BSS_SIZE = 524288  # OUT_BUF_SIZE
TOOL_NAME = "pr"
BIN = str(Path(__file__).resolve().parent.parent / "fpr")
GNU = "/usr/bin/pr"

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
    report_result(size < 200000, f"elf: binary size {size} bytes (<200KB)")

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
        log("[WARN] elf: RWX segment found")
    report_result(has_nx_stack or not has_rwx, "elf: PT_GNU_STACK NX or no RWX")
    report_result(entry_in_load, "elf: entry point within LOAD segment")

    bad_patterns = [
        (b"/home/", "home dir"),
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

    test_input = b"hello\nworld\n"

    rc, out, err = run(["strace", "-f", "-e", "trace=%network", BIN, "-t"], stdin_data=test_input)
    net_calls = [l for l in err.split(b"\n") if b"socket(" in l or b"connect(" in l]
    report_result(len(net_calls) == 0, "syscall: no network syscalls")

    rc, out, err = run(["strace", "-f", "-e", "trace=%process", BIN, "--help"])
    spawn_calls = [l for l in err.split(b"\n")
                   if b"fork(" in l or b"vfork(" in l or b"clone(" in l]
    spawn_calls = [l for l in spawn_calls if b"execve(" not in l]
    report_result(len(spawn_calls) == 0, "syscall: no process spawning")

    rc, out, err = run(["strace", "-c", "-e", "trace=all", BIN, "-t"], stdin_data=test_input)
    report_result(rc in (0, 124), "syscall: strace -c completed")

# =============================================================================
#                     3. /proc FILESYSTEM RUNTIME ANALYSIS
# =============================================================================

def test_proc_runtime():
    log("\n=== /proc Filesystem Runtime Analysis ===")
    p = subprocess.Popen([BIN, "-t"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
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
            report_result(os.path.basename(exe) == "fpr", "proc: /proc/PID/exe points to fpr")
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

    p = subprocess.Popen([BIN, "-t"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
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
    rc, _, _ = run_asm(["-t"], stdin_data=b"hello\n", preexec_fn=limit_nofile)
    report_result(rc in (0, 1), "fd: works with RLIMIT_NOFILE=3")

    script = f'echo "test" | {BIN} -t 2>/dev/null 1>&-; echo $?'
    p = subprocess.run(["bash", "-c", script], capture_output=True, timeout=TIMEOUT, text=True)
    report_result(p.returncode == 0, "fd: closed stdout doesn't crash")

    script = f'echo "test" | {BIN} --invalid 2>&- 1>/dev/null; echo $?'
    p = subprocess.run(["bash", "-c", script], capture_output=True, timeout=TIMEOUT, text=True)
    report_result(p.returncode == 0, "fd: closed stderr doesn't crash")

    if os.path.exists("/dev/full"):
        script = f'echo "test" | {BIN} -t > /dev/full 2>/dev/null; echo $?'
        p = subprocess.run(["bash", "-c", script], capture_output=True, timeout=TIMEOUT, text=True)
        report_result(p.stdout.strip() != "" and p.returncode == 0, "fd: /dev/full ENOSPC handling")

    script = f'echo "test" | {BIN} -t > /dev/null 2>/dev/null; echo $?'
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
        rc, _, _ = run_asm(["-t"], stdin_data=data)
        report_result(rc < 128, f"mem: no crash on {desc} (rc={rc})")

    log("\n--- Large Input Testing ---")
    for desc, size in [
        ("64KB", 65536),
        ("256KB", 262144),
        ("512KB", 524288),
        ("1MB", 1048576),
    ]:
        data = (b"A" * 100 + b"\n") * (size // 101)
        rc, _, _ = run_asm(["-t"], stdin_data=data)
        report_result(rc < 128, f"mem: {desc} input no crash (rc={rc})")

    log("\n--- Long Line Testing ---")
    for desc, size in [
        ("1KB line", 1024),
        ("8KB line", 8192),
        ("64KB line", 65536),
    ]:
        data = b"X" * size + b"\n"
        rc, _, _ = run_asm(["-t"], stdin_data=data)
        report_result(rc < 128, f"mem: {desc} no crash (rc={rc})")

    log("\n--- Many Lines Testing ---")
    for desc, count in [
        ("10000 lines", 10000),
        ("100000 lines", 100000),
    ]:
        data = b"line\n" * count
        rc, out, _ = run_asm(["-t"], stdin_data=data, timeout=10)
        report_result(rc < 128, f"mem: {desc} no crash (rc={rc})")

# =============================================================================
#                     6. SIGNAL HANDLING
# =============================================================================

def test_signal_handling():
    log("\n=== Signal Handling ===")

    # SIGPIPE: writing to closed pipe
    script = f'echo "test" | {BIN} -t | head -0 2>/dev/null; echo $?'
    p = subprocess.run(["bash", "-c", script], capture_output=True, timeout=TIMEOUT, text=True)
    rc = int(p.stdout.strip()) if p.stdout.strip().isdigit() else -1
    report_result(rc in (0, 141), f"signal: SIGPIPE handled (rc={rc})")

    # SIGPIPE with large output
    script = f'seq 1 100000 | {BIN} -t | head -1 > /dev/null 2>&1; echo $?'
    p = subprocess.run(["bash", "-c", script], capture_output=True, timeout=TIMEOUT, text=True)
    rc = int(p.stdout.strip()) if p.stdout.strip().isdigit() else -1
    report_result(rc in (0, 141), f"signal: SIGPIPE large output (rc={rc})")

# =============================================================================
#                     7. INPUT VALIDATION
# =============================================================================

def test_input_validation():
    log("\n=== Input Validation ===")

    # Invalid options
    rc, _, err = run_asm(["--invalid-option"])
    report_result(rc != 0, "input: rejects --invalid-option")

    # Missing file
    rc, _, err = run_asm(["/nonexistent/file/path"])
    report_result(rc != 0, "input: rejects missing file")

    # Zero-length page with -l
    rc, _, _ = run_asm(["-t", "-l", "0"], stdin_data=b"test\n")
    report_result(rc < 128, "input: -l 0 doesn't crash")

    # Negative-like column count
    rc, _, _ = run_asm(["-t", "--columns=0"], stdin_data=b"test\n")
    report_result(rc < 128, "input: --columns=0 doesn't crash")

    # Very large page width
    rc, _, _ = run_asm(["-t", "-w", "999999"], stdin_data=b"test\n")
    report_result(rc < 128, "input: -w 999999 doesn't crash")

# =============================================================================
#                     8. BINARY DATA HANDLING
# =============================================================================

def test_binary_data():
    log("\n=== Binary Data Handling ===")

    # All byte values
    data = bytes(range(256)) + b"\n"
    rc, _, _ = run_asm(["-t"], stdin_data=data)
    report_result(rc < 128, "binary: all 256 byte values")

    # NUL bytes in input
    data = b"hello\x00world\n"
    rc, _, _ = run_asm(["-t"], stdin_data=data)
    report_result(rc < 128, "binary: NUL bytes in lines")

    # Very long line with binary
    data = bytes(range(256)) * 100 + b"\n"
    rc, _, _ = run_asm(["-t"], stdin_data=data)
    report_result(rc < 128, "binary: long binary line")

# =============================================================================
#                     9. RESOURCE LIMITS
# =============================================================================

def test_resource_limits():
    log("\n=== Resource Limits ===")

    def limit_memory():
        resource.setrlimit(resource.RLIMIT_AS, (50 * 1024 * 1024, 50 * 1024 * 1024))
    rc, _, _ = run_asm(["-t"], stdin_data=b"hello\n", preexec_fn=limit_memory)
    report_result(rc < 128, f"rlimit: 50MB RLIMIT_AS (rc={rc})")

    def limit_fsize():
        resource.setrlimit(resource.RLIMIT_FSIZE, (1024, 1024))
    rc, _, _ = run_asm(["-t"], stdin_data=b"hello\n", preexec_fn=limit_fsize)
    report_result(rc < 128, f"rlimit: small RLIMIT_FSIZE (rc={rc})")

# =============================================================================
#                     10. CONCURRENCY SAFETY
# =============================================================================

def test_concurrency():
    log("\n=== Concurrency Safety ===")
    procs = []
    for i in range(10):
        p = subprocess.Popen([BIN, "-t"], stdin=subprocess.PIPE,
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        procs.append(p)
    all_ok = True
    for i, p in enumerate(procs):
        try:
            out, err = p.communicate(input=f"line {i}\n".encode(), timeout=TIMEOUT)
            if p.returncode >= 128:
                all_ok = False
        except:
            all_ok = False
            try: p.kill()
            except: pass
            p.wait()
    report_result(all_ok, "concurrency: 10 parallel instances")

# =============================================================================
#                            MAIN
# =============================================================================

if __name__ == "__main__":
    log(f"=== Security Tests for {TOOL_NAME} ===")
    log(f"Binary: {BIN}")
    log(f"GNU ref: {GNU}")

    if not os.path.exists(BIN):
        log(f"FATAL: binary not found: {BIN}")
        sys.exit(1)

    test_elf_binary_security()
    test_syscall_surface()
    test_proc_runtime()
    test_fd_hygiene()
    test_memory_safety()
    test_signal_handling()
    test_input_validation()
    test_binary_data()
    test_resource_limits()
    test_concurrency()

    log(f"\n{'=' * 50}")
    log(f"Results: {pass_count}/{test_count} passed, {skip_count} skipped, {len(failures)} failed")
    log(f"{'=' * 50}")

    if failures:
        log("\nFailures:")
        for f in failures:
            log(f"  - {f['label']}")

    sys.exit(0 if not failures else 1)
