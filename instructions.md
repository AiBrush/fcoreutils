# Claude Code Instructions: fast-coreutils

## Project Vision

Build `fast-coreutils` - a high-performance Rust implementation of GNU coreutils that is:
- **10-30x faster** than GNU through SIMD and parallelism
- **100% GNU compatible** - passes all GNU test suites
- **Cross-platform** - Linux, macOS, Windows (x86_64 + ARM64)
- **Single binary** - no runtime dependencies
- **Memory safe** - pure Rust, no unsafe except for proven SIMD

---

## Phase 0: Project Setup and Research

### 0.1 Initialize Repository

```bash
# Create the project
cargo new fast-coreutils --lib
cd fast-coreutils
```

Create the following structure:
```
fast-coreutils/
├── Cargo.toml              # Workspace with lib + bins
├── README.md               # Project documentation
├── PROGRESS.md             # Track your progress here (CRITICAL)
├── ARCHITECTURE.md         # Document design decisions
├── BENCHMARKS.md           # Record all benchmark results
├── src/
│   ├── lib.rs              # Core library exports
│   ├── common/             # Shared utilities
│   │   ├── mod.rs
│   │   ├── io.rs           # I/O utilities (mmap, buffered read)
│   │   ├── simd.rs         # SIMD abstractions
│   │   ├── parallel.rs     # Rayon helpers
│   │   └── args.rs         # CLI argument parsing patterns
│   ├── wc/                 # Each tool in its own module
│   │   ├── mod.rs          # Public API
│   │   ├── core.rs         # Core algorithm
│   │   └── tests.rs        # Unit tests
│   ├── cut/
│   ├── base64/
│   ├── sha256sum/
│   ├── sort/
│   ├── tr/
│   ├── uniq/
│   ├── b2sum/
│   ├── tac/
│   └── md5sum/
├── src/bin/                # Binary entry points
│   ├── fwc.rs              # Prefixed to avoid conflicts
│   ├── fcut.rs
│   ├── fbase64.rs
│   ├── fsha256sum.rs
│   ├── fsort.rs
│   ├── ftr.rs
│   ├── funiq.rs
│   ├── fb2sum.rs
│   ├── ftac.rs
│   └── fmd5sum.rs
├── benches/
│   ├── wc_benchmark.rs     # Criterion benchmarks per tool
│   ├── comparison.rs       # vs GNU comparison
│   └── fixtures/           # Test data for benchmarks
├── tests/
│   ├── compat/             # GNU compatibility tests
│   │   ├── wc_compat.rs
│   │   └── ...
│   ├── integration/        # End-to-end tests
│   └── fixtures/           # Test files
├── .github/
│   └── workflows/
│       ├── test.yml        # Test on every push
│       ├── pre-merge.yml   # Build all platforms before merge
│       └── release.yml     # Publish to crates.io + GitHub releases
└── scripts/
    ├── gnu_compat_test.sh  # Run GNU test suite
    └── benchmark.sh        # Compare against GNU
```

### 0.2 Core Dependencies

```toml
[package]
name = "fast-coreutils"
version = "0.1.0"
edition = "2024"
license = "MIT"
description = "High-performance GNU coreutils replacement"
repository = "https://github.com/AiBrush/fast-coreutils"
keywords = ["coreutils", "cli", "performance", "simd"]
categories = ["command-line-utilities", "filesystem"]

[lib]
name = "fast_coreutils"
path = "src/lib.rs"

[[bin]]
name = "fwc"
path = "src/bin/fwc.rs"

# ... repeat for each tool

[dependencies]
# CLI
clap = { version = "4", features = ["derive", "cargo"] }

# SIMD byte operations (auto-detects AVX2/NEON)
memchr = "2"

# Memory-mapped I/O
memmap2 = "0.9"

# Parallelism
rayon = "1"

# Hashing (with hardware acceleration)
sha2 = "0.10"           # SHA-256 with SHA-NI
blake2 = "0.10"         # BLAKE2
md-5 = "0.10"           # MD5

# Base64 (SIMD-accelerated)
base64-simd = "0.8"

# Error handling
thiserror = "1"
anyhow = "1"

[dev-dependencies]
criterion = { version = "0.5", features = ["html_reports"] }
proptest = "1"          # Property-based testing
tempfile = "3"

[profile.release]
lto = "fat"
codegen-units = 1
panic = "abort"
strip = true

[profile.bench]
inherits = "release"
debug = true
```

### 0.3 Research Phase (CRITICAL)

Before writing any implementation, research deeply:

1. **Study GNU source code**
   ```bash
   git clone https://github.com/coreutils/coreutils
   # Read the implementation of each tool
   # Understand ALL flags and edge cases
   # Note any undocumented behaviors
   ```

2. **Study GNU test suite**
   ```bash
   cd coreutils/tests
   # Each tool has tests in tests/<toolname>/
   # Understand what behaviors are tested
   # Document edge cases in ARCHITECTURE.md
   ```

3. **Study existing Rust implementations**
   - uutils/coreutils - for compatibility approach
   - gnu-sort crate - for sort optimizations
   - NeoSmart tac - for SIMD tac

4. **Research SIMD techniques**
   - memchr crate internals
   - Daniel Lemire's blog on SIMD
   - Wojciech Muła's SIMD techniques

**Document all findings in ARCHITECTURE.md before coding.**

---

## Phase 1: Foundation (Week 1)

### 1.1 Common Utilities

Build the shared foundation that all tools will use:

```rust
// src/common/io.rs
// Research the best approach for each:
// - When to use mmap vs buffered read?
// - How to handle stdin vs files?
// - How to handle very large files (>RAM)?
// - How to handle binary vs text mode on Windows?
```

Think deeply about:
- **Memory mapping**: When is it faster? When does it hurt?
- **Buffer sizes**: What's optimal for different file sizes?
- **Cross-platform**: Windows line endings, path handling
- **Error handling**: What errors can occur? How to report them GNU-compatibly?

### 1.2 SIMD Abstraction Layer

```rust
// src/common/simd.rs
// Create abstractions that work across:
// - x86_64 with AVX2
// - x86_64 with SSE2 only (older CPUs)
// - ARM64 with NEON
// - Fallback for unknown platforms
```

Research questions:
- How does memchr handle runtime detection?
- Should we use std::simd (unstable) or explicit intrinsics?
- How to benchmark SIMD vs scalar to prove speedup?

---

## Phase 2: Implement Tools (Priority Order)

### Tool 1: wc (Word Count)

**This is your proof of concept. Get it perfect.**

#### Research
- Read GNU wc source completely
- Run `wc --help` and document EVERY flag
- Study fastlwc for SIMD approach
- Study how GNU handles multibyte characters (-m flag)

#### Flags to implement (ALL of them)
```
-c, --bytes            print the byte counts
-m, --chars            print the character counts
-l, --lines            print the newline counts
-L, --max-line-length  print the maximum display width
-w, --words            print the word counts
    --files0-from=F    read input from files in NUL-terminated list
    --total=WHEN       when to print a line with total counts
```

#### Algorithm research
- How does `-w` (word count) work exactly? What counts as a word?
- How does `-m` (char count) differ from `-c` (byte count) for UTF-8?
- What about `-L` (max line length) with wide characters?

#### Performance targets
- Line counting: 30x faster (proven achievable)
- Word counting: 10x faster
- Byte counting: Should be near-instant (just stat the file)

#### Testing strategy
```bash
# Generate test files
dd if=/dev/urandom bs=1M count=100 of=test_100mb.bin
python -c "print('hello world\\n' * 1000000)" > test_text.txt

# Run GNU tests
cd coreutils/tests && make check TESTS=wc

# Our compatibility tests
diff <(gnu-wc file) <(fwc file)
```

### Tool 2: cut (Field Extraction)

#### Research
- Delimiter handling (-d)
- Field selection (-f1,3-5)
- Byte selection (-b)
- Character selection (-c)
- Complement (--complement)

#### Edge cases to handle
- What if delimiter doesn't exist in line?
- What about empty fields?
- How does -s (suppress lines without delimiter) work?

### Tool 3: base64

#### Research
- Use base64-simd crate (don't reinvent)
- Wrap with CLI that matches GNU exactly
- Handle -d (decode), -w (wrap), -i (ignore garbage)

### Tool 4: sha256sum

#### Research
- SHA-NI hardware detection
- Multiple file handling
- Check mode (-c)
- Binary vs text mode (-b, -t)

### Tool 5: sort

**This is the most complex. Allocate extra time.**

#### Research deeply
- Numeric sort (-n)
- Human numeric sort (-h)
- Version sort (-V)
- Field/key sorting (-k)
- Stable sort (-s)
- Unique (-u)
- Parallel sort (--parallel)
- External sort for huge files (-T)

#### Algorithm choices
- Radix sort for numeric data
- Parallel merge sort for general data
- External merge sort for files > RAM

### Tool 6: tr (Translate)

#### Research
- Character class handling ([:alpha:], [:digit:])
- Range expansion (a-z)
- Delete mode (-d)
- Squeeze mode (-s)
- Complement (-c)

### Tool 7: uniq

#### Research
- Case insensitive (-i)
- Count (-c)
- Duplicate only (-d)
- Unique only (-u)
- Field skipping (-f)
- Character skipping (-s)

### Tool 8: b2sum

#### Research
- BLAKE2b vs BLAKE2s
- Length option (-l)
- Use blake2 crate

### Tool 9: tac

#### Research
- Study NeoSmart's SIMD tac
- Separator option (-s)
- Before flag (-b)

### Tool 10: md5sum

#### Research
- Same structure as sha256sum
- Binary/text mode handling

---

## Phase 3: Testing Strategy

### 3.1 Unit Tests

Every function must have unit tests:
```rust
#[cfg(test)]
mod tests {
    use super::*;
    
    #[test]
    fn test_count_lines_empty() { ... }
    
    #[test]
    fn test_count_lines_no_trailing_newline() { ... }
    
    #[test]
    fn test_count_lines_binary_data() { ... }
}
```

### 3.2 Property-Based Tests

Use proptest for fuzzing:
```rust
proptest! {
    #[test]
    fn wc_matches_gnu(input: Vec<u8>) {
        let our_result = fwc::count(&input);
        let gnu_result = run_gnu_wc(&input);
        prop_assert_eq!(our_result, gnu_result);
    }
}
```

### 3.3 GNU Compatibility Tests

Create a script that runs GNU test suite against our binaries:
```bash
#!/bin/bash
# scripts/gnu_compat_test.sh

# Clone GNU coreutils if not present
if [ ! -d "gnu-coreutils" ]; then
    git clone https://github.com/coreutils/coreutils gnu-coreutils
fi

# Build our tools
cargo build --release

# Run tests with our binaries
export PATH="$(pwd)/target/release:$PATH"
cd gnu-coreutils/tests
make check TESTS=wc
make check TESTS=cut
# ... etc
```

### 3.4 Performance Tests

Every tool must have benchmarks proving 10x+ speedup:
```rust
// benches/wc_benchmark.rs
use criterion::{criterion_group, criterion_main, Criterion};

fn benchmark_wc(c: &mut Criterion) {
    let data = std::fs::read("fixtures/100mb.txt").unwrap();
    
    let mut group = c.benchmark_group("wc_lines");
    
    group.bench_function("fast-coreutils", |b| {
        b.iter(|| fast_coreutils::wc::count_lines(&data))
    });
    
    // Compare with GNU (run external process)
    group.bench_function("gnu", |b| {
        b.iter(|| {
            std::process::Command::new("wc")
                .arg("-l")
                .arg("fixtures/100mb.txt")
                .output()
        })
    });
    
    group.finish();
}
```

---

## Phase 4: CI/CD

### 4.1 Test Workflow

```yaml
# .github/workflows/test.yml
name: Test

on:
  push:
    branches: [main]
  pull_request:
  merge_group:

concurrency:
  group: test-${{ github.head_ref || github.ref }}
  cancel-in-progress: true

jobs:
  test-rust:
    name: Test (Rust)
    runs-on: ${{ matrix.os }}
    strategy:
      matrix:
        os: [ubuntu-latest, macos-latest, windows-latest]
    steps:
      - uses: actions/checkout@v6
      - uses: dtolnay/rust-toolchain@stable
      - uses: Swatinem/rust-cache@v2
      - name: Run tests
        run: cargo test --release
      - name: Run clippy
        run: cargo clippy -- -D warnings

  gnu-compat:
    name: GNU Compatibility
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v6
      - uses: dtolnay/rust-toolchain@stable
      - name: Build
        run: cargo build --release
      - name: Clone GNU coreutils
        run: git clone --depth 1 https://github.com/coreutils/coreutils
      - name: Run GNU tests
        run: ./scripts/gnu_compat_test.sh

  benchmarks:
    name: Benchmarks
    needs: [test-rust]
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v6
      - uses: dtolnay/rust-toolchain@stable
      - name: Run benchmarks
        run: cargo bench --bench comparison
      - name: Upload results
        uses: actions/upload-artifact@v6
        with:
          name: benchmark-results
          path: target/criterion
```

### 4.2 Pre-merge Workflow

Build for all platforms before allowing merge.

### 4.3 Release Workflow

- Automatic versioning from tags
- Build binaries for all platforms
- Create GitHub release with binaries
- Publish to crates.io

---

## Phase 5: Documentation

### README.md

Must include:
- Performance comparison table
- Installation instructions (cargo install, binaries)
- Usage examples
- Compatibility notes
- Link to benchmarks

### ARCHITECTURE.md

Document:
- Why we made each design decision
- SIMD techniques used
- Caching strategies
- Platform-specific considerations

### BENCHMARKS.md

Continuously updated with:
- Performance results for each tool
- Comparison methodology
- Hardware used for benchmarks

---

## Progress Tracking (CRITICAL)

### PROGRESS.md

Maintain this file with:
```markdown
# fast-coreutils Progress

## Current Status: Phase X - [description]

## Completed
- [ ] wc: lines, words, bytes, chars, max-line-length
- [ ] wc: GNU test suite passing
- [ ] wc: 30x speedup verified

## In Progress
- [ ] cut: implementing -f flag

## Blocked
- [ ] sort: need to research external sort algorithm

## Benchmarks
| Tool | vs GNU | Target | Status |
|------|--------|--------|--------|
| wc   | 32x    | 10x    | ✅     |
| cut  | 8x     | 10x    | 🔄     |

## Key Findings
- memchr 2.7+ has ARM NEON support
- Windows requires different path handling for...

## Questions to Resolve
- How does GNU handle invalid UTF-8 in -m mode?
```

### Memory Updates

After each significant milestone, update your memory with:
- Key architectural decisions
- Performance findings
- Compatibility gotchas
- What worked and what didn't

---

## Creative Problem Solving Guidelines

### Think Beyond the Obvious

1. **Don't just copy GNU's algorithm** - They optimized for 1990s hardware. Modern CPUs have SIMD, multiple cores, huge caches.

2. **Question everything** - Why does GNU do X? Is there a faster way that produces identical output?

3. **Measure, don't assume** - Before implementing an optimization, benchmark to prove it helps.

4. **Learn from failures** - If something is slower than expected, investigate why. Document findings.

### Research Sources

- Daniel Lemire's blog (lemire.me) - SIMD techniques
- Wojciech Muła's site (0x80.pl) - SIMD algorithms
- Rust Performance Book
- BurntSushi's blog (burntsushi.net) - memchr, ripgrep insights

### When Stuck

1. Read the GNU source code - understand their solution first
2. Search for academic papers on the algorithm
3. Check if there's a Rust crate that solves part of the problem
4. Benchmark different approaches, don't guess

---

## Success Criteria

Before declaring a tool "complete":

1. ✅ All GNU flags implemented
2. ✅ Passes 100% of GNU test suite
3. ✅ Works on Linux, macOS, Windows
4. ✅ Works on x86_64 and ARM64
5. ✅ At least 10x faster than GNU (proven with benchmarks)
6. ✅ No unsafe code (except SIMD intrinsics if needed)
7. ✅ Comprehensive unit tests
8. ✅ Documentation complete
9. ✅ Clippy passes with no warnings
10. ✅ CI/CD builds and tests passing

---

## Final Notes

This is an ambitious project. The key to success is:

1. **Deep research before coding** - Understand the problem completely
2. **Incremental progress** - Get one tool perfect before moving to the next
3. **Continuous benchmarking** - Prove every optimization works
4. **Rigorous testing** - 100% GNU compatibility is non-negotiable
5. **Document everything** - Future you will thank present you

Start with `wc`. Get it absolutely perfect. Use that as the template for all other tools.

Good luck! 🚀
