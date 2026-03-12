#!/bin/bash
# Test suite for fsha1sum
# Usage: bash tests/run_tests.sh ./fsha1sum

BIN="${1:-./fsha1sum}"
GNU="/usr/bin/sha1sum"
TOOL="sha1sum"

PASS=0
FAIL=0
ERRORS=()

normalize_gnu() {
    sed -e "s|$GNU|PROG|g" -e "s|Usage: $TOOL|Usage: PROG|g" -e "s|^$TOOL |PROG |g"
}

normalize_our() {
    sed -e "s|$BIN|PROG|g" -e "s|Usage: $TOOL|Usage: PROG|g" -e "s|^$TOOL |PROG |g"
}

run_test() {
    local desc="$1"
    shift
    local args=("$@")

    expected=$($GNU "${args[@]}" 2>&1 | normalize_gnu)
    expected_exit=$?
    got=$($BIN "${args[@]}" 2>&1 | normalize_our)
    got_exit=$?

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

run_test_stdin() {
    local desc="$1"
    local input="$2"
    shift 2
    local args=("$@")

    expected=$(echo -e "$input" | $GNU "${args[@]}" 2>&1 | normalize_gnu)
    expected_exit=$?
    got=$(echo -e "$input" | $BIN "${args[@]}" 2>&1 | normalize_our)
    got_exit=$?

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

run_test_printf() {
    local desc="$1"
    local input="$2"
    shift 2
    local args=("$@")

    expected=$(printf "%s" "$input" | $GNU "${args[@]}" 2>&1 | normalize_gnu)
    expected_exit=$?
    got=$(printf "%s" "$input" | $BIN "${args[@]}" 2>&1 | normalize_our)
    got_exit=$?

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

# ── Setup temp files ─────────────────────────────────────────
TMPDIR=$(mktemp -d /tmp/sha1_test.XXXXXX)
trap "rm -rf $TMPDIR" EXIT

printf "hello\n" > "$TMPDIR/hello.txt"
printf "world\n" > "$TMPDIR/world.txt"
echo -n "" > "$TMPDIR/empty.txt"
printf "test content\n" > "$TMPDIR/test.txt"

# Generate checksum files for -c tests
$GNU "$TMPDIR/hello.txt" > "$TMPDIR/hello.sha1"
$GNU "$TMPDIR/hello.txt" "$TMPDIR/world.txt" > "$TMPDIR/multi.sha1"

# ── Known test vectors ───────────────────────────────────────
echo "=== SHA-1 Known Test Vectors ==="

# SHA1("") = da39a3ee5e6b4b0d3255bfef95601890afd80709
empty_hash=$(printf "" | $BIN | cut -d' ' -f1)
if [ "$empty_hash" = "da39a3ee5e6b4b0d3255bfef95601890afd80709" ]; then
    PASS=$((PASS+1))
    echo "[PASS] SHA1 empty string"
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: SHA1 empty string")
    ERRORS+=("  expected: da39a3ee5e6b4b0d3255bfef95601890afd80709")
    ERRORS+=("  got:      $empty_hash")
fi

# SHA1("abc") = a9993e364706816aba3e25717850c26c9cd0d89d
abc_hash=$(printf "abc" | $BIN | cut -d' ' -f1)
if [ "$abc_hash" = "a9993e364706816aba3e25717850c26c9cd0d89d" ]; then
    PASS=$((PASS+1))
    echo "[PASS] SHA1 'abc'"
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: SHA1 'abc'")
    ERRORS+=("  expected: a9993e364706816aba3e25717850c26c9cd0d89d")
    ERRORS+=("  got:      $abc_hash")
fi

# SHA1("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq")
# = 84983e441c3bd26ebaae4aa1f95129e5e54670f1
long_hash=$(printf "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq" | $BIN | cut -d' ' -f1)
if [ "$long_hash" = "84983e441c3bd26ebaae4aa1f95129e5e54670f1" ]; then
    PASS=$((PASS+1))
    echo "[PASS] SHA1 long test vector"
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: SHA1 long test vector")
    ERRORS+=("  expected: 84983e441c3bd26ebaae4aa1f95129e5e54670f1")
    ERRORS+=("  got:      $long_hash")
fi

echo ""
echo "=== Functional Tests ==="

# ── Hash from stdin ──────────────────────────────────────────
run_test_stdin "hash hello from stdin" "hello"
run_test_stdin "hash empty line from stdin" ""
run_test_stdin "hash numbers from stdin" "1234567890"
run_test_stdin "hash multiline from stdin" "line1\nline2\nline3"
run_test_printf "hash no trailing newline" "hello"

# ── Hash from file ───────────────────────────────────────────
run_test "hash from file (hello)" "$TMPDIR/hello.txt"
run_test "hash from file (world)" "$TMPDIR/world.txt"
run_test "hash from file (empty)" "$TMPDIR/empty.txt"
run_test "hash from file (test)" "$TMPDIR/test.txt"

# ── Multiple files ───────────────────────────────────────────
run_test "multiple files" "$TMPDIR/hello.txt" "$TMPDIR/world.txt"
run_test "three files" "$TMPDIR/hello.txt" "$TMPDIR/world.txt" "$TMPDIR/test.txt"

# ── Known hash verification ─────────────────────────────────
known_hash=$(echo "hello" | $GNU | cut -d' ' -f1)
our_hash=$(echo "hello" | $BIN | cut -d' ' -f1)
if [ "$known_hash" = "$our_hash" ]; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: known hash verification")
    ERRORS+=("  expected hash: $known_hash")
    ERRORS+=("  got hash:      $our_hash")
fi

# ── -c (check mode) ─────────────────────────────────────────
run_test "-c check single file" -c "$TMPDIR/hello.sha1"
run_test "-c check multiple files" -c "$TMPDIR/multi.sha1"

# ── Binary mode flag ────────────────────────────────────────
run_test "-b binary mode" -b "$TMPDIR/hello.txt"

# ── Stdin with - ─────────────────────────────────────────────
run_test_stdin "hash with explicit - for stdin" "hello" -

# ── Results ──────────────────────────────────────────────────
echo ""
echo "Results: $PASS passed, $FAIL failed out of $((PASS+FAIL)) tests"
for e in "${ERRORS[@]}"; do echo "$e"; done
echo ""

if [ $FAIL -eq 0 ]; then
    echo "ALL TESTS PASSED"
    exit 0
else
    echo "$FAIL TESTS FAILED"
    exit 1
fi
