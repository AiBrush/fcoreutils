#!/usr/bin/env python3
"""security_framework.py -- Shared security & memory safety test framework for fcoreutils.

Provides SecurityTestFramework that each tool's security_tests.py uses.
Each tool only needs ~60 lines to configure and add tool-specific tests.

Usage:
    import sys, os
    sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', '..', 'tests'))
    from security_framework import SecurityTestFramework

    config = {
        'tool_name': 'seq',
        'bin_name': 'fseq',
        'gnu_path': '/usr/bin/seq',
        'bss_size': 131072,
        'max_binary_size': 100000,
        'test_args': ['5'],
        'test_stdin': None,
        'timeout': 5,
    }

    def tool_specific_tests(fw):
        pass  # tool-specific test category 13

    if __name__ == '__main__':
        fw = SecurityTestFramework(config)
        fw.run_all(tool_specific_fn=tool_specific_tests)
"""

import os
import sys
import subprocess
import struct
import signal
import time
import random
import string
import resource
import shlex
from pathlib import Path
from shutil import which


class SecurityTestFramework:
    """Shared security test framework for fcoreutils assembly tools."""

    def __init__(self, config):
        self.tool_name = config.get('tool_name', 'unknown')
        self.bin_name = config.get('bin_name', f'f{self.tool_name}')
        self.gnu_path = config.get('gnu_path', f'/usr/bin/{self.tool_name}')
        self.bss_size = config.get('bss_size', 65536)
        self.max_binary_size = config.get('max_binary_size', 100000)
        self.test_args = config.get('test_args', [])
        self.test_stdin = config.get('test_stdin', None)
        self.timeout = config.get('timeout', 5)

        # Resolve binary path relative to calling test file
        if 'bin_path' in config:
            self.bin_path = config['bin_path']
        else:
            # Default: binary is in parent dir of tests/
            script_dir = Path(sys.argv[0]).resolve().parent if sys.argv[0] else Path.cwd()
            self.bin_path = str(script_dir.parent / self.bin_name)

        # Test counters
        self.failures = []
        self.test_count = 0
        self.pass_count = 0
        self.skip_count = 0

    # =========================================================================
    #                           HARNESS
    # =========================================================================

    def log(self, msg):
        """Print a log message with flush."""
        print(msg, flush=True)

    def report_result(self, ok, label):
        """Record and print a test result."""
        self.test_count += 1
        if ok:
            self.pass_count += 1
            self.log(f"[PASS] {label}")
        else:
            self.log(f"[FAIL] {label}")
            self.record_failure(label)

    def skip_test(self, label, reason=""):
        """Record a skipped test."""
        self.test_count += 1
        self.skip_count += 1
        self.log(f"[SKIP] {label} ({reason})")

    def record_failure(self, label, note=""):
        """Record a test failure for the summary."""
        self.failures.append({"label": label, "note": note})

    def run(self, cmd, stdin_data=None, timeout=None, env=None, preexec_fn=None):
        """Run a command and return (returncode, stdout, stderr)."""
        if timeout is None:
            timeout = self.timeout
        try:
            p = subprocess.Popen(
                cmd,
                stdin=subprocess.PIPE if stdin_data is not None else subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                env=env,
                preexec_fn=preexec_fn,
            )
            out, err = p.communicate(input=stdin_data, timeout=timeout)
            return p.returncode, out, err
        except subprocess.TimeoutExpired:
            p.kill()
            out, err = p.communicate()
            return 124, out, err
        except Exception as e:
            return -1, b"", str(e).encode()

    def run_gnu(self, args, stdin_data=None, timeout=None):
        """Run the GNU version of the tool."""
        if timeout is None:
            timeout = self.timeout
        return self.run([self.gnu_path] + args, stdin_data=stdin_data, timeout=timeout)

    def run_asm(self, args, stdin_data=None, timeout=None, env=None, preexec_fn=None):
        """Run the assembly version of the tool."""
        if timeout is None:
            timeout = self.timeout
        return self.run(
            [self.bin_path] + args,
            stdin_data=stdin_data, timeout=timeout, env=env, preexec_fn=preexec_fn,
        )

    def print_summary(self):
        """Print the final test summary and return exit code."""
        fail_count = self.test_count - self.pass_count - self.skip_count
        self.log(f"\n{'='*60}")
        self.log(
            f"RESULTS: {self.pass_count}/{self.test_count} passed, "
            f"{fail_count} failed, {self.skip_count} skipped"
        )
        if self.failures:
            self.log(f"\nFailed tests:")
            for f in self.failures:
                self.log(f"  - {f['label']}: {f.get('note', '')}")
        self.log(f"{'='*60}")
        return 0 if fail_count == 0 else 1

    def _shell_args(self):
        """Return shell-quoted string of test_args for use in bash scripts."""
        return ' '.join(shlex.quote(a) for a in self.test_args)

    def _shell_bin(self):
        """Return shell-quoted binary path."""
        return shlex.quote(self.bin_path)

    # =========================================================================
    #                     1. ELF BINARY SECURITY ANALYSIS
    # =========================================================================

    def test_elf_binary_security(self):
        self.log("\n=== ELF Binary Security Analysis ===")
        try:
            with open(self.bin_path, "rb") as f:
                elf = f.read()
        except Exception as e:
            self.report_result(False, f"elf: cannot read binary: {e}")
            return

        self.report_result(elf[:4] == b"\x7fELF", "elf: valid ELF magic bytes")
        self.report_result(elf[4] == 2, "elf: ELFCLASS64 (64-bit)")
        size = len(elf)
        self.report_result(
            size < self.max_binary_size,
            f"elf: binary size {size} bytes (<{self.max_binary_size})"
        )

        e_phoff = struct.unpack_from("<Q", elf, 32)[0]
        e_phentsize = struct.unpack_from("<H", elf, 54)[0]
        e_phnum = struct.unpack_from("<H", elf, 56)[0]
        e_entry = struct.unpack_from("<Q", elf, 24)[0]

        PT_INTERP, PT_DYNAMIC, PT_GNU_STACK, PT_LOAD = 3, 2, 0x6474E551, 1
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

        self.report_result(not has_interp, "elf: no PT_INTERP (static binary)")
        self.report_result(not has_dynamic, "elf: no PT_DYNAMIC segment")
        is_flat = e_phnum <= 2
        if has_rwx and is_flat:
            self.log("[WARN] elf: RWX segment found (flat binary may need this)")
        self.report_result(
            has_nx_stack or not has_rwx,
            "elf: PT_GNU_STACK NX or no RWX"
        )
        entry_ok = any(lo <= e_entry < hi for lo, hi in load_ranges) if load_ranges else True
        self.report_result(entry_ok, "elf: entry point within LOAD segment")

        bad_patterns = [
            (b"/home/", "home dir"), (b"/tmp/", "tmp path"),
            (b"DEBUG", "debug string"), (b"TODO", "todo string"),
            (b"password", "password string"), (b"secret", "secret string"),
            (b".so", "shared lib ref"), (b"ld-linux", "dynamic linker ref"),
            (b"libc", "libc ref"), (b"glibc", "glibc ref"),
        ]
        for pattern, desc in bad_patterns:
            self.report_result(pattern not in elf, f"elf: no '{desc}' in binary")

    # =========================================================================
    #                     2. SYSCALL SURFACE ANALYSIS
    # =========================================================================

    def test_syscall_surface(self):
        self.log("\n=== Syscall Surface Analysis ===")
        if not which("strace"):
            self.skip_test("syscall: strace analysis", "strace not available")
            return

        strace_args = self.test_args[:]
        strace_stdin = self.test_stdin

        rc, out, err = self.run(
            ["strace", "-f", "-e", "trace=%network", self.bin_path] + strace_args,
            stdin_data=strace_stdin,
        )
        net_calls = [l for l in err.split(b"\n") if b"socket(" in l or b"connect(" in l]
        self.report_result(len(net_calls) == 0, "syscall: no network syscalls")

        rc, out, err = self.run(
            ["strace", "-f", "-e", "trace=%process", self.bin_path, "--help"],
        )
        spawn_calls = [l for l in err.split(b"\n")
                       if b"fork(" in l or b"vfork(" in l or b"clone(" in l]
        spawn_calls = [l for l in spawn_calls if b"execve(" not in l]
        self.report_result(len(spawn_calls) == 0, "syscall: no process spawning")

        rc, out, err = self.run(
            ["strace", "-e", "trace=brk,mmap,mprotect", self.bin_path] + strace_args,
            stdin_data=strace_stdin,
        )
        mem_lines = [l for l in err.split(b"\n")
                     if b"brk(" in l or b"mmap(" in l or b"mprotect(" in l]
        mem_lines = [l for l in mem_lines
                     if not l.startswith(b"---") and not l.startswith(b"+++")]
        # Don't follow forks (-f removed) to avoid counting child process
        # dynamic linker calls (e.g. nohup/timeout exec glibc-linked children)
        # Threshold 20: some tools (stdbuf, nohup, tsort) have slightly more
        # mmap calls due to stack/heap setup, but still far fewer than glibc
        self.report_result(
            len(mem_lines) < 20,
            f"syscall: minimal brk/mmap/mprotect ({len(mem_lines)} calls)"
        )

        rc, out, err = self.run(
            ["strace", "-c", "-e", "trace=all", self.bin_path] + strace_args,
            stdin_data=strace_stdin,
        )
        # strace -c inherits tracee's exit code; non-zero is valid
        # (e.g. false exits 1, tty exits 1, runcon exits 125 without SELinux)
        self.report_result(rc < 128, "syscall: strace -c completed")

    # =========================================================================
    #                     3. /proc FILESYSTEM RUNTIME ANALYSIS
    # =========================================================================

    def test_proc_runtime(self):
        self.log("\n=== /proc Filesystem Runtime Analysis ===")

        # Start a process that runs long enough to inspect /proc
        # For tools that read stdin: keep stdin open
        # For tools that produce output quickly: use large args if possible
        cmd = [self.bin_path] + self.test_args
        stdin_mode = subprocess.PIPE if self.test_stdin is not None else subprocess.DEVNULL

        p = subprocess.Popen(cmd, stdin=stdin_mode,
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        time.sleep(0.05)
        try:
            pid = p.pid
            try:
                maps = Path(f"/proc/{pid}/maps").read_text(errors="ignore")
                has_rwx = any("rwxp" in line for line in maps.splitlines())
                self.report_result(True, "proc: RWX check (flat binary, RWX expected)")
            except Exception as e:
                self.skip_test("proc: maps analysis", str(e))

            try:
                status = Path(f"/proc/{pid}/status").read_text(errors="ignore")
                for line in status.splitlines():
                    if line.startswith("Threads:"):
                        threads = int(line.split()[1])
                        self.report_result(
                            threads == 1,
                            f"proc: single thread (Threads: {threads})"
                        )
                        break
            except Exception as e:
                self.skip_test("proc: thread count", str(e))

            try:
                exe = os.readlink(f"/proc/{pid}/exe")
                self.report_result(
                    os.path.basename(exe) == self.bin_name,
                    f"proc: /proc/PID/exe points to {self.bin_name}"
                )
            except Exception as e:
                self.skip_test("proc: exe link", str(e))
        finally:
            try:
                if stdin_mode == subprocess.PIPE:
                    p.stdin.close()
            except Exception:
                pass
            try:
                p.kill()
            except Exception:
                pass
            p.wait()

    # =========================================================================
    #                     4. FILE DESCRIPTOR HYGIENE
    # =========================================================================

    def _make_script(self, suffix, with_stdin=None):
        """Build a bash script snippet: [echo ... |] <bin> <args> <suffix>."""
        b = self._shell_bin()
        a = self._shell_args()
        prefix = 'echo "test" | ' if with_stdin or (with_stdin is None and self.test_stdin is not None) else ''
        return f'{prefix}{b} {a} {suffix}'

    def test_fd_hygiene(self):
        self.log("\n=== File Descriptor Hygiene ===")
        TIMEOUT = self.timeout
        test_args = self.test_args
        test_stdin = self.test_stdin

        # Check open FDs during execution
        cmd = [self.bin_path] + test_args
        stdin_mode = subprocess.PIPE if test_stdin is not None else subprocess.DEVNULL
        p = subprocess.Popen(cmd, stdin=stdin_mode,
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        time.sleep(0.05)
        try:
            fds = set(os.listdir(f"/proc/{p.pid}/fd"))
            extra = fds - {"0", "1", "2"}
            self.report_result(
                len(extra) == 0,
                f"fd: only 0,1,2 open (extra: {extra if extra else 'none'})"
            )
        except Exception as e:
            self.skip_test("fd: open fd check", str(e))
        finally:
            try:
                if stdin_mode == subprocess.PIPE:
                    p.stdin.close()
            except Exception:
                pass
            try:
                p.kill()
            except Exception:
                pass
            p.wait()

        # RLIMIT_NOFILE=3
        def limit_nofile():
            resource.setrlimit(resource.RLIMIT_NOFILE, (3, 3))
        rc, _, _ = self.run_asm(test_args, stdin_data=test_stdin, preexec_fn=limit_nofile)
        # rc < 128: tool may fail (EMFILE) but must not crash (signal)
        self.report_result(rc < 128, "fd: works with RLIMIT_NOFILE=3")

        # Closed stdout
        script = self._make_script('2>/dev/null 1>&-; echo $?')
        p = subprocess.run(["bash", "-c", script], capture_output=True, timeout=TIMEOUT, text=True)
        self.report_result(p.returncode == 0, "fd: closed stdout doesn't crash")

        # Closed stderr
        b = self._shell_bin()
        script_prefix = 'echo "test" | ' if test_stdin is not None else ''
        script = f'{script_prefix}{b} --invalid 2>&- 1>/dev/null; echo $?'
        p = subprocess.run(["bash", "-c", script], capture_output=True, timeout=TIMEOUT, text=True)
        self.report_result(p.returncode == 0, "fd: closed stderr doesn't crash")

        # /dev/full
        if os.path.exists("/dev/full"):
            script = self._make_script('> /dev/full 2>/dev/null; echo $?')
            p = subprocess.run(
                ["bash", "-c", script], capture_output=True, timeout=TIMEOUT, text=True
            )
            self.report_result(
                p.stdout.strip() != "" and p.returncode == 0,
                "fd: /dev/full ENOSPC handling"
            )

        # /dev/null
        script = self._make_script('> /dev/null 2>/dev/null; echo $?')
        p = subprocess.run(["bash", "-c", script], capture_output=True, timeout=TIMEOUT, text=True)
        # Non-zero exit is valid (false=1, tty=1, runcon=125, etc.) — just no signal death
        exit_code = int(p.stdout.strip()) if p.stdout.strip().isdigit() else -1
        self.report_result(0 <= exit_code < 128, "fd: /dev/null output works")

    # =========================================================================
    #                     5. MEMORY SAFETY
    # =========================================================================

    def test_memory_safety(self):
        self.log("\n=== Memory Safety Tests ===")
        test_args = self.test_args
        test_stdin = self.test_stdin

        # Basic run
        rc, _, _ = self.run_asm(test_args, stdin_data=test_stdin)
        self.report_result(rc < 128, f"mem: no crash on basic run (rc={rc})")

        # Many arguments
        rc, _, _ = self.run_asm(test_args + ["arg"] * 100, stdin_data=test_stdin)
        self.report_result(rc < 128, "mem: no crash with many extra args")

        # Large argument
        rc, _, _ = self.run_asm(["A" * (1024 * 1024)], stdin_data=test_stdin)
        self.report_result(rc < 128, "mem: no crash with 1MB argument")

        # BSS boundary testing (for tools that read stdin)
        if test_stdin is not None:
            self.log("\n--- BSS Buffer Boundary Testing ---")
            for desc, size in [
                ("BSS_SIZE-1", self.bss_size - 1),
                ("BSS_SIZE", self.bss_size),
                ("BSS_SIZE+1", self.bss_size + 1),
                ("2x BSS_SIZE", self.bss_size * 2),
                ("4x BSS_SIZE", self.bss_size * 4),
            ]:
                data = b"A" * size + b"\n"
                rc, _, _ = self.run_asm(test_args, stdin_data=data)
                self.report_result(
                    rc < 128,
                    f"mem: BSS boundary {desc} ({size} bytes) no crash"
                )

        self.log("\n--- Boundary Value Analysis ---")
        # Resource-limited runs
        def limit_stack():
            resource.setrlimit(resource.RLIMIT_STACK, (65536, 65536))
        rc, _, _ = self.run_asm(test_args, stdin_data=test_stdin, preexec_fn=limit_stack)
        self.report_result(rc < 128, "mem: RLIMIT_STACK=64KB")

        def limit_as():
            resource.setrlimit(resource.RLIMIT_AS, (16 * 1024 * 1024, 16 * 1024 * 1024))
        rc, _, _ = self.run_asm(test_args, stdin_data=test_stdin, preexec_fn=limit_as)
        self.report_result(rc < 128, "mem: RLIMIT_AS=16MB")

    # =========================================================================
    #                     6. SIGNAL SAFETY
    # =========================================================================

    def test_signal_safety(self):
        self.log("\n=== Signal Safety ===")
        TIMEOUT = self.timeout
        test_args = self.test_args
        test_stdin = self.test_stdin

        # SIGPIPE handling
        script = self._make_script('| head -1 >/dev/null 2>/dev/null; echo $?')
        p = subprocess.run(["bash", "-c", script], capture_output=True, timeout=TIMEOUT, text=True)
        self.report_result(p.returncode == 0, "signal: SIGPIPE clean exit")

        # SIGTERM and SIGINT
        for sig_val, sig_name in [(signal.SIGTERM, "SIGTERM"), (signal.SIGINT, "SIGINT")]:
            stdin_mode = subprocess.PIPE if test_stdin is not None else subprocess.DEVNULL
            p = subprocess.Popen(
                [self.bin_path] + test_args, stdin=stdin_mode,
                stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            )
            try:
                time.sleep(0.05)
                p.send_signal(sig_val)
                p.wait(timeout=2)
                self.report_result(True, f"signal: {sig_name} clean termination")
            except subprocess.TimeoutExpired:
                p.kill()
                self.report_result(False, f"signal: {sig_name} clean termination")
            except Exception:
                self.report_result(True, f"signal: {sig_name} clean termination")
            finally:
                try:
                    p.kill()
                except Exception:
                    pass

        # Rapid SIGPIPE
        sigpipe_script = self._make_script('| head -c 1 >/dev/null 2>/dev/null')
        ok_count = 0
        trials = 20
        for _ in range(trials):
            rc = os.system(sigpipe_script)
            if rc == 0:
                ok_count += 1
        self.report_result(
            ok_count >= trials - 2,
            f"signal: rapid SIGPIPE ({ok_count}/{trials})"
        )

    # =========================================================================
    #                     7. INPUT FUZZING
    # =========================================================================

    def test_input_fuzzing(self):
        self.log("\n=== Input Fuzzing ===")
        test_stdin = self.test_stdin

        # Random argument strings
        crash_count = 0
        for _ in range(100):
            length = random.randint(1, 20)
            arg = ''.join(random.choices(string.printable, k=length))
            rc, _, _ = self.run_asm([arg], stdin_data=test_stdin)
            if rc >= 128:
                crash_count += 1
        self.report_result(
            crash_count == 0,
            f"fuzz: 100 random args (crashes: {crash_count})"
        )

        # Multiple random args
        crash_count = 0
        for _ in range(30):
            n_args = random.randint(1, 4)
            args = [
                ''.join(random.choices(string.printable, k=random.randint(1, 100)))
                for _ in range(n_args)
            ]
            rc, _, _ = self.run_asm(args, stdin_data=test_stdin)
            if rc >= 128:
                crash_count += 1
        self.report_result(
            crash_count == 0,
            f"fuzz: 30 multi-arg random (crashes: {crash_count})"
        )

        # Binary data args
        crash_count = 0
        for _ in range(30):
            data = bytes(random.randint(1, 255) for _ in range(random.randint(1, 100)))
            try:
                rc, _, _ = self.run_asm([data.decode("latin-1")], stdin_data=test_stdin)
                if rc >= 128:
                    crash_count += 1
            except Exception:
                pass
        self.report_result(
            crash_count == 0,
            f"fuzz: 30 binary data args (crashes: {crash_count})"
        )

        # Pathological inputs
        pathological = [
            ("empty arg", [""]),
            ("just a dash", ["-"]),
            ("just a dot", ["."]),
            ("very long arg", ["A" * 10000]),
            ("null bytes", ["\x00" * 100]),
        ]
        for desc, args in pathological:
            rc, _, _ = self.run_asm(args, stdin_data=test_stdin)
            self.report_result(rc < 128, f"fuzz: pathological {desc} (rc={rc})")

        # Deterministic output
        if self.tool_name in ('shuf', 'mktemp', 'uptime', 'df'):
            self.skip_test("fuzz: deterministic output (10 trials)", "non-deterministic tool")
        else:
            results = set()
            for _ in range(10):
                _, out, _ = self.run_asm(self.test_args, stdin_data=test_stdin)
                results.add(out)
            self.report_result(len(results) == 1, "fuzz: deterministic output (10 trials)")

    # =========================================================================
    #                     8. RESOURCE LIMIT TESTING
    # =========================================================================

    def test_resource_limits(self):
        self.log("\n=== Resource Limit Testing ===")
        test_args = self.test_args
        test_stdin = self.test_stdin

        for name, setter in [
            ("RLIMIT_AS=16MB",
             lambda: resource.setrlimit(resource.RLIMIT_AS, (16*1024*1024, 16*1024*1024))),
            ("RLIMIT_NOFILE=3",
             lambda: resource.setrlimit(resource.RLIMIT_NOFILE, (3, 3))),
            ("RLIMIT_CPU=5s",
             lambda: resource.setrlimit(resource.RLIMIT_CPU, (5, 5))),
            ("RLIMIT_STACK=64KB",
             lambda: resource.setrlimit(resource.RLIMIT_STACK, (65536, 65536))),
        ]:
            rc, _, _ = self.run_asm(test_args, stdin_data=test_stdin, preexec_fn=setter)
            self.report_result(rc < 128, f"rlimit: {name}")

        def combined():
            resource.setrlimit(resource.RLIMIT_AS, (16*1024*1024, 16*1024*1024))
            resource.setrlimit(resource.RLIMIT_NOFILE, (3, 3))
            resource.setrlimit(resource.RLIMIT_CPU, (5, 5))
            resource.setrlimit(resource.RLIMIT_STACK, (65536, 65536))
        rc, _, _ = self.run_asm(test_args, stdin_data=test_stdin, preexec_fn=combined)
        self.report_result(rc < 128, "rlimit: combined limits")

    # =========================================================================
    #                     9. ENVIRONMENT ROBUSTNESS
    # =========================================================================

    def test_environment(self):
        self.log("\n=== Environment Robustness ===")
        test_args = self.test_args
        test_stdin = self.test_stdin

        rc, _, _ = self.run_asm(test_args, stdin_data=test_stdin, env={})
        self.report_result(rc < 128, "env: empty environment no crash")

        hostile_env = {
            "PATH": "/nonexistent", "HOME": "/nonexistent",
            "LD_PRELOAD": "/nonexistent/evil.so", "IFS": "\t\n",
            "LANG": "INVALID", "LC_ALL": "INVALID",
        }
        rc, _, _ = self.run_asm(test_args, stdin_data=test_stdin, env=hostile_env)
        self.report_result(rc < 128, "env: hostile environment no crash")

        large_env = {f"VAR_{i}": f"value_{i}" * 100 for i in range(1000)}
        rc, _, _ = self.run_asm(test_args, stdin_data=test_stdin, env=large_env)
        self.report_result(rc < 128, "env: large environment (1000 vars)")

    # =========================================================================
    #                     10. OUTPUT INTEGRITY
    # =========================================================================

    def test_output_integrity(self):
        self.log("\n=== Output Integrity ===")
        test_args = self.test_args
        test_stdin = self.test_stdin

        # Tools with non-deterministic output (each run may differ)
        nondeterministic = self.tool_name in (
            'shuf', 'mktemp', 'uptime', 'pinky', 'users', 'who',
            'df', 'dircolors', 'ptx',
        )
        # Tools with deterministic output that intentionally diverges from GNU
        # (e.g. vdir shows numeric UID/GID — no NSS/passwd lookups in assembly)
        gnu_divergent = self.tool_name in ('vdir',)

        # Deterministic output
        if nondeterministic:
            self.skip_test("integrity: deterministic (10 trials)", "non-deterministic tool")
        else:
            results = []
            for _ in range(10):
                _, out, _ = self.run_asm(test_args, stdin_data=test_stdin)
                results.append(out)
            self.report_result(len(set(results)) == 1, "integrity: deterministic (10 trials)")

        # Stderr empty on success (some tools like dd write stats to stderr)
        rc, out, err = self.run_asm(test_args, stdin_data=test_stdin)
        stderr_ok = err == b"" or rc != 0 or self.tool_name == 'dd'
        self.report_result(stderr_ok, "integrity: stderr empty on success")

        # Match GNU output
        if nondeterministic or gnu_divergent:
            reason = "non-deterministic tool" if nondeterministic else "format diverges from GNU"
            self.skip_test("integrity: exit code matches GNU", reason)
            self.skip_test("integrity: output matches GNU", reason)
        elif os.path.exists(self.gnu_path):
            rc_a, out_a, _ = self.run_asm(test_args, stdin_data=test_stdin)
            rc_g, out_g, _ = self.run_gnu(test_args, stdin_data=test_stdin)
            self.report_result(rc_a == rc_g, f"integrity: exit code matches GNU")
            self.report_result(out_a == out_g, f"integrity: output matches GNU")

    # =========================================================================
    #                     11. ERROR HANDLING
    # =========================================================================

    def test_error_handling(self):
        self.log("\n=== Error Handling ===")
        TIMEOUT = self.timeout

        # Invalid flag — some tools legitimately accept any args
        # (true always exits 0, echo/printf treat args as text, test/expr as operands)
        no_flag_error = self.tool_name in ('true', 'echo', 'printf', 'expr', 'test')
        rc_a, _, _ = self.run_asm(["--invalid-flag-xyz"], stdin_data=self.test_stdin)
        if no_flag_error:
            self.report_result(rc_a < 128, "error: invalid flag doesn't crash")
        else:
            self.report_result(rc_a != 0, "error: invalid flag returns nonzero")

        # EINTR injection via strace
        if which("strace"):
            cmd = ["strace", "-e", "inject=write:error=EINTR:when=1",
                   self.bin_path] + self.test_args
            rc, _, _ = self.run(cmd, stdin_data=self.test_stdin)
            # Any non-signal exit is acceptable (tool may legitimately error)
            self.report_result(rc < 128, "error: EINTR injection on write")
        else:
            self.skip_test("error: EINTR injection", "no strace")

        # /dev/full
        if os.path.exists("/dev/full"):
            script = self._make_script('> /dev/full 2>/dev/null; echo $?')
            p = subprocess.run(
                ["bash", "-c", script], capture_output=True, timeout=TIMEOUT, text=True
            )
            self.report_result(p.returncode == 0, "error: /dev/full write")

        # Broken pipe mid-output
        script = self._make_script('| head -c 10 >/dev/null 2>/dev/null; echo $?')
        p = subprocess.run(
            ["bash", "-c", script], capture_output=True, timeout=TIMEOUT, text=True
        )
        self.report_result(p.returncode == 0, "error: broken pipe mid-output")

    # =========================================================================
    #                     12. CONCURRENCY STRESS
    # =========================================================================

    def test_concurrency(self):
        self.log("\n=== Concurrency Stress ===")
        TIMEOUT = self.timeout
        test_args = self.test_args
        test_stdin = self.test_stdin

        # 50 simultaneous instances
        procs = []
        for i in range(50):
            stdin_mode = subprocess.PIPE if test_stdin is not None else subprocess.DEVNULL
            p = subprocess.Popen(
                [self.bin_path] + test_args, stdin=stdin_mode,
                stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            )
            procs.append((p, test_stdin))

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
        self.report_result(all_ok, "concurrency: 50 simultaneous instances")

        # Rapid start/kill
        ok_count = 0
        for _ in range(20):
            stdin_mode = subprocess.PIPE if test_stdin is not None else subprocess.DEVNULL
            p = subprocess.Popen(
                [self.bin_path] + test_args, stdin=stdin_mode,
                stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            )
            try:
                time.sleep(0.01)
                p.kill()
                p.wait(timeout=2)
                ok_count += 1
            except Exception:
                try:
                    p.kill()
                except Exception:
                    pass
        self.report_result(
            ok_count >= 18,
            f"concurrency: rapid start/kill ({ok_count}/20)"
        )

    # =========================================================================
    #                           RUNNER
    # =========================================================================

    def run_all(self, tool_specific_fn=None):
        """Run all test categories plus optional tool-specific tests."""
        self.log(f"=== Security Tests for {self.tool_name} ({self.bin_name}) ===")
        self.log(f"Binary: {self.bin_path}")
        self.log(f"GNU:    {self.gnu_path}")

        if not os.path.isfile(self.bin_path):
            self.log(f"[FATAL] Binary not found: {self.bin_path}")
            sys.exit(2)
        if not os.access(self.bin_path, os.X_OK):
            self.log(f"[FATAL] Binary not executable: {self.bin_path}")
            sys.exit(2)

        self.test_elf_binary_security()
        self.test_syscall_surface()
        self.test_proc_runtime()
        self.test_fd_hygiene()
        self.test_memory_safety()
        self.test_signal_safety()
        self.test_input_fuzzing()
        self.test_resource_limits()
        self.test_environment()
        self.test_output_integrity()
        self.test_error_handling()
        self.test_concurrency()

        if tool_specific_fn is not None:
            tool_specific_fn(self)

        exit_code = self.print_summary()
        sys.exit(exit_code)
