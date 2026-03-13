#!/bin/bash
# Test suite for fnumfmt
# Usage: bash tests/run_tests.sh ./fnumfmt

BIN="${1:-./fnumfmt}"
GNU="numfmt"
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

run_test() {
    local desc="$1"
    shift
    local args=("$@")

    local expected=$(timeout 5 $GNU "${args[@]}" 2>&1)
    local expected_exit=$?
    local got=$(timeout 5 $BIN "${args[@]}" 2>&1)
    local got_exit=$?

    if [ "$expected" = "$got" ] && [ "$expected_exit" = "$got_exit" ]; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
        ERRORS+=("FAIL: $desc")
        if [ "$expected" != "$got" ]; then
            ERRORS+=("  expected: $(echo "$expected" | head -3)")
            ERRORS+=("  got:      $(echo "$got" | head -3)")
        fi
        if [ "$expected_exit" != "$got_exit" ]; then
            ERRORS+=("  expected exit: $expected_exit, got: $got_exit")
        fi
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
    PASS=$((PASS+1))
}

# ── Standard flags ──
run_test_exit_only "--help exit code" --help
run_test_exit_only "--version exit code" --version

# ── FD isolation ──
run_test_fd "--help to stdout" --help

# ── Pass-through (no conversion) ──
run_test "pass-through 42" 42
run_test "pass-through 0" 0
run_test "pass-through 1000" 1000

# ── --to=si ──
run_test "--to=si 1000" --to=si 1000
run_test "--to=si 1000000" --to=si 1000000

# ── --to=iec ──
run_test "--to=iec 1024" --to=iec 1024
run_test "--to=iec 1048576" --to=iec 1048576

# ── --to=iec-i ──
run_test "--to=iec-i 1024" --to=iec-i 1024
run_test "--to=iec-i 1048576" --to=iec-i 1048576

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
