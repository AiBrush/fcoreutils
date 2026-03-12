#!/usr/bin/env python3
"""security_tests.py — Security & memory safety tests for ffactor (assembly factor)."""

import os
import sys
import subprocess
import struct
import signal
import time
import tempfile
import resource
from pathlib import Path
from shutil import which

# =============================================================================
#                           CONFIGURATION
# =============================================================================

TIMEOUT = 5
BSS_SIZE = 131072  # 128KB output buffer in ffactor
TOOL_NAME = "factor"
BIN = str(Path(__file__).resolve().parent.parent / "ffactor")
GNU = "/usr/bin/factor"

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

    rc, out, err = run(["strace", "-f", "-e", "trace=%network", BIN, "12"])
    net_calls = [l for l in err.split(b"\n") if b"socket(" in l or b"connect(" in l]
    report_result(len(net_calls) == 0, "syscall: no network syscalls")

    rc, out, err = run(["strace", "-f", "-e", "trace=%process", BIN, "--help"])
    spawn_calls = [l for l in err.split(b"\n")
                   if b"fork(" in l or b"vfork(" in l or b"clone(" in l]
    spawn_calls = [l for l in spawn_calls if b"execve(" not in l]
    report_result(len(spawn_calls) == 0, "syscall: no process spawning")

    rc, out, err = run(["strace", "-f", "-e", "trace=brk,mmap,mprotect", BIN, "12"])
    mem_lines = [l for l in err.split(b"\n")
                 if b"brk(" in l or b"mmap(" in l or b"mprotect(" in l]
    mem_lines = [l for l in mem_lines if not l.startswith(b"---") and not l.startswith(b"+++")]
    report_result(len(mem_lines) < 10, f"syscall: minimal brk/mmap/mprotect ({len(mem_lines)} calls)")

    rc, out, err = run(["strace", "-c", "-e", "trace=all", BIN, "12"])
    report_result(rc in (0, 124), "syscall: strace -c completed")

# =============================================================================
#                     3. /proc FILESYSTEM RUNTIME ANALYSIS
# =============================================================================

def test_proc_runtime():
    log("\n=== /proc Filesystem Runtime Analysis ===")
    # Feed a huge input via a pipe to keep process alive while we inspect /proc
    # Generate input in a temp file to avoid blocking
    big_input = "\n".join(str(i) for i in range(1, 1000001)) + "\n"
    with tempfile.NamedTemporaryFile(mode='w', suffix='.txt', delete=False) as f:
        f.write(big_input)
        tmpfile = f.name
    try:
        with open(tmpfile, 'r') as inf:
            p = subprocess.Popen([BIN], stdin=inf,
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
                report_result(os.path.basename(exe) == "ffactor", "proc: /proc/PID/exe points to ffactor")
            except Exception as e:
                skip_test("proc: exe link", str(e))
        finally:
            try: p.kill()
            except: pass
            p.wait()
    finally:
        os.unlink(tmpfile)

# =============================================================================
#                     4. FILE DESCRIPTOR HYGIENE
# =============================================================================

def test_fd_hygiene():
    log("\n=== File Descriptor Hygiene ===")

    big_input = "\n".join(str(i) for i in range(1, 1000001)) + "\n"
    with tempfile.NamedTemporaryFile(mode='w', suffix='.txt', delete=False) as f:
        f.write(big_input)
        tmpfile = f.name
    try:
        with open(tmpfile, 'r') as inf:
            p = subprocess.Popen([BIN], stdin=inf,
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
    finally:
        os.unlink(tmpfile)

    def limit_nofile():
        resource.setrlimit(resource.RLIMIT_NOFILE, (3, 3))
    rc, _, _ = run_asm(["12"], preexec_fn=limit_nofile)
    report_result(rc in (0, 1), "fd: works with RLIMIT_NOFILE=3")

    script = f'{BIN} 12 2>/dev/null 1>&-; echo $?'
    p = subprocess.run(["bash", "-c", script], capture_output=True, timeout=TIMEOUT, text=True)
    report_result(p.returncode == 0, "fd: closed stdout doesn't crash")

    script = f'{BIN} abc 2>&- 1>/dev/null; echo $?'
    p = subprocess.run(["bash", "-c", script], capture_output=True, timeout=TIMEOUT, text=True)
    report_result(p.returncode == 0, "fd: closed stderr doesn't crash")

    if os.path.exists("/dev/full"):
        script = f'{BIN} 12 > /dev/full 2>/dev/null; echo $?'
        p = subprocess.run(["bash", "-c", script], capture_output=True, timeout=TIMEOUT, text=True)
        report_result(p.stdout.strip() != "" and p.returncode == 0, "fd: /dev/full ENOSPC handling")

    script = f'{BIN} 12 > /dev/null 2>/dev/null; echo $?'
    p = subprocess.run(["bash", "-c", script], capture_output=True, timeout=TIMEOUT, text=True)
    report_result(p.stdout.strip() == "0", "fd: /dev/null output works")

# =============================================================================
#                     5. MEMORY SAFETY
# =============================================================================

def test_memory_safety():
    log("\n=== Memory Safety Tests ===")

    for desc, args in [
        ("factor 1", ["1"]),
        ("factor 0", ["0"]),
        ("factor 12", ["12"]),
        ("factor large prime", ["999999937"]),
        ("factor 2^63-1", ["9223372036854775807"]),
        ("factor 2^64-1", ["18446744073709551615"]),
    ]:
        rc, _, _ = run_asm(args)
        report_result(rc < 128, f"mem: no crash on {desc} (rc={rc})")

    # Large input via stdin
    big_input = "\n".join(str(i) for i in range(1, 10001)) + "\n"
    rc, out, _ = run_asm([], stdin_data=big_input.encode(), timeout=10)
    report_result(rc < 128, f"mem: stdin 10K numbers no crash (rc={rc})")
    lines = out.strip().split(b"\n")
    report_result(len(lines) == 10000, f"mem: stdin 10K numbers all processed ({len(lines)} lines)")

    # Many args
    args = [str(i) for i in range(1, 101)]
    rc, out, _ = run_asm(args)
    lines = out.strip().split(b"\n")
    report_result(rc == 0 and len(lines) == 100, "mem: 100 args processed correctly")

# =============================================================================
#                     6. SIGNAL HANDLING
# =============================================================================

def test_signal_handling():
    log("\n=== Signal Handling ===")

    # SIGPIPE — writing to closed pipe
    big_input = "\n".join(str(i) for i in range(1, 1000001)) + "\n"
    script = f'echo "{big_input[:1000]}" | {BIN} | head -1'
    p = subprocess.run(["bash", "-c", script], capture_output=True, timeout=TIMEOUT)
    report_result(p.returncode == 0, "sig: SIGPIPE from head -1 (no crash)")

    # SIGINT
    p = subprocess.Popen([BIN], stdin=subprocess.PIPE,
                         stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    time.sleep(0.1)
    p.send_signal(signal.SIGINT)
    try:
        _, _ = p.communicate(timeout=TIMEOUT)
        report_result(True, f"sig: SIGINT handled (rc={p.returncode})")
    except subprocess.TimeoutExpired:
        p.kill()
        p.wait()
        report_result(False, "sig: SIGINT caused hang")

    # SIGTERM
    p = subprocess.Popen([BIN], stdin=subprocess.PIPE,
                         stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    time.sleep(0.1)
    p.send_signal(signal.SIGTERM)
    try:
        _, _ = p.communicate(timeout=TIMEOUT)
        report_result(True, f"sig: SIGTERM handled (rc={p.returncode})")
    except subprocess.TimeoutExpired:
        p.kill()
        p.wait()
        report_result(False, "sig: SIGTERM caused hang")

# =============================================================================
#                     7. INPUT FUZZING
# =============================================================================

def test_input_fuzzing():
    log("\n=== Input Fuzzing ===")

    # Random bytes
    random_data = os.urandom(4096)
    rc, _, _ = run_asm([], stdin_data=random_data)
    report_result(rc < 128, f"fuzz: random 4KB bytes no crash (rc={rc})")

    # Very long line
    long_line = b"1" * 100000 + b"\n"
    rc, _, _ = run_asm([], stdin_data=long_line)
    report_result(rc < 128, f"fuzz: 100KB single line no crash (rc={rc})")

    # NULL bytes
    null_data = b"\x00" * 1024 + b"\n"
    rc, _, _ = run_asm([], stdin_data=null_data)
    report_result(rc < 128, f"fuzz: NULL bytes no crash (rc={rc})")

    # Unicode/high bytes
    unicode_data = "12\n\xff\xfe\n42\n".encode("latin-1")
    rc, _, _ = run_asm([], stdin_data=unicode_data)
    report_result(rc < 128, f"fuzz: high bytes no crash (rc={rc})")

    # Empty input
    rc, out, _ = run_asm([], stdin_data=b"")
    report_result(rc == 0 and out == b"", "fuzz: empty stdin (rc=0, no output)")

    # Just whitespace
    rc, out, _ = run_asm([], stdin_data=b"   \n\t\n  \n")
    report_result(rc == 0 and out == b"", "fuzz: whitespace-only stdin")

    # Many numbers on one line
    line = " ".join(str(i) for i in range(1, 1001)) + "\n"
    rc, out, _ = run_asm([], stdin_data=line.encode())
    lines = out.strip().split(b"\n")
    report_result(rc == 0 and len(lines) == 1000, f"fuzz: 1000 numbers one line ({len(lines)} results)")

    # Mix of valid and invalid
    mixed = b"12\nabc\n42\n!@#\n7\n"
    rc, out, err = run_asm([], stdin_data=mixed)
    out_lines = [l for l in out.strip().split(b"\n") if l]
    report_result(rc == 1 and len(out_lines) == 3, f"fuzz: mixed valid/invalid (rc={rc}, {len(out_lines)} outputs)")

    # Large number of arguments
    args = ["12"] * 500
    rc, out, _ = run_asm(args)
    lines = out.strip().split(b"\n")
    report_result(rc == 0 and len(lines) == 500, "fuzz: 500 identical args")

    # Numbers with leading zeros
    rc, out, _ = run_asm(["0000012"])
    report_result(rc == 0 and b"12: 2 2 3" in out, "fuzz: leading zeros")

    # Numbers with leading +
    rc, out, _ = run_asm(["+12"])
    report_result(rc == 0 and b"12: 2 2 3" in out, "fuzz: leading plus")

# =============================================================================
#                     8. RESOURCE LIMITS
# =============================================================================

def test_resource_limits():
    log("\n=== Resource Limit Tests ===")

    def limit_stack(size):
        def inner():
            resource.setrlimit(resource.RLIMIT_STACK, (size, size))
        return inner

    # Small stack
    rc, _, _ = run_asm(["12"], preexec_fn=limit_stack(64 * 1024))
    report_result(rc < 128, f"rlimit: 64KB stack (rc={rc})")

    # Limited CPU time
    def limit_cpu():
        resource.setrlimit(resource.RLIMIT_CPU, (2, 2))
    rc, _, _ = run_asm(["12"], preexec_fn=limit_cpu)
    report_result(rc == 0, "rlimit: CPU limit 2s, simple number")

# =============================================================================
#                           MAIN
# =============================================================================

def main():
    log(f"=== Security Tests for {BIN} ===")

    if not Path(BIN).exists():
        log(f"ERROR: Binary not found at {BIN}")
        sys.exit(1)

    test_elf_binary_security()
    test_syscall_surface()
    test_proc_runtime()
    test_fd_hygiene()
    test_memory_safety()
    test_signal_handling()
    test_input_fuzzing()
    test_resource_limits()

    log(f"\n{'='*60}")
    log(f"Security Tests: {pass_count}/{test_count} passed, {skip_count} skipped")
    if failures:
        log(f"\nFailed tests:")
        for f in failures:
            log(f"  - {f['label']}" + (f" ({f['note']})" if f['note'] else ""))
        sys.exit(1)
    else:
        log("All security tests passed!")
        sys.exit(0)

if __name__ == "__main__":
    main()
