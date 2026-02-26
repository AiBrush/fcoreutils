# PR #75 Review: Implement logname as x86_64 Assembly

## Summary

This PR adds a `logname` utility implemented in x86_64 NASM assembly, offering both a modular (dev) build and a unified flat-binary (release) build. Both builds compile successfully, and all 11 tests pass against the GNU reference implementation. Output is byte-identical to GNU coreutils 9.4 on this system.

---

## 1. GNU Coreutils Compatibility

### Verified Compatible

| Behavior | Status |
|---|---|
| `--help` output | Byte-identical to GNU |
| `--version` output | Byte-identical to GNU |
| No-argument behavior | Matches GNU |
| Extra operand error (`logname foo`) | Matches GNU |
| Invalid short option (`-x`) | Matches GNU |
| Bare dash (`-`) treated as operand | Matches GNU |
| Double dash (`--`) terminates options | Matches GNU |
| `-- arg` extra operand error | Matches GNU |
| `-- --help` treated as operand | Matches GNU |
| Short `-h` as invalid option | Matches GNU |
| Unrecognized long option (`--badopt`) | Matches GNU |
| Exit codes (0 on success, 1 on error) | Matches GNU |
| Empty string argument | Matches GNU |
| Multiple args after `--` | Matches GNU |

### Compatibility Concerns

1. **Locale-dependent quoting**: GNU coreutils uses locale-aware quotes in error messages (e.g., Unicode left/right single quotes in UTF-8 locales). This implementation always uses ASCII `'...'`. Error messages will differ from GNU in non-C/POSIX locales. This is acceptable for an assembly implementation but worth documenting.

2. **Login resolution order**: The implementation correctly mirrors glibc's `getlogin_r()` approach:
   - Method 1: `/proc/self/loginuid` -> `/etc/passwd` lookup
   - Method 2: utmp tty matching

   This is correct and matches GNU behavior.

3. **Hardcoded `--version` text**: The version string contains `"Written by FIXME: unknown."`. While this currently matches the system's GNU build, this is a placeholder that should be addressed.

---

## 2. Security Assessment

### Good Security Properties

- **No dynamic linking**: Statically linked binary, immune to `LD_PRELOAD` attacks
- **W^X enforced**: Code segment is R+E, data/BSS is R+W -- no segment is both writable and executable
- **Non-executable stack (release)**: Release build correctly includes `PT_GNU_STACK` with `RW` (no execute) flags
- **Buffer bounds checking**: All string copy loops have explicit bounds checks (255 for `name_buf`, `UT_NAMESIZE-1` for utmp copy, 31 for `uid_str`)
- **File descriptors properly closed**: All opened fds are closed in both success and error paths
- **EINTR handling**: Both `asm_read` and `asm_write` correctly retry on `EINTR` (`-4`)
- **NULL termination**: All constructed strings are properly null-terminated
- **No heap allocation**: All buffers are compile-time BSS -- no heap corruption possible
- **Minimal syscall surface**: Only uses `read`, `write`, `open`, `close`, `readlink`, `exit`
- **UID 4294967295 rejection**: Correctly rejects the invalid/unset loginuid sentinel value
- **Verified utmp struct offsets**: `ut_type` at 0, `ut_line` at 8, `ut_user` at 44, entry size 384 -- all confirmed correct against system headers

### [CRITICAL] Missing `PT_GNU_STACK` in Dev Build

The dev build (linked via `ld`) **does not have a `PT_GNU_STACK` program header**. This is because NASM object files don't emit a `.note.GNU-stack` section by default. Without this header, the kernel's behavior for stack executability depends on the kernel version and configuration -- on older kernels or certain configurations, the stack may be executable.

**Fix**: Add `-z noexecstack` to `LDFLAGS` in the Makefile:
```makefile
LDFLAGS   = --gc-sections -z noexecstack
```

Or add to each `.asm` source file:
```nasm
section .note.GNU-stack noalloc noexec nowrite progbits
```

### [MINOR] No Partial Write Handling

The `asm_write` / `do_write` function does not handle partial writes (where `write()` returns less than `rdx`). For `logname`'s short outputs this is unlikely to cause real-world issues, but it's technically incomplete. A write to a pipe or network-backed fd could theoretically return a partial result.

---

## 3. Performance Evaluation

### No Performance Regressions

| Metric | GNU logname | flogname (dev) | flogname_release |
|---|---|---|---|
| Binary size | 35,336 bytes | 15,416 bytes | 2,707 bytes |
| Linking | Dynamic (glibc) | Static | Flat binary (no linker) |
| Startup overhead | glibc init + dynamic linker | Direct `_start` | Direct `_start` |

The assembly implementation is significantly smaller and has lower startup overhead by eliminating the dynamic linker and glibc initialization. The `logname` utility is I/O-bound (reading `/proc`, `/etc/passwd`, or utmp), so the actual per-invocation performance difference is primarily in startup time.

No performance regressions identified.

---

## 4. Code Quality Issues

### [CRITICAL] Duplicate Function: `check_flag` == `str_eq`

`lib/args.asm:check_flag` and `lib/str.asm:str_eq` are **byte-for-byte identical** (differing only in label names). The `check_flag` function should be removed, and `tools/flogname.asm` should use `str_eq` instead.

### [CRITICAL] Directory Naming Inconsistency

The existing assembly implementation lives in `assembly/yes/`, but this PR creates `asm/logname/`. The project should use a consistent directory name. Either rename to `assembly/logname/` or migrate the existing `assembly/` to `asm/`.

### [MODERATE] Dual Source Files Risk

The PR contains both:
- `tools/flogname.asm` (modular, dev build) + `lib/*.asm`
- `flogname_unified.asm` (monolithic, release build)

These are manually kept in sync. Any future change must be applied to **both** files, creating a risk of divergence. Consider either:
- Auto-generating the unified file from the modular sources (like the `yes` implementation's `build.py`)
- Documenting the sync requirement prominently

### [MODERATE] No README

The existing `assembly/yes/` has a comprehensive `README.md` with benchmarks, architecture docs, and build instructions. This implementation has none.

### [MINOR] Missing Include Guard / Section Annotations

The library files (`lib/io.asm`, `lib/args.asm`, `lib/str.asm`) each `%include "include/linux.inc"` but don't have include guards. If `linux.inc` is included multiple times, it will produce duplicate definition warnings (though NASM handles `%define` redefinitions silently).

---

## 5. Test Coverage Assessment

The test suite covers all critical argument parsing paths (11 tests, all passing). The tests wisely compare against actual GNU output for both stdout/stderr content and exit codes.

**Missing test cases to consider:**
- Behavior when `/proc/self/loginuid` doesn't exist (e.g., in containers)
- Behavior when `/var/run/utmp` doesn't exist
- Behavior when stdin is not a tty (both methods may fail -> `"no login name"`)
- Very long username in `/etc/passwd` (bounds check verification)

---

## 6. Build Verification

```
$ make dev    -> OK (nasm + ld, 15,416 bytes)
$ make release -> OK (nasm -f bin, 2,707 bytes)
$ make test    -> 11/11 passed (dev build)
$ bash tests/run_tests.sh ./flogname_release -> 11/11 passed (release build)
```

Both `--help` and `--version` outputs are byte-identical to GNU. All error messages match format and exit codes.

---

## Verdict

The implementation is **well-crafted assembly code** that correctly implements the `logname` specification with byte-identical output to GNU coreutils. The login resolution logic (loginuid -> passwd -> utmp) is sound and follows the same approach as glibc.

### Must fix before merge:
1. Add `-z noexecstack` to dev build `LDFLAGS` (security)
2. Remove duplicate `check_flag` function; use `str_eq` instead
3. Resolve directory naming inconsistency (`asm/` vs `assembly/`)

### Should fix:
4. Address the `"Written by FIXME: unknown."` placeholder in `--version`
5. Add documentation (README) for the implementation
6. Consider auto-generating the unified file to prevent source divergence
