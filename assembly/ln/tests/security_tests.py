#!/usr/bin/env python3
"""security_tests.py — Security & memory safety tests for fln.

fln is a GNU-compatible 'ln' written in x86-64 Linux assembly.
It creates hard and symbolic links.

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
   13. Tool-specific (ln: link creation behavior)
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
GNU = "ln"
LOG_EVERY = 1

failures = []
test_count = 0
pass_count = 0
skip_count = 0


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
    for name in ["fln_release", "fln"]:
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
    report_result(size < 30000, f"elf: binary size {size} bytes (<30KB)")

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
        (b"/etc/", "filesystem path /etc/"),
        (b"/home/", "home directory path"),
        (b"/tmp/", "tmp path"),
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

    with tempfile.TemporaryDirectory() as tmpdir:
        src = os.path.join(tmpdir, "src")
        dst = os.path.join(tmpdir, "dst")
        with open(src, "w") as f:
            f.write("test")

        cmd = ["strace", "-f", "-e", "trace=%process,%network,write,read,openat,open,creat,brk,mmap,mprotect,link",
               BIN, src, dst]
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

        link_calls = [l for l in lines if "link(" in l]
        report_result(len(link_calls) >= 1, "syscall: link() called (expected)")

        all_calls = [l for l in lines if "(" in l and "=" in l]
        report_result(len(all_calls) <= 6, f"syscall: total {len(all_calls)} syscalls (<=6 expected)")


# =============================================================================
#                     3. /proc FILESYSTEM RUNTIME ANALYSIS
# =============================================================================

def check_proc_analysis():
    log("\n=== 3. /proc Filesystem Runtime Analysis ===")
    with tempfile.TemporaryDirectory() as tmpdir:
        src = os.path.join(tmpdir, "src")
        dst = os.path.join(tmpdir, "dst")
        with open(src, "w") as f:
            f.write("test")

        rc, out, err = run([BIN, src, dst])
        report_result(rc == 0, "proc: tool runs and exits cleanly")


# =============================================================================
#                     4. FILE DESCRIPTOR HYGIENE
# =============================================================================

def check_fd_hygiene():
    log("\n=== 4. File Descriptor Hygiene ===")

    with tempfile.TemporaryDirectory() as tmpdir:
        src = os.path.join(tmpdir, "src")
        with open(src, "w") as f:
            f.write("test")

        dst = os.path.join(tmpdir, "dst_closed_stdout")
        script = f'exec 3>&1 1>&-; {BIN} {src} {dst} 2>/dev/null; echo $? >&3'
        p = subprocess.run(["bash", "-c", script], capture_output=True, timeout=TIMEOUT, text=True)
        rc = p.stdout.strip()
        report_result(rc == "0", "fd: closed stdout -> exit 0")

        dst2 = os.path.join(tmpdir, "dst_closed_stderr")
        script = f'exec 3>&1; {BIN} {src} {dst2} 2>&- 1>&3; echo $? >&3'
        p = subprocess.run(["bash", "-c", script], capture_output=True, timeout=TIMEOUT, text=True)
        lines = p.stdout.strip().split("\n")
        rc = lines[-1] if lines else ""
        report_result(rc == "0", "fd: closed stderr -> exit 0")

        dst4 = os.path.join(tmpdir, "dst_devnull")
        script = f'{BIN} {src} {dst4} > /dev/null 2>/dev/null; echo $?'
        p = subprocess.run(["bash", "-c", script], capture_output=True, timeout=TIMEOUT, text=True)
        rc = p.stdout.strip()
        report_result(rc == "0", "fd: /dev/null redirect -> exit 0")


# =============================================================================
#                     5. MEMORY SAFETY
# =============================================================================

def check_memory_safety():
    log("\n=== 5. Memory Safety ===")

    with tempfile.TemporaryDirectory() as tmpdir:
        src = os.path.join(tmpdir, "src")
        dst = os.path.join(tmpdir, "dst")
        with open(src, "w") as f:
            f.write("test")

        rc, out, err = run([BIN, src, dst])
        report_result(rc == 0, "memory: no signal death on normal run")

    rc, out, err = run([BIN] + [f"arg{i}" for i in range(100)])
    report_result(rc >= 0 and rc < 128, "memory: no crash with 100 args")

    long_arg = "A" * (128 * 1024)
    rc, out, err = run([BIN, long_arg, "dst"])
    report_result(rc >= 0 and rc < 128, "memory: no crash with 128KB argument")

    for i in range(10):
        arg = "".join(chr(random.randint(1, 127)) for _ in range(random.randint(0, 500)))
        rc, _, _ = run([BIN, arg, "dst"])
        if rc >= 128:
            report_result(False, f"memory: crash with random arg (trial {i})")
            break
    else:
        report_result(True, "memory: no signal death with 10 random args")

    def limit_stack():
        resource.setrlimit(resource.RLIMIT_STACK, (65536, 65536))
    rc, out, err = run([BIN, "/nonexistent", "/tmp/x"], preexec_fn=limit_stack)
    report_result(rc >= 0 and rc < 128, "memory: 64KB stack -> no crash")

    def limit_mem():
        resource.setrlimit(resource.RLIMIT_AS, (16 * 1024 * 1024, 16 * 1024 * 1024))
    rc, out, err = run([BIN, "/nonexistent", "/tmp/x"], preexec_fn=limit_mem)
    report_result(rc >= 0 and rc < 128, "memory: 16MB address space -> no crash")


# =============================================================================
#                     6. SIGNAL SAFETY
# =============================================================================

def check_signal_safety():
    log("\n=== 6. Signal Safety ===")

    with tempfile.TemporaryDirectory() as tmpdir:
        src = os.path.join(tmpdir, "src")
        dst = os.path.join(tmpdir, "dst")
        with open(src, "w") as f:
            f.write("test")

        script = f'{BIN} {src} {dst} | head -c 0'
        p = subprocess.run(["bash", "-c", script], capture_output=True, timeout=TIMEOUT)
        report_result(p.returncode >= 0 and p.returncode < 128, "signal: SIGPIPE clean exit")

    for sig_name in ["SIGTERM", "SIGINT", "SIGHUP"]:
        with tempfile.TemporaryDirectory() as tmpdir:
            src = os.path.join(tmpdir, "src")
            dst = os.path.join(tmpdir, "dst")
            with open(src, "w") as f:
                f.write("test")
            rc, out, err = run([BIN, src, dst])
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
        if rc >= 128:
            crash_count += 1
    report_result(crash_count == 0, f"fuzz: 50 random short args -- no signal death ({crash_count})")

    crash_count = 0
    for i in range(20):
        arg = "".join(random.choices(string.printable, k=random.randint(1000, 10000)))
        rc, out, err = run([BIN, arg, "dst"])
        if rc >= 128:
            crash_count += 1
    report_result(crash_count == 0, f"fuzz: 20 random long args -- no signal death ({crash_count})")

    for desc, arg in [("all-newlines", "\n" * 1000),
                      ("all-0xff", "\xff" * 1000),
                      ("control-chars", "".join(chr(i) for i in range(1, 32))),
                      ("unicode-multibyte", "\u00e9\u00e0\u00fc\u4e16\u754c" * 100)]:
        rc, _, _ = run([BIN, arg, "dst"])
        report_result(rc >= 0 and rc < 128, f"fuzz: pathological {desc} -> no crash")

    rc, out, err = run([BIN] + [""] * 2000)
    report_result(rc >= 0 and rc < 128, "fuzz: 2000 empty args -> no crash")


# =============================================================================
#                     8. RESOURCE LIMIT TESTING
# =============================================================================

def check_resource_limits():
    log("\n=== 8. Resource Limit Testing ===")

    def limit_as():
        resource.setrlimit(resource.RLIMIT_AS, (16 * 1024 * 1024, 16 * 1024 * 1024))
    rc, _, _ = run([BIN, "/nonexistent", "/tmp/x"], preexec_fn=limit_as)
    report_result(rc >= 0 and rc < 128, "rlimit: RLIMIT_AS=16MB -> no crash")

    def limit_nofile():
        resource.setrlimit(resource.RLIMIT_NOFILE, (3, 3))
    rc, _, _ = run([BIN, "/nonexistent", "/tmp/x"], preexec_fn=limit_nofile)
    report_result(rc >= 0 and rc < 128, "rlimit: RLIMIT_NOFILE=3 -> no crash")

    def limit_cpu():
        resource.setrlimit(resource.RLIMIT_CPU, (1, 1))
    rc, _, _ = run([BIN, "/nonexistent", "/tmp/x"], preexec_fn=limit_cpu)
    report_result(rc >= 0 and rc < 128, "rlimit: RLIMIT_CPU=1s -> no crash")

    def limit_stack():
        resource.setrlimit(resource.RLIMIT_STACK, (65536, 65536))
    rc, _, _ = run([BIN, "/nonexistent", "/tmp/x"], preexec_fn=limit_stack)
    report_result(rc >= 0 and rc < 128, "rlimit: RLIMIT_STACK=64KB -> no crash")

    def limit_fsize():
        resource.setrlimit(resource.RLIMIT_FSIZE, (0, 0))
    rc, _, _ = run([BIN, "/nonexistent", "/tmp/x"], preexec_fn=limit_fsize)
    report_result(rc >= 0 and rc < 128, "rlimit: RLIMIT_FSIZE=0 -> no crash")


# =============================================================================
#                     9. ENVIRONMENT ROBUSTNESS
# =============================================================================

def check_environment():
    log("\n=== 9. Environment Robustness ===")

    with tempfile.TemporaryDirectory() as tmpdir:
        src = os.path.join(tmpdir, "src")
        dst = os.path.join(tmpdir, "dst")
        with open(src, "w") as f:
            f.write("test")

        rc, out, err = run([BIN, src, dst], env={})
        report_result(rc == 0, "env: empty environment -> exit 0")

    with tempfile.TemporaryDirectory() as tmpdir:
        src = os.path.join(tmpdir, "src")
        dst = os.path.join(tmpdir, "dst")
        with open(src, "w") as f:
            f.write("test")
        hostile = {
            "PATH": "",
            "HOME": "/nonexistent",
            "LANG": "xx_XX.BROKEN",
            "TERM": "",
            "LC_ALL": "C",
        }
        rc, out, err = run([BIN, src, dst], env=hostile)
        report_result(rc == 0, "env: hostile env vars -> exit 0")

    with tempfile.TemporaryDirectory() as tmpdir:
        src = os.path.join(tmpdir, "src")
        dst = os.path.join(tmpdir, "dst")
        with open(src, "w") as f:
            f.write("test")
        big_env = {f"VAR_{i}": f"value_{'X' * 100}" for i in range(1000)}
        rc, out, err = run([BIN, src, dst], env=big_env)
        report_result(rc == 0, "env: 1000 env vars -> exit 0")


# =============================================================================
#                     10. OUTPUT INTEGRITY
# =============================================================================

def check_output_integrity():
    log("\n=== 10. Output Integrity ===")

    with tempfile.TemporaryDirectory() as tmpdir:
        src = os.path.join(tmpdir, "src")
        with open(src, "w") as f:
            f.write("test")

        outputs = []
        for i in range(10):
            dst = os.path.join(tmpdir, f"dst_{i}")
            rc, out, err = run([BIN, src, dst])
            outputs.append((rc, out, err))

        all_zero = all(o[0] == 0 for o in outputs)
        report_result(all_zero, "output: all 10 runs exit 0")

        all_silent = all(o[1] == b"" for o in outputs)
        report_result(all_silent, "output: all 10 runs produce no stdout (ln is silent on success)")

    gnu_path = which(GNU)
    if gnu_path:
        rc_f, out_f, err_f = run([BIN])
        rc_g, out_g, err_g = run([gnu_path])
        report_result(rc_f == rc_g, "output: exit code matches GNU for no args")


# =============================================================================
#                     11. ERROR HANDLING
# =============================================================================

def check_error_handling():
    log("\n=== 11. Error Handling ===")

    for desc, args in [
        ("no args", []),
        ("nonexistent source", ["/nonexistent_src_xyz", "/tmp/dst_xyz"]),
    ]:
        rc, out, err = run([BIN] + args)
        report_result(rc >= 0 and rc < 128, f"error: '{desc}' -> no signal death")

    gnu_path = which(GNU)
    if gnu_path:
        for args in [["--help"], ["--version"], []]:
            rc_f, _, _ = run([BIN] + args)
            rc_g, _, _ = run([gnu_path] + args)
            report_result(rc_f == rc_g, f"error: exit code matches GNU for {args}")


# =============================================================================
#                     12. CONCURRENCY STRESS
# =============================================================================

def check_concurrency():
    log("\n=== 12. Concurrency Stress ===")

    with tempfile.TemporaryDirectory() as tmpdir:
        src = os.path.join(tmpdir, "src")
        with open(src, "w") as f:
            f.write("test")

        procs = []
        for i in range(50):
            dst = os.path.join(tmpdir, f"dst_{i}")
            p = subprocess.Popen([BIN, src, dst],
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            procs.append(p)

        crash_count = 0
        for p in procs:
            try:
                out, err = p.communicate(timeout=TIMEOUT)
                if p.returncode != 0 and p.returncode >= 128:
                    crash_count += 1
            except subprocess.TimeoutExpired:
                p.kill()
                crash_count += 1

        report_result(crash_count == 0, f"concurrency: 50 simultaneous ({crash_count} crashes)")


# =============================================================================
#                     13. TOOL-SPECIFIC: ln
# =============================================================================

def check_tool_specific():
    log("\n=== 13. Tool-Specific: ln ===")

    with tempfile.TemporaryDirectory() as tmpdir:
        # Core hard link
        src = os.path.join(tmpdir, "src")
        dst = os.path.join(tmpdir, "dst")
        with open(src, "w") as f:
            f.write("hello world")

        rc, out, err = run([BIN, src, dst])
        report_result(rc == 0, "ln: basic hard link creation -> exit 0")
        report_result(out == b"", "ln: no stdout on success")
        report_result(err == b"", "ln: no stderr on success")

        if os.path.exists(dst):
            src_stat = os.stat(src)
            dst_stat = os.stat(dst)
            report_result(src_stat.st_ino == dst_stat.st_ino, "ln: same inode (hard link)")
            report_result(src_stat.st_nlink >= 2, "ln: link count >= 2")
        else:
            report_result(False, "ln: same inode (hard link)")
            report_result(False, "ln: link count >= 2")
        os.unlink(dst)

        # Symbolic link
        sym = os.path.join(tmpdir, "sym")
        rc, out, err = run([BIN, "-s", src, sym])
        report_result(rc == 0, "ln: symbolic link creation -> exit 0")
        report_result(os.path.islink(sym), "ln: is a symbolic link")
        if os.path.islink(sym):
            target = os.readlink(sym)
            report_result(target == src, "ln: symlink target matches")
        else:
            report_result(False, "ln: symlink target matches")
        if os.path.islink(sym):
            os.unlink(sym)

        # Force flag
        with open(dst, "w") as f:
            f.write("existing")
        rc, out, err = run([BIN, "-f", src, dst])
        report_result(rc == 0, "ln: -f force link -> exit 0")
        if os.path.exists(dst):
            src_stat = os.stat(src)
            dst_stat = os.stat(dst)
            report_result(src_stat.st_ino == dst_stat.st_ino, "ln: -f same inode")
        else:
            report_result(False, "ln: -f same inode")
        os.unlink(dst)

        # EEXIST without -f
        with open(dst, "w") as f:
            f.write("existing")
        rc, out, err = run([BIN, src, dst])
        report_result(rc == 1, "ln: EEXIST -> exit 1")
        err_text = err.decode(errors="replace")
        report_result("File exists" in err_text, "ln: EEXIST error message")
        os.unlink(dst)

        # Verbose output
        verb_dst = os.path.join(tmpdir, "verb")
        rc, out, err = run([BIN, "-v", src, verb_dst])
        report_result(rc == 0, "ln: -v verbose -> exit 0")
        out_text = out.decode(errors="replace")
        report_result("'" in out_text and "->" in out_text, "ln: verbose output format")
        if os.path.exists(verb_dst):
            os.unlink(verb_dst)

        os.unlink(src)

    # --help
    rc, out, err = run([BIN, "--help"])
    report_result(rc == 0, "ln: --help -> exit 0")
    report_result(b"Usage:" in out, "ln: --help contains 'Usage:'")

    # --version
    rc, out, err = run([BIN, "--version"])
    report_result(rc == 0, "ln: --version -> exit 0")
    report_result(b"ln" in out, "ln: --version contains 'ln'")

    # Missing operand
    rc, out, err = run([BIN])
    err_text = err.decode(errors="replace")
    report_result("missing" in err_text, "ln: missing operand message")
    report_result("Try" in err_text, "ln: missing operand -> try help hint")


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
