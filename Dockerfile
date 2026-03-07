# ── Build stage ──────────────────────────────────────────────────────────────
FROM rust:slim@sha256:d6782f2b326a10eaf593eb90cafc34a03a287b4a25fe4d0c693c90304b06f6d7 AS builder

WORKDIR /build

# nasm  → assembly fyes build
# python3 → build.py assembly driver
# libssl-dev → system OpenSSL headers for hash performance (SHA-NI via OPENSSL_STATIC=1)
RUN apt-get update && \
    apt-get install -y --no-install-recommends nasm python3 libssl-dev && \
    rm -rf /var/lib/apt/lists/*

COPY . .

RUN OPENSSL_STATIC=1 cargo build --release

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
FROM debian:bookworm-slim@sha256:74d56e3931e0d5a1dd51f8c8a2466d21de84a271cd3b5a733b803aa91abf4421

COPY --from=builder /dist/ /usr/local/bin/

LABEL org.opencontainers.image.source="https://github.com/AiBrush/fcoreutils"
LABEL org.opencontainers.image.description="High-performance GNU coreutils replacement in Rust. 10-30x faster with SIMD acceleration. Drop-in compatible, cross-platform."
LABEL org.opencontainers.image.licenses="MIT"
LABEL org.opencontainers.image.documentation="https://github.com/AiBrush/fcoreutils#readme"
