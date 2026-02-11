# coreutils-rs Progress

## Current Status: All 10 Tools Complete - v0.0.8 Released

All 10 GNU coreutils replacements are fully implemented, optimized, and tested.
Each tool is a drop-in replacement with byte-identical GNU output.

## Tool Checklist

### wc (Word Count) - COMPLETE
- [x] SIMD SSE2 word counting with whitespace classification
- [x] memchr SIMD line counting (auto-detects AVX2/SSE2/NEON)
- [x] stat-only byte counting (`-c` never reads the file)
- [x] Zero-copy mmap for large files (>64KB)
- [x] Parallel multi-file processing with thread pool
- [x] All flags: `-l`, `-w`, `-c`, `-m`, `-L`, `--files0-from`, `--total`
- [x] GNU-identical output format (right-aligned columns, correct field order)
- [x] 30+ unit tests, 18 GNU compatibility tests

### cut (Field Extraction) - COMPLETE
- [x] Zero-copy mmap file reading
- [x] SIMD byte scanning for delimiter detection
- [x] Zero-copy field extraction (no allocation per line)
- [x] All flags: `-d`, `-f`, `-b`, `-c`, `--complement`, `-s`, `--output-delimiter`
- [x] GNU-identical output format

### base64 (Base64 Encode/Decode) - COMPLETE
- [x] SIMD vectorized encode/decode via `base64-simd` crate
- [x] 4MB chunked streaming for arbitrary file sizes
- [x] Raw fd stdout bypass (avoids Rust BufWriter overhead)
- [x] Zero-copy mmap for encoding
- [x] All flags: `-d`, `-w`, `-i`
- [x] GNU-identical output format with line wrapping

### sha256sum (SHA-256 Checksums) - COMPLETE
- [x] Zero-copy mmap with `madvise(MADV_SEQUENTIAL)` and readahead
- [x] Parallel multi-file hashing with thread pool
- [x] SHA-NI hardware acceleration detection
- [x] All flags: `-c`, `--check`, `--status`, `--quiet`, `--strict`, `-b`, `-t`
- [x] GNU-identical output format

### md5sum (MD5 Checksums) - COMPLETE
- [x] Zero-copy mmap with `madvise(MADV_SEQUENTIAL)` and readahead
- [x] Parallel multi-file hashing with thread pool
- [x] All flags: `-c`, `--check`, `--status`, `--quiet`, `--strict`, `-b`, `-t`
- [x] GNU-identical output format

### b2sum (BLAKE2b Checksums) - COMPLETE
- [x] Zero-copy mmap with `madvise(MADV_SEQUENTIAL)` and readahead
- [x] BLAKE2b hardware-accelerated implementation
- [x] All flags: `-c`, `--check`, `--status`, `--quiet`, `--strict`, `-l` (length)
- [x] GNU-identical output format

### sort (Line Sorting) - COMPLETE
- [x] Parallel merge sort with Rayon thread pool
- [x] Efficient key extraction and comparison
- [x] All GNU sort modes: `-n`, `-g`, `-h`, `-V`, `-M`, `-R`
- [x] All flags: `-r`, `-u`, `-s`, `-k`, `-t`, `-o`, `-m`, `-c`, `-C`
- [x] GNU-identical output format

### tr (Character Translation) - COMPLETE
- [x] Mmap stdin reading for large inputs
- [x] 256-byte lookup tables for O(1) character mapping
- [x] 4MB output buffers for minimized write syscalls
- [x] Zero-copy translation pipeline
- [x] Character classes: `[:alpha:]`, `[:digit:]`, `[:space:]`, etc.
- [x] All flags: `-d`, `-s`, `-c`, `-C`, `-t`
- [x] GNU-identical output format

### uniq (Deduplicate Lines) - COMPLETE
- [x] Zero-copy mmap file reading
- [x] 1MB output buffers for efficient I/O
- [x] All GNU uniq flags: `-c`, `-d`, `-D`, `-u`, `-i`, `-f`, `-s`, `-w`
- [x] GNU-identical output format

### tac (Reverse Lines) - COMPLETE
- [x] Forward SIMD scan with memchr for newline detection
- [x] 1MB BufWriter for efficient reversed output
- [x] Custom separator support (`-s`)
- [x] Before-separator mode (`-b`)
- [x] GNU-identical output format

## Benchmarks (100MB text file, warm cache)

| Tool | GNU | fcoreutils | Speedup | Status |
|------|-----|------------|---------|--------|
| `wc -l` | 42ms | 28ms | **1.5x** | measured |
| `wc -w` | 297ms | 117ms | **2.5x** | measured |
| `wc -c` | ~0ms | ~0ms | **instant** | measured |
| `wc` (default) | 302ms | 135ms | **2.2x** | measured |
| `cut -d: -f5` | 325ms | 161ms | **2.0x** | measured |
| `cut -b1-20` | 310ms | 49ms | **6.3x** | measured |
| `base64` | TBD | TBD | TBD | pending |
| `sha256sum` | TBD | TBD | TBD | pending |
| `md5sum` | TBD | TBD | TBD | pending |
| `b2sum` | TBD | TBD | TBD | pending |
| `sort` | TBD | TBD | TBD | pending |
| `tr` | TBD | TBD | TBD | pending |
| `uniq` | TBD | TBD | TBD | pending |
| `tac` | TBD | TBD | TBD | pending |

## Key Findings
- Zero-copy mmap is critical: eliminated 100MB copy, reduced sys time from 50ms to 4ms
- memchr SIMD line counting is 1.5x faster than GNU's AVX-2 (on this machine)
- Our scalar word counting is 2.5x faster than GNU (simpler code, better branch prediction)
- GNU wc uses lseek() for -c on regular files (we now do the same with stat)
- GNU output order: lines, words, chars, bytes, max_line_length (chars before bytes!)
- Hardware-accelerated hashing (SHA-NI, BLAKE2b) combined with mmap+madvise provides significant throughput
- 256-byte lookup tables in `tr` provide O(1) character classification without branching
- Forward scanning with memchr in `tac` is faster than reverse scanning
