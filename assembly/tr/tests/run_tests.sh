#!/bin/bash
# Test suite for ftr
# Usage: bash tests/run_tests.sh ./ftr

BIN="${1:-./ftr}"
GNU="/usr/bin/tr"
TOOL="tr"

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

# ── Standard flags ───────────────────────────────────────────
run_test "--help output" --help
run_test "--version output" --version

# ── Basic translation (a-z to A-Z) ──────────────────────────
run_test_stdin "lowercase to uppercase" "hello world" 'a-z' 'A-Z'
run_test_stdin "uppercase to lowercase" "HELLO WORLD" 'A-Z' 'a-z'
run_test_stdin "translate digits" "abc123def" '0-9' 'xxxxxxxxxx'
run_test_stdin "translate single char" "aabbcc" 'a' 'x'

# ── -d (delete) ─────────────────────────────────────────────
run_test_stdin "-d delete vowels" "hello world" -d 'aeiou'
run_test_stdin "-d delete digits" "abc123def456" -d '0-9'
run_test_stdin "-d delete spaces" "hello world foo" -d ' '
run_test_stdin "-d delete single char" "aabbcc" -d 'b'

# ── -s (squeeze) ────────────────────────────────────────────
run_test_stdin "-s squeeze spaces" "hello   world" -s ' '
run_test_stdin "-s squeeze repeats" "aabbcc" -s 'abc'
run_test_stdin "-s squeeze newlines" "hello\n\n\nworld" -s '\n'

# ── Character classes ────────────────────────────────────────
run_test_stdin "[:lower:] to [:upper:]" "hello world" '[:lower:]' '[:upper:]'
run_test_stdin "[:upper:] to [:lower:]" "HELLO WORLD" '[:upper:]' '[:lower:]'
run_test_stdin "-d [:digit:]" "abc123def" -d '[:digit:]'
run_test_stdin "-d [:space:]" "hello world" -d '[:space:]'
run_test_stdin "-s [:space:]" "hello   world" -s '[:space:]'

# ── -c (complement) ─────────────────────────────────────────
run_test_stdin "-c complement translate" "hello123" -c '[:alpha:]' '_'

# ── Edge cases ───────────────────────────────────────────────
run_test_stdin "empty input" "" 'a' 'b'
run_test_stdin "no matching chars" "xyz" 'a' 'b'
run_test_stdin "all matching chars" "aaa" 'a' 'b'

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
