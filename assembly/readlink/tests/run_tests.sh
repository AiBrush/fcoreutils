#!/bin/bash
# Test suite for freadlink
# Usage: bash tests/run_tests.sh ./freadlink

BIN="${1:-./freadlink}"
GNU="readlink"
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

    # Normalize tool name in error messages
    expected_err=$(echo "$expected_err" | sed "s|$(which $GNU)|$GNU|g")

    if [ "$expected" = "$got" ] && [ "$expected_exit" = "$got_exit" ] && [ "$expected_err" = "$got_err" ]; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
        ERRORS+=("FAIL: $desc")
        if [ "$expected" != "$got" ]; then
            ERRORS+=("  expected stdout: $(echo "$expected" | head -3)")
            ERRORS+=("  got stdout:      $(echo "$got" | head -3)")
        fi
        if [ "$expected_err" != "$got_err" ]; then
            ERRORS+=("  expected stderr: $(echo "$expected_err" | head -3)")
            ERRORS+=("  got stderr:      $(echo "$got_err" | head -3)")
        fi
        if [ "$expected_exit" != "$got_exit" ]; then
            ERRORS+=("  expected exit: $expected_exit, got: $got_exit")
        fi
    fi
}

# Separate test for help/version (text may differ)
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

# Test that compares only stdout and exit code (ignores stderr)
run_test_stdout() {
    local desc="$1"
    shift
    local args=("$@")

    $GNU "${args[@]}" > "$TMPDIR/expected" 2>/dev/null
    local expected_exit=$?
    $BIN "${args[@]}" > "$TMPDIR/got" 2>/dev/null
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

# ── Setup test fixtures ──
mkdir -p "$TMPDIR/testdir/a/b"
touch "$TMPDIR/testdir/realfile"
touch "$TMPDIR/testdir/a/b/deepfile"
ln -sf "$TMPDIR/testdir/realfile" "$TMPDIR/testdir/symlink1"
ln -sf realfile "$TMPDIR/testdir/relsymlink"
ln -sf ../realfile "$TMPDIR/testdir/a/upsymlink"
ln -sf a/b/deepfile "$TMPDIR/testdir/deepsymlink"
ln -sf nonexistent "$TMPDIR/testdir/brokensymlink"
ln -sf "$TMPDIR/testdir/symlink1" "$TMPDIR/testdir/chainsymlink"
ln -sf "$TMPDIR/testdir/a" "$TMPDIR/testdir/dirsymlink"

# ── Standard flags ──
run_test_exit_only "--help exit code" --help
run_test_exit_only "--version exit code" --version
run_test "invalid long flag" --invalid-flag-xyz
run_test "invalid short flag" -X

# ── FD isolation ──
run_test_fd "--help to stdout" --help
run_test_fd "error to stderr" --invalid-flag-xyz

# ── Simple readlink (no -f/-e/-m) ──
run_test_stdout "absolute symlink" "$TMPDIR/testdir/symlink1"
run_test_stdout "relative symlink" "$TMPDIR/testdir/relsymlink"
run_test_stdout "up-dir symlink" "$TMPDIR/testdir/a/upsymlink"
run_test_stdout "deep symlink" "$TMPDIR/testdir/deepsymlink"
run_test_stdout "broken symlink" "$TMPDIR/testdir/brokensymlink"
run_test_stdout "chain symlink" "$TMPDIR/testdir/chainsymlink"
run_test_stdout "dir symlink" "$TMPDIR/testdir/dirsymlink"
run_test_stdout "non-symlink file" "$TMPDIR/testdir/realfile"
run_test_stdout "non-symlink dir" "$TMPDIR/testdir/a"
run_test_stdout "nonexistent path" "$TMPDIR/testdir/nosuchfile"

# ── Multiple files ──
run_test_stdout "multiple symlinks" "$TMPDIR/testdir/symlink1" "$TMPDIR/testdir/relsymlink"
run_test_stdout "symlink + non-symlink" "$TMPDIR/testdir/symlink1" "$TMPDIR/testdir/realfile"

# ── Canonicalize -f ──
run_test_stdout "-f absolute symlink" -f "$TMPDIR/testdir/symlink1"
run_test_stdout "-f relative symlink" -f "$TMPDIR/testdir/relsymlink"
run_test_stdout "-f up-dir symlink" -f "$TMPDIR/testdir/a/upsymlink"
run_test_stdout "-f chain symlink" -f "$TMPDIR/testdir/chainsymlink"
run_test_stdout "-f dir symlink" -f "$TMPDIR/testdir/dirsymlink"
run_test_stdout "-f regular file" -f "$TMPDIR/testdir/realfile"
run_test_stdout "-f directory" -f "$TMPDIR/testdir/a"
run_test_stdout "-f dotdot" -f "$TMPDIR/testdir/a/.."
run_test_stdout "-f dot" -f "$TMPDIR/testdir/."
run_test_stdout "-f nonexistent last" -f "$TMPDIR/testdir/nosuchfile"
run_test_stdout "-f nonexistent middle" -f "$TMPDIR/testdir/nosuch/file"
run_test_stdout "-f root" -f /
run_test_stdout "-f deep symlink" -f "$TMPDIR/testdir/deepsymlink"
run_test_stdout "--canonicalize" --canonicalize "$TMPDIR/testdir/symlink1"

# ── Canonicalize -e ──
run_test_stdout "-e existing file" -e "$TMPDIR/testdir/realfile"
run_test_stdout "-e existing symlink" -e "$TMPDIR/testdir/symlink1"
run_test_stdout "-e nonexistent" -e "$TMPDIR/testdir/nosuchfile"
run_test_stdout "-e broken symlink" -e "$TMPDIR/testdir/brokensymlink"
run_test_stdout "--canonicalize-existing" --canonicalize-existing "$TMPDIR/testdir/realfile"

# ── Canonicalize -m ──
run_test_stdout "-m existing" -m "$TMPDIR/testdir/realfile"
run_test_stdout "-m nonexistent" -m "$TMPDIR/testdir/nosuchfile"
run_test_stdout "-m deep nonexistent" -m "$TMPDIR/testdir/nosuch/deep/path"
run_test_stdout "-m root" -m /
run_test_stdout "--canonicalize-missing" --canonicalize-missing "$TMPDIR/testdir/nosuchfile"

# ── Flags ──
run_test_stdout "-n no newline" -n "$TMPDIR/testdir/symlink1"
run_test_stdout "-z NUL terminator" -z "$TMPDIR/testdir/symlink1"
run_test_stdout "-nf combined" -nf "$TMPDIR/testdir/symlink1"
run_test_stdout "-zf combined" -zf "$TMPDIR/testdir/symlink1"

# ── Verbose/quiet ──
run_test "-v nonexistent" -v "$TMPDIR/testdir/nosuchfile"
run_test "-v -e nonexistent" -ve "$TMPDIR/testdir/nosuchfile"
run_test_stdout "-q nonexistent" -q "$TMPDIR/testdir/nosuchfile"
run_test_stdout "-s nonexistent" -s "$TMPDIR/testdir/nosuchfile"

# ── Double dash ──
run_test_stdout "-- separator" -- "$TMPDIR/testdir/symlink1"

# ── Missing operand ──
run_test "missing operand"

# ── Edge cases ──
run_test_stdout "-f trailing slashes" -f "$TMPDIR/testdir/a/"
run_test_stdout "-f multiple slashes" -f "$TMPDIR/testdir//a//b"

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
