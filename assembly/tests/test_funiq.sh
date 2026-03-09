#!/bin/bash
# GNU compatibility tests for funiq (assembly)
# Compares byte-for-byte stdout and exit code against GNU uniq
# Usage: bash test_funiq.sh [path-to-funiq]

BIN="${1:-../uniq/funiq}"
GNU="/usr/bin/uniq"

PASS=0
FAIL=0
ERRORS=()

TMPDIR=$(mktemp -d /tmp/test_funiq.XXXXXX)
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
            ERRORS+=("  expected first 3 lines: $(head -3 "$TMPDIR/expected")")
            ERRORS+=("  got first 3 lines:      $(head -3 "$TMPDIR/got")")
        fi
        if [ "$expected_exit" != "$got_exit" ]; then
            ERRORS+=("  expected exit: $expected_exit, got: $got_exit")
        fi
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
            ERRORS+=("  expected first 3 lines: $(head -3 "$TMPDIR/expected")")
            ERRORS+=("  got first 3 lines:      $(head -3 "$TMPDIR/got")")
        fi
        if [ "$expected_exit" != "$got_exit" ]; then
            ERRORS+=("  expected exit: $expected_exit, got: $got_exit")
        fi
    fi
}

# ── Create test files ──
printf "a\na\na\nb\nc\nc\n" > "$TMPDIR/basic.txt"
printf "" > "$TMPDIR/empty.txt"
printf "hello\n" > "$TMPDIR/single.txt"
printf "Hello\nhello\nHELLO\nworld\n" > "$TMPDIR/case.txt"
printf "a\na\na\na\na\n" > "$TMPDIR/allsame.txt"
printf "a\nb\nc\nd\ne\n" > "$TMPDIR/nodups.txt"

echo "=== funiq GNU compatibility tests ==="
echo ""

# ── Basic sorted file comparison ──
echo "-- Basic operation --"
run_test_file "basic dedup from file" "$TMPDIR/basic.txt"
run_test_stdin "basic dedup stdin" "$(printf 'a\na\na\nb\nc\nc\n')"
run_test_stdin "single line" "$(printf 'hello\n')"
run_test_stdin "empty input" ""
run_test_stdin "no trailing newline" "hello"

# ── No duplicates ──
echo "-- No duplicates --"
run_test_file "no duplicates" "$TMPDIR/nodups.txt"
run_test_stdin "no dups stdin" "$(printf 'a\nb\nc\nd\n')"

# ── All same line ──
echo "-- All same --"
run_test_file "all same" "$TMPDIR/allsame.txt"
run_test_stdin "all same stdin" "$(printf 'x\nx\nx\nx\n')"

# ── Count (-c) ──
echo "-- Count (-c) --"
run_test_stdin "-c basic" "$(printf 'a\na\na\nb\nc\nc\n')" -c
run_test_stdin "-c single" "$(printf 'hello\n')" -c
run_test_stdin "-c all same" "$(printf 'a\na\na\na\na\n')" -c
run_test_stdin "-c all different" "$(printf 'a\nb\nc\n')" -c
run_test_file "-c from file" -c "$TMPDIR/basic.txt"

# ── Duplicates only (-d) ──
echo "-- Duplicates only (-d) --"
run_test_stdin "-d basic" "$(printf 'a\na\na\nb\nc\nc\n')" -d
run_test_stdin "-d no repeats" "$(printf 'a\nb\nc\n')" -d
run_test_stdin "-d all same" "$(printf 'a\na\na\n')" -d
run_test_file "-d from file" -d "$TMPDIR/basic.txt"

# ── Unique only (-u) ──
echo "-- Unique only (-u) --"
run_test_stdin "-u basic" "$(printf 'a\na\na\nb\nc\nc\n')" -u
run_test_stdin "-u no repeats" "$(printf 'a\nb\nc\n')" -u
run_test_stdin "-u all same" "$(printf 'a\na\na\n')" -u
run_test_file "-u from file" -u "$TMPDIR/basic.txt"

# ── Case insensitive (-i) ──
echo "-- Case insensitive (-i) --"
run_test_stdin "-i basic" "$(printf 'Hello\nhello\nHELLO\nworld\n')" -i
run_test_stdin "-ci" "$(printf 'Hello\nhello\nHELLO\nworld\n')" -c -i
run_test_stdin "-di" "$(printf 'Hello\nhello\nHELLO\nworld\n')" -d -i
run_test_stdin "-ui" "$(printf 'Hello\nhello\nHELLO\nworld\n')" -u -i
run_test_file "-i from file" -i "$TMPDIR/case.txt"

# ── Empty input ──
echo "-- Empty input --"
run_test_stdin "empty stdin" ""
run_test_file "empty file" "$TMPDIR/empty.txt"

# ── Edge cases ──
echo "-- Edge cases --"
run_test_stdin "whitespace lines" "$(printf '  \n  \n\t\n')"
run_test_stdin "blank lines" "$(printf '\n\n\na\n')"

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
