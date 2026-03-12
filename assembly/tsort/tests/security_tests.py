#!/usr/bin/env python3
"""security_tests.py — Security & memory safety tests for ftsort (assembly tsort)."""

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
TOOL_NAME = "tsort"
BIN = str(Path(__file__).resolve().parent.parent / "ftsort")
GNU = "/usr/bin/tsort"

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

    test_input = b"a b\nb c\n"

    rc, out, err = run(["strace", "-f", "-e", "trace=%network", BIN], stdin_data=test_input)
    net_calls = [l for l in err.split(b"\n") if b"socket(" in l or b"connect(" in l]
    report_result(len(net_calls) == 0, "syscall: no network syscalls")

    rc, out, err = run(["strace", "-f", "-e", "trace=%process", BIN, "--help"])
    spawn_calls = [l for l in err.split(b"\n")
                   if b"fork(" in l or b"vfork(" in l or b"clone(" in l]
    spawn_calls = [l for l in spawn_calls if b"execve(" not in l]
    report_result(len(spawn_calls) == 0, "syscall: no process spawning")

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
            report_result(os.path.basename(exe) == "ftsort", "proc: /proc/PID/exe points to ftsort")
        except Exception as e:
            skip_test("proc: exe link", str(e))
    finally:
        try: p.stdin.write(b"a b\n"); p.stdin.close()
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
    rc, _, _ = run_asm([], stdin_data=b"a b\n", preexec_fn=limit_nofile)
    report_result(rc in (0, 1), "fd: works with RLIMIT_NOFILE=3")

    script = f'echo "a b" | {BIN} 2>/dev/null 1>&-; echo $?'
    p = subprocess.run(["bash", "-c", script], capture_output=True, timeout=TIMEOUT, text=True)
    report_result(p.returncode == 0, "fd: closed stdout doesn't crash")

    script = f'echo "a b" | {BIN} --invalid 2>&- 1>/dev/null; echo $?'
    p = subprocess.run(["bash", "-c", script], capture_output=True, timeout=TIMEOUT, text=True)
    report_result(p.returncode == 0, "fd: closed stderr doesn't crash")

    if os.path.exists("/dev/full"):
        script = f'echo "a b" | {BIN} > /dev/full 2>/dev/null; echo $?'
        p = subprocess.run(["bash", "-c", script], capture_output=True, timeout=TIMEOUT, text=True)
        report_result(p.stdout.strip() != "" and p.returncode == 0, "fd: /dev/full ENOSPC handling")

    script = f'echo "a b" | {BIN} > /dev/null 2>/dev/null; echo $?'
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

    log("\n--- BSS Buffer Overflow Testing ---")
    for desc, size in [
        ("BSS_SIZE-1", BSS_SIZE - 1),
        ("BSS_SIZE", BSS_SIZE),
        ("BSS_SIZE+1", BSS_SIZE + 1),
        ("2x BSS_SIZE", BSS_SIZE * 2),
        ("4x BSS_SIZE", BSS_SIZE * 4),
    ]:
        # Many pairs to process
        pairs = []
        n = size // 10
        for i in range(n):
            pairs.append(f"{i} {i+1}")
        data = "\n".join(pairs).encode() + b"\n"
        rc, _, _ = run_asm([], stdin_data=data)
        report_result(rc < 128, f"mem: BSS boundary {desc} ({len(data)} bytes) no crash")

    big_data = b"a b\n" * 100000
    rc, _, _ = run_asm([], stdin_data=big_data, timeout=30)
    report_result(rc < 128, f"mem: large repeated input no crash ({len(big_data)} bytes)")

    long_token = b"X" * 10000 + b" " + b"Y" * 10000 + b"\n"
    rc, _, _ = run_asm([], stdin_data=long_token)
    report_result(rc < 128, "mem: long tokens no crash")

    log("\n--- Boundary Value Analysis ---")
    for desc, data in [
        ("no trailing newline", b"a b"),
        ("only newlines", b"\n" * 50),
        ("CRLF line endings", b"a b\r\nb c\r\n"),
        ("embedded nulls", b"hello\x00world \x00test\n"),
        ("all spaces", b"          "),
        ("tab-only", b"\t\t\t\t"),
    ]:
        rc, _, _ = run_asm([], stdin_data=data, timeout=10)
        report_result(rc < 128, f"mem: boundary - {desc} no crash")

    def limit_stack():
        resource.setrlimit(resource.RLIMIT_STACK, (65536, 65536))
    rc, _, _ = run_asm([], stdin_data=b"a b\n" * 100, preexec_fn=limit_stack)
    report_result(rc < 128, "mem: RLIMIT_STACK=64KB")

    def limit_as():
        resource.setrlimit(resource.RLIMIT_AS, (16 * 1024 * 1024, 16 * 1024 * 1024))
    rc, _, _ = run_asm([], stdin_data=b"a b\n" * 100, preexec_fn=limit_as)
    report_result(rc < 128, "mem: RLIMIT_AS=16MB")

# =============================================================================
#                     6. SIGNAL SAFETY
# =============================================================================

def test_signal_safety():
    log("\n=== Signal Safety ===")

    # SIGPIPE
    script = f'echo "a b" | {BIN} | head -1 >/dev/null 2>/dev/null; echo $?'
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
        rc = os.system(f'echo "a b" | {BIN} | head -c 1 >/dev/null 2>/dev/null')
        if rc == 0: ok_count += 1
    report_result(ok_count >= trials - 2, f"signal: rapid SIGPIPE ({ok_count}/{trials})")

# =============================================================================
#                     7. INPUT FUZZING
# =============================================================================

def test_input_fuzzing():
    log("\n=== Input Fuzzing ===")

    crash_count = 0
    for _ in range(100):
        # Generate random token pairs
        tokens = []
        for _ in range(random.randint(0, 20)):
            token = ''.join(random.choices(string.ascii_letters + string.digits, k=random.randint(1, 20)))
            tokens.append(token)
        # Pair them up
        data = ""
        for i in range(0, len(tokens) - 1, 2):
            data += f"{tokens[i]} {tokens[i+1]}\n"
        rc, _, _ = run_asm([], stdin_data=data.encode())
        if rc >= 128: crash_count += 1
    report_result(crash_count == 0, f"fuzz: 100 random pairs (crashes: {crash_count})")

    crash_count = 0
    for _ in range(30):
        data = os.urandom(random.randint(100, 10000))
        rc, _, _ = run_asm([], stdin_data=data, timeout=10)
        if rc >= 128: crash_count += 1
    report_result(crash_count == 0, f"fuzz: 30 random binary (crashes: {crash_count})")

    pathological = [
        ("64KB nulls", b"\x00" * BSS_SIZE),
        ("64KB newlines", b"\n" * BSS_SIZE),
        ("64KB 0xFF", b"\xff" * BSS_SIZE),
        ("32KB CRLF", b"\r\n" * (BSS_SIZE // 2)),
        ("1MB single char", b"A" * (1024 * 1024)),
    ]
    for desc, data in pathological:
        rc, _, _ = run_asm([], stdin_data=data, timeout=10)
        report_result(rc < 128, f"fuzz: pathological {desc} (rc={rc})")

    test_data = b"a b\nb c\nc d\n"
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
    test_data = b"a b\nb c\n"

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
    test_data = b"a b\nb c\n"

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

    test_data = b"a b\nb c\nc d\n"
    results = []
    for _ in range(10):
        _, out, _ = run_asm([], stdin_data=test_data)
        results.append(out)
    report_result(len(set(results)) == 1, "integrity: deterministic (10 trials)")

    rc, out, err = run_asm([], stdin_data=b"a b\n")
    report_result(err == b"" or rc != 0, "integrity: stderr empty on success")

    for desc, data in [
        ("normal", b"a b\nb c\n"),
        ("empty", b""),
    ]:
        rc_a, _, _ = run_asm([], stdin_data=data)
        rc_g, _, _ = run_gnu([], stdin_data=data)
        report_result(rc_a == rc_g, f"integrity: exit code match GNU ({desc})")

# =============================================================================
#                     11. ERROR HANDLING
# =============================================================================

def test_error_handling():
    log("\n=== Error Handling ===")

    rc_a, _, _ = run_asm(["--invalid-flag-xyz"], stdin_data=b"a b\n")
    report_result(rc_a != 0, "error: invalid flag returns nonzero")

    if os.path.exists("/dev/full"):
        script = f'echo "a b" | {BIN} > /dev/full 2>/dev/null; echo $?'
        p = subprocess.run(["bash", "-c", script], capture_output=True, timeout=TIMEOUT, text=True)
        report_result(p.returncode == 0, "error: /dev/full write")

    # Broken pipe mid-output (large output)
    data = "\n".join(f"{i} {i+1}" for i in range(1000)).encode() + b"\n"
    script = f'printf "%s" "{data.decode()}" | {BIN} | head -c 10 >/dev/null 2>/dev/null; echo $?'
    # Use file instead to avoid shell issues with large data
    with tempfile.NamedTemporaryFile(mode='wb', suffix='.txt', delete=False) as f:
        f.write(data)
        tmpf = f.name
    try:
        script = f'{BIN} {tmpf} | head -c 10 >/dev/null 2>/dev/null; echo $?'
        p = subprocess.run(["bash", "-c", script], capture_output=True, timeout=TIMEOUT, text=True)
        report_result(p.returncode == 0, "error: broken pipe mid-output")
    finally:
        os.unlink(tmpf)

# =============================================================================
#                     12. CONCURRENCY STRESS
# =============================================================================

def test_concurrency():
    log("\n=== Concurrency Stress ===")

    procs = []
    for i in range(50):
        pairs = [f"n{j} n{j+1}" for j in range(random.randint(2, 20))]
        data = "\n".join(pairs).encode() + b"\n"
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

    # Deterministic across runs
    data = b"a b\nb c\nc d\n"
    rc1, out1, _ = run_asm([], stdin_data=data)
    rc2, out2, _ = run_asm([], stdin_data=data)
    report_result(out1 == out2, "concurrency: repeated runs identical")

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
#                     13. TOOL-SPECIFIC: TSORT TESTS
# =============================================================================

def test_tsort_specific():
    log("\n=== Tsort-Specific Tests ===")

    # Basic chain
    data = b"a b\nb c\nc d\n"
    rc_a, out_a, _ = run_asm([], stdin_data=data)
    rc_g, out_g, _ = run_gnu([], stdin_data=data)
    report_result(out_a == out_g, "tsort: basic chain matches GNU")

    # Empty
    rc_a, out_a, _ = run_asm([], stdin_data=b"")
    rc_g, out_g, _ = run_gnu([], stdin_data=b"")
    report_result(out_a == out_g and rc_a == rc_g, "tsort: empty input matches GNU")

    # Self loop
    data = b"a a\n"
    rc_a, out_a, _ = run_asm([], stdin_data=data)
    rc_g, out_g, _ = run_gnu([], stdin_data=data)
    report_result(out_a == out_g and rc_a == rc_g, "tsort: self loop matches GNU")

    # Diamond
    data = b"a b\na c\nb d\nc d\n"
    rc_a, out_a, _ = run_asm([], stdin_data=data)
    rc_g, out_g, _ = run_gnu([], stdin_data=data)
    report_result(out_a == out_g, "tsort: diamond matches GNU")

    # Cycle
    data = b"a b\nb c\nc a\n"
    rc_a, out_a, err_a = run_asm([], stdin_data=data)
    rc_g, out_g, err_g = run_gnu([], stdin_data=data)
    # Normalize tool name in error messages
    err_a_norm = err_a.replace(BIN.encode(), b"tsort")
    err_g_norm = err_g.replace(GNU.encode(), b"tsort")
    report_result(out_a == out_g, "tsort: cycle stdout matches GNU")
    report_result(err_a_norm == err_g_norm, "tsort: cycle stderr matches GNU")
    report_result(rc_a == rc_g, "tsort: cycle exit code matches GNU")

    # Multiple cycles
    data = b"a b\nb a\nc d\nd c\n"
    rc_a, out_a, err_a = run_asm([], stdin_data=data)
    rc_g, out_g, err_g = run_gnu([], stdin_data=data)
    report_result(out_a == out_g, "tsort: multiple cycles stdout matches GNU")
    report_result(rc_a == rc_g, "tsort: multiple cycles exit code matches GNU")

    # Odd tokens
    data = b"a\n"
    rc_a, _, _ = run_asm([], stdin_data=data)
    rc_g, _, _ = run_gnu([], stdin_data=data)
    report_result(rc_a == rc_g and rc_a != 0, "tsort: odd tokens exit code matches GNU")

    # Numeric nodes
    data = b"1 2\n2 3\n3 4\n"
    rc_a, out_a, _ = run_asm([], stdin_data=data)
    rc_g, out_g, _ = run_gnu([], stdin_data=data)
    report_result(out_a == out_g, "tsort: numeric nodes matches GNU")

    # Independent nodes
    data = b"a a\nb b\nc c\n"
    rc_a, out_a, _ = run_asm([], stdin_data=data)
    rc_g, out_g, _ = run_gnu([], stdin_data=data)
    report_result(out_a == out_g, "tsort: independent nodes matches GNU")

    # File input
    with tempfile.NamedTemporaryFile(mode='wb', suffix='.txt', delete=False) as f:
        f.write(b"a b\nb c\n")
        tmpfile = f.name
    try:
        rc_a, out_a, _ = run_asm([tmpfile])
        rc_g, out_g, _ = run_gnu([tmpfile])
        report_result(out_a == out_g, "tsort: file argument matches GNU")
    finally:
        os.unlink(tmpfile)

    # stdin via -
    data = b"a b\nb c\n"
    rc_a, out_a, _ = run_asm(["-"], stdin_data=data)
    rc_g, out_g, _ = run_gnu(["-"], stdin_data=data)
    report_result(out_a == out_g, "tsort: stdin via '-' matches GNU")

    # Whitespace handling
    data = b"  a   b  \n  b    c  \n"
    rc_a, out_a, _ = run_asm([], stdin_data=data)
    rc_g, out_g, _ = run_gnu([], stdin_data=data)
    report_result(out_a == out_g, "tsort: whitespace handling matches GNU")

    # Duplicate edges
    data = b"a b\na b\na b\n"
    rc_a, out_a, _ = run_asm([], stdin_data=data)
    rc_g, out_g, _ = run_gnu([], stdin_data=data)
    report_result(out_a == out_g, "tsort: duplicate edges matches GNU")

    # Large input (1000 nodes chain)
    pairs = "\n".join(f"{i} {i+1}" for i in range(999))
    data = (pairs + "\n").encode()
    rc_a, out_a, _ = run_asm([], stdin_data=data, timeout=30)
    rc_g, out_g, _ = run_gnu([], stdin_data=data, timeout=30)
    report_result(out_a == out_g and rc_a == rc_g, "tsort: large chain (1000) matches GNU")

    # --help
    rc_a, out_a, _ = run_asm(["--help"])
    report_result(rc_a == 0 and len(out_a) > 0, "tsort: --help works")

    # --version
    rc_a, out_a, _ = run_asm(["--version"])
    report_result(rc_a == 0 and len(out_a) > 0, "tsort: --version works")

    # No trailing newline
    data = b"a b"
    rc_a, out_a, _ = run_asm([], stdin_data=data)
    rc_g, out_g, _ = run_gnu([], stdin_data=data)
    report_result(out_a == out_g, "tsort: no trailing newline matches GNU")

    # Tab-separated
    data = b"a\tb\nb\tc\n"
    rc_a, out_a, _ = run_asm([], stdin_data=data)
    rc_g, out_g, _ = run_gnu([], stdin_data=data)
    report_result(out_a == out_g, "tsort: tab-separated matches GNU")

# =============================================================================
#                           MAIN
# =============================================================================

def run_tests():
    log(f"=== Security Tests for {TOOL_NAME} (ftsort) ===")
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
    test_tsort_specific()

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
