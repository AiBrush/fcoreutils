#!/bin/bash
# Test suite for flogname
# Usage: bash tests/run_tests.sh ./flogname

BIN="${1:-./flogname}"
GNU="logname"
PASS=0
FAIL=0
ERRORS=()

run_test() {
    local desc="$1"
    local args="$2"
    local input="$3"

    if [ -n "$input" ]; then
        expected=$(echo "$input" | $GNU $args 2>&1)
        gnu_exit=$?
        got=$(echo "$input" | $BIN $args 2>&1)
        got_exit=$?
    else
        expected=$($GNU $args 2>&1)
        gnu_exit=$?
        got=$($BIN $args 2>&1)
        got_exit=$?
    fi

    if [ "$expected" = "$got" ] && [ "$gnu_exit" = "$got_exit" ]; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
        ERRORS+=("FAIL: $desc")
        if [ "$expected" != "$got" ]; then
            ERRORS+=("  expected output: $(echo "$expected" | head -3)")
            ERRORS+=("  got output:      $(echo "$got" | head -3)")
        fi
        if [ "$gnu_exit" != "$got_exit" ]; then
            ERRORS+=("  expected exit: $gnu_exit, got: $got_exit")
        fi
    fi
}

# ── Standard flags (required for ALL tools) ──────────────────
# SKIP: --help/--version text is version-specific, tested in security_tests.py instead
#run_test "--help output"    "--help"   ""
#run_test "--version output" "--version" ""
run_test "invalid long flag" "--invalid-flag-xyz" ""

# ── logname-specific tests ───────────────────────────────────
run_test "no arguments"       ""           ""
run_test "extra operand"      "extraarg"   ""
run_test "invalid short opt"  "-x"         ""
run_test "bare dash"          "-"          ""
run_test "double dash only"   "--"         ""
run_test "double dash + arg"  "-- extraarg" ""
run_test "double dash + help" "-- --help"  ""
run_test "short opt -h"       "-h"         ""

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
