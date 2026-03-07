# fcoreutils

[![Test](https://github.com/AiBrush/fcoreutils/actions/workflows/test.yml/badge.svg)](https://github.com/AiBrush/fcoreutils/actions/workflows/test.yml)
[![Release](https://github.com/AiBrush/fcoreutils/actions/workflows/release.yml/badge.svg)](https://github.com/AiBrush/fcoreutils/actions/workflows/release.yml)
[![crates.io](https://img.shields.io/crates/v/fcoreutils?color=orange)](https://crates.io/crates/fcoreutils)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![GitHub Release](https://img.shields.io/github/v/release/AiBrush/fcoreutils)](https://github.com/AiBrush/fcoreutils/releases)

High-performance GNU coreutils replacement in Rust — 100+ tools, SIMD-accelerated, drop-in compatible, cross-platform.

## Independent Test Results (v0.19.0)

*Source: [AiBrush/coreutils-rs-independent-test](https://github.com/AiBrush/coreutils-rs-independent-test) — Linux x86_64, GitHub Actions, hyperfine*

**Summary:** 107 tools tracked · 101 benchmarked · **fastest: unexpand at 39.0x** vs GNU · compat: **3805/3911 (97.3%)** across 107 tools

> Compat is GNU test pass rate on Linux x86_64 (skipped tests counted as not passed). Speedup is peak across all benchmark scenarios. `-` = no benchmark data collected. `N/A` = not applicable (requires root/SELinux/tty).

| Tool | Compat | Speedup | Notes |
|------|-------:|--------:|-------|
| arch | ✅ 17/17 | 0.8x | |
| b2sum | ✅ 25/25 | **1.2x** | |
| base32 | ✅ 29/29 | **1.8x** | |
| base64 | ✅ 33/33 | **7.0x** | |
| basename | ✅ 26/26 | 0.9x | |
| basenc | ⚠️ 99% (95/96) | **2.6x** | 1 skip: bounded-memory test (ulimit) |
| cat | ✅ 49/49 | **1.8x** | I/O-bound — near kernel splice limit |
| chcon | ⚠️ 62% (15/24) | N/A | 9 skips: require SELinux; can't benchmark without it |
| chgrp | ⚠️ 89% (17/19) | **1.0x** | 2 skips: require root |
| chmod | ⚠️ 99% (78/79) | - | 1 skip: requires root; no data throughput to benchmark |
| chown | ⚠️ 85% (17/20) | **1.0x** | 3 skips: require root |
| chroot | ⚠️ 47% (18/38) | N/A | 20 skips: require root; can't benchmark in CI |
| cksum | ✅ 48/48 | **1.4x** | |
| comm | ✅ 30/30 | **4.3x** | |
| cp | ✅ 69/69 | **1.1x** | I/O-bound — kernel copy_file_range |
| csplit | ✅ 2/2 | - | No data throughput to benchmark (creates files) |
| cut | ⚠️ 97% (96/99) | **6.6x** | 3 skips: bounded-memory/overflow tests |
| date | ✅ 46/46 | **1.0x** | |
| dd | ✅ 29/29 | **1.1x** | I/O-bound — kernel copy_file_range |
| df | ✅ 25/25 | **1.6x** | |
| dir | ✅ 45/45 | **1.1x** | |
| dircolors | ✅ 14/14 | 0.9x | |
| dirname | ✅ 23/23 | 0.9x | |
| du | ✅ 51/51 | 0.9x | |
| echo | ✅ 53/53 | 0.9x | |
| env | ⚠️ 96% (49/51) | **1.0x** | 2 skips: environment-dependent tests |
| expand | ✅ 35/35 | **10.7x** | |
| expr | ✅ 43/43 | **1.0x** | |
| factor | ⚠️ 93% (55/59) | **1.3x** | 2 skips + 2 GNU timeouts (128-bit) |
| false | ✅ 6/6 | 0.8x | Startup-only tool — no data to process |
| fmt | ✅ 22/22 | **1.3x** | |
| fold | ⚠️ 98% (57/58) | **8.0x** | 1 skip: bounded-memory test (ulimit) |
| groups | ✅ 28/28 | 0.9x | |
| head | ⚠️ 95% (60/63) | **1.9x** | 3 skips: large-file/overflow edge cases; I/O-bound via sendfile |
| hostid | ✅ 6/6 | 0.9x | |
| id | ✅ 27/27 | **1.1x** | |
| install | ⚠️ 84% (27/32) | **1.1x** | 5 skips: require root |
| join | ✅ 37/37 | **1.7x** | |
| kill | ✅ 20/20 | 0.9x | |
| link | ✅ 32/32 | 0.9x | |
| ln | ✅ 33/33 | 0.9x | |
| logname | ✅ 13/13 | 0.9x | |
| ls | ✅ 65/65 | **1.1x** | |
| md5sum | ✅ 30/30 | **1.1x** | |
| mkdir | ⚠️ 84% (37/44) | **1.0x** | 7 skips: require root or SELinux |
| mkfifo | ✅ 11/11 | **1.0x** | |
| mknod | ✅ 12/12 | **1.0x** | |
| mktemp | ⚠️ 88% (15/17) | 0.9x | 2 skips: tmpdir edge cases |
| mv | ✅ 3/3 | **1.1x** | |
| nice | ⚠️ 94% (32/34) | **1.0x** | 2 skips: require root |
| nl | ⚠️ 98% (61/62) | **9.4x** | 1 skip: overflow test (getlimits) |
| nohup | ✅ 11/11 | **1.0x** | |
| nproc | ⚠️ 94% (29/31) | 0.9x | 2 skips: cgroup/environment tests |
| numfmt | ⚠️ 97% (32/33) | **1.1x** | 1 skip: GB18030 locale test |
| od | ✅ 50/50 | **13.2x** | |
| paste | ✅ 32/32 | **3.9x** | |
| pathchk | ✅ 22/22 | 0.9x | |
| pinky | ✅ 32/32 | 0.9x | |
| pr | ⚠️ 95% (18/19) | **6.3x** | 1 skip: bounded-memory test (ulimit) |
| printenv | ✅ 9/9 | 0.9x | |
| printf | ✅ 74/74 | 0.9x | |
| ptx | ✅ 15/15 | **1.9x** | |
| pwd | ⚠️ 94% (16/17) | 0.9x | 1 skip: symlink/mount edge case |
| readlink | ✅ 60/60 | 0.9x | |
| realpath | ✅ 43/43 | 0.8x | |
| rev | ✅ 32/32 | **23.1x** | |
| rm | ✅ 23/23 | 0.9x | |
| rmdir | ✅ 21/21 | 0.9x | |
| runcon | ⚠️ 40% (2/5) | N/A | 3 skips: require SELinux; can't benchmark without it |
| seq | ✅ 62/62 | **15.6x** | |
| sha1sum | ✅ 43/43 | **1.2x** | |
| sha224sum | ✅ 39/39 | **1.1x** | |
| sha256sum | ✅ 34/34 | **1.2x** | |
| sha384sum | ✅ 39/39 | 0.9x | |
| sha512sum | ✅ 39/39 | **1.0x** | |
| shred | ✅ 27/27 | **2.6x** | |
| shuf | ⚠️ 98% (52/53) | **4.9x** | 1 skip: requires valgrind |
| sleep | ✅ 15/15 | **1.0x** | |
| sort | ✅ 111/111 | **12.4x** | |
| split | ✅ 72/72 | **1.4x** | I/O-bound — kernel copy_file_range |
| stat | ✅ 38/38 | **1.2x** | |
| stdbuf | ✅ 13/13 | 0.8x | |
| stty | ⚠️ 60% (25/42) | N/A | 17 skips: require a real terminal; can't benchmark in CI |
| sum | ✅ 23/23 | **1.2x** | |
| sync | ⚠️ 90% (9/10) | 0.9x | 1 skip: device sync test |
| tac | ✅ 59/59 | **2.7x** | |
| tail | ✅ 80/80 | **2.0x** | I/O-bound — near kernel sendfile limit |
| tee | ✅ 27/27 | **1.1x** | |
| test | ✅ 116/116 | 0.9x | |
| timeout | ✅ 36/36 | 0.9x | |
| touch | ⚠️ 92% (44/48) | **1.0x** | 3 skips: require root/specific fs; 1 flaky: race in timestamp test |
| tr | ✅ 59/59 | **6.6x** | |
| true | ✅ 7/7 | 0.8x | Startup-only tool — no data to process |
| truncate | ⚠️ 94% (46/49) | **1.0x** | 3 skips: require root or specific fs |
| tsort | ✅ 19/19 | **8.3x** | |
| tty | ✅ 10/10 | 0.8x | |
| uname | ✅ 14/14 | 0.9x | |
| unexpand | ⚠️ 96% (26/27) | **39.0x** | 1 skip: bounded-memory test (ulimit) |
| uniq | ⚠️ 99% (85/86) | **11.2x** | 1 skip: locale-dependent collation |
| unlink | ✅ 30/30 | 0.9x | |
| uptime | ✅ 16/16 | **1.5x** | |
| users | ✅ 6/6 | 0.9x | |
| vdir | ✅ 41/41 | 0.9x | |
| wc | ✅ 77/77 | **17.5x** | |
| who | ✅ 38/38 | 0.9x | |
| whoami | ✅ 16/16 | 0.9x | |
| yes | ⚠️ 86% (25/29) | **1.5x** | 4 fails: stderr/stdout interleaving with long strings via `2>&1` |
| **Average** | **97.3%** (3805/3911) | **3.1x** | 101 skips (root/SELinux/tty/ulimit), 5 flaky fails |

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

We pursue a second optimization track alongside Rust: hand-crafted x86_64 assembly for platforms where maximum throughput matters. **20 tools** are implemented in assembly — static ELF binaries with no dynamic linker, no libc, and non-executable stacks.

Benchmarked on Linux x86_64, 10 MB test files, hyperfine with warmup. The **better** value in each pair is **bold**.

| Tool | Compat | Asm Size | C Size | Asm Memory | C Memory | Asm Startup | C Startup | Asm Throughput | C Throughput |
|------|-------:|--------:|---------:|-----------:|---------:|------------:|----------:|---------------:|-------------:|
| arch | ✅ 17/17 | **11.5 KB** | 42.4 KB | **716 KB** | 1,744 KB | **0.09 ms** | 0.79 ms | - | - |
| base64 | ✅ 33/33 | **5.7 KB** | 46.4 KB | **716 KB** | 1,956 KB | **0.10 ms** | 0.59 ms | 490 MB/s | **521 MB/s** |
| cut | ⚠️ 97% (96/99) | **9.3 KB** | 54.4 KB | **812 KB** | 1,784 KB | **0.01 ms** | 1.20 ms | **694 MB/s** | 303 MB/s |
| echo | ✅ 53/53 | **2.9 KB** | 42.4 KB | **716 KB** | 1,800 KB | **0.03 ms** | 0.84 ms | - | - |
| head | ⚠️ 95% (60/63) | **7.2 KB** | 50.4 KB | **684 KB** | 1,960 KB | **0.19 ms** | 0.58 ms | - | - |
| hostid | ✅ 6/6 | **2.5 KB** | 42.4 KB | **816 KB** | 2,112 KB | **0.21 ms** | 1.10 ms | - | - |
| logname | ✅ 13/13 | **2.6 KB** | 42.4 KB | **684 KB** | 2,052 KB | **0.27 ms** | 1.20 ms | - | - |
| md5sum | ✅ 30/30 | **9.6 KB** | 54.4 KB | **716 KB** | 3,996 KB | **0.02 ms** | 1.80 ms | 317 MB/s | **435 MB/s** |
| pwd | ⚠️ 94% (16/17) | **2.7 KB** | 42.4 KB | **716 KB** | 1,812 KB | **0.11 ms** | 0.61 ms | - | - |
| rev | ✅ 32/32 | **2.8 KB** | 14.4 KB | **684 KB** | 2,048 KB | **0.06 ms** | 0.86 ms | **429 MB/s** | 42 MB/s |
| sleep | ✅ 15/15 | **2.6 KB** | 42.4 KB | **716 KB** | 1,880 KB | **0.15 ms** | 0.91 ms | - | - |
| sync | ⚠️ 90% (9/10) | **3.1 KB** | 42.4 KB | **684 KB** | 1,864 KB | **0.21 ms** | 0.98 ms | - | - |
| tac | ✅ 59/59 | **4.6 KB** | 46.4 KB | 10,116 KB | **1,932 KB** | **0.04 ms** | 0.94 ms | **840 MB/s** | 758 MB/s |
| tail | ✅ 80/80 | **7.5 KB** | 78.5 KB | **716 KB** | 2,036 KB | **0.13 ms** | 0.59 ms | - | - |
| tr | ✅ 59/59 | **9.8 KB** | 58.4 KB | **1,584 KB** | 1,920 KB | **0.41 ms** | 0.96 ms | 820 MB/s | **980 MB/s** |
| true | ✅ 7/7 | **1.2 KB** | 42.4 KB | **716 KB** | 1,108 KB | **0.18 ms** | 0.57 ms | - | - |
| tty | ✅ 10/10 | **2.0 KB** | 42.4 KB | **564 KB** | 1,780 KB | **0.42 ms** | 1.34 ms | - | - |
| wc | ✅ 77/77 | **11.7 KB** | 66.5 KB | **716 KB** | 2,188 KB | **0.16 ms** | 0.79 ms | 224 MB/s | **322 MB/s** |
| whoami | ✅ 16/16 | **2.2 KB** | 42.4 KB | **812 KB** | 2,140 KB | **0.19 ms** | 1.00 ms | - | - |
| yes | ⚠️ 90% (26/29) | **1.8 KB** | 42.4 KB | **1,912 KB** | 1,948 KB | **0.93 ms** | 4.30 ms | 2.3 GB/s | **2.4 GB/s** |
| **Average** | **98.5%** (714/725) | **5.2 KB** | 46.8 KB | **1,290 KB** | 2,003 KB | **0.20 ms** | 1.10 ms | **764 MB/s** | 720 MB/s |

- **Size** — Stripped binary on disk. Assembly averages **5.2 KB** vs 45.5 KB for GNU C (8.7x smaller)
- **Memory** — Peak resident set size (RSS) during execution, measured with `/usr/bin/time -v`
- **Startup** — Wall-clock time to run with trivial or no input (hyperfine, 200+ runs). Assembly is faster because there is no dynamic linker, no libc init, and no relocation overhead
- **Throughput** — Sustained data processing rate on a 10 MB file (10 MB / wall time). `-` means the tool only prints a short string and exits, so throughput is not applicable. Tools like rev (10.2x) and cut (2.3x) show large gains; I/O-bound tools (yes, base64) converge to kernel limits

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
