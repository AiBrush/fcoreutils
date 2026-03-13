#!/bin/bash
# Test suite for fstdbuf
# Usage: bash tests/run_tests.sh ./fstdbuf

BIN="${1:-./fstdbuf}"
GNU="stdbuf"
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
run_test_fd "error to stderr" --invalid-flag-xyz

# ── Missing operand ──
run_test_exit_only "no arguments"

# ── Run with -o L ──
desc="stdbuf -o L echo hello"
expected=$(timeout 5 $GNU -o L echo hello 2>&1)
expected_exit=$?
got=$(timeout 5 $BIN -o L echo hello 2>&1)
got_exit=$?
if [ "$expected" = "$got" ] && [ "$expected_exit" = "$got_exit" ]; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: $desc")
    if [ "$expected" != "$got" ]; then
        ERRORS+=("  expected: $expected")
        ERRORS+=("  got:      $got")
    fi
    if [ "$expected_exit" != "$got_exit" ]; then
        ERRORS+=("  expected exit: $expected_exit, got: $got_exit")
    fi
fi

# ── Run with -o 0 ──
desc="stdbuf -o 0 echo world"
expected=$(timeout 5 $GNU -o 0 echo world 2>&1)
expected_exit=$?
got=$(timeout 5 $BIN -o 0 echo world 2>&1)
got_exit=$?
if [ "$expected" = "$got" ] && [ "$expected_exit" = "$got_exit" ]; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: $desc")
    if [ "$expected" != "$got" ]; then
        ERRORS+=("  expected: $expected")
        ERRORS+=("  got:      $got")
    fi
fi

# ── Nonexistent command ──
desc="stdbuf -o L nonexistent_cmd_xyz"
$GNU -o L nonexistent_cmd_xyz 2>/dev/null
expected_exit=$?
$BIN -o L nonexistent_cmd_xyz 2>/dev/null
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
