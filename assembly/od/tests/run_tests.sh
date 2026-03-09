#!/bin/bash
# Test suite for fod (assembly od)
# Usage: bash tests/run_tests.sh ./fod

BIN="${1:-./fod}"
GNU="od"

PASS=0
FAIL=0
ERRORS=()

run_test() {
    local desc="$1"
    shift
    local input="$1"
    shift

    local expected=$(printf "$input" | $GNU "$@" 2>&1)
    local expected_exit=$?
    local got=$(printf "$input" | $BIN "$@" 2>&1)
    local got_exit=$?

    if [ "$expected" = "$got" ] && [ "$expected_exit" = "$got_exit" ]; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
        ERRORS+=("FAIL: $desc")
        if [ "$expected" != "$got" ]; then
            ERRORS+=("  expected output: $(echo "$expected" | head -3)")
            ERRORS+=("  got output:      $(echo "$got" | head -3)")
        fi
        if [ "$expected_exit" != "$got_exit" ]; then
            ERRORS+=("  expected exit: $expected_exit, got: $got_exit")
        fi
    fi
}

run_file_test() {
    local desc="$1"
    local file="$2"
    shift 2

    local expected=$($GNU "$@" "$file" 2>&1)
    local expected_exit=$?
    local got=$($BIN "$@" "$file" 2>&1)
    local got_exit=$?

    if [ "$expected" = "$got" ] && [ "$expected_exit" = "$got_exit" ]; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
        ERRORS+=("FAIL: $desc")
        if [ "$expected" != "$got" ]; then
            ERRORS+=("  expected: $(echo "$expected" | head -3)")
            ERRORS+=("  got:      $(echo "$got" | head -3)")
        fi
    fi
}

echo "=== Testing $BIN against GNU od ==="
echo ""

# ── Setup temp files ─────────────────────────────────────────
TMPDIR=$(mktemp -d /tmp/fod_test.XXXXXX)
trap "rm -rf $TMPDIR" EXIT

# Create test data files
dd if=/dev/urandom of="$TMPDIR/random.bin" bs=1K count=1 2>/dev/null
printf '\x00\x01\x02\x03\x04\x05\x06\x07\x08\x09\x0a\x0b\x0c\x0d\x0e\x0f' > "$TMPDIR/16bytes.bin"
printf '\x00\x01\x02\x03\x04\x05\x06\x07\x08\x09\x0a\x0b\x0c\x0d\x0e\x0f\x10\x11\x12\x13\x14\x15\x16\x17\x18\x19\x1a\x1b\x1c\x1d\x1e\x1f' > "$TMPDIR/32bytes.bin"
echo "Hello, World!" > "$TMPDIR/hello.txt"
echo -n "" > "$TMPDIR/empty.bin"
printf '\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00' > "$TMPDIR/zeros16.bin"
printf '\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00' > "$TMPDIR/zeros48.bin"
printf 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789abcdefghijklmnop' > "$TMPDIR/alpha.txt"
printf '\xff\xfe\xfd\xfc\xfb\xfa\xf9\xf8\xf7\xf6\xf5\xf4\xf3\xf2\xf1\xf0' > "$TMPDIR/highbytes.bin"

# ── Default format (octal shorts) ───────────────────────────
run_file_test "default format" "$TMPDIR/16bytes.bin"
run_file_test "default 32 bytes" "$TMPDIR/32bytes.bin"
run_file_test "default hello" "$TMPDIR/hello.txt"

# ── Octal formats ───────────────────────────────────────────
run_file_test "-t o1" "$TMPDIR/16bytes.bin" -t o1
run_file_test "-t o2" "$TMPDIR/16bytes.bin" -t o2
run_file_test "-t o4" "$TMPDIR/16bytes.bin" -t o4
run_file_test "-b (=o1)" "$TMPDIR/16bytes.bin" -b

# ── Hex formats ─────────────────────────────────────────────
run_file_test "-t x1" "$TMPDIR/16bytes.bin" -t x1
run_file_test "-t x2" "$TMPDIR/16bytes.bin" -t x2
run_file_test "-t x4" "$TMPDIR/16bytes.bin" -t x4
run_file_test "-x (=x2)" "$TMPDIR/16bytes.bin" -x

# ── Signed decimal formats ──────────────────────────────────
run_file_test "-t d1" "$TMPDIR/16bytes.bin" -t d1
run_file_test "-t d2" "$TMPDIR/16bytes.bin" -t d2
run_file_test "-t d4" "$TMPDIR/16bytes.bin" -t d4
run_file_test "-s (=d2)" "$TMPDIR/16bytes.bin" -s
run_file_test "-t d1 high bytes" "$TMPDIR/highbytes.bin" -t d1
run_file_test "-t d2 high bytes" "$TMPDIR/highbytes.bin" -t d2

# ── Unsigned decimal formats ────────────────────────────────
run_file_test "-t u1" "$TMPDIR/16bytes.bin" -t u1
run_file_test "-t u2" "$TMPDIR/16bytes.bin" -t u2
run_file_test "-t u4" "$TMPDIR/16bytes.bin" -t u4
run_file_test "-d (=u2)" "$TMPDIR/16bytes.bin" -d

# ── Named characters (type a) ──────────────────────────────
run_file_test "-t a" "$TMPDIR/16bytes.bin" -t a
run_file_test "-t a 32bytes" "$TMPDIR/32bytes.bin" -t a
run_file_test "-a" "$TMPDIR/16bytes.bin" -a

# ── C-style characters (type c) ────────────────────────────
run_file_test "-t c" "$TMPDIR/16bytes.bin" -t c
run_file_test "-t c 32bytes" "$TMPDIR/32bytes.bin" -t c
run_file_test "-c" "$TMPDIR/16bytes.bin" -c
run_file_test "-c hello" "$TMPDIR/hello.txt" -c
run_file_test "-c high bytes" "$TMPDIR/highbytes.bin" -c

# ── Address radix ───────────────────────────────────────────
run_file_test "-A o (default)" "$TMPDIR/16bytes.bin" -A o -t x1
run_file_test "-A d" "$TMPDIR/16bytes.bin" -A d -t x1
run_file_test "-A x" "$TMPDIR/16bytes.bin" -A x -t x1
run_file_test "-A n" "$TMPDIR/16bytes.bin" -A n -t x1

# ── Duplicate suppression ──────────────────────────────────
run_file_test "dup suppression" "$TMPDIR/zeros48.bin"
run_file_test "-v (no dup suppression)" "$TMPDIR/zeros48.bin" -v

# ── Width flag ──────────────────────────────────────────────
run_file_test "-w8" "$TMPDIR/32bytes.bin" -w8 -t x1
run_file_test "-w4" "$TMPDIR/16bytes.bin" -w4 -t x1
run_file_test "-w32" "$TMPDIR/32bytes.bin" -w32 -t x1

# ── Skip and limit ─────────────────────────────────────────
run_file_test "-j 8" "$TMPDIR/16bytes.bin" -j 8 -t x1
run_file_test "-N 8" "$TMPDIR/16bytes.bin" -N 8 -t x1
run_file_test "-j 4 -N 8" "$TMPDIR/32bytes.bin" -j 4 -N 8 -t x1

# ── Empty input ─────────────────────────────────────────────
run_file_test "empty file" "$TMPDIR/empty.bin"

# ── Multiple types ──────────────────────────────────────────
run_file_test "-t x1 -t o1" "$TMPDIR/16bytes.bin" -t x1 -t o1
run_file_test "-t d4 -t x1" "$TMPDIR/16bytes.bin" -t d4 -t x1
run_file_test "-t x2 -t o1" "$TMPDIR/16bytes.bin" -t x2 -t o1
run_file_test "-t a -t c" "$TMPDIR/16bytes.bin" -t a -t c

# ── Stdin ───────────────────────────────────────────────────
run_test "stdin default" '\x41\x42\x43\x44\x45\x46\x47\x48'
run_test "stdin -t x1" '\x41\x42\x43\x44' -t x1
run_test "stdin -t c" '\x41\x42\x43\x44' -t c
run_test "stdin -t a" '\x41\x42\x43\x44' -t a

# ── Partial last values ────────────────────────────────────
run_test "partial x2" '\x01\x02\x03' -t x2
run_test "partial o2" '\x01\x02\x03' -t o2
run_test "partial d2" '\x01\x02\x03' -t d2
run_test "partial u2" '\x01\x02\x03' -t u2

# ── Large file test ─────────────────────────────────────────
run_file_test "1K random -t x1" "$TMPDIR/random.bin" -t x1
run_file_test "1K random -t o2" "$TMPDIR/random.bin" -t o2

# ── Special: printable chars in type c ──────────────────────
run_file_test "alpha -t c" "$TMPDIR/alpha.txt" -t c

# ── Short flags combined ───────────────────────────────────
run_file_test "-bcx combined" "$TMPDIR/16bytes.bin" -b -c -x

# ── Print results ──────────────────────────────────────────
echo ""
echo "================================"
echo "Results: $PASS passed, $FAIL failed out of $((PASS+FAIL)) tests"

if [ ${#ERRORS[@]} -gt 0 ]; then
    echo ""
    echo "Failed tests:"
    for err in "${ERRORS[@]}"; do
        echo "  $err"
    done
fi

exit $FAIL
