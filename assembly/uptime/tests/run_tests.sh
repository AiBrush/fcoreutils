#!/bin/bash
# Test suite for fuptime
# Usage: bash tests/run_tests.sh [./fuptime]

BIN="${1:-./fuptime}"
GNU="uptime"
PASS=0
FAIL=0
ERRORS=()

run_test() {
    local desc="$1"
    local args="$2"

    expected=$($GNU $args 2>&1)
    got=$($BIN $args 2>&1)

    $GNU $args > /dev/null 2>&1
    expected_exit=$?

    $BIN $args > /dev/null 2>&1
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

# Compare outputs structurally (allowing minor time drift)
run_fuzzy_test() {
    local desc="$1"
    local args="$2"

    expected=$($GNU $args 2>&1)
    got=$($BIN $args 2>&1)

    $GNU $args > /dev/null 2>&1
    expected_exit=$?

    $BIN $args > /dev/null 2>&1
    got_exit=$?

    # For normal mode: compare format structure
    # Strip the timestamp and load averages for structural comparison
    # Just check exit code and that output has the right shape
    if [ "$expected_exit" != "$got_exit" ]; then
        FAIL=$((FAIL+1))
        ERRORS+=("FAIL: $desc (exit code)")
        ERRORS+=("  expected exit: $expected_exit, got: $got_exit")
        return
    fi

    # For empty args: check format " HH:MM:SS up ..."
    if [ -z "$args" ]; then
        if echo "$got" | grep -qP '^ \d{2}:\d{2}:\d{2} up .+user.+load average:'; then
            PASS=$((PASS+1))
        else
            FAIL=$((FAIL+1))
            ERRORS+=("FAIL: $desc (format mismatch)")
            ERRORS+=("  got: $got")
        fi
        return
    fi

    # For since mode: allow ±2 second drift (race between GNU and ASM invocations)
    if echo "$desc" | grep -qi "since"; then
        exp_epoch=$(date -d "$expected" +%s 2>/dev/null || echo "0")
        got_epoch=$(date -d "$got" +%s 2>/dev/null || echo "0")
        diff_secs=$(( exp_epoch - got_epoch ))
        if [ "$diff_secs" -lt 0 ]; then diff_secs=$(( -diff_secs )); fi
        if [ "$diff_secs" -le 2 ]; then
            PASS=$((PASS+1))
        else
            FAIL=$((FAIL+1))
            ERRORS+=("FAIL: $desc")
            ERRORS+=("  expected: $(echo "$expected" | head -3)")
            ERRORS+=("  got:      $(echo "$got" | head -3)")
        fi
        return
    fi

    # For other cases, try exact match
    if [ "$expected" = "$got" ]; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
        ERRORS+=("FAIL: $desc")
        ERRORS+=("  expected: $(echo "$expected" | head -3)")
        ERRORS+=("  got:      $(echo "$got" | head -3)")
    fi
}

# ── Option tests ─────────────────────────────────────────────
echo "Testing fuptime..."

# Normal output format check
run_fuzzy_test "normal output format" ""

# Pretty mode
run_fuzzy_test "pretty mode -p" "-p"
run_fuzzy_test "pretty mode --pretty" "--pretty"

# Since mode
run_fuzzy_test "since mode -s" "-s"
run_fuzzy_test "since mode --since" "--since"

# Version
run_test "version -V" "-V"
run_test "version --version" "--version"

# Help
run_test "help -h" "-h"
run_test "help --help" "--help"

# Error cases
run_test "invalid option -x" "-x"
run_test "invalid option -z" "-z"
run_test "invalid option --bogus" "--bogus"

# Exit codes
echo "Checking exit codes..."
$BIN > /dev/null 2>&1; ec=$?
if [ "$ec" = "0" ]; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: normal exit code should be 0, got $ec")
fi

$BIN -x > /dev/null 2>&1; ec=$?
if [ "$ec" = "1" ]; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: error exit code should be 1, got $ec")
fi

$BIN --help > /dev/null 2>&1; ec=$?
if [ "$ec" = "0" ]; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: --help exit code should be 0, got $ec")
fi

$BIN --version > /dev/null 2>&1; ec=$?
if [ "$ec" = "0" ]; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: --version exit code should be 0, got $ec")
fi

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
