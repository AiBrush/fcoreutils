#!/bin/bash
# Test suite for fbase64
# Usage: bash tests/run_tests.sh ./fbase64

BIN="${1:-./fbase64}"
GNU="/usr/bin/base64"
TOOL="base64"

PASS=0
FAIL=0
ERRORS=()

normalize_gnu() {
    sed -e "s|$GNU|PROG|g" -e "s|Usage: $TOOL|Usage: PROG|g" -e "s|^$TOOL |PROG |g"
}

normalize_our() {
    sed -e "s|$BIN|PROG|g" -e "s|Usage: $TOOL|Usage: PROG|g" -e "s|^$TOOL |PROG |g"
}

run_test() {
    local desc="$1"
    shift
    local args=("$@")

    expected=$($GNU "${args[@]}" 2>&1 | normalize_gnu)
    expected_exit=$?
    got=$($BIN "${args[@]}" 2>&1 | normalize_our)
    got_exit=$?

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

run_test_stdin() {
    local desc="$1"
    local input="$2"
    shift 2
    local args=("$@")

    expected=$(echo -e "$input" | $GNU "${args[@]}" 2>&1 | normalize_gnu)
    expected_exit=$?
    got=$(echo -e "$input" | $BIN "${args[@]}" 2>&1 | normalize_our)
    got_exit=$?

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

run_test_printf() {
    local desc="$1"
    local input="$2"
    shift 2
    local args=("$@")

    expected=$(printf "%s" "$input" | $GNU "${args[@]}" 2>&1 | normalize_gnu)
    expected_exit=$?
    got=$(printf "%s" "$input" | $BIN "${args[@]}" 2>&1 | normalize_our)
    got_exit=$?

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

# ── Setup temp files ─────────────────────────────────────────
TMPDIR=$(mktemp -d /tmp/b64_test.XXXXXX)
trap "rm -rf $TMPDIR" EXIT

printf "hello world\n" > "$TMPDIR/basic.txt"
printf "aGVsbG8gd29ybGQK\n" > "$TMPDIR/encoded.txt"
echo -n "" > "$TMPDIR/empty.txt"

# ── Standard flags ───────────────────────────────────────────
# SKIP: --help/--version text is version-specific, tested in security_tests.py instead
#run_test "--help output" --help
#run_test "--version output" --version

# ── Encode basic string ──────────────────────────────────────
run_test_stdin "encode hello" "hello"
run_test_stdin "encode hello world" "hello world"
run_test_stdin "encode numbers" "1234567890"
run_test_printf "encode no newline" "hello"

# ── Decode basic string (-d) ────────────────────────────────
run_test_stdin "decode aGVsbG8K" "aGVsbG8K" -d
run_test_stdin "decode aGVsbG8gd29ybGQK" "aGVsbG8gd29ybGQK" -d
run_test_stdin "decode MTIzNDU2Nzg5MAo=" "MTIzNDU2Nzg5MAo=" -d

# ── Empty input ──────────────────────────────────────────────
run_test_printf "encode empty input" ""
run_test "encode empty file" "$TMPDIR/empty.txt"

# ── -w0 (no wrap) ───────────────────────────────────────────
run_test_stdin "encode -w0 no wrap" "hello" -w0
run_test_printf "encode -w0 no newline" "hello" -w0

# ── Long input (wrap at 76) ─────────────────────────────────
run_test_printf "encode long input (wraps at 76)" "$(printf '%0100d' 0)"
run_test_printf "encode long input -w0" "$(printf '%0100d' 0)" -w0

# ── File arguments ───────────────────────────────────────────
run_test "encode from file" "$TMPDIR/basic.txt"
run_test "decode from file" -d "$TMPDIR/encoded.txt"

# ── Custom wrap width ───────────────────────────────────────
run_test_stdin "encode -w 20 (custom wrap)" "hello world this is a test" -w 20

# ── Decode with newlines in encoded data ─────────────────────
run_test_stdin "decode multiline encoded" "aGVs\nbG8K" -d

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
