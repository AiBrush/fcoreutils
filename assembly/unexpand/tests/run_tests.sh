#!/bin/bash
# Test suite for funexpand
# Usage: bash tests/run_tests.sh ./funexpand

BIN="${1:-./funexpand}"
GNU="/usr/bin/unexpand"
TOOL="unexpand"

PASS=0
FAIL=0
ERRORS=()

run_test() {
    local desc="$1"
    shift
    local args=("$@")

    expected=$($GNU "${args[@]}" 2>&1)
    expected_exit=$?
    got=$($BIN "${args[@]}" 2>&1)
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

    expected=$(printf "$input" | $GNU "${args[@]}" 2>&1)
    expected_exit=$?
    got=$(printf "$input" | $BIN "${args[@]}" 2>&1)
    got_exit=$?

    if [ "$expected" = "$got" ] && [ "$expected_exit" = "$got_exit" ]; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
        ERRORS+=("FAIL: $desc")
        if [ "$expected" != "$got" ]; then
            ERRORS+=("  expected: $(echo "$expected" | cat -A | head -3)")
            ERRORS+=("  got:      $(echo "$got" | cat -A | head -3)")
        fi
        if [ "$expected_exit" != "$got_exit" ]; then
            ERRORS+=("  expected exit: $expected_exit, got: $got_exit")
        fi
    fi
}

# hex comparison for binary-safe testing
run_test_stdin_hex() {
    local desc="$1"
    local input="$2"
    shift 2
    local args=("$@")

    expected=$(printf "$input" | $GNU "${args[@]}" | od -An -tx1 | tr -d ' \n')
    got=$(printf "$input" | $BIN "${args[@]}" | od -An -tx1 | tr -d ' \n')

    if [ "$expected" = "$got" ]; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
        ERRORS+=("FAIL: $desc")
        ERRORS+=("  expected hex: $expected")
        ERRORS+=("  got hex:      $got")
    fi
}

# ── Setup temp files ─────────────────────────────────────────
TMPDIR=$(mktemp -d /tmp/unexpand_test.XXXXXX)
trap "rm -rf $TMPDIR" EXIT

printf '        hello\n        world\n' > "$TMPDIR/two_lines.txt"
printf '    x    y    z\n' > "$TMPDIR/spaces.txt"
printf '' > "$TMPDIR/empty.txt"
printf 'no spaces here\n' > "$TMPDIR/nospaces.txt"
printf '        line1\n    line2\nno_indent\n' > "$TMPDIR/mixed.txt"

# ═══════════════════════════════════════════════════════════
#  Default mode (leading blanks only, tabstop=8)
# ═══════════════════════════════════════════════════════════

run_test_stdin_hex "default: 8 spaces" '        hello\n'
run_test_stdin_hex "default: 4 spaces (no tab)" '    hello\n'
run_test_stdin_hex "default: 16 spaces (2 tabs)" '                hello\n'
run_test_stdin_hex "default: 9 spaces (tab + space)" '         hello\n'
run_test_stdin_hex "default: 12 spaces (tab + 4 spaces)" '            hello\n'
run_test_stdin_hex "default: 7 spaces (no tab)" '       hello\n'
run_test_stdin_hex "default: only leading" '    hello    world\n'
run_test_stdin_hex "default: tab + 4 spaces" '\t    hello\n'
run_test_stdin_hex "default: 3 spaces + tab" '   \t   hello\n'
run_test_stdin_hex "default: just a tab" '\thello\n'
run_test_stdin_hex "default: no spaces" 'hello\n'
run_test_stdin_hex "default: empty" ''
run_test_stdin_hex "default: newline only" '\n'
run_test_stdin_hex "default: multiple newlines" '\n\n\n'
run_test_stdin_hex "default: no trailing newline" 'hello'
run_test_stdin_hex "default: just spaces" '        '
run_test_stdin_hex "default: spaces + newline" '        \n'
run_test_stdin_hex "default: mixed indent" '        line1\n    line2\nno_indent\n'

# ═══════════════════════════════════════════════════════════
#  -a mode (convert all blanks)
# ═══════════════════════════════════════════════════════════

run_test_stdin_hex "-a: middle spaces crossing tab" 'hello   world\n' -a
run_test_stdin_hex "-a: 2 spaces cross tab" '123456  x\n' -a
run_test_stdin_hex "-a: 3 spaces cross tab" '12345   x\n' -a
run_test_stdin_hex "-a: 1 space at tab boundary (no convert)" '1234567 x\n' -a
run_test_stdin_hex "-a: 1 space not at boundary" '12345 x\n' -a
run_test_stdin_hex "-a: trailing spaces reaching tab" 'hello   \n' -a
run_test_stdin_hex "-a: trailing spaces not reaching" 'hello  \n' -a
run_test_stdin_hex "-a: ab + 6 spaces" 'ab      c\n' -a
run_test_stdin_hex "-a: a + 7 spaces" 'a       b\n' -a
run_test_stdin_hex "-a: multiple tab crossings" 'a       b       c\n' -a
run_test_stdin_hex "-a: 2 spaces at tab boundary" '12345678  x\n' -a
run_test_stdin_hex "-a: tab at col 0" '\thello\n' -a
run_test_stdin_hex "-a: spaces at end of line" 'hello        \n' -a
run_test_stdin_hex "-a: 8 spaces mid + 8 spaces" '        hello        world\n' -a
run_test_stdin_hex "-a: 2 spaces not reaching" '1234  x\n' -a
run_test_stdin_hex "-a: multiple lines" 'hello   world\ngoodbye   cruel\n' -a
run_test_stdin_hex "-a: space + tab" ' \thello\n' -a
run_test_stdin_hex "-a: tab + space + tab" '\t \thello\n' -a

# ═══════════════════════════════════════════════════════════
#  -t N (custom tab stop)
# ═══════════════════════════════════════════════════════════

run_test_stdin_hex "-t 4" '    hello    world\n' -t 4
run_test_stdin_hex "-t 2" '  he  llo\n' -t 2
run_test_stdin_hex "-t 4 (implies -a)" '    he    llo\n' -t 4
run_test_stdin_hex "-t4 (no space)" '    hello\n' -t4
run_test_stdin_hex "-t 1 (every position)" '  hello\n' -t 1

# ═══════════════════════════════════════════════════════════
#  -t LIST (comma-separated tab stops)
# ═══════════════════════════════════════════════════════════

run_test_stdin_hex "-t 4,8 list" '    x    y\n' -t 4,8
run_test_stdin_hex "-t 5,10 list" '     abc     def\n' -t 5,10
run_test_stdin_hex "-t 1,5,9 list" ' abc    def\n' -t 1,5,9

# ═══════════════════════════════════════════════════════════
#  --first-only
# ═══════════════════════════════════════════════════════════

run_test_stdin_hex "first-only overrides -a" '        x        y\n' -a --first-only
run_test_stdin_hex "first-only alone" '        x        y\n' --first-only

# ═══════════════════════════════════════════════════════════
#  File arguments
# ═══════════════════════════════════════════════════════════

run_test "file argument" "$TMPDIR/two_lines.txt"
run_test "file with -a" -a "$TMPDIR/spaces.txt"
run_test "empty file" "$TMPDIR/empty.txt"
run_test "no spaces file" "$TMPDIR/nospaces.txt"
run_test "multiple files" "$TMPDIR/two_lines.txt" "$TMPDIR/mixed.txt"
run_test "- for stdin via file" -

# ═══════════════════════════════════════════════════════════
#  Backspace handling
# ═══════════════════════════════════════════════════════════

run_test_stdin_hex "backspace" '12\b     x\n' -a

# ═══════════════════════════════════════════════════════════
#  Edge cases
# ═══════════════════════════════════════════════════════════

run_test_stdin_hex "all tabs" '\t\t\thello\n'
run_test_stdin_hex "mixed tabs and spaces" '\t    \t  hello\n'
run_test_stdin_hex "only whitespace line" '        \n'
run_test_stdin_hex "large indent" '                                hello\n'

# ═══════════════════════════════════════════════════════════
#  Results
# ═══════════════════════════════════════════════════════════

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
