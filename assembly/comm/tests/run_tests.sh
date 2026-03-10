#!/bin/bash
# Test suite for fcomm
# Usage: bash tests/run_tests.sh ./fcomm

BIN="${1:-./fcomm}"
GNU="/usr/bin/comm"
TOOL="comm"

PASS=0
FAIL=0
ERRORS=()

normalize_gnu() {
    sed -e "s|$GNU|PROG|g" -e "s|^$TOOL:|PROG:|g"
}

normalize_our() {
    sed -e "s|$BIN|PROG|g" -e "s|^$TOOL:|PROG:|g"
}

# run_test: run with two files and compare stdout+stderr+exit
run_test() {
    local desc="$1"
    shift
    local args=("$@")

    expected_out=$($GNU "${args[@]}" 2>/tmp/comm_test_gnu_err)
    expected_exit=$?
    expected_err=$(cat /tmp/comm_test_gnu_err | normalize_gnu)
    got_out=$($BIN "${args[@]}" 2>/tmp/comm_test_our_err)
    got_exit=$?
    got_err=$(cat /tmp/comm_test_our_err | normalize_our)

    if [ "$expected_out" = "$got_out" ] && [ "$expected_exit" = "$got_exit" ] && [ "$expected_err" = "$got_err" ]; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
        ERRORS+=("FAIL: $desc")
        if [ "$expected_out" != "$got_out" ]; then
            ERRORS+=("  expected stdout: $(echo "$expected_out" | head -3)")
            ERRORS+=("  got stdout:      $(echo "$got_out" | head -3)")
        fi
        if [ "$expected_err" != "$got_err" ]; then
            ERRORS+=("  expected stderr: $(echo "$expected_err" | head -3)")
            ERRORS+=("  got stderr:      $(echo "$got_err" | head -3)")
        fi
        if [ "$expected_exit" != "$got_exit" ]; then
            ERRORS+=("  expected exit: $expected_exit, got: $got_exit")
        fi
    fi
}

# run_test_stdin: pipe stdin to first file arg (-)
run_test_stdin() {
    local desc="$1"
    local input="$2"
    shift 2
    local args=("$@")

    expected_out=$(printf "%s" "$input" | $GNU "${args[@]}" 2>/tmp/comm_test_gnu_err)
    expected_exit=$?
    expected_err=$(cat /tmp/comm_test_gnu_err | normalize_gnu)
    got_out=$(printf "%s" "$input" | $BIN "${args[@]}" 2>/tmp/comm_test_our_err)
    got_exit=$?
    got_err=$(cat /tmp/comm_test_our_err | normalize_our)

    if [ "$expected_out" = "$got_out" ] && [ "$expected_exit" = "$got_exit" ] && [ "$expected_err" = "$got_err" ]; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
        ERRORS+=("FAIL: $desc")
        if [ "$expected_out" != "$got_out" ]; then
            ERRORS+=("  expected stdout: $(echo "$expected_out" | head -3)")
            ERRORS+=("  got stdout:      $(echo "$got_out" | head -3)")
        fi
        if [ "$expected_err" != "$got_err" ]; then
            ERRORS+=("  expected stderr: $(echo "$expected_err" | head -3)")
            ERRORS+=("  got stderr:      $(echo "$got_err" | head -3)")
        fi
        if [ "$expected_exit" != "$got_exit" ]; then
            ERRORS+=("  expected exit: $expected_exit, got: $got_exit")
        fi
    fi
}

# run_test_raw: for -z tests, compare with od
run_test_raw() {
    local desc="$1"
    shift
    local args=("$@")

    expected=$($GNU "${args[@]}" 2>/dev/null | od -c)
    expected_exit=$?
    got=$($BIN "${args[@]}" 2>/dev/null | od -c)
    got_exit=$?

    if [ "$expected" = "$got" ] && [ "$expected_exit" = "$got_exit" ]; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
        ERRORS+=("FAIL: $desc")
        if [ "$expected" != "$got" ]; then
            ERRORS+=("  expected: $(echo "$expected" | head -3)")
            ERRORS+=("  got:      $(echo "$got" | head -3)")
        fi
        if [ "$expected_exit" != "$got_exit" ]; then
            ERRORS+=("  expected exit: $expected_exit, got: $got_exit")
        fi
    fi
}

# ── Setup temp files ─────────────────────────────────────────
TMPDIR=$(mktemp -d /tmp/comm_test.XXXXXX)
trap "rm -rf $TMPDIR /tmp/comm_test_gnu_err /tmp/comm_test_our_err" EXIT

# Basic sorted files
printf "a\nb\nc\n" > "$TMPDIR/f1.txt"
printf "b\nc\nd\n" > "$TMPDIR/f2.txt"
printf "" > "$TMPDIR/empty.txt"
printf "a\nb\nc\n" > "$TMPDIR/same1.txt"
printf "a\nb\nc\n" > "$TMPDIR/same2.txt"
printf "x\ny\nz\n" > "$TMPDIR/disjoint1.txt"
printf "a\nb\nc\n" > "$TMPDIR/disjoint2.txt"
printf "a\n" > "$TMPDIR/single.txt"
printf "c\na\nb\n" > "$TMPDIR/unsorted.txt"
printf "a\nb\nc\n" > "$TMPDIR/sorted.txt"

# ── Basic 3-column output ────────────────────────────────────
run_test "basic 3-column" "$TMPDIR/f1.txt" "$TMPDIR/f2.txt"
run_test "identical files" "$TMPDIR/same1.txt" "$TMPDIR/same2.txt"
run_test "disjoint files" "$TMPDIR/disjoint1.txt" "$TMPDIR/disjoint2.txt"
run_test "single line file" "$TMPDIR/single.txt" "$TMPDIR/f2.txt"
run_test "empty + non-empty" "$TMPDIR/empty.txt" "$TMPDIR/f1.txt"
run_test "non-empty + empty" "$TMPDIR/f1.txt" "$TMPDIR/empty.txt"
run_test "both empty" "$TMPDIR/empty.txt" "$TMPDIR/empty.txt"

# File with no trailing newline
printf "a\nb\nc" > "$TMPDIR/notrail1.txt"
printf "b\nc\nd" > "$TMPDIR/notrail2.txt"
run_test "no trailing newline" "$TMPDIR/notrail1.txt" "$TMPDIR/notrail2.txt"

# ── Column suppression: -1 ───────────────────────────────────
run_test "-1 basic" -1 "$TMPDIR/f1.txt" "$TMPDIR/f2.txt"
run_test "-1 identical" -1 "$TMPDIR/same1.txt" "$TMPDIR/same2.txt"
run_test "-1 disjoint" -1 "$TMPDIR/disjoint1.txt" "$TMPDIR/disjoint2.txt"
run_test "-1 empty+nonempty" -1 "$TMPDIR/empty.txt" "$TMPDIR/f1.txt"

# ── Column suppression: -2 ───────────────────────────────────
run_test "-2 basic" -2 "$TMPDIR/f1.txt" "$TMPDIR/f2.txt"
run_test "-2 identical" -2 "$TMPDIR/same1.txt" "$TMPDIR/same2.txt"
run_test "-2 disjoint" -2 "$TMPDIR/disjoint1.txt" "$TMPDIR/disjoint2.txt"
run_test "-2 empty+nonempty" -2 "$TMPDIR/empty.txt" "$TMPDIR/f1.txt"

# ── Column suppression: -3 ───────────────────────────────────
run_test "-3 basic" -3 "$TMPDIR/f1.txt" "$TMPDIR/f2.txt"
run_test "-3 identical" -3 "$TMPDIR/same1.txt" "$TMPDIR/same2.txt"
run_test "-3 disjoint" -3 "$TMPDIR/disjoint1.txt" "$TMPDIR/disjoint2.txt"

# ── Combined suppression ─────────────────────────────────────
run_test "-12 basic" -12 "$TMPDIR/f1.txt" "$TMPDIR/f2.txt"
run_test "-13 basic" -13 "$TMPDIR/f1.txt" "$TMPDIR/f2.txt"
run_test "-23 basic" -23 "$TMPDIR/f1.txt" "$TMPDIR/f2.txt"
run_test "-123 basic" -123 "$TMPDIR/f1.txt" "$TMPDIR/f2.txt"
run_test "-1 -2 separate" -1 -2 "$TMPDIR/f1.txt" "$TMPDIR/f2.txt"
run_test "-1 -2 -3 separate" -1 -2 -3 "$TMPDIR/f1.txt" "$TMPDIR/f2.txt"
run_test "-12 identical" -12 "$TMPDIR/same1.txt" "$TMPDIR/same2.txt"
run_test "-12 disjoint" -12 "$TMPDIR/disjoint1.txt" "$TMPDIR/disjoint2.txt"

# ── --output-delimiter ───────────────────────────────────────
run_test "--output-delimiter=|" --output-delimiter='|' "$TMPDIR/f1.txt" "$TMPDIR/f2.txt"
run_test "--output-delimiter=:: " --output-delimiter=':: ' "$TMPDIR/f1.txt" "$TMPDIR/f2.txt"
run_test "--output-delimiter= with -1" -1 --output-delimiter='|' "$TMPDIR/f1.txt" "$TMPDIR/f2.txt"
run_test "--output-delimiter= with -2" -2 --output-delimiter='|' "$TMPDIR/f1.txt" "$TMPDIR/f2.txt"
run_test "--output-delimiter= with -3" -3 --output-delimiter='|' "$TMPDIR/f1.txt" "$TMPDIR/f2.txt"
run_test "--output-delimiter= with -12" -12 --output-delimiter='|' "$TMPDIR/f1.txt" "$TMPDIR/f2.txt"
run_test "--output-delimiter empty" --output-delimiter='' "$TMPDIR/f1.txt" "$TMPDIR/f2.txt"

# ── --total ──────────────────────────────────────────────────
run_test "--total basic" --total "$TMPDIR/f1.txt" "$TMPDIR/f2.txt"
run_test "--total identical" --total "$TMPDIR/same1.txt" "$TMPDIR/same2.txt"
run_test "--total disjoint" --total "$TMPDIR/disjoint1.txt" "$TMPDIR/disjoint2.txt"
run_test "--total empty" --total "$TMPDIR/empty.txt" "$TMPDIR/empty.txt"
run_test "--total + delimiter" --total --output-delimiter='|' "$TMPDIR/f1.txt" "$TMPDIR/f2.txt"
run_test "--total -1" --total -1 "$TMPDIR/f1.txt" "$TMPDIR/f2.txt"
run_test "--total -12" --total -12 "$TMPDIR/f1.txt" "$TMPDIR/f2.txt"
run_test "--total -123" --total -123 "$TMPDIR/f1.txt" "$TMPDIR/f2.txt"

# ── --check-order ────────────────────────────────────────────
run_test "default order check (unsorted)" "$TMPDIR/unsorted.txt" "$TMPDIR/sorted.txt"
run_test "--check-order (unsorted)" --check-order "$TMPDIR/unsorted.txt" "$TMPDIR/sorted.txt"
run_test "--check-order (sorted)" --check-order "$TMPDIR/sorted.txt" "$TMPDIR/f2.txt"
run_test "--nocheck-order (unsorted)" --nocheck-order "$TMPDIR/unsorted.txt" "$TMPDIR/sorted.txt"

# Unsorted file2
printf "d\nb\na\n" > "$TMPDIR/unsorted2.txt"
run_test "default order check (unsorted file2)" "$TMPDIR/sorted.txt" "$TMPDIR/unsorted2.txt"
run_test "--check-order (unsorted file2)" --check-order "$TMPDIR/sorted.txt" "$TMPDIR/unsorted2.txt"

# ── -z (zero-terminated) ────────────────────────────────────
printf "a\0b\0c\0" > "$TMPDIR/z1.txt"
printf "b\0c\0d\0" > "$TMPDIR/z2.txt"
run_test_raw "-z basic" -z "$TMPDIR/z1.txt" "$TMPDIR/z2.txt"
run_test_raw "-z identical" -z "$TMPDIR/z1.txt" "$TMPDIR/z1.txt"
run_test_raw "-z -1" -z -1 "$TMPDIR/z1.txt" "$TMPDIR/z2.txt"
run_test_raw "-z -12" -z -12 "$TMPDIR/z1.txt" "$TMPDIR/z2.txt"

printf "a\0" > "$TMPDIR/z_single.txt"
printf "" > "$TMPDIR/z_empty.txt"
run_test_raw "-z single" -z "$TMPDIR/z_single.txt" "$TMPDIR/z2.txt"
run_test_raw "-z empty" -z "$TMPDIR/z_empty.txt" "$TMPDIR/z2.txt"

# ── stdin with - ─────────────────────────────────────────────
run_test_stdin "stdin file1 (-)" "$(printf 'a\nb\nc\n')" - "$TMPDIR/f2.txt"
run_test_stdin "stdin file2 (-)" "$(printf 'b\nc\nd\n')" "$TMPDIR/f1.txt" -

# ── -- (end of options) ─────────────────────────────────────
run_test "-- before files" -- "$TMPDIR/f1.txt" "$TMPDIR/f2.txt"

# ── Error cases ──────────────────────────────────────────────
# Missing operand
expected_out=$($GNU 2>/tmp/comm_test_gnu_err)
expected_exit=$?
expected_err=$(cat /tmp/comm_test_gnu_err | normalize_gnu)
got_out=$($BIN 2>/tmp/comm_test_our_err)
got_exit=$?
got_err=$(cat /tmp/comm_test_our_err | normalize_our)
if [ "$expected_exit" = "$got_exit" ]; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: missing operand exit code")
    ERRORS+=("  expected exit: $expected_exit, got: $got_exit")
fi

# Missing second operand
expected_out=$($GNU "$TMPDIR/f1.txt" 2>/tmp/comm_test_gnu_err)
expected_exit=$?
got_out=$($BIN "$TMPDIR/f1.txt" 2>/tmp/comm_test_our_err)
got_exit=$?
if [ "$expected_exit" = "$got_exit" ]; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: missing second operand exit code")
    ERRORS+=("  expected exit: $expected_exit, got: $got_exit")
fi

# Extra operand
expected_out=$($GNU "$TMPDIR/f1.txt" "$TMPDIR/f2.txt" "$TMPDIR/f2.txt" 2>/tmp/comm_test_gnu_err)
expected_exit=$?
got_out=$($BIN "$TMPDIR/f1.txt" "$TMPDIR/f2.txt" "$TMPDIR/f2.txt" 2>/tmp/comm_test_our_err)
got_exit=$?
if [ "$expected_exit" = "$got_exit" ]; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: extra operand exit code")
    ERRORS+=("  expected exit: $expected_exit, got: $got_exit")
fi

# Nonexistent file
expected_out=$($GNU "$TMPDIR/f1.txt" "/nonexistent_file" 2>/tmp/comm_test_gnu_err)
expected_exit=$?
got_out=$($BIN "$TMPDIR/f1.txt" "/nonexistent_file" 2>/tmp/comm_test_our_err)
got_exit=$?
if [ "$expected_exit" = "$got_exit" ]; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: nonexistent file exit code")
    ERRORS+=("  expected exit: $expected_exit, got: $got_exit")
fi

# ── Large file test ──────────────────────────────────────────
# Generate large sorted files
seq 1 10000 | sort > "$TMPDIR/large1.txt"
seq 5001 15000 | sort > "$TMPDIR/large2.txt"
run_test "large files" "$TMPDIR/large1.txt" "$TMPDIR/large2.txt"
run_test "large -12" -12 "$TMPDIR/large1.txt" "$TMPDIR/large2.txt"
run_test "large --total" --total "$TMPDIR/large1.txt" "$TMPDIR/large2.txt"

# ── Lines with special characters ────────────────────────────
printf "hello world\ntest\ttab\n" > "$TMPDIR/special1.txt"
printf "hello world\nzzzz\n" > "$TMPDIR/special2.txt"
run_test "lines with spaces/tabs" "$TMPDIR/special1.txt" "$TMPDIR/special2.txt"

# Long lines
python3 -c "print('a'*10000); print('b'*10000)" > "$TMPDIR/long1.txt" 2>/dev/null || \
    perl -e "print 'a'x10000 . \"\n\" . 'b'x10000 . \"\n\"" > "$TMPDIR/long1.txt"
python3 -c "print('a'*10000); print('c'*10000)" > "$TMPDIR/long2.txt" 2>/dev/null || \
    perl -e "print 'a'x10000 . \"\n\" . 'c'x10000 . \"\n\"" > "$TMPDIR/long2.txt"
run_test "long lines" "$TMPDIR/long1.txt" "$TMPDIR/long2.txt"

# ── Blank/empty lines ───────────────────────────────────────
printf "\n\na\n" > "$TMPDIR/blank1.txt"
printf "\na\nb\n" > "$TMPDIR/blank2.txt"
run_test "blank lines" "$TMPDIR/blank1.txt" "$TMPDIR/blank2.txt"

# Single character files
printf "a\n" > "$TMPDIR/sc1.txt"
printf "a\n" > "$TMPDIR/sc2.txt"
run_test "single char identical" "$TMPDIR/sc1.txt" "$TMPDIR/sc2.txt"

printf "a\n" > "$TMPDIR/sc3.txt"
printf "b\n" > "$TMPDIR/sc4.txt"
run_test "single char different" "$TMPDIR/sc3.txt" "$TMPDIR/sc4.txt"

# ── --help and --version ─────────────────────────────────────
# Just check exit codes (output content will differ)
$BIN --help > /dev/null 2>&1
help_exit=$?
if [ "$help_exit" = "0" ]; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: --help should exit 0, got $help_exit")
fi

$BIN --version > /dev/null 2>&1
ver_exit=$?
if [ "$ver_exit" = "0" ]; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: --version should exit 0, got $ver_exit")
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
