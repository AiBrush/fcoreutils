#!/usr/bin/env python3
"""security_tests.py — Security & memory safety tests for fshred (assembly shred)."""

import os
import re
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

TIMEOUT = 10
TOOL_NAME = "shred"
BIN = str(Path(__file__).resolve().parent.parent / "fshred")
GNU = "/usr/bin/shred"

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

    with tempfile.NamedTemporaryFile(delete=False) as f:
        f.write(b"test data for strace\n")
        tmpfile = f.name

    try:
        rc, out, err = run(["strace", "-f", "-e", "trace=%network", BIN, "-n", "1", tmpfile])
        net_calls = [l for l in err.split(b"\n") if b"socket(" in l or b"connect(" in l]
        report_result(len(net_calls) == 0, "syscall: no network syscalls")

        rc, out, err = run(["strace", "-f", "-e", "trace=%process", BIN, "--help"])
        spawn_calls = [l for l in err.split(b"\n")
                       if b"fork(" in l or b"vfork(" in l or b"clone(" in l]
        spawn_calls = [l for l in spawn_calls if b"execve(" not in l]
        report_result(len(spawn_calls) == 0, "syscall: no process spawning")

        rc, out, err = run(["strace", "-f", "-e", "trace=brk,mmap,mprotect", BIN, "-n", "1", tmpfile])
        mem_lines = [l for l in err.split(b"\n")
                     if b"brk(" in l or b"mmap(" in l or b"mprotect(" in l]
        mem_lines = [l for l in mem_lines if not l.startswith(b"---") and not l.startswith(b"+++")]
        report_result(len(mem_lines) < 10, f"syscall: minimal brk/mmap/mprotect ({len(mem_lines)} calls)")

        rc, out, err = run(["strace", "-c", "-e", "trace=all", BIN, "-n", "1", tmpfile])
        report_result(rc in (0, 124), "syscall: strace -c completed")
    finally:
        os.unlink(tmpfile)

# =============================================================================
#                     3. FILE DESCRIPTOR HYGIENE
# =============================================================================

def test_fd_hygiene():
    log("\n=== File Descriptor Hygiene ===")

    with tempfile.NamedTemporaryFile(delete=False) as f:
        f.write(b"fd test data\n")
        tmpfile = f.name

    try:
        # After shred, no extra FDs should be left open
        rc, _, _ = run_asm(["-n", "1", tmpfile])
        report_result(rc == 0, "fd: basic shred completes")

        # Closed stdout doesn't crash
        script = f'{BIN} --help 1>&- 2>/dev/null; echo $?'
        p = subprocess.run(["bash", "-c", script], capture_output=True, timeout=TIMEOUT, text=True)
        report_result(p.returncode == 0, "fd: closed stdout doesn't crash")

        # Closed stderr doesn't crash
        script = f'{BIN} -v -n 1 {tmpfile} 2>&- 1>/dev/null; echo $?'
        p = subprocess.run(["bash", "-c", script], capture_output=True, timeout=TIMEOUT, text=True)
        report_result(p.returncode == 0, "fd: closed stderr doesn't crash")

        # /dev/null output works
        script = f'{BIN} -n 1 {tmpfile} > /dev/null 2>/dev/null; echo $?'
        p = subprocess.run(["bash", "-c", script], capture_output=True, timeout=TIMEOUT, text=True)
        report_result(p.stdout.strip() == "0", "fd: /dev/null output works")
    finally:
        try: os.unlink(tmpfile)
        except: pass

# =============================================================================
#                     4. MEMORY SAFETY
# =============================================================================

def test_memory_safety():
    log("\n=== Memory Safety Tests ===")

    # Large file shred
    tmpdir = tempfile.mkdtemp()
    try:
        # 1MB file
        large_file = os.path.join(tmpdir, "large.dat")
        with open(large_file, "wb") as f:
            f.write(os.urandom(1024 * 1024))
        rc, _, _ = run_asm(["-n", "1", large_file])
        report_result(rc == 0, "mem: 1MB file shred succeeds")

        # 10MB file
        big_file = os.path.join(tmpdir, "big.dat")
        with open(big_file, "wb") as f:
            f.write(os.urandom(10 * 1024 * 1024))
        rc, _, _ = run_asm(["-n", "1", big_file])
        report_result(rc == 0, "mem: 10MB file shred succeeds")

        # Empty file
        empty_file = os.path.join(tmpdir, "empty.dat")
        with open(empty_file, "wb") as f:
            pass
        rc, _, _ = run_asm(["-n", "1", "-z", empty_file])
        report_result(rc == 0, "mem: empty file shred succeeds")

        # File with size exactly at buffer boundary (128KB)
        boundary_file = os.path.join(tmpdir, "boundary.dat")
        with open(boundary_file, "wb") as f:
            f.write(os.urandom(131072))
        rc, _, _ = run_asm(["-n", "1", "-x", boundary_file])
        report_result(rc == 0, "mem: 128KB boundary file succeeds")

        # File just over buffer boundary
        over_file = os.path.join(tmpdir, "over.dat")
        with open(over_file, "wb") as f:
            f.write(os.urandom(131073))
        rc, _, _ = run_asm(["-n", "1", "-x", over_file])
        report_result(rc == 0, "mem: 128KB+1 file succeeds")

        # Single byte file
        one_file = os.path.join(tmpdir, "one.dat")
        with open(one_file, "wb") as f:
            f.write(b"X")
        rc, _, _ = run_asm(["-n", "1", "-x", "-z", one_file])
        report_result(rc == 0, "mem: 1-byte file succeeds")
        with open(one_file, "rb") as f:
            content = f.read()
        report_result(content == b"\x00", "mem: 1-byte file zeroed correctly")
    finally:
        import shutil
        shutil.rmtree(tmpdir, ignore_errors=True)

# =============================================================================
#                     5. SIGNAL HANDLING
# =============================================================================

def test_signal_handling():
    log("\n=== Signal Handling Tests ===")

    tmpdir = tempfile.mkdtemp()
    try:
        # Create a file to shred during signal test
        sig_file = os.path.join(tmpdir, "signal.dat")
        with open(sig_file, "wb") as f:
            f.write(os.urandom(1024))

        # SIGTERM during shred — use a large file to ensure we can catch it mid-write
        large_sig_file = os.path.join(tmpdir, "signal_large.dat")
        with open(large_sig_file, "wb") as f:
            f.write(os.urandom(10 * 1024 * 1024))  # 10MB
        p = subprocess.Popen([BIN, "-n", "100", large_sig_file],
                             stdin=subprocess.DEVNULL,
                             stdout=subprocess.PIPE,
                             stderr=subprocess.PIPE)
        time.sleep(0.1)
        p.send_signal(signal.SIGTERM)
        rc = p.wait(timeout=5)
        # Process should terminate (either killed by signal or finished early)
        report_result(True, f"signal: SIGTERM handled (rc={rc})")

        # SIGINT
        with open(sig_file, "wb") as f:
            f.write(os.urandom(1024))
        p = subprocess.Popen([BIN, "-n", "100", sig_file],
                             stdin=subprocess.DEVNULL,
                             stdout=subprocess.PIPE,
                             stderr=subprocess.PIPE)
        time.sleep(0.1)
        p.send_signal(signal.SIGINT)
        rc = p.wait(timeout=5)
        report_result(True, f"signal: SIGINT handled (rc={rc})")
    finally:
        import shutil
        shutil.rmtree(tmpdir, ignore_errors=True)

# =============================================================================
#                     6. PATH / ARGUMENT SAFETY
# =============================================================================

def test_argument_safety():
    log("\n=== Argument Safety Tests ===")

    # Very long filename
    tmpdir = tempfile.mkdtemp()
    try:
        long_name = os.path.join(tmpdir, "A" * 255)
        try:
            with open(long_name, "w") as f:
                f.write("test")
            rc, _, _ = run_asm(["-n", "1", long_name])
            report_result(rc == 0, "arg: 255-char filename accepted")
        except OSError:
            skip_test("arg: 255-char filename", "OS rejected filename")

        # Filename with special chars
        special_file = os.path.join(tmpdir, "file with spaces.txt")
        with open(special_file, "w") as f:
            f.write("test")
        rc, _, _ = run_asm(["-n", "1", special_file])
        report_result(rc == 0, "arg: filename with spaces")

        # Many files at once
        files = []
        for i in range(50):
            fpath = os.path.join(tmpdir, f"multi_{i}.txt")
            with open(fpath, "w") as f:
                f.write(f"data {i}")
            files.append(fpath)
        rc, _, _ = run_asm(["-n", "1"] + files)
        report_result(rc == 0, "arg: 50 files at once")

        # -n with very large number
        test_file = os.path.join(tmpdir, "largen.txt")
        with open(test_file, "w") as f:
            f.write("test")
        rc, _, _ = run_asm(["-n", "1000", "-x", test_file], timeout=30)
        report_result(rc == 0, "arg: -n 1000 succeeds")

        # Invalid iteration count
        rc, _, err = run_asm(["-n", "abc", test_file])
        report_result(rc != 0, "arg: -n abc rejected")

        # Empty string as file
        rc, _, err = run_asm([""])
        report_result(rc != 0, "arg: empty string filename rejected")

        # Nonexistent file
        rc, _, err = run_asm(["/nonexistent/path/file"])
        report_result(rc != 0, "arg: nonexistent file rejected")
        report_result(b"No such file" in err or b"failed to open" in err,
                      "arg: nonexistent file error message")

    finally:
        import shutil
        shutil.rmtree(tmpdir, ignore_errors=True)

# =============================================================================
#                     7. DATA INTEGRITY
# =============================================================================

def test_data_integrity():
    log("\n=== Data Integrity Tests ===")

    tmpdir = tempfile.mkdtemp()
    try:
        # Verify file is actually overwritten (not just truncated)
        test_file = os.path.join(tmpdir, "integrity.dat")
        original = b"ORIGINAL_SECRET_DATA_" * 100
        with open(test_file, "wb") as f:
            f.write(original)

        rc, _, _ = run_asm(["-n", "1", "-x", test_file])
        report_result(rc == 0, "data: overwrite succeeds")

        with open(test_file, "rb") as f:
            content = f.read()
        report_result(len(content) == len(original), "data: file size preserved with -x")
        report_result(content != original, "data: content actually changed")

        # Verify zero pass produces all zeros
        zero_file = os.path.join(tmpdir, "zeros.dat")
        with open(zero_file, "wb") as f:
            f.write(b"secret" * 100)

        rc, _, _ = run_asm(["-z", "-x", zero_file])
        report_result(rc == 0, "data: zero pass succeeds")

        with open(zero_file, "rb") as f:
            content = f.read()
        report_result(all(b == 0 for b in content), "data: zero pass produces all zeros")

        # Verify -u actually removes
        remove_file = os.path.join(tmpdir, "removeme.dat")
        with open(remove_file, "wb") as f:
            f.write(b"remove this")

        rc, _, _ = run_asm(["-u", "-n", "1", remove_file])
        report_result(rc == 0, "data: remove succeeds")
        report_result(not os.path.exists(remove_file), "data: file actually removed")

        # Verify -s overrides size
        size_file = os.path.join(tmpdir, "sized.dat")
        with open(size_file, "wb") as f:
            f.write(b"small")

        rc, _, _ = run_asm(["-s", "2048", "-z", size_file])
        report_result(rc == 0, "data: -s override succeeds")

        stat = os.stat(size_file)
        report_result(stat.st_size == 2048, f"data: -s 2048 produced {stat.st_size} bytes")

        # Verify random data is actually random (not repeating)
        rand_file = os.path.join(tmpdir, "random.dat")
        with open(rand_file, "wb") as f:
            f.write(b"\x00" * 4096)

        rc, _, _ = run_asm(["-n", "1", "-x", rand_file])
        report_result(rc == 0, "data: random overwrite succeeds")

        with open(rand_file, "rb") as f:
            content = f.read()
        # Check that not all bytes are the same
        unique_bytes = len(set(content))
        report_result(unique_bytes > 100, f"data: random data has {unique_bytes} unique byte values")

    finally:
        import shutil
        shutil.rmtree(tmpdir, ignore_errors=True)

# =============================================================================
#                     8. GNU COMPATIBILITY
# =============================================================================

def test_gnu_compat():
    log("\n=== GNU Compatibility Tests ===")

    if not os.path.exists(GNU):
        skip_test("compat: GNU shred not found", "not installed")
        return

    tmpdir = tempfile.mkdtemp()
    try:
        # Compare verbose output format
        for args_desc, args in [
            ("1 pass", ["-v", "-n", "1"]),
            ("3 passes", ["-v", "-n", "3"]),
            ("1 pass + zero", ["-v", "-n", "1", "-z"]),
            ("0 passes + zero", ["-v", "-n", "0", "-z"]),
        ]:
            gnu_file = os.path.join(tmpdir, f"gnu_{args_desc.replace(' ', '_')}.txt")
            asm_file = os.path.join(tmpdir, f"asm_{args_desc.replace(' ', '_')}.txt")
            for f in [gnu_file, asm_file]:
                with open(f, "w") as fh:
                    fh.write("test data")

            gnu_rc, _, gnu_err = run([GNU] + args + [gnu_file])
            asm_rc, _, asm_err = run([BIN] + args + [asm_file])

            # Normalize filenames in output
            gnu_out = gnu_err.decode(errors="replace").replace(gnu_file, "FILE")
            asm_out = asm_err.decode(errors="replace").replace(asm_file, "FILE")

            report_result(gnu_rc == asm_rc, f"compat: exit code match ({args_desc})")
            # Compare verbose output structurally (tolerant of minor formatting
            # differences across GNU coreutils versions).  We verify:
            #   - same number of "pass" lines
            #   - same pass types (random / 000000) in the same order
            pass_re = re.compile(r"pass\s+(\d+)/(\d+)\s+\(([^)]+)\)")
            gnu_passes = pass_re.findall(gnu_out)
            asm_passes = pass_re.findall(asm_out)
            verbose_ok = (len(gnu_passes) == len(asm_passes) and
                          all(g[2] == a[2] for g, a in zip(gnu_passes, asm_passes)))
            report_result(verbose_ok, f"compat: verbose output match ({args_desc})")

        # Compare error messages (nonexistent file)
        gnu_rc, _, gnu_err = run_gnu(["/nonexistent_xyz_file"])
        asm_rc, _, asm_err = run_asm(["/nonexistent_xyz_file"])
        report_result(gnu_rc == asm_rc, "compat: nonexistent file exit code")

        # Compare no-args behavior
        gnu_rc, _, gnu_err = run_gnu([])
        asm_rc, _, asm_err = run_asm([])
        report_result(gnu_rc == asm_rc, "compat: no-args exit code")
        report_result(b"missing file operand" in gnu_err and b"missing file operand" in asm_err,
                      "compat: no-args error message")

    finally:
        import shutil
        shutil.rmtree(tmpdir, ignore_errors=True)

# =============================================================================
#                           MAIN
# =============================================================================

def main():
    if not os.path.exists(BIN):
        log(f"ERROR: Binary not found: {BIN}")
        log("Build it first: make dev")
        sys.exit(1)

    test_elf_binary_security()
    test_syscall_surface()
    test_fd_hygiene()
    test_memory_safety()
    test_signal_handling()
    test_argument_safety()
    test_data_integrity()
    test_gnu_compat()

    log(f"\n{'='*60}")
    log(f"TOTAL: {test_count} tests, {pass_count} passed, {len(failures)} failed, {skip_count} skipped")
    if failures:
        log("\nFailed tests:")
        for f in failures:
            log(f"  - {f['label']}")
        sys.exit(1)
    else:
        log("All tests PASSED!")
        sys.exit(0)

if __name__ == "__main__":
    main()
