#!/bin/bash
# Test suite for ftee
# Usage: bash tests/run_tests.sh ./ftee

BIN="${1:-./ftee}"
GNU="tee"
PASS=0
FAIL=0
ERRORS=()
TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT

run_test_stdin() {
    local desc="$1"
    local input="$2"
    shift 2
    local args=("$@")

    printf '%s' "$input" | $GNU "${args[@]}" > "$TMPDIR/expected_stdout" 2> "$TMPDIR/expected_err"
    local expected_exit=$?
    printf '%s' "$input" | $BIN "${args[@]}" > "$TMPDIR/got_stdout" 2> "$TMPDIR/got_err"
    local got_exit=$?

    local expected=$(cat "$TMPDIR/expected_stdout")
    local got=$(cat "$TMPDIR/got_stdout")

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

run_test_file_content() {
    local desc="$1"
    local input="$2"
    shift 2
    local gnu_args=("$@")
    local bin_args=("$@")

    # Replace placeholder with actual temp files
    local gnu_file="$TMPDIR/gnu_out"
    local bin_file="$TMPDIR/bin_out"

    printf '%s' "$input" | $GNU "$gnu_file" > /dev/null 2>&1
    local expected_exit=$?
    local expected_content=$(cat "$gnu_file" 2>/dev/null)

    rm -f "$bin_file"
    printf '%s' "$input" | $BIN "$bin_file" > /dev/null 2>&1
    local got_exit=$?
    local got_content=$(cat "$bin_file" 2>/dev/null)

    if [ "$expected_content" = "$got_content" ] && [ "$expected_exit" = "$got_exit" ]; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
        ERRORS+=("FAIL: $desc")
        if [ "$expected_content" != "$got_content" ]; then
            ERRORS+=("  expected file: $(echo "$expected_content" | head -3)")
            ERRORS+=("  got file:      $(echo "$got_content" | head -3)")
        fi
        if [ "$expected_exit" != "$got_exit" ]; then
            ERRORS+=("  expected exit: $expected_exit, got: $got_exit")
        fi
    fi
    rm -f "$gnu_file" "$bin_file"
}

run_test_exit_only() {
    local desc="$1"
    shift
    local args=("$@")

    echo "" | $GNU "${args[@]}" > /dev/null 2>&1
    local expected_exit=$?
    echo "" | $BIN "${args[@]}" > /dev/null 2>&1
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

    echo "" | $BIN "${args[@]}" > "$TMPDIR/stdout" 2> "$TMPDIR/stderr"
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

# ── Core functionality ──
run_test_stdin "basic passthrough" "hello world"
run_test_stdin "multiline" "line1
line2
line3"
run_test_stdin "empty input" ""
run_test_stdin "binary data" "$(printf '\x00\x01\x02\x03')"

# File output
run_test_file_content "write to file" "hello from tee"

# Append mode
echo "first line" > "$TMPDIR/append_test"
echo "second line" | $BIN -a "$TMPDIR/append_test" > /dev/null 2>&1
got_append=$(cat "$TMPDIR/append_test")
expected_append="first line
second line"
if [ "$got_append" = "$expected_append" ]; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: append mode")
fi

# Multiple files
echo "multi test" | $BIN "$TMPDIR/multi1" "$TMPDIR/multi2" > /dev/null 2>&1
c1=$(cat "$TMPDIR/multi1")
c2=$(cat "$TMPDIR/multi2")
if [ "$c1" = "multi test" ] && [ "$c2" = "multi test" ]; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: multiple output files")
fi

# /dev/null as output
run_test_stdin "tee to /dev/null" "hello" /dev/null

# stdout matches input
echo "check stdout" | $BIN > "$TMPDIR/stdout_check" 2>/dev/null
got_stdout=$(cat "$TMPDIR/stdout_check")
if [ "$got_stdout" = "check stdout" ]; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: stdout should match input")
fi

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
