#!/bin/bash
# Test suite for fprintf
# Usage: bash tests/run_tests.sh ./fprintf

BIN="${1:-./fprintf}"
GNU="/usr/bin/printf"
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

    PASS=$((PASS+1))
}

# ── Standard flags ──
run_test_exit_only "--help exit code" --help
run_test_exit_only "--version exit code" --version

# ── FD isolation ──
run_test_fd "--help to stdout" --help

# ── Basic strings ──
run_test "simple string" "hello"
run_test "string with newline" "hello\n"
run_test "string with tab" "hello\tworld"
run_test "empty format" ""

# ── %s format ──
run_test "%s string" "%s" "hello"
run_test "%s multiple" "%s %s" "hello" "world"
run_test "%s no arg" "%s"

# ── %d format ──
run_test "%d positive" "%d" "42"
run_test "%d negative" "%d" "-42"
run_test "%d zero" "%d" "0"

# ── %u format ──
run_test "%u unsigned" "%u" "42"
run_test "%u zero" "%u" "0"

# ── %o format ──
run_test "%o octal" "%o" "8"
run_test "%o zero" "%o" "0"
run_test "%o 255" "%o" "255"

# ── %x format ──
run_test "%x hex" "%x" "255"
run_test "%x zero" "%x" "0"
run_test "%x 16" "%x" "16"

# ── %X format ──
run_test "%X hex" "%X" "255"

# ── %c format ──
run_test "%c char" "%c" "A"
run_test "%c char B" "%c" "B"

# ── %% literal ──
run_test "%% literal" "100%%"

# ── Escape sequences ──
run_test "\\n newline" "line1\nline2"
run_test "\\t tab" "col1\tcol2"
run_test "\\\\ backslash" "back\\\\slash"

# ── Recycling args ──
run_test "recycle format" "%s\n" "a" "b" "c"

# ── Character value with quote ──
run_test "%d char A" "%d" "'A"

# ── Missing operand ──
run_test_exit_only "no args"

# ── Multiple format specifiers ──
run_test "multi spec" "%s=%d" "x" "42"

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
