#!/bin/bash
# Test suite for fwhoami
# Usage: bash tests/run_tests.sh ./fwhoami

BIN="${1:-./fwhoami}"
GNU="whoami"
PASS=0
FAIL=0
ERRORS=()

run_test() {
    local desc="$1"
    local args="$2"
    local input="$3"

    if [ -n "$input" ]; then
        expected=$(echo "$input" | $GNU $args 2>&1)
        got=$(echo "$input" | $BIN $args 2>&1)
    else
        expected=$($GNU $args 2>&1)
        got=$($BIN $args 2>&1)
    fi

    # Capture exit codes separately
    if [ -n "$input" ]; then
        echo "$input" | $GNU $args > /dev/null 2>&1
        expected_exit=$?
        echo "$input" | $BIN $args > /dev/null 2>&1
        got_exit=$?
    else
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

# ── Standard flags (required for ALL tools) ──────────────────
run_test "--help output"   "--help"   ""
run_test "--version output" "--version" ""
run_test "invalid flag"    "--invalid-flag-xyz" ""

# ── Tool-specific tests ──────────────────────────────────────
run_test "basic whoami"    ""          ""
run_test "extra operand"   "extra"     ""
run_test "extra operand quoted" "hello world" ""

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
