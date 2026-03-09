#!/bin/bash
# GNU compatibility tests for fseq (assembly)
# Compares byte-for-byte stdout and exit code against GNU seq
# Usage: bash test_fseq.sh [path-to-fseq]

BIN="${1:-../seq/fseq}"
GNU="/usr/bin/seq"

PASS=0
FAIL=0
ERRORS=()

TMPDIR=$(mktemp -d /tmp/test_fseq.XXXXXX)
trap "rm -rf $TMPDIR" EXIT

run_test() {
    local desc="$1"
    shift
    local args=("$@")

    $GNU "${args[@]}" > "$TMPDIR/expected" 2> "$TMPDIR/expected_err"
    local expected_exit=$?
    $BIN "${args[@]}" > "$TMPDIR/got" 2> "$TMPDIR/got_err"
    local got_exit=$?

    if diff -q "$TMPDIR/expected" "$TMPDIR/got" > /dev/null 2>&1 && \
       [ "$expected_exit" = "$got_exit" ]; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
        ERRORS+=("FAIL: $desc (args: ${args[*]})")
        if ! diff -q "$TMPDIR/expected" "$TMPDIR/got" > /dev/null 2>&1; then
            ERRORS+=("  expected first 3 lines: $(head -3 "$TMPDIR/expected")")
            ERRORS+=("  got first 3 lines:      $(head -3 "$TMPDIR/got")")
            local exp_lines=$(wc -l < "$TMPDIR/expected")
            local got_lines=$(wc -l < "$TMPDIR/got")
            if [ "$exp_lines" != "$got_lines" ]; then
                ERRORS+=("  expected lines: $exp_lines, got lines: $got_lines")
            fi
        fi
        if [ "$expected_exit" != "$got_exit" ]; then
            ERRORS+=("  expected exit: $expected_exit, got: $got_exit")
        fi
    fi
}

# Just check exit codes for error cases
run_test_err() {
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
        ERRORS+=("FAIL: $desc (expected exit: $expected_exit, got: $got_exit)")
    fi
}

echo "=== fseq GNU compatibility tests ==="
echo ""

# ── Basic ranges ──
echo "-- Basic integer sequences --"
run_test "seq 1 10" 1 10
run_test "seq 1 100" 1 100
run_test "seq 1 1000" 1 1000
run_test "seq 1 10000" 1 10000
run_test "seq 5 15" 5 15
run_test "seq 5" 5
run_test "seq 1" 1
run_test "seq 0" 0

# ── Decade boundaries ──
echo "-- Decade boundaries --"
run_test "seq 98 102" 98 102
run_test "seq 999 1001" 999 1001
run_test "seq 9999 10001" 9999 10001

# ── Negative to positive ──
echo "-- Negative numbers --"
run_test "seq -5 5" -- -5 5
run_test "seq -3 -1" -- -3 -1
run_test "seq -1 1" -- -1 1
run_test "seq -10 -2 -2" -- -10 -2 -2

# ── Countdown ──
echo "-- Countdown --"
run_test "seq 10 -1 1" 10 -1 1
run_test "seq 100 -1 1" 100 -1 1
run_test "seq 5 -1 -5" 5 -1 -5

# ── Equal width (-w) ──
echo "-- Equal width --"
run_test "seq -w 1 10" -w 1 10
run_test "seq -w 1 100" -w 1 100
run_test "seq -w 998 1000" -w 998 1000
run_test "seq -w 8 10" -w 8 10

# ── Custom separator (-s) ──
echo "-- Custom separator --"
run_test "seq -s, 1 5" -s, 1 5
run_test "seq -s ' ' 1 5" -s ' ' 1 5
run_test "seq -s ' + ' 1 4" -s ' + ' 1 4

# ── Float sequences ──
echo "-- Float sequences --"
run_test "seq 0.5 0.5 3.0" 0.5 0.5 3.0
run_test "seq 0.1 0.1 0.5" 0.1 0.1 0.5
run_test "seq 0.1 0.1 1.0" 0.1 0.1 1.0
run_test "seq 1.0 3" 1.0 3
run_test "seq 1.00 1.00 3.00" 1.00 1.00 3.00

# ── Empty range (no output) ──
echo "-- Empty ranges --"
run_test "seq 1 0 (empty)" 1 0
run_test "seq 5 1 (empty)" 5 1
run_test "seq -1 -5 (empty)" -- -1 -5
run_test "seq 1 -1 5 (empty)" 1 -1 5

# ── Format (-f) ──
echo "-- Format --"
run_test "seq -f %03g 1 5" -f '%03g' 1 5
run_test "seq -f %g 1 5" -f '%g' 1 5
run_test "seq -f %f 1 3" -f '%f' 1 3

# ── Error cases ──
echo "-- Error cases --"
run_test_err "no args"
run_test_err "too many args" 1 2 3 4
run_test_err "invalid arg" abc
run_test_err "zero increment" 1 0 5

# ── Large sequence line count check ──
echo "-- Large sequence --"
expected_lines=$($GNU 1 10000 | wc -l)
got_lines=$($BIN 1 10000 | wc -l)
if [ "$expected_lines" = "$got_lines" ]; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: seq 1 10000 line count (expected $expected_lines, got $got_lines)")
fi

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
