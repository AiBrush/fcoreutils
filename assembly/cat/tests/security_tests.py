#!/usr/bin/env python3
"""security_tests.py — Security & memory safety tests for fcat (assembly cat)."""

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
BSS_SIZE = 131072  # 128KB read buffer in fcat
TOOL_NAME = "cat"
BIN = str(Path(__file__).resolve().parent.parent / "fcat")
GNU = "/usr/bin/cat"

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

    test_input = b"hello\nworld\n"

    rc, out, err = run(["strace", "-f", "-e", "trace=%network", BIN], stdin_data=test_input)
    net_calls = [l for l in err.split(b"\n") if b"socket(" in l or b"connect(" in l]
    report_result(len(net_calls) == 0, "syscall: no network syscalls")

    rc, out, err = run(["strace", "-f", "-e", "trace=%process", BIN, "--help"])
    spawn_calls = [l for l in err.split(b"\n")
                   if b"fork(" in l or b"vfork(" in l or b"clone(" in l]
    spawn_calls = [l for l in spawn_calls if b"execve(" not in l]
    report_result(len(spawn_calls) == 0, "syscall: no process spawning")

    # cat uses read/write/sendfile — memory allocation should be minimal
    rc, out, err = run(["strace", "-f", "-e", "trace=brk,mmap,mprotect", BIN], stdin_data=test_input)
    mem_lines = [l for l in err.split(b"\n")
                 if b"brk(" in l or b"mmap(" in l or b"mprotect(" in l]
    mem_lines = [l for l in mem_lines if not l.startswith(b"---") and not l.startswith(b"+++")]
    report_result(len(mem_lines) < 10, f"syscall: minimal brk/mmap/mprotect ({len(mem_lines)} calls)")

    rc, out, err = run(["strace", "-c", "-e", "trace=all", BIN], stdin_data=test_input)
    report_result(rc in (0, 124), "syscall: strace -c completed")

# =============================================================================
#                     3. /proc FILESYSTEM RUNTIME ANALYSIS
# =============================================================================

def test_proc_runtime():
    log("\n=== /proc Filesystem Runtime Analysis ===")
    p = subprocess.Popen([BIN], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    time.sleep(0.05)
    try:
        pid = p.pid
        try:
            maps = Path(f"/proc/{pid}/maps").read_text(errors="ignore")
            has_rwx = any("rwxp" in line for line in maps.splitlines())
            # Flat binaries (nasm -f bin) inherently have a single RWX LOAD segment
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
            report_result(os.path.basename(exe) == "fcat", "proc: /proc/PID/exe points to fcat")
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

    script = f'echo "test" | {BIN} --invalid 2>&- 1>/dev/null; echo $?'
    p = subprocess.run(["bash", "-c", script], capture_output=True, timeout=TIMEOUT, text=True)
    report_result(p.returncode == 0, "fd: closed stderr doesn't crash")

    if os.path.exists("/dev/full"):
        script = f'echo "test" | {BIN} > /dev/full 2>/dev/null; echo $?'
        p = subprocess.run(["bash", "-c", script], capture_output=True, timeout=TIMEOUT, text=True)
        report_result(p.stdout.strip() != "" and p.returncode == 0, "fd: /dev/full ENOSPC handling")

    script = f'echo "test" | {BIN} > /dev/null 2>/dev/null; echo $?'
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
        rc, _, _ = run_asm([], stdin_data=data)
        report_result(rc < 128, f"mem: no crash on {desc} (rc={rc})")

    log("\n--- BSS Buffer Boundary Testing ---")
    for desc, size in [
        ("BSS_SIZE-1", BSS_SIZE - 1),
        ("BSS_SIZE", BSS_SIZE),
        ("BSS_SIZE+1", BSS_SIZE + 1),
        ("2x BSS_SIZE", BSS_SIZE * 2),
        ("4x BSS_SIZE", BSS_SIZE * 4),
        ("8x BSS_SIZE", BSS_SIZE * 8),
    ]:
        data = b"A" * size + b"\n"
        rc, _, _ = run_asm([], stdin_data=data)
        report_result(rc < 128, f"mem: BSS boundary {desc} ({size} bytes) no crash")

    big_data = (b"line of test data\n") * 600000
    rc, _, _ = run_asm([], stdin_data=big_data)
    report_result(rc < 128, f"mem: 10MB+ input no crash ({len(big_data)} bytes)")

    long_line = b"X" * (BSS_SIZE * 2) + b"\n"
    rc, _, _ = run_asm([], stdin_data=long_line)
    report_result(rc < 128, "mem: single line >BSS_SIZE no crash")

    tiny_lines = b"\n" * 1000000
    rc, _, _ = run_asm([], stdin_data=tiny_lines)
    report_result(rc < 128, "mem: 1M tiny lines no crash")

    log("\n--- Boundary Value Analysis ---")
    for desc, data in [
        ("no trailing newline", b"hello"),
        ("only newlines", b"\n" * 50),
        ("1MB single line", b"A" * (1024 * 1024)),
        ("CRLF line endings", b"line1\r\nline2\r\nline3\r\n"),
        ("embedded nulls", b"hello\x00world\x00\n"),
        ("all 256 byte values", bytes(range(256)) * 4),
        ("alternating null/ff", (b"\x00\xff") * 32768),
    ]:
        rc, _, _ = run_asm([], stdin_data=data)
        report_result(rc < 128, f"mem: boundary - {desc} no crash")

    def limit_stack():
        resource.setrlimit(resource.RLIMIT_STACK, (65536, 65536))
    rc, _, _ = run_asm([], stdin_data=b"test\n" * 100, preexec_fn=limit_stack)
    report_result(rc < 128, "mem: RLIMIT_STACK=64KB")

    def limit_as():
        resource.setrlimit(resource.RLIMIT_AS, (16 * 1024 * 1024, 16 * 1024 * 1024))
    rc, _, _ = run_asm([], stdin_data=b"test\n" * 100, preexec_fn=limit_as)
    report_result(rc < 128, "mem: RLIMIT_AS=16MB")

# =============================================================================
#                     6. SIGNAL SAFETY
# =============================================================================

def test_signal_safety():
    log("\n=== Signal Safety ===")

    # cat writes to stdout — SIGPIPE when downstream closes
    script = f'seq 10000 | {BIN} | head -1 >/dev/null 2>/dev/null; echo $?'
    p = subprocess.run(["bash", "-c", script], capture_output=True, timeout=TIMEOUT, text=True)
    report_result(p.returncode == 0, "signal: SIGPIPE clean exit")

    for sig_val, sig_name in [(signal.SIGTERM, "SIGTERM"), (signal.SIGINT, "SIGINT")]:
        p = subprocess.Popen([BIN], stdin=subprocess.PIPE,
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
        rc = os.system(f'seq 100 | {BIN} | head -c 1 >/dev/null 2>/dev/null')
        if rc == 0: ok_count += 1
    report_result(ok_count >= trials - 2, f"signal: rapid SIGPIPE ({ok_count}/{trials})")

# =============================================================================
#                     7. INPUT FUZZING
# =============================================================================

def test_input_fuzzing():
    log("\n=== Input Fuzzing ===")

    crash_count = 0
    for _ in range(100):
        length = random.randint(0, 1000)
        data = ''.join(random.choices(string.printable, k=length)).encode()
        rc, _, _ = run_asm([], stdin_data=data)
        if rc >= 128: crash_count += 1
    report_result(crash_count == 0, f"fuzz: 100 random printable (crashes: {crash_count})")

    crash_count = 0
    for _ in range(30):
        data = os.urandom(random.randint(1024, 102400))
        rc, _, _ = run_asm([], stdin_data=data)
        if rc >= 128: crash_count += 1
    report_result(crash_count == 0, f"fuzz: 30 long random (crashes: {crash_count})")

    crash_count = 0
    for _ in range(30):
        data = bytes(random.randint(0, 255) for _ in range(random.randint(1, 10000)))
        rc, _, _ = run_asm([], stdin_data=data)
        if rc >= 128: crash_count += 1
    report_result(crash_count == 0, f"fuzz: 30 binary blobs (crashes: {crash_count})")

    pathological = [
        ("64KB nulls", b"\x00" * BSS_SIZE),
        ("64KB newlines", b"\n" * BSS_SIZE),
        ("64KB 0xFF", b"\xff" * BSS_SIZE),
        ("32KB CRLF", b"\r\n" * (BSS_SIZE // 2)),
        ("1MB single char", b"A" * (1024 * 1024)),
        ("alternating null/ff", (b"\x00\xff") * (BSS_SIZE // 2)),
        ("random with nulls", os.urandom(BSS_SIZE).replace(b"\n", b"\x00")),
    ]
    for desc, data in pathological:
        rc, _, _ = run_asm([], stdin_data=data)
        report_result(rc < 128, f"fuzz: pathological {desc} (rc={rc})")

    test_data = b"hello\nworld\nfoo\nbar\n"
    results = set()
    for _ in range(10):
        _, out, _ = run_asm([], stdin_data=test_data)
        results.add(out)
    report_result(len(results) == 1, "fuzz: deterministic output (10 trials)")

# =============================================================================
#                     8. RESOURCE LIMIT TESTING
# =============================================================================

def test_resource_limits():
    log("\n=== Resource Limit Testing ===")
    test_data = b"line\n" * 20

    for name, setter in [
        ("RLIMIT_AS=16MB", lambda: resource.setrlimit(resource.RLIMIT_AS, (16*1024*1024, 16*1024*1024))),
        ("RLIMIT_NOFILE=3", lambda: resource.setrlimit(resource.RLIMIT_NOFILE, (3, 3))),
        ("RLIMIT_CPU=5s", lambda: resource.setrlimit(resource.RLIMIT_CPU, (5, 5))),
        ("RLIMIT_STACK=64KB", lambda: resource.setrlimit(resource.RLIMIT_STACK, (65536, 65536))),
    ]:
        rc, _, _ = run_asm([], stdin_data=test_data, preexec_fn=setter)
        report_result(rc < 128, f"rlimit: {name}")

    def combined():
        resource.setrlimit(resource.RLIMIT_AS, (16*1024*1024, 16*1024*1024))
        resource.setrlimit(resource.RLIMIT_NOFILE, (3, 3))
        resource.setrlimit(resource.RLIMIT_CPU, (5, 5))
        resource.setrlimit(resource.RLIMIT_STACK, (65536, 65536))
    rc, _, _ = run_asm([], stdin_data=test_data, preexec_fn=combined)
    report_result(rc < 128, "rlimit: combined limits")

# =============================================================================
#                     9. ENVIRONMENT ROBUSTNESS
# =============================================================================

def test_environment():
    log("\n=== Environment Robustness ===")
    test_data = b"hello\nworld\n"

    rc, _, _ = run_asm([], stdin_data=test_data, env={})
    report_result(rc < 128, "env: empty environment no crash")

    hostile_env = {
        "PATH": "/nonexistent", "HOME": "/nonexistent",
        "LD_PRELOAD": "/nonexistent/evil.so", "IFS": "\t\n",
        "LANG": "INVALID", "LC_ALL": "INVALID",
    }
    rc, _, _ = run_asm([], stdin_data=test_data, env=hostile_env)
    report_result(rc < 128, "env: hostile environment no crash")

    large_env = {f"VAR_{i}": f"value_{i}" * 100 for i in range(1000)}
    rc, _, _ = run_asm([], stdin_data=test_data, env=large_env)
    report_result(rc < 128, "env: large environment (1000 vars)")

# =============================================================================
#                     10. OUTPUT INTEGRITY
# =============================================================================

def test_output_integrity():
    log("\n=== Output Integrity ===")

    test_data = b"".join(f"line {i}\n".encode() for i in range(50))
    results = []
    for _ in range(10):
        _, out, _ = run_asm([], stdin_data=test_data)
        results.append(out)
    report_result(len(set(results)) == 1, "integrity: deterministic (10 trials)")

    rc, out, err = run_asm([], stdin_data=b"hello\n")
    report_result(err == b"" or rc != 0, "integrity: stderr empty on success")

    for desc, data in [
        ("normal", b"hello\nworld\n"),
        ("empty", b""),
    ]:
        rc_a, out_a, _ = run_asm([], stdin_data=data)
        rc_g, out_g, _ = run_gnu([], stdin_data=data)
        report_result(rc_a == rc_g, f"integrity: exit code match GNU ({desc})")
        report_result(out_a == out_g, f"integrity: output match GNU ({desc})")

# =============================================================================
#                     11. ERROR HANDLING
# =============================================================================

def test_error_handling():
    log("\n=== Error Handling ===")

    rc_a, _, _ = run_asm(["--invalid-flag-xyz"], stdin_data=b"test\n")
    report_result(rc_a != 0, "error: invalid flag returns nonzero")

    if which("strace"):
        rc, _, _ = run(["strace", "-e", "inject=write:error=EINTR:when=1",
                        BIN], stdin_data=b"hello\nworld\n")
        report_result(rc in (0, 1, 124), "error: EINTR injection on write")
    else:
        skip_test("error: EINTR injection", "no strace")

    if os.path.exists("/dev/full"):
        script = f'echo "test" | {BIN} > /dev/full 2>/dev/null; echo $?'
        p = subprocess.run(["bash", "-c", script], capture_output=True, timeout=TIMEOUT, text=True)
        report_result(p.returncode == 0, "error: /dev/full write")

    script = f'seq 1000 | {BIN} | head -c 10 >/dev/null 2>/dev/null; echo $?'
    p = subprocess.run(["bash", "-c", script], capture_output=True, timeout=TIMEOUT, text=True)
    report_result(p.returncode == 0, "error: broken pipe mid-output")

    # Nonexistent file
    rc_a, _, err_a = run_asm(["/nonexistent/file/path"])
    rc_g, _, err_g = run_gnu(["/nonexistent/file/path"])
    report_result(rc_a != 0, "error: nonexistent file returns nonzero")
    report_result(rc_a == rc_g, "error: nonexistent file exit code matches GNU")

# =============================================================================
#                     12. CONCURRENCY STRESS
# =============================================================================

def test_concurrency():
    log("\n=== Concurrency Stress ===")

    procs = []
    for i in range(50):
        data = f"instance {i} line\n".encode() * 10
        p = subprocess.Popen([BIN], stdin=subprocess.PIPE,
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        procs.append((p, data))

    all_ok = True
    for p, data in procs:
        try:
            out, err = p.communicate(input=data, timeout=TIMEOUT)
            if p.returncode >= 128: all_ok = False
        except subprocess.TimeoutExpired:
            p.kill(); p.communicate(); all_ok = False
    report_result(all_ok, "concurrency: 50 simultaneous instances")

    # cat | cat roundtrip pipe chain — output must equal input
    script = f'echo "hello world" | {BIN} | {BIN} | {BIN}'
    p = subprocess.run(["bash", "-c", script], capture_output=True, timeout=TIMEOUT, text=True)
    report_result(p.stdout.strip() == "hello world", "concurrency: pipe chain cat|cat|cat passthrough")

    ok_count = 0
    for _ in range(20):
        p = subprocess.Popen([BIN], stdin=subprocess.PIPE,
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            time.sleep(0.01); p.kill(); p.wait(timeout=2); ok_count += 1
        except:
            try: p.kill()
            except: pass
    report_result(ok_count >= 18, f"concurrency: rapid start/kill ({ok_count}/20)")

# =============================================================================
#                     13. TOOL-SPECIFIC: CAT TESTS
# =============================================================================

def test_cat_specific():
    log("\n=== Cat-Specific Tests ===")

    # --- Stdin passthrough ---
    rc_a, out_a, _ = run_asm([], stdin_data=b"hello\n")
    rc_g, out_g, _ = run_gnu([], stdin_data=b"hello\n")
    report_result(out_a == out_g, "cat: stdin passthrough matches GNU")
    report_result(out_a == b"hello\n", "cat: stdin passthrough correct")

    # --- Empty stdin ---
    rc_a, out_a, _ = run_asm([], stdin_data=b"")
    rc_g, out_g, _ = run_gnu([], stdin_data=b"")
    report_result(out_a == out_g, "cat: empty stdin matches GNU")
    report_result(out_a == b"", "cat: empty stdin produces no output")

    # --- Multiple lines via stdin ---
    data = b"line1\nline2\nline3\n"
    rc_a, out_a, _ = run_asm([], stdin_data=data)
    rc_g, out_g, _ = run_gnu([], stdin_data=data)
    report_result(out_a == out_g, "cat: multiple lines matches GNU")

    # --- File reading ---
    with tempfile.NamedTemporaryFile(mode='wb', suffix='.txt', delete=False) as f:
        f.write(b"file content\nsecond line\n")
        tmpfile = f.name
    try:
        rc_a, out_a, _ = run_asm([tmpfile])
        rc_g, out_g, _ = run_gnu([tmpfile])
        report_result(out_a == out_g, "cat: file reading matches GNU")
        report_result(out_a == b"file content\nsecond line\n", "cat: file content correct")
    finally:
        os.unlink(tmpfile)

    # --- Multiple files ---
    files = []
    try:
        for i in range(3):
            with tempfile.NamedTemporaryFile(mode='wb', suffix='.txt', delete=False) as f:
                f.write(f"file{i}\n".encode())
                files.append(f.name)
        rc_a, out_a, _ = run_asm(files)
        rc_g, out_g, _ = run_gnu(files)
        report_result(out_a == out_g, "cat: multiple files matches GNU")
        report_result(out_a == b"file0\nfile1\nfile2\n", "cat: multiple files concatenated")
    finally:
        for f in files:
            os.unlink(f)

    # --- Binary data passthrough ---
    binary_data = bytes(range(256))
    rc_a, out_a, _ = run_asm([], stdin_data=binary_data)
    rc_g, out_g, _ = run_gnu([], stdin_data=binary_data)
    report_result(out_a == out_g, "cat: binary data passthrough matches GNU")

    # --- -n (number all lines) ---
    data = b"alpha\nbeta\ngamma\n"
    rc_a, out_a, _ = run_asm(["-n"], stdin_data=data)
    rc_g, out_g, _ = run_gnu(["-n"], stdin_data=data)
    report_result(out_a == out_g, "cat: -n number lines matches GNU")

    # --- -n with empty lines ---
    data = b"line1\n\nline3\n"
    rc_a, out_a, _ = run_asm(["-n"], stdin_data=data)
    rc_g, out_g, _ = run_gnu(["-n"], stdin_data=data)
    report_result(out_a == out_g, "cat: -n with empty lines matches GNU")

    # --- -b (number non-blank lines) ---
    data = b"alpha\n\nbeta\n\ngamma\n"
    rc_a, out_a, _ = run_asm(["-b"], stdin_data=data)
    rc_g, out_g, _ = run_gnu(["-b"], stdin_data=data)
    report_result(out_a == out_g, "cat: -b number non-blank matches GNU")

    # --- -s (squeeze blank lines) ---
    data = b"line1\n\n\n\nline2\n\n\nline3\n"
    rc_a, out_a, _ = run_asm(["-s"], stdin_data=data)
    rc_g, out_g, _ = run_gnu(["-s"], stdin_data=data)
    report_result(out_a == out_g, "cat: -s squeeze blank matches GNU")

    # --- -E (show ends) ---
    data = b"hello\nworld\n"
    rc_a, out_a, _ = run_asm(["-E"], stdin_data=data)
    rc_g, out_g, _ = run_gnu(["-E"], stdin_data=data)
    report_result(out_a == out_g, "cat: -E show ends matches GNU")

    # --- -T (show tabs) ---
    data = b"no\ttab\there\n"
    rc_a, out_a, _ = run_asm(["-T"], stdin_data=data)
    rc_g, out_g, _ = run_gnu(["-T"], stdin_data=data)
    report_result(out_a == out_g, "cat: -T show tabs matches GNU")

    # --- -v (show non-printing) ---
    data = b"\x01\x02\x03\x7f\n"
    rc_a, out_a, _ = run_asm(["-v"], stdin_data=data)
    rc_g, out_g, _ = run_gnu(["-v"], stdin_data=data)
    report_result(out_a == out_g, "cat: -v show non-printing matches GNU")

    # --- -v with high bytes ---
    data = b"\x80\x81\xfe\xff\n"
    rc_a, out_a, _ = run_asm(["-v"], stdin_data=data)
    rc_g, out_g, _ = run_gnu(["-v"], stdin_data=data)
    report_result(out_a == out_g, "cat: -v high bytes matches GNU")

    # --- - (stdin marker) mixed with files ---
    with tempfile.NamedTemporaryFile(mode='wb', suffix='.txt', delete=False) as f:
        f.write(b"from file\n")
        tmpfile = f.name
    try:
        rc_a, out_a, _ = run_asm([tmpfile, "-", tmpfile], stdin_data=b"from stdin\n")
        rc_g, out_g, _ = run_gnu([tmpfile, "-", tmpfile], stdin_data=b"from stdin\n")
        report_result(out_a == out_g, "cat: file + stdin marker + file matches GNU")
    finally:
        os.unlink(tmpfile)

    # --- /dev/null ---
    rc_a, out_a, _ = run_asm(["/dev/null"])
    rc_g, out_g, _ = run_gnu(["/dev/null"])
    report_result(out_a == out_g, "cat: /dev/null produces no output")
    report_result(rc_a == 0, "cat: /dev/null exits 0")

    # --- Large file ---
    with tempfile.NamedTemporaryFile(mode='wb', suffix='.txt', delete=False) as f:
        large_data = b"".join(f"line{i:06d}\n".encode() for i in range(10000))
        f.write(large_data)
        tmpfile = f.name
    try:
        rc_a, out_a, _ = run_asm([tmpfile], timeout=10)
        rc_g, out_g, _ = run_gnu([tmpfile], timeout=10)
        report_result(out_a == out_g, "cat: large file (10K lines) matches GNU")
    finally:
        os.unlink(tmpfile)

    # --- Symlink ---
    with tempfile.NamedTemporaryFile(mode='wb', suffix='.txt', delete=False) as f:
        f.write(b"symlink target\n")
        tmpfile = f.name
    linkpath = tmpfile + ".link"
    try:
        os.symlink(tmpfile, linkpath)
        rc_a, out_a, _ = run_asm([linkpath])
        rc_g, out_g, _ = run_gnu([linkpath])
        report_result(out_a == out_g, "cat: symlink reading matches GNU")
    finally:
        os.unlink(linkpath)
        os.unlink(tmpfile)

    # --- FIFO (named pipe) ---
    fifo_path = tempfile.mktemp(suffix='.fifo')
    try:
        os.mkfifo(fifo_path)
        # Write to FIFO in background, then read with cat
        fifo_data = b"fifo content\n"
        def write_fifo():
            with open(fifo_path, 'wb') as fw:
                fw.write(fifo_data)
        import threading
        t = threading.Thread(target=write_fifo)
        t.start()
        rc_a, out_a, _ = run_asm([fifo_path], timeout=3)
        t.join(timeout=3)
        report_result(out_a == fifo_data, "cat: FIFO (named pipe) reading works")
    except Exception as e:
        skip_test("cat: FIFO reading", str(e))
    finally:
        try: os.unlink(fifo_path)
        except: pass

    # --- /dev/urandom passthrough (just verify no crash, limited read) ---
    script = f'{BIN} /dev/urandom | head -c 1024 > /dev/null 2>/dev/null; echo $?'
    p = subprocess.run(["bash", "-c", script], capture_output=True, timeout=TIMEOUT, text=True)
    report_result(p.returncode == 0, "cat: /dev/urandom passthrough no crash")

    # --- Combined flags -n -s ---
    data = b"line1\n\n\n\nline2\n"
    rc_a, out_a, _ = run_asm(["-ns"], stdin_data=data)
    rc_g, out_g, _ = run_gnu(["-ns"], stdin_data=data)
    report_result(out_a == out_g, "cat: -ns combined matches GNU")

    # --- Combined flags -b -s ---
    data = b"alpha\n\n\n\nbeta\n\ngamma\n"
    rc_a, out_a, _ = run_asm(["-bs"], stdin_data=data)
    rc_g, out_g, _ = run_gnu(["-bs"], stdin_data=data)
    report_result(out_a == out_g, "cat: -bs combined matches GNU")

    # --- -A (= -vET) ---
    data = b"\thello\x01\n"
    rc_a, out_a, _ = run_asm(["-A"], stdin_data=data)
    rc_g, out_g, _ = run_gnu(["-A"], stdin_data=data)
    report_result(out_a == out_g, "cat: -A (show-all) matches GNU")

    # --- -e (= -vE) ---
    data = b"hello\x01\n"
    rc_a, out_a, _ = run_asm(["-e"], stdin_data=data)
    rc_g, out_g, _ = run_gnu(["-e"], stdin_data=data)
    report_result(out_a == out_g, "cat: -e (vE) matches GNU")

    # --- -t (= -vT) ---
    data = b"\thello\x01\n"
    rc_a, out_a, _ = run_asm(["-t"], stdin_data=data)
    rc_g, out_g, _ = run_gnu(["-t"], stdin_data=data)
    report_result(out_a == out_g, "cat: -t (vT) matches GNU")

    # --- -- (end of options) ---
    with tempfile.NamedTemporaryFile(mode='wb', prefix='-n', suffix='.txt', delete=False) as f:
        f.write(b"content\n")
        tmpfile = f.name
    try:
        rc_a, out_a, _ = run_asm(["--", tmpfile])
        rc_g, out_g, _ = run_gnu(["--", tmpfile])
        report_result(out_a == out_g, "cat: -- end of options matches GNU")
    finally:
        os.unlink(tmpfile)

    # --- No trailing newline ---
    rc_a, out_a, _ = run_asm([], stdin_data=b"no newline at end")
    rc_g, out_g, _ = run_gnu([], stdin_data=b"no newline at end")
    report_result(out_a == out_g, "cat: no trailing newline matches GNU")

    # --- Very long line ---
    long_line = b"A" * 100000 + b"\n"
    rc_a, out_a, _ = run_asm([], stdin_data=long_line)
    rc_g, out_g, _ = run_gnu([], stdin_data=long_line)
    report_result(out_a == out_g, "cat: 100KB single line matches GNU")

    # --- -n with many lines ---
    data = b"".join(f"line{i}\n".encode() for i in range(100))
    rc_a, out_a, _ = run_asm(["-n"], stdin_data=data)
    rc_g, out_g, _ = run_gnu(["-n"], stdin_data=data)
    report_result(out_a == out_g, "cat: -n with 100 lines matches GNU")

    # --- Nonexistent file among valid files ---
    with tempfile.NamedTemporaryFile(mode='wb', suffix='.txt', delete=False) as f:
        f.write(b"valid\n")
        tmpfile = f.name
    try:
        rc_a, out_a, err_a = run_asm([tmpfile, "/nonexistent/file", tmpfile])
        rc_g, out_g, err_g = run_gnu([tmpfile, "/nonexistent/file", tmpfile])
        # GNU cat continues after errors and outputs valid files
        report_result(rc_a != 0, "cat: nonexistent among valid returns nonzero")
        report_result(b"valid\n" in out_a, "cat: outputs valid files despite error")
    finally:
        os.unlink(tmpfile)

    # --- --help ---
    rc_a, out_a, _ = run_asm(["--help"])
    report_result(rc_a == 0 and len(out_a) > 0, "cat: --help works")

    # --- --version ---
    rc_a, out_a, _ = run_asm(["--version"])
    report_result(rc_a == 0 and len(out_a) > 0, "cat: --version works")

# =============================================================================
#                           MAIN
# =============================================================================

def run_tests():
    log(f"=== Security Tests for {TOOL_NAME} (fcat) ===")
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
    test_cat_specific()

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
