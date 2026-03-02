# fcoreutils

[![Test](https://github.com/AiBrush/fcoreutils/actions/workflows/test.yml/badge.svg)](https://github.com/AiBrush/fcoreutils/actions/workflows/test.yml)
[![Release](https://github.com/AiBrush/fcoreutils/actions/workflows/release.yml/badge.svg)](https://github.com/AiBrush/fcoreutils/actions/workflows/release.yml)
[![crates.io](https://img.shields.io/crates/v/fcoreutils?color=orange)](https://crates.io/crates/fcoreutils)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![GitHub Release](https://img.shields.io/github/v/release/AiBrush/fcoreutils)](https://github.com/AiBrush/fcoreutils/releases)

High-performance GNU coreutils replacement in Rust — 100+ tools, SIMD-accelerated, drop-in compatible, cross-platform.

## Independent Test Results (v0.16.3)

*Source: [AiBrush/coreutils-rs-independent-test](https://github.com/AiBrush/coreutils-rs-independent-test) — Linux x86_64, GitHub Actions, hyperfine*

**Summary:** 107 tools tracked · **15 benchmarks at 10x+** across 9 tools · fastest: rev at 26.3x vs GNU · compat: **3797/3803 (99.8%)** — 106 tools at 100%

> Sizes are stripped release binaries. Compat is GNU test pass rate (skipped tests excluded). Speedup is peak across all benchmark scenarios. `-` = no data or not applicable. `SKIP` = requires root or SELinux, or GNU baseline not available.

| Tool | f\* size | GNU size | uutils size | Compat | f\* vs GNU | f\* vs uutils |
|------|--------:|---------:|------------:|-------:|-----------:|--------------:|
| arch | 425.2 KB | 34.5 KB | - | ✅ 100% (17/17) | 0.9x | - |
| b2sum | 633.9 KB | 54.5 KB | 2.3 MB | ✅ 100% (25/25) | 1.2x | 1.2x |
| base32 | 444.9 KB | 38.5 KB | - | ✅ 100% (29/29) | 1.6x | - |
| base64 | 550.2 KB | 38.5 KB | 1.3 MB | ✅ 100% (33/33) | **6.9x** | **5.7x** |
| basename | 429.7 KB | 34.5 KB | - | ✅ 100% (26/26) | 0.9x | - |
| basenc | 467.0 KB | 46.5 KB | - | ✅ 100% (95/95) | **2.4x** | - |
| cat | 460.2 KB | 38.5 KB | 1.3 MB | ✅ 100% (49/49) | 1.6x | 1.8x |
| chcon | 458.9 KB | 58.5 KB | - | ✅ 100% (15/15) | - | - |
| chgrp | 524.5 KB | 58.5 KB | - | ✅ 100% (17/17) | **5.8x** | - |
| chmod | 530.2 KB | 54.5 KB | - | ✅ 100% (78/78) | - | - |
| chown | 528.4 KB | 58.5 KB | - | ✅ 100% (17/17) | 1.0x | - |
| chroot | 464.7 KB | 38.5 KB | - | ✅ 100% (18/18) | - | - |
| cksum | 679.7 KB | 102.5 KB | - | ✅ 100% (48/48) | 1.3x | - |
| comm | 453.7 KB | 38.5 KB | 1.3 MB | ✅ 100% (30/30) | **4.0x** | **3.4x** |
| cp | 570.0 KB | 138.5 KB | - | ✅ 100% (69/69) | 1.2x | - |
| csplit | 1.8 MB | 50.5 KB | - | ✅ 100% (2/2) | - | - |
| cut | 626.9 KB | 38.5 KB | 1.3 MB | ✅ 100% (96/96) | **6.4x** | 1.6x |
| date | 508.5 KB | 106.5 KB | - | ✅ 100% (46/46) | 0.9x | - |
| dd | 503.9 KB | 70.5 KB | - | ✅ 100% (29/29) | 1.0x | - |
| df | 544.5 KB | 87.1 KB | - | ✅ 100% (25/25) | 1.2x | - |
| dir | 612.9 KB | 139.0 KB | - | ✅ 100% (45/45) | 1.1x | - |
| dircolors | 450.2 KB | 46.5 KB | - | ✅ 100% (14/14) | 0.9x | - |
| dirname | 426.5 KB | 34.4 KB | - | ✅ 100% (23/23) | 0.9x | - |
| du | 512.4 KB | 98.5 KB | - | ✅ 100% (51/51) | 1.0x | - |
| echo | 427.0 KB | 34.4 KB | - | ✅ 100% (53/53) | 1.2x | - |
| env | 474.7 KB | 46.9 KB | - | ✅ 100% (49/49) | 0.9x | - |
| expand | 453.5 KB | 34.5 KB | 1.3 MB | ✅ 100% (35/35) | **10.3x** | **12.9x** |
| expr | 1.8 MB | 42.4 KB | - | ✅ 100% (43/43) | 0.9x | - |
| factor | 472.0 KB | 62.5 KB | - | ✅ 100% (55/55) | 1.7x | - |
| false | 297.0 KB | 26.3 KB | - | ✅ 100% (6/6) | - | - |
| fmt | 457.4 KB | 38.5 KB | - | ✅ 100% (22/22) | 1.1x | - |
| fold | 450.7 KB | 34.5 KB | 1.3 MB | ✅ 100% (54/54) | **6.0x** | 1.5x |
| groups | 428.5 KB | 34.5 KB | - | ✅ 100% (28/28) | 0.9x | - |
| head | 454.9 KB | 42.5 KB | 1.3 MB | ✅ 100% (60/60) | **2.1x** | 1.1x |
| hostid | 424.7 KB | 34.5 KB | - | ✅ 100% (6/6) | 0.9x | - |
| id | 435.9 KB | 38.5 KB | - | ✅ 100% (27/27) | 1.1x | - |
| install | 516.6 KB | 142.5 KB | - | ✅ 100% (27/27) | 1.1x | - |
| join | 469.3 KB | 50.5 KB | 2.6 MB | ✅ 100% (37/37) | 1.2x | 1.1x |
| kill | 454.5 KB | 22.4 KB | - | ✅ 100% (20/20) | - | - |
| link | 430.5 KB | 34.5 KB | - | ✅ 100% (32/32) | 0.9x | - |
| ln | 456.4 KB | 54.5 KB | - | ✅ 100% (33/33) | 1.0x | - |
| logname | 424.7 KB | 34.5 KB | - | ✅ 100% (13/13) | 0.7x | - |
| ls | 616.0 KB | 139.0 KB | - | ✅ 100% (65/65) | 1.2x | - |
| md5sum | 648.6 KB | 38.4 KB | 2.3 MB | ✅ 100% (30/30) | 1.4x | 1.2x |
| mkdir | 443.0 KB | 74.5 KB | - | ✅ 100% (37/37) | 1.0x | - |
| mkfifo | 432.3 KB | 42.5 KB | - | ✅ 100% (11/11) | 0.9x | - |
| mknod | 437.0 KB | 42.5 KB | - | ✅ 100% (12/12) | 1.0x | - |
| mktemp | 443.9 KB | 34.5 KB | - | ✅ 100% (15/15) | 0.9x | - |
| mv | 474.8 KB | 134.5 KB | - | ✅ 100% (3/3) | 1.1x | - |
| nice | 457.7 KB | 34.5 KB | - | ✅ 100% (32/32) | 0.9x | - |
| nl | 1.8 MB | 38.6 KB | 2.7 MB | ✅ 100% (60/60) | **5.5x** | 1.6x |
| nohup | 455.9 KB | 34.4 KB | - | ✅ 100% (11/11) | 0.9x | - |
| nproc | 444.4 KB | 34.5 KB | - | ✅ 100% (29/29) | 0.9x | - |
| numfmt | 528.7 KB | 58.5 KB | - | ✅ 100% (31/31) | 1.0x | - |
| od | 536.6 KB | 70.5 KB | - | ✅ 100% (50/50) | **10.7x** | - |
| paste | 450.4 KB | 38.4 KB | 1.2 MB | ✅ 100% (30/30) | **2.1x** | **18.6x** |
| pathchk | 438.7 KB | 34.5 KB | - | ✅ 100% (22/22) | 0.9x | - |
| pinky | 768.2 KB | 38.4 KB | - | ✅ 100% (32/32) | 0.7x | - |
| pr | 502.0 KB | 70.6 KB | - | ✅ 100% (18/18) | **4.0x** | - |
| printenv | 428.7 KB | 34.4 KB | - | ✅ 100% (9/9) | 0.9x | - |
| printf | 494.8 KB | 54.4 KB | - | ✅ 100% (74/74) | 0.9x | - |
| ptx | 533.7 KB | 54.5 KB | - | ✅ 100% (15/15) | 1.9x | - |
| pwd | 429.7 KB | 34.5 KB | - | ✅ 100% (16/16) | - | - |
| readlink | 444.2 KB | 42.4 KB | - | ✅ 100% (60/60) | 0.9x | - |
| realpath | 445.0 KB | 42.4 KB | - | ✅ 100% (43/43) | 0.8x | - |
| rev | 439.3 KB | 14.4 KB | - | ✅ 100% (32/32) | **26.3x** | - |
| rm | 532.7 KB | 58.5 KB | - | ✅ 100% (23/23) | 1.0x | - |
| rmdir | 431.2 KB | 46.4 KB | - | ✅ 100% (21/21) | 0.9x | - |
| runcon | 463.9 KB | 34.5 KB | - | ✅ 100% (2/2) | - | - |
| seq | 546.7 KB | 50.5 KB | - | ✅ 100% (62/62) | **15.5x** | - |
| sha1sum | 641.8 KB | 38.4 KB | - | ✅ 100% (43/43) | 1.4x | - |
| sha224sum | 642.5 KB | 38.4 KB | - | ✅ 100% (39/39) | 1.1x | - |
| sha256sum | 643.3 KB | 38.4 KB | 2.3 MB | ✅ 100% (34/34) | 1.5x | 1.0x |
| sha384sum | 644.4 KB | 38.4 KB | - | ✅ 100% (39/39) | 0.9x | - |
| sha512sum | 643.5 KB | 38.4 KB | - | ✅ 100% (39/39) | 0.9x | - |
| shred | 456.9 KB | 54.5 KB | - | ✅ 100% (27/27) | **14.6x** | - |
| shuf | 482.6 KB | 46.5 KB | - | ✅ 100% (52/52) | **3.1x** | - |
| sleep | 444.4 KB | 34.5 KB | - | ✅ 100% (15/15) | 0.9x | - |
| sort | 1.1 MB | 102.8 KB | 3.2 MB | ✅ 100% (111/111) | **13.6x** | **12.1x** |
| split | 539.9 KB | 54.9 KB | - | ✅ 100% (72/72) | 1.0x | - |
| stat | 463.7 KB | 86.5 KB | - | ✅ 100% (38/38) | 1.1x | - |
| stdbuf | 484.4 KB | 50.5 KB | - | ✅ 100% (13/13) | 1.0x | - |
| stty | 454.7 KB | 78.5 KB | - | ✅ 100% (25/25) | - | - |
| sum | 442.5 KB | 34.4 KB | - | ✅ 100% (23/23) | 1.2x | - |
| sync | 430.6 KB | 34.4 KB | - | ✅ 100% (9/9) | 0.9x | - |
| tac | 1.9 MB | 38.4 KB | 2.7 MB | ✅ 100% (59/59) | **2.6x** | 1.7x |
| tail | 478.7 KB | 62.5 KB | 1.7 MB | ✅ 100% (80/80) | **2.0x** | **2.2x** |
| tee | 436.3 KB | 38.5 KB | - | ✅ 100% (27/27) | 1.3x | - |
| test | 440.2 KB | 46.4 KB | - | ✅ 100% (116/116) | - | - |
| timeout | 487.0 KB | 38.9 KB | - | ✅ 100% (36/36) | 0.8x | - |
| touch | 464.5 KB | 94.5 KB | - | ✅ 100% (45/45) | 0.9x | - |
| tr | 699.5 KB | 46.5 KB | 1.3 MB | ✅ 100% (59/59) | **6.6x** | **6.0x** |
| true | 296.6 KB | 26.3 KB | - | ✅ 100% (7/7) | - | - |
| truncate | 441.9 KB | 38.5 KB | - | ✅ 100% (46/46) | 1.0x | - |
| tsort | 460.2 KB | 46.5 KB | - | ✅ 100% (19/19) | **10.5x** | - |
| tty | 425.8 KB | 34.5 KB | - | ✅ 100% (10/10) | 1.1x | - |
| uname | 428.6 KB | 34.5 KB | - | ✅ 100% (14/14) | 1.0x | - |
| unexpand | 454.3 KB | 38.5 KB | 1.3 MB | ✅ 100% (26/26) | **5.7x** | **2.9x** |
| uniq | 903.0 KB | 38.5 KB | 1.3 MB | ✅ 100% (85/85) | **12.0x** | **6.0x** |
| unlink | 429.4 KB | 34.5 KB | - | ✅ 100% (30/30) | 1.0x | - |
| uptime | 501.2 KB | 14.4 KB | - | ✅ 100% (16/16) | 1.5x | - |
| users | 461.2 KB | 34.5 KB | - | ✅ 100% (6/6) | 0.9x | - |
| vdir | 612.9 KB | 139.0 KB | - | ✅ 100% (41/41) | 1.1x | - |
| wc | 909.5 KB | 54.5 KB | 1.4 MB | ✅ 100% (77/77) | **18.2x** | **18.2x** |
| who | 785.0 KB | 58.5 KB | - | ✅ 100% (38/38) | 0.8x | - |
| whoami | 425.0 KB | 34.5 KB | - | ✅ 100% (16/16) | 0.9x | - |
| yes | 431.1 KB | 34.4 KB | - | ⚠️ 79% (23/29) | 1.0x | - |

### Remaining Failures (6)

| Tool | Failed | Cause |
|------|--------|-------|
| yes | 6/29 | Non-deterministic stderr/stdout interleaving via `2>&1` with long padded strings |

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

We are pursuing a second optimization track alongside Rust: hand-crafted x86_64 assembly for platforms where maximum throughput matters. We started with `yes` — it is simple enough to implement completely and serves as a proof-of-concept for the approach.

Our assembly `yes` achieves **~2.6 GB/s** (1.89x faster than GNU yes, 1.25x faster than our Rust implementation) while compiling to under 1,900 bytes with no runtime dependencies.

| Binary         | Size          | Throughput  | Memory (RSS) | Startup  |
|----------------|---------------|-------------|--------------|----------|
| fyes (asm)     | 1,853 bytes   | 2,060 MB/s  | 28 KB        | 0.24 ms  |
| GNU yes (C)    | 35,208 bytes  | 2,189 MB/s  | 1,956 KB     | 0.75 ms  |
| fyes (Rust)    | ~435 KB       | ~2,190 MB/s | ~2,000 KB    | ~0.75 ms |

Benchmarked on Linux x86_64. At pipe-limited throughput all three write at ~2.1 GB/s.
The assembly wins on binary size (19x smaller), memory (70x less RSS), and startup latency (3x faster).

On **Linux x86_64** and **Linux ARM64**, releases ship the assembly binary. All other platforms (macOS, Windows) use the Rust implementation. The assembly binary is a static ELF with only two syscalls (`write` and `exit`/`exit_group`), no dynamic linker, and a non-executable stack.

Our priority remains **100% GNU compatibility in Rust first**. We will pursue assembly implementations for additional commands over time, as the tooling and verification process matures. The goal is not to rush assembly ports but to do them right — with full security review and byte-for-byte compatibility testing.

See [`assembly/yes/`](assembly/yes/) for the source and [`tests/assembly/`](tests/assembly/) for the test suite.

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
