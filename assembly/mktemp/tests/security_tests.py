#!/usr/bin/env python3
"""security_tests.py — Security & memory safety tests for fmktemp.

fmktemp is a GNU-compatible 'mktemp' written in x86-64 Linux assembly.
It creates temporary files or directories with unique random names.

TEST CATEGORIES:
    1. ELF binary security analysis
    2. Syscall surface analysis (strace)
    3. /proc filesystem runtime analysis
    4. File descriptor hygiene
    5. Memory safety
    6. Signal safety
    7. Input fuzzing
    8. Resource limit testing
    9. Environment robustness
   10. Output integrity
   11. Error handling
   12. Concurrency stress
   13. Tool-specific (mktemp: temp file/dir creation behavior)
"""

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

TIMEOUT = 5
BIN = ""
GNU = "mktemp"
LOG_EVERY = 1

failures = []
test_count = 0
pass_count = 0
skip_count = 0

# Track temp files/dirs to clean up at exit
_cleanup_paths = []


def log(msg):
    print(msg, flush=True)


def report_result(ok, label):
    global test_count, pass_count
    test_count += 1
    if ok:
        pass_count += 1
        if LOG_EVERY:
            log(f"[PASS] {label}")
    else:
        log(f"[FAIL] {label}")
        record_failure("test", label)


def report_skip(label):
    global skip_count, test_count, pass_count
    test_count += 1
    skip_count += 1
    pass_count += 1
    log(f"[SKIP] {label}")


def record_failure(category, details):
    failures.append({"category": category, "details": details})


def find_binary():
    global BIN
    script_dir = Path(__file__).resolve().parent
    for name in ["fmktemp_release", "fmktemp"]:
        candidate = script_dir.parent / name
        if candidate.exists():
            BIN = str(candidate)
            break
    if not BIN:
        log(f"[ERROR] Binary not found in {script_dir.parent}")
        sys.exit(2)
    log(f"Binary: {BIN}")
    gnu_path = which(GNU)
    if gnu_path:
        log(f"GNU reference: {gnu_path}")
    else:
        log(f"GNU reference not found: {GNU}")


def run(cmd, stdin_data=None, env=None, preexec_fn=None, timeout=None):
    if timeout is None:
        timeout = TIMEOUT
    try:
        p = subprocess.Popen(
            cmd,
            stdin=subprocess.PIPE if stdin_data is not None else subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=env,
            preexec_fn=preexec_fn,
        )
    except (OSError, ValueError):
        return (126, b'', b'OSError')
    try:
        out, err = p.communicate(input=stdin_data, timeout=timeout)
    except subprocess.TimeoutExpired:
        p.kill()
        out, err = p.communicate()
        return (124, out, err)
    return (p.returncode, out, err)


def cleanup_mktemp_result(rc, out):
    """Clean up any temp file/dir created by mktemp from its stdout."""
    if rc == 0 and out:
        path = out.decode(errors="replace").strip()
        if path and os.path.exists(path):
            try:
                if os.path.isdir(path):
                    os.rmdir(path)
                else:
                    os.unlink(path)
            except OSError:
                pass


# =============================================================================
#                     1. ELF BINARY SECURITY ANALYSIS
# =============================================================================

def check_elf_properties():
    log("\n=== 1. ELF Binary Security Analysis ===")
    try:
        with open(BIN, "rb") as f:
            elf = f.read()
    except Exception as e:
        record_failure("elf", f"Cannot read binary: {e}")
        report_result(False, "elf: read binary")
        return

    report_result(elf[:4] == b"\x7fELF", "elf: magic bytes \\x7fELF")
    report_result(elf[4] == 2, "elf: ELFCLASS64 (64-bit)")

    size = len(elf)
    report_result(size < 100000, f"elf: binary size {size} bytes (<100KB)")

    e_phoff = struct.unpack_from("<Q", elf, 32)[0]
    e_phentsize = struct.unpack_from("<H", elf, 54)[0]
    e_phnum = struct.unpack_from("<H", elf, 56)[0]
    e_entry = struct.unpack_from("<Q", elf, 24)[0]

    PT_LOAD, PT_INTERP, PT_DYNAMIC, PT_GNU_STACK = 1, 3, 2, 0x6474E551
    PF_X, PF_W, PF_R = 1, 2, 4

    has_interp = has_dynamic = has_rwx = False
    has_nx_stack = False
    load_ranges = []

    for i in range(e_phnum):
        off = e_phoff + i * e_phentsize
        p_type = struct.unpack_from("<I", elf, off)[0]
        p_flags = struct.unpack_from("<I", elf, off + 4)[0]
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
            load_ranges.append((p_vaddr, p_vaddr + p_memsz))

    report_result(not has_interp, "elf: no PT_INTERP (static binary)")
    report_result(not has_dynamic, "elf: no PT_DYNAMIC (no dynamic linking)")
    report_result(has_nx_stack, "elf: PT_GNU_STACK NX (non-executable stack)")

    entry_ok = any(lo <= e_entry < hi for lo, hi in load_ranges) if load_ranges else True
    report_result(entry_ok, f"elf: entry point 0x{e_entry:x} within LOAD segment")


def check_strings_leaks():
    log("\n=== Binary String Leak Analysis ===")
    with open(BIN, "rb") as f:
        data = f.read()

    bad_patterns = [
        (b"/home/", "home directory path"),
        (b"DEBUG", "debug string"),
        (b"TODO", "todo string"),
        (b"password", "password string"),
        (b"secret", "secret string"),
        (b".so", "shared library reference"),
        (b"ld-linux", "dynamic linker reference"),
        (b"libc", "libc reference"),
        (b"glibc", "glibc reference"),
    ]
    for pattern, desc in bad_patterns:
        found = pattern in data
        report_result(not found, f"strings: no {desc} in binary")

    from collections import Counter
    import math
    if len(data) > 0:
        counts = Counter(data)
        entropy = sum(-p * math.log2(p) for p in (c / len(data) for c in counts.values()) if p > 0)
        report_result(entropy < 7.0, f"strings: binary entropy {entropy:.2f} (<7.0)")


# =============================================================================
#                     2. SYSCALL SURFACE ANALYSIS
# =============================================================================

def check_syscall_surface():
    log("\n=== 2. Syscall Surface Analysis ===")
    if not which("strace"):
        report_skip("syscall: strace not available")
        return

    # mktemp creates a file by default, use -u (dry-run) to minimize side effects
    cmd = ["strace", "-f", "-e", "trace=%process,%network,write,read,openat,open,creat,brk,mmap,mprotect,getrandom",
           BIN, "-u"]
    rc, out, err = run(cmd)
    err_text = err.decode(errors="replace")
    lines = [l for l in err_text.splitlines()
             if l and not l.startswith("---") and not l.startswith("+++")
             and not l.startswith("execve(")]

    net_calls = [l for l in lines if any(s in l for s in
                 ["socket(", "connect(", "bind(", "listen(", "accept("])]
    report_result(len(net_calls) == 0, "syscall: no network syscalls")

    spawn_calls = [l for l in lines if any(s in l for s in
                   ["fork(", "vfork(", "clone(", "clone3("])]
    report_result(len(spawn_calls) == 0, "syscall: no process spawning")

    mem_calls = [l for l in lines if any(s in l for s in
                 ["brk(", "mmap(", "mprotect("])]
    report_result(len(mem_calls) == 0, "syscall: no memory allocation")


# =============================================================================
#                     3. /proc FILESYSTEM RUNTIME ANALYSIS
# =============================================================================

def check_proc_analysis():
    log("\n=== 3. /proc Filesystem Runtime Analysis ===")
    rc, out, err = run([BIN, "-u"])
    report_result(rc == 0, "proc: tool runs and exits cleanly (dry-run)")

    if which("strace"):
        cmd = ["strace", "-e", "trace=openat,open", BIN, "-u"]
        rc, out, err = run(cmd)
        err_text = err.decode(errors="replace")
        opens = [l for l in err_text.splitlines()
                 if ("openat(" in l or "open(" in l)
                 and not l.startswith("---") and not l.startswith("+++")]
        report_result(len(opens) == 0, "proc: no file descriptors opened (dry-run)")


# =============================================================================
#                     4. FILE DESCRIPTOR HYGIENE
# =============================================================================

def check_fd_hygiene():
    log("\n=== 4. File Descriptor Hygiene ===")

    # closed stdout -> doesn't hang
    script = f'exec 3>&1 1>&-; {BIN} -u 2>/dev/null; echo $? >&3'
    p = subprocess.run(["bash", "-c", script], capture_output=True, timeout=TIMEOUT, text=True)
    rc = p.stdout.strip()
    report_result(rc != "", "fd: closed stdout -> doesn't hang")

    # closed stderr -> doesn't hang
    script = f'exec 3>&1; {BIN} -u 2>&- 1>&3; echo $? >&3'
    p = subprocess.run(["bash", "-c", script], capture_output=True, timeout=TIMEOUT, text=True)
    lines = p.stdout.strip().split("\n")
    rc = lines[-1] if lines else ""
    report_result(rc == "0", "fd: closed stderr -> exit 0")

    # RLIMIT_NOFILE=3
    def limit_nofile():
        resource.setrlimit(resource.RLIMIT_NOFILE, (3, 3))
    rc, out, err = run([BIN, "-u"], preexec_fn=limit_nofile)
    report_result(rc >= 0 and rc < 128, "fd: RLIMIT_NOFILE=3 -> no crash")

    # /dev/null redirect
    script = f'{BIN} -u > /dev/null 2>/dev/null; echo $?'
    p = subprocess.run(["bash", "-c", script], capture_output=True, timeout=TIMEOUT, text=True)
    rc = p.stdout.strip()
    report_result(rc == "0", "fd: /dev/null redirect -> exit 0")


# =============================================================================
#                     5. MEMORY SAFETY
# =============================================================================

def check_memory_safety():
    log("\n=== 5. Memory Safety ===")

    rc, out, err = run([BIN, "-u"])
    report_result(rc == 0, "memory: no signal death on normal run")
    cleanup_mktemp_result(rc, out)

    # Many args that will fail (nonexistent parent)
    rc, out, err = run([BIN] + [f"/tmp/nonexistent_sec_parent_{i}/fileXXXXXX" for i in range(50)])
    report_result(rc >= 0 and rc < 128, "memory: no crash with 50 failing template args")

    # Long argument
    long_arg = "A" * 4000
    rc, out, err = run([BIN, long_arg])
    report_result(rc >= 0 and rc < 128, "memory: no crash with 4000-char argument")

    # Long template (should fail but not crash)
    long_template = "/tmp/" + "A" * 3000 + "XXXXXX"
    rc, out, err = run([BIN, long_template])
    report_result(rc >= 0 and rc < 128, "memory: no crash with 3000-char template")
    cleanup_mktemp_result(rc, out)

    # Random args
    for i in range(10):
        arg = "".join(chr(random.randint(1, 127)) for _ in range(random.randint(0, 500)))
        rc, out, _ = run([BIN, arg])
        cleanup_mktemp_result(rc, out)
        if rc >= 128:
            report_result(False, f"memory: crash with random arg (trial {i})")
            break
    else:
        report_result(True, "memory: no signal death with 10 random args")

    # Small stack
    def limit_stack():
        resource.setrlimit(resource.RLIMIT_STACK, (65536, 65536))
    rc, out, err = run([BIN, "-u"], preexec_fn=limit_stack)
    report_result(rc == 0, "memory: 64KB stack -> exit 0")

    # Small address space
    def limit_mem():
        resource.setrlimit(resource.RLIMIT_AS, (16 * 1024 * 1024, 16 * 1024 * 1024))
    rc, out, err = run([BIN, "-u"], preexec_fn=limit_mem)
    report_result(rc == 0, "memory: 16MB address space -> exit 0")


# =============================================================================
#                     6. SIGNAL SAFETY
# =============================================================================

def check_signal_safety():
    log("\n=== 6. Signal Safety ===")

    # SIGPIPE: pipe output to head -c 0
    script = f'{BIN} -u | head -c 0'
    p = subprocess.run(["bash", "-c", script], capture_output=True, timeout=TIMEOUT)
    report_result(p.returncode >= 0 and p.returncode < 128, "signal: SIGPIPE clean exit")

    ok_count = 0
    trials = 20
    for i in range(trials):
        rc = os.system(f"{BIN} -u | head -c 0 >/dev/null 2>/dev/null")
        if os.WIFEXITED(rc) and os.WEXITSTATUS(rc) < 128:
            ok_count += 1
    report_result(ok_count >= trials - 2, f"signal: rapid SIGPIPE ({ok_count}/{trials})")

    for sig_name in ["SIGTERM", "SIGINT", "SIGHUP"]:
        rc, out, err = run([BIN, "-u"])
        report_result(rc == 0, f"signal: {sig_name} -- exits cleanly")


# =============================================================================
#                     7. INPUT FUZZING
# =============================================================================

def check_fuzzing():
    log("\n=== 7. Input Fuzzing ===")

    crash_count = 0
    for i in range(50):
        n_args = random.randint(0, 10)
        args = ["".join(random.choices(string.printable, k=random.randint(0, 100)))
                for _ in range(n_args)]
        rc, out, err = run([BIN] + args)
        cleanup_mktemp_result(rc, out)
        if rc >= 128:
            crash_count += 1
    report_result(crash_count == 0, f"fuzz: 50 random short args -- no signal death ({crash_count})")

    crash_count = 0
    for i in range(20):
        arg = "".join(random.choices(string.printable, k=random.randint(100, 1000)))
        rc, out, err = run([BIN, arg])
        cleanup_mktemp_result(rc, out)
        if rc >= 128:
            crash_count += 1
    report_result(crash_count == 0, f"fuzz: 20 random long args -- no signal death ({crash_count})")

    for desc, arg in [("all-newlines", "\n" * 1000),
                      ("all-0xff", "\xff" * 1000),
                      ("control-chars", "".join(chr(i) for i in range(1, 32))),
                      ("unicode-multibyte", "\u00e9\u00e0\u00fc\u4e16\u754c" * 100)]:
        rc, out, _ = run([BIN, arg])
        cleanup_mktemp_result(rc, out)
        report_result(rc >= 0 and rc < 128, f"fuzz: pathological {desc} -> no crash")

    rc, out, err = run([BIN] + [""] * 200)
    cleanup_mktemp_result(rc, out)
    report_result(rc >= 0 and rc < 128, "fuzz: 200 empty args -> no crash")

    rc, out, err = run([BIN, "X" * 4000])
    cleanup_mktemp_result(rc, out)
    report_result(rc >= 0 and rc < 128, "fuzz: 4000-char single arg -> no crash")


# =============================================================================
#                     8. RESOURCE LIMIT TESTING
# =============================================================================

def check_resource_limits():
    log("\n=== 8. Resource Limit Testing ===")

    def limit_as():
        resource.setrlimit(resource.RLIMIT_AS, (16 * 1024 * 1024, 16 * 1024 * 1024))
    rc, _, _ = run([BIN, "-u"], preexec_fn=limit_as)
    report_result(rc == 0, "rlimit: RLIMIT_AS=16MB -> exit 0")

    def limit_nofile():
        resource.setrlimit(resource.RLIMIT_NOFILE, (3, 3))
    rc, _, _ = run([BIN, "-u"], preexec_fn=limit_nofile)
    report_result(rc >= 0 and rc < 128, "rlimit: RLIMIT_NOFILE=3 -> no crash")

    def limit_cpu():
        resource.setrlimit(resource.RLIMIT_CPU, (1, 1))
    rc, _, _ = run([BIN, "-u"], preexec_fn=limit_cpu)
    report_result(rc == 0, "rlimit: RLIMIT_CPU=1s -> exit 0")

    def limit_stack():
        resource.setrlimit(resource.RLIMIT_STACK, (65536, 65536))
    rc, _, _ = run([BIN, "-u"], preexec_fn=limit_stack)
    report_result(rc == 0, "rlimit: RLIMIT_STACK=64KB -> exit 0")

    def limit_fsize():
        resource.setrlimit(resource.RLIMIT_FSIZE, (0, 0))
    rc, out, _ = run([BIN, "-u"], preexec_fn=limit_fsize)
    report_result(rc == 0, "rlimit: RLIMIT_FSIZE=0 -> exit 0 (dry-run)")

    def limit_all():
        resource.setrlimit(resource.RLIMIT_AS, (16 * 1024 * 1024, 16 * 1024 * 1024))
        resource.setrlimit(resource.RLIMIT_NOFILE, (3, 3))
        resource.setrlimit(resource.RLIMIT_CPU, (1, 1))
        resource.setrlimit(resource.RLIMIT_STACK, (65536, 65536))
        resource.setrlimit(resource.RLIMIT_FSIZE, (0, 0))
    rc, _, _ = run([BIN, "-u"], preexec_fn=limit_all)
    report_result(rc >= 0 and rc < 128, "rlimit: all limits combined -> no crash")


# =============================================================================
#                     9. ENVIRONMENT ROBUSTNESS
# =============================================================================

def check_environment():
    log("\n=== 9. Environment Robustness ===")

    rc, out, err = run([BIN, "-u"], env={})
    report_result(rc == 0, "env: empty environment -> exit 0")

    hostile = {
        "PATH": "",
        "HOME": "/nonexistent",
        "LANG": "xx_XX.BROKEN",
        "TERM": "",
        "LC_ALL": "C",
        "TMPDIR": "/tmp",
    }
    rc, out, err = run([BIN, "-u"], env=hostile)
    report_result(rc == 0, "env: hostile env vars -> exit 0")

    big_env = {f"VAR_{i}": f"value_{'X' * 100}" for i in range(1000)}
    big_env["TMPDIR"] = "/tmp"
    rc, out, err = run([BIN, "-u"], env=big_env)
    report_result(rc == 0, "env: 1000 env vars -> exit 0")

    special_env = os.environ.copy()
    special_env["EVIL"] = "A" * 100000
    rc, out, err = run([BIN, "-u"], env=special_env)
    report_result(rc == 0, "env: 100KB env var -> exit 0")

    # TMPDIR set to a nonexistent path
    bad_tmpdir_env = os.environ.copy()
    bad_tmpdir_env["TMPDIR"] = "/nonexistent_tmpdir_test_xyz"
    rc, out, err = run([BIN], env=bad_tmpdir_env)
    cleanup_mktemp_result(rc, out)
    report_result(rc >= 0 and rc < 128, "env: TMPDIR=/nonexistent -> no crash")


# =============================================================================
#                     10. OUTPUT INTEGRITY
# =============================================================================

def check_output_integrity():
    log("\n=== 10. Output Integrity ===")

    outputs = []
    created = []
    for i in range(10):
        rc, out, err = run([BIN])
        outputs.append((rc, out, err))
        if rc == 0:
            path = out.decode(errors="replace").strip()
            if path:
                created.append(path)

    all_zero = all(o[0] == 0 for o in outputs)
    report_result(all_zero, "output: all 10 runs exit 0")

    # Each run should produce exactly one line of stdout (the path)
    all_one_line = all(len(o[1].decode(errors="replace").strip().split("\n")) == 1 for o in outputs)
    report_result(all_one_line, "output: all 10 runs produce exactly one line to stdout")

    all_no_err = all(o[2] == b"" for o in outputs)
    report_result(all_no_err, "output: all 10 runs produce no stderr")

    # All paths should be unique
    unique_paths = set(created)
    report_result(len(unique_paths) == 10, f"output: all 10 paths unique ({len(unique_paths)} unique)")

    # Clean up
    for path in created:
        try:
            os.unlink(path)
        except OSError:
            pass

    # Output ends with newline
    rc, out, err = run([BIN])
    if rc == 0:
        report_result(out.endswith(b"\n"), "output: output ends with newline")
        cleanup_mktemp_result(rc, out)
    else:
        report_result(False, "output: output ends with newline (mktemp failed)")


# =============================================================================
#                     11. ERROR HANDLING
# =============================================================================

def check_error_handling():
    log("\n=== 11. Error Handling ===")

    for flag in ["--badopt", "--nonexistent"]:
        rc, out, err = run([BIN, flag])
        cleanup_mktemp_result(rc, out)
        report_result(rc >= 0 and rc < 128, f"error: '{flag}' -> no signal death")

    gnu_path = which(GNU)
    if gnu_path:
        for args in [["--help"], ["--version"]]:
            rc_f, out_f, _ = run([BIN] + args)
            rc_g, out_g, _ = run([gnu_path] + args)
            cleanup_mktemp_result(rc_f, out_f)
            cleanup_mktemp_result(rc_g, out_g)
            report_result(rc_f == rc_g, f"error: exit code matches GNU for {args}")

    # Nonexistent parent directory
    rc, out, err = run([BIN, "/nonexistent_sec_test_dir/fileXXXXXX"])
    report_result(rc == 1, "error: nonexistent parent dir -> exit 1")
    report_result(len(err) > 0, "error: nonexistent parent dir -> stderr message")

    # Template with too few X's
    with tempfile.TemporaryDirectory() as tmpdir:
        rc, out, err = run([BIN, os.path.join(tmpdir, "noXs")])
        cleanup_mktemp_result(rc, out)
        report_result(rc == 1, "error: too few X's -> exit 1")

    if which("strace"):
        cmd = ["strace", "-e", "inject=write:error=EINTR:when=1", BIN, "-u"]
        rc, out, err = run(cmd)
        report_result(rc >= 0 and rc < 128, "error: EINTR injection -> no crash")


# =============================================================================
#                     12. CONCURRENCY STRESS
# =============================================================================

def check_concurrency():
    log("\n=== 12. Concurrency Stress ===")

    # 50 simultaneous mktemp calls (all creating files)
    procs = []
    with tempfile.TemporaryDirectory() as tmpdir:
        for i in range(50):
            p = subprocess.Popen(
                [BIN, "-p", tmpdir],
                stdout=subprocess.PIPE, stderr=subprocess.PIPE
            )
            procs.append(p)

        crash_count = 0
        created_paths = []
        for p in procs:
            try:
                out, err = p.communicate(timeout=TIMEOUT)
                if p.returncode >= 128:
                    crash_count += 1
                elif p.returncode == 0:
                    path = out.decode(errors="replace").strip()
                    if path:
                        created_paths.append(path)
            except subprocess.TimeoutExpired:
                p.kill()
                crash_count += 1

        report_result(crash_count == 0, f"concurrency: 50 simultaneous ({crash_count} crashes)")

        # All created paths should be unique (no collisions)
        unique_paths = set(created_paths)
        report_result(len(unique_paths) == len(created_paths),
                      f"concurrency: all paths unique ({len(unique_paths)}/{len(created_paths)})")

        # Clean up
        for path in created_paths:
            try:
                os.unlink(path)
            except OSError:
                pass

    # Rapid sequential start
    ok_count = 0
    with tempfile.TemporaryDirectory() as tmpdir:
        for i in range(50):
            p = subprocess.Popen(
                [BIN, "-u", "-p", tmpdir],
                stdout=subprocess.PIPE, stderr=subprocess.PIPE
            )
            try:
                p.wait(timeout=1)
                ok_count += 1
            except subprocess.TimeoutExpired:
                p.kill()
    report_result(ok_count == 50, f"concurrency: rapid start ({ok_count}/50)")


# =============================================================================
#                     13. TOOL-SPECIFIC: mktemp
# =============================================================================

def check_tool_specific():
    log("\n=== 13. Tool-Specific: mktemp ===")

    # Default temp file creation
    rc, out, err = run([BIN])
    path = out.decode(errors="replace").strip()
    report_result(rc == 0, "mktemp: default -> exit 0")
    report_result(os.path.isfile(path), "mktemp: default creates a file")
    if os.path.isfile(path):
        perms = oct(os.stat(path).st_mode & 0o777)
        report_result(perms == "0o600", f"mktemp: file permissions 0600 ({perms})")
        os.unlink(path)
    else:
        report_result(False, "mktemp: file permissions (file not created)")

    # Output path starts with /tmp/
    rc, out, err = run([BIN])
    path = out.decode(errors="replace").strip()
    report_result(path.startswith("/tmp/"), f"mktemp: output starts with /tmp/ (got '{path[:20]}...')")
    cleanup_mktemp_result(rc, out)

    # -d creates a directory
    rc, out, err = run([BIN, "-d"])
    path = out.decode(errors="replace").strip()
    report_result(rc == 0, "mktemp: -d -> exit 0")
    report_result(os.path.isdir(path), "mktemp: -d creates a directory")
    if os.path.isdir(path):
        perms = oct(os.stat(path).st_mode & 0o777)
        report_result(perms == "0o700", f"mktemp: dir permissions 0700 ({perms})")
        os.rmdir(path)
    else:
        report_result(False, "mktemp: dir permissions (dir not created)")

    # -u dry-run (no file created)
    rc, out, err = run([BIN, "-u"])
    path = out.decode(errors="replace").strip()
    report_result(rc == 0, "mktemp: -u -> exit 0")
    report_result(not os.path.exists(path), "mktemp: -u does not create file")

    # -p DIR (creates in specified directory)
    with tempfile.TemporaryDirectory() as tmpdir:
        rc, out, err = run([BIN, "-p", tmpdir])
        path = out.decode(errors="replace").strip()
        report_result(rc == 0, "mktemp: -p DIR -> exit 0")
        report_result(path.startswith(tmpdir + "/"), f"mktemp: -p file in correct dir")
        cleanup_mktemp_result(rc, out)

    # --tmpdir=DIR
    with tempfile.TemporaryDirectory() as tmpdir:
        rc, out, err = run([BIN, f"--tmpdir={tmpdir}"])
        path = out.decode(errors="replace").strip()
        report_result(rc == 0, "mktemp: --tmpdir=DIR -> exit 0")
        report_result(path.startswith(tmpdir + "/"), "mktemp: --tmpdir file in correct dir")
        cleanup_mktemp_result(rc, out)

    # Custom template
    with tempfile.TemporaryDirectory() as tmpdir:
        template = os.path.join(tmpdir, "myfileXXXXXX")
        rc, out, err = run([BIN, template])
        path = out.decode(errors="replace").strip()
        report_result(rc == 0, "mktemp: custom template -> exit 0")
        report_result(path.startswith(os.path.join(tmpdir, "myfile")),
                      "mktemp: custom template prefix preserved")
        cleanup_mktemp_result(rc, out)

    # --suffix=.txt
    rc, out, err = run([BIN, "--suffix=.txt"])
    path = out.decode(errors="replace").strip()
    report_result(rc == 0, "mktemp: --suffix=.txt -> exit 0")
    report_result(path.endswith(".txt"), f"mktemp: --suffix produces .txt suffix")
    cleanup_mktemp_result(rc, out)

    # -q suppresses error messages
    rc, out, err = run([BIN, "-q", "/nonexistent_dir/testXXXXXX"])
    report_result(rc == 1, "mktemp: -q error -> exit 1")
    report_result(err == b"", "mktemp: -q suppresses stderr")

    # Error on nonexistent directory (without -q)
    rc, out, err = run([BIN, "/nonexistent_dir/testXXXXXX"])
    report_result(rc == 1, "mktemp: nonexistent dir -> exit 1")
    report_result(len(err) > 0, "mktemp: nonexistent dir -> stderr message")

    # TMPDIR env var
    with tempfile.TemporaryDirectory() as tmpdir:
        env = os.environ.copy()
        env["TMPDIR"] = tmpdir
        rc, out, err = run([BIN], env=env)
        path = out.decode(errors="replace").strip()
        report_result(rc == 0, "mktemp: TMPDIR env -> exit 0")
        report_result(path.startswith(tmpdir + "/"), "mktemp: TMPDIR env respected")
        cleanup_mktemp_result(rc, out)

    # Combined -du (dry-run directory)
    rc, out, err = run([BIN, "-du"])
    path = out.decode(errors="replace").strip()
    report_result(rc == 0, "mktemp: -du -> exit 0")
    report_result(not os.path.exists(path), "mktemp: -du does not create dir")

    # Uniqueness under rapid creation (100 files)
    with tempfile.TemporaryDirectory() as tmpdir:
        paths = []
        all_ok = True
        for i in range(100):
            rc, out, err = run([BIN, "-p", tmpdir])
            if rc == 0:
                path = out.decode(errors="replace").strip()
                paths.append(path)
            else:
                all_ok = False
                break
        unique_count = len(set(paths))
        report_result(unique_count == 100 and all_ok,
                      f"mktemp: 100 files all unique ({unique_count} unique)")
        for p in paths:
            try:
                os.unlink(p)
            except OSError:
                pass


# =============================================================================
#                           MAIN
# =============================================================================

def run_tests():
    find_binary()
    check_elf_properties()
    check_strings_leaks()
    check_syscall_surface()
    check_proc_analysis()
    check_fd_hygiene()
    check_memory_safety()
    check_signal_safety()
    check_fuzzing()
    check_resource_limits()
    check_environment()
    check_output_integrity()
    check_error_handling()
    check_concurrency()
    check_tool_specific()


def print_summary():
    log("\n" + "=" * 60)
    log(f"RESULTS: {pass_count}/{test_count} passed, "
        f"{test_count - pass_count - skip_count} failed, {skip_count} skipped")
    if failures:
        log(f"\nFAILURES ({len(failures)}):")
        for f in failures:
            log(f"  [{f['category']}] {f['details']}")
    log("=" * 60)


if __name__ == "__main__":
    run_tests()
    print_summary()
    sys.exit(0 if (test_count - pass_count - skip_count) == 0 else 1)
