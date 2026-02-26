#!/bin/bash
# Test suite for ftrue
# Usage: bash tests/run_tests.sh ./ftrue

BIN="${1:-./ftrue}"
GNU="/usr/bin/true"
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

# Test that normalizes program name before comparison.
# GNU uses argv[0] (e.g. "/usr/bin/true") in --help, while
# our binary hardcodes "true". This normalizes both to "true".
run_test_help() {
    local desc="$1"
    local args="$2"

    local expected=$($GNU $args 2>&1)
    local got=$($BIN $args 2>&1)

    $GNU $args > /dev/null 2>&1
    local expected_exit=$?
    $BIN $args > /dev/null 2>&1
    local got_exit=$?

    # Normalize: replace any path/true with just "true"
    local expected_norm=$(echo "$expected" | sed 's|[^ ]*/true|true|g')
    local got_norm=$(echo "$got" | sed 's|[^ ]*/true|true|g')

    if [ "$expected_norm" = "$got_norm" ] && [ "$expected_exit" = "$got_exit" ]; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
        ERRORS+=("FAIL: $desc")
        if [ "$expected_norm" != "$got_norm" ]; then
            ERRORS+=("  expected (normalized): $(echo "$expected_norm" | head -3)")
            ERRORS+=("  got (normalized):      $(echo "$got_norm" | head -3)")
        fi
        if [ "$expected_exit" != "$got_exit" ]; then
            ERRORS+=("  expected exit: $expected_exit, got: $got_exit")
        fi
    fi
}

# ── Standard flags (required for ALL tools) ──────────────────
# GNU true handles --help and --version when argc == 2
run_test_help "--help output"    "--help"
run_test "--version output" "--version" ""
run_test "invalid flag"     "--invalid-flag-xyz" ""

# ── Tool-specific tests ──────────────────────────────────────
run_test "no arguments"              ""              ""
run_test "single argument"           "foo"           ""
run_test "multiple arguments"        "foo bar baz"   ""
run_test "dash argument"             "-"             ""
run_test "double dash"               "--"            ""
run_test "mixed flags and args"      "--foo bar -x"  ""

# ── argc != 2 edge cases (--help/--version ignored) ──────────
run_test "--help with extra arg"     "--help extra"  ""
run_test "--version with extra arg"  "--version foo" ""

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
