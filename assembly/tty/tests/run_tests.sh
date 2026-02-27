#!/bin/bash
# Test suite for ftty
# Usage: bash tests/run_tests.sh ./ftty

BIN="${1:-./ftty}"
GNU="tty"
PASS=0
FAIL=0
ERRORS=()

run_test() {
    local desc="$1"
    local args="$2"
    local input="$3"
    local use_pipe="${4:-}"

    if [ "$use_pipe" = "pipe" ]; then
        expected=$(echo "" | $GNU $args 2>&1)
        expected_exit=${PIPESTATUS[1]}
        got=$(echo "" | $BIN $args 2>&1)
        got_exit=${PIPESTATUS[1]}
    elif [ -n "$input" ]; then
        expected=$(echo "$input" | $GNU $args 2>&1)
        expected_exit=${PIPESTATUS[1]}
        got=$(echo "$input" | $BIN $args 2>&1)
        got_exit=${PIPESTATUS[1]}
    else
        expected=$($GNU $args 2>&1)
        expected_exit=$?
        got=$($BIN $args 2>&1)
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

# For tests where we specifically need to test with piped stdin
run_test_pipe() {
    local desc="$1"
    local args="$2"

    expected=$(echo "" | $GNU $args 2>&1)
    expected_exit=${PIPESTATUS[1]}
    got=$(echo "" | $BIN $args 2>&1)
    got_exit=${PIPESTATUS[1]}

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

# For tests comparing stderr specifically
run_test_stderr() {
    local desc="$1"
    local args="$2"

    expected_out=$($GNU $args 2>/dev/null)
    expected_err=$($GNU $args 2>&1 >/dev/null)
    expected_exit=$?

    got_out=$($BIN $args 2>/dev/null)
    got_err=$($BIN $args 2>&1 >/dev/null)
    got_exit=$?

    if [ "$expected_out" = "$got_out" ] && [ "$expected_err" = "$got_err" ] && [ "$expected_exit" = "$got_exit" ]; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
        ERRORS+=("FAIL: $desc")
        if [ "$expected_out" != "$got_out" ]; then
            ERRORS+=("  expected stdout: $(echo "$expected_out" | head -3)")
            ERRORS+=("  got stdout:      $(echo "$got_out" | head -3)")
        fi
        if [ "$expected_err" != "$got_err" ]; then
            ERRORS+=("  expected stderr: $(echo "$expected_err" | head -3)")
            ERRORS+=("  got stderr:      $(echo "$got_err" | head -3)")
        fi
        if [ "$expected_exit" != "$got_exit" ]; then
            ERRORS+=("  expected exit: $expected_exit, got: $got_exit")
        fi
    fi
}

# ── Standard flags (required for ALL tools) ──────────────────
run_test "--help output"    "--help"    ""
run_test "--version output" "--version" ""

# ── Error handling tests ─────────────────────────────────────
run_test_stderr "unrecognized long option"   "--invalid-flag-xyz"
run_test_stderr "unrecognized --badarg"      "--badarg"
run_test_stderr "invalid short option -x"    "-x"
run_test_stderr "invalid short option -a"    "-a"
run_test_stderr "combined -sx (invalid x)"   "-sx"
run_test_stderr "extra operand"              "extraarg"

# ── Core functionality (piped stdin = not a tty) ─────────────
run_test_pipe "not a tty (piped stdin)"      ""
run_test_pipe "silent mode -s"               "-s"
run_test_pipe "silent mode --silent"         "--silent"
run_test_pipe "silent mode --quiet"          "--quiet"
run_test_pipe "multiple silent flags"        "-s --silent --quiet"

# ── End-of-options marker -- ─────────────────────────────────
run_test_pipe "-- (end of options, no args)"  "--"
run_test_pipe "-s -- (silent with end marker)" "-s --"
run_test_stderr "-- foo (extra operand after --)" "-- foo"
run_test_stderr "-- -s (operand after --)"      "-- -s"
run_test_stderr "-- --help (operand after --)"  "-- --help"

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
