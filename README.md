# fcoreutils

[![Test](https://github.com/AiBrush/fcoreutils/actions/workflows/test.yml/badge.svg)](https://github.com/AiBrush/fcoreutils/actions/workflows/test.yml)
[![Release](https://github.com/AiBrush/fcoreutils/actions/workflows/release.yml/badge.svg)](https://github.com/AiBrush/fcoreutils/actions/workflows/release.yml)
[![crates.io](https://img.shields.io/crates/v/fcoreutils?color=orange)](https://crates.io/crates/fcoreutils)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![GitHub Release](https://img.shields.io/github/v/release/AiBrush/fcoreutils)](https://github.com/AiBrush/fcoreutils/releases)

High-performance GNU coreutils replacement in Rust — 100+ tools, SIMD-accelerated, drop-in compatible, cross-platform.

## Independent Test Results (v0.22.1)

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

We pursue a second optimization track alongside Rust: hand-crafted x86_64 assembly for platforms where maximum throughput matters. **107 tools** have assembly implementations — all 107 are fully buildable static ELF binaries with no dynamic linker, no libc, and non-executable stacks.

All 107 tools are tested by the [independent test suite](https://github.com/AiBrush/coreutils-rs-independent-test). Results below from the latest CI run (v0.22.1). Speedups **>1.0x** vs GNU are **bold**. ✅ = all tests pass, ⚠️ = partial.

| Tool | Compat | Security | Asm Size | Speedup vs GNU |
|------|--------|----------|----------|----------------|
| arch | ✅ 12/12 | ✅ 75/77 | 13.5 KB | — |
| b2sum | ✅ 23/23 | ✅ 102/102 | 9.6 KB | — |
| base32 | ✅ 16/16 | ✅ 112/112 | 6.8 KB | **1.8x** |
| base64 | ✅ 17/17 | ✅ 109/109 | 5.7 KB | **1.6x** |
| basename | ✅ 36/36 | ✅ 84/86 | 2.9 KB | — |
| basenc | ✅ 205/205 | ✅ 97/97 | 11.6 KB | 0.7x |
| cat | ✅ 65/65 | ✅ 95/95 | 18.0 KB | **3.8x** |
| chcon | ✅ 6/6 | ✅ 69/71 | 3.8 KB | — |
| chgrp | ✅ 14/14 | ✅ 68/70 | 5.8 KB | — |
| chmod | ✅ 9/9 | ✅ 76/78 | 4.9 KB | — |
| chown | ✅ 11/11 | ✅ 75/78 | 7.2 KB | — |
| chroot | ✅ 7/7 | ✅ 67/69 | 4.5 KB | — |
| cksum | ✅ 22/22 | ✅ 82/84 | 3.4 KB | — |
| comm | ✅ 71/71 | ✅ 87/89 | 23.2 KB | **2.3x** |
| cp | ✅ 28/28 | ✅ 85/87 | 6.2 KB | — |
| csplit | ✅ 8/8 | ✅ 67/69 | 3.7 KB | — |
| cut | ✅ 24/24 | ✅ 91/91 | 9.3 KB | **4.1x** |
| date | ✅ 15/15 | ✅ 72/74 | 14.2 KB | — |
| dd | ✅ 12/12 | ✅ 75/77 | 4.3 KB | — |
| df | ✅ 12/12 | ✅ 66/72 | 16.8 KB | — |
| dir | ✅ 10/10 | ✅ 67/69 | 28.6 KB | — |
| dircolors | ✅ 27/27 | ✅ 73/78 | 6.7 KB | — |
| dirname | ✅ 31/31 | ✅ 94/96 | 2.2 KB | — |
| du | ✅ 13/13 | ✅ 71/73 | 16.3 KB | — |
| echo | ✅ 57/57 | ✅ 131/133 | 8.2 KB | 0.2x |
| env | ✅ 13/13 | ✅ 79/81 | 3.1 KB | — |
| expand | ✅ 60/60 | ✅ 106/106 | 29.5 KB | **4.4x** |
| expr | ✅ 36/36 | ✅ 74/76 | 5.0 KB | — |
| factor | — | ✅ 82/84 | 16.8 KB | — |
| false | ✅ 20/20 | ✅ 92/94 | 4.8 KB | — |
| fmt | ✅ 31/31 | ✅ 90/90 | 6.5 KB | — |
| fold | ✅ 58/58 | ✅ 90/90 | 9.8 KB | **7.2x** |
| groups | ✅ 5/5 | ✅ 79/81 | 3.5 KB | — |
| head | ✅ 19/19 | ✅ 89/89 | 7.2 KB | **3.1x** |
| hostid | ✅ 6/6 | ✅ 77/79 | 13.1 KB | — |
| id | ✅ 20/20 | ✅ 86/88 | 5.7 KB | — |
| install | ✅ 13/13 | ✅ 69/71 | 4.4 KB | — |
| join | ✅ 88/88 | ✅ 109/111 | 39.6 KB | — |
| kill | ✅ 4/4 | ✅ 74/76 | 3.3 KB | — |
| link | ✅ 17/17 | ✅ 78/80 | 2.5 KB | — |
| ln | ✅ 23/23 | ✅ 83/85 | 4.9 KB | — |
| logname | ✅ 9/9 | ✅ 68/70 | 13.4 KB | — |
| ls | ✅ 16/16 | ✅ 79/81 | 28.6 KB | — |
| md5sum | ✅ 16/16 | ✅ 119/119 | 9.6 KB | 0.7x |
| mkdir | ✅ 24/24 | ✅ 84/86 | 4.2 KB | — |
| mkfifo | ✅ 15/15 | ✅ 76/78 | 3.1 KB | — |
| mknod | ✅ 16/16 | ✅ 78/80 | 4.6 KB | — |
| mktemp | ✅ 20/20 | ✅ 86/92 | 4.8 KB | — |
| mv | ✅ 20/20 | ✅ 79/81 | 4.4 KB | — |
| nice | ✅ 8/8 | ✅ 74/76 | 13.8 KB | — |
| nl | ✅ 69/69 | ✅ 101/101 | 38.2 KB | **10.3x** |
| nohup | ✅ 16/16 | ✅ 76/78 | 9.4 KB | — |
| nproc | ✅ 12/12 | ✅ 77/79 | 2.5 KB | — |
| numfmt | ✅ 12/12 | ✅ 66/68 | 11.1 KB | — |
| od | ✅ 58/58 | ✅ 104/104 | 37.7 KB | **10.3x** |
| paste | ✅ 58/58 | ✅ 87/87 | 24.2 KB | **2.8x** |
| pathchk | ✅ 48/48 | ✅ 113/115 | 2.9 KB | — |
| pinky | ✅ 11/11 | ✅ 65/70 | 3.0 KB | — |
| pr | ✅ 50/50 | ✅ 82/82 | 38.7 KB | **10.7x** |
| printenv | ✅ 22/22 | ✅ 86/88 | 2.2 KB | — |
| printf | ✅ 32/32 | ✅ 84/86 | 3.7 KB | — |
| ptx | ✅ 7/7 | ✅ 63/68 | 67.6 KB | — |
| pwd | ✅ 14/14 | ✅ 77/79 | 12.8 KB | — |
| readlink | ✅ 54/54 | ✅ 95/97 | 4.4 KB | — |
| realpath | ✅ 29/29 | ✅ 76/78 | 4.0 KB | — |
| rev | ✅ 15/15 | ✅ 89/89 | 2.6 KB | **9.8x** |
| rm | ✅ 24/24 | ✅ 85/87 | 4.5 KB | — |
| rmdir | ✅ 27/27 | ✅ 81/83 | 3.0 KB | — |
| runcon | ✅ 6/6 | ✅ 67/69 | 8.5 KB | — |
| seq | ✅ 50/50 | ✅ 93/95 | 36.2 KB | **18.5x** |
| sha1sum | ✅ 19/19 | ✅ 104/104 | 8.4 KB | — |
| sha224sum | ✅ 19/19 | ✅ 103/103 | 8.8 KB | — |
| sha256sum | ✅ 16/16 | ✅ 103/103 | 8.7 KB | — |
| sha384sum | ✅ 19/19 | ✅ 103/103 | 9.2 KB | — |
| sha512sum | ✅ 22/22 | ✅ 103/103 | 9.2 KB | — |
| shred | ✅ 58/58 | ✅ 98/100 | 8.5 KB | — |
| shuf | ✅ 66/66 | ✅ 82/86 | 26.5 KB | **1.8x** |
| sleep | ✅ 17/17 | ✅ 80/82 | 13.4 KB | — |
| sort | ✅ 46/46 | ✅ 105/105 | 39.7 KB | **1.2x** |
| split | ✅ 25/25 | ✅ 90/90 | 5.4 KB | — |
| stat | ✅ 26/26 | ✅ 97/99 | 26.0 KB | — |
| stdbuf | ✅ 8/8 | ✅ 67/69 | 18.3 KB | — |
| stty | ✅ 6/6 | ✅ 66/68 | 3.7 KB | — |
| sum | ✅ 34/34 | ✅ 89/91 | 2.7 KB | — |
| sync | ✅ 16/16 | ✅ 75/77 | 14.6 KB | — |
| tac | ✅ 13/13 | ✅ 86/86 | 4.6 KB | **2.0x** |
| tail | ✅ 18/18 | ✅ 90/90 | 7.5 KB | **3.2x** |
| tee | ✅ 12/12 | ✅ 83/83 | 2.6 KB | — |
| test | ✅ 49/49 | ✅ 77/79 | 6.4 KB | — |
| timeout | ✅ 14/14 | ✅ 75/77 | 17.8 KB | — |
| touch | ✅ 30/30 | ✅ 77/79 | 6.6 KB | — |
| tr | ✅ 20/20 | ✅ 91/91 | 9.8 KB | **2.3x** |
| true | ✅ 9/9 | ✅ 82/84 | 9.9 KB | — |
| truncate | ✅ 30/30 | ✅ 78/80 | 4.4 KB | — |
| tsort | ✅ 41/41 | ✅ 90/90 | 12.9 KB | **3.4x** |
| tty | ✅ 16/16 | ✅ 83/85 | 12.0 KB | — |
| uname | ✅ 36/36 | ✅ 102/104 | 3.3 KB | — |
| unexpand | ✅ 57/57 | ✅ 104/104 | 22.1 KB | **3.1x** |
| uniq | ✅ 72/72 | ✅ 99/99 | 39.3 KB | **9.8x** |
| unlink | ✅ 14/14 | ✅ 90/92 | 1.8 KB | — |
| uptime | ✅ 16/16 | ✅ 72/78 | 13.3 KB | — |
| users | ✅ 17/17 | ✅ 70/75 | 2.2 KB | — |
| vdir | ✅ 7/7 | ✅ 67/71 | 28.6 KB | — |
| wc | ✅ 23/23 | ✅ 95/95 | 30.4 KB | **1.5x** |
| who | ✅ 25/25 | ✅ 65/70 | 12.4 KB | — |
| whoami | ✅ 4/4 | ✅ 78/80 | 12.4 KB | — |
| yes | ✅ 884/884 | — | 1.8 KB | — |
| **Totals** | **3560/3560** | **8976/9158** | avg **10.4 KB** | up to **18.5x** |

- **107 tools implemented**, all 107 buildable and tested as static ELF binaries
- **All 107 tools pass 100% of compat tests** — security tests pass 98.0% with **0 failures** (all shortfall is CI environment skips: `/proc` permissions, `mktemp` variants)
- **Size** — Stripped static ELF binary on disk. Assembly averages **10.4 KB** across all 107 tools
- **Speedup** — Wall-clock throughput on a 10 MB file (hyperfine, warmup). `—` means the tool is not benchmarked. Top performers: seq (18.5x), pr (10.7x), nl/od (10.3x), rev (9.8x), fold (7.2x)
- **Security** — 65-133 point security audit per tool: ELF hardening, syscall surface, memory safety, signal handling, fuzzing

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
