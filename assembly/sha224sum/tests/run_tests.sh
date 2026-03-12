#!/bin/bash
# Test suite for fsha224sum
# Usage: bash tests/run_tests.sh ./fsha224sum

BIN="${1:-./fsha224sum}"
GNU="/usr/bin/sha224sum"
TOOL="sha224sum"

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
TMPDIR=$(mktemp -d /tmp/sha224_test.XXXXXX)
trap "rm -rf $TMPDIR" EXIT

printf "hello\n" > "$TMPDIR/hello.txt"
printf "world\n" > "$TMPDIR/world.txt"
echo -n "" > "$TMPDIR/empty.txt"
printf "test content\n" > "$TMPDIR/test.txt"

# Generate checksum files for -c tests
$GNU "$TMPDIR/hello.txt" > "$TMPDIR/hello.sha224"
$GNU "$TMPDIR/hello.txt" "$TMPDIR/world.txt" > "$TMPDIR/multi.sha224"

# ── Known test vectors ───────────────────────────────────────
echo "=== SHA-224 Known Test Vectors ==="

# SHA224("") = d14a028c2a3a2bc9476102bb288234c415a2b01f828ea62ac5b3e42f
empty_hash=$(printf "" | $BIN | cut -d' ' -f1)
if [ "$empty_hash" = "d14a028c2a3a2bc9476102bb288234c415a2b01f828ea62ac5b3e42f" ]; then
    PASS=$((PASS+1))
    echo "[PASS] SHA224 empty string"
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: SHA224 empty string")
    ERRORS+=("  expected: d14a028c2a3a2bc9476102bb288234c415a2b01f828ea62ac5b3e42f")
    ERRORS+=("  got:      $empty_hash")
fi

# SHA224("abc") = 23097d223405d8228642a477bda255b32aadbce4bda0b3f7e36c9da7
abc_hash=$(printf "abc" | $BIN | cut -d' ' -f1)
if [ "$abc_hash" = "23097d223405d8228642a477bda255b32aadbce4bda0b3f7e36c9da7" ]; then
    PASS=$((PASS+1))
    echo "[PASS] SHA224 'abc'"
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: SHA224 'abc'")
    ERRORS+=("  expected: 23097d223405d8228642a477bda255b32aadbce4bda0b3f7e36c9da7")
    ERRORS+=("  got:      $abc_hash")
fi

# SHA224("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq")
# = 75388b16512776cc5dba5da1fd890150b0c6455cb4f58b1952522525
long_hash=$(printf "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq" | $BIN | cut -d' ' -f1)
if [ "$long_hash" = "75388b16512776cc5dba5da1fd890150b0c6455cb4f58b1952522525" ]; then
    PASS=$((PASS+1))
    echo "[PASS] SHA224 long test vector"
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: SHA224 long test vector")
    ERRORS+=("  expected: 75388b16512776cc5dba5da1fd890150b0c6455cb4f58b1952522525")
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
run_test "-c check single file" -c "$TMPDIR/hello.sha224"
run_test "-c check multiple files" -c "$TMPDIR/multi.sha224"

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
