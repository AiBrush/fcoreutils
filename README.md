# fcoreutils

[![Test](https://github.com/AiBrush/fcoreutils/actions/workflows/test.yml/badge.svg)](https://github.com/AiBrush/fcoreutils/actions/workflows/test.yml)
[![Release](https://github.com/AiBrush/fcoreutils/actions/workflows/release.yml/badge.svg)](https://github.com/AiBrush/fcoreutils/actions/workflows/release.yml)
[![crates.io](https://img.shields.io/crates/v/fcoreutils?color=orange)](https://crates.io/crates/fcoreutils)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![GitHub Release](https://img.shields.io/github/v/release/AiBrush/fcoreutils)](https://github.com/AiBrush/fcoreutils/releases)

High-performance GNU coreutils replacement in Rust — 100+ tools, SIMD-accelerated, drop-in compatible, cross-platform.

## Independent Test Results (v0.18.9)

*Source: [AiBrush/coreutils-rs-independent-test](https://github.com/AiBrush/coreutils-rs-independent-test) — Linux x86_64, GitHub Actions, hyperfine*

**Summary:** 107 tools tracked · 101 benchmarked · **fastest: unexpand at 36.5x** vs GNU · compat: **3799/3911 (97.1%)** across 107 tools

> Compat is GNU test pass rate on Linux x86_64. Speedup is peak across all benchmark scenarios. `-` = no data collected. `N/A` = not applicable.

| Tool | Compat | Speedup f\* vs GNU |
|------|-------:|-------------------:|
| arch | ✅ 17/17 | 0.9x |
| b2sum | ✅ 25/25 | **1.2x** |
| base32 | ✅ 29/29 | **1.7x** |
| base64 | ✅ 33/33 | **6.8x** |
| basename | ✅ 26/26 | 0.9x |
| basenc | ⚠️ 99% (95/96) | **2.5x** |
| cat | ✅ 49/49 | **1.9x** |
| chcon | ⚠️ 62% (15/24) | N/A |
| chgrp | ⚠️ 89% (17/19) | **1.0x** |
| chmod | ⚠️ 99% (78/79) | - |
| chown | ⚠️ 85% (17/20) | 0.9x |
| chroot | ⚠️ 47% (18/38) | N/A |
| cksum | ✅ 48/48 | **1.3x** |
| comm | ✅ 30/30 | **3.7x** |
| cp | ✅ 69/69 | **1.2x** |
| csplit | ✅ 2/2 | - |
| cut | ⚠️ 97% (96/99) | **6.6x** |
| date | ✅ 46/46 | **1.0x** |
| dd | ✅ 29/29 | **1.0x** |
| df | ✅ 25/25 | **1.2x** |
| dir | ✅ 45/45 | **1.1x** |
| dircolors | ✅ 14/14 | 0.8x |
| dirname | ✅ 23/23 | **1.0x** |
| du | ✅ 51/51 | **1.0x** |
| echo | ✅ 53/53 | 0.9x |
| env | ⚠️ 96% (49/51) | 0.9x |
| expand | ✅ 35/35 | **10.9x** |
| expr | ✅ 43/43 | 0.9x |
| factor | ⚠️ 93% (55/59) | **1.4x** |
| false | ✅ 6/6 | 0.8x |
| fmt | ✅ 22/22 | **1.3x** |
| fold | ⚠️ 93% (54/58) | **8.9x** |
| groups | ✅ 28/28 | 0.9x |
| head | ⚠️ 95% (60/63) | **2.0x** |
| hostid | ✅ 6/6 | 0.9x |
| id | ✅ 27/27 | **1.1x** |
| install | ⚠️ 84% (27/32) | **1.1x** |
| join | ✅ 37/37 | **1.2x** |
| kill | ✅ 20/20 | 0.9x |
| link | ✅ 32/32 | 0.9x |
| ln | ✅ 33/33 | **1.0x** |
| logname | ✅ 13/13 | 0.9x |
| ls | ✅ 65/65 | **1.1x** |
| md5sum | ✅ 30/30 | **1.2x** |
| mkdir | ⚠️ 84% (37/44) | **1.2x** |
| mkfifo | ✅ 11/11 | **1.0x** |
| mknod | ✅ 12/12 | **1.1x** |
| mktemp | ⚠️ 88% (15/17) | **1.0x** |
| mv | ✅ 3/3 | **1.0x** |
| nice | ⚠️ 94% (32/34) | 0.9x |
| nl | ⚠️ 97% (60/62) | **10.5x** |
| nohup | ✅ 11/11 | **1.0x** |
| nproc | ⚠️ 94% (29/31) | 0.9x |
| numfmt | ⚠️ 94% (31/33) | **1.6x** |
| od | ✅ 50/50 | **10.5x** |
| paste | ⚠️ 94% (30/32) | **3.8x** |
| pathchk | ✅ 22/22 | 0.9x |
| pinky | ✅ 32/32 | 0.9x |
| pr | ⚠️ 95% (18/19) | **7.7x** |
| printenv | ✅ 9/9 | 0.9x |
| printf | ✅ 74/74 | 0.8x |
| ptx | ✅ 15/15 | **2.0x** |
| pwd | ⚠️ 94% (16/17) | **1.0x** |
| readlink | ✅ 60/60 | 0.9x |
| realpath | ✅ 43/43 | 0.9x |
| rev | ✅ 32/32 | **22.6x** |
| rm | ✅ 23/23 | **1.0x** |
| rmdir | ✅ 21/21 | 0.9x |
| runcon | ⚠️ 40% (2/5) | N/A |
| seq | ✅ 62/62 | **15.4x** |
| sha1sum | ✅ 43/43 | **1.1x** |
| sha224sum | ✅ 39/39 | **1.1x** |
| sha256sum | ✅ 34/34 | **1.3x** |
| sha384sum | ✅ 39/39 | 0.9x |
| sha512sum | ✅ 39/39 | **1.0x** |
| shred | ✅ 27/27 | **2.3x** |
| shuf | ⚠️ 98% (52/53) | **5.1x** |
| sleep | ✅ 15/15 | **1.0x** |
| sort | ✅ 111/111 | **13.0x** |
| split | ✅ 72/72 | **1.4x** |
| stat | ✅ 38/38 | **1.1x** |
| stdbuf | ✅ 13/13 | 0.9x |
| stty | ⚠️ 60% (25/42) | N/A |
| sum | ✅ 23/23 | **1.2x** |
| sync | ⚠️ 90% (9/10) | 0.9x |
| tac | ✅ 59/59 | **2.6x** |
| tail | ✅ 80/80 | **1.2x** |
| tee | ✅ 27/27 | **1.2x** |
| test | ✅ 116/116 | 0.9x |
| timeout | ✅ 36/36 | **1.0x** |
| touch | ⚠️ 94% (45/48) | **1.0x** |
| tr | ✅ 59/59 | **7.4x** |
| true | ✅ 7/7 | 0.8x |
| truncate | ⚠️ 94% (46/49) | 0.9x |
| tsort | ✅ 19/19 | **10.1x** |
| tty | ✅ 10/10 | 0.9x |
| uname | ✅ 14/14 | 0.9x |
| unexpand | ⚠️ 96% (26/27) | **36.5x** |
| uniq | ⚠️ 99% (85/86) | **12.3x** |
| unlink | ✅ 30/30 | 0.9x |
| uptime | ✅ 16/16 | **1.6x** |
| users | ✅ 6/6 | **1.6x** |
| vdir | ✅ 41/41 | **1.1x** |
| wc | ✅ 77/77 | **19.1x** |
| who | ⚠️ 97% (37/38) | **1.0x** |
| whoami | ✅ 16/16 | 0.9x |
| yes | ⚠️ 90% (26/29) | **1.1x** |

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
