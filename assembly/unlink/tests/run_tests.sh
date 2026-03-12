#!/bin/bash
# Test suite for funlink
# Usage: bash tests/run_tests.sh ./funlink

BIN="${1:-./funlink}"
GNU="unlink"
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

    # Normalize tool name in error messages (use sed -i on file to preserve bytes)
    LC_ALL=C sed -i "s|$(which $GNU)|$GNU|g" "$TMPDIR/expected_err"

    local stdout_match=true
    local stderr_match=true

    if ! cmp -s "$TMPDIR/expected" "$TMPDIR/got"; then
        stdout_match=false
    fi
    if ! cmp -s "$TMPDIR/expected_err" "$TMPDIR/got_err"; then
        stderr_match=false
    fi

    if $stdout_match && $stderr_match && [ "$expected_exit" = "$got_exit" ]; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
        ERRORS+=("FAIL: $desc")
        if ! $stdout_match; then
            ERRORS+=("  expected stdout: $(head -3 "$TMPDIR/expected")")
            ERRORS+=("  got stdout:      $(head -3 "$TMPDIR/got")")
        fi
        if ! $stderr_match; then
            ERRORS+=("  expected stderr: $(head -3 "$TMPDIR/expected_err")")
            ERRORS+=("  got stderr:      $(head -3 "$TMPDIR/got_err")")
        fi
        if [ "$expected_exit" != "$got_exit" ]; then
            ERRORS+=("  expected exit: $expected_exit, got: $got_exit")
        fi
    fi
}

# Separate test for help/version (text is patched by build_tool.py)
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

# Custom test for unlink-specific behavior (no GNU comparison needed)
run_test_custom() {
    local desc="$1"
    local expected_exit="$2"
    shift 2
    local args=("$@")

    $BIN "${args[@]}" > "$TMPDIR/got" 2> "$TMPDIR/got_err"
    local got_exit=$?

    if [ "$expected_exit" = "$got_exit" ]; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
        ERRORS+=("FAIL: $desc — expected exit: $expected_exit, got: $got_exit")
        if [ -s "$TMPDIR/got_err" ]; then
            ERRORS+=("  stderr: $(cat "$TMPDIR/got_err" | head -3)")
        fi
    fi
}

# ── Standard flags ──
run_test_exit_only "--help exit code" --help
run_test_exit_only "--version exit code" --version

# ── FD isolation ──
run_test_fd "--help to stdout" --help
run_test_fd "error to stderr"

# ── Error handling: missing operand ──
run_test "missing operand (no args)"

# ── Error handling: extra operand ──
run_test "extra operand" a b

# ── Core functionality: unlink a file ──
TESTFILE="$TMPDIR/test_unlink"
echo "hello" > "$TESTFILE"
run_test_custom "unlink regular file" 0 "$TESTFILE"

# Verify the file was actually removed
if [ ! -e "$TESTFILE" ]; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: file still exists after unlink")
fi

# ── Error: unlink nonexistent file ──
run_test "unlink nonexistent file" "$TMPDIR/nonexistent_file"

# ── Error: unlink directory ──
mkdir -p "$TMPDIR/testdir"

# Compare error message with GNU for directory unlink
$GNU "$TMPDIR/testdir" > "$TMPDIR/expected" 2> "$TMPDIR/expected_err"
expected_exit=$?
$BIN "$TMPDIR/testdir" > "$TMPDIR/got" 2> "$TMPDIR/got_err"
got_exit=$?

LC_ALL=C sed -i "s|$(which $GNU)|$GNU|g" "$TMPDIR/expected_err"

if cmp -s "$TMPDIR/expected_err" "$TMPDIR/got_err" && [ "$expected_exit" = "$got_exit" ]; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: unlink directory error message mismatch")
    ERRORS+=("  expected: $(cat "$TMPDIR/expected_err")")
    ERRORS+=("  got:      $(cat "$TMPDIR/got_err")")
fi

rmdir "$TMPDIR/testdir"

# ── Error message format: compare with GNU ──
# Test that error messages match GNU exactly for nonexistent file
NONEXIST="$TMPDIR/nosuch_file_xyz"

$GNU "$NONEXIST" > "$TMPDIR/expected" 2> "$TMPDIR/expected_err"
expected_exit=$?
$BIN "$NONEXIST" > "$TMPDIR/got" 2> "$TMPDIR/got_err"
got_exit=$?

expected_err=$(cat "$TMPDIR/expected_err" | sed "s|$(which $GNU)|$GNU|g")
got_err=$(cat "$TMPDIR/got_err")

if [ "$expected_err" = "$got_err" ] && [ "$expected_exit" = "$got_exit" ]; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: error message mismatch for nonexistent file")
    ERRORS+=("  expected: $expected_err")
    ERRORS+=("  got:      $got_err")
fi

# ── Verify unlink only removes one link ──
echo "multilink" > "$TMPDIR/ml_src"
ln "$TMPDIR/ml_src" "$TMPDIR/ml_link"
run_test_custom "unlink one of two links" 0 "$TMPDIR/ml_link"

# Original should still exist
if [ -f "$TMPDIR/ml_src" ]; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: original file removed when unlinking hard link")
fi

# Link should be gone
if [ ! -e "$TMPDIR/ml_link" ]; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: hard link still exists after unlink")
fi

rm -f "$TMPDIR/ml_src"

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
