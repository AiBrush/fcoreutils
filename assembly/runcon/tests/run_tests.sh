#!/bin/bash
# Test suite for fruncon
# Usage: bash tests/run_tests.sh ./fruncon

BIN="${1:-./fruncon}"
GNU="runcon"
PASS=0
FAIL=0
ERRORS=()

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

run_test_fd() {
    local desc="$1"
    shift
    local args=("$@")
    local TMPDIR=$(mktemp -d)
    trap "rm -rf $TMPDIR" RETURN

    $BIN "${args[@]}" > "$TMPDIR/stdout" 2> "$TMPDIR/stderr"
    local exit_code=$?

    if echo "${args[@]}" | grep -q "\-\-help"; then
        if [ -s "$TMPDIR/stdout" ] && [ ! -s "$TMPDIR/stderr" ]; then
            PASS=$((PASS+1))
        else
            FAIL=$((FAIL+1))
            ERRORS+=("FAIL: $desc — --help should write to stdout only")
        fi
        return
    fi

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
run_test_fd "error to stderr" system_u:object_r:etc_t:s0 /nonexistent_xyz

# ── Missing operand ──
run_test_exit_only "no arguments (missing operand)"

# ── Non-SELinux: operation not supported ──
desc="runcon on non-SELinux"
$GNU system_u:object_r:etc_t:s0 true 2>/dev/null
expected_exit=$?
$BIN system_u:object_r:etc_t:s0 true 2>/dev/null
got_exit=$?
if [ "$expected_exit" = "$got_exit" ]; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: $desc — expected exit: $expected_exit, got: $got_exit")
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
