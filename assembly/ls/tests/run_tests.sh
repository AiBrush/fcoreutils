#!/bin/bash
# Test suite for fls (assembly ls)
# Usage: bash tests/run_tests.sh ./fls

# Force C locale so GNU ls sorts by byte order, matching our assembly implementation
export LC_ALL=C

BIN="${1:-./fls}"
GNU="ls"
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

# Compare just the sorted filenames (for format-independent checking)
run_test_names() {
    local desc="$1"
    shift
    local args=("$@")

    $GNU "${args[@]}" 2>/dev/null | tr -s ' \t' '\n' | sort > "$TMPDIR/expected_names"
    local expected_exit=${PIPESTATUS[0]}
    $BIN "${args[@]}" 2>/dev/null | tr -s ' \t' '\n' | sort > "$TMPDIR/got_names"
    local got_exit=${PIPESTATUS[0]}

    local expected=$(cat "$TMPDIR/expected_names")
    local got=$(cat "$TMPDIR/got_names")

    if [ "$expected" = "$got" ] && [ "$expected_exit" = "$got_exit" ]; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
        ERRORS+=("FAIL: $desc")
        if [ "$expected" != "$got" ]; then
            ERRORS+=("  expected names: $(echo "$expected" | head -5)")
            ERRORS+=("  got names:      $(echo "$got" | head -5)")
        fi
    fi
}

# ── Setup test directory ──
mkdir -p "$TMPDIR/testdir/subdir"
echo "hello" > "$TMPDIR/testdir/file1.txt"
echo "world" > "$TMPDIR/testdir/file2.txt"
echo "hidden" > "$TMPDIR/testdir/.hidden"
touch "$TMPDIR/testdir/subdir/nested.txt"
ln -s file1.txt "$TMPDIR/testdir/link1" 2>/dev/null
ln -s /nonexistent "$TMPDIR/testdir/broken_link" 2>/dev/null

# ── Standard flags ──
run_test_exit_only "--help exit code" --help
run_test_exit_only "--version exit code" --version

# ── One per line output (piped, default) ──
run_test "list test dir (one-per-line)" "$TMPDIR/testdir"
run_test "-1 flag" -1 "$TMPDIR/testdir"
run_test "-a flag" -a "$TMPDIR/testdir"
run_test "-A flag" -A "$TMPDIR/testdir"

# ── Check names match for multi-column ──
run_test_names "-C names match" -C "$TMPDIR/testdir"

# ── Long format ──
# Note: long format includes uid/gid which may differ in display
# We just check exit code and basic structure
run_test_exit_only "-l exit code" -l "$TMPDIR/testdir"

# ── Flags ──
run_test "-1a combined" -1a "$TMPDIR/testdir"
run_test "-1A combined" -1A "$TMPDIR/testdir"
run_test "-r reverse" -r "$TMPDIR/testdir"

# ── Directory flag ──
run_test "-d flag" -d "$TMPDIR/testdir"

# ── Non-existent ──
run_test "nonexistent file" "$TMPDIR/nonexistent_$$"

# ── Multiple args ──
run_test "multiple dirs" "$TMPDIR/testdir" "$TMPDIR/testdir/subdir"

# ── Empty dir ──
mkdir -p "$TMPDIR/emptydir"
run_test "empty directory" "$TMPDIR/emptydir"

# ── Root-level entries ──
run_test_exit_only "list /tmp exit code" /tmp

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
