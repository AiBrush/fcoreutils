#!/bin/bash
# Test suite for fstat
# Usage: bash tests/run_tests.sh ./fstat

BIN="${1:-./fstat}"
GNU="stat"
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
    local expected_err=$(cat "$TMPDIR/expected_err")
    local got_err=$(cat "$TMPDIR/got_err")

    expected_err=$(echo "$expected_err" | sed "s|$(which $GNU)|$GNU|g")

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

run_test_fd() {
    local desc="$1"
    shift
    local args=("$@")

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

# Setup test fixtures
touch "$TMPDIR/testfile"
mkdir -p "$TMPDIR/testdir"
ln -sf "$TMPDIR/testfile" "$TMPDIR/symlink"

# ── Standard flags ──
run_test_exit_only "--help exit code" --help
run_test_exit_only "--version exit code" --version
run_test_exit_only "invalid long flag" --invalid-flag-xyz
run_test_exit_only "invalid short flag" -Z

# ── FD isolation ──
run_test_fd "--help to stdout" --help
run_test_fd "error to stderr" --invalid-flag-xyz

# ── Format specifiers ──
run_test "-c %n" -c "%n" "$TMPDIR/testfile"
run_test "-c %s" -c "%s" "$TMPDIR/testfile"
run_test "-c %b" -c "%b" "$TMPDIR/testfile"
run_test "-c %i" -c "%i" "$TMPDIR/testfile"
run_test "-c %h" -c "%h" "$TMPDIR/testfile"
run_test "-c %u" -c "%u" "$TMPDIR/testfile"
run_test "-c %g" -c "%g" "$TMPDIR/testfile"
run_test "-c %a" -c "%a" "$TMPDIR/testfile"
run_test "-c %o" -c "%o" "$TMPDIR/testfile"
run_test "-c %X" -c "%X" "$TMPDIR/testfile"
run_test "-c %Y" -c "%Y" "$TMPDIR/testfile"
run_test "-c %Z" -c "%Z" "$TMPDIR/testfile"
run_test "-c %W" -c "%W" "$TMPDIR/testfile"
run_test "-c %F" -c "%F" "$TMPDIR/testfile"
run_test "-c %F dir" -c "%F" "$TMPDIR/testdir"

# ── Terse output ──
run_test "-t terse" -t "$TMPDIR/testfile"

# ── Error handling ──
run_test_exit_only "nonexistent file" "$TMPDIR/nonexistent"
run_test_exit_only "missing operand"

# ── Multiple files ──
run_test "-c %n multi" -c "%n" "$TMPDIR/testfile" "$TMPDIR/testdir"

# ── Follow symlinks ──
run_test "-L -c %F symlink" -L -c "%F" "$TMPDIR/symlink"

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
