#!/bin/bash
# GNU compatibility tests for ffalse (assembly)
# Compares byte-for-byte against GNU false
# Usage: bash test_ffalse.sh [path-to-ffalse]

BIN="${1:-../false/ffalse}"
GNU="/usr/bin/false"

PASS=0
FAIL=0
ERRORS=()

TMPDIR=$(mktemp -d /tmp/test_ffalse.XXXXXX)
trap "rm -rf $TMPDIR" EXIT

# ── Helper: compare exit code ──
check_exit() {
    local desc="$1"
    shift

    $GNU "$@" > "$TMPDIR/gnu_out" 2> "$TMPDIR/gnu_err"
    local gnu_exit=$?
    $BIN "$@" > "$TMPDIR/our_out" 2> "$TMPDIR/our_err"
    local our_exit=$?

    local failed=0

    if [ "$gnu_exit" != "$our_exit" ]; then
        failed=1
    fi

    # stdout must match (should be empty)
    if ! diff -q "$TMPDIR/gnu_out" "$TMPDIR/our_out" > /dev/null 2>&1; then
        failed=1
    fi

    if [ "$failed" -eq 0 ]; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
        ERRORS+=("FAIL: $desc")
        if [ "$gnu_exit" != "$our_exit" ]; then
            ERRORS+=("  expected exit: $gnu_exit, got: $our_exit")
        fi
        if ! diff -q "$TMPDIR/gnu_out" "$TMPDIR/our_out" > /dev/null 2>&1; then
            ERRORS+=("  stdout differs")
        fi
    fi
}

echo "=== ffalse GNU compatibility tests ==="
echo ""

# ── Exit code is always 1 ──
echo "-- Exit code tests --"
check_exit "no arguments"
check_exit "single argument" foo
check_exit "multiple arguments" foo bar baz
check_exit "dash argument" -
check_exit "double dash" --
check_exit "invalid flag" --invalid-flag-xyz
check_exit "mixed flags and args" --foo bar -x

# ── No output on stdout ──
echo "-- Stdout silence tests --"
check_no_stdout() {
    local desc="$1"
    shift
    local stdout=$($BIN "$@" 2>/dev/null)
    if [ -z "$stdout" ]; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
        ERRORS+=("FAIL: $desc -- unexpected stdout: $stdout")
    fi
}

check_no_stdout "no args stdout silent"
check_no_stdout "with args stdout silent" foo bar
check_no_stdout "with -- stdout silent" --

# ── No output on stderr ──
echo "-- Stderr silence tests --"
check_no_stderr() {
    local desc="$1"
    shift
    local stderr=$($BIN "$@" 2>&1 >/dev/null)
    if [ -z "$stderr" ]; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
        ERRORS+=("FAIL: $desc -- unexpected stderr: $stderr")
    fi
}

check_no_stderr "no args stderr silent"
check_no_stderr "with args stderr silent" foo bar
check_no_stderr "with -- stderr silent" --

# ── Verify exit code is exactly 1 ──
echo "-- Exact exit code 1 --"
verify_exit_1() {
    local desc="$1"
    shift
    $BIN "$@" > /dev/null 2>&1
    local got=$?
    if [ "$got" -eq 1 ]; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
        ERRORS+=("FAIL: $desc -- expected exit 1, got $got")
    fi
}

verify_exit_1 "exit 1 no args"
verify_exit_1 "exit 1 with --help" --help
verify_exit_1 "exit 1 with --version" --version
verify_exit_1 "exit 1 with random args" foo bar baz
verify_exit_1 "exit 1 with --" --

# ── Rapid invocation stress test ──
echo "-- Stress test --"
stress_pass=true
for i in $(seq 100); do
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
    ERRORS+=("FAIL: rapid invocation stress test (100 iterations)")
fi

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
