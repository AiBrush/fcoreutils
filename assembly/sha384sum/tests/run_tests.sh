#!/bin/bash
# Test suite for fsha384sum
# Usage: bash tests/run_tests.sh ./fsha384sum

BIN="${1:-./fsha384sum}"
GNU="/usr/bin/sha384sum"
TOOL="sha384sum"

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
TMPDIR=$(mktemp -d /tmp/sha384_test.XXXXXX)
trap "rm -rf $TMPDIR" EXIT

printf "hello\n" > "$TMPDIR/hello.txt"
printf "world\n" > "$TMPDIR/world.txt"
echo -n "" > "$TMPDIR/empty.txt"
printf "test content\n" > "$TMPDIR/test.txt"

# Generate checksum files for -c tests
$GNU "$TMPDIR/hello.txt" > "$TMPDIR/hello.sha384"
$GNU "$TMPDIR/hello.txt" "$TMPDIR/world.txt" > "$TMPDIR/multi.sha384"

# ── Known test vectors ───────────────────────────────────────
echo "=== SHA-384 Known Test Vectors ==="

# SHA384("") = 38b060a751ac96384cd9327eb1b1e36a21fdb71114be07434c0cc7bf63f6e1da274edebfe76f65fbd51ad2f14898b95b
empty_hash=$(printf "" | $BIN | cut -d' ' -f1)
if [ "$empty_hash" = "38b060a751ac96384cd9327eb1b1e36a21fdb71114be07434c0cc7bf63f6e1da274edebfe76f65fbd51ad2f14898b95b" ]; then
    PASS=$((PASS+1))
    echo "[PASS] SHA384 empty string"
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: SHA384 empty string")
    ERRORS+=("  expected: 38b060a751ac96384cd9327eb1b1e36a21fdb71114be07434c0cc7bf63f6e1da274edebfe76f65fbd51ad2f14898b95b")
    ERRORS+=("  got:      $empty_hash")
fi

# SHA384("abc") = cb00753f45a35e8bb5a03d699ac65007272c32ab0eded1631a8b605a43ff5bed8086072ba1e7cc2358baeca134c825a7
abc_hash=$(printf "abc" | $BIN | cut -d' ' -f1)
if [ "$abc_hash" = "cb00753f45a35e8bb5a03d699ac65007272c32ab0eded1631a8b605a43ff5bed8086072ba1e7cc2358baeca134c825a7" ]; then
    PASS=$((PASS+1))
    echo "[PASS] SHA384 'abc'"
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: SHA384 'abc'")
    ERRORS+=("  expected: cb00753f45a35e8bb5a03d699ac65007272c32ab0eded1631a8b605a43ff5bed8086072ba1e7cc2358baeca134c825a7")
    ERRORS+=("  got:      $abc_hash")
fi

# SHA384("abcdefghbcdefghicdefghijdefghijkefghijklfghijklmghijklmnhijklmnoijklmnopjklmnopqklmnopqrlmnopqrsmnopqrstnopqrstu")
# = 09330c33f71147e83d192fc782cd1b4753111b173b3b05d22fa08086e3b0f712fcc7c71a557e2db966c3e9fa91746039
long_hash=$(printf "abcdefghbcdefghicdefghijdefghijkefghijklfghijklmghijklmnhijklmnoijklmnopjklmnopqklmnopqrlmnopqrsmnopqrstnopqrstu" | $BIN | cut -d' ' -f1)
if [ "$long_hash" = "09330c33f71147e83d192fc782cd1b4753111b173b3b05d22fa08086e3b0f712fcc7c71a557e2db966c3e9fa91746039" ]; then
    PASS=$((PASS+1))
    echo "[PASS] SHA384 long test vector"
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: SHA384 long test vector")
    ERRORS+=("  expected: 09330c33f71147e83d192fc782cd1b4753111b173b3b05d22fa08086e3b0f712fcc7c71a557e2db966c3e9fa91746039")
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
run_test "-c check single file" -c "$TMPDIR/hello.sha384"
run_test "-c check multiple files" -c "$TMPDIR/multi.sha384"

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
