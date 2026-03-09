#!/bin/bash
# GNU compatibility tests for fsort (assembly)
# Compares byte-for-byte stdout and exit code against GNU sort
# All tests use LC_ALL=C to avoid locale-dependent differences
# Usage: bash test_fsort.sh [path-to-fsort]

export LC_ALL=C

BIN="${1:-../sort/fsort}"
GNU="/usr/bin/sort"

PASS=0
FAIL=0
ERRORS=()

TMPDIR=$(mktemp -d /tmp/test_fsort.XXXXXX)
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
            ERRORS+=("  expected first 5 lines: $(head -5 "$TMPDIR/expected")")
            ERRORS+=("  got first 5 lines:      $(head -5 "$TMPDIR/got")")
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
            ERRORS+=("  expected first 5 lines: $(head -5 "$TMPDIR/expected")")
            ERRORS+=("  got first 5 lines:      $(head -5 "$TMPDIR/got")")
        fi
        if [ "$expected_exit" != "$got_exit" ]; then
            ERRORS+=("  expected exit: $expected_exit, got: $got_exit")
        fi
    fi
}

# ── Create test files ──
printf "banana\napple\ncherry\ndate\n" > "$TMPDIR/fruits.txt"
printf "3\n1\n4\n1\n5\n9\n2\n6\n" > "$TMPDIR/nums.txt"
printf "" > "$TMPDIR/empty.txt"
printf "one\n" > "$TMPDIR/single.txt"
printf "a\nb\nc\nd\ne\n" > "$TMPDIR/sorted.txt"
printf "e\nd\nc\nb\na\n" > "$TMPDIR/reversed.txt"
printf "a\nb\nc\na\nb\nc\n" > "$TMPDIR/dups.txt"
printf "10\n9\n100\n2\n1\n" > "$TMPDIR/numvals.txt"

echo "=== fsort GNU compatibility tests (LC_ALL=C) ==="
echo ""

# ── Basic sort ──
echo "-- Basic sort --"
run_test_file "basic sort" "$TMPDIR/fruits.txt"
run_test_stdin "basic stdin" "$(printf 'cherry\napple\nbanana\n')"

# ── Already sorted ──
echo "-- Already sorted --"
run_test_file "already sorted" "$TMPDIR/sorted.txt"

# ── Reverse sorted input ──
echo "-- Reverse sorted input --"
run_test_file "reverse input" "$TMPDIR/reversed.txt"

# ── Reverse (-r) ──
echo "-- Reverse (-r) --"
run_test_file "-r sort" -r "$TMPDIR/fruits.txt"
run_test_file "-r with numbers" -r "$TMPDIR/nums.txt"
run_test_stdin "-r stdin" "$(printf 'c\nb\na\n')" -r

# ── Empty input ──
echo "-- Empty input --"
run_test_file "empty file" "$TMPDIR/empty.txt"
run_test_stdin "empty stdin" ""

# ── Single line ──
echo "-- Single line --"
run_test_file "single line" "$TMPDIR/single.txt"
run_test_stdin "single line stdin" "$(printf 'hello\n')"

# ── Duplicate lines ──
echo "-- Duplicate lines --"
run_test_file "duplicates" "$TMPDIR/dups.txt"

# ── Numeric sort (-n) ──
echo "-- Numeric sort (-n) --"
run_test_file "-n sort" -n "$TMPDIR/numvals.txt"
run_test_file "-n with duplicates" -n "$TMPDIR/nums.txt"
run_test_stdin "-n negative numbers" "$(printf '5\n-3\n0\n-1\n10\n')" -n
run_test_stdin "-n with leading spaces" "$(printf '  5\n3\n  1\n')" -n

# ── Reverse numeric (-rn) ──
echo "-- Reverse numeric (-rn) --"
run_test_file "-rn sort" -rn "$TMPDIR/numvals.txt"

# ── Unique (-u) ──
echo "-- Unique (-u) --"
run_test_file "-u deduplicate" -u "$TMPDIR/dups.txt"
run_test_stdin "-u all same" "$(printf 'a\na\na\n')" -u
run_test_stdin "-u with numbers" "$(printf '3\n1\n2\n1\n3\n')" -u

# ── Check sorted (-c) ──
echo "-- Check sorted --"
run_test_file "-c sorted" -c "$TMPDIR/sorted.txt"
run_test_stdin "-c unsorted" "$(printf 'b\na\n')" -c

# ── Multiple files ──
echo "-- Multiple files --"
run_test_file "multiple files" "$TMPDIR/fruits.txt" "$TMPDIR/nums.txt"

# ── Combined flags ──
echo "-- Combined flags --"
run_test_file "-rnu" -rnu "$TMPDIR/nums.txt"
run_test_stdin "-bn blanks + numeric" "$(printf '  3\n1\n  2\n')" -bn

# ── Stable sort (-s) ──
echo "-- Stable sort --"
run_test_stdin "-s stable" "$(printf 'b 2\na 1\nb 1\na 2\n')" -s

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
