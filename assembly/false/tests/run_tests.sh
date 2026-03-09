#!/bin/bash
# Test suite for ffalse
# Usage: bash tests/run_tests.sh ./ffalse

BIN="${1:-./ffalse}"
GNU="/usr/bin/false"
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

# ── Tool-specific tests ──────────────────────────────────────
run_test "no arguments"              ""              ""
run_test "single argument"           "foo"           ""
run_test "multiple arguments"        "foo bar baz"   ""
run_test "dash argument"             "-"             ""
run_test "double dash"               "--"            ""
run_test "mixed flags and args"      "--foo bar -x"  ""
run_test "invalid flag"              "--invalid-flag-xyz" ""

# ── Edge cases (false ignores everything) ─────────────────────
# SKIP: --help/--version text is version-specific, skipped per project convention
#run_test "--help (ignored)"          "--help"        ""
#run_test "--version (ignored)"       "--version"     ""
run_test "--help with extra arg"     "--help extra"  ""
run_test "--version with extra arg"  "--version foo" ""
run_test "empty string arg"          "''"            ""
run_test "many arguments"            "a b c d e f"  ""

# ── Verify exit code is always 1 ─────────────────────────────
verify_exit_1() {
    local desc="$1"
    shift
    $BIN "$@" > /dev/null 2>&1
    local got_exit=$?
    if [ "$got_exit" = "1" ]; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
        ERRORS+=("FAIL: $desc — expected exit 1, got $got_exit")
    fi
}

verify_exit_1 "exit 1 with no args"
verify_exit_1 "exit 1 with --help" --help
verify_exit_1 "exit 1 with --version" --version
verify_exit_1 "exit 1 with random args" foo bar baz
verify_exit_1 "exit 1 with --" --

# ── Verify no output on stdout or stderr ──────────────────────
check_no_output() {
    local desc="$1"
    shift
    local stdout=$($BIN "$@" 2>/dev/null)
    local stderr=$($BIN "$@" 2>&1 >/dev/null)
    if [ -z "$stdout" ] && [ -z "$stderr" ]; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
        ERRORS+=("FAIL: $desc — unexpected output")
        [ -n "$stdout" ] && ERRORS+=("  stdout: $stdout")
        [ -n "$stderr" ] && ERRORS+=("  stderr: $stderr")
    fi
}

check_no_output "no output with no args"
check_no_output "no output with args" foo bar
check_no_output "no output with --" --

# ── Rapid invocation stress test ──────────────────────────────
stress_pass=true
for i in $(seq 1000); do
    $BIN > /dev/null 2>&1
    if [ $? -ne 1 ]; then
        stress_pass=false
        break
    fi
done
if $stress_pass; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: rapid invocation stress test")
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
