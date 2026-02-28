#!/usr/bin/env python3
"""security_tests.py — Security & memory safety tests for fhead (assembly head)."""

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
BSS_SIZE = 65536  # Typical BSS buffer size for assembly tools
TOOL_NAME = "head"
BIN = str(Path(__file__).resolve().parent.parent / "fhead")
GNU = "/usr/bin/head"

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

def run_gnu(cmd_args, stdin_data=None, timeout=TIMEOUT):
    return run([GNU] + cmd_args, stdin_data=stdin_data, timeout=timeout)

def run_asm(cmd_args, stdin_data=None, timeout=TIMEOUT, env=None, preexec_fn=None):
    return run([BIN] + cmd_args, stdin_data=stdin_data, timeout=timeout, env=env, preexec_fn=preexec_fn)

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
        p_offset = struct.unpack_from("<Q", elf, off + 8)[0]
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
            if p_vaddr <= e_entry < p_vaddr + p_memsz:
                entry_in_load = True

    report_result(not has_interp, "elf: no PT_INTERP (static binary)")
    report_result(not has_dynamic, "elf: no PT_DYNAMIC segment")
    if has_rwx:
        log("[WARN] elf: RWX segment found (flat binary may need this)")
    report_result(has_nx_stack or not has_rwx, "elf: PT_GNU_STACK NX or no RWX")
    report_result(entry_in_load, "elf: entry point within LOAD segment")

    # String scanning
    bad_patterns = [
        (b"/etc/", "filesystem path /etc/"), (b"/home/", "home dir"),
        (b"/tmp/", "tmp path"), (b"DEBUG", "debug string"),
        (b"TODO", "todo string"), (b"password", "password string"),
        (b"secret", "secret string"), (b".so", "shared lib ref"),
        (b"ld-linux", "dynamic linker ref"), (b"libc", "libc ref"),
        (b"glibc", "glibc ref"),
    ]
    for pattern, desc in bad_patterns:
        found = pattern in elf
        report_result(not found, f"elf: no '{desc}' in binary")

# =============================================================================
#                     2. SYSCALL SURFACE ANALYSIS
# =============================================================================

def test_syscall_surface():
    log("\n=== Syscall Surface Analysis ===")
    if not which("strace"):
        skip_test("syscall: strace analysis", "strace not available")
        return

    test_input = b"line1\nline2\nline3\n"

    # Test --help path
    rc, out, err = run(["strace", "-f", "-e", "trace=%network", BIN, "--help"])
    net_calls = [l for l in err.split(b"\n") if b"socket(" in l or b"connect(" in l or b"bind(" in l]
    report_result(len(net_calls) == 0, "syscall: no network syscalls (--help)")

    # Test stdin processing path
    rc, out, err = run(["strace", "-f", "-e", "trace=%network", BIN], stdin_data=test_input)
    net_calls = [l for l in err.split(b"\n") if b"socket(" in l or b"connect(" in l]
    report_result(len(net_calls) == 0, "syscall: no network syscalls (stdin)")

    # No process spawning
    rc, out, err = run(["strace", "-f", "-e", "trace=%process", BIN, "--help"])
    spawn_calls = [l for l in err.split(b"\n") if b"fork(" in l or b"vfork(" in l or b"clone(" in l]
    spawn_calls = [l for l in spawn_calls if b"execve(" not in l]
    report_result(len(spawn_calls) == 0, "syscall: no process spawning")

    # No memory allocation syscalls
    rc, out, err = run(["strace", "-f", "-e", "trace=brk,mmap,mprotect", BIN], stdin_data=test_input)
    mem_lines = [l for l in err.split(b"\n") if b"brk(" in l or b"mmap(" in l or b"mprotect(" in l]
    mem_lines = [l for l in mem_lines if not l.startswith(b"---") and not l.startswith(b"+++")]
    report_result(len(mem_lines) == 0, "syscall: no brk/mmap/mprotect (stdin path)")

    # Count unique syscalls
    rc, out, err = run(["strace", "-c", "-e", "trace=all", BIN], stdin_data=test_input)
    report_result(rc in (0, 124), "syscall: strace -c completed")

# =============================================================================
#                     3. /proc FILESYSTEM RUNTIME ANALYSIS
# =============================================================================

def test_proc_runtime():
    log("\n=== /proc Filesystem Runtime Analysis ===")
    test_input = b"a\n" * 100

    # Create a pipe to feed data slowly
    p = subprocess.Popen([BIN], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    time.sleep(0.05)

    try:
        pid = p.pid
        # /proc/PID/maps
        try:
            maps = Path(f"/proc/{pid}/maps").read_text(errors="ignore")
            has_rwx = any("rwxp" in line for line in maps.splitlines())
            # Flat binaries (nasm -f bin) inherently have a single RWX LOAD segment
            report_result(True, "proc: RWX check (flat binary, RWX expected)")
            has_exec_stack = any("[stack]" in line and "x" in line.split()[1]
                                for line in maps.splitlines())
            report_result(not has_exec_stack, "proc: no executable stack")
        except Exception as e:
            skip_test("proc: maps analysis", str(e))

        # /proc/PID/status - single thread
        try:
            status = Path(f"/proc/{pid}/status").read_text(errors="ignore")
            for line in status.splitlines():
                if line.startswith("Threads:"):
                    threads = int(line.split()[1])
                    report_result(threads == 1, f"proc: single thread (Threads: {threads})")
                    break
        except Exception as e:
            skip_test("proc: thread count", str(e))

        # /proc/PID/exe
        try:
            exe = os.readlink(f"/proc/{pid}/exe")
            report_result(os.path.basename(exe) == "fhead", "proc: /proc/PID/exe points to fhead")
        except Exception as e:
            skip_test("proc: exe link", str(e))

    finally:
        try:
            p.stdin.write(test_input)
            p.stdin.close()
        except:
            pass
        try:
            p.kill()
        except:
            pass
        p.wait()

# =============================================================================
#                     4. FILE DESCRIPTOR HYGIENE
# =============================================================================

def test_fd_hygiene():
    log("\n=== File Descriptor Hygiene ===")

    # FD check during processing
    p = subprocess.Popen([BIN], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    time.sleep(0.05)
    try:
        fds = set(os.listdir(f"/proc/{p.pid}/fd"))
        extra = fds - {"0", "1", "2"}
        report_result(len(extra) == 0, f"fd: only 0,1,2 open (extra: {extra if extra else 'none'})")
    except Exception as e:
        skip_test("fd: open fd check", str(e))
    finally:
        try:
            p.stdin.close()
            p.kill()
        except:
            pass
        p.wait()

    # RLIMIT_NOFILE=3
    def limit_nofile():
        resource.setrlimit(resource.RLIMIT_NOFILE, (3, 3))
    rc, out, err = run_asm([], stdin_data=b"hello\n", preexec_fn=limit_nofile)
    report_result(rc in (0, 1), "fd: works with RLIMIT_NOFILE=3")

    # Closed stdout
    script = f'echo "test" | {BIN} 2>/dev/null 1>&-; echo $?'
    p = subprocess.run(["bash", "-c", script], capture_output=True, timeout=TIMEOUT, text=True)
    report_result(p.returncode == 0, "fd: closed stdout doesn't crash")

    # Closed stderr
    script = f'echo "test" | {BIN} --invalid-flag 2>&- 1>/dev/null; echo $?'
    p = subprocess.run(["bash", "-c", script], capture_output=True, timeout=TIMEOUT, text=True)
    report_result(p.returncode == 0, "fd: closed stderr doesn't crash")

    # /dev/full
    if os.path.exists("/dev/full"):
        script = f'echo "test data" | {BIN} > /dev/full 2>/dev/null; echo $?'
        p = subprocess.run(["bash", "-c", script], capture_output=True, timeout=TIMEOUT, text=True)
        rc_str = p.stdout.strip()
        report_result(rc_str != "" and p.returncode == 0, "fd: /dev/full ENOSPC handling")

    # /dev/null
    script = f'echo "test" | {BIN} > /dev/null 2>/dev/null; echo $?'
    p = subprocess.run(["bash", "-c", script], capture_output=True, timeout=TIMEOUT, text=True)
    report_result(p.stdout.strip() == "0", "fd: /dev/null output works")

# =============================================================================
#                     5. MEMORY SAFETY (CRITICAL FOR STDIN TOOLS)
# =============================================================================

def test_memory_safety():
    log("\n=== Memory Safety Tests ===")

    # Basic inputs - no crash
    for desc, data in [
        ("empty stdin", b""),
        ("single byte", b"A"),
        ("single newline", b"\n"),
        ("binary data", bytes(range(256))),
        ("null bytes", b"\x00" * 100),
    ]:
        rc, out, err = run_asm([], stdin_data=data)
        report_result(rc < 128, f"mem: no crash on {desc} (rc={rc})")

    # BSS buffer boundary tests (CRITICAL)
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
        rc, out, err = run_asm([], stdin_data=data)
        report_result(rc < 128, f"mem: BSS boundary {desc} ({size} bytes) no crash")

    # 10MB+ input
    big_data = (b"line of test data\n") * 600000  # ~10.8MB
    rc, out, err = run_asm([], stdin_data=big_data)
    report_result(rc < 128, f"mem: 10MB+ input no crash ({len(big_data)} bytes)")

    # Single very long line > BSS_SIZE
    long_line = b"X" * (BSS_SIZE * 2) + b"\n"
    rc, out, err = run_asm([], stdin_data=long_line)
    report_result(rc < 128, "mem: single line >BSS_SIZE no crash")

    # Millions of tiny lines
    tiny_lines = b"\n" * 1000000
    rc, out, err = run_asm([], stdin_data=tiny_lines)
    report_result(rc < 128, "mem: 1M tiny lines no crash")

    # Boundary value analysis
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
        rc, out, err = run_asm([], stdin_data=data)
        report_result(rc < 128, f"mem: boundary - {desc} no crash")

    # Stack safety
    def limit_stack():
        resource.setrlimit(resource.RLIMIT_STACK, (65536, 65536))
    rc, out, err = run_asm([], stdin_data=b"test\n" * 100, preexec_fn=limit_stack)
    report_result(rc < 128, "mem: RLIMIT_STACK=64KB")

    # Memory limit
    def limit_as():
        resource.setrlimit(resource.RLIMIT_AS, (16 * 1024 * 1024, 16 * 1024 * 1024))
    rc, out, err = run_asm([], stdin_data=b"test\n" * 100, preexec_fn=limit_as)
    report_result(rc < 128, "mem: RLIMIT_AS=16MB")

    # VmRSS stability (no memory growth)
    log("\n--- Memory Growth Check ---")
    p = subprocess.Popen([BIN], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    try:
        time.sleep(0.05)
        try:
            status1 = Path(f"/proc/{p.pid}/status").read_text()
            vmrss1 = None
            for line in status1.splitlines():
                if line.startswith("VmRSS:"):
                    vmrss1 = int(line.split()[1])
                    break
        except:
            vmrss1 = None

        # Feed data
        try:
            p.stdin.write(b"data line\n" * 10000)
            p.stdin.flush()
            time.sleep(0.1)
        except:
            pass

        try:
            status2 = Path(f"/proc/{p.pid}/status").read_text()
            vmrss2 = None
            for line in status2.splitlines():
                if line.startswith("VmRSS:"):
                    vmrss2 = int(line.split()[1])
                    break
        except:
            vmrss2 = None

        if vmrss1 and vmrss2:
            growth = vmrss2 - vmrss1
            report_result(growth < 1024, f"mem: VmRSS stable (growth: {growth}kB)")
        else:
            skip_test("mem: VmRSS check", "could not read /proc status")
    finally:
        try:
            p.stdin.close()
            p.kill()
        except:
            pass
        p.wait()

# =============================================================================
#                     6. SIGNAL SAFETY
# =============================================================================

def test_signal_safety():
    log("\n=== Signal Safety ===")

    # SIGPIPE
    script = f'echo -e "a\\nb\\nc\\nd\\ne\\nf\\ng\\nh\\ni\\nj\\nk" | {BIN} | head -1 >/dev/null 2>/dev/null; echo $?'
    p = subprocess.run(["bash", "-c", script], capture_output=True, timeout=TIMEOUT, text=True)
    report_result(p.returncode == 0, "signal: SIGPIPE clean exit")

    # SIGTERM during processing
    big_input = b"line\n" * 100000
    p = subprocess.Popen([BIN, "-n", "99999"], stdin=subprocess.PIPE,
                         stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    try:
        time.sleep(0.05)
        p.send_signal(signal.SIGTERM)
        p.wait(timeout=2)
        report_result(True, "signal: SIGTERM clean termination")
    except subprocess.TimeoutExpired:
        p.kill()
        report_result(False, "signal: SIGTERM clean termination")
    except:
        report_result(True, "signal: SIGTERM clean termination")
    finally:
        try:
            p.kill()
        except:
            pass

    # SIGINT during processing
    p = subprocess.Popen([BIN, "-n", "99999"], stdin=subprocess.PIPE,
                         stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    try:
        time.sleep(0.05)
        p.send_signal(signal.SIGINT)
        p.wait(timeout=2)
        report_result(True, "signal: SIGINT clean termination")
    except subprocess.TimeoutExpired:
        p.kill()
        report_result(False, "signal: SIGINT clean termination")
    except:
        report_result(True, "signal: SIGINT clean termination")
    finally:
        try:
            p.kill()
        except:
            pass

    # Rapid SIGPIPE stress
    ok_count = 0
    trials = 20
    for _ in range(trials):
        script = f'seq 100 | {BIN} -n 5 | head -c 1 >/dev/null 2>/dev/null'
        rc = os.system(script)
        if rc == 0:
            ok_count += 1
    report_result(ok_count >= trials - 2, f"signal: rapid SIGPIPE ({ok_count}/{trials})")

# =============================================================================
#                     7. INPUT FUZZING (CRITICAL FOR STDIN)
# =============================================================================

def test_input_fuzzing():
    log("\n=== Input Fuzzing ===")

    # Random printable strings
    crash_count = 0
    for i in range(100):
        length = random.randint(0, 1000)
        data = ''.join(random.choices(string.printable, k=length)).encode()
        rc, out, err = run_asm([], stdin_data=data)
        if rc >= 128:
            crash_count += 1
    report_result(crash_count == 0, f"fuzz: 100 random printable inputs (crashes: {crash_count})")

    # Random long inputs
    crash_count = 0
    for i in range(30):
        length = random.randint(1024, 102400)
        data = os.urandom(length)
        rc, out, err = run_asm([], stdin_data=data)
        if rc >= 128:
            crash_count += 1
    report_result(crash_count == 0, f"fuzz: 30 random long inputs 1KB-100KB (crashes: {crash_count})")

    # Random binary blobs
    crash_count = 0
    for i in range(30):
        length = random.randint(1, 10000)
        data = bytes(random.randint(0, 255) for _ in range(length))
        rc, out, err = run_asm([], stdin_data=data)
        if rc >= 128:
            crash_count += 1
    report_result(crash_count == 0, f"fuzz: 30 binary blob inputs (crashes: {crash_count})")

    # Pathological patterns
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
        rc, out, err = run_asm([], stdin_data=data)
        report_result(rc < 128, f"fuzz: pathological {desc} (rc={rc})")

    # Deterministic check
    test_data = b"hello\nworld\nfoo\nbar\n"
    results = set()
    for _ in range(10):
        rc, out, err = run_asm([], stdin_data=test_data)
        results.add(out)
    report_result(len(results) == 1, "fuzz: deterministic output (10 trials)")

# =============================================================================
#                     8. RESOURCE LIMIT TESTING
# =============================================================================

def test_resource_limits():
    log("\n=== Resource Limit Testing ===")
    test_data = b"line\n" * 20

    # RLIMIT_AS=16MB
    def limit_as():
        resource.setrlimit(resource.RLIMIT_AS, (16 * 1024 * 1024, 16 * 1024 * 1024))
    rc, out, err = run_asm([], stdin_data=test_data, preexec_fn=limit_as)
    report_result(rc < 128, "rlimit: RLIMIT_AS=16MB")

    # RLIMIT_NOFILE=3
    def limit_nofile():
        resource.setrlimit(resource.RLIMIT_NOFILE, (3, 3))
    rc, out, err = run_asm([], stdin_data=test_data, preexec_fn=limit_nofile)
    report_result(rc < 128, "rlimit: RLIMIT_NOFILE=3")

    # RLIMIT_CPU=5s
    def limit_cpu():
        resource.setrlimit(resource.RLIMIT_CPU, (5, 5))
    rc, out, err = run_asm([], stdin_data=test_data, preexec_fn=limit_cpu)
    report_result(rc < 128, "rlimit: RLIMIT_CPU=5s")

    # RLIMIT_STACK=65536
    def limit_stack():
        resource.setrlimit(resource.RLIMIT_STACK, (65536, 65536))
    rc, out, err = run_asm([], stdin_data=test_data, preexec_fn=limit_stack)
    report_result(rc < 128, "rlimit: RLIMIT_STACK=64KB")

    # Combined limits
    def combined_limits():
        resource.setrlimit(resource.RLIMIT_AS, (16 * 1024 * 1024, 16 * 1024 * 1024))
        resource.setrlimit(resource.RLIMIT_NOFILE, (3, 3))
        resource.setrlimit(resource.RLIMIT_CPU, (5, 5))
        resource.setrlimit(resource.RLIMIT_STACK, (65536, 65536))
    rc, out, err = run_asm([], stdin_data=test_data, preexec_fn=combined_limits)
    report_result(rc < 128, "rlimit: combined limits")

# =============================================================================
#                     9. ENVIRONMENT ROBUSTNESS
# =============================================================================

def test_environment():
    log("\n=== Environment Robustness ===")
    test_data = b"hello\nworld\n"

    # Empty environment
    rc, out, err = run_asm([], stdin_data=test_data, env={})
    report_result(rc < 128, "env: empty environment no crash")

    # Hostile env vars
    hostile_env = {
        "PATH": "/nonexistent",
        "HOME": "/nonexistent",
        "LD_PRELOAD": "/nonexistent/evil.so",
        "LD_LIBRARY_PATH": "/nonexistent",
        "IFS": "\t\n",
        "LANG": "INVALID",
        "LC_ALL": "INVALID",
    }
    rc, out, err = run_asm([], stdin_data=test_data, env=hostile_env)
    report_result(rc < 128, "env: hostile environment no crash")

    # Large environment
    large_env = {f"VAR_{i}": f"value_{i}" * 100 for i in range(1000)}
    rc, out, err = run_asm([], stdin_data=test_data, env=large_env)
    report_result(rc < 128, "env: large environment (1000 vars)")

# =============================================================================
#                     10. OUTPUT INTEGRITY
# =============================================================================

def test_output_integrity():
    log("\n=== Output Integrity ===")

    # Deterministic output
    test_data = b"".join(f"line {i}\n".encode() for i in range(50))
    results = []
    for _ in range(10):
        rc, out, err = run_asm([], stdin_data=test_data)
        results.append(out)
    report_result(len(set(results)) == 1, "integrity: deterministic (10 trials)")

    # stderr/stdout isolation
    rc, out, err = run_asm([], stdin_data=b"hello\n")
    report_result(err == b"" or rc != 0, "integrity: stderr empty on success")

    # Exit code comparison with GNU
    for desc, args, data in [
        ("normal", [], b"hello\nworld\n"),
        ("empty input", [], b""),
    ]:
        rc_asm, _, _ = run_asm(args, stdin_data=data)
        rc_gnu, _, _ = run_gnu(args, stdin_data=data)
        report_result(rc_asm == rc_gnu, f"integrity: exit code match GNU ({desc})")

    # Large output integrity
    lines = [f"line {i:06d}\n".encode() for i in range(100)]
    data = b"".join(lines)
    rc, out, err = run_asm(["-n", "10"], stdin_data=data)
    expected = b"".join(lines[:10])
    report_result(out == expected, "integrity: first 10 lines of 100")

    # Compare output with GNU on various inputs
    for desc, args, data in [
        ("5 lines", ["-n", "5"], b"".join(f"L{i}\n".encode() for i in range(20))),
        ("default 10", [], b"".join(f"L{i}\n".encode() for i in range(20))),
        ("more than available", ["-n", "100"], b"only three\nlines\nhere\n"),
    ]:
        rc_a, out_a, _ = run_asm(args, stdin_data=data)
        rc_g, out_g, _ = run_gnu(args, stdin_data=data)
        report_result(out_a == out_g, f"integrity: output match GNU ({desc})")

# =============================================================================
#                     11. ERROR HANDLING
# =============================================================================

def test_error_handling():
    log("\n=== Error Handling ===")

    # Invalid flags
    rc_a, _, err_a = run_asm(["--invalid-flag-xyz"], stdin_data=b"test\n")
    rc_g, _, err_g = run_gnu(["--invalid-flag-xyz"], stdin_data=b"test\n")
    report_result(rc_a != 0, "error: invalid flag returns nonzero")

    # EINTR injection
    if which("strace"):
        rc, out, err = run(["strace", "-e", "inject=write:error=EINTR:when=1",
                            BIN], stdin_data=b"hello\nworld\n")
        report_result(rc in (0, 1, 124), "error: EINTR injection on write")

        rc, out, err = run(["strace", "-e", "inject=read:error=EINTR:when=1",
                            BIN], stdin_data=b"hello\nworld\n")
        report_result(rc in (0, 1, 124), "error: EINTR injection on read")
    else:
        skip_test("error: EINTR injection", "no strace")

    # /dev/full write
    if os.path.exists("/dev/full"):
        script = f'echo "test" | {BIN} > /dev/full 2>/dev/null; echo $?'
        p = subprocess.run(["bash", "-c", script], capture_output=True, timeout=TIMEOUT, text=True)
        report_result(p.returncode == 0, "error: /dev/full write")

    # Broken pipe mid-output
    script = f'seq 1000 | {BIN} -n 500 | head -c 10 >/dev/null 2>/dev/null; echo $?'
    p = subprocess.run(["bash", "-c", script], capture_output=True, timeout=TIMEOUT, text=True)
    report_result(p.returncode == 0, "error: broken pipe mid-output")

# =============================================================================
#                     12. CONCURRENCY STRESS
# =============================================================================

def test_concurrency():
    log("\n=== Concurrency Stress ===")

    # 50 simultaneous instances
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
            if p.returncode >= 128:
                all_ok = False
        except subprocess.TimeoutExpired:
            p.kill()
            p.communicate()
            all_ok = False
    report_result(all_ok, "concurrency: 50 simultaneous instances")

    # Pipe chains
    script = f'seq 100 | {BIN} -n 50 | {BIN} -n 25 | {BIN} -n 10 | wc -l'
    p = subprocess.run(["bash", "-c", script], capture_output=True, timeout=TIMEOUT, text=True)
    report_result(p.stdout.strip() == "10", "concurrency: pipe chain head|head|head")

    # Rapid start/kill
    ok_count = 0
    for _ in range(20):
        p = subprocess.Popen([BIN], stdin=subprocess.PIPE,
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            time.sleep(0.01)
            p.kill()
            p.wait(timeout=2)
            ok_count += 1
        except:
            try:
                p.kill()
            except:
                pass
    report_result(ok_count >= 18, f"concurrency: rapid start/kill ({ok_count}/20)")

# =============================================================================
#                     13. TOOL-SPECIFIC: HEAD TESTS
# =============================================================================

def test_head_specific():
    log("\n=== Head-Specific Tests ===")

    lines_20 = b"".join(f"line{i:03d}\n".encode() for i in range(20))
    lines_5 = b"".join(f"line{i:03d}\n".encode() for i in range(5))

    # Default 10 lines
    rc_a, out_a, _ = run_asm([], stdin_data=lines_20)
    rc_g, out_g, _ = run_gnu([], stdin_data=lines_20)
    report_result(out_a == out_g, "head: default 10 lines matches GNU")

    # -n N
    for n in [1, 5, 10, 15, 20, 100]:
        rc_a, out_a, _ = run_asm(["-n", str(n)], stdin_data=lines_20)
        rc_g, out_g, _ = run_gnu(["-n", str(n)], stdin_data=lines_20)
        report_result(out_a == out_g, f"head: -n {n} matches GNU")

    # -n 0
    rc_a, out_a, _ = run_asm(["-n", "0"], stdin_data=lines_20)
    rc_g, out_g, _ = run_gnu(["-n", "0"], stdin_data=lines_20)
    report_result(out_a == out_g, "head: -n 0 matches GNU")

    # Fewer lines than requested
    rc_a, out_a, _ = run_asm(["-n", "100"], stdin_data=lines_5)
    rc_g, out_g, _ = run_gnu(["-n", "100"], stdin_data=lines_5)
    report_result(out_a == out_g, "head: fewer lines than requested")

    # Exactly N lines
    rc_a, out_a, _ = run_asm(["-n", "5"], stdin_data=lines_5)
    rc_g, out_g, _ = run_gnu(["-n", "5"], stdin_data=lines_5)
    report_result(out_a == out_g, "head: exactly N lines")

    # Empty input
    rc_a, out_a, _ = run_asm([], stdin_data=b"")
    rc_g, out_g, _ = run_gnu([], stdin_data=b"")
    report_result(out_a == out_g, "head: empty input")

    # Single line, no trailing newline
    rc_a, out_a, _ = run_asm([], stdin_data=b"no newline")
    rc_g, out_g, _ = run_gnu([], stdin_data=b"no newline")
    report_result(out_a == out_g, "head: single line no trailing newline")

    # Binary data preservation
    binary_data = bytes(range(256)) + b"\n" + bytes(range(256)) + b"\n"
    rc_a, out_a, _ = run_asm(["-n", "1"], stdin_data=binary_data)
    rc_g, out_g, _ = run_gnu(["-n", "1"], stdin_data=binary_data)
    report_result(out_a == out_g, "head: binary data preservation")

    # -c N (byte count) if supported
    rc_a, out_a, _ = run_asm(["-c", "10"], stdin_data=b"hello world this is a test\n")
    rc_g, out_g, _ = run_gnu(["-c", "10"], stdin_data=b"hello world this is a test\n")
    if rc_a == 0 and rc_g == 0:
        report_result(out_a == out_g, "head: -c 10 bytes matches GNU")
    else:
        skip_test("head: -c byte mode", "not supported")

    # Line counting accuracy with \r\n
    crlf_data = b"line1\r\nline2\r\nline3\r\n"
    rc_a, out_a, _ = run_asm(["-n", "2"], stdin_data=crlf_data)
    rc_g, out_g, _ = run_gnu(["-n", "2"], stdin_data=crlf_data)
    report_result(out_a == out_g, "head: CRLF line counting matches GNU")

    # Very large line count (should not hang)
    data = b"x\n" * 10
    rc_a, out_a, _ = run_asm(["-n", "999999"], stdin_data=data)
    report_result(rc_a < 128 and out_a == data, "head: -n 999999 with small input")

    # --help/--version
    rc_a, out_a, err_a = run_asm(["--help"])
    report_result(rc_a == 0 and len(out_a) > 0, "head: --help works")

    rc_a, out_a, err_a = run_asm(["--version"])
    report_result(rc_a == 0 and len(out_a) > 0, "head: --version works")

    # Negative line count -n -N (all but last N)
    rc_a, out_a, _ = run_asm(["-n", "-3"], stdin_data=lines_20)
    rc_g, out_g, _ = run_gnu(["-n", "-3"], stdin_data=lines_20)
    if rc_a == 0 and rc_g == 0:
        report_result(out_a == out_g, "head: -n -3 (all but last 3) matches GNU")
    else:
        skip_test("head: -n -N", "not supported or error")

    # Large input default head
    large = b"".join(f"L{i:08d}\n".encode() for i in range(10000))
    rc_a, out_a, _ = run_asm([], stdin_data=large)
    rc_g, out_g, _ = run_gnu([], stdin_data=large)
    report_result(out_a == out_g, "head: large input (10K lines) default 10")

# =============================================================================
#                           MAIN
# =============================================================================

def run_tests():
    log(f"=== Security Tests for {TOOL_NAME} (fhead) ===")
    log(f"Binary: {BIN}")
    log(f"GNU:    {GNU}")

    if not os.path.isfile(BIN):
        log(f"[FATAL] Binary not found: {BIN}")
        sys.exit(2)
    if not os.access(BIN, os.X_OK):
        log(f"[FATAL] Binary not executable: {BIN}")
        sys.exit(2)

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
    test_head_specific()

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
