#!/bin/bash
# Test suite for fcksum
# Usage: bash tests/run_tests.sh ./fcksum

BIN="${1:-./fcksum}"
GNU="cksum"
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

run_test_stdin() {
    local desc="$1"
    local input="$2"

    echo -n "$input" | $GNU > "$TMPDIR/expected" 2>/dev/null
    local expected_exit=$?
    echo -n "$input" | $BIN > "$TMPDIR/got" 2>/dev/null
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

# ── Known CRC values ──
run_test_stdin "stdin: 123456789" "123456789"
run_test_stdin "stdin: empty" ""
run_test_stdin "stdin: hello+newline" "hello
"
run_test_stdin "stdin: single byte 'a'" "a"
run_test_stdin "stdin: single byte 0x00" "\x00"
run_test_stdin "stdin: ABC" "ABC"

# ── File tests ──
run_test "/dev/null" /dev/null

# Create test files
echo -n "123456789" > "$TMPDIR/test1.txt"
echo "hello" > "$TMPDIR/test2.txt"
echo -n "" > "$TMPDIR/empty.txt"
printf 'line1\nline2\nline3\n' > "$TMPDIR/multiline.txt"

run_test "file with 123456789" "$TMPDIR/test1.txt"
run_test "file with hello+newline" "$TMPDIR/test2.txt"
run_test "empty file" "$TMPDIR/empty.txt"
run_test "multiline file" "$TMPDIR/multiline.txt"

# ── Multiple files ──
run_test "two files" "$TMPDIR/test1.txt" "$TMPDIR/test2.txt"
run_test "three files" "$TMPDIR/test1.txt" "$TMPDIR/test2.txt" "$TMPDIR/empty.txt"
run_test "file + /dev/null" "$TMPDIR/test1.txt" /dev/null

# ── Stdin via dash ──
# echo -n "123456789" | cksum - reads from stdin when given "-"
# Actually GNU cksum treats "-" as stdin

# ── Standard flags ──
run_test_exit_only "--help exit code" --help
run_test_exit_only "--version exit code" --version

# ── FD isolation ──
run_test_fd "--help to stdout" --help
run_test_fd "error to stderr" /nonexistent/file/path

# ── Error handling ──
run_test "nonexistent file" /nonexistent/file/path
run_test "nonexistent + valid" /nonexistent/file/path "$TMPDIR/test1.txt"

# ── Large file ──
dd if=/dev/urandom of="$TMPDIR/largefile" bs=1024 count=100 2>/dev/null
run_test "100KB random file" "$TMPDIR/largefile"

# ── Binary content ──
printf '\x00\x01\x02\xff\xfe\xfd' > "$TMPDIR/binary.dat"
run_test "binary content" "$TMPDIR/binary.dat"

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
