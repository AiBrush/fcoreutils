#!/bin/bash
# Test suite for fpathchk
# Usage: bash tests/run_tests.sh ./fpathchk

BIN="${1:-./fpathchk}"
GNU="pathchk"
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

# Test that only checks exit code (for help/version where text may differ)
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

# Test that checks exit code matches expected value
run_test_exit() {
    local desc="$1"
    local expected_exit="$2"
    shift 2
    local args=("$@")

    $BIN "${args[@]}" > /dev/null 2> /dev/null
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

# ── Standard flags ──
run_test_exit_only "--help exit code" --help
run_test_exit_only "--version exit code" --version
run_test_exit_only "invalid long flag" --invalid-flag-xyz
run_test_exit_only "invalid short flag" -Z

# ── FD isolation ──
run_test_fd "--help to stdout" --help
run_test_fd "error to stderr"

# ── Core functionality: valid paths ──
run_test_exit "valid simple path" 0 /usr/bin/sort
run_test_exit "valid relative path" 0 file.txt
run_test_exit "valid path with dots" 0 ../some/path
run_test_exit "valid root" 0 /
run_test_exit "valid dot" 0 .
run_test_exit "valid dotdot" 0 ..
run_test_exit "valid multiple slashes" 0 /usr///bin///sort
run_test_exit "valid single char" 0 a
run_test_exit "valid underscore" 0 _file
run_test_exit "valid multiple paths" 0 /usr/bin /tmp

# ── Multiple paths ──
run_test_exit "multiple valid paths" 0 path1 path2 path3
run_test_exit "multiple paths one invalid -p" 1 -p ok "hello@world"

# ── -p flag: POSIX portability ──
run_test_exit "-p valid short name" 0 -p abc
run_test_exit "-p valid 14 chars" 0 -p "$(printf 'a%.0s' {1..14})"
run_test_exit "-p too long component" 1 -p "$(printf 'a%.0s' {1..15})"
run_test_exit "-p non-portable @" 1 -p "hello@world"
run_test_exit "-p non-portable space" 1 -p "hello world"
run_test_exit "-p valid path separators" 0 -p "a/b/c"
run_test_exit "-p valid with dots" 0 -p "a.b"
run_test_exit "-p valid with hyphen" 0 -p "a-b"
run_test_exit "-p valid with underscore" 0 -p "a_b"

# ── -P flag: extra checks ──
run_test_exit "-P valid path" 0 -P validpath
run_test_exit "-P empty string" 1 -P ""
run_test_exit "-P leading hyphen" 1 -P -- "-file"
run_test_exit "-P no leading hyphen" 0 -P file
run_test_exit "-P path with slashes" 0 -P /usr/bin/sort

# ── Combined -p -P ──
run_test_exit "-pP valid" 0 -pP valid
run_test_exit "-pP empty" 1 -pP ""
run_test_exit "-pP leading hyphen" 1 -pP -- "-file"
run_test_exit "-pP non-portable char" 1 -pP "hello@world"

# ── --portability flag ──
run_test_exit "--portability valid" 0 --portability valid
run_test_exit "--portability empty" 1 --portability ""
run_test_exit "--portability leading hyphen" 1 --portability -- "-file"

# ── Error messages (compare with GNU) ──
run_test "-P empty string message" -P ""
run_test "-P leading hyphen message" -P -- "-file"
run_test "missing operand message"

# ── Double dash ──
run_test_exit "-- separator" 0 -- /usr/bin/sort
run_test_exit "-- with -p" 0 -p -- valid
run_test_exit "-- stops option parsing" 0 -- -p

# ── Edge cases ──
run_test_exit "bare dash is valid path" 0 -
run_test_exit "path with trailing slash" 0 /usr/bin/
run_test_exit "empty string without -P" 1 ""

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
