# fcoreutils

[![Test](https://github.com/AiBrush/coreutils-rs/actions/workflows/test.yml/badge.svg)](https://github.com/AiBrush/coreutils-rs/actions/workflows/test.yml)
[![Release](https://github.com/AiBrush/coreutils-rs/actions/workflows/release.yml/badge.svg)](https://github.com/AiBrush/coreutils-rs/actions/workflows/release.yml)
[![crates.io](https://img.shields.io/crates/v/fcoreutils?color=orange)](https://crates.io/crates/fcoreutils)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![GitHub Release](https://img.shields.io/github/v/release/AiBrush/coreutils-rs)](https://github.com/AiBrush/coreutils-rs/releases)

High-performance GNU coreutils replacement in Rust — 100+ tools, SIMD-accelerated, drop-in compatible, cross-platform.

## Independent Benchmarks (v0.9.2)

*Source: [AiBrush/coreutils-rs-independent-test](https://github.com/AiBrush/coreutils-rs-independent-test) — Linux x86_64, source-built, 100MB file, hyperfine*

### Performance (fcoreutils vs GNU coreutils)

| Tool | Mode | Speedup vs GNU |
|------|------|---------------:|
| wc | line count (`-l`) | **31.7x** |
| wc | word count (`-w`) | **15.1x** |
| wc | byte count (`-c`) | **17.4x** |
| wc | combined (default) | **13.0x** |
| sort | unique (`-u`) | **11.9x** |
| uniq | dedup | **10.8x** |
| uniq | various modes | 6.3–6.5x |
| tr | delete (`-d`) | **6.4x** |
| sort | typical | 5.0–5.8x |
| cut | fields/bytes | **5.4x** |
| base64 | encode (piped) | **5.4x** |
| tr | typical | 2.3–3.9x |
| tac | reverse | **3.2x** |
| b2sum | hash | 1.1–1.3x |
| sha256sum | hash | 0.5–1.0x |
| md5sum | hash | 0.5–0.9x |

### Compatibility (GNU test suite)

| Tool | Tests Passing | Status |
|------|:------------:|:------:|
| b2sum | 25/25 | ✅ |
| cut | 49/49 | ✅ |
| md5sum | 30/30 | ✅ |
| sha256sum | 34/34 | ✅ |
| tac | 30/30 | ✅ |
| tr | 46/46 | ✅ |
| uniq | 46/46 | ✅ |
| sort | 50/51 | ⚠️ |
| wc | 71/73 | ⚠️ |
| base64 | 32/33 | ⚠️ |
| yes | 4/23 | ⚠️ |

## All Tools

### Text Processing

| Tool | Binary | Description | Tests |
|------|--------|-------------|:-----:|
| wc | `fwc` | Word, line, char, byte count (SIMD SSE2, single-pass, parallel) | 71/73 ⚠️ |
| cut | `fcut` | Field/byte/char extraction (mmap, SIMD) | 49/49 ✅ |
| sort | `fsort` | Line sorting (parallel merge sort) | 50/51 ⚠️ |
| tr | `ftr` | Character translation (SIMD pshufb, AVX2/SSE2, parallel) | 46/46 ✅ |
| uniq | `funiq` | Filter duplicate lines (mmap, zero-copy, single-pass) | 46/46 ✅ |
| tac | `ftac` | Reverse file lines (parallel memchr, zero-copy writev, vmsplice) | 30/30 ✅ |
| head | `fhead` | Output first lines (zero-copy mmap, SIMD newline scan) | 47/47 ✅ |
| tail | `ftail` | Output last lines (reverse SIMD scan, follow mode) | 44/44 ✅ |
| cat | `fcat` | Concatenate files (zero-copy splice/sendfile, mmap) | 44/44 ✅ |
| rev | `frev` | Reverse lines character-by-character (mmap, SIMD) | 32/32 ✅ |
| expand | `fexpand` | Convert tabs to spaces (mmap, configurable tab stops) | 33/33 ✅ |
| unexpand | `funexpand` | Convert spaces to tabs (mmap, configurable tab stops) | 26/26 ✅ |
| fold | `ffold` | Wrap lines to specified width (mmap, byte/char modes) | 35/35 ✅ |
| paste | `fpaste` | Merge lines of files (mmap, serial/parallel modes) | 30/30 ✅ |
| nl | `fnl` | Number lines (mmap, section delimiters, regex) | 47/47 ✅ |
| comm | `fcomm` | Compare sorted files line by line (mmap, SIMD) | 30/30 ✅ |
| join | `fjoin` | Join lines on a common field (mmap) | 35/35 ✅ |

### Encoding/Decoding

| Tool | Binary | Description | Tests |
|------|--------|-------------|:-----:|
| base64 | `fbase64` | Base64 encode/decode (SIMD, parallel, fused strip+decode) | 32/33 ⚠️ |
| base32 | `fbase32` | RFC 4648 base32 encoding/decoding | 29/29 ✅ |
| basenc | `fbasenc` | Multi-format encoder/decoder (base64, base32, base16, base2, z85) | 40/40 ✅ |

### Checksums

| Tool | Binary | Description | Tests |
|------|--------|-------------|:-----:|
| sha256sum | `fsha256sum` | SHA-256 checksums (mmap, madvise, readahead, parallel) | 34/34 ✅ |
| md5sum | `fmd5sum` | MD5 checksums (mmap, batch I/O, parallel hash, batched output) | 30/30 ✅ |
| b2sum | `fb2sum` | BLAKE2b checksums (mmap, madvise, readahead) | 25/25 ✅ |
| sha1sum | `fsha1sum` | SHA-1 checksums | 15/15 ✅ |
| sha224sum | `fsha224sum` | SHA-224 checksums | 10/10 ✅ |
| sha384sum | `fsha384sum` | SHA-384 checksums | 10/10 ✅ |
| sha512sum | `fsha512sum` | SHA-512 checksums | 10/10 ✅ |
| sum | `fsum` | BSD/SysV checksums | 23/23 ✅ |
| cksum | `fcksum` | CRC-32 checksums | 21/21 ✅ |

### File Operations

| Tool | Binary | Description | Tests |
|------|--------|-------------|:-----:|
| cp | `fcp` | Copy files and directories | 18/18 ✅ |
| rm | `frm` | Remove files or directories | 12/12 ✅ |
| dd | `fdd` | Convert and copy files with block-level operations | 17/17 ✅ |
| split | `fsplit` | Split files into pieces | 20/20 ✅ |
| install | `finstall` | Copy files and set attributes | 11/11 ✅ |
| shred | `fshred` | Overwrite files to hide contents | 10/10 ✅ |
| ln | `fln` | Create hard and symbolic links | 16/16 ✅ |
| link | `flink` | Create hard link (low-level) | 8/8 ✅ |
| unlink | `funlink` | Remove file (low-level) | 7/7 ✅ |
| touch | `ftouch` | Change file timestamps | 21/21 ✅ |
| truncate | `ftruncate` | Shrink or extend file sizes | 25/25 ✅ |
| mkdir | `fmkdir` | Create directories (symbolic mode support) | 17/17 ✅ |
| rmdir | `frmdir` | Remove empty directories | 10/12 ⚠️ |
| mkfifo | `fmkfifo` | Create named pipes (FIFOs) | 11/11 ✅ |
| mknod | `fmknod` | Create special files | 10/10 ✅ |
| mktemp | `fmktemp` | Create temporary files/directories | 15/15 ✅ |

### Permissions

| Tool | Binary | Description | Tests |
|------|--------|-------------|:-----:|
| chmod | `fchmod` | Change file mode/permission bits | 33/33 ✅ |
| chown | `fchown` | Change file owner and group | 11/11 ✅ |
| chgrp | `fchgrp` | Change group ownership of files | 11/11 ✅ |

### Text/Data Generation

| Tool | Binary | Description | Tests |
|------|--------|-------------|:-----:|
| seq | `fseq` | Generate number sequences | 53/53 ✅ |
| shuf | `fshuf` | Random permutations of input | 27/27 ✅ |
| tsort | `ftsort` | Topological sorting | 19/19 ✅ |
| echo | `fecho` | Display a line of text | 38/38 ✅ |
| expr | `fexpr` | Evaluate expressions | 43/43 ✅ |
| factor | `ffactor` | Print prime factors of numbers | 26/26 ✅ |
| test | `ftest` | Check file types and compare values | 51/51 ✅ |
| numfmt | `fnumfmt` | Convert numbers to/from human-readable format | 27/27 ✅ |

### Path Utilities

| Tool | Binary | Description | Tests |
|------|--------|-------------|:-----:|
| basename | `fbasename` | Strip directory and suffix from paths | 26/26 ✅ |
| dirname | `fdirname` | Strip last path component | 23/23 ✅ |
| readlink | `freadlink` | Print symlink targets | 19/19 ✅ |
| realpath | `frealpath` | Resolve absolute paths | 24/24 ✅ |
| pathchk | `fpathchk` | Validate path names | 17/17 ✅ |
| pwd | `fpwd` | Print working directory | 8/8 ✅ |

### System Information

| Tool | Binary | Description | Tests |
|------|--------|-------------|:-----:|
| id | `fid` | Print user and group IDs | 16/16 ✅ |
| groups | `fgroups` | Print group memberships | 4/4 ✅ |
| whoami | `fwhoami` | Print effective user name | 4/4 ✅ |
| logname | `flogname` | Print login name | 3/3 ✅ |
| uname | `funame` | Print system information | 14/14 ✅ |
| uptime | `fuptime` | System uptime and load averages | 5/5 ✅ |
| arch | `farch` | Print machine architecture | 5/5 ✅ |
| hostid | `fhostid` | Print host identifier | 6/6 ✅ |
| tty | `ftty` | Print terminal name | 6/6 ✅ |
| nproc | `fnproc` | Print number of processors | 8/8 ✅ |
| users | `fusers` | Print logged-in user names | 8/8 ✅ |
| ls | `fls` | List directory contents | 39/39 ✅ |

### Process/Environment

| Tool | Binary | Description | Tests |
|------|--------|-------------|:-----:|
| printenv | `fprintenv` | Print environment variables | 5/5 ✅ |
| env | `fenv` | Run program with modified environment | 17/17 ✅ |
| timeout | `ftimeout` | Run command with time limit | 19/21 ⚠️ |
| nice | `fnice` | Run with modified scheduling priority | 12/12 ✅ |
| nohup | `fnohup` | Run immune to hangups | 6/6 ✅ |
| sleep | `fsleep` | Delay for specified time | 10/10 ✅ |
| sync | `fsync` | Flush filesystem caches | 5/6 ✅ |
| chroot | `fchroot` | Change root directory (requires root) | 11/11 ✅ |
| tee | `ftee` | Read stdin, write to stdout and files | 15/15 ✅ |
| yes | `fyes` | Output a string repeatedly | 4/23 ⚠️ |
| stdbuf | `fstdbuf` | Run command with modified I/O stream buffering | 6/6 ✅ |

### Shell Utilities

| Tool | Binary | Description | Tests |
|------|--------|-------------|:-----:|
| true | `ftrue` | Exit with status 0 | 8/8 ✅ |
| false | `ffalse` | Exit with status 1 | 7/7 ✅ |
| dircolors | `fdircolors` | Setup LS_COLORS environment variable | 12/14 ⚠️ |

### Tools with Known Issues

| Tool | Binary | Description | Tests | Issue Area |
|------|--------|-------------|:-----:|------------|
| stat | `fstat` | Display file or filesystem status | 23/29 ⚠️ | Format strings, terse output |
| date | `fdate` | Display or set the system date and time | 28/28 ✅ | — |
| who | `fwho` | Show who is logged on | 11/15 ⚠️ | Boot time, runlevel |
| pinky | `fpinky` | Lightweight finger information | 3/9 ⚠️ | Long/short format output |
| df | `fdf` | Report filesystem disk space usage | 4/17 ⚠️ | Output formatting, type filtering |
| du | `fdu` | Estimate file space usage | 16/21 ⚠️ | Apparent size, byte blocks |
| od | `fod` | Octal dump of file contents | 34/35 ⚠️ | Float format |
| pr | `fpr` | Paginate or columnate files for printing | 12/19 ⚠️ | Multi-column, merge mode |
| printf | `fprintf` | Format and print data | 49/53 ⚠️ | Quoting, negative integers |
| fmt | `ffmt` | Simple text formatter (reflow paragraphs) | 17/18 ⚠️ | Wide line wrapping |
| ptx | `fptx` | Produce permuted index of file contents | 2/10 ⚠️ | Core output format |
| stty | `fstty` | Change and print terminal line settings | 4/7 ✅ | 3 skipped |

### Not Yet Tested

| Tool | Binary | Description |
|------|--------|-------------|
| mv | `fmv` | Move or rename files and directories |
| dir | `fdir` | List directory contents (like ls) |
| vdir | `fvdir` | List directory contents verbosely (like ls -l) |
| csplit | `fcsplit` | Split files based on context/patterns |
| runcon | `fruncon` | Run command with specified SELinux security context |
| chcon | `fchcon` | Change SELinux security context of files |

## Installation

```bash
cargo install fcoreutils
```

Or build from source:

```bash
git clone https://github.com/AiBrush/coreutils-rs.git
cd coreutils-rs
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

Our assembly `yes` achieves **~2.6 GB/s** (1.89x faster than GNU yes, 1.25x faster than our Rust implementation) while compiling to under 1,300 bytes with no runtime dependencies.

| Binary         | Size          | Throughput  | Memory (RSS) | Startup  |
|----------------|---------------|-------------|--------------|----------|
| fyes (asm)     | 1,701 bytes   | 2,060 MB/s  | 28 KB        | 0.24 ms  |
| GNU yes (C)    | 43,432 bytes  | 2,189 MB/s  | 1,956 KB     | 0.75 ms  |
| fyes (Rust)    | ~435 KB       | ~2,190 MB/s | ~2,000 KB    | ~0.75 ms |

Benchmarked on Linux x86_64. At pipe-limited throughput all three write at ~2.1 GB/s.
The assembly wins on binary size (25x smaller), memory (70x less RSS), and startup latency (3x faster).

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
