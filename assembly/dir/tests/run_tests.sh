#!/bin/bash
# Test suite for fdir (assembly dir)
# Usage: bash tests/run_tests.sh ./fdir

BIN="${1:-./fdir}"
GNU="dir"
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

run_test_names() {
    local desc="$1"
    shift
    local args=("$@")

    $GNU "${args[@]}" 2>/dev/null | tr -s ' \t' '\n' | sort > "$TMPDIR/expected_names"
    $BIN "${args[@]}" 2>/dev/null | tr -s ' \t' '\n' | sort > "$TMPDIR/got_names"

    local expected=$(cat "$TMPDIR/expected_names")
    local got=$(cat "$TMPDIR/got_names")

    if [ "$expected" = "$got" ]; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
        ERRORS+=("FAIL: $desc")
        ERRORS+=("  expected names: $(echo "$expected" | head -5)")
        ERRORS+=("  got names:      $(echo "$got" | head -5)")
    fi
}

# ── Setup test directory ──
mkdir -p "$TMPDIR/testdir/subdir"
echo "hello" > "$TMPDIR/testdir/file1.txt"
echo "world" > "$TMPDIR/testdir/file2.txt"
touch "$TMPDIR/testdir/.hidden"

# ── Standard flags ──
run_test_exit_only "--help exit code" --help
run_test_exit_only "--version exit code" --version

# ── Names match (format may differ) ──
run_test_names "names in testdir" "$TMPDIR/testdir"
run_test_names "-a names" -a "$TMPDIR/testdir"
run_test_names "-A names" -A "$TMPDIR/testdir"

# ── One per line ──
run_test "-1 flag" -1 "$TMPDIR/testdir"
run_test "-1a combined" -1a "$TMPDIR/testdir"

# ── Directory itself ──
run_test "-d flag" -d "$TMPDIR/testdir"

# ── Empty dir ──
mkdir -p "$TMPDIR/emptydir"
run_test "empty dir" "$TMPDIR/emptydir"

# ── Non-existent ──
run_test "nonexistent" "$TMPDIR/nonexistent_$$"

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
