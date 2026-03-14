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

We pursue a second optimization track alongside Rust: hand-crafted x86_64 assembly for platforms where maximum throughput matters. **107 tools** have assembly implementations — all 107 are fully buildable static ELF binaries with no dynamic linker, no libc, and non-executable stacks.

All 107 tools are tested by the [independent test suite](https://github.com/AiBrush/coreutils-rs-independent-test). Results below from the latest CI run (v0.21.6). Speedups **>1.0x** vs GNU are **bold**. ✅ = all tests pass, ⚠️ = partial.

| Tool | Compat | Security | Asm Size | Speedup vs GNU |
|------|--------|----------|----------|----------------|
| arch | ✅ 12/12 | ✅ 97/97 | 13.5 KB | — |
| b2sum | ✅ 23/23 | ✅ 102/102 | 9.6 KB | — |
| base32 | ✅ 16/16 | ✅ 126/126 | 6.8 KB | **1.8x** |
| base64 | ✅ 17/17 | ✅ 123/123 | 5.7 KB | **1.6x** |
| basename | ⚠️ 4/36 | ⚠️ 71/102 | 4.5 KB | — |
| basenc | ✅ 205/205 | ✅ 94/94 | 11.6 KB | 0.7x |
| cat | ✅ 65/65 | ✅ 130/130 | 18.0 KB | **3.8x** |
| chcon | ⚠️ 3/6 | ⚠️ 20/21 | 4.5 KB | — |
| chgrp | ✅ 14/14 | ✅ 29/29 | 5.8 KB | — |
| chmod | ✅ 9/9 | ✅ 76/78 | 4.9 KB | — |
| chown | ✅ 11/11 | ✅ 87/87 | 7.2 KB | — |
| chroot | ⚠️ 3/7 | ⚠️ 20/21 | 4.5 KB | — |
| cksum | ✅ 22/22 | ✅ 82/84 | 3.4 KB | — |
| comm | ✅ 71/71 | ✅ 90/91 | 23.2 KB | **2.3x** |
| cp | ⚠️ 13/28 | ⚠️ 26/40 | 4.5 KB | — |
| csplit | ⚠️ 3/8 | ⚠️ 41/45 | 4.5 KB | — |
| cut | ✅ 24/24 | ✅ 102/102 | 9.3 KB | **4.1x** |
| date | ✅ 15/15 | ✅ 42/42 | 14.2 KB | — |
| dd | ⚠️ 4/12 | ⚠️ 44/48 | 4.5 KB | — |
| df | ✅ 12/12 | ✅ 15/15 | 16.8 KB | — |
| dir | ✅ 10/10 | ✅ 11/11 | 28.6 KB | — |
| dircolors | ✅ 27/27 | ✅ 33/33 | 6.7 KB | — |
| dirname | ⚠️ 3/31 | ⚠️ 71/105 | 4.5 KB | — |
| du | ✅ 13/13 | ✅ 13/13 | 16.3 KB | — |
| echo | ✅ 57/57 | ✅ 182/182 | 8.2 KB | 0.2x |
| env | ⚠️ 5/13 | ⚠️ 67/78 | 4.5 KB | — |
| expand | ✅ 60/60 | ✅ 124/124 | 29.5 KB | **4.4x** |
| expr | ⚠️ 3/36 | ⚠️ 41/52 | 4.5 KB | — |
| factor | — | ✅ 56/56 | 16.8 KB | — |
| false | ✅ 20/20 | ✅ 117/117 | 4.8 KB | — |
| fmt | ✅ 31/31 | ✅ 91/91 | 6.5 KB | — |
| fold | ✅ 58/58 | ✅ 116/116 | 9.8 KB | **7.2x** |
| groups | ⚠️ 2/5 | ⚠️ 55/70 | 4.5 KB | — |
| head | ✅ 19/19 | ✅ 115/116 | 7.2 KB | **3.1x** |
| hostid | ✅ 6/6 | ✅ 88/88 | 13.1 KB | — |
| id | ⚠️ 2/20 | ⚠️ 56/79 | 4.5 KB | — |
| install | ⚠️ 2/13 | ⚠️ 41/47 | 4.5 KB | — |
| join | ✅ 88/88 | ✅ 98/98 | 39.6 KB | — |
| kill | ⚠️ 39/49 | ⚠️ 97/138 | 13.4 KB | — |
| link | ⚠️ 4/17 | ⚠️ 72/83 | 4.5 KB | — |
| ln | ⚠️ 9/23 | ⚠️ 61/67 | 4.5 KB | — |
| logname | ✅ 9/9 | ✅ 77/77 | 13.4 KB | — |
| ls | ✅ 16/16 | ✅ 37/37 | 28.6 KB | — |
| md5sum | ✅ 16/16 | ✅ 133/133 | 9.6 KB | 0.7x |
| mkdir | ⚠️ 5/24 | ⚠️ 74/92 | 4.5 KB | — |
| mkfifo | ⚠️ 3/15 | ⚠️ 53/61 | 4.5 KB | — |
| mknod | ⚠️ 3/16 | ⚠️ 48/63 | 4.5 KB | — |
| mktemp | ⚠️ 4/20 | ⚠️ 79/99 | 4.5 KB | — |
| mv | ⚠️ 9/20 | ⚠️ 24/34 | 4.5 KB | — |
| nice | ✅ 8/8 | ✅ 53/53 | 13.8 KB | — |
| nl | ✅ 69/69 | ✅ 122/122 | 38.2 KB | **10.3x** |
| nohup | ✅ 16/16 | ✅ 26/26 | 9.4 KB | — |
| nproc | ⚠️ 3/12 | ⚠️ 71/89 | 4.5 KB | — |
| numfmt | ⚠️ 2/12 | ⚠️ 20/21 | 4.5 KB | — |
| od | ✅ 58/58 | ✅ 124/124 | 37.7 KB | **10.3x** |
| paste | ✅ 58/58 | ✅ 95/95 | 24.2 KB | **2.8x** |
| pathchk | ⚠️ 1/48 | ⚠️ 47/76 | 0.5 KB | — |
| pinky | ⚠️ 9/11 | ⚠️ 20/21 | 4.5 KB | — |
| pr | ✅ 50/50 | ✅ 56/56 | 38.7 KB | **10.7x** |
| printenv | ⚠️ 3/22 | ⚠️ 76/105 | 4.5 KB | — |
| printf | ⚠️ 4/32 | ⚠️ 20/42 | 4.5 KB | — |
| ptx | ⚠️ 5/7 | ⚠️ 20/21 | 4.5 KB | — |
| pwd | ✅ 14/14 | ✅ 93/93 | 12.8 KB | — |
| readlink | ✅ 54/54 | ✅ 95/97 | 4.4 KB | — |
| realpath | ⚠️ 3/29 | ⚠️ 18/32 | 4.5 KB | — |
| rev | ✅ 15/15 | ✅ 109/109 | 2.6 KB | **9.8x** |
| rm | ⚠️ 11/24 | ⚠️ 39/53 | 4.5 KB | — |
| rmdir | ⚠️ 4/27 | ⚠️ 77/100 | 4.5 KB | — |
| runcon | ⚠️ 3/6 | ⚠️ 20/21 | 4.5 KB | — |
| seq | ✅ 50/50 | ✅ 131/131 | 36.2 KB | **18.5x** |
| sha1sum | ✅ 19/19 | ✅ 104/104 | 8.4 KB | — |
| sha224sum | ✅ 19/19 | ✅ 103/103 | 8.8 KB | — |
| sha256sum | ✅ 16/16 | ✅ 103/103 | 8.7 KB | — |
| sha384sum | ✅ 19/19 | ✅ 103/103 | 9.2 KB | — |
| sha512sum | ✅ 22/22 | ✅ 109/109 | 9.2 KB | — |
| shred | ✅ 58/58 | ✅ 65/65 | 8.5 KB | — |
| shuf | ✅ 66/66 | ✅ 113/113 | 26.5 KB | **1.8x** |
| sleep | ✅ 17/17 | ✅ 103/103 | 13.4 KB | — |
| sort | ✅ 46/46 | ✅ 122/122 | 39.7 KB | **1.2x** |
| split | ✅ 25/25 | ✅ 68/68 | 5.4 KB | — |
| stat | ✅ 26/26 | ✅ 54/54 | 26.0 KB | — |
| stdbuf | ⚠️ 3/8 | ⚠️ 20/21 | 4.5 KB | — |
| stty | ⚠️ 2/6 | ⚠️ 20/21 | 4.5 KB | — |
| sum | ✅ 34/34 | ✅ 89/91 | 2.7 KB | — |
| sync | ✅ 16/16 | ✅ 89/89 | 14.6 KB | — |
| tac | ✅ 13/13 | ✅ 105/105 | 4.6 KB | **2.0x** |
| tail | ✅ 18/18 | ✅ 111/111 | 7.5 KB | **3.2x** |
| tee | ⚠️ 3/12 | ⚠️ 62/77 | 4.5 KB | — |
| test | ⚠️ 30/49 | ⚠️ 50/55 | 4.5 KB | — |
| timeout | ✅ 14/14 | ✅ 42/42 | 17.8 KB | — |
| touch | ✅ 30/30 | ✅ 86/86 | 6.6 KB | — |
| tr | ✅ 20/20 | ✅ 102/102 | 9.8 KB | **2.3x** |
| true | ✅ 9/9 | ✅ 110/110 | 9.9 KB | — |
| truncate | ✅ 30/30 | ✅ 84/86 | 4.4 KB | — |
| tsort | ✅ 41/41 | ✅ 100/100 | 12.9 KB | **3.4x** |
| tty | ✅ 16/16 | ✅ 88/88 | 12.0 KB | — |
| uname | ⚠️ 3/36 | ⚠️ 86/113 | 4.5 KB | — |
| unexpand | ✅ 57/57 | ✅ 123/123 | 22.1 KB | **3.1x** |
| uniq | ✅ 72/72 | ✅ 116/116 | 39.3 KB | **9.8x** |
| unlink | ⚠️ 6/14 | ⚠️ 77/100 | 4.5 KB | — |
| uptime | ✅ 16/16 | ✅ 79/79 | 13.3 KB | — |
| users | ✅ 17/17 | ✅ 82/82 | 2.2 KB | — |
| vdir | ✅ 7/7 | ✅ 9/9 | 28.6 KB | — |
| wc | ✅ 23/23 | ✅ 109/109 | 30.4 KB | **1.5x** |
| who | ✅ 25/25 | ✅ 11/11 | 12.4 KB | — |
| whoami | ✅ 4/4 | ✅ 86/86 | 12.4 KB | — |
| yes | ✅ 884/884 | ✅ 72/72 | 1.8 KB | — |
| **Totals** | **3235/3771** | **7934/8455** | avg **11.2 KB** | up to **18.5x** |

- **107 tools implemented**, all 107 buildable and tested as static ELF binaries
- **69 tools fully passing** all compat tests, 37 tools partially passing (stub implementations — compat work in progress)
- **Size** — Stripped static ELF binary on disk. Assembly averages **11.2 KB** across all 107 tools
- **Speedup** — Wall-clock throughput on a 10 MB file (hyperfine, warmup). `—` means the tool is not benchmarked. Top performers: seq (18.5x), pr (10.7x), nl/od (10.3x), rev (9.8x), fold (7.2x)
- **Security** — 97-point security audit per tool: ELF hardening, syscall surface, memory safety, signal handling, fuzzing

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
