# coreutils-rs

High-performance GNU coreutils replacement in Rust. Faster with SIMD acceleration. Drop-in compatible, cross-platform.

## Performance (100MB text file)

| Command | GNU | coreutils-rs | Speedup |
|---------|-----|-------------|---------|
| `wc -l` | 42ms | 28ms | **1.5x** |
| `wc -w` | 297ms | 117ms | **2.5x** |
| `wc -c` | ~0ms | ~0ms | instant |
| `wc` (default) | 302ms | 135ms | **2.2x** |

## Tools

| Tool | Binary | Status | Description |
|------|--------|--------|-------------|
| wc | `fwc` | Complete | Word, line, byte, char count |
| cut | `fcut` | Planned | Field/byte/char extraction |
| base64 | `fbase64` | Planned | Base64 encode/decode |
| sha256sum | `fsha256sum` | Planned | SHA-256 checksums |
| sort | `fsort` | Planned | Line sorting |
| tr | `ftr` | Planned | Character translation |
| uniq | `funiq` | Planned | Filter duplicate lines |
| b2sum | `fb2sum` | Planned | BLAKE2 checksums |
| tac | `ftac` | Planned | Reverse file lines |
| md5sum | `fmd5sum` | Planned | MD5 checksums |

## Installation

```bash
cargo install coreutils-rs
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
```

## Key Optimizations

- **Zero-copy mmap**: Large files are memory-mapped directly, avoiding copies
- **SIMD line counting**: `memchr` crate auto-detects AVX2/NEON for newline scanning
- **stat-only byte counting**: `-c` flag uses `stat()` without reading file content
- **Optimized release profile**: Fat LTO, single codegen unit, abort on panic

## GNU Compatibility

Output is byte-identical to GNU coreutils. All flags are supported including `--files0-from`, `--total`, and correct column alignment.

## Architecture

See [ARCHITECTURE.md](ARCHITECTURE.md) for design decisions and [PROGRESS.md](PROGRESS.md) for development status.

## License

MIT
