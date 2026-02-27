#!/bin/bash
# Test suite for fsleep
# Usage: bash tests/run_tests.sh ./fsleep

BIN="${1:-./fsleep}"
GNU="sleep"
PASS=0
FAIL=0
ERRORS=()

run_test() {
    local desc="$1"
    local args="$2"
    local input="$3"
    local timeout_val="${4:-10}"

    if [ -n "$input" ]; then
        expected=$(echo "$input" | timeout "$timeout_val" $GNU $args 2>&1)
        expected_exit=$?
        got=$(echo "$input" | timeout "$timeout_val" $BIN $args 2>&1)
        got_exit=$?
    else
        expected=$(timeout "$timeout_val" $GNU $args 2>&1)
        expected_exit=$?
        got=$(timeout "$timeout_val" $BIN $args 2>&1)
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

# Special test for timing-sensitive operations
run_timed_test() {
    local desc="$1"
    local args="$2"
    local max_ms="$3"

    local start_ns=$(date +%s%N)
    timeout 5 $BIN $args > /dev/null 2>&1
    local exit_code=$?
    local end_ns=$(date +%s%N)
    local elapsed_ms=$(( (end_ns - start_ns) / 1000000 ))

    if [ "$exit_code" = "0" ] && [ "$elapsed_ms" -lt "$max_ms" ]; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
        ERRORS+=("FAIL: $desc")
        if [ "$exit_code" != "0" ]; then
            ERRORS+=("  expected exit: 0, got: $exit_code")
        fi
        if [ "$elapsed_ms" -ge "$max_ms" ]; then
            ERRORS+=("  elapsed: ${elapsed_ms}ms >= ${max_ms}ms")
        fi
    fi
}

run_sleep_duration_test() {
    local desc="$1"
    local args="$2"
    local min_ms="$3"
    local max_ms="$4"

    local start_ns=$(date +%s%N)
    timeout 10 $BIN $args > /dev/null 2>&1
    local exit_code=$?
    local end_ns=$(date +%s%N)
    local elapsed_ms=$(( (end_ns - start_ns) / 1000000 ))

    if [ "$exit_code" = "0" ] && [ "$elapsed_ms" -ge "$min_ms" ] && [ "$elapsed_ms" -lt "$max_ms" ]; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
        ERRORS+=("FAIL: $desc")
        if [ "$exit_code" != "0" ]; then
            ERRORS+=("  expected exit: 0, got: $exit_code")
        fi
        ERRORS+=("  elapsed: ${elapsed_ms}ms (expected ${min_ms}-${max_ms}ms)")
    fi
}

# ── Standard flags (required for ALL tools) ──────────────────
# SKIP: --help/--version text is version-specific, tested in security_tests.py instead
#run_test "--help output"    "--help"    ""
#run_test "--version output" "--version" ""

# ── Error cases ──────────────────────────────────────────────
run_test "no arguments"     ""          ""
run_test "invalid arg"      "abc"       ""
# Empty string test — uses direct quoting to pass actual empty string
desc="empty string arg"
expected=$(timeout 10 $GNU "" 2>&1)
expected_exit=$?
got=$(timeout 10 $BIN "" 2>&1)
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

# ── Basic functionality ──────────────────────────────────────
run_timed_test "sleep 0"        "0"         500
run_timed_test "sleep 0s"       "0s"        500
run_timed_test "sleep 0m"       "0m"        500
run_timed_test "sleep 0h"       "0h"        500
run_timed_test "sleep 0d"       "0d"        500

# ── Float handling ───────────────────────────────────────────
run_timed_test "sleep 0.0"      "0.0"       500
run_timed_test "sleep 0.001"    "0.001"     500
run_timed_test "sleep .0"       ".0"        500

# ── Actual sleep duration ────────────────────────────────────
run_sleep_duration_test "sleep 0.1s duration"  "0.1"   50   500
run_sleep_duration_test "sleep 0.2 duration"   "0.2"   150  600

# ── Multiple arguments ───────────────────────────────────────
run_timed_test "multiple zeros"   "0 0 0"   500
run_sleep_duration_test "sum 0.05+0.05" "0.05 0.05" 50 500

# ── Suffix tests ─────────────────────────────────────────────
run_sleep_duration_test "sleep 0.001m" "0.001m" 30 500

# ── Exit code tests ──────────────────────────────────────────
run_test "invalid flag exit code" "--invalid-flag-xyz" ""

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
