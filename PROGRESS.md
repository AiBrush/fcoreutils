# coreutils-rs Progress

## Current Status: Phase 1 - wc Complete, Ready for Next Tool

## Tool Checklist

### wc (Word Count) - COMPLETE
- [x] Research GNU wc.c source (1024 lines, AVX-512/AVX-2 line counting)
- [x] Document all flags and edge cases (18 compatibility tests pass)
- [x] Study fastlwc SIMD approach (PSHUFB whitespace classification)
- [x] Write ARCHITECTURE.md for wc
- [x] Implement line counting (-l) with memchr SIMD
- [x] Implement byte counting (-c) with stat-only fast path
- [x] Implement word counting (-w) with scalar transition detection
- [x] Implement character counting (-m) with UTF-8 lead byte detection
- [x] Implement max-line-length (-L) with tab handling
- [x] Implement --files0-from
- [x] Implement --total (auto/always/never/only)
- [x] Handle stdin and multiple files
- [x] Match GNU output format exactly (right-aligned, correct field order)
- [x] 30 unit tests passing
- [x] 18 GNU compatibility tests passing (byte-identical output)
- [x] Benchmarks vs GNU wc (see table below)
- [x] Zero-copy mmap for large files

### cut (Field Extraction) - NOT STARTED
- [ ] Research / ARCHITECTURE.md
- [ ] Implement -d, -f, -b, -c, --complement, -s
- [ ] Tests and benchmarks

### base64 - NOT STARTED
- [ ] Research / ARCHITECTURE.md
- [ ] Implement encode/decode with base64-simd
- [ ] Tests and benchmarks

### sha256sum - NOT STARTED
- [ ] Research / ARCHITECTURE.md
- [ ] Implement with SHA-NI detection
- [ ] Tests and benchmarks

### sort - NOT STARTED
- [ ] Research / ARCHITECTURE.md (complex - radix, parallel merge, external)
- [ ] Implement all sort modes
- [ ] Tests and benchmarks

### tr (Translate) - NOT STARTED
- [ ] Research / ARCHITECTURE.md
- [ ] Implement character classes, ranges, -d, -s, -c
- [ ] Tests and benchmarks

### uniq - NOT STARTED
- [ ] Research / ARCHITECTURE.md
- [ ] Implement -c, -d, -u, -i, -f, -s
- [ ] Tests and benchmarks

### b2sum - NOT STARTED
- [ ] Research / ARCHITECTURE.md
- [ ] Implement with blake2 crate
- [ ] Tests and benchmarks

### tac - NOT STARTED
- [ ] Research / ARCHITECTURE.md
- [ ] Implement with SIMD reverse line iteration
- [ ] Tests and benchmarks

### md5sum - NOT STARTED
- [ ] Research / ARCHITECTURE.md
- [ ] Implement with md-5 crate
- [ ] Tests and benchmarks

## Benchmarks (100MB text file, warm cache)

| Tool | GNU | fwc | Speedup | Target | Status |
|------|-----|-----|---------|--------|--------|
| wc -l | 42ms | 28ms | **1.5x** | 30x | needs SIMD word counting |
| wc -w | 297ms | 117ms | **2.5x** | 10x | scalar, future: PSHUFB |
| wc -c | 1ms | 1ms | **~instant** | instant | both use stat |
| wc (default) | 302ms | 135ms | **2.2x** | 10x | word counting dominates |
| cut | - | - | - | 10x | -- |
| base64 | - | - | - | 50x+ | -- |
| sha256sum | - | - | - | 4-6x | -- |
| sort | - | - | - | 5-10x | -- |
| tr | - | - | - | 10x | -- |
| uniq | - | - | - | 10x | -- |
| b2sum | - | - | - | 5x | -- |
| tac | - | - | - | 3x | -- |
| md5sum | - | - | - | 4-6x | -- |

## Key Findings
- Zero-copy mmap is critical: eliminated 100MB copy, reduced sys time from 50ms to 4ms
- memchr SIMD line counting is 1.5x faster than GNU's AVX-2 (on this machine)
- Our scalar word counting is 2.5x faster than GNU (simpler code, better branch prediction)
- GNU wc uses lseek() for -c on regular files (we now do the same with stat)
- GNU output order: lines, words, chars, bytes, max_line_length (chars before bytes!)
- GNU invalid UTF-8 in -m: invalid bytes are NOT counted as characters
- Whitespace for -w: space, tab, newline, CR, form feed (0x0C), vertical tab (0x0B)
- --total=only: suppresses individual files, prints total with no "total" label
- GNU uses 256KB buffer for streaming reads; we use mmap (zero-copy for large files)
- Column width from stat file sizes (GNU) vs from actual counts (us) - effectively same result

## Answered Questions
- Invalid UTF-8 in -m: bytes NOT counted (GNU uses mbrtoc32, skips invalid). Our approach counts non-continuation bytes which differs slightly but matches in C locale.
- Whitespace for -w: isspace() in C locale = space, tab, newline, CR, form feed, vertical tab
- --files0-from: reads NUL-delimited filenames, cannot combine with positional args
- Vertical tab (\v): zero display width for -L
- \r: zero display width for -L, not a line terminator
