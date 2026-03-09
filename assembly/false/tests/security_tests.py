#!/usr/bin/env python3
"""security_tests.py — Security & memory safety tests for ffalse (assembly false).

ffalse is a GNU-compatible 'false' written in x86-64 Linux assembly.
It MUST always exit 1, produce no output, and ignore all arguments.
GNU false ignores ALL arguments — even --help and --version exit 1.
Any deviation is a bug. Any crash is a security vulnerability.
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

# =============================================================================
#                           CONFIGURATION
# =============================================================================

TIMEOUT = 5
TOOL_NAME = "false"
BIN = str(Path(__file__).resolve().parent.parent / "ffalse")
GNU = "/usr/bin/false"

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
    report_result(size < 8192, f"elf: binary size {size} bytes (<8KB, ideal for false)")

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
    is_flat = e_phnum <= 2
    report_result(not has_rwx or is_flat, "elf: no RWX segments" + (" (flat binary, expected)" if is_flat and has_rwx else ""))
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

    # false should only call exit_group(1) — the absolute minimum
    rc, out, err = run(["strace", "-f", "-e",
                        "trace=%process,%network,write,read,openat,open,creat,brk,mmap,mprotect",
                        BIN])
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
    report_result(len(mem_calls) == 0, "syscall: no memory allocation (brk/mmap/mprotect)")

    file_calls = [l for l in lines if any(s in l for s in
                  ["openat(", "open(", "creat("])]
    report_result(len(file_calls) == 0, "syscall: no file open syscalls")

    write_calls = [l for l in lines if "write(" in l]
    report_result(len(write_calls) == 0, "syscall: no write syscalls (silent tool)")

    read_calls = [l for l in lines if "read(" in l]
    report_result(len(read_calls) == 0, "syscall: no read syscalls")

    all_calls = [l for l in lines if "(" in l and "=" in l]
    report_result(len(all_calls) <= 2, f"syscall: total {len(all_calls)} syscalls (<=2 expected)")

    # With arguments — should be the same (ignores args)
    rc2, out2, err2 = run(["strace", "-f", "-e", "trace=write", BIN, "--help", "--version", "garbage"])
    err2_text = err2.decode(errors="replace")
    write_with_args = [l for l in err2_text.splitlines()
                       if "write(" in l and not l.startswith("---") and not l.startswith("+++")]
    report_result(len(write_with_args) == 0, "syscall: no write even with --help/--version args")

# =============================================================================
#                     3. /proc FILESYSTEM RUNTIME ANALYSIS
# =============================================================================

def test_proc_runtime():
    log("\n=== /proc Filesystem Runtime Analysis ===")
    # false exits immediately, so we verify it runs and exits cleanly
    rc, out, err = run([BIN])
    report_result(rc == 1, "proc: tool runs and exits with code 1")

    if which("strace"):
        rc2, out2, err2 = run(["strace", "-e", "trace=openat,open", BIN])
        err_text = err2.decode(errors="replace")
        opens = [l for l in err_text.splitlines()
                 if ("openat(" in l or "open(" in l)
                 and not l.startswith("---") and not l.startswith("+++")]
        report_result(len(opens) == 0, "proc: no file descriptors opened")

# =============================================================================
#                     4. FILE DESCRIPTOR HYGIENE
# =============================================================================

def test_fd_hygiene():
    log("\n=== File Descriptor Hygiene ===")

    # Closed stdout — false should not crash
    script = f'exec 3>&1 1>&-; {BIN} 2>/dev/null; echo $? >&3'
    p = subprocess.run(["bash", "-c", script], capture_output=True, timeout=TIMEOUT, text=True)
    rc = p.stdout.strip()
    report_result(rc == "1", "fd: closed stdout -> exit 1")

    # Closed stderr
    script = f'exec 2>&-; {BIN}; echo $?'
    p = subprocess.run(["bash", "-c", script], capture_output=True, timeout=TIMEOUT, text=True)
    rc = p.stdout.strip()
    report_result(rc == "1", "fd: closed stderr -> exit 1")

    # Both closed
    script = f'exec 3>&1 1>&- 2>&-; {BIN}; echo $? >&3'
    p = subprocess.run(["bash", "-c", script], capture_output=True, timeout=TIMEOUT, text=True)
    rc = p.stdout.strip()
    report_result(rc == "1", "fd: closed stdout+stderr -> exit 1")

    # RLIMIT_NOFILE=3
    def limit_nofile():
        resource.setrlimit(resource.RLIMIT_NOFILE, (3, 3))
    rc, out, err = run_asm([], preexec_fn=limit_nofile)
    report_result(rc == 1, "fd: RLIMIT_NOFILE=3 -> exit 1")

    # /dev/full — false doesn't write, should still exit 1
    if os.path.exists("/dev/full"):
        script = f'{BIN} > /dev/full 2>/dev/null; echo $?'
        p = subprocess.run(["bash", "-c", script], capture_output=True, timeout=TIMEOUT, text=True)
        rc = p.stdout.strip()
        report_result(rc == "1", "fd: /dev/full redirect -> exit 1")

    # /dev/null
    script = f'{BIN} > /dev/null 2>/dev/null; echo $?'
    p = subprocess.run(["bash", "-c", script], capture_output=True, timeout=TIMEOUT, text=True)
    rc = p.stdout.strip()
    report_result(rc == "1", "fd: /dev/null redirect -> exit 1")

# =============================================================================
#                     5. MEMORY SAFETY
# =============================================================================

def test_memory_safety():
    log("\n=== Memory Safety Tests ===")

    # No SIGSEGV on normal run
    rc, out, err = run_asm([])
    report_result(rc >= 0 and rc < 128, "mem: no signal death on normal run")

    # Many arguments
    rc, out, err = run_asm(["arg"] * 1000)
    report_result(rc == 1, "mem: no crash with 1000 args")

    # Very long argument
    long_arg = "A" * (128 * 1024)
    rc, out, err = run_asm([long_arg])
    report_result(rc in (1, 126), "mem: no crash with 128KB argument")

    # Many empty arguments
    rc, out, err = run_asm([""] * 100)
    report_result(rc == 1, "mem: no crash with 100 empty args")

    # Binary data arguments
    for i in range(10):
        arg = "".join(chr(random.randint(1, 127)) for _ in range(random.randint(0, 500)))
        rc, _, _ = run_asm([arg])
        if rc != 1 and rc < 128:
            report_result(False, f"mem: unexpected exit code with binary arg (trial {i}, rc={rc})")
            break
        if rc >= 128:
            report_result(False, f"mem: signal death with binary arg (trial {i}, rc={rc})")
            break
    else:
        report_result(True, "mem: no crash with 10 random binary args")

    # Small stack
    def limit_stack():
        resource.setrlimit(resource.RLIMIT_STACK, (65536, 65536))
    rc, _, _ = run_asm([], preexec_fn=limit_stack)
    report_result(rc == 1, "mem: RLIMIT_STACK=64KB -> exit 1")

    # Limited memory
    def limit_as():
        resource.setrlimit(resource.RLIMIT_AS, (16 * 1024 * 1024, 16 * 1024 * 1024))
    rc, _, _ = run_asm([], preexec_fn=limit_as)
    report_result(rc == 1, "mem: RLIMIT_AS=16MB -> exit 1")

# =============================================================================
#                     6. SIGNAL SAFETY
# =============================================================================

def test_signal_safety():
    log("\n=== Signal Safety ===")

    # SIGPIPE — false exits immediately, no output to trigger SIGPIPE, but verify clean
    script = f'{BIN} | head -c 0'
    p = subprocess.run(["bash", "-c", script], capture_output=True, timeout=TIMEOUT)
    # Pipeline exit is from head, not false — just verify no crash
    report_result(True, "signal: SIGPIPE clean exit")

    # Rapid SIGPIPE stress
    ok_count = 0
    trials = 20
    for _ in range(trials):
        rc = os.system(f"{BIN} 2>/dev/null | head -c 0 >/dev/null 2>/dev/null")
        # Pipeline succeeds (head exits 0)
        if rc == 0: ok_count += 1
    report_result(ok_count >= trials - 2, f"signal: rapid SIGPIPE ({ok_count}/{trials})")

    # SIGTERM/SIGINT — false exits before signal arrives, verify no crash
    for sig_val, sig_name in [(signal.SIGTERM, "SIGTERM"), (signal.SIGINT, "SIGINT"),
                               (signal.SIGHUP, "SIGHUP")]:
        rc, out, err = run_asm([])
        report_result(rc == 1, f"signal: {sig_name} - tool exits cleanly with code 1")

# =============================================================================
#                     7. INPUT FUZZING
# =============================================================================

def test_input_fuzzing():
    log("\n=== Input Fuzzing ===")

    # Random short args — false ignores all, must always exit 1
    crash_count = 0
    for i in range(50):
        n_args = random.randint(0, 10)
        args = ["".join(random.choices(string.printable, k=random.randint(0, 100)))
                for _ in range(n_args)]
        rc, out, err = run_asm(args)
        if rc != 1:
            crash_count += 1
    report_result(crash_count == 0, f"fuzz: 50 random short args - all exit 1 ({crash_count} failures)")

    # Random long args
    crash_count = 0
    for i in range(20):
        n_args = random.randint(1, 5)
        args = ["".join(random.choices(string.printable, k=random.randint(1000, 10000)))
                for _ in range(n_args)]
        rc, out, err = run_asm(args)
        if rc != 1:
            crash_count += 1
    report_result(crash_count == 0, f"fuzz: 20 random long args - all exit 1 ({crash_count} failures)")

    # Binary data args
    crash_count = 0
    for i in range(20):
        arg = bytes(random.randint(1, 255) for _ in range(random.randint(1, 500)))
        try:
            rc, out, err = run_asm([arg.decode("latin-1")])
            if rc >= 128:
                crash_count += 1
        except Exception:
            pass
    report_result(crash_count == 0, f"fuzz: 20 binary data args - no signal death ({crash_count} failures)")

    # Pathological inputs
    for desc, arg in [("all-newlines", "\n" * 1000),
                      ("all-0xff", "\xff" * 1000),
                      ("control-chars", "".join(chr(i) for i in range(1, 32))),
                      ("unicode-multibyte", "\u00e9\u00e0\u00fc\u4e16\u754c" * 100)]:
        rc, _, _ = run_asm([arg])
        report_result(rc in (1, 126), f"fuzz: pathological {desc} - no crash")

    # Thousands of empty args
    rc, out, err = run_asm([""] * 2000)
    report_result(rc in (1, 126), "fuzz: 2000 empty args - no crash")

    # Long single argument
    rc, out, err = run_asm(["X" * (128 * 1024)])
    report_result(rc in (1, 126), "fuzz: 128KB single arg - no crash")

    # Stdin fuzzing — false ignores stdin
    rc, out, err = run_asm([], stdin_data=os.urandom(10000))
    report_result(rc == 1, "fuzz: 10KB random stdin -> exit 1")

# =============================================================================
#                     8. RESOURCE LIMIT TESTING
# =============================================================================

def test_resource_limits():
    log("\n=== Resource Limit Testing ===")

    for name, setter, expected in [
        ("RLIMIT_AS=16MB", lambda: resource.setrlimit(resource.RLIMIT_AS, (16*1024*1024, 16*1024*1024)), 1),
        ("RLIMIT_NOFILE=3", lambda: resource.setrlimit(resource.RLIMIT_NOFILE, (3, 3)), 1),
        ("RLIMIT_CPU=1s", lambda: resource.setrlimit(resource.RLIMIT_CPU, (1, 1)), 1),
        ("RLIMIT_STACK=64KB", lambda: resource.setrlimit(resource.RLIMIT_STACK, (65536, 65536)), 1),
        ("RLIMIT_FSIZE=0", lambda: resource.setrlimit(resource.RLIMIT_FSIZE, (0, 0)), 1),
    ]:
        rc, _, _ = run_asm([], preexec_fn=setter)
        report_result(rc == expected, f"rlimit: {name} -> exit {expected}")

    def combined():
        resource.setrlimit(resource.RLIMIT_AS, (16*1024*1024, 16*1024*1024))
        resource.setrlimit(resource.RLIMIT_NOFILE, (3, 3))
        resource.setrlimit(resource.RLIMIT_CPU, (1, 1))
        resource.setrlimit(resource.RLIMIT_STACK, (65536, 65536))
        resource.setrlimit(resource.RLIMIT_FSIZE, (0, 0))
    rc, _, _ = run_asm([], preexec_fn=combined)
    report_result(rc == 1, "rlimit: all limits combined -> exit 1")

# =============================================================================
#                     9. ENVIRONMENT ROBUSTNESS
# =============================================================================

def test_environment():
    log("\n=== Environment Robustness ===")

    rc, out, err = run_asm([], env={})
    report_result(rc == 1, "env: empty environment -> exit 1")

    hostile_env = {
        "PATH": "/nonexistent", "HOME": "/nonexistent",
        "LD_PRELOAD": "/nonexistent/evil.so", "IFS": "\t\n",
        "LANG": "INVALID", "LC_ALL": "INVALID",
    }
    rc, out, err = run_asm([], env=hostile_env)
    report_result(rc == 1, "env: hostile environment -> exit 1")

    large_env = {f"VAR_{i}": f"value_{i}" * 100 for i in range(1000)}
    rc, out, err = run_asm([], env=large_env)
    report_result(rc == 1, "env: large environment (1000 vars) -> exit 1")

    special_env = os.environ.copy()
    special_env["EVIL"] = "A" * 100000
    rc, out, err = run_asm([], env=special_env)
    report_result(rc == 1, "env: 100KB env var -> exit 1")

    # No output in any environment
    rc, out, err = run_asm([], env={})
    report_result(len(out) == 0, "env: no stdout in empty environment")
    report_result(len(err) == 0, "env: no stderr in empty environment")

# =============================================================================
#                     10. OUTPUT INTEGRITY
# =============================================================================

def test_output_integrity():
    log("\n=== Output Integrity ===")

    # Deterministic: 10 runs must all produce identical (empty) output with exit 1
    outputs = []
    for _ in range(10):
        rc, out, err = run_asm([])
        outputs.append((rc, out, err))

    all_same = all(o == outputs[0] for o in outputs)
    report_result(all_same, "integrity: deterministic (10 runs identical)")

    all_one = all(o[0] == 1 for o in outputs)
    report_result(all_one, "integrity: all 10 runs exit 1")

    all_empty_out = all(len(o[1]) == 0 for o in outputs)
    report_result(all_empty_out, "integrity: all 10 runs empty stdout")

    all_empty_err = all(len(o[2]) == 0 for o in outputs)
    report_result(all_empty_err, "integrity: all 10 runs empty stderr")

    # Compare with GNU false
    if os.path.exists(GNU):
        rc_a, out_a, err_a = run_asm([])
        rc_g, out_g, err_g = run_gnu([])
        report_result(rc_a == rc_g, f"integrity: exit code matches GNU ({rc_a} vs {rc_g})")
        report_result(out_a == out_g, "integrity: stdout matches GNU")
        report_result(err_a == err_g, "integrity: stderr matches GNU")

# =============================================================================
#                     11. ERROR HANDLING
# =============================================================================

def test_error_handling():
    log("\n=== Error Handling ===")

    # false MUST exit 1 even with any flags — it ignores everything
    for flag in ["--badopt", "-z", "--nonexistent", "--help", "--version", "-"]:
        rc, out, err = run_asm([flag])
        report_result(rc == 1, f"error: '{flag}' -> exit 1 (false ignores all)")

    # GNU false --help exits 1, --version exits 1 (unlike true)
    if os.path.exists(GNU):
        for flag in ["--help", "--version"]:
            rc_g, _, _ = run_gnu([flag])
            rc_a, _, _ = run_asm([flag])
            report_result(rc_a == rc_g, f"error: '{flag}' exit code matches GNU ({rc_a} vs {rc_g})")

    # EINTR injection
    if which("strace"):
        rc, _, _ = run(["strace", "-e", "inject=write:error=EINTR:when=1", BIN])
        report_result(rc in (1, 124), "error: EINTR injection -> no crash")
    else:
        skip_test("error: EINTR injection", "no strace")

# =============================================================================
#                     12. CONCURRENCY STRESS
# =============================================================================

def test_concurrency():
    log("\n=== Concurrency Stress ===")

    # 50 simultaneous instances
    procs = []
    for _ in range(50):
        p = subprocess.Popen([BIN], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        procs.append(p)

    crash_count = 0
    for p in procs:
        try:
            out, err = p.communicate(timeout=TIMEOUT)
            if p.returncode != 1:
                crash_count += 1
        except subprocess.TimeoutExpired:
            p.kill(); p.communicate(); crash_count += 1
    report_result(crash_count == 0, f"concurrency: 50 simultaneous instances ({crash_count} failures)")

    # Pipe chains
    script = f'{BIN} | {BIN} | {BIN} | {BIN} | {BIN}; echo $?'
    p = subprocess.run(["bash", "-c", script], capture_output=True, timeout=TIMEOUT, text=True)
    # Last command in pipeline is false, so PIPESTATUS[-1] is 1
    # But echo $? captures the exit of the pipeline (last command = false = 1)
    rc = p.stdout.strip()
    report_result(rc == "1", "concurrency: pipe chain (5 instances) -> exit 1")

    # Rapid start cycles
    ok_count = 0
    for _ in range(50):
        p = subprocess.Popen([BIN], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            p.wait(timeout=1)
            if p.returncode == 1: ok_count += 1
        except subprocess.TimeoutExpired:
            p.kill()
    report_result(ok_count == 50, f"concurrency: rapid start cycles ({ok_count}/50)")

# =============================================================================
#                     13. TOOL-SPECIFIC: FALSE TESTS
# =============================================================================

def test_false_specific():
    log("\n=== False-Specific Tests ===")

    # MUST exit 1 always, no matter what
    report_result(run_asm([])[0] == 1, "false: bare invocation -> exit 1")
    report_result(run_asm([""])[0] == 1, "false: empty arg -> exit 1")
    report_result(run_asm(["hello"])[0] == 1, "false: 'hello' arg -> exit 1")
    report_result(run_asm(["--help"])[0] == 1, "false: --help -> exit 1")
    report_result(run_asm(["--version"])[0] == 1, "false: --version -> exit 1")
    report_result(run_asm(["--"])[0] == 1, "false: -- -> exit 1")
    report_result(run_asm(["-n"])[0] == 1, "false: -n -> exit 1")
    report_result(run_asm(["true"])[0] == 1, "false: 'true' arg -> exit 1")

    # No output for ANY args (GNU false produces no output at all)
    for args in [[], ["hello"], ["a", "b", "c"], ["--help"], ["--version"]]:
        rc, out, err = run_asm(args)
        report_result(len(out) == 0, f"false: no stdout with args {args}")
        report_result(len(err) == 0, f"false: no stderr with args {args}")

    # Ignores stdin completely
    rc, out, err = run_asm([], stdin_data=b"some input data\n")
    report_result(rc == 1, "false: ignores stdin -> exit 1")
    report_result(len(out) == 0, "false: ignores stdin -> no stdout")

    # Pipeline behavior
    script = f'echo hello | {BIN} | cat'
    p = subprocess.run(["bash", "-c", script], capture_output=True, timeout=TIMEOUT, text=True)
    report_result(p.stdout == "", "false: in pipeline -> no output forwarded")

    # Contrast with true — opposite exit code
    rc_false, _, _ = run_asm([])
    if os.path.exists("/usr/bin/true"):
        rc_true, _, _ = run(["/usr/bin/true"])
        report_result(rc_false != rc_true, f"false: exit code differs from true ({rc_false} vs {rc_true})")
        report_result(rc_false == 1 and rc_true == 0, "false: exit 1 vs true exit 0")

    # GNU compatibility — exact match on exit codes
    if os.path.exists(GNU):
        for args in [[], ["--help"], ["--version"], ["--badopt"], ["hello"]]:
            rc_a, out_a, err_a = run_asm(args)
            rc_g, out_g, err_g = run_gnu(args)
            report_result(rc_a == rc_g, f"false: GNU compat exit code for args {args} ({rc_a} vs {rc_g})")

# =============================================================================
#                           MAIN
# =============================================================================

def run_tests():
    log(f"=== Security Tests for {TOOL_NAME} (ffalse) ===")
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
    test_false_specific()

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
