#!/bin/bash
# Test suite for ftail
# Usage: bash tests/run_tests.sh ./ftail

BIN="${1:-./ftail}"
GNU="/usr/bin/tail"
TOOL="tail"

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

# ── Setup temp files ─────────────────────────────────────────
TMPDIR=$(mktemp -d /tmp/tail_test.XXXXXX)
trap "rm -rf $TMPDIR" EXIT

seq 1 20 > "$TMPDIR/twenty.txt"
seq 1 5 > "$TMPDIR/five.txt"
echo -n "" > "$TMPDIR/empty.txt"
echo "oneline" > "$TMPDIR/single.txt"

# ── Standard flags ───────────────────────────────────────────
# SKIP: --help/--version text is version-specific, tested in security_tests.py instead
#run_test "--help output" --help
#run_test "--version output" --version

# ── Default behavior (last 10 lines from stdin) ─────────────
run_test_stdin "default 10 lines from stdin" "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n13\n14\n15"

# ── -n option ────────────────────────────────────────────────
run_test_stdin "-n 5 (last 5 lines)" "1\n2\n3\n4\n5\n6\n7\n8\n9\n10" -n 5
run_test_stdin "-n 1 (last line)" "hello\nworld" -n 1
run_test_stdin "-n +3 (from line 3)" "1\n2\n3\n4\n5\n6\n7\n8\n9\n10" -n +3
run_test_stdin "-n +1 (all lines)" "hello\nworld\nfoo" -n +1

# ── -c option (bytes) ───────────────────────────────────────
run_test_stdin "-c 10 (last 10 bytes)" "hello world\nsecond line" -c 10
run_test_stdin "-c 5 (last 5 bytes)" "abcdefghij" -c 5

# ── File arguments ───────────────────────────────────────────
run_test "file argument (20 lines)" "$TMPDIR/twenty.txt"
run_test "file argument -n 3" -n 3 "$TMPDIR/twenty.txt"
run_test "file argument (5 lines)" "$TMPDIR/five.txt"

# ── Multiple files ───────────────────────────────────────────
run_test "multiple files" "$TMPDIR/five.txt" "$TMPDIR/twenty.txt"
run_test "multiple files -n 2" -n 2 "$TMPDIR/five.txt" "$TMPDIR/twenty.txt"

# ── Empty input ──────────────────────────────────────────────
run_test_stdin "empty stdin" ""
run_test "empty file" "$TMPDIR/empty.txt"

# ── Single line input ────────────────────────────────────────
run_test_stdin "single line stdin" "hello"
run_test "single line file" "$TMPDIR/single.txt"

# ── Quiet and verbose headers ────────────────────────────────
run_test "-q with multiple files" -q "$TMPDIR/five.txt" "$TMPDIR/twenty.txt"
run_test "-v with single file" -v "$TMPDIR/five.txt"

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
