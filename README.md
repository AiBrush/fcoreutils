# fcoreutils

[![Test](https://github.com/AiBrush/fcoreutils/actions/workflows/test.yml/badge.svg)](https://github.com/AiBrush/fcoreutils/actions/workflows/test.yml)
[![Release](https://github.com/AiBrush/fcoreutils/actions/workflows/release.yml/badge.svg)](https://github.com/AiBrush/fcoreutils/actions/workflows/release.yml)
[![crates.io](https://img.shields.io/crates/v/fcoreutils?color=orange)](https://crates.io/crates/fcoreutils)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![GitHub Release](https://img.shields.io/github/v/release/AiBrush/fcoreutils)](https://github.com/AiBrush/fcoreutils/releases)

High-performance GNU coreutils replacement in Rust — 100+ tools, SIMD-accelerated, drop-in compatible, cross-platform.

## Independent Test Results (v0.11.3)

*Source: [AiBrush/coreutils-rs-independent-test](https://github.com/AiBrush/coreutils-rs-independent-test) — Linux x86_64, GitHub Actions, 100MB file, hyperfine*

**Summary:** 107 tools tracked · **2204/2213 tests passed (99.6%)** · 96 tools at 100% · fastest: wc at 26.1x vs GNU

> Sizes are stripped release binaries. Compat is GNU test pass rate (skipped tests excluded). Speedup is peak across all benchmark scenarios. `-` = no data or not applicable. `SKIP` = requires root or SELinux, or GNU baseline not available.

| Tool | f\* size | GNU size | uutils size | Compat | f\* vs GNU | f\* vs uutils |
|------|--------:|---------:|------------:|-------:|-----------:|--------------:|
| arch | 424.9 KB | 34.5 KB | - | ✅ 100% (5/5) | 0.8x | - |
| b2sum | 633.9 KB | 54.5 KB | 2.3 MB | ✅ 100% (25/25) | 1.3x | 1.2x |
| base32 | 445.3 KB | 38.5 KB | - | ✅ 100% (29/29) | **1.5x** | - |
| base64 | 558.6 KB | 38.5 KB | 1.3 MB | ✅ 100% (33/33) | **5.8x** | **6.1x** |
| basename | 429.7 KB | 34.5 KB | - | ✅ 100% (26/26) | 0.8x | - |
| basenc | 458.9 KB | 46.5 KB | - | ✅ 100% (40/40) | 1.1x | - |
| cat | 458.7 KB | 38.5 KB | 1.3 MB | ✅ 100% (46/46) | **2.4x** | **1.8x** |
| chcon | 458.9 KB | 58.5 KB | - | SKIP | - | - |
| chgrp | 523.9 KB | 58.5 KB | - | ✅ 100% (11/11) | 1.0x | - |
| chmod | 525.5 KB | 54.5 KB | - | ✅ 100% (33/33) | 0.9x | - |
| chown | 528.4 KB | 58.5 KB | - | ✅ 100% (11/11) | 1.1x | - |
| chroot | 464.7 KB | 38.5 KB | - | SKIP | - | - |
| cksum | 450.5 KB | 102.5 KB | - | ✅ 100% (21/21) | 1.2x | - |
| comm | 453.7 KB | 38.5 KB | 1.3 MB | ✅ 100% (30/30) | **3.4x** | **3.3x** |
| cp | 494.2 KB | 138.5 KB | - | ✅ 100% (18/18) | 0.9x | - |
| csplit | 1.8 MB | 50.5 KB | - | SKIP | **17.6x** | - |
| cut | 635.1 KB | 38.5 KB | 1.3 MB | ✅ 100% (49/49) | **5.3x** | **1.7x** |
| date | 505.2 KB | 106.5 KB | - | ✅ 100% (32/32) | - | - |
| dd | 495.7 KB | 70.5 KB | - | ✅ 100% (17/17) | 0.9x | - |
| df | 539.7 KB | 87.1 KB | - | ❌ 53% (9/17) | - | - |
| dir | 585.5 KB | 139.0 KB | - | SKIP | - | - |
| dircolors | 450.1 KB | 46.5 KB | - | ✅ 100% (14/14) | - | - |
| dirname | 426.5 KB | 34.4 KB | - | ✅ 100% (23/23) | 0.8x | - |
| du | 510.9 KB | 98.5 KB | - | ✅ 100% (23/23) | - | - |
| echo | 426.4 KB | 34.4 KB | - | ✅ 100% (38/38) | 0.8x | - |
| env | 467.4 KB | 46.9 KB | - | ✅ 100% (17/17) | 0.9x | - |
| expand | 446.7 KB | 34.5 KB | 1.3 MB | ✅ 100% (33/33) | **10.0x** | **12.9x** |
| expr | 1.8 MB | 42.4 KB | - | ✅ 100% (43/43) | 0.8x | - |
| factor | 453.0 KB | 62.5 KB | - | ✅ 100% (26/26) | 0.9x | - |
| false | 297.0 KB | 26.3 KB | - | ✅ 100% (7/7) | - | - |
| fmt | 457.9 KB | 38.5 KB | - | ✅ 100% (18/18) | - | - |
| fold | 445.7 KB | 34.5 KB | 1.3 MB | ✅ 100% (35/35) | **5.1x** | **1.7x** |
| groups | 428.5 KB | 34.5 KB | - | ✅ 100% (4/4) | 0.8x | - |
| head | 455.3 KB | 42.5 KB | 1.3 MB | ✅ 100% (47/47) | **1.9x** | 1.2x |
| hostid | 424.7 KB | 34.5 KB | - | ✅ 100% (6/6) | 0.9x | - |
| id | 433.1 KB | 38.5 KB | - | ✅ 100% (16/16) | 1.0x | - |
| install | 513.4 KB | 142.5 KB | - | ✅ 100% (11/11) | 1.1x | - |
| join | 468.2 KB | 50.5 KB | 2.6 MB | ✅ 100% (35/35) | 0.7x | 0.8x |
| kill | 453.2 KB | 22.4 KB | - | SKIP | - | - |
| link | 430.5 KB | 34.5 KB | - | ✅ 100% (8/8) | 0.9x | - |
| ln | 451.7 KB | 54.5 KB | - | ✅ 100% (16/16) | 0.9x | - |
| logname | 424.7 KB | 34.5 KB | - | ✅ 100% (3/3) | 0.8x | - |
| ls | 586.9 KB | 139.0 KB | - | ✅ 100% (42/42) | - | - |
| md5sum | 646.2 KB | 38.4 KB | 2.3 MB | ✅ 100% (30/30) | 1.1x | 1.2x |
| mkdir | 442.5 KB | 74.5 KB | - | ✅ 100% (17/17) | 1.0x | - |
| mkfifo | 432.3 KB | 42.5 KB | - | ✅ 100% (11/11) | 1.0x | - |
| mknod | 434.4 KB | 42.5 KB | - | ✅ 100% (10/10) | 1.0x | - |
| mktemp | 443.9 KB | 34.5 KB | - | ✅ 100% (15/15) | - | - |
| mv | 474.8 KB | 134.5 KB | - | SKIP | 1.0x | - |
| nice | 457.5 KB | 34.5 KB | - | ✅ 100% (12/12) | 0.9x | - |
| nl | 1.8 MB | 38.6 KB | 2.7 MB | ✅ 100% (47/47) | **5.0x** | **1.6x** |
| nohup | 455.6 KB | 34.4 KB | - | ✅ 100% (6/6) | 0.9x | - |
| nproc | 444.0 KB | 34.5 KB | - | ✅ 100% (8/8) | 0.8x | - |
| numfmt | 517.0 KB | 58.5 KB | - | ✅ 100% (31/31) | - | - |
| od | 523.2 KB | 70.5 KB | - | ✅ 100% (41/41) | - | - |
| paste | 450.4 KB | 38.4 KB | 1.2 MB | ✅ 100% (30/30) | **2.6x** | **20.8x** |
| pathchk | 438.7 KB | 34.5 KB | - | ✅ 100% (17/17) | 0.8x | - |
| pinky | 768.6 KB | 38.4 KB | - | ✅ 100% (9/9) | - | - |
| pr | 502.2 KB | 70.6 KB | - | ✅ 100% (19/19) | - | - |
| printenv | 428.4 KB | 34.4 KB | - | SKIP | - | - |
| printf | 493.3 KB | 54.4 KB | - | ✅ 100% (59/59) | - | - |
| ptx | 525.9 KB | 54.5 KB | - | ✅ 100% (10/10) | - | - |
| pwd | 429.2 KB | 34.5 KB | - | ✅ 100% (8/8) | - | - |
| readlink | 439.2 KB | 42.4 KB | - | ✅ 100% (19/19) | 0.8x | - |
| realpath | 443.5 KB | 42.4 KB | - | ✅ 100% (24/24) | 0.8x | - |
| rev | 439.3 KB | 14.4 KB | - | ✅ 100% (32/32) | **23.0x** | - |
| rm | 522.7 KB | 58.5 KB | - | ✅ 100% (12/12) | 0.9x | - |
| rmdir | 431.0 KB | 46.4 KB | - | ✅ 100% (12/12) | 0.9x | - |
| runcon | 463.9 KB | 34.5 KB | - | SKIP | - | - |
| seq | 485.9 KB | 50.5 KB | - | ✅ 100% (53/53) | **16.0x** | - |
| sha1sum | 642.1 KB | 38.4 KB | - | ✅ 100% (15/15) | 1.0x | - |
| sha224sum | 642.7 KB | 38.4 KB | - | ✅ 100% (10/10) | 1.0x | - |
| sha256sum | 643.2 KB | 38.4 KB | 2.3 MB | ✅ 100% (34/34) | 1.0x | 1.0x |
| sha384sum | 643.6 KB | 38.4 KB | - | ✅ 100% (10/10) | 0.8x | - |
| sha512sum | 642.9 KB | 38.4 KB | - | ✅ 100% (10/10) | 0.7x | - |
| shred | 456.5 KB | 54.5 KB | - | ✅ 100% (10/10) | **2.4x** | - |
| shuf | 470.0 KB | 46.5 KB | - | ✅ 100% (27/27) | - | - |
| sleep | 444.4 KB | 34.5 KB | - | ✅ 100% (10/10) | 0.9x | - |
| sort | 981.1 KB | 102.8 KB | 3.2 MB | ✅ 100% (51/51) | **12.3x** | **12.2x** |
| split | 523.7 KB | 54.9 KB | - | ✅ 100% (22/22) | 1.0x | - |
| stat | 465.5 KB | 86.5 KB | - | ⚠️ 97% (28/29) | - | - |
| stdbuf | 484.4 KB | 50.5 KB | - | ✅ 100% (6/6) | - | - |
| stty | 454.7 KB | 78.5 KB | - | ✅ 100% (4/4) | - | - |
| sum | 439.7 KB | 34.4 KB | - | ✅ 100% (23/23) | 1.4x | - |
| sync | 430.2 KB | 34.4 KB | - | ✅ 100% (5/5) | 0.9x | - |
| tac | 1.9 MB | 38.4 KB | 2.7 MB | ✅ 100% (30/30) | **3.2x** | **1.7x** |
| tail | 481.5 KB | 62.5 KB | 1.7 MB | ✅ 100% (44/44) | **1.5x** | **2.1x** |
| tee | 443.4 KB | 38.5 KB | - | ✅ 100% (15/15) | - | - |
| test | 440.5 KB | 46.4 KB | - | ✅ 100% (51/51) | - | - |
| timeout | 485.9 KB | 38.9 KB | - | ✅ 100% (21/21) | - | - |
| touch | 457.8 KB | 94.5 KB | - | ✅ 100% (21/21) | 1.0x | - |
| tr | 696.2 KB | 46.5 KB | 1.3 MB | ✅ 100% (46/46) | **6.6x** | **6.6x** |
| true | 296.6 KB | 26.3 KB | - | ✅ 100% (8/8) | - | - |
| truncate | 441.2 KB | 38.5 KB | - | ✅ 100% (25/25) | 0.9x | - |
| tsort | 464.7 KB | 46.5 KB | - | ✅ 100% (19/19) | - | - |
| tty | 425.8 KB | 34.5 KB | - | ✅ 100% (6/6) | 0.8x | - |
| uname | 428.6 KB | 34.5 KB | - | ✅ 100% (14/14) | 0.9x | - |
| unexpand | 449.5 KB | 38.5 KB | 1.3 MB | ✅ 100% (26/26) | **4.5x** | **12.9x** |
| uniq | 907.0 KB | 38.5 KB | 1.3 MB | ✅ 100% (46/46) | **11.4x** | **6.0x** |
| unlink | 429.4 KB | 34.5 KB | - | ✅ 100% (7/7) | 0.9x | - |
| uptime | 497.8 KB | 14.4 KB | - | ✅ 100% (5/5) | - | - |
| users | 461.2 KB | 34.5 KB | - | ✅ 100% (8/8) | - | - |
| vdir | 585.5 KB | 139.0 KB | - | SKIP | - | - |
| wc | 907.9 KB | 54.5 KB | 1.4 MB | ✅ 100% (73/73) | **26.1x** | **14.2x** |
| who | 782.6 KB | 58.5 KB | - | ✅ 100% (15/15) | - | - |
| whoami | 425.0 KB | 34.5 KB | - | ✅ 100% (4/4) | 0.8x | - |
| yes | 1,853 B | 34.4 KB | - | ✅ 100% (23/23) | **4.1x** | - |

### Remaining Failures (9)

| Tool | Failed | Cause |
|------|--------|-------|
| df | 8/17 | Filesystem-dependent sizes (race condition) |
| stat | 1/29 | `-f` filesystem block counts change between runs |

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
