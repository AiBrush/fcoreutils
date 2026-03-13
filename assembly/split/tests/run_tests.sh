#!/bin/bash
# Test suite for fsplit
# Usage: bash tests/run_tests.sh ./fsplit

BIN="${1:-./fsplit}"
GNU="split"
PASS=0
FAIL=0
ERRORS=()
TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT

# Helper to clean output files from a directory
clean_output() {
    local dir="$1"
    local prefix="${2:-x}"
    for f in "$dir"/${prefix}*; do
        [ -f "$f" ] && rm -f "$f"
    done
}

run_test_exit_only() {
    local desc="$1"
    shift
    local args=("$@")

    $GNU "${args[@]}" > /dev/null 2>&1
    local expected_exit=$?
    $BIN "${args[@]}" > /dev/null 2>&1
    local got_exit=$?

    if [ "$expected_exit" = "$got_exit" ]; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
        ERRORS+=("FAIL: $desc -- expected exit: $expected_exit, got: $got_exit")
    fi
}

# Compare split output files between GNU and our tool
run_split_test() {
    local desc="$1"
    shift
    local args=("$@")

    local gnu_dir="$TMPDIR/gnu_$$"
    local our_dir="$TMPDIR/our_$$"
    mkdir -p "$gnu_dir" "$our_dir"

    (cd "$gnu_dir" && $GNU "${args[@]}") > /dev/null 2>&1
    local expected_exit=$?
    (cd "$our_dir" && $BIN "${args[@]}") > /dev/null 2>&1
    local got_exit=$?

    local gnu_files=$(cd "$gnu_dir" && ls -1 2>/dev/null | sort)
    local our_files=$(cd "$our_dir" && ls -1 2>/dev/null | sort)

    local ok=1
    if [ "$expected_exit" != "$got_exit" ]; then
        ok=0
        ERRORS+=("FAIL: $desc -- expected exit: $expected_exit, got: $got_exit")
    fi

    if [ "$gnu_files" != "$our_files" ]; then
        ok=0
        ERRORS+=("FAIL: $desc -- file list mismatch")
        ERRORS+=("  GNU files: $gnu_files")
        ERRORS+=("  Our files: $our_files")
    else
        # Compare contents
        for f in $gnu_files; do
            if ! diff "$gnu_dir/$f" "$our_dir/$f" > /dev/null 2>&1; then
                ok=0
                ERRORS+=("FAIL: $desc -- content mismatch in $f")
                break
            fi
        done
    fi

    if [ "$ok" -eq 1 ]; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
    fi

    rm -rf "$gnu_dir" "$our_dir"
}

# ── Create test files ─────────────────────────────────────────
# 25-line file
for i in $(seq 0 24); do echo "line$i"; done > "$TMPDIR/input25.txt"

# 100-line file
for i in $(seq 0 99); do echo "line $i content here"; done > "$TMPDIR/input100.txt"

# Binary file
dd if=/dev/urandom of="$TMPDIR/binary.bin" bs=1000 count=1 2>/dev/null

# Small file
echo "hello" > "$TMPDIR/small.txt"

# Empty file
touch "$TMPDIR/empty.txt"

# ── Standard flags ──
run_test_exit_only "--help exit code" --help
run_test_exit_only "--version exit code" --version

# ── Default line split (1000 lines) ──
echo "=== Default split ==="
run_split_test "default 1000 lines on 25 lines" "$TMPDIR/input25.txt"

# ── Line split (-l) ──
echo "=== Line split ==="
run_split_test "-l 5 on 25 lines" -l 5 "$TMPDIR/input25.txt"
run_split_test "-l 10 on 25 lines" -l 10 "$TMPDIR/input25.txt"
run_split_test "-l 25 on 25 lines" -l 25 "$TMPDIR/input25.txt"
run_split_test "-l 1 on small" -l 1 "$TMPDIR/small.txt"
run_split_test "-l 100 on 25 lines" -l 100 "$TMPDIR/input25.txt"
run_split_test "-l 5 on 100 lines" -l 5 "$TMPDIR/input100.txt"

# ── Byte split (-b) ──
echo "=== Byte split ==="
run_split_test "-b 100 on binary" -b 100 "$TMPDIR/binary.bin"
run_split_test "-b 300 on binary" -b 300 "$TMPDIR/binary.bin"
run_split_test "-b 1000 on binary" -b 1000 "$TMPDIR/binary.bin"

# ── Byte split with suffixes ──
echo "=== Byte split with K suffix ==="
# Create a 3KB file
dd if=/dev/urandom of="$TMPDIR/big3k.bin" bs=1024 count=3 2>/dev/null
run_split_test "-b 1K on 3KB file" -b 1K "$TMPDIR/big3k.bin"

# ── Custom prefix ──
echo "=== Custom prefix ==="
run_split_test "custom prefix" -l 5 "$TMPDIR/input25.txt" myprefix_

# ── Numeric suffixes (-d) ──
echo "=== Numeric suffixes ==="
run_split_test "-d numeric suffixes" -d -l 5 "$TMPDIR/input25.txt"

# ── Suffix length (-a) ──
echo "=== Suffix length ==="
run_split_test "-a 3 suffix length" -a 3 -l 5 "$TMPDIR/input25.txt"
run_split_test "-d -a 3 numeric + length" -d -a 3 -l 5 "$TMPDIR/input25.txt"

# ── Additional suffix ──
echo "=== Additional suffix ==="
run_split_test "--additional-suffix=.txt" --additional-suffix=.txt -l 5 "$TMPDIR/input25.txt"

# ── Reconstruction test ──
echo "=== Reconstruction ==="
gnu_dir="$TMPDIR/recon_gnu"
our_dir="$TMPDIR/recon_our"
mkdir -p "$gnu_dir" "$our_dir"

(cd "$our_dir" && $BIN -l 5 "$TMPDIR/input25.txt")
reconstructed=""
for f in $(ls -1 "$our_dir" | sort); do
    reconstructed="${reconstructed}$(cat "$our_dir/$f")"
done
original=$(cat "$TMPDIR/input25.txt")
if [ "$reconstructed" = "$original" ]; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: reconstruction -- cat pieces != original")
fi
rm -rf "$gnu_dir" "$our_dir"

# Byte split reconstruction
our_dir="$TMPDIR/recon_byte"
mkdir -p "$our_dir"
(cd "$our_dir" && $BIN -b 300 "$TMPDIR/binary.bin")
cat "$our_dir"/x* > "$TMPDIR/recon_result.bin" 2>/dev/null
if diff "$TMPDIR/binary.bin" "$TMPDIR/recon_result.bin" > /dev/null 2>&1; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: byte split reconstruction -- cat pieces != original")
fi
rm -rf "$our_dir"

# ── Stdin input ──
echo "=== Stdin ==="
gnu_dir="$TMPDIR/stdin_gnu"
our_dir="$TMPDIR/stdin_our"
mkdir -p "$gnu_dir" "$our_dir"

printf "a\nb\nc\nd\n" | (cd "$gnu_dir" && $GNU -l 2 -)
local_exit_gnu=$?
printf "a\nb\nc\nd\n" | (cd "$our_dir" && $BIN -l 2 -)
local_exit_our=$?

gnu_files=$(cd "$gnu_dir" && ls -1 | sort)
our_files=$(cd "$our_dir" && ls -1 | sort)
if [ "$gnu_files" = "$our_files" ] && [ "$local_exit_gnu" = "$local_exit_our" ]; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: stdin split -- file mismatch")
fi
rm -rf "$gnu_dir" "$our_dir"

# ── Error handling ──
echo "=== Error handling ==="
run_test_exit_only "nonexistent file" /nonexistent/file/path

$BIN --badopt > /dev/null 2>&1
rc=$?
$GNU --badopt > /dev/null 2>&1
expected_rc=$?
if [ "$rc" -lt 128 ]; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: --badopt -> signal death")
fi

# ── Verbose ──
echo "=== Verbose ==="
our_dir="$TMPDIR/verbose_out"
mkdir -p "$our_dir"
(cd "$our_dir" && $BIN --verbose -l 5 "$TMPDIR/input25.txt") 2> "$TMPDIR/verbose_err.txt"
verbose_output=$(cat "$TMPDIR/verbose_err.txt")
if echo "$verbose_output" | grep -q "creating file"; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: --verbose does not print 'creating file'")
fi
rm -rf "$our_dir"

# ── Empty file ──
echo "=== Empty file ==="
run_split_test "empty file" "$TMPDIR/empty.txt"

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
