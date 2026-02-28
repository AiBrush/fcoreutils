#!/bin/bash
# Test suite for fsync (sync command)
# Usage: bash tests/run_tests.sh ./fsync

BIN="${1:-./fsync}"
GNU="sync"
PASS=0
FAIL=0
ERRORS=()

run_test() {
    local desc="$1"
    local args="$2"
    local input="$3"

    if [ -n "$input" ]; then
        expected=$(echo "$input" | $GNU $args 2>&1)
        expected_exit=$?
        got=$(echo "$input" | $BIN $args 2>&1)
        got_exit=$?
    else
        expected=$($GNU $args 2>&1)
        expected_exit=$?
        got=$($BIN $args 2>&1)
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

# Create temp directory for test files
TMPDIR=$(mktemp -d)
echo "hello world" > "$TMPDIR/testfile.txt"
trap "rm -rf $TMPDIR" EXIT

# ── Standard flags (required for ALL tools) ──────────────────
# SKIP: --help/--version text is version-specific, tested in security_tests.py instead
#run_test "--help output"    "--help"    ""
#run_test "--version output" "--version" ""
run_test "invalid long flag" "--invalid-flag-xyz" ""

# ── Short option tests ──────────────────────────────────────
run_test "invalid short flag -x" "-x" ""
run_test "invalid short flag -z" "-z" ""

# ── Sync all (no args) ──────────────────────────────────────
run_test "sync all (no args)" "" ""

# ── File sync tests ─────────────────────────────────────────
run_test "sync single file" "$TMPDIR/testfile.txt" ""
run_test "sync -d with file" "-d $TMPDIR/testfile.txt" ""
run_test "sync -f with file" "-f $TMPDIR/testfile.txt" ""

# ── Error cases ─────────────────────────────────────────────
run_test "sync nonexistent file" "/nonexistent_sync_test_file_xyz" ""
run_test "-d without file" "-d" ""
run_test "-f without file" "-f" ""
run_test "-df conflict" "-df $TMPDIR/testfile.txt" ""
run_test "--data --file-system conflict" "--data --file-system $TMPDIR/testfile.txt" ""

# ── Double dash tests ───────────────────────────────────────
run_test "-- no files" "--" ""
run_test "-- with file" "-- $TMPDIR/testfile.txt" ""

# ── Exit code tests ─────────────────────────────────────────
run_test "exit 0 on success" "" ""
run_test "exit 1 on nonexistent" "-f /nonexistent_sync_test_file_xyz" ""

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
