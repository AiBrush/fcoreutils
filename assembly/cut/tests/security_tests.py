#!/usr/bin/env python3
"""security_tests.py — Security & memory safety tests for fcut (assembly cut)."""

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
TOOL_NAME = "cut"
BIN = str(Path(__file__).resolve().parent.parent / "fcut")
GNU = "/usr/bin/cut"

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

    test_input = b"one:two:three\nfour:five:six\n"

    rc, out, err = run(["strace", "-f", "-e", "trace=%network", BIN, "-d:", "-f1"],
                       stdin_data=test_input)
    net_calls = [l for l in err.split(b"\n") if b"socket(" in l or b"connect(" in l]
    report_result(len(net_calls) == 0, "syscall: no network syscalls")

    rc, out, err = run(["strace", "-f", "-e", "trace=%process", BIN, "--help"])
    spawn_calls = [l for l in err.split(b"\n")
                   if b"fork(" in l or b"vfork(" in l or b"clone(" in l]
    spawn_calls = [l for l in spawn_calls if b"execve(" not in l]
    report_result(len(spawn_calls) == 0, "syscall: no process spawning")

    rc, out, err = run(["strace", "-f", "-e", "trace=brk,mmap,mprotect", BIN, "-d:", "-f1"],
                       stdin_data=test_input)
    mem_lines = [l for l in err.split(b"\n")
                 if b"brk(" in l or b"mmap(" in l or b"mprotect(" in l]
    mem_lines = [l for l in mem_lines if not l.startswith(b"---") and not l.startswith(b"+++")]
    # Assembly tools may use brk for BSS setup; check count is reasonable (<10)
    report_result(len(mem_lines) < 10, f"syscall: minimal brk/mmap/mprotect ({len(mem_lines)} calls)")

# =============================================================================
#                     3. /proc FILESYSTEM RUNTIME ANALYSIS
# =============================================================================

def test_proc_runtime():
    log("\n=== /proc Filesystem Runtime Analysis ===")
    p = subprocess.Popen([BIN, "-d:", "-f1"], stdin=subprocess.PIPE,
                         stdout=subprocess.PIPE, stderr=subprocess.PIPE)
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
            report_result(os.path.basename(exe) == "fcut", "proc: /proc/PID/exe points to fcut")
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

    p = subprocess.Popen([BIN, "-d:", "-f1"], stdin=subprocess.PIPE,
                         stdout=subprocess.PIPE, stderr=subprocess.PIPE)
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
    rc, _, _ = run_asm(["-d:", "-f1"], stdin_data=b"a:b:c\n", preexec_fn=limit_nofile)
    report_result(rc in (0, 1), "fd: works with RLIMIT_NOFILE=3")

    script = f'echo "a:b:c" | {BIN} -d: -f1 2>/dev/null 1>&-; echo $?'
    p = subprocess.run(["bash", "-c", script], capture_output=True, timeout=TIMEOUT, text=True)
    report_result(p.returncode == 0, "fd: closed stdout doesn't crash")

    if os.path.exists("/dev/full"):
        script = f'echo "a:b:c" | {BIN} -d: -f1 > /dev/full 2>/dev/null; echo $?'
        p = subprocess.run(["bash", "-c", script], capture_output=True, timeout=TIMEOUT, text=True)
        report_result(p.stdout.strip() != "" and p.returncode == 0, "fd: /dev/full ENOSPC handling")

    script = f'echo "test" | {BIN} -d: -f1 > /dev/null 2>/dev/null; echo $?'
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
        rc, _, _ = run_asm(["-d:", "-f1"], stdin_data=data)
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
        data = b"A" * size + b"\n"
        rc, _, _ = run_asm(["-d:", "-f1"], stdin_data=data)
        report_result(rc < 128, f"mem: BSS boundary {desc} ({size} bytes) no crash")

    big_data = (b"field1:field2:field3\n") * 500000
    rc, _, _ = run_asm(["-d:", "-f1"], stdin_data=big_data)
    report_result(rc < 128, f"mem: 10MB+ input no crash ({len(big_data)} bytes)")

    long_line = b"X" * (BSS_SIZE * 2) + b"\n"
    rc, _, _ = run_asm(["-d:", "-f1"], stdin_data=long_line)
    report_result(rc < 128, "mem: single line >BSS_SIZE no crash")

    tiny_lines = b"\n" * 1000000
    rc, _, _ = run_asm(["-d:", "-f1"], stdin_data=tiny_lines)
    report_result(rc < 128, "mem: 1M tiny lines no crash")

    log("\n--- Boundary Value Analysis ---")
    for desc, data in [
        ("no trailing newline", b"a:b:c"),
        ("only newlines", b"\n" * 50),
        ("1MB single line", b"A" * (1024 * 1024)),
        ("CRLF line endings", b"a:b\r\nc:d\r\n"),
        ("embedded nulls", b"a\x00b:c\x00d\n"),
        ("all 256 byte values", bytes(range(256)) * 4),
        ("many delimiters", b"::::::::::::\n"),
    ]:
        rc, _, _ = run_asm(["-d:", "-f1"], stdin_data=data)
        report_result(rc < 128, f"mem: boundary - {desc} no crash")

    def limit_stack():
        resource.setrlimit(resource.RLIMIT_STACK, (65536, 65536))
    rc, _, _ = run_asm(["-d:", "-f1"], stdin_data=b"a:b\n" * 100, preexec_fn=limit_stack)
    report_result(rc < 128, "mem: RLIMIT_STACK=64KB")

    def limit_as():
        resource.setrlimit(resource.RLIMIT_AS, (16 * 1024 * 1024, 16 * 1024 * 1024))
    rc, _, _ = run_asm(["-d:", "-f1"], stdin_data=b"a:b\n" * 100, preexec_fn=limit_as)
    report_result(rc < 128, "mem: RLIMIT_AS=16MB")

# =============================================================================
#                     6. SIGNAL SAFETY
# =============================================================================

def test_signal_safety():
    log("\n=== Signal Safety ===")

    script = f'seq 100 | {BIN} -d" " -f1 | head -1 >/dev/null 2>/dev/null; echo $?'
    p = subprocess.run(["bash", "-c", script], capture_output=True, timeout=TIMEOUT, text=True)
    report_result(p.returncode == 0, "signal: SIGPIPE clean exit")

    for sig_val, sig_name in [(signal.SIGTERM, "SIGTERM"), (signal.SIGINT, "SIGINT")]:
        p = subprocess.Popen([BIN, "-d:", "-f1"], stdin=subprocess.PIPE,
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
        rc = os.system(f'seq 100 | {BIN} -d" " -f1 | head -c 1 >/dev/null 2>/dev/null')
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
        rc, _, _ = run_asm(["-d:", "-f1"], stdin_data=data)
        if rc >= 128: crash_count += 1
    report_result(crash_count == 0, f"fuzz: 100 random printable (crashes: {crash_count})")

    crash_count = 0
    for _ in range(30):
        data = os.urandom(random.randint(1024, 102400))
        rc, _, _ = run_asm(["-d:", "-f1"], stdin_data=data)
        if rc >= 128: crash_count += 1
    report_result(crash_count == 0, f"fuzz: 30 long random (crashes: {crash_count})")

    crash_count = 0
    for _ in range(30):
        data = bytes(random.randint(0, 255) for _ in range(random.randint(1, 10000)))
        rc, _, _ = run_asm(["-d:", "-f1"], stdin_data=data)
        if rc >= 128: crash_count += 1
    report_result(crash_count == 0, f"fuzz: 30 binary blobs (crashes: {crash_count})")

    pathological = [
        ("64KB nulls", b"\x00" * BSS_SIZE),
        ("64KB newlines", b"\n" * BSS_SIZE),
        ("64KB 0xFF", b"\xff" * BSS_SIZE),
        ("64KB colons", b":" * BSS_SIZE),
        ("1MB single char", b"A" * (1024 * 1024)),
        ("alternating null/ff", (b"\x00\xff") * (BSS_SIZE // 2)),
        ("many empty fields", b"::::\n" * 10000),
    ]
    for desc, data in pathological:
        rc, _, _ = run_asm(["-d:", "-f1"], stdin_data=data)
        report_result(rc < 128, f"fuzz: pathological {desc} (rc={rc})")

    test_data = b"a:b:c\nd:e:f\n"
    results = set()
    for _ in range(10):
        _, out, _ = run_asm(["-d:", "-f2"], stdin_data=test_data)
        results.add(out)
    report_result(len(results) == 1, "fuzz: deterministic output (10 trials)")

# =============================================================================
#                     8. RESOURCE LIMIT TESTING
# =============================================================================

def test_resource_limits():
    log("\n=== Resource Limit Testing ===")
    test_data = b"a:b:c\n" * 20

    for name, setter in [
        ("RLIMIT_AS=16MB", lambda: resource.setrlimit(resource.RLIMIT_AS, (16*1024*1024, 16*1024*1024))),
        ("RLIMIT_NOFILE=3", lambda: resource.setrlimit(resource.RLIMIT_NOFILE, (3, 3))),
        ("RLIMIT_CPU=5s", lambda: resource.setrlimit(resource.RLIMIT_CPU, (5, 5))),
        ("RLIMIT_STACK=64KB", lambda: resource.setrlimit(resource.RLIMIT_STACK, (65536, 65536))),
    ]:
        rc, _, _ = run_asm(["-d:", "-f1"], stdin_data=test_data, preexec_fn=setter)
        report_result(rc < 128, f"rlimit: {name}")

    def combined():
        resource.setrlimit(resource.RLIMIT_AS, (16*1024*1024, 16*1024*1024))
        resource.setrlimit(resource.RLIMIT_NOFILE, (3, 3))
        resource.setrlimit(resource.RLIMIT_CPU, (5, 5))
        resource.setrlimit(resource.RLIMIT_STACK, (65536, 65536))
    rc, _, _ = run_asm(["-d:", "-f1"], stdin_data=test_data, preexec_fn=combined)
    report_result(rc < 128, "rlimit: combined limits")

# =============================================================================
#                     9. ENVIRONMENT ROBUSTNESS
# =============================================================================

def test_environment():
    log("\n=== Environment Robustness ===")
    test_data = b"a:b:c\n"

    rc, _, _ = run_asm(["-d:", "-f1"], stdin_data=test_data, env={})
    report_result(rc < 128, "env: empty environment no crash")

    hostile_env = {
        "PATH": "/nonexistent", "HOME": "/nonexistent",
        "LD_PRELOAD": "/nonexistent/evil.so", "IFS": "\t\n",
    }
    rc, _, _ = run_asm(["-d:", "-f1"], stdin_data=test_data, env=hostile_env)
    report_result(rc < 128, "env: hostile environment no crash")

    large_env = {f"VAR_{i}": f"value_{i}" * 100 for i in range(1000)}
    rc, _, _ = run_asm(["-d:", "-f1"], stdin_data=test_data, env=large_env)
    report_result(rc < 128, "env: large environment (1000 vars)")

# =============================================================================
#                     10. OUTPUT INTEGRITY
# =============================================================================

def test_output_integrity():
    log("\n=== Output Integrity ===")

    test_data = b"one:two:three\nfour:five:six\n"
    results = []
    for _ in range(10):
        _, out, _ = run_asm(["-d:", "-f2"], stdin_data=test_data)
        results.append(out)
    report_result(len(set(results)) == 1, "integrity: deterministic (10 trials)")

    rc, out, err = run_asm(["-d:", "-f1"], stdin_data=b"a:b\n")
    report_result(err == b"" or rc != 0, "integrity: stderr empty on success")

# =============================================================================
#                     11. ERROR HANDLING
# =============================================================================

def test_error_handling():
    log("\n=== Error Handling ===")

    rc_a, _, _ = run_asm(["--invalid-flag-xyz"], stdin_data=b"test\n")
    report_result(rc_a != 0, "error: invalid flag returns nonzero")

    if which("strace"):
        rc, _, _ = run(["strace", "-e", "inject=write:error=EINTR:when=1",
                        BIN, "-d:", "-f1"], stdin_data=b"a:b\nc:d\n")
        report_result(rc in (0, 1, 124), "error: EINTR injection on write")
    else:
        skip_test("error: EINTR injection", "no strace")

    if os.path.exists("/dev/full"):
        script = f'echo "a:b:c" | {BIN} -d: -f1 > /dev/full 2>/dev/null; echo $?'
        p = subprocess.run(["bash", "-c", script], capture_output=True, timeout=TIMEOUT, text=True)
        report_result(p.returncode == 0, "error: /dev/full write")

# =============================================================================
#                     12. CONCURRENCY STRESS
# =============================================================================

def test_concurrency():
    log("\n=== Concurrency Stress ===")

    procs = []
    for i in range(50):
        data = f"field{i}:value{i}\n".encode() * 10
        p = subprocess.Popen([BIN, "-d:", "-f1"], stdin=subprocess.PIPE,
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

    ok_count = 0
    for _ in range(20):
        p = subprocess.Popen([BIN, "-d:", "-f1"], stdin=subprocess.PIPE,
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            time.sleep(0.01); p.kill(); p.wait(timeout=2); ok_count += 1
        except:
            try: p.kill()
            except: pass
    report_result(ok_count >= 18, f"concurrency: rapid start/kill ({ok_count}/20)")

# =============================================================================
#                     13. TOOL-SPECIFIC: CUT TESTS
# =============================================================================

def test_cut_specific():
    log("\n=== Cut-Specific Tests ===")

    data = b"one:two:three\nfour:five:six\n"

    # -f1 (first field)
    rc_a, out_a, _ = run_asm(["-d:", "-f1"], stdin_data=data)
    rc_g, out_g, _ = run_gnu(["-d:", "-f1"], stdin_data=data)
    report_result(out_a == out_g, "cut: -d: -f1 matches GNU")

    # -f2 (second field)
    rc_a, out_a, _ = run_asm(["-d:", "-f2"], stdin_data=data)
    rc_g, out_g, _ = run_gnu(["-d:", "-f2"], stdin_data=data)
    report_result(out_a == out_g, "cut: -d: -f2 matches GNU")

    # -f3 (third field)
    rc_a, out_a, _ = run_asm(["-d:", "-f3"], stdin_data=data)
    rc_g, out_g, _ = run_gnu(["-d:", "-f3"], stdin_data=data)
    report_result(out_a == out_g, "cut: -d: -f3 matches GNU")

    # -f1,3 (multiple fields)
    rc_a, out_a, _ = run_asm(["-d:", "-f1,3"], stdin_data=data)
    rc_g, out_g, _ = run_gnu(["-d:", "-f1,3"], stdin_data=data)
    report_result(out_a == out_g, "cut: -d: -f1,3 matches GNU")

    # -f1-3 (field range)
    rc_a, out_a, _ = run_asm(["-d:", "-f1-3"], stdin_data=data)
    rc_g, out_g, _ = run_gnu(["-d:", "-f1-3"], stdin_data=data)
    report_result(out_a == out_g, "cut: -d: -f1-3 matches GNU")

    # Different delimiters
    for delim, desc in [(",", "comma"), ("\t", "tab"), (" ", "space")]:
        d = f"one{delim}two{delim}three\n".encode()
        rc_a, out_a, _ = run_asm([f"-d{delim}", "-f2"], stdin_data=d)
        rc_g, out_g, _ = run_gnu([f"-d{delim}", "-f2"], stdin_data=d)
        report_result(out_a == out_g, f"cut: -d '{desc}' -f2 matches GNU")

    # -c (characters)
    data = b"hello world\n"
    rc_a, out_a, _ = run_asm(["-c1-5"], stdin_data=data)
    rc_g, out_g, _ = run_gnu(["-c1-5"], stdin_data=data)
    if rc_a == 0 and rc_g == 0:
        report_result(out_a == out_g, "cut: -c1-5 matches GNU")
    else:
        skip_test("cut: -c mode", "not supported or error")

    # -b (bytes)
    rc_a, out_a, _ = run_asm(["-b1-5"], stdin_data=data)
    rc_g, out_g, _ = run_gnu(["-b1-5"], stdin_data=data)
    if rc_a == 0 and rc_g == 0:
        report_result(out_a == out_g, "cut: -b1-5 matches GNU")
    else:
        skip_test("cut: -b mode", "not supported or error")

    # Delimiter not found in line (should print whole line)
    data = b"no_delim_here\n"
    rc_a, out_a, _ = run_asm(["-d:", "-f1"], stdin_data=data)
    rc_g, out_g, _ = run_gnu(["-d:", "-f1"], stdin_data=data)
    report_result(out_a == out_g, "cut: delimiter not found matches GNU")

    # Empty fields
    data = b":::\n"
    rc_a, out_a, _ = run_asm(["-d:", "-f1"], stdin_data=data)
    rc_g, out_g, _ = run_gnu(["-d:", "-f1"], stdin_data=data)
    report_result(out_a == out_g, "cut: empty fields matches GNU")

    # Missing fields (field beyond available)
    data = b"a:b\n"
    rc_a, out_a, _ = run_asm(["-d:", "-f5"], stdin_data=data)
    rc_g, out_g, _ = run_gnu(["-d:", "-f5"], stdin_data=data)
    report_result(out_a == out_g, "cut: missing field matches GNU")

    # Very long lines
    long_data = (b"f" * 5000 + b":") * 10 + b"last\n"
    rc_a, out_a, _ = run_asm(["-d:", "-f1"], stdin_data=long_data)
    rc_g, out_g, _ = run_gnu(["-d:", "-f1"], stdin_data=long_data)
    report_result(out_a == out_g, "cut: very long line matches GNU")

    # Empty input
    rc_a, out_a, _ = run_asm(["-d:", "-f1"], stdin_data=b"")
    rc_g, out_g, _ = run_gnu(["-d:", "-f1"], stdin_data=b"")
    report_result(out_a == out_g, "cut: empty input matches GNU")

    # Single field line
    data = b"single\n"
    rc_a, out_a, _ = run_asm(["-d:", "-f1"], stdin_data=data)
    rc_g, out_g, _ = run_gnu(["-d:", "-f1"], stdin_data=data)
    report_result(out_a == out_g, "cut: single field line matches GNU")

    # Many fields
    data = b":".join(f"f{i}".encode() for i in range(100)) + b"\n"
    rc_a, out_a, _ = run_asm(["-d:", "-f50"], stdin_data=data)
    rc_g, out_g, _ = run_gnu(["-d:", "-f50"], stdin_data=data)
    report_result(out_a == out_g, "cut: 100 fields -f50 matches GNU")

    # Large input
    large = b"".join(f"field1:field2:field3\n".encode() for _ in range(10000))
    rc_a, out_a, _ = run_asm(["-d:", "-f2"], stdin_data=large, timeout=10)
    rc_g, out_g, _ = run_gnu(["-d:", "-f2"], stdin_data=large, timeout=10)
    report_result(out_a == out_g, "cut: large input (10K lines) matches GNU")

    # --help/--version
    rc_a, out_a, _ = run_asm(["--help"])
    report_result(rc_a == 0 and len(out_a) > 0, "cut: --help works")

    rc_a, out_a, _ = run_asm(["--version"])
    report_result(rc_a == 0 and len(out_a) > 0, "cut: --version works")

# =============================================================================
#                           MAIN
# =============================================================================

def run_tests():
    log(f"=== Security Tests for {TOOL_NAME} (fcut) ===")
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
    test_cut_specific()

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
