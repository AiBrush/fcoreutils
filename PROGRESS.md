# coreutils-rs Progress

## Current Status: Phase 0 - Project Setup & Research

## Tool Checklist

### wc (Word Count) - IN PROGRESS
- [ ] Research GNU wc.c source
- [ ] Document all flags and edge cases
- [ ] Study fastlwc SIMD approach
- [ ] Write ARCHITECTURE.md for wc
- [ ] Implement line counting (-l) with memchr
- [ ] Implement byte counting (-c)
- [ ] Implement word counting (-w)
- [ ] Implement character counting (-m)
- [ ] Implement max-line-length (-L)
- [ ] Implement --files0-from
- [ ] Implement --total
- [ ] Handle stdin and multiple files
- [ ] Match GNU output format exactly
- [ ] Unit tests
- [ ] GNU compatibility tests
- [ ] Benchmarks vs GNU wc

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

## Benchmarks

| Tool | vs GNU | Target | Status |
|------|--------|--------|--------|
| wc -l | - | 30x | -- |
| wc -w | - | 10x | -- |
| wc -c | - | instant | -- |
| cut | - | 10x | -- |
| base64 | - | 50x+ | -- |
| sha256sum | - | 4-6x | -- |
| sort | - | 5-10x | -- |
| tr | - | 10x | -- |
| uniq | - | 10x | -- |
| b2sum | - | 5x | -- |
| tac | - | 3x | -- |
| md5sum | - | 4-6x | -- |

## Key Findings
- mutagen-rs release profile: `lto = "fat"`, `codegen-units = 1`, `panic = "abort"`, `strip = true`, `opt-level = 3`
- memchr 2.7+ has ARM NEON support, auto-detects AVX2
- fastlwc achieves 30x speedup on line counting via `memchr::memchr_iter(b'\n', data).count()`
- base64-simd can achieve 94x speedup (AVX2 vs scalar)
- sha2 crate auto-detects SHA-NI hardware
- mmap faster than buffered I/O for files > 64KB; buffered better for small files
- GNU wc counts newlines, not lines (file with no trailing newline has 0 lines for "hello")

## Questions / Blockers
- How does GNU wc handle invalid UTF-8 in -m mode?
- What's the exact whitespace definition for -w? (space, tab, newline, CR, form feed, vertical tab)
- How does --files0-from interact with other flags?
