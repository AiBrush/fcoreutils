#!/bin/bash
# Test suite for fenv
# Usage: bash tests/run_tests.sh ./fenv

BIN="${1:-./fenv}"
GNU="env"
PASS=0
FAIL=0
ERRORS=()
TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT

run_test() {
    local desc="$1"
    shift
    local args=("$@")

    $GNU "${args[@]}" > "$TMPDIR/expected" 2> "$TMPDIR/expected_err"
    local expected_exit=$?
    $BIN "${args[@]}" > "$TMPDIR/got" 2> "$TMPDIR/got_err"
    local got_exit=$?

    local expected=$(cat "$TMPDIR/expected")
    local got=$(cat "$TMPDIR/got")

    if [ "$expected" = "$got" ] && [ "$expected_exit" = "$got_exit" ]; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
        ERRORS+=("FAIL: $desc")
        if [ "$expected" != "$got" ]; then
            ERRORS+=("  expected stdout: $(echo "$expected" | head -3)")
            ERRORS+=("  got stdout:      $(echo "$got" | head -3)")
        fi
        if [ "$expected_exit" != "$got_exit" ]; then
            ERRORS+=("  expected exit: $expected_exit, got: $got_exit")
        fi
    fi
}

run_test_exit_only() {
    local desc="$1"
    shift
    local args=("$@")

    $GNU "${args[@]}" > /dev/null 2>&1
    local expected_exit=$?
    $BIN "${args[@]}" > /dev/null 2>&1
    local got_exit=$?

    if [ "$expected_exit" = "$got_exit" ]; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
        ERRORS+=("FAIL: $desc — expected exit: $expected_exit, got: $got_exit")
    fi
}

# Test that compares sorted output (for env var printing where order may differ)
run_test_sorted() {
    local desc="$1"
    shift
    local args=("$@")

    $GNU "${args[@]}" 2>/dev/null | grep -v '^_=' | sort > "$TMPDIR/expected_sorted"
    local expected_exit=${PIPESTATUS[0]}
    $BIN "${args[@]}" 2>/dev/null | grep -v '^_=' | sort > "$TMPDIR/got_sorted"
    local got_exit=${PIPESTATUS[0]}

    if cmp -s "$TMPDIR/expected_sorted" "$TMPDIR/got_sorted" && [ "$expected_exit" = "$got_exit" ]; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
        ERRORS+=("FAIL: $desc")
        if ! cmp -s "$TMPDIR/expected_sorted" "$TMPDIR/got_sorted"; then
            ERRORS+=("  sorted output differs")
            ERRORS+=("  expected lines: $(wc -l < "$TMPDIR/expected_sorted")")
            ERRORS+=("  got lines:      $(wc -l < "$TMPDIR/got_sorted")")
        fi
        if [ "$expected_exit" != "$got_exit" ]; then
            ERRORS+=("  expected exit: $expected_exit, got: $got_exit")
        fi
    fi
}

# Test FD isolation: stdout vs stderr
run_test_fd() {
    local desc="$1"
    shift
    local args=("$@")

    $BIN "${args[@]}" > "$TMPDIR/stdout" 2> "$TMPDIR/stderr"
    local exit_code=$?

    # Check that --help goes to stdout (not stderr)
    if echo "${args[@]}" | grep -q "\-\-help"; then
        if [ -s "$TMPDIR/stdout" ] && [ ! -s "$TMPDIR/stderr" ]; then
            PASS=$((PASS+1))
        else
            FAIL=$((FAIL+1))
            ERRORS+=("FAIL: $desc — --help should write to stdout only")
        fi
        return
    fi

    # For error cases: check stderr has content, stdout empty
    if [ $exit_code -ne 0 ]; then
        if [ ! -s "$TMPDIR/stdout" ] && [ -s "$TMPDIR/stderr" ]; then
            PASS=$((PASS+1))
        else
            FAIL=$((FAIL+1))
            ERRORS+=("FAIL: $desc — errors should go to stderr only")
        fi
        return
    fi

    PASS=$((PASS+1))
}

# ── Standard flags ──
run_test_exit_only "--help exit code" --help
run_test_exit_only "--version exit code" --version

# ── FD isolation ──
run_test_fd "--help to stdout" --help

# ── No args: print all env (sorted comparison) ──
run_test_sorted "no args: print all env vars"

# ── -i flag: empty environment ──
run_test "-i: empty env" -i

# ── Set single var ──
run_test "set var" FOO=bar /usr/bin/printenv FOO

# ── -i with var and command ──
run_test "-i with var" -i FOO=hello /usr/bin/printenv FOO

# ── -u flag: unset a variable ──
# Create a test with a known variable
export TEST_ENV_VAR_XYZ="test_value"
run_test_exit_only "-u unset var" -u TEST_ENV_VAR_XYZ /usr/bin/printenv TEST_ENV_VAR_XYZ
unset TEST_ENV_VAR_XYZ

# ── Command execution ──
run_test "run true" /usr/bin/true
run_test_exit_only "run false" /usr/bin/false

# ── Command not found ──
run_test_exit_only "nonexistent command" /nonexistent/command/xyz

# ── Multiple VAR=VALUE ──
run_test "multiple vars" -i A=1 B=2 C=3 /usr/bin/printenv A

# ── Double dash ──
run_test "-- separator" -- /usr/bin/true

# ── Results ──
echo ""
echo "Results: $PASS passed, $FAIL failed out of $((PASS+FAIL)) tests"
for e in "${ERRORS[@]}"; do echo "  $e"; done
echo ""

if [ $FAIL -eq 0 ]; then
    echo "ALL TESTS PASSED"
    exit 0
else
    echo "$FAIL TESTS FAILED"
    exit 1
fi
