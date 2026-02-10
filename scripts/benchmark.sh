#!/bin/bash
set -euo pipefail

# Compare fwc against GNU wc
# Requires: hyperfine, wc (GNU), and built fwc

FWC="./target/release/fwc"
TESTFILE="${1:-/tmp/coreutils-rs-bench.txt}"

echo "=== coreutils-rs benchmark ==="
echo ""

# Generate test file if it doesn't exist
if [ ! -f "$TESTFILE" ]; then
    echo "Generating test file: $TESTFILE (100MB)"
    python3 -c "
import sys
line = 'the quick brown fox jumps over the lazy dog\n'
count = (100 * 1024 * 1024) // len(line)
sys.stdout.buffer.write(line.encode() * count)
" > "$TESTFILE"
fi

echo "Test file: $TESTFILE ($(du -h "$TESTFILE" | cut -f1))"
echo ""

# Build release
echo "Building release..."
cargo build --release 2>/dev/null
echo ""

# Verify correctness first
echo "=== Correctness check ==="
GNU_RESULT=$(wc "$TESTFILE")
OUR_RESULT=$("$FWC" "$TESTFILE")
echo "GNU wc:  $GNU_RESULT"
echo "fwc:     $OUR_RESULT"
echo ""

# Benchmark with hyperfine if available
if command -v hyperfine &> /dev/null; then
    echo "=== Line counting (-l) ==="
    hyperfine --warmup 3 "wc -l $TESTFILE" "$FWC -l $TESTFILE"
    echo ""

    echo "=== Word counting (-w) ==="
    hyperfine --warmup 3 "wc -w $TESTFILE" "$FWC -w $TESTFILE"
    echo ""

    echo "=== Byte counting (-c) ==="
    hyperfine --warmup 3 "wc -c $TESTFILE" "$FWC -c $TESTFILE"
    echo ""

    echo "=== Default (lines + words + bytes) ==="
    hyperfine --warmup 3 "wc $TESTFILE" "$FWC $TESTFILE"
    echo ""
else
    echo "hyperfine not found. Install with: cargo install hyperfine"
    echo "Falling back to time-based comparison..."
    echo ""

    echo "=== Line counting (-l) ==="
    echo "GNU wc:"
    time wc -l "$TESTFILE"
    echo ""
    echo "fwc:"
    time "$FWC" -l "$TESTFILE"
    echo ""

    echo "=== Word counting (-w) ==="
    echo "GNU wc:"
    time wc -w "$TESTFILE"
    echo ""
    echo "fwc:"
    time "$FWC" -w "$TESTFILE"
    echo ""
fi
