#!/bin/bash
# Test suite for frealpath
# Usage: bash tests/run_tests.sh ./frealpath

BIN="${1:-./frealpath}"
GNU="realpath"
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
mkdir -p "$TMPDIR/testdir/a/b"
touch "$TMPDIR/testdir/realfile"
touch "$TMPDIR/testdir/a/b/deepfile"
ln -sf "$TMPDIR/testdir/realfile" "$TMPDIR/testdir/symlink1"
ln -sf realfile "$TMPDIR/testdir/relsymlink"
ln -sf ../realfile "$TMPDIR/testdir/a/upsymlink"
ln -sf nonexistent "$TMPDIR/testdir/brokensymlink"
ln -sf "$TMPDIR/testdir/symlink1" "$TMPDIR/testdir/chainsymlink"

# ── Standard flags ──
run_test_exit_only "--help exit code" --help
run_test_exit_only "--version exit code" --version
run_test_exit_only "invalid long flag" --invalid-flag-xyz
run_test_exit_only "invalid short flag" -X

# ── FD isolation ──
run_test_fd "--help to stdout" --help
run_test_fd "error to stderr" --invalid-flag-xyz

# ── Basic resolving ──
run_test "regular file" "$TMPDIR/testdir/realfile"
run_test "directory" "$TMPDIR/testdir/a"
run_test "symlink" "$TMPDIR/testdir/symlink1"
run_test "relative symlink" "$TMPDIR/testdir/relsymlink"
run_test "chain symlink" "$TMPDIR/testdir/chainsymlink"
run_test "up-dir symlink" "$TMPDIR/testdir/a/upsymlink"
run_test "dotdot" "$TMPDIR/testdir/a/.."
run_test "dot" "$TMPDIR/testdir/."
run_test "root" /

# ── -e mode (all must exist) ──
run_test "-e existing" -e "$TMPDIR/testdir/realfile"
run_test_exit_only "-e nonexistent" -e "$TMPDIR/testdir/nosuchfile"
run_test_exit_only "-e broken symlink" -e "$TMPDIR/testdir/brokensymlink"

# ── -m mode (none need exist) ──
run_test "-m existing" -m "$TMPDIR/testdir/realfile"
run_test "-m nonexistent" -m "$TMPDIR/testdir/nosuchfile"
run_test "-m deep nonexistent" -m "$TMPDIR/testdir/nosuch/deep/path"

# ── -s mode (no symlinks) ──
run_test "-s regular file" -s "$TMPDIR/testdir/realfile"
run_test "-s directory" -s "$TMPDIR/testdir/a"
run_test "-s dotdot" -s "$TMPDIR/testdir/a/.."

# ── Multiple files ──
run_test "multiple files" "$TMPDIR/testdir/realfile" "$TMPDIR/testdir/a"

# ── Missing operand ──
run_test_exit_only "missing operand"

# ── Double dash ──
run_test "-- separator" -- "$TMPDIR/testdir/realfile"

# ── Trailing slashes ──
run_test "trailing slash" "$TMPDIR/testdir/a/"
run_test "multiple slashes" "$TMPDIR/testdir//a//b"

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
