#!/bin/bash
# Test suite for fecho
# Usage: bash tests/run_tests.sh ./fecho

BIN="${1:-./fecho}"
# Use /usr/bin/echo as reference for most tests
GNU="/usr/bin/echo"
PASS=0
FAIL=0
ERRORS=()

run_test() {
    local desc="$1"
    local args="$2"
    local input="$3"

    if [ -n "$input" ]; then
        expected=$(echo "$input" | eval $GNU $args 2>&1)
        expected_exit=$?
        got=$(echo "$input" | eval $BIN $args 2>&1)
        eval $BIN $args > /dev/null 2>&1
        got_exit=$?
    else
        expected=$(eval $GNU $args 2>&1)
        expected_exit=$?
        got=$(eval $BIN $args 2>&1)
        eval $BIN $args > /dev/null 2>&1
        got_exit=$?
    fi

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

# Test with explicit expected bytes (not comparing against GNU)
# Usage: run_test_expected "desc" expected_exit byte_string args...
# byte_string is written to a temp file as reference
run_test_expected() {
    local desc="$1"
    local expected_exit="$2"
    local expected_bytes="$3"
    shift 3

    local expected_file=$(mktemp)
    local got_file=$(mktemp)

    printf '%s' "$expected_bytes" > "$expected_file"
    $BIN "$@" > "$got_file" 2>&1
    local got_exit=$?

    if cmp -s "$expected_file" "$got_file" && [ "$expected_exit" = "$got_exit" ]; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
        ERRORS+=("FAIL: $desc")
        if ! cmp -s "$expected_file" "$got_file"; then
            ERRORS+=("  expected bytes: $(od -c "$expected_file" | head -2)")
            ERRORS+=("  got bytes:      $(od -c "$got_file" | head -2)")
        fi
        if [ "$expected_exit" != "$got_exit" ]; then
            ERRORS+=("  expected exit: $expected_exit, got: $got_exit")
        fi
    fi

    rm -f "$expected_file" "$got_file"
}

# Use raw byte comparison for tests that need exact binary matching
run_test_raw() {
    local desc="$1"
    shift
    # Remaining args are the arguments to pass

    local expected_file=$(mktemp)
    local got_file=$(mktemp)

    $GNU "$@" > "$expected_file" 2>&1
    local expected_exit=$?
    $BIN "$@" > "$got_file" 2>&1
    local got_exit=$?

    if cmp -s "$expected_file" "$got_file" && [ "$expected_exit" = "$got_exit" ]; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
        ERRORS+=("FAIL: $desc")
        if ! cmp -s "$expected_file" "$got_file"; then
            ERRORS+=("  expected output: $(xxd "$expected_file" | head -3)")
            ERRORS+=("  got output:      $(xxd "$got_file" | head -3)")
        fi
        if [ "$expected_exit" != "$got_exit" ]; then
            ERRORS+=("  expected exit: $expected_exit, got: $got_exit")
        fi
    fi

    rm -f "$expected_file" "$got_file"
}

# ── Basic output tests ──────────────────────────────────────
run_test "no args (just newline)" "" ""
run_test "single word" "hello" ""
run_test "multiple words" "hello world" ""
run_test "three args" "a b c" ""
run_test "empty string arg" "''" ""
run_test "two empty strings" "'' ''" ""
run_test "mixed empty and non-empty" "'' hello '' world ''" ""

# ── Special characters as arguments ─────────────────────────
# Note: /usr/bin/echo handles --help/--version specially, but echo (the shell
# builtin) does not. Our implementation matches the shell builtin behavior
# (and the Rust reference implementation). Test these explicitly.
run_test_expected "--help is text" 0 $'--help\n' "--help"
run_test_expected "--version is text" 0 $'--version\n' "--version"
run_test "-- is text" "--" ""
run_test "--invalid-flag-xyz" "--invalid-flag-xyz" ""
run_test "single dash is text" "-" ""

# ── Flag tests ──────────────────────────────────────────────
run_test_raw "-n suppresses newline" -n "hello"
run_test_raw "-n with multiple args" -n "hello" "world"
run_test_raw "-n no args" -n
run_test_raw "-e with no escapes" -e "hello"
run_test_raw "-E explicit" -E "hello"

# ── Combined flags ──────────────────────────────────────────
run_test_raw "-ne combined" -ne 'hello\nworld'
run_test_raw "-en combined" -en 'hello\nworld'
run_test_raw "-neE (E overrides e)" -neE 'hello\nworld'
run_test_raw "-nEe (e overrides E)" -nEe 'hello\nworld'
run_test_raw "-eee redundant" -eee 'hello\nworld'
run_test_raw "-nnn redundant" -nnn "hello"

# ── Invalid flag stops parsing ──────────────────────────────
run_test "invalid flag -z" "-z hello" ""
run_test "invalid flag -a" "-a hello" ""
run_test "flag after non-flag" "hello -n" ""
run_test "double dash stops flags" "-- -n hello" ""

# ── Escape sequences with -e ────────────────────────────────
run_test_raw "escape backslash" -e 'hello\\world'
run_test_raw "escape alert" -e 'hello\aworld'
run_test_raw "escape backspace" -e 'hello\bworld'
run_test_raw "escape escape" -e 'hello\eworld'
run_test_raw "escape formfeed" -e 'hello\fworld'
run_test_raw "escape newline" -e 'hello\nworld'
run_test_raw "escape carriage return" -e 'hello\rworld'
run_test_raw "escape tab" -e 'hello\tworld'
run_test_raw "escape vtab" -e 'hello\vworld'

# ── \c escape (stop output) ────────────────────────────────
run_test_raw "escape \\c stops output" -e 'hello\cworld'
run_test_raw "escape \\c mid-args" -e 'hello\c' 'world'
run_test_raw "escape \\c alone" -e '\c'
run_test_raw "escape \\c with -n" -ne '\c'

# ── Octal escapes ───────────────────────────────────────────
run_test_raw "octal \\0 (NUL)" -e 'A\0B'
run_test_raw "octal \\0101 = A" -e '\0101'
run_test_raw "octal \\060 = 0" -e '\060'
run_test_raw "octal \\0377 = 0xFF" -e '\0377'
run_test_raw "octal max 3 digits" -e '\01234'
run_test_raw "octal invalid after \\0" -e '\08'

# ── Hex escapes ─────────────────────────────────────────────
run_test_raw "hex \\x41 = A" -e '\x41'
run_test_raw "hex \\x0a = newline" -e '\x0a'
run_test_raw "hex \\xZZ = literal" -e '\xZZ'
run_test_raw "hex \\x4 = single digit" -e '\x4'
run_test_raw "hex case insensitive" -e '\x4F'

# ── Unknown escapes ─────────────────────────────────────────
run_test_raw "unknown escape \\z" -e '\z'
run_test_raw "unknown escape \\q" -e '\q'
run_test_raw "trailing backslash" -e 'hello\'

# ── Escapes WITHOUT -e (should be literal) ──────────────────
run_test_raw "no -e: backslash n literal" 'hello\nworld'
run_test_raw "no -e: backslash t literal" 'hello\tworld'

# ── Edge cases ──────────────────────────────────────────────
run_test "very long single arg" "$(python3 -c "print('A' * 4000)")" ""
run_test "many args" "$(seq 1 100 | tr '\n' ' ')" ""

# ── Exit code tests ─────────────────────────────────────────
$BIN hello > /dev/null 2>&1; got_exit=$?
$GNU hello > /dev/null 2>&1; expected_exit=$?
if [ "$got_exit" = "$expected_exit" ]; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: exit code for normal output (expected $expected_exit, got $got_exit)")
fi

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
