#!/bin/bash
# Test suite for ffactor
# Usage: bash tests/run_tests.sh ./ffactor

BIN="${1:-./ffactor}"
GNU="/usr/bin/factor"
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
        fi
        if [ "$expected_exit" != "$got_exit" ]; then
            ERRORS+=("  expected exit: $expected_exit, got: $got_exit")
        fi
    fi
}

# Test that just exit code matches (for error messages with different tool paths)
run_test_exit() {
    local desc="$1"
    shift
    local args=("$@")

    $GNU "${args[@]}" > /dev/null 2>&1
    expected_exit=$?
    $BIN "${args[@]}" > /dev/null 2>&1
    got_exit=$?

    # Also check stdout matches
    expected_out=$($GNU "${args[@]}" 2>/dev/null)
    got_out=$($BIN "${args[@]}" 2>/dev/null)

    if [ "$expected_out" = "$got_out" ] && [ "$expected_exit" = "$got_exit" ]; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
        ERRORS+=("FAIL: $desc (args: ${args[*]})")
        if [ "$expected_out" != "$got_out" ]; then
            ERRORS+=("  expected stdout: $(echo "$expected_out" | head -3)")
            ERRORS+=("  got stdout:      $(echo "$got_out" | head -3)")
        fi
        if [ "$expected_exit" != "$got_exit" ]; then
            ERRORS+=("  expected exit: $expected_exit, got: $got_exit")
        fi
    fi
}

# Test with stdin input (uses $'...' syntax for literal input)
run_test_stdin() {
    local desc="$1"
    local input="$2"

    expected=$(echo "$input" | $GNU 2>&1)
    got=$(echo "$input" | $BIN 2>&1)

    echo "$input" | $GNU > /dev/null 2>&1
    expected_exit=$?
    echo "$input" | $BIN > /dev/null 2>&1
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

echo "=== ffactor test suite ==="
echo ""

# ── Basic numbers ──
echo "--- Basic numbers ---"
run_test "factor 0"              0
run_test "factor 1"              1
run_test "factor 2"              2
run_test "factor 3"              3
run_test "factor 4"              4
run_test "factor 5"              5
run_test "factor 6"              6
run_test "factor 7"              7
run_test "factor 8"              8
run_test "factor 9"              9
run_test "factor 10"             10
run_test "factor 11"             11
run_test "factor 12"             12
run_test "factor 13"             13

# ── Primes ──
echo "--- Primes ---"
run_test "factor 17"             17
run_test "factor 97"             97
run_test "factor 997"            997
run_test "factor 7919"           7919
run_test "factor 999999937"      999999937
run_test "factor 1000000007"     1000000007

# ── Composites ──
echo "--- Composites ---"
run_test "factor 15"             15
run_test "factor 28"             28
run_test "factor 42"             42
run_test "factor 100"            100
run_test "factor 144"            144
run_test "factor 360"            360
run_test "factor 1000"           1000
run_test "factor 9999"           9999
run_test "factor 99999"          99999

# ── Powers of 2 ──
echo "--- Powers of 2 ---"
run_test "factor 1024"           1024
run_test "factor 65536"          65536
run_test "factor 1073741824"     1073741824
run_test "factor 4294967296"     4294967296

# ── Perfect powers ──
echo "--- Perfect powers ---"
run_test "factor 27"             27
run_test "factor 81"             81
run_test "factor 125"            125
run_test "factor 256"            256
run_test "factor 625"            625
run_test "factor 2187"           2187

# ── Large numbers ──
echo "--- Large numbers ---"
run_test "factor 2147483647"     2147483647
run_test "factor 4294967295"     4294967295
run_test "factor 9223372036854775807" 9223372036854775807
run_test "factor 18446744073709551615" 18446744073709551615
run_test "factor 18446744073709551614" 18446744073709551614
run_test "factor 18446744073709551613" 18446744073709551613

# ── Large primes ──
echo "--- Large primes ---"
run_test "factor 999999999999999877" 999999999999999877
run_test "factor 999999999999999613" 999999999999999613
run_test "factor 1000000000000000003" 1000000000000000003

# ── Multiple arguments ──
echo "--- Multiple arguments ---"
run_test "factor 6 15 28"        6 15 28
run_test "factor 2 3 5 7 11"    2 3 5 7 11
run_test "factor 100 200 300"    100 200 300

# ── Leading + prefix (GNU compat) ──
echo "--- Leading + prefix ---"
run_test "factor +12"            +12
run_test "factor +0"             +0
run_test "factor +1"             +1
run_test "factor +100"           +100

# ── Leading zeros ──
echo "--- Leading zeros ---"
run_test "factor 012"            012
run_test "factor 0012"           0012
run_test "factor 00"             00

# ── Invalid input (exit code + stdout check) ──
echo "--- Invalid input ---"
run_test_exit "factor abc"            abc
run_test_exit "factor -1 via --"      -- -1
run_test_exit "factor mixed"          12 abc 15

# ── Overflow (> 2^64-1) — our assembly only supports 64-bit ──
# GNU factor handles these via GMP, we report as invalid
echo "--- Overflow (known limitation: > 2^64-1) ---"
# Just verify we don't crash and exit non-zero
$BIN 18446744073709551616 > /dev/null 2>&1
ov_exit=$?
if [ $ov_exit -ne 0 ]; then PASS=$((PASS+1)); echo "  OK: overflow exits non-zero"; else FAIL=$((FAIL+1)); ERRORS+=("FAIL: overflow should exit non-zero"); fi
$BIN 99999999999999999999 > /dev/null 2>&1
ov_exit=$?
if [ $ov_exit -ne 0 ]; then PASS=$((PASS+1)); echo "  OK: huge overflow exits non-zero"; else FAIL=$((FAIL+1)); ERRORS+=("FAIL: huge overflow should exit non-zero"); fi

# ── Stdin input ──
echo "--- Stdin ---"
run_test_stdin "stdin single"         "42"
run_test_stdin "stdin multi-line"     "12
15
28"
run_test_stdin "stdin spaces"         "12 15 28"
run_test_stdin "stdin tabs"           "12	15"
run_test_stdin "stdin leading spaces" "  12
  15  "
run_test_stdin "stdin empty"          ""
run_test_stdin "stdin 0"              "0"
run_test_stdin "stdin 1"              "1"

# ── Help/version (just check exit code + non-empty output) ──
echo "--- Help/version ---"
$BIN --help > /dev/null 2>&1
if [ $? -eq 0 ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); ERRORS+=("FAIL: --help exit code"); fi

$BIN --version > /dev/null 2>&1
if [ $? -eq 0 ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); ERRORS+=("FAIL: --version exit code"); fi

# ── Bulk test: 1-10000 ──
echo "--- Bulk test: 1-10000 ---"
expected=$(seq 1 10000 | $GNU)
got=$(seq 1 10000 | $BIN)
if [ "$expected" = "$got" ]; then
    PASS=$((PASS+1))
    echo "  OK: 1-10000 bulk match"
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: bulk 1-10000 mismatch")
    diff <(echo "$expected") <(echo "$got") | head -10
fi

# ── Summary ──
echo ""
echo "=== Results ==="
TOTAL=$((PASS+FAIL))
echo "Passed: $PASS/$TOTAL"

if [ ${#ERRORS[@]} -gt 0 ]; then
    echo ""
    echo "Failures:"
    for err in "${ERRORS[@]}"; do
        echo "  $err"
    done
fi

if [ "$FAIL" -gt 0 ]; then
    exit 1
else
    echo "All tests passed!"
    exit 0
fi
