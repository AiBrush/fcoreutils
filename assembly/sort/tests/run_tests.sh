#!/bin/bash
# Test suite for fsort
# Usage: bash tests/run_tests.sh ./fsort

BIN="${1:-./fsort}"
GNU="/usr/bin/sort"
TOOL="sort"

PASS=0
FAIL=0
ERRORS=()

normalize_gnu() {
    sed -e "s|$GNU|PROG|g" -e "s|Usage: $TOOL|Usage: PROG|g" -e "s|^$TOOL:|PROG:|g"
}

normalize_our() {
    sed -e "s|$BIN|PROG|g" -e "s|Usage: $TOOL|Usage: PROG|g" -e "s|^$TOOL:|PROG:|g"
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

    expected=$(printf '%s' "$input" | $GNU "${args[@]}" 2>&1 | normalize_gnu)
    expected_exit=$?
    got=$(printf '%s' "$input" | $BIN "${args[@]}" 2>&1 | normalize_our)
    got_exit=$?

    if [ "$expected" = "$got" ] && [ "$expected_exit" = "$got_exit" ]; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
        ERRORS+=("FAIL: $desc")
        if [ "$expected" != "$got" ]; then
            ERRORS+=("  expected: $(echo "$expected" | head -5)")
            ERRORS+=("  got:      $(echo "$got" | head -5)")
        fi
        if [ "$expected_exit" != "$got_exit" ]; then
            ERRORS+=("  expected exit: $expected_exit, got: $got_exit")
        fi
    fi
}

# ── Setup temp files ─────────────────────────────────────────
TMPDIR=$(mktemp -d /tmp/sort_test.XXXXXX)
trap "rm -rf $TMPDIR" EXIT

# Create test files
printf "banana\napple\ncherry\ndate\n" > "$TMPDIR/fruits.txt"
printf "3\n1\n4\n1\n5\n9\n2\n6\n" > "$TMPDIR/nums.txt"
printf "" > "$TMPDIR/empty.txt"
printf "one\n" > "$TMPDIR/single.txt"
printf "a\nb\nc\nd\ne\n" > "$TMPDIR/sorted.txt"
printf "e\nd\nc\nb\na\n" > "$TMPDIR/reversed.txt"
printf "Banana\napple\nCherry\ndate\nApple\n" > "$TMPDIR/mixed_case.txt"
printf "foo:3\nbar:1\nbaz:2\n" > "$TMPDIR/delimited.txt"
printf "alpha beta 3\ngamma delta 1\nepsilon zeta 2\n" > "$TMPDIR/fields.txt"
printf "a\nb\nc\na\nb\nc\n" > "$TMPDIR/dups.txt"
seq 1 100 | shuf > "$TMPDIR/hundred.txt"
printf "10\n9\n100\n2\n1\n" > "$TMPDIR/numvals.txt"
printf "  foo\n  bar\nbaz\n" > "$TMPDIR/blanks.txt"
printf "JAN\nMAR\nFEB\nDEC\nAPR\n" > "$TMPDIR/months.txt"
printf "1.2\n1.10\n1.1\n1.9\n" > "$TMPDIR/versions.txt"

# ── Basic sort (lexicographic) ───────────────────────────────
run_test "basic sort file" "$TMPDIR/fruits.txt"
run_test "empty file" "$TMPDIR/empty.txt"
run_test "single line" "$TMPDIR/single.txt"
run_test "already sorted" "$TMPDIR/sorted.txt"
run_test "reverse input" "$TMPDIR/reversed.txt"
run_test "hundred numbers" "$TMPDIR/hundred.txt"
run_test_stdin "stdin sort" "$(printf 'cherry\napple\nbanana\n')"

# ── Reverse sort (-r) ───────────────────────────────────────
run_test "-r sort" -r "$TMPDIR/fruits.txt"
run_test "-r with numbers" -r "$TMPDIR/nums.txt"
run_test_stdin "-r stdin" "$(printf 'c\nb\na\n')" -r

# ── Numeric sort (-n) ───────────────────────────────────────
run_test "-n sort" -n "$TMPDIR/numvals.txt"
run_test "-n with duplicates" -n "$TMPDIR/nums.txt"
run_test_stdin "-n negative numbers" "$(printf '5\n-3\n0\n-1\n10\n')" -n
run_test_stdin "-n with leading spaces" "$(printf '  5\n3\n  1\n')" -n

# ── Reverse numeric (-rn) ───────────────────────────────────
run_test "-rn sort" -rn "$TMPDIR/numvals.txt"

# ── Unique (-u) ─────────────────────────────────────────────
run_test "-u deduplicate" -u "$TMPDIR/dups.txt"
run_test_stdin "-u with numbers" "$(printf '3\n1\n2\n1\n3\n')" -u
run_test_stdin "-u all same" "$(printf 'a\na\na\n')" -u

# ── Fold case (-f) ──────────────────────────────────────────
run_test "-f fold case" -f "$TMPDIR/mixed_case.txt"
run_test_stdin "-f simple" "$(printf 'B\na\nC\n')" -f

# ── Ignore leading blanks (-b) ──────────────────────────────
run_test "-b ignore leading blanks" -b "$TMPDIR/blanks.txt"

# ── Dictionary order (-d) ───────────────────────────────────
run_test_stdin "-d dictionary" "$(printf 'b-b\na.a\nc_c\n')" -d

# ── Ignore non-printing (-i) ────────────────────────────────
run_test_stdin "-i ignore non-printing" "$(printf 'beta\nalpha\ngamma\n')" -i

# ── Stable sort (-s) ────────────────────────────────────────
run_test_stdin "-s stable" "$(printf 'b 2\na 1\nb 1\na 2\n')" -s

# ── Field delimiter (-t) ────────────────────────────────────
run_test "-t colon" -t : "$TMPDIR/delimited.txt"
run_test_stdin "-t comma" "$(printf 'c,3\na,1\nb,2\n')" -t ,

# ── Sort keys (-k) ──────────────────────────────────────────
run_test "-k2 field sort" -k 2 "$TMPDIR/fields.txt"
run_test_stdin "-k2,2 single field" "$(printf 'x b\ny a\nz c\n')" -k 2,2
run_test_stdin "-k2n,2 numeric key" "$(printf 'a 3\nb 1\nc 2\n')" -k 2n,2
run_test_stdin "-k1,1 -k2n,2 multi-key" "$(printf 'b 2\na 3\nb 1\na 1\n')" -k 1,1 -k 2n,2
run_test "-t: -k2,2 delimited key" -t : -k 2,2 "$TMPDIR/delimited.txt"

# ── Check sorted (-c) ───────────────────────────────────────
run_test "-c sorted input" -c "$TMPDIR/sorted.txt"
run_test_stdin "-c unsorted" "$(printf 'b\na\n')" -c

# ── Check quiet (-C) ────────────────────────────────────────
run_test_stdin "-C sorted" "$(printf 'a\nb\nc\n')" -C
run_test_stdin "-C unsorted" "$(printf 'b\na\n')" -C

# ── Unique + check (-cu) ────────────────────────────────────
run_test_stdin "-cu unique sorted" "$(printf 'a\nb\nc\n')" -cu
run_test_stdin "-cu with dups" "$(printf 'a\na\nb\n')" -cu

# ── Output file (-o) ────────────────────────────────────────
$GNU -o "$TMPDIR/gnu_out.txt" "$TMPDIR/fruits.txt"
$BIN -o "$TMPDIR/our_out.txt" "$TMPDIR/fruits.txt"
if diff -q "$TMPDIR/gnu_out.txt" "$TMPDIR/our_out.txt" > /dev/null 2>&1; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: -o output file")
fi

# ── Multiple files ──────────────────────────────────────────
run_test "multiple files" "$TMPDIR/fruits.txt" "$TMPDIR/nums.txt"

# ── Zero-terminated (-z) ────────────────────────────────────
run_test_stdin "-z null-terminated" "$(printf 'c\0b\0a\0')" -z

# ── Month sort (-M) ────────────────────────────────────────
run_test "-M month sort" -M "$TMPDIR/months.txt"

# ── Version sort (-V) ──────────────────────────────────────
run_test "-V version sort" -V "$TMPDIR/versions.txt"

# ── Merge (-m) ──────────────────────────────────────────────
run_test "-m merge sorted files" -m "$TMPDIR/sorted.txt" "$TMPDIR/sorted.txt"

# ── Combined flags ──────────────────────────────────────────
run_test "-rnu reverse numeric unique" -rnu "$TMPDIR/nums.txt"
run_test_stdin "-fu fold case unique" "$(printf 'A\na\nB\nb\n')" -fu
run_test_stdin "-bn blanks + numeric" "$(printf '  3\n1\n  2\n')" -bn

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
