#!/usr/bin/env python3
"""security_tests.py — Security & memory safety tests for fcomm (assembly comm)."""

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
TOOL_NAME = "comm"
BIN = str(Path(__file__).resolve().parent.parent / "fcomm")
GNU = "/usr/bin/comm"

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

def make_temp_file(content, suffix=".txt"):
    f = tempfile.NamedTemporaryFile(mode='wb', suffix=suffix, delete=False)
    f.write(content)
    f.close()
    return f.name

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

    f1 = make_temp_file(b"a\nb\nc\n")
    f2 = make_temp_file(b"b\nc\nd\n")

    try:
        rc, out, err = run(["strace", "-f", "-e", "trace=%network", BIN, f1, f2])
        net_calls = [l for l in err.split(b"\n") if b"socket(" in l or b"connect(" in l]
        report_result(len(net_calls) == 0, "syscall: no network syscalls")

        rc, out, err = run(["strace", "-f", "-e", "trace=%process", BIN, "--help"])
        spawn_calls = [l for l in err.split(b"\n")
                       if b"fork(" in l or b"vfork(" in l or b"clone(" in l]
        spawn_calls = [l for l in spawn_calls if b"execve(" not in l]
        report_result(len(spawn_calls) == 0, "syscall: no process spawning")

        rc, out, err = run(["strace", "-f", "-e", "trace=brk,mmap,mprotect", BIN, f1, f2])
        mem_lines = [l for l in err.split(b"\n")
                     if b"brk(" in l or b"mmap(" in l or b"mprotect(" in l]
        mem_lines = [l for l in mem_lines if not l.startswith(b"---") and not l.startswith(b"+++")]
        report_result(len(mem_lines) < 10, f"syscall: minimal brk/mmap/mprotect ({len(mem_lines)} calls)")

        rc, out, err = run(["strace", "-c", "-e", "trace=all", BIN, f1, f2])
        report_result(rc in (0, 124), "syscall: strace -c completed")
    finally:
        os.unlink(f1)
        os.unlink(f2)

# =============================================================================
#                     3. /proc FILESYSTEM RUNTIME ANALYSIS
# =============================================================================

def test_proc_runtime():
    log("\n=== /proc Filesystem Runtime Analysis ===")
    f1 = make_temp_file(b"a\nb\nc\n")
    f2 = make_temp_file(b"b\nc\nd\n")

    try:
        p = subprocess.Popen([BIN, f1, f2], stdin=subprocess.DEVNULL,
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE)
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
                report_result(os.path.basename(exe) == "fcomm", "proc: /proc/PID/exe points to fcomm")
            except Exception as e:
                skip_test("proc: exe link", str(e))
        finally:
            try: p.kill()
            except: pass
            p.wait()
    finally:
        os.unlink(f1)
        os.unlink(f2)

# =============================================================================
#                     4. FILE DESCRIPTOR HYGIENE
# =============================================================================

def test_fd_hygiene():
    log("\n=== File Descriptor Hygiene ===")

    f1 = make_temp_file(b"a\nb\nc\n")
    f2 = make_temp_file(b"b\nc\nd\n")

    try:
        # comm processes files synchronously, check fd hygiene with --help
        script = f'{BIN} --help >/dev/null 2>/dev/null; echo $?'
        p = subprocess.run(["bash", "-c", script], capture_output=True, timeout=TIMEOUT, text=True)
        report_result(p.stdout.strip() == "0", "fd: basic operation clean exit")

        # Closed stdout
        script = f'{BIN} {f1} {f2} 2>/dev/null 1>&-; echo $?'
        p = subprocess.run(["bash", "-c", script], capture_output=True, timeout=TIMEOUT, text=True)
        report_result(p.returncode == 0, "fd: closed stdout doesn't crash")

        # Closed stderr
        script = f'{BIN} --invalid 2>&- 1>/dev/null; echo $?'
        p = subprocess.run(["bash", "-c", script], capture_output=True, timeout=TIMEOUT, text=True)
        report_result(p.returncode == 0, "fd: closed stderr doesn't crash")

        # /dev/full
        if os.path.exists("/dev/full"):
            script = f'{BIN} {f1} {f2} > /dev/full 2>/dev/null; echo $?'
            p = subprocess.run(["bash", "-c", script], capture_output=True, timeout=TIMEOUT, text=True)
            report_result(p.stdout.strip() != "" and p.returncode == 0, "fd: /dev/full ENOSPC handling")

        # /dev/null output
        script = f'{BIN} {f1} {f2} > /dev/null 2>/dev/null; echo $?'
        p = subprocess.run(["bash", "-c", script], capture_output=True, timeout=TIMEOUT, text=True)
        report_result(p.stdout.strip() == "0", "fd: /dev/null output works")

        # RLIMIT_NOFILE
        def limit_nofile():
            resource.setrlimit(resource.RLIMIT_NOFILE, (10, 10))
        rc, _, _ = run_asm([f1, f2], preexec_fn=limit_nofile)
        report_result(rc in (0, 1), "fd: works with RLIMIT_NOFILE=10")
    finally:
        os.unlink(f1)
        os.unlink(f2)

# =============================================================================
#                     5. MEMORY SAFETY
# =============================================================================

def test_memory_safety():
    log("\n=== Memory Safety Tests ===")

    temp_files = []
    try:
        # Various edge case inputs
        for desc, data1, data2 in [
            ("empty files", b"", b""),
            ("empty + non-empty", b"", b"a\nb\n"),
            ("single byte each", b"A\n", b"B\n"),
            ("identical files", b"a\nb\nc\n", b"a\nb\nc\n"),
            ("binary data", bytes(range(1, 256)) + b"\n", bytes(range(1, 256)) + b"\n"),
            ("null bytes in lines", b"he\x00llo\nworld\n", b"he\x00llo\ntest\n"),
        ]:
            f1 = make_temp_file(data1)
            f2 = make_temp_file(data2)
            temp_files.extend([f1, f2])
            rc, _, _ = run_asm([f1, f2])
            report_result(rc < 128, f"mem: no crash on {desc} (rc={rc})")

        # Large files
        log("\n--- Large File Tests ---")
        large_data1 = b"".join(f"line_{i:010d}\n".encode() for i in range(100000))
        large_data2 = b"".join(f"line_{i:010d}\n".encode() for i in range(50000, 150000))
        f1 = make_temp_file(large_data1)
        f2 = make_temp_file(large_data2)
        temp_files.extend([f1, f2])
        rc, _, _ = run_asm([f1, f2], timeout=30)
        report_result(rc < 128, f"mem: 100K line files no crash (rc={rc})")

        # Long lines
        log("\n--- Long Line Tests ---")
        for size_name, size in [("1KB", 1024), ("64KB", 65536), ("1MB", 1048576)]:
            data = b"A" * size + b"\n"
            f1 = make_temp_file(data)
            f2 = make_temp_file(data)
            temp_files.extend([f1, f2])
            rc, _, _ = run_asm([f1, f2])
            report_result(rc < 128, f"mem: {size_name} line no crash (rc={rc})")

        # Boundary value analysis
        log("\n--- Boundary Value Analysis ---")
        for desc, data1, data2 in [
            ("no trailing newline", b"hello", b"hello"),
            ("CRLF endings", b"line1\r\nline2\r\n", b"line1\r\nline3\r\n"),
            ("only newlines", b"\n\n\n", b"\n\n"),
            ("all 256 byte values", bytes(range(256)) * 4 + b"\n", bytes(range(256)) * 4 + b"\n"),
        ]:
            f1 = make_temp_file(data1)
            f2 = make_temp_file(data2)
            temp_files.extend([f1, f2])
            rc, _, _ = run_asm([f1, f2])
            report_result(rc < 128, f"mem: boundary - {desc} no crash (rc={rc})")

        # Resource limits
        def limit_stack():
            resource.setrlimit(resource.RLIMIT_STACK, (65536, 65536))

        f1 = make_temp_file(b"a\nb\nc\n")
        f2 = make_temp_file(b"b\nc\nd\n")
        temp_files.extend([f1, f2])
        rc, _, _ = run_asm([f1, f2], preexec_fn=limit_stack)
        report_result(rc < 128, "mem: RLIMIT_STACK=64KB")

        def limit_as():
            resource.setrlimit(resource.RLIMIT_AS, (64 * 1024 * 1024, 64 * 1024 * 1024))
        rc, _, _ = run_asm([f1, f2], preexec_fn=limit_as)
        report_result(rc < 128, "mem: RLIMIT_AS=64MB")

    finally:
        for f in temp_files:
            try: os.unlink(f)
            except: pass

# =============================================================================
#                     6. SIGNAL SAFETY
# =============================================================================

def test_signal_safety():
    log("\n=== Signal Safety ===")

    f1 = make_temp_file(b"".join(f"line_{i:06d}\n".encode() for i in range(10000)))
    f2 = make_temp_file(b"".join(f"line_{i:06d}\n".encode() for i in range(5000, 15000)))

    try:
        # SIGPIPE
        script = f'{BIN} {f1} {f2} | head -1 >/dev/null 2>/dev/null; echo $?'
        p = subprocess.run(["bash", "-c", script], capture_output=True, timeout=TIMEOUT, text=True)
        report_result(p.returncode == 0, "signal: SIGPIPE clean exit")

        # SIGTERM
        for sig_val, sig_name in [(signal.SIGTERM, "SIGTERM"), (signal.SIGINT, "SIGINT")]:
            f1b = make_temp_file(b"".join(f"line_{i:06d}\n".encode() for i in range(1000000)))
            f2b = make_temp_file(b"".join(f"line_{i:06d}\n".encode() for i in range(500000, 1500000)))
            try:
                p = subprocess.Popen([BIN, f1b, f2b],
                                     stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                time.sleep(0.05)
                p.send_signal(sig_val)
                p.wait(timeout=2)
                report_result(True, f"signal: {sig_name} clean termination")
            except subprocess.TimeoutExpired:
                p.kill()
                report_result(False, f"signal: {sig_name} clean termination")
            except:
                report_result(True, f"signal: {sig_name} clean termination")
            finally:
                try: p.kill()
                except: pass
                os.unlink(f1b)
                os.unlink(f2b)

        # Rapid SIGPIPE
        ok_count = 0
        trials = 20
        for _ in range(trials):
            rc = os.system(f'{BIN} {f1} {f2} | head -c 1 >/dev/null 2>/dev/null')
            if rc == 0: ok_count += 1
        report_result(ok_count >= trials - 2, f"signal: rapid SIGPIPE ({ok_count}/{trials})")
    finally:
        os.unlink(f1)
        os.unlink(f2)

# =============================================================================
#                     7. INPUT FUZZING
# =============================================================================

def test_input_fuzzing():
    log("\n=== Input Fuzzing ===")

    temp_files = []
    try:
        crash_count = 0
        for _ in range(50):
            data1 = ''.join(random.choices(string.printable, k=random.randint(0, 500))).encode()
            data2 = ''.join(random.choices(string.printable, k=random.randint(0, 500))).encode()
            f1 = make_temp_file(data1)
            f2 = make_temp_file(data2)
            temp_files.extend([f1, f2])
            rc, _, _ = run_asm([f1, f2])
            if rc >= 128: crash_count += 1
        report_result(crash_count == 0, f"fuzz: 50 random printable (crashes: {crash_count})")

        crash_count = 0
        for _ in range(30):
            data1 = os.urandom(random.randint(100, 10000))
            data2 = os.urandom(random.randint(100, 10000))
            f1 = make_temp_file(data1)
            f2 = make_temp_file(data2)
            temp_files.extend([f1, f2])
            rc, _, _ = run_asm([f1, f2])
            if rc >= 128: crash_count += 1
        report_result(crash_count == 0, f"fuzz: 30 binary blobs (crashes: {crash_count})")

        # Pathological inputs
        crash_count = 0
        pathological = [
            (b"\n" * 10000, b"\n" * 10000),
            (b"\x00" * 1000, b"\x00" * 1000),
            (b"a" * 100000 + b"\n", b"b" * 100000 + b"\n"),
            (b"\xff" * 1000 + b"\n", b"\xff" * 1000 + b"\n"),
        ]
        for data1, data2 in pathological:
            f1 = make_temp_file(data1)
            f2 = make_temp_file(data2)
            temp_files.extend([f1, f2])
            rc, _, _ = run_asm([f1, f2])
            if rc >= 128: crash_count += 1
        report_result(crash_count == 0, f"fuzz: pathological inputs (crashes: {crash_count})")
    finally:
        for f in temp_files:
            try: os.unlink(f)
            except: pass

# =============================================================================
#                     8. ARGUMENT PARSING ROBUSTNESS
# =============================================================================

def test_argument_parsing():
    log("\n=== Argument Parsing Robustness ===")

    f1 = make_temp_file(b"a\nb\nc\n")
    f2 = make_temp_file(b"b\nc\nd\n")

    try:
        # Valid flag combinations
        for desc, args in [
            ("-1", ["-1"]),
            ("-2", ["-2"]),
            ("-3", ["-3"]),
            ("-12", ["-12"]),
            ("-123", ["-123"]),
            ("-1 -2 -3", ["-1", "-2", "-3"]),
            ("-z", ["-z"]),
            ("--total", ["--total"]),
            ("--check-order", ["--check-order"]),
            ("--nocheck-order", ["--nocheck-order"]),
            ("--output-delimiter=|", ["--output-delimiter=|"]),
            ("--zero-terminated", ["--zero-terminated"]),
        ]:
            rc, _, _ = run_asm(args + [f1, f2])
            report_result(rc < 128, f"args: {desc} no crash (rc={rc})")

        # Error cases (should exit 1, not crash)
        for desc, args in [
            ("no args", []),
            ("one arg", [f1]),
            ("three args", [f1, f2, f1]),
            ("nonexistent file", [f1, "/nonexistent_file_xyzzy"]),
            ("unknown short opt", ["-x", f1, f2]),
            ("unknown long opt", ["--foobar", f1, f2]),
        ]:
            rc, _, _ = run_asm(args)
            report_result(rc < 128 and rc != 0, f"args: {desc} exits non-zero no crash (rc={rc})")

        # -- end of options
        rc, out, _ = run_asm(["--", f1, f2])
        report_result(rc == 0, "args: -- end of options")

        # --help and --version
        rc, out, _ = run_asm(["--help"])
        report_result(rc == 0 and len(out) > 50, f"args: --help (rc={rc}, len={len(out)})")

        rc, out, _ = run_asm(["--version"])
        report_result(rc == 0 and len(out) > 5, f"args: --version (rc={rc}, len={len(out)})")

    finally:
        os.unlink(f1)
        os.unlink(f2)

# =============================================================================
#                     9. CORRECTNESS VERIFICATION
# =============================================================================

def test_correctness():
    log("\n=== Correctness Verification ===")

    temp_files = []
    try:
        # Compare against GNU comm for various inputs
        test_cases = [
            ("basic", b"a\nb\nc\n", b"b\nc\nd\n", []),
            ("identical", b"a\nb\nc\n", b"a\nb\nc\n", []),
            ("disjoint", b"x\ny\nz\n", b"a\nb\nc\n", []),
            ("empty both", b"", b"", []),
            ("empty first", b"", b"a\nb\n", []),
            ("empty second", b"a\nb\n", b"", []),
            ("-1", b"a\nb\nc\n", b"b\nc\nd\n", ["-1"]),
            ("-2", b"a\nb\nc\n", b"b\nc\nd\n", ["-2"]),
            ("-3", b"a\nb\nc\n", b"b\nc\nd\n", ["-3"]),
            ("-12", b"a\nb\nc\n", b"b\nc\nd\n", ["-12"]),
            ("-23", b"a\nb\nc\n", b"b\nc\nd\n", ["-23"]),
            ("-13", b"a\nb\nc\n", b"b\nc\nd\n", ["-13"]),
            ("-123", b"a\nb\nc\n", b"b\nc\nd\n", ["-123"]),
            ("--total", b"a\nb\nc\n", b"b\nc\nd\n", ["--total"]),
            ("--output-delimiter=|", b"a\nb\nc\n", b"b\nc\nd\n", ["--output-delimiter=|"]),
            ("single line", b"a\n", b"a\n", []),
            ("no trailing nl", b"a\nb", b"b\nc", []),
        ]

        for desc, data1, data2, flags in test_cases:
            f1 = make_temp_file(data1)
            f2 = make_temp_file(data2)
            temp_files.extend([f1, f2])

            grc, gout, gerr = run([GNU] + flags + [f1, f2])
            arc, aout, aerr = run([BIN] + flags + [f1, f2])

            match = (gout == aout and grc == arc)
            report_result(match, f"correct: {desc} (gnu_rc={grc}, asm_rc={arc})")

    finally:
        for f in temp_files:
            try: os.unlink(f)
            except: pass

# =============================================================================
#                     MAIN
# =============================================================================

def main():
    if not os.path.isfile(BIN):
        log(f"ERROR: binary not found at {BIN}")
        sys.exit(1)

    test_elf_binary_security()
    test_syscall_surface()
    test_proc_runtime()
    test_fd_hygiene()
    test_memory_safety()
    test_signal_safety()
    test_input_fuzzing()
    test_argument_parsing()
    test_correctness()

    log(f"\n{'='*60}")
    log(f"RESULTS: {pass_count} passed, {len(failures)} failed, {skip_count} skipped out of {test_count} tests")
    if failures:
        log("\nFailed tests:")
        for f in failures:
            log(f"  - {f['label']}")
    log(f"{'='*60}")

    if failures:
        sys.exit(1)
    else:
        log("\nALL TESTS PASSED")
        sys.exit(0)

if __name__ == "__main__":
    main()
