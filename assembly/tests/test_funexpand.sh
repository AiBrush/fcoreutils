#!/bin/bash
# GNU compatibility tests for funexpand (assembly)
# Compares byte-for-byte stdout and exit code against GNU unexpand
# Usage: bash test_funexpand.sh [path-to-funexpand]

BIN="${1:-../unexpand/funexpand}"
GNU="/usr/bin/unexpand"

PASS=0
FAIL=0
ERRORS=()

TMPDIR=$(mktemp -d /tmp/test_funexpand.XXXXXX)
trap "rm -rf $TMPDIR" EXIT

# Hex comparison for binary-safe testing
run_test_stdin_hex() {
    local desc="$1"
    local input="$2"
    shift 2
    local args=("$@")

    local expected=$(printf "$input" | $GNU "${args[@]}" | od -An -tx1 | tr -d ' \n')
    local got=$(printf "$input" | $BIN "${args[@]}" | od -An -tx1 | tr -d ' \n')

    if [ "$expected" = "$got" ]; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
        ERRORS+=("FAIL: $desc")
        ERRORS+=("  expected hex: ${expected:0:120}")
        ERRORS+=("  got hex:      ${got:0:120}")
    fi
}

run_test_file() {
    local desc="$1"
    shift
    local args=("$@")

    $GNU "${args[@]}" > "$TMPDIR/expected" 2> "$TMPDIR/expected_err"
    local expected_exit=$?
    $BIN "${args[@]}" > "$TMPDIR/got" 2> "$TMPDIR/got_err"
    local got_exit=$?

    if diff -q "$TMPDIR/expected" "$TMPDIR/got" > /dev/null 2>&1 && \
       [ "$expected_exit" = "$got_exit" ]; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
        ERRORS+=("FAIL: $desc")
        if ! diff -q "$TMPDIR/expected" "$TMPDIR/got" > /dev/null 2>&1; then
            ERRORS+=("  output differs (hex): expected=$(od -An -tx1 "$TMPDIR/expected" | tr -d ' \n' | head -c 120)")
            ERRORS+=("                        got=$(od -An -tx1 "$TMPDIR/got" | tr -d ' \n' | head -c 120)")
        fi
        if [ "$expected_exit" != "$got_exit" ]; then
            ERRORS+=("  expected exit: $expected_exit, got: $got_exit")
        fi
    fi
}

# ── Create test files ──
printf '        hello\n        world\n' > "$TMPDIR/two_lines.txt"
printf '    x    y    z\n' > "$TMPDIR/spaces.txt"
printf '' > "$TMPDIR/empty.txt"
printf 'no spaces here\n' > "$TMPDIR/nospaces.txt"
printf '        line1\n    line2\nno_indent\n' > "$TMPDIR/mixed.txt"

echo "=== funexpand GNU compatibility tests ==="
echo ""

# ── Default mode (leading blanks only, tabstop=8) ──
echo "-- Default mode (leading blanks, tabstop=8) --"
run_test_stdin_hex "8 spaces -> tab" '        hello\n'
run_test_stdin_hex "4 spaces (no tab)" '    hello\n'
run_test_stdin_hex "16 spaces (2 tabs)" '                hello\n'
run_test_stdin_hex "9 spaces (tab + space)" '         hello\n'
run_test_stdin_hex "7 spaces (no tab)" '       hello\n'
run_test_stdin_hex "only leading, mid unchanged" '    hello    world\n'
run_test_stdin_hex "no spaces" 'hello\n'
run_test_stdin_hex "empty input" ''
run_test_stdin_hex "newline only" '\n'
run_test_stdin_hex "multiple newlines" '\n\n\n'
run_test_stdin_hex "just spaces (no newline)" '        '
run_test_stdin_hex "spaces + newline" '        \n'

# ── -a mode (convert all blanks) ──
echo "-- All blanks mode (-a) --"
run_test_stdin_hex "-a middle spaces crossing tab" 'hello   world\n' -a
run_test_stdin_hex "-a 1 space not at boundary" '12345 x\n' -a
run_test_stdin_hex "-a ab + 6 spaces" 'ab      c\n' -a
run_test_stdin_hex "-a multiple tab crossings" 'a       b       c\n' -a
run_test_stdin_hex "-a 8 spaces mid + 8 spaces" '        hello        world\n' -a
run_test_stdin_hex "-a multiple lines" 'hello   world\ngoodbye   cruel\n' -a

# ── Custom tab stop (-t) ──
echo "-- Custom tab stops --"
run_test_stdin_hex "-t 4" '    hello    world\n' -t 4
run_test_stdin_hex "-t 2" '  he  llo\n' -t 2
run_test_stdin_hex "-t 4 (implies -a)" '    he    llo\n' -t 4
run_test_stdin_hex "-t4 (no space)" '    hello\n' -t4

# ── File arguments ──
echo "-- File arguments --"
run_test_file "file argument" "$TMPDIR/two_lines.txt"
run_test_file "file with -a" -a "$TMPDIR/spaces.txt"
run_test_file "empty file" "$TMPDIR/empty.txt"
run_test_file "no spaces file" "$TMPDIR/nospaces.txt"
run_test_file "multiple files" "$TMPDIR/two_lines.txt" "$TMPDIR/mixed.txt"

# ── No spaces (passthrough) ──
echo "-- Passthrough --"
run_test_stdin_hex "no spaces passthrough" 'hello\n'

# ── Edge cases ──
echo "-- Edge cases --"
run_test_stdin_hex "all tabs passthrough" '\t\t\thello\n'
run_test_stdin_hex "mixed tabs and spaces" '\t    \t  hello\n'
run_test_stdin_hex "only whitespace line" '        \n'
run_test_stdin_hex "large indent" '                                hello\n'

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
