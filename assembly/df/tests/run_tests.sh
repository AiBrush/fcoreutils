#!/bin/bash
# Test suite for fdf (assembly df)
# Usage: bash tests/run_tests.sh ./fdf

BIN="${1:-./fdf}"
GNU="df"
PASS=0
FAIL=0
ERRORS=()
TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT

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

# Check that output has a header line
run_test_header() {
    local desc="$1"
    shift
    local args=("$@")

    $BIN "${args[@]}" > "$TMPDIR/out" 2>/dev/null
    local rc=$?

    if [ $rc -ne 0 ]; then
        FAIL=$((FAIL+1))
        ERRORS+=("FAIL: $desc — exit code $rc")
        return
    fi

    local first_line=$(head -1 "$TMPDIR/out")
    if echo "$first_line" | grep -qi "filesystem"; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
        ERRORS+=("FAIL: $desc — header missing 'Filesystem'")
        ERRORS+=("  got: $first_line")
    fi
}

# Check that specific file shows filesystem info
run_test_file() {
    local desc="$1"
    local file="$2"

    $BIN "$file" > "$TMPDIR/out" 2>/dev/null
    local rc=$?

    if [ $rc -ne 0 ]; then
        FAIL=$((FAIL+1))
        ERRORS+=("FAIL: $desc — exit code $rc")
        return
    fi

    local lines=$(wc -l < "$TMPDIR/out")
    if [ "$lines" -ge 2 ]; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
        ERRORS+=("FAIL: $desc — expected >= 2 lines, got $lines")
    fi
}

# ── Standard flags ──
run_test_exit_only "--help exit code" --help
run_test_exit_only "--version exit code" --version

# ── Default output ──
run_test_header "default header"
run_test_exit_only "default exit code"

# ── Flags ──
run_test_exit_only "-h flag" -h
run_test_exit_only "-T flag" -T
run_test_exit_only "-i flag" -i
run_test_exit_only "-a flag" -a
run_test_exit_only "-k flag" -k

# ── Specific file ──
run_test_file "specific file /tmp" /tmp
run_test_file "specific file /" /

# ── Non-existent ──
run_test_exit_only "nonexistent" /nonexistent_path_$$

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
