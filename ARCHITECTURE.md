# coreutils-rs Architecture

## wc (Word Count)

### GNU wc Internals (from studying coreutils 9.7 src/wc.c)

**Flags:** `-c` (bytes), `-m` (chars), `-l` (lines), `-w` (words), `-L` (max line length),
`--files0-from=F`, `--total=WHEN`, `--debug` (undocumented: shows SIMD tier)

**Default:** When no flags given, defaults to `-lwc` (lines + words + bytes).

**Output order:** lines, words, chars, bytes, max_line_length (always fixed).

**Column width:** Computed from `stat()` file sizes (sum of all files), not from actual counts.
Non-regular files (stdin, pipes, /proc) force minimum width of 7.

**Line counting (4 tiers):**
1. AVX-512: `_mm512_cmpeq_epi8_mask` + `popcountll` (64 bytes/cycle)
2. AVX-2: `_mm256_cmpeq_epi8` + `_mm256_movemask_epi8` + popcount (32 bytes/cycle)
3. Scalar long-lines: `rawmemchr(p, '\n')` when avg line > 15 chars
4. Scalar short-lines: byte-by-byte `*p == '\n'`

**Word counting:** Tracks whitespace→non-whitespace transitions.
- C locale: `isspace()` for bytes 0-255
- UTF-8 locale: `c32isspace()` for multibyte + hardcoded ASCII switch
- Non-breaking spaces (U+00A0 etc.) treated as separators unless POSIXLY_CORRECT

**Character counting (-m):**
- MB_CUR_MAX == 1 (C locale): chars = bytes
- MB_CUR_MAX > 1: uses `mbrtoc32()`, invalid bytes NOT counted as chars

**Max line length (-L):**
- `\n`: resets line position, checks max
- `\r`, `\f`: resets line position (no line increment)
- `\t`: `linepos += 8 - (linepos % 8)` (standard 8-column tabs)
- `\v`: zero display width
- Printable ASCII: width 1
- Multibyte: `c32width(wide_char)` (equivalent to wcwidth)

**Byte counting (-c only):** Uses `lseek()` for regular files — never reads the file!
For /proc files (size is page-aligned), seeks near EOF and reads remainder to verify.

**Buffer:** 256 KiB stack-allocated (`IO_BUFSIZE = 256 * 1024`).

### Our Approach vs GNU

| Feature | GNU wc | coreutils-rs |
|---------|--------|-------------|
| Line counting | AVX-512/AVX-2/scalar | memchr (auto-detects AVX2/NEON/SSE2) |
| Word counting | scalar with lookup table | scalar (TODO: SIMD via PSHUFB) |
| Byte counting | lseek for regular files | data.len() after read |
| Char counting | mbrtoc32() | UTF-8 leading byte detection |
| File I/O | read() with 256KB buffer | mmap for >64KB, fs::read for small |
| Max line length | c32width() for multibyte | byte counting (C locale only) |

### SIMD Word Counting (from fastlwc research)

fastlwc achieves 30x speedup using PSHUFB for parallel whitespace classification:

1. **Whitespace lookup:** Load 16-byte lookup table into SIMD register.
   Use `_mm_shuffle_epi8` (PSHUFB) with input byte lower nibbles as indices.
   Two-step approach: lower nibble lookup + upper nibble mask verification.

2. **Transition detection:** Given whitespace mask `ws`:
   - `first_chars = ~ws & ((ws << 1) | carry_from_previous_chunk)`
   - Each set bit in `first_chars` marks a word start

3. **Count:** Use `popcnt` on the mask to count word starts.

For our Rust implementation, memchr handles line counting optimally.
Word counting could benefit from similar SIMD approach in the future.

### Edge Cases Verified Against GNU wc 9.7

| Case | Expected | Status |
|------|----------|--------|
| Empty file | `0 0 0 file` | Verified |
| Single newline | `1 0 1 file` | Verified |
| No trailing newline | `0 1 5 file` (for "hello") | Verified |
| CRLF endings | \r not counted as line, \r display width 0 | Verified |
| Binary data (NUL bytes) | NUL is non-whitespace | Verified |
| Form feed / vertical tab | Both are word separators | Verified |
| Tab in -L | Advances to next multiple of 8 | Verified |
| -cm together | Shows chars then bytes (fixed order) | Verified |
| --total=only | No individual files, no "total" label | Verified |
| --total=always | Shows total even for single file | Verified |
| --total=never | No total even for multiple files | Verified |
| UTF-8 -m | Counts characters, not bytes | Verified |
| Stdin default | Width 7, no filename | Verified |

### Performance Targets

| Metric | GNU wc | Target | Technique |
|--------|--------|--------|-----------|
| Line count | ~1 GB/s | ~10 GB/s | memchr SIMD |
| Word count | ~200 MB/s | ~2 GB/s | scalar (future: PSHUFB) |
| Byte count | instant (lseek) | ~instant | data.len() |
| Char count | ~200 MB/s | ~2 GB/s | UTF-8 lead byte detection |
