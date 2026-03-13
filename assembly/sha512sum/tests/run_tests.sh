#!/bin/bash
# Test suite for fsha512sum
# Usage: bash tests/run_tests.sh ./fsha512sum

BIN="${1:-./fsha512sum}"
GNU="/usr/bin/sha512sum"
TOOL="sha512sum"

PASS=0
FAIL=0
ERRORS=()

normalize_gnu() {
    sed -e "s|$GNU|PROG|g" -e "s|Usage: $TOOL|Usage: PROG|g" -e "s|^$TOOL:|PROG:|g" -e "s|^$TOOL |PROG |g"
}

normalize_our() {
    sed -e "s|$BIN|PROG|g" -e "s|Usage: $TOOL|Usage: PROG|g" -e "s|^$TOOL:|PROG:|g" -e "s|^$TOOL |PROG |g"
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
TMPDIR=$(mktemp -d /tmp/sha512_test.XXXXXX)
trap "rm -rf $TMPDIR" EXIT

printf "hello\n" > "$TMPDIR/hello.txt"
printf "world\n" > "$TMPDIR/world.txt"
echo -n "" > "$TMPDIR/empty.txt"
printf "test content\n" > "$TMPDIR/test.txt"

# Generate checksum files for -c tests
$GNU "$TMPDIR/hello.txt" > "$TMPDIR/hello.sha512"
$GNU "$TMPDIR/hello.txt" "$TMPDIR/world.txt" > "$TMPDIR/multi.sha512"

# ── Known test vectors ───────────────────────────────────────
echo "=== SHA-512 Known Test Vectors ==="

# SHA512("") = cf83e1357eefb8bdf1542850d66d8007d620e4050b5715dc83f4a921d36ce9ce47d0d13c5d85f2b0ff8318d2877eec2f63b931bd47417a81a538327af927da3e
empty_hash=$(printf "" | $BIN | cut -d' ' -f1)
if [ "$empty_hash" = "cf83e1357eefb8bdf1542850d66d8007d620e4050b5715dc83f4a921d36ce9ce47d0d13c5d85f2b0ff8318d2877eec2f63b931bd47417a81a538327af927da3e" ]; then
    PASS=$((PASS+1))
    echo "[PASS] SHA512 empty string"
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: SHA512 empty string")
    ERRORS+=("  expected: cf83e1357eefb8bdf1542850d66d8007d620e4050b5715dc83f4a921d36ce9ce47d0d13c5d85f2b0ff8318d2877eec2f63b931bd47417a81a538327af927da3e")
    ERRORS+=("  got:      $empty_hash")
fi

# SHA512("abc") = ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f
abc_hash=$(printf "abc" | $BIN | cut -d' ' -f1)
if [ "$abc_hash" = "ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f" ]; then
    PASS=$((PASS+1))
    echo "[PASS] SHA512 'abc'"
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: SHA512 'abc'")
    ERRORS+=("  expected: ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f")
    ERRORS+=("  got:      $abc_hash")
fi

# SHA512("abcdefghbcdefghicdefghijdefghijkefghijklfghijklmghijklmnhijklmnoijklmnopjklmnopqklmnopqrlmnopqrsmnopqrstnopqrstu")
# = 8e959b75dae313da8cf4f72814fc143f8f7779c6eb9f7fa17299aeadb6889018501d289e4900f7e4331b99dec4b5433ac7d329eeb6dd26545e96e55b874be909
long_hash=$(printf "abcdefghbcdefghicdefghijdefghijkefghijklfghijklmghijklmnhijklmnoijklmnopjklmnopqklmnopqrlmnopqrsmnopqrstnopqrstu" | $BIN | cut -d' ' -f1)
if [ "$long_hash" = "8e959b75dae313da8cf4f72814fc143f8f7779c6eb9f7fa17299aeadb6889018501d289e4900f7e4331b99dec4b5433ac7d329eeb6dd26545e96e55b874be909" ]; then
    PASS=$((PASS+1))
    echo "[PASS] SHA512 long test vector"
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: SHA512 long test vector")
    ERRORS+=("  expected: 8e959b75dae313da8cf4f72814fc143f8f7779c6eb9f7fa17299aeadb6889018501d289e4900f7e4331b99dec4b5433ac7d329eeb6dd26545e96e55b874be909")
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
run_test "-c check single file" -c "$TMPDIR/hello.sha512"
run_test "-c check multiple files" -c "$TMPDIR/multi.sha512"

# ── Binary mode flag ────────────────────────────────────────
run_test "-b binary mode" -b "$TMPDIR/hello.txt"

# ── Stdin with - ─────────────────────────────────────────────
run_test_stdin "hash with explicit - for stdin" "hello" -

# ── Error cases ──────────────────────────────────────────────
run_test "nonexistent file" /nonexistent/file/path

# ── Large file ───────────────────────────────────────────────
dd if=/dev/urandom of="$TMPDIR/largefile" bs=1024 count=100 2>/dev/null
run_test "100KB random file" "$TMPDIR/largefile"

# ── Binary content ───────────────────────────────────────────
printf '\x00\x01\x02\xff\xfe\xfd' > "$TMPDIR/binary.dat"
run_test "binary content" "$TMPDIR/binary.dat"

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
