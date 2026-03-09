#!/bin/bash
# GNU compatibility tests for fod (assembly)
# Compares byte-for-byte stdout and exit code against GNU od
# Usage: bash test_fod.sh [path-to-fod]

BIN="${1:-../od/fod}"
GNU="od"

PASS=0
FAIL=0
ERRORS=()

TMPDIR=$(mktemp -d /tmp/test_fod.XXXXXX)
trap "rm -rf $TMPDIR" EXIT

run_test_stdin() {
    local desc="$1"
    local input="$2"
    shift 2
    local args=("$@")

    local expected=$(printf "$input" | $GNU "${args[@]}" 2>&1)
    local expected_exit=$?
    local got=$(printf "$input" | $BIN "${args[@]}" 2>&1)
    local got_exit=$?

    if [ "$expected" = "$got" ] && [ "$expected_exit" = "$got_exit" ]; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
        ERRORS+=("FAIL: $desc")
        if [ "$expected" != "$got" ]; then
            ERRORS+=("  expected first 3 lines: $(echo "$expected" | head -3)")
            ERRORS+=("  got first 3 lines:      $(echo "$got" | head -3)")
        fi
        if [ "$expected_exit" != "$got_exit" ]; then
            ERRORS+=("  expected exit: $expected_exit, got: $got_exit")
        fi
    fi
}

run_test_file() {
    local desc="$1"
    local file="$2"
    shift 2
    local args=("$@")

    local expected=$($GNU "${args[@]}" "$file" 2>&1)
    local expected_exit=$?
    local got=$($BIN "${args[@]}" "$file" 2>&1)
    local got_exit=$?

    if [ "$expected" = "$got" ] && [ "$expected_exit" = "$got_exit" ]; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
        ERRORS+=("FAIL: $desc")
        if [ "$expected" != "$got" ]; then
            ERRORS+=("  expected first 3 lines: $(echo "$expected" | head -3)")
            ERRORS+=("  got first 3 lines:      $(echo "$got" | head -3)")
        fi
        if [ "$expected_exit" != "$got_exit" ]; then
            ERRORS+=("  expected exit: $expected_exit, got: $got_exit")
        fi
    fi
}

# ── Create test data ──
printf '\x00\x01\x02\x03\x04\x05\x06\x07\x08\x09\x0a\x0b\x0c\x0d\x0e\x0f' > "$TMPDIR/16bytes.bin"
printf '\x00\x01\x02\x03\x04\x05\x06\x07\x08\x09\x0a\x0b\x0c\x0d\x0e\x0f\x10\x11\x12\x13\x14\x15\x16\x17\x18\x19\x1a\x1b\x1c\x1d\x1e\x1f' > "$TMPDIR/32bytes.bin"
echo "Hello, World!" > "$TMPDIR/hello.txt"
echo -n "" > "$TMPDIR/empty.bin"
printf '\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00' > "$TMPDIR/zeros16.bin"
printf '\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00' > "$TMPDIR/zeros48.bin"
printf 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789abcdefghijklmnop' > "$TMPDIR/alpha.txt"
printf '\xff\xfe\xfd\xfc\xfb\xfa\xf9\xf8' > "$TMPDIR/highbytes.bin"

# Small file < 16 bytes
printf '\x41\x42\x43' > "$TMPDIR/small.bin"

echo "=== fod GNU compatibility tests ==="
echo ""

# ── Hex dump: od -A x -t x1 ──
echo "-- Hex dump (-A x -t x1) --"
run_test_file "-A x -t x1" "$TMPDIR/16bytes.bin" -A x -t x1
run_test_file "-A x -t x1 32 bytes" "$TMPDIR/32bytes.bin" -A x -t x1
run_test_file "-A x -t x1 hello" "$TMPDIR/hello.txt" -A x -t x1

# ── Octal dump: od -A o -t o1 ──
echo "-- Octal dump (-A o -t o1) --"
run_test_file "-A o -t o1" "$TMPDIR/16bytes.bin" -A o -t o1
run_test_file "-A o -t o1 32 bytes" "$TMPDIR/32bytes.bin" -A o -t o1

# ── Decimal addresses, decimal bytes: od -A d -t d1 ──
echo "-- Decimal dump (-A d -t d1) --"
run_test_file "-A d -t d1" "$TMPDIR/16bytes.bin" -A d -t d1

# ── No addresses: od -A n ──
echo "-- No addresses (-A n) --"
run_test_file "-A n" "$TMPDIR/16bytes.bin" -A n -t x1
run_test_file "-A n default type" "$TMPDIR/16bytes.bin" -A n

# ── Empty file ──
echo "-- Empty file --"
run_test_file "empty file" "$TMPDIR/empty.bin"

# ── Binary data with nulls ──
echo "-- Binary with nulls --"
run_test_file "zeros 16 bytes" "$TMPDIR/zeros16.bin"
run_test_file "zeros 48 bytes (dup suppression)" "$TMPDIR/zeros48.bin"
run_test_file "zeros 48 -v (no suppression)" "$TMPDIR/zeros48.bin" -v

# ── Small file (< 16 bytes) ──
echo "-- Small file --"
run_test_file "3-byte file" "$TMPDIR/small.bin"
run_test_file "3-byte file -t x1" "$TMPDIR/small.bin" -t x1
run_test_file "3-byte file -t c" "$TMPDIR/small.bin" -t c

# ── Limit bytes (-N) ──
echo "-- Limit bytes (-N) --"
run_test_file "-N 8" "$TMPDIR/16bytes.bin" -N 8 -t x1
run_test_file "-N 32" "$TMPDIR/32bytes.bin" -N 32 -t x1
run_test_file "-N 4" "$TMPDIR/alpha.txt" -N 4 -t x1

# ── Skip bytes (-j) ──
echo "-- Skip bytes (-j) --"
run_test_file "-j 8" "$TMPDIR/16bytes.bin" -j 8 -t x1
run_test_file "-j 10" "$TMPDIR/32bytes.bin" -j 10 -t x1
run_test_file "-j 4 -N 8" "$TMPDIR/32bytes.bin" -j 4 -N 8 -t x1

# ── Various format types ──
echo "-- Format types --"
run_test_file "-t o1 (octal bytes)" "$TMPDIR/16bytes.bin" -t o1
run_test_file "-t o2 (octal shorts)" "$TMPDIR/16bytes.bin" -t o2
run_test_file "-t x2 (hex shorts)" "$TMPDIR/16bytes.bin" -t x2
run_test_file "-t x4 (hex words)" "$TMPDIR/16bytes.bin" -t x4
run_test_file "-t d1 (signed decimal)" "$TMPDIR/16bytes.bin" -t d1
run_test_file "-t d2 (signed decimal shorts)" "$TMPDIR/16bytes.bin" -t d2
run_test_file "-t u1 (unsigned decimal)" "$TMPDIR/16bytes.bin" -t u1
run_test_file "-t a (named chars)" "$TMPDIR/16bytes.bin" -t a
run_test_file "-t c (C chars)" "$TMPDIR/16bytes.bin" -t c

# ── Short flags ──
echo "-- Short flags --"
run_test_file "-b (octal bytes)" "$TMPDIR/16bytes.bin" -b
run_test_file "-c (C chars)" "$TMPDIR/16bytes.bin" -c
run_test_file "-x (hex shorts)" "$TMPDIR/16bytes.bin" -x
run_test_file "-d (unsigned decimal shorts)" "$TMPDIR/16bytes.bin" -d
run_test_file "-s (signed decimal shorts)" "$TMPDIR/16bytes.bin" -s

# ── Stdin ──
echo "-- Stdin --"
run_test_stdin "stdin default" '\x41\x42\x43\x44\x45\x46\x47\x48'
run_test_stdin "stdin -t x1" '\x41\x42\x43\x44' -t x1
run_test_stdin "stdin -t c" '\x41\x42\x43\x44' -t c

# ── High bytes ──
echo "-- High bytes --"
run_test_file "high bytes -t x1" "$TMPDIR/highbytes.bin" -t x1
run_test_file "high bytes -t d1" "$TMPDIR/highbytes.bin" -t d1
run_test_file "high bytes -c" "$TMPDIR/highbytes.bin" -c

# ── Multiple types ──
echo "-- Multiple types --"
run_test_file "-t x1 -t o1" "$TMPDIR/16bytes.bin" -t x1 -t o1
run_test_file "-t a -t c" "$TMPDIR/16bytes.bin" -t a -t c

# ── Results ──
echo ""
echo "Results: $PASS passed, $FAIL failed out of $((PASS+FAIL)) tests"
for e in "${ERRORS[@]}"; do echo "  $e"; done
echo ""

if [ $FAIL -eq 0 ]; then
    echo "ALL TESTS PASSED"
    exit 0
else
    echo "$FAIL TESTS FAILED"
    exit 1
fi
