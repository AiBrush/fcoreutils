# fast-coreutils: Research Reference

## SIMD Performance Evidence

### wc (Word Count)
```
Source: fastlwc benchmark (GitHub: expr-fi/fastlwc)
File: 1.6GB text file

GNU wc:           6.55 seconds
SIMD wc:          0.22 seconds
Speedup:          30x

Key technique: memchr::memchr_iter(b'\n', data).count()
```

### base64
```
Source: Muła & Lemire, ACM Transactions on the Web (2017)
"Faster Base64 Encoding and Decoding Using AVX2 Instructions"

Standard decode:  19.73 cycles/byte
AVX2 decode:      0.21 cycles/byte
Speedup:          94x

Rust crate: base64-simd (uses same technique)
```

### SHA-256
```
Source: Intel SHA Extensions documentation

Software SHA-256:     500-800 MB/s
SHA-NI (hardware):    2.8-3.2 GB/s
Speedup:              4-6x

Rust crate: sha2 (auto-detects SHA-NI)
```

### tac (Reverse Lines)
```
Source: NeoSmart Technologies blog (2024)
"Using SIMD acceleration in rust to create the world's fastest tac"

GNU tac:          baseline
SIMD tac:         3x faster

Key technique: memchr reverse iteration + mmap
```

---

## GNU Coreutils Test Suite

Location: `coreutils/tests/`

### Structure
```
tests/
├── wc/
│   ├── wc.pl           # Main test script
│   └── ...
├── cut/
├── sort/
└── ...
```

### Running Tests
```bash
# Build GNU coreutils first
./configure
make

# Run specific tool tests
make check TESTS=wc
make check TESTS="wc cut sort"

# Run all tests
make check
```

### Test Categories
- Empty input handling
- Binary data
- Unicode/multibyte
- Large files
- Error conditions
- Edge cases (no trailing newline, etc.)

---

## Cross-Platform Considerations

### Windows
- Line endings: CRLF vs LF
- Path separators: \ vs /
- Binary mode for stdin/stdout
- No /dev/null (use NUL)
- No mmap equivalent? (Use CreateFileMapping)

### macOS
- BSD vs GNU flag differences (we implement GNU)
- ARM64 (Apple Silicon) uses NEON SIMD
- File system case-insensitivity

### Linux
- AVX-512 on newer Intel CPUs
- ARM64 servers (AWS Graviton)

---

## Key Rust Crates

### SIMD Operations
```toml
memchr = "2"  # SIMD byte search (AVX2, NEON, WASM)
```
- `memchr::memchr_iter(needle, haystack)` - find all occurrences
- `memchr::memmem::find(haystack, needle)` - substring search
- Automatically uses best SIMD for platform

### Memory Mapping
```toml
memmap2 = "0.9"  # Cross-platform mmap
```
- Faster than buffered I/O for large files
- Be careful with files that change during read

### Parallelism
```toml
rayon = "1"  # Data parallelism
```
- `par_iter()` for parallel iteration
- `par_chunks()` for parallel file processing
- Work-stealing for load balancing

### Hashing
```toml
sha2 = "0.10"    # SHA-256 with SHA-NI
blake2 = "0.10"  # BLAKE2
md-5 = "0.10"    # MD5
```
- All auto-detect hardware acceleration
- Use `Digest` trait for uniform interface

### Base64
```toml
base64-simd = "0.8"  # SIMD base64
```
- AVX2 on x86_64
- NEON on ARM64
- Fallback for other platforms

---

## Algorithm Notes

### Line Counting (wc -l)
```rust
// Naive: O(n) with byte-by-byte comparison
fn count_naive(data: &[u8]) -> usize {
    data.iter().filter(|&&b| b == b'\n').count()
}

// SIMD: O(n/32) with AVX2 (32 bytes at once)
fn count_simd(data: &[u8]) -> usize {
    memchr::memchr_iter(b'\n', data).count()
}
```

### Word Counting (wc -w)
Definition: sequence of non-whitespace characters

```rust
// Track state: was previous byte whitespace?
// Word starts when: current is non-ws AND previous was ws

// SIMD approach:
// 1. Create mask of whitespace bytes
// 2. Shift mask by 1
// 3. Find transitions from ws to non-ws
// 4. Count bits

// Whitespace: space, tab, newline, carriage return, form feed, vertical tab
const WHITESPACE: &[u8] = b" \t\n\r\x0c\x0b";
```

### Field Extraction (cut -f)
```rust
// Find all delimiter positions with SIMD
let positions: Vec<usize> = memchr::memchr_iter(delim, line).collect();

// Extract fields by slicing between positions
// Handle -f1,3-5 style field specifications
```

### Sorting (sort)
```rust
// Algorithm selection based on data:
match analyze_data(lines) {
    DataType::Numeric => radix_sort(lines),      // O(n*k)
    DataType::ShortStrings => pdqsort(lines),    // Pattern-defeating quicksort
    DataType::LongStrings => parallel_merge(lines),
    DataType::HugeFile => external_merge(lines), // Files > RAM
}

// Rayon for parallelism
lines.par_sort_unstable_by(|a, b| compare(a, b));
```

### Character Translation (tr)
```rust
// Build 256-byte lookup table
let mut table: [u8; 256] = std::array::from_fn(|i| i as u8);
for (&from, &to) in set1.iter().zip(set2.iter()) {
    table[from as usize] = to;
}

// Apply table (can be SIMD-optimized with pshufb)
for byte in data.iter_mut() {
    *byte = table[*byte as usize];
}
```

---

## Performance Testing Methodology

### Criterion Setup
```rust
use criterion::{black_box, criterion_group, criterion_main, Criterion};

fn bench_wc_lines(c: &mut Criterion) {
    let data = include_bytes!("fixtures/1mb.txt");
    
    c.bench_function("wc_lines", |b| {
        b.iter(|| fast_coreutils::wc::count_lines(black_box(data)))
    });
}
```

### Comparison with GNU
```bash
#!/bin/bash
# Generate test file
dd if=/dev/zero bs=1M count=100 | tr '\0' 'x' > test.txt
echo "" >> test.txt  # Ensure trailing newline

# Benchmark GNU
hyperfine 'wc -l test.txt'

# Benchmark ours
hyperfine './target/release/fwc -l test.txt'

# Side-by-side
hyperfine 'wc -l test.txt' './target/release/fwc -l test.txt'
```

### What to Measure
1. **Cold start**: First run (includes disk I/O)
2. **Warm cache**: Repeated runs (data in page cache)
3. **Throughput**: Bytes/second for large files
4. **Latency**: Time for small files

---

## Common Gotchas

### GNU Compatibility
1. **Trailing newline**: `wc -l` counts newlines, not lines. A file with "hello" (no newline) has 0 lines.

2. **Exit codes**: GNU tools have specific exit codes. 0 = success, 1 = minor errors, 2 = serious errors.

3. **Locale**: `-m` (character count) depends on locale. LC_ALL=C treats bytes as characters.

4. **Binary files**: Some tools have special handling for binary (contain NUL bytes).

5. **Large files**: Must handle files > 4GB, > 2^32 lines.

### Cross-Platform
1. **Windows stdin**: Must set binary mode with `_setmode(_fileno(stdin), _O_BINARY)`

2. **Path encoding**: Windows uses UTF-16 internally. Handle with `std::ffi::OsString`.

3. **File permissions**: Not meaningful on Windows. Handle gracefully.

### Performance
1. **Small files**: mmap overhead may exceed benefit. Use buffered read for < 64KB.

2. **Many small files**: Process in batches to amortize syscall overhead.

3. **Sparse files**: mmap may allocate more memory than expected.

---

## Memory Management

### When to Use mmap
```rust
const MMAP_THRESHOLD: u64 = 64 * 1024; // 64KB

fn read_file(path: &Path) -> io::Result<Vec<u8>> {
    let metadata = std::fs::metadata(path)?;
    
    if metadata.len() >= MMAP_THRESHOLD {
        // Use mmap for large files
        let file = File::open(path)?;
        let mmap = unsafe { Mmap::map(&file)? };
        Ok(mmap.to_vec()) // or keep as Mmap
    } else {
        // Use regular read for small files
        std::fs::read(path)
    }
}
```

### Avoiding Allocations
```rust
// Bad: allocates for each line
for line in data.split(|&b| b == b'\n') {
    let line_str = String::from_utf8_lossy(line); // allocation!
    process(line_str);
}

// Good: work with slices
for line in data.split(|&b| b == b'\n') {
    process_bytes(line); // no allocation
}
```

---

## Error Handling Patterns

```rust
use thiserror::Error;

#[derive(Error, Debug)]
pub enum WcError {
    #[error("cannot open '{0}': {1}")]
    OpenError(PathBuf, io::Error),
    
    #[error("read error: {0}")]
    ReadError(#[from] io::Error),
    
    #[error("invalid utf-8 in filename")]
    InvalidFilename,
}

// Match GNU error format exactly
fn format_error(tool: &str, err: &WcError) -> String {
    format!("{}: {}", tool, err)
}
```

---

## CI/CD Patterns (from mutagen-rs)

### Matrix Strategy
```yaml
strategy:
  fail-fast: false
  matrix:
    include:
      - os: ubuntu-latest
        target: x86_64-unknown-linux-gnu
      - os: ubuntu-latest
        target: aarch64-unknown-linux-gnu
      - os: macos-latest
        target: x86_64-apple-darwin
      - os: macos-latest
        target: aarch64-apple-darwin
      - os: windows-latest
        target: x86_64-pc-windows-msvc
```

### Cross-Compilation
```yaml
- name: Install cross
  run: cargo install cross

- name: Build
  run: cross build --release --target ${{ matrix.target }}
```

### Release Binaries
```yaml
- name: Create release archive
  run: |
    mkdir -p release
    cp target/${{ matrix.target }}/release/fwc* release/
    tar -czf fast-coreutils-${{ matrix.target }}.tar.gz -C release .
```
