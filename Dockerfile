# ── Build stage ──────────────────────────────────────────────────────────────
FROM rust:slim AS builder

WORKDIR /build

# nasm  → assembly fyes build
# python3 → build.py assembly driver
RUN apt-get update && \
    apt-get install -y --no-install-recommends nasm python3 && \
    rm -rf /var/lib/apt/lists/*

COPY . .

RUN cargo build --release

# Build hand-written assembly fyes (overwrites Rust binary if successful)
RUN arch=$(uname -m); \
    case "$arch" in \
      x86_64)  target="linux-x86_64" ;; \
      aarch64) target="linux-arm64"  ;; \
      *)       target=""             ;; \
    esac; \
    if [ -n "$target" ]; then \
      cd assembly/yes && \
      python3 build.py --target "$target" -o /build/target/release/fyes || true; \
    fi

# Collect all built binaries into /dist (executable files named f*)
RUN mkdir /dist && \
    find /build/target/release -maxdepth 1 -type f -executable -name 'f*' \
      -exec cp {} /dist/ \;

# ── Runtime stage ─────────────────────────────────────────────────────────────
FROM debian:bookworm-slim

COPY --from=builder /dist/ /usr/local/bin/

LABEL org.opencontainers.image.source="https://github.com/AiBrush/fcoreutils"
LABEL org.opencontainers.image.description="High-performance GNU coreutils replacement in Rust. 10-30x faster with SIMD acceleration. Drop-in compatible, cross-platform."
LABEL org.opencontainers.image.licenses="MIT"
LABEL org.opencontainers.image.documentation="https://github.com/AiBrush/fcoreutils#readme"
