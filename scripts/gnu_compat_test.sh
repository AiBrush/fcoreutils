#!/bin/bash
set -euo pipefail

# Test fwc against GNU wc for compatibility
# Generates various test inputs and compares output byte-for-byte

FWC="./target/release/fwc"
PASS=0
FAIL=0
TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; echo "    GNU: $2"; echo "    FWC: $3"; FAIL=$((FAIL + 1)); }

compare() {
    local desc="$1"
    shift
    local gnu_out fwc_out
    gnu_out=$(eval "$@" | wc 2>&1) || gnu_out="ERROR"
    fwc_out=$(eval "$@" | "$FWC" 2>&1) || fwc_out="ERROR"
    if [ "$gnu_out" = "$fwc_out" ]; then
        pass "$desc"
    else
        fail "$desc" "$gnu_out" "$fwc_out"
    fi
}

compare_file() {
    local desc="$1"
    local file="$2"
    shift 2
    local flags="${*:-}"
    local gnu_out fwc_out
    gnu_out=$(wc $flags "$file" 2>&1) || gnu_out="ERROR"
    fwc_out=("$FWC" $flags "$file" 2>&1) || fwc_out="ERROR"
    if [ "$gnu_out" = "$fwc_out" ]; then
        pass "$desc"
    else
        fail "$desc" "$gnu_out" "$fwc_out"
    fi
}

echo "=== GNU wc compatibility tests ==="
echo ""

# Build
echo "Building release..."
cargo build --release 2>/dev/null
echo ""

# Test 1: Empty input
echo "" -n > "$TMPDIR/empty"
compare_file "Empty file" "$TMPDIR/empty"
compare_file "Empty file -l" "$TMPDIR/empty" "-l"
compare_file "Empty file -w" "$TMPDIR/empty" "-w"
compare_file "Empty file -c" "$TMPDIR/empty" "-c"

# Test 2: Single newline
echo "" > "$TMPDIR/newline"
compare_file "Single newline" "$TMPDIR/newline"

# Test 3: No trailing newline
printf "hello" > "$TMPDIR/no_newline"
compare_file "No trailing newline" "$TMPDIR/no_newline"

# Test 4: Simple text
printf "hello world\n" > "$TMPDIR/simple"
compare_file "Simple text" "$TMPDIR/simple"

# Test 5: Multiple lines
printf "one two\nthree four five\nsix\n" > "$TMPDIR/multi"
compare_file "Multiple lines" "$TMPDIR/multi"

# Test 6: Leading/trailing whitespace
printf "  hello  \n  world  \n" > "$TMPDIR/whitespace"
compare_file "Whitespace" "$TMPDIR/whitespace"

# Test 7: Tabs
printf "a\tb\tc\n" > "$TMPDIR/tabs"
compare_file "Tabs" "$TMPDIR/tabs"

# Test 8: Binary data
printf "\x00\x01\x02\n\xff\xfe\n" > "$TMPDIR/binary"
compare_file "Binary data" "$TMPDIR/binary"

# Test 9: Character counting with UTF-8
printf "caf\xc3\xa9\n" > "$TMPDIR/utf8"
compare_file "UTF-8 -m" "$TMPDIR/utf8" "-m"

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
exit $FAIL
