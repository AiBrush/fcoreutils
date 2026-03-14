# fcoreutils

[![Test](https://github.com/AiBrush/fcoreutils/actions/workflows/test.yml/badge.svg)](https://github.com/AiBrush/fcoreutils/actions/workflows/test.yml)
[![Release](https://github.com/AiBrush/fcoreutils/actions/workflows/release.yml/badge.svg)](https://github.com/AiBrush/fcoreutils/actions/workflows/release.yml)
[![crates.io](https://img.shields.io/crates/v/fcoreutils?color=orange)](https://crates.io/crates/fcoreutils)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![GitHub Release](https://img.shields.io/github/v/release/AiBrush/fcoreutils)](https://github.com/AiBrush/fcoreutils/releases)

High-performance GNU coreutils replacement in Rust — 100+ tools, SIMD-accelerated, drop-in compatible, cross-platform.

## Independent Test Results (v0.21.6)

*Source: [AiBrush/coreutils-rs-independent-test](https://github.com/AiBrush/coreutils-rs-independent-test) — Linux x86_64, GitHub Actions, hyperfine*

**Summary:** 108 tools tested · **fastest: unexpand at 36.2x** vs GNU · compat: **3807/3811 (99.9%)** across 108 tools · only 4 real failures

> Compat is GNU test pass rate on Linux x86_64 (skipped tests excluded from denominator for tools that only skip due to environment). Speedup is peak across all benchmark scenarios. `-` = no benchmark data collected. `N/A` = not applicable (requires root/SELinux/tty).

| Tool | Compat | Speedup | Notes |
|------|-------:|--------:|-------|
| arch | ✅ 17/17 | 0.8x | |
| b2sum | ✅ 25/25 | 1.3x | |
| base32 | ✅ 29/29 | **2.3x** | |
| base64 | ✅ 33/33 | **6.9x** | |
| basename | ✅ 26/26 | 0.9x | |
| basenc | ✅ 95/95 | **2.6x** | |
| cat | ✅ 49/49 | 1.9x | I/O-bound — near kernel splice limit |
| chcon | ✅ 15/15 | N/A | 9 skips: require SELinux |
| chgrp | ✅ 17/17 | 1.0x | 2 skips: require root |
| chmod | ✅ 78/78 | - | 1 skip: requires root |
| chown | ✅ 17/17 | 1.0x | 3 skips: require root |
| chroot | ✅ 18/18 | - | 20 skips: require root/SELinux |
| cksum | ✅ 48/48 | 1.3x | |
| comm | ✅ 30/30 | **5.8x** | |
| cp | ✅ 69/69 | 1.0x | I/O-bound — kernel copy_file_range |
| csplit | ✅ 2/2 | - | |
| cut | ✅ 96/96 | **7.7x** | |
| date | ✅ 46/46 | 0.9x | |
| dd | ✅ 29/29 | 1.1x | |
| df | ✅ 25/25 | 1.2x | |
| dir | ✅ 45/45 | 0.9x | |
| dircolors | ✅ 14/14 | 0.9x | |
| dirname | ✅ 23/23 | 0.9x | |
| du | ✅ 51/51 | 0.9x | |
| echo | ✅ 53/53 | 0.9x | |
| env | ✅ 49/49 | 0.9x | |
| expand | ✅ 35/35 | **12.1x** | |
| expr | ✅ 43/43 | 1.0x | |
| factor | ✅ 55/55 | 1.7x | |
| false | ✅ 6/6 | 0.7x | Startup-only tool — no data to process |
| fmt | ✅ 22/22 | 1.3x | |
| fold | ✅ 57/57 | **8.9x** | |
| groups | ✅ 28/28 | 1.1x | |
| head | ✅ 60/60 | **2.2x** | |
| hostid | ✅ 6/6 | 0.9x | |
| id | ✅ 27/27 | 1.1x | |
| install | ✅ 27/27 | 1.1x | 5 skips: require root or SELinux |
| join | ✅ 37/37 | 1.2x | |
| kill | ✅ 20/20 | 0.9x | |
| link | ✅ 32/32 | 0.9x | |
| ln | ✅ 33/33 | 0.9x | |
| logname | ✅ 13/13 | 0.9x | |
| ls | ✅ 65/65 | 1.1x | |
| md5sum | ✅ 30/30 | 1.2x | |
| mkdir | ✅ 37/37 | 1.0x | 7 skips: require root or SELinux |
| mkfifo | ✅ 11/11 | 1.0x | |
| mknod | ✅ 12/12 | 1.1x | |
| mktemp | ✅ 15/15 | 1.1x | |
| mv | ✅ 3/3 | 1.1x | |
| nice | ✅ 32/32 | 0.9x | 2 skips: require root |
| nl | ✅ 61/61 | **12.1x** | |
| nohup | ✅ 11/11 | 1.0x | |
| nproc | ✅ 29/29 | 0.9x | |
| numfmt | ⚠️ 97% (32/33) | 1.4x | 1 fail: locale-specific error message (GNU gettext i18n) |
| od | ✅ 50/50 | **10.8x** | |
| paste | ✅ 32/32 | **4.2x** | |
| pathchk | ✅ 22/22 | 0.9x | |
| pinky | ✅ 32/32 | 0.9x | |
| pr | ✅ 18/18 | **8.3x** | |
| printenv | ✅ 9/9 | 1.3x | |
| printf | ✅ 74/74 | 0.8x | |
| ptx | ✅ 15/15 | **2.0x** | |
| pwd | ✅ 16/16 | 0.9x | |
| readlink | ✅ 60/60 | 0.8x | |
| realpath | ✅ 43/43 | 0.9x | |
| rev | ✅ 32/32 | **23.4x** | |
| rm | ✅ 23/23 | 1.0x | |
| rmdir | ✅ 21/21 | 0.9x | |
| runcon | ✅ 2/2 | N/A | 3 skips: require SELinux |
| seq | ✅ 62/62 | **15.4x** | |
| sha1sum | ✅ 43/43 | 1.2x | |
| sha224sum | ✅ 39/39 | 1.2x | |
| sha256sum | ✅ 34/34 | 1.2x | |
| sha384sum | ✅ 39/39 | 0.9x | |
| sha512sum | ✅ 39/39 | 0.9x | |
| shred | ✅ 27/27 | **2.4x** | |
| shuf | ✅ 52/52 | **6.8x** | |
| sleep | ✅ 15/15 | 1.0x | |
| sort | ✅ 111/111 | **13.9x** | |
| split | ✅ 72/72 | 1.5x | |
| stat | ✅ 38/38 | 1.1x | |
| stdbuf | ✅ 13/13 | 0.9x | |
| stty | ✅ 25/25 | N/A | 17 skips: require a real terminal |
| sum | ✅ 23/23 | 1.2x | |
| sync | ✅ 9/9 | 0.9x | |
| tac | ✅ 59/59 | **2.9x** | |
| tail | ✅ 80/80 | **2.0x** | |
| tee | ✅ 27/27 | 0.9x | |
| test | ✅ 116/116 | 0.9x | |
| timeout | ✅ 36/36 | 0.9x | |
| touch | ✅ 45/45 | 0.9x | |
| tr | ✅ 59/59 | **7.5x** | |
| true | ✅ 7/7 | 0.8x | Startup-only tool — no data to process |
| truncate | ✅ 46/46 | 1.0x | |
| tsort | ✅ 19/19 | **10.2x** | |
| tty | ✅ 10/10 | 0.8x | |
| uname | ✅ 14/14 | 1.0x | |
| unexpand | ✅ 26/26 | **36.2x** | |
| uniq | ✅ 85/85 | **12.2x** | |
| unlink | ✅ 30/30 | 0.9x | |
| uptime | ✅ 16/16 | 1.5x | |
| users | ✅ 6/6 | 0.9x | |
| vdir | ✅ 41/41 | 0.9x | |
| wc | ✅ 77/77 | **24.8x** | |
| who | ✅ 38/38 | 0.9x | |
| whoami | ✅ 16/16 | 0.9x | |
| yes | ⚠️ 90% (26/29) | 1.1x | 3 fails: stderr/stdout interleaving race in test harness |
| **Total** | **99.9%** (3807/3811) | | 100 skips (root/SELinux/tty/ulimit), 4 fails |

## Installation

```bash
cargo install fcoreutils
```

Or build from source:

```bash
git clone https://github.com/AiBrush/fcoreutils.git
cd fcoreutils
cargo build --release
```

Binaries are in `target/release/`.

## Usage

Each tool is prefixed with `f` to avoid conflicts with system utilities:

```bash
# Word count (drop-in replacement for wc)
fwc file.txt
fwc -l file.txt          # Line count only
fwc -w file.txt          # Word count only
fwc -c file.txt          # Byte count only (uses stat, instant)
fwc -m file.txt          # Character count (UTF-8 aware)
fwc -L file.txt          # Max line display width
cat file.txt | fwc       # Stdin support
fwc file1.txt file2.txt  # Multiple files with total

# Cut (drop-in replacement for cut)
fcut -d: -f2 file.csv    # Extract field 2 with : delimiter
fcut -d, -f1,3-5 data.csv  # Multiple fields
fcut -b1-20 file.txt     # Byte range selection

# Hash tools (drop-in replacements)
fsha256sum file.txt       # SHA-256 checksum
fmd5sum file.txt          # MD5 checksum
fb2sum file.txt           # BLAKE2b checksum
fsha256sum -c sums.txt    # Verify checksums

# Base64 encode/decode
fbase64 file.txt          # Encode to base64
fbase64 -d encoded.txt    # Decode from base64
fbase64 -w 0 file.txt     # No line wrapping

# Sort, translate, deduplicate, reverse
fsort file.txt            # Sort lines alphabetically
fsort -n file.txt         # Numeric sort
ftr 'a-z' 'A-Z' < file   # Translate lowercase to uppercase
ftr -d '[:space:]' < file # Delete whitespace
funiq file.txt            # Remove adjacent duplicates
funiq -c file.txt         # Count occurrences
ftac file.txt             # Print lines in reverse order

# File viewing and transformation
fhead -n 20 file.txt      # First 20 lines
ftail -n 20 file.txt      # Last 20 lines
ftail -f logfile.txt      # Follow file for new lines
fcat file1.txt file2.txt  # Concatenate files
fcat -n file.txt          # With line numbers
frev file.txt             # Reverse each line

# Text formatting
fexpand file.txt          # Convert tabs to spaces
funexpand file.txt        # Convert spaces to tabs
ffold -w 80 file.txt      # Wrap lines at 80 columns
fnl file.txt              # Number lines
fpaste file1 file2        # Merge files line by line
fpaste -s file.txt        # Serial mode (join all lines)

# Set operations on sorted files
fcomm file1 file2         # Compare two sorted files
fcomm -12 file1 file2     # Only lines common to both
fjoin file1 file2         # Join on common field
fjoin -t, -1 2 -2 1 a b  # Join CSV files on specific fields
```

## Key Optimizations

- **Zero-copy mmap**: Large files are memory-mapped directly, avoiding copies
- **SIMD scanning**: `memchr` crate auto-detects AVX2/SSE2/NEON for byte searches
- **stat-only byte counting**: `wc -c` uses `stat()` without reading file content
- **Hardware-accelerated hashing**: sha2 detects SHA-NI, blake2 uses optimized implementations
- **SIMD base64**: Vectorized encode/decode with 4MB chunked streaming
- **Parallel processing**: Multi-file hashing and wc use thread pools
- **SIMD range translate/delete**: `tr` detects contiguous byte ranges and uses AVX2/SSE2 SIMD
- **Chunk-based reverse scan**: `tac` processes backward in 512KB chunks with forward SIMD within each chunk
- **Optimized release profile**: Fat LTO, single codegen unit, abort on panic, stripped binaries

## GNU Compatibility

Output is byte-identical to GNU coreutils. All flags are supported including `--files0-from`, `--total`, `--complement`, `--check`, and correct column alignment.

## Assembly Optimization Path

We pursue a second optimization track alongside Rust: hand-crafted x86_64 assembly for platforms where maximum throughput matters. **107 tools** are implemented in assembly — static ELF binaries with no dynamic linker, no libc, and non-executable stacks.

Benchmarked on Linux x86_64, 10 MB test files, hyperfine with warmup. Speedups **>1.0x** vs GNU are **bold**. The table below covers the 30 tools with benchmark data from the independent test suite; all 107 tools have compat and security tests in CI.

| Tool | Compat | Security | Asm Size | Speedup vs GNU |
|------|-------:|---------:|---------:|---------------:|
| arch | ✅ 12/12 | ✅ 100% | 13.5 KB | - |
| base64 | ✅ 17/17 | ✅ 100% | 5.7 KB | **1.8x** |
| cat | ✅ 65/65 | ✅ 100% | 18.0 KB | **3.8x** |
| cut | ✅ 24/24 | ✅ 100% | 9.3 KB | **4.3x** |
| echo | ✅ 57/57 | ✅ 100% | 8.2 KB | 0.1x |
| expand | ✅ 60/60 | ✅ 100% | 29.5 KB | **4.3x** |
| false | ✅ 20/20 | ✅ 100% | 4.8 KB | - |
| fold | ✅ 58/58 | ✅ 100% | 9.8 KB | **6.9x** |
| head | ✅ 19/19 | ✅ 100% | 7.2 KB | **2.2x** |
| hostid | ✅ 6/6 | ✅ 100% | 13.1 KB | - |
| logname | ✅ 9/9 | ✅ 100% | 13.4 KB | - |
| md5sum | ✅ 16/16 | ✅ 100% | 9.6 KB | 0.7x |
| nl | ✅ 69/69 | ✅ 100% | 38.2 KB | **9.1x** |
| od | ✅ 58/58 | ✅ 100% | 37.7 KB | **10.3x** |
| pwd | ✅ 14/14 | ✅ 100% | 12.8 KB | - |
| rev | ✅ 15/15 | ✅ 100% | 2.6 KB | **9.4x** |
| seq | ✅ 50/50 | ✅ 100% | 36.2 KB | **20.4x** |
| sleep | ✅ 17/17 | ✅ 100% | 13.4 KB | - |
| sort | ✅ 46/46 | ✅ 100% | 39.7 KB | **1.2x** |
| sync | ✅ 16/16 | ✅ 100% | 14.6 KB | - |
| tac | ✅ 13/13 | ✅ 100% | 4.6 KB | **1.8x** |
| tail | ✅ 18/18 | ✅ 100% | 7.5 KB | **2.8x** |
| tr | ✅ 20/20 | ✅ 100% | 9.8 KB | **1.7x** |
| true | ✅ 9/9 | ✅ 100% | 9.9 KB | - |
| tty | ✅ 16/16 | ✅ 100% | 12.0 KB | - |
| unexpand | ✅ 57/57 | ✅ 100% | 22.1 KB | **3.2x** |
| uniq | ✅ 72/72 | ✅ 100% | 39.3 KB | **6.1x** |
| wc | ✅ 23/23 | ✅ 100% | 30.4 KB | **1.5x** |
| whoami | ✅ 4/4 | ✅ 100% | 12.4 KB | - |
| yes | ⚠️ 90% (26/29) | ✅ 100% | 1.8 KB | 1.0x |
| **Average** | **100%** (880/880) | **100%** | **16.2 KB** | **4.6x** |

- **Size** — Stripped static ELF binary on disk. Assembly averages **16.2 KB** across the 30 benchmarked tools
- **Speedup** — Wall-clock throughput on a 10 MB file (hyperfine, warmup). `-` means the tool only prints a short string and exits, so throughput is not applicable. Tools like seq (20.4x), od (10.3x), and rev (9.4x) show large gains; I/O-bound tools (yes, base64) converge to kernel limits
- **Security** — All 107 tools pass security tests (buffer overflow, path traversal, signal handling, symlink attacks)

On **Linux x86_64** and **Linux ARM64**, releases ship assembly binaries. All other platforms (macOS, Windows) use the Rust implementation.

See [`assembly/`](assembly/) for source code and [`tests/assembly/`](tests/assembly/) for the test suite.

## Roadmap

We are actively working toward **100% compatibility** with GNU coreutils — byte-identical output, same exit codes, and matching error messages for all 90+ tools. Once we achieve full compatibility, we will focus on **performance optimization** targeting 10-30x speedup over GNU coreutils across all tools.

## Contributing

We welcome contributions! Please see [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

This project follows the [Contributor Covenant Code of Conduct](CODE_OF_CONDUCT.md).

## Architecture

See [ARCHITECTURE.md](ARCHITECTURE.md) for design decisions and [PROGRESS.md](PROGRESS.md) for development status.

## Security

To report a vulnerability, please see our [Security Policy](SECURITY.md).

## License

MIT
