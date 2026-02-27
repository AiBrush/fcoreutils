#!/bin/bash
# Test suite for ftac
# Usage: bash tests/run_tests.sh ./ftac

BIN="${1:-./ftac}"
GNU="/usr/bin/tac"
TOOL="tac"

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
TMPDIR=$(mktemp -d /tmp/tac_test.XXXXXX)
trap "rm -rf $TMPDIR" EXIT

printf "line1\nline2\nline3\n" > "$TMPDIR/three.txt"
printf "line1\nline2\nline3\nline4\nline5\n" > "$TMPDIR/five.txt"
echo -n "" > "$TMPDIR/empty.txt"
echo "oneline" > "$TMPDIR/single.txt"

# ── Standard flags ───────────────────────────────────────────
# SKIP: --help/--version text is version-specific, tested in security_tests.py instead
#run_test "--help output" --help
#run_test "--version output" --version

# ── Basic reverse (stdin) ────────────────────────────────────
run_test_stdin "basic reverse 3 lines" "line1\nline2\nline3"
run_test_stdin "basic reverse 5 lines" "1\n2\n3\n4\n5"
run_test_stdin "reverse with varying lengths" "short\na much longer line here\nmed"

# ── Single line ──────────────────────────────────────────────
run_test_stdin "single line" "hello"
run_test_stdin "single line with trailing content" "hello\n"

# ── Empty input ──────────────────────────────────────────────
run_test_printf "empty input" ""
run_test "empty file" "$TMPDIR/empty.txt"

# ── Multiple lines ───────────────────────────────────────────
run_test_stdin "10 lines" "1\n2\n3\n4\n5\n6\n7\n8\n9\n10"
run_test_stdin "lines with spaces" "hello world\nfoo bar\nbaz qux"

# ── File arguments ───────────────────────────────────────────
run_test "file argument (3 lines)" "$TMPDIR/three.txt"
run_test "file argument (5 lines)" "$TMPDIR/five.txt"
run_test "single line file" "$TMPDIR/single.txt"

# ── Multiple file arguments ──────────────────────────────────
run_test "multiple files" "$TMPDIR/three.txt" "$TMPDIR/five.txt"

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
