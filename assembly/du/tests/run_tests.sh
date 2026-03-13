#!/bin/bash
# Test suite for fdu (assembly du)
# Usage: bash tests/run_tests.sh ./fdu

BIN="${1:-./fdu}"
GNU="du"
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
            ERRORS+=("  expected: $(echo "$expected" | head -3)")
            ERRORS+=("  got:      $(echo "$got" | head -3)")
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

# Compare just the final total number (ignore path differences)
run_test_total() {
    local desc="$1"
    shift
    local args=("$@")

    local expected=$($GNU "${args[@]}" 2>/dev/null | tail -1 | awk '{print $1}')
    local got=$($BIN "${args[@]}" 2>/dev/null | tail -1 | awk '{print $1}')

    if [ "$expected" = "$got" ]; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
        ERRORS+=("FAIL: $desc — expected total: $expected, got: $got")
    fi
}

# ── Setup ──
mkdir -p "$TMPDIR/testdir/subdir"
dd if=/dev/zero of="$TMPDIR/testdir/file1.txt" bs=1024 count=4 2>/dev/null
dd if=/dev/zero of="$TMPDIR/testdir/file2.txt" bs=1024 count=8 2>/dev/null
dd if=/dev/zero of="$TMPDIR/testdir/subdir/nested.txt" bs=1024 count=2 2>/dev/null

# ── Standard flags ──
run_test_exit_only "--help exit code" --help
run_test_exit_only "--version exit code" --version

# ── Basic usage ──
run_test_exit_only "basic dir" "$TMPDIR/testdir"
run_test "-s flag" -s "$TMPDIR/testdir"

# ── Compare totals ──
run_test_total "summary total" -s "$TMPDIR/testdir"

# ── Flags ──
run_test_exit_only "-a flag" -a "$TMPDIR/testdir"
run_test_exit_only "-c flag" -c "$TMPDIR/testdir"
run_test_exit_only "-h flag" -sh "$TMPDIR/testdir"
run_test_exit_only "-b flag" -sb "$TMPDIR/testdir"

# ── Max depth ──
run_test_exit_only "-d 0" -d 0 "$TMPDIR/testdir"
run_test_exit_only "-d 1" -d 1 "$TMPDIR/testdir"

# ── Non-existent ──
run_test "nonexistent" "$TMPDIR/nonexistent_$$"

# ── Empty dir ──
mkdir -p "$TMPDIR/emptydir"
run_test "-s empty dir" -s "$TMPDIR/emptydir"

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
