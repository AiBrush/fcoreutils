#!/bin/bash
# Test suite for fpwd
# Usage: bash tests/run_tests.sh ./fpwd

BIN="${1:-./fpwd}"
GNU="/usr/bin/pwd"
PASS=0
FAIL=0
ERRORS=()

# Normalize program name in output for comparison
# Replaces the binary path with "PROG" so we can compare structurally
normalize() {
    local bin_name="$1"
    sed "s|${bin_name}|PROG|g"
}

run_test() {
    local desc="$1"
    local args="$2"
    local input="$3"

    if [ -n "$input" ]; then
        expected=$(echo "$input" | $GNU $args 2>&1 | normalize "$GNU")
        got=$(echo "$input" | $BIN $args 2>&1 | normalize "$BIN")
        # Get exit codes
        echo "$input" | $GNU $args > /dev/null 2>&1
        expected_exit=$?
        echo "$input" | $BIN $args > /dev/null 2>&1
        got_exit=$?
    else
        expected=$($GNU $args 2>&1 | normalize "$GNU")
        got=$($BIN $args 2>&1 | normalize "$BIN")
        $GNU $args > /dev/null 2>&1
        expected_exit=$?
        $BIN $args > /dev/null 2>&1
        got_exit=$?
    fi

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

# Exact match test (no normalization) for specific outputs
run_exact_test() {
    local desc="$1"
    local expected="$2"
    local got="$3"
    local expected_exit="$4"
    local got_exit="$5"

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

# ── Standard flags (required for ALL tools) ──────────────────
# SKIP: --help/--version text is version-specific, tested in security_tests.py instead
#run_test "--help output"   "--help"   ""
#run_test "--version output" "--version" ""
run_test "invalid long flag" "--invalid-flag-xyz" ""
run_test "invalid short flag" "-x" ""

# ── pwd-specific tests ──────────────────────────────────────

# Basic pwd (no args) - should print current directory
expected_pwd=$($GNU 2>&1)
got_pwd=$($BIN 2>&1)
$GNU > /dev/null 2>&1; expected_exit=$?
$BIN > /dev/null 2>&1; got_exit=$?
run_exact_test "basic pwd" "$expected_pwd" "$got_pwd" "$expected_exit" "$got_exit"

# -P flag (physical)
expected_pwd=$($GNU -P 2>&1)
got_pwd=$($BIN -P 2>&1)
$GNU -P > /dev/null 2>&1; expected_exit=$?
$BIN -P > /dev/null 2>&1; got_exit=$?
run_exact_test "pwd -P" "$expected_pwd" "$got_pwd" "$expected_exit" "$got_exit"

# -L flag (logical)
expected_pwd=$($GNU -L 2>&1)
got_pwd=$($BIN -L 2>&1)
$GNU -L > /dev/null 2>&1; expected_exit=$?
$BIN -L > /dev/null 2>&1; got_exit=$?
run_exact_test "pwd -L" "$expected_pwd" "$got_pwd" "$expected_exit" "$got_exit"

# Combined flags -LP (last wins = physical)
expected_pwd=$($GNU -LP 2>&1)
got_pwd=$($BIN -LP 2>&1)
$GNU -LP > /dev/null 2>&1; expected_exit=$?
$BIN -LP > /dev/null 2>&1; got_exit=$?
run_exact_test "pwd -LP" "$expected_pwd" "$got_pwd" "$expected_exit" "$got_exit"

# Combined flags -PL (last wins = logical)
expected_pwd=$($GNU -PL 2>&1)
got_pwd=$($BIN -PL 2>&1)
$GNU -PL > /dev/null 2>&1; expected_exit=$?
$BIN -PL > /dev/null 2>&1; got_exit=$?
run_exact_test "pwd -PL" "$expected_pwd" "$got_pwd" "$expected_exit" "$got_exit"

# -- (end of options)
expected_pwd=$($GNU -- 2>&1)
got_pwd=$($BIN -- 2>&1)
$GNU -- > /dev/null 2>&1; expected_exit=$?
$BIN -- > /dev/null 2>&1; got_exit=$?
run_exact_test "pwd --" "$expected_pwd" "$got_pwd" "$expected_exit" "$got_exit"

# Combined flag with invalid -Px
run_test "combined flag with invalid -Px" "-Px" ""

# Exit code is 0 for basic usage
$BIN > /dev/null 2>&1
run_exact_test "exit code 0" "" "" "0" "$?"

# Exit code is 1 for invalid flag
$BIN --invalid-opt > /dev/null 2>&1
invalid_exit=$?
run_exact_test "exit code 1 for invalid flag" "" "" "1" "$invalid_exit"

# --logical long form
expected_pwd=$($GNU --logical 2>&1)
got_pwd=$($BIN --logical 2>&1)
$GNU --logical > /dev/null 2>&1; expected_exit=$?
$BIN --logical > /dev/null 2>&1; got_exit=$?
run_exact_test "pwd --logical" "$expected_pwd" "$got_pwd" "$expected_exit" "$got_exit"

# --physical long form
expected_pwd=$($GNU --physical 2>&1)
got_pwd=$($BIN --physical 2>&1)
$GNU --physical > /dev/null 2>&1; expected_exit=$?
$BIN --physical > /dev/null 2>&1; got_exit=$?
run_exact_test "pwd --physical" "$expected_pwd" "$got_pwd" "$expected_exit" "$got_exit"

# Non-option argument handling
run_test "non-option argument" "extra_arg" ""

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
