#!/bin/bash
# Test suite for fseq
# Usage: bash tests/run_tests.sh ./fseq

BIN="${1:-./fseq}"
GNU="/usr/bin/seq"
PASS=0
FAIL=0
ERRORS=()

run_test() {
    local desc="$1"
    shift
    local args=("$@")

    expected=$($GNU "${args[@]}" 2>&1)
    got=$($BIN "${args[@]}" 2>&1)

    $GNU "${args[@]}" > /dev/null 2>&1
    expected_exit=$?
    $BIN "${args[@]}" > /dev/null 2>&1
    got_exit=$?

    if [ "$expected" = "$got" ] && [ "$expected_exit" = "$got_exit" ]; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
        ERRORS+=("FAIL: $desc (args: ${args[*]})")
        if [ "$expected" != "$got" ]; then
            ERRORS+=("  expected output: $(echo "$expected" | head -3)")
            ERRORS+=("  got output:      $(echo "$got" | head -3)")
            exp_lines=$(echo "$expected" | wc -l)
            got_lines=$(echo "$got" | wc -l)
            if [ "$exp_lines" != "$got_lines" ]; then
                ERRORS+=("  expected lines: $exp_lines, got lines: $got_lines")
            fi
        fi
        if [ "$expected_exit" != "$got_exit" ]; then
            ERRORS+=("  expected exit: $expected_exit, got: $got_exit")
        fi
    fi
}

# Normalize help text (GNU uses full path, we use "seq")
run_test_help() {
    local desc="$1"
    shift
    local args=("$@")

    expected=$($GNU "${args[@]}" 2>&1 | sed 's|[^ ]*/seq|seq|g')
    got=$($BIN "${args[@]}" 2>&1 | sed 's|[^ ]*/seq|seq|g')

    $GNU "${args[@]}" > /dev/null 2>&1
    expected_exit=$?
    $BIN "${args[@]}" > /dev/null 2>&1
    got_exit=$?

    if [ "$expected" = "$got" ] && [ "$expected_exit" = "$got_exit" ]; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
        ERRORS+=("FAIL: $desc")
        if [ "$expected" != "$got" ]; then
            ERRORS+=("  expected: $(echo "$expected" | head -3)")
            ERRORS+=("  got:      $(echo "$got" | head -3)")
        fi
        if [ "$expected_exit" != "$got_exit" ]; then
            ERRORS+=("  expected exit: $expected_exit, got: $got_exit")
        fi
    fi
}

# Test that output matches but error text is normalized
run_test_err() {
    local desc="$1"
    shift
    local args=("$@")

    $GNU "${args[@]}" > /dev/null 2>&1
    expected_exit=$?
    $BIN "${args[@]}" > /dev/null 2>&1
    got_exit=$?

    if [ "$expected_exit" = "$got_exit" ]; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
        ERRORS+=("FAIL: $desc (exit code mismatch)")
        ERRORS+=("  expected exit: $expected_exit, got: $got_exit")
    fi
}

echo "=== fseq test suite ==="
echo ""

# ── Basic integer sequences ──
run_test "seq 5"                5
run_test "seq 1"                1
run_test "seq 0"                0
run_test "seq 3 7"              3 7
run_test "seq 1 2 10"           1 2 10
run_test "seq 1 2 9"            1 2 9
run_test "seq 10 -1 7"          10 -1 7
run_test "seq 10 -2 1"          10 -2 1
run_test "seq 0 3"              0 3
run_test "seq 1 1"              1 1
run_test "seq 0 0"              0 0
run_test "seq 1 100"            1 100
run_test "seq 100 -1 1"         100 -1 1

# ── Negative numbers ──
run_test "seq -3 -1"            -- -3 -1
run_test "seq -5 -1"            -- -5 -1
run_test "seq -10 -2 -2"        -- -10 -2 -2
run_test "seq -1 1"             -- -1 1
run_test "seq 5 -1 -5"          5 -1 -5

# ── Empty ranges ──
run_test "empty: seq 5 1"       5 1
run_test "empty: seq -1 -5"     -- -1 -5
run_test "empty: seq 1 -1 5"    1 -1 5

# ── -w (equal width) ──
run_test "-w 1 10"              -w 1 10
run_test "-w 8 10"              -w 8 10
run_test "-w 1 100"             -w 1 100
run_test "-w 998 1000"          -w 998 1000
run_test "-w 1 1"               -w 1 1
run_test "-w -1 1"              -w -- -1 1

# ── -s (separator) ──
run_test "-s, 1 5"              -s, 1 5
run_test "-s ' ' 1 5"           -s ' ' 1 5
run_test "-s ' + ' 1 4"         -s ' + ' 1 4
run_test "-s tab"               -s '	' 1 3

# ── -f (format) ──
run_test "-f %03g 1 5"          -f '%03g' 1 5
run_test "-f %g 1 5"            -f '%g' 1 5
run_test "-f %f 1 3"            -f '%f' 1 3
run_test "-f %.2e 1 3"          -f '%.2e' 1 3
run_test "-f %10g 1 3"          -f '%10g' 1 3

# ── Float sequences ──
run_test "float 0.1 0.1 0.5"    0.1 0.1 0.5
run_test "float 0.1 0.1 1.0"    0.1 0.1 1.0
run_test "float 1.0 3"          1.0 3
run_test "float -1.5 0.5 1.5"   -- -1.5 0.5 1.5
run_test "float 1.00 1.00 3.00" 1.00 1.00 3.00

# ── Hex input ──
run_test "hex 0x10"             0x10
run_test "hex 0xa"              0xa

# ── Error cases (just check exit code) ──
run_test_err "no args"
run_test_err "too many args"       1 2 3 4
run_test_err "invalid arg"         abc
run_test_err "zero increment"      1 0 5

# ── --help/--version (check exit code and non-empty output) ──
out=$($BIN --help 2>&1)
if [ $? -eq 0 ] && [ -n "$out" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); ERRORS+=("FAIL: --help"); fi
out=$($BIN --version 2>&1)
if [ $? -eq 0 ] && [ -n "$out" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); ERRORS+=("FAIL: --version"); fi

# ── Large sequences (just check line count) ──
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
for e in "${ERRORS[@]}"; do echo "$e"; done
echo ""

if [ $FAIL -eq 0 ]; then
    echo "ALL TESTS PASSED"
    exit 0
else
    echo "$FAIL TESTS FAILED"
    exit 1
fi
