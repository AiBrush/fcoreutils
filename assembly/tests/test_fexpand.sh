#!/bin/bash
# GNU compatibility tests for fexpand (assembly)
# Compares byte-for-byte stdout and exit code against GNU expand
# Usage: bash test_fexpand.sh [path-to-fexpand]

BIN="${1:-../expand/fexpand}"
GNU="/usr/bin/expand"

PASS=0
FAIL=0
ERRORS=()

TMPDIR=$(mktemp -d /tmp/test_fexpand.XXXXXX)
trap "rm -rf $TMPDIR" EXIT

run_test_stdin() {
    local desc="$1"
    local input="$2"
    shift 2
    local args=("$@")

    printf '%s' "$input" | $GNU "${args[@]}" > "$TMPDIR/expected" 2> "$TMPDIR/expected_err"
    local expected_exit=$?
    printf '%s' "$input" | $BIN "${args[@]}" > "$TMPDIR/got" 2> "$TMPDIR/got_err"
    local got_exit=$?

    if diff -q "$TMPDIR/expected" "$TMPDIR/got" > /dev/null 2>&1 && \
       [ "$expected_exit" = "$got_exit" ]; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
        ERRORS+=("FAIL: $desc")
        if ! diff -q "$TMPDIR/expected" "$TMPDIR/got" > /dev/null 2>&1; then
            ERRORS+=("  expected (cat -A): $(head -3 "$TMPDIR/expected" | cat -A)")
            ERRORS+=("  got (cat -A):      $(head -3 "$TMPDIR/got" | cat -A)")
        fi
        if [ "$expected_exit" != "$got_exit" ]; then
            ERRORS+=("  expected exit: $expected_exit, got: $got_exit")
        fi
    fi
}

run_test_file() {
    local desc="$1"
    local file="$2"
    shift 2
    local args=("$@")

    $GNU "${args[@]}" "$file" > "$TMPDIR/expected" 2> "$TMPDIR/expected_err"
    local expected_exit=$?
    $BIN "${args[@]}" "$file" > "$TMPDIR/got" 2> "$TMPDIR/got_err"
    local got_exit=$?

    if diff -q "$TMPDIR/expected" "$TMPDIR/got" > /dev/null 2>&1 && \
       [ "$expected_exit" = "$got_exit" ]; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
        ERRORS+=("FAIL: $desc")
        if ! diff -q "$TMPDIR/expected" "$TMPDIR/got" > /dev/null 2>&1; then
            ERRORS+=("  expected (cat -A): $(head -3 "$TMPDIR/expected" | cat -A)")
            ERRORS+=("  got (cat -A):      $(head -3 "$TMPDIR/got" | cat -A)")
        fi
        if [ "$expected_exit" != "$got_exit" ]; then
            ERRORS+=("  expected exit: $expected_exit, got: $got_exit")
        fi
    fi
}

# ── Create test files ──
printf 'a\tb\tc\n' > "$TMPDIR/tabs.txt"
printf '\thello\n' > "$TMPDIR/leading_tab.txt"
printf '\t\thello\n' > "$TMPDIR/double_tab.txt"
printf 'hello\t\n' > "$TMPDIR/trailing_tab.txt"
printf 'a\tb\n\tc\td\n' > "$TMPDIR/multiline.txt"
printf 'hello world\n' > "$TMPDIR/notabs.txt"
printf '' > "$TMPDIR/empty.txt"
printf '\t \thello\n' > "$TMPDIR/mixed.txt"
printf '    a\tb\tc\n' > "$TMPDIR/spaces_and_tabs.txt"

echo "=== fexpand GNU compatibility tests ==="
echo ""

# ── Basic tab expansion (default tab stop 8) ──
echo "-- Basic tab expansion --"
run_test_stdin "default tab expansion" "$(printf 'a\tb\tc')"
run_test_stdin "tab at start" "$(printf '\thello')"
run_test_stdin "double tab" "$(printf '\t\thello')"
run_test_stdin "tab at end" "$(printf 'hello\t')"
run_test_stdin "multiple lines with tabs" "$(printf 'a\tb\n\tc\td')"
run_test_file "tab file" "$TMPDIR/tabs.txt"
run_test_file "leading tab file" "$TMPDIR/leading_tab.txt"

# ── No tabs in input (passthrough) ──
echo "-- Passthrough --"
run_test_stdin "no tabs passthrough" "hello world"
run_test_file "no tabs file" "$TMPDIR/notabs.txt"

# ── Empty input ──
echo "-- Empty input --"
run_test_stdin "empty input" ""
run_test_file "empty file" "$TMPDIR/empty.txt"

# ── Custom tab stop -t 4 ──
echo "-- Custom tab stops --"
run_test_stdin "-t 4" "$(printf 'a\tb\tc')" -t 4
run_test_stdin "-t 2" "$(printf 'a\tb\tc')" -t 2
run_test_stdin "-t 1" "$(printf 'a\tb\tc')" -t 1
run_test_stdin "-t 16" "$(printf 'a\tb')" -t 16

# ── Only leading tabs (-i) ──
echo "-- Initial only (-i) --"
run_test_stdin "-i no leading tab" "$(printf 'a\tb\tc')" -i
run_test_stdin "-i with leading tab" "$(printf '\ta\tb\tc')" -i
run_test_stdin "-i double leading tab" "$(printf '\t\ta\tb\tc')" -i

# ── Mixed tabs and spaces ──
echo "-- Mixed tabs and spaces --"
run_test_stdin "mixed tabs and spaces" "$(printf '\t \thello')"
run_test_file "mixed file" "$TMPDIR/mixed.txt"
run_test_file "spaces and tabs file" "$TMPDIR/spaces_and_tabs.txt"

# ── Just tab, just newline ──
echo "-- Edge cases --"
run_test_stdin "just tab" "$(printf '\t')"
run_test_stdin "just newline" "$(printf '\n')"
run_test_stdin "tab then newline" "$(printf '\t\n')"
run_test_stdin "newline then tab" "$(printf '\n\t')"
run_test_stdin "only tabs" "$(printf '\t\t\t')"

# ── Tab at exact column boundary ──
echo "-- Column boundary --"
run_test_stdin "tab at exact boundary -t 4" "$(printf 'abcd\te')" -t 4
run_test_stdin "tab one before boundary -t 4" "$(printf 'abc\te')" -t 4
run_test_stdin "tab two before boundary -t 4" "$(printf 'ab\te')" -t 4

# ── Long option forms ──
echo "-- Long options --"
run_test_stdin "--tabs=4" "$(printf 'a\tb')" --tabs=4
run_test_stdin "--initial" "$(printf '\ta\tb')" --initial

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
