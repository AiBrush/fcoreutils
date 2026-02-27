#!/bin/bash
# Test suite for frev
# Usage: bash tests/run_tests.sh ./frev
# Note: GNU rev is from util-linux, not coreutils

BIN="${1:-./frev}"
GNU="/usr/bin/rev"
TOOL="rev"

PASS=0
FAIL=0
ERRORS=()

# rev (util-linux) uses " rev [options]" in help and "rev from util-linux" in version
normalize_gnu() {
    sed -e "s|$GNU|PROG|g" -e "s| $TOOL | PROG |g" -e "s| $TOOL\$| PROG|g"
}

normalize_our() {
    sed -e "s|$BIN|PROG|g" -e "s| $TOOL | PROG |g" -e "s| $TOOL\$| PROG|g"
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

# ── Setup temp files ─────────────────────────────────────────
TMPDIR=$(mktemp -d /tmp/rev_test.XXXXXX)
trap "rm -rf $TMPDIR" EXIT

printf "hello\nworld\n" > "$TMPDIR/basic.txt"
printf "abcdef\n" > "$TMPDIR/single.txt"
echo -n "" > "$TMPDIR/empty.txt"

# ── Standard flags (util-linux uses -h and -V) ──────────────
run_test "--help output (-h)" -h
run_test "--version output (-V)" -V

# ── Basic reverse ────────────────────────────────────────────
run_test_stdin "basic reverse single word" "hello"
run_test_stdin "basic reverse with spaces" "hello world"
run_test_stdin "reverse digits" "12345"

# ── Empty line ───────────────────────────────────────────────
run_test_stdin "empty line" ""

# ── Single character ─────────────────────────────────────────
run_test_stdin "single char" "a"
run_test_stdin "single space" " "

# ── Multiple lines ───────────────────────────────────────────
run_test_stdin "multiple lines" "hello\nworld\nfoo"
run_test_stdin "multiple lines with spaces" "hello world\nfoo bar\nbaz qux"
run_test_stdin "lines of different lengths" "a\nbb\nccc\ndddd"

# ── File argument ────────────────────────────────────────────
run_test "file argument (basic)" "$TMPDIR/basic.txt"
run_test "file argument (single line)" "$TMPDIR/single.txt"
run_test "file argument (empty)" "$TMPDIR/empty.txt"

# ── Special characters ──────────────────────────────────────
run_test_stdin "tabs" "a\tb\tc"
run_test_stdin "punctuation" "hello, world!"
run_test_stdin "numbers and symbols" "abc123!@#"

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
