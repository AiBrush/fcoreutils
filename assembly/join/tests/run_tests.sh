#!/bin/bash
# Test suite for fjoin (assembly join)
# Usage: bash tests/run_tests.sh ./fjoin

BIN="${1:-./fjoin}"
GNU="/usr/bin/join"
TOOL="join"

PASS=0
FAIL=0
ERRORS=()

normalize_gnu() {
    sed -e "s|$GNU|PROG|g" -e "s|^$TOOL:|PROG:|g"
}

normalize_our() {
    sed -e "s|$BIN|PROG|g" -e "s|^$TOOL:|PROG:|g"
}

# run_test: compare stdout+stderr+exit
run_test() {
    local desc="$1"
    shift
    local args=("$@")

    expected_out=$($GNU "${args[@]}" 2>/tmp/join_test_gnu_err)
    expected_exit=$?
    expected_err=$(cat /tmp/join_test_gnu_err | normalize_gnu)
    got_out=$($BIN "${args[@]}" 2>/tmp/join_test_our_err)
    got_exit=$?
    got_err=$(cat /tmp/join_test_our_err | normalize_our)

    if [ "$expected_out" = "$got_out" ] && [ "$expected_exit" = "$got_exit" ]; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
        ERRORS+=("FAIL: $desc")
        if [ "$expected_out" != "$got_out" ]; then
            ERRORS+=("  expected stdout: $(echo "$expected_out" | head -3)")
            ERRORS+=("  got stdout:      $(echo "$got_out" | head -3)")
        fi
        if [ "$expected_exit" != "$got_exit" ]; then
            ERRORS+=("  expected exit: $expected_exit, got: $got_exit")
        fi
    fi
}

# run_test_strict: also check stderr matches
run_test_strict() {
    local desc="$1"
    shift
    local args=("$@")

    expected_out=$($GNU "${args[@]}" 2>/tmp/join_test_gnu_err)
    expected_exit=$?
    expected_err=$(cat /tmp/join_test_gnu_err | normalize_gnu)
    got_out=$($BIN "${args[@]}" 2>/tmp/join_test_our_err)
    got_exit=$?
    got_err=$(cat /tmp/join_test_our_err | normalize_our)

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

# run_test_stdin: pipe stdin to - arg
run_test_stdin() {
    local desc="$1"
    local input="$2"
    shift 2
    local args=("$@")

    expected_out=$(printf "%s" "$input" | $GNU "${args[@]}" 2>/dev/null)
    expected_exit=$?
    got_out=$(printf "%s" "$input" | $BIN "${args[@]}" 2>/dev/null)
    got_exit=$?

    if [ "$expected_out" = "$got_out" ] && [ "$expected_exit" = "$got_exit" ]; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
        ERRORS+=("FAIL: $desc")
        if [ "$expected_out" != "$got_out" ]; then
            ERRORS+=("  expected stdout: $(echo "$expected_out" | head -3)")
            ERRORS+=("  got stdout:      $(echo "$got_out" | head -3)")
        fi
        if [ "$expected_exit" != "$got_exit" ]; then
            ERRORS+=("  expected exit: $expected_exit, got: $got_exit")
        fi
    fi
}

# run_test_raw: compare binary output (for -z tests)
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
TMPDIR=$(mktemp -d /tmp/join_test.XXXXXX)
trap "rm -rf $TMPDIR /tmp/join_test_gnu_err /tmp/join_test_our_err" EXIT

# Basic sorted files
printf "1 alice\n2 bob\n3 carol\n" > "$TMPDIR/f1.txt"
printf "1 apples\n2 bananas\n3 cherries\n" > "$TMPDIR/f2.txt"
printf "2 bananas\n3 cherries\n4 dates\n" > "$TMPDIR/f2b.txt"
printf "" > "$TMPDIR/empty.txt"
printf "1 alice\n" > "$TMPDIR/single.txt"

# ── Basic join ────────────────────────────────────────────────
run_test "basic join" "$TMPDIR/f1.txt" "$TMPDIR/f2.txt"
run_test "partial match" "$TMPDIR/f1.txt" "$TMPDIR/f2b.txt"
run_test "no match (empty + full)" "$TMPDIR/empty.txt" "$TMPDIR/f1.txt"
run_test "no match (full + empty)" "$TMPDIR/f1.txt" "$TMPDIR/empty.txt"
run_test "both empty" "$TMPDIR/empty.txt" "$TMPDIR/empty.txt"
run_test "single line match" "$TMPDIR/single.txt" "$TMPDIR/f1.txt"

# Identical files
printf "a 1\nb 2\nc 3\n" > "$TMPDIR/same1.txt"
printf "a 1\nb 2\nc 3\n" > "$TMPDIR/same2.txt"
run_test "identical files" "$TMPDIR/same1.txt" "$TMPDIR/same2.txt"

# Disjoint files
printf "a 1\nb 2\n" > "$TMPDIR/dis1.txt"
printf "c 3\nd 4\n" > "$TMPDIR/dis2.txt"
run_test "disjoint files" "$TMPDIR/dis1.txt" "$TMPDIR/dis2.txt"

# No trailing newline
printf "1 alice\n2 bob" > "$TMPDIR/notr1.txt"
printf "2 bananas\n3 cherries" > "$TMPDIR/notr2.txt"
run_test "no trailing newline" "$TMPDIR/notr1.txt" "$TMPDIR/notr2.txt"

# Multi-field files
printf "1 alice alpha\n2 bob beta\n3 carol gamma\n" > "$TMPDIR/mf1.txt"
printf "1 apples red\n2 bananas yellow\n3 cherries red\n" > "$TMPDIR/mf2.txt"
run_test "multi-field" "$TMPDIR/mf1.txt" "$TMPDIR/mf2.txt"

# ── -a (print unpairable) ────────────────────────────────────
run_test "-a 1" -a 1 "$TMPDIR/f1.txt" "$TMPDIR/f2b.txt"
run_test "-a 2" -a 2 "$TMPDIR/f1.txt" "$TMPDIR/f2b.txt"
run_test "-a 1 -a 2" -a 1 -a 2 "$TMPDIR/f1.txt" "$TMPDIR/f2b.txt"
run_test "-a1 (attached)" -a1 "$TMPDIR/f1.txt" "$TMPDIR/f2b.txt"
run_test "-a2 (attached)" -a2 "$TMPDIR/f1.txt" "$TMPDIR/f2b.txt"
run_test "-a 1 empty" -a 1 "$TMPDIR/empty.txt" "$TMPDIR/f1.txt"
run_test "-a 2 empty" -a 2 "$TMPDIR/empty.txt" "$TMPDIR/f1.txt"
run_test "-a 1 identical" -a 1 "$TMPDIR/same1.txt" "$TMPDIR/same2.txt"
run_test "-a 2 disjoint" -a 2 "$TMPDIR/dis1.txt" "$TMPDIR/dis2.txt"
run_test "-a 1 -a 2 disjoint" -a 1 -a 2 "$TMPDIR/dis1.txt" "$TMPDIR/dis2.txt"

# ── -v (only unpairable) ─────────────────────────────────────
run_test "-v 1" -v 1 "$TMPDIR/f1.txt" "$TMPDIR/f2b.txt"
run_test "-v 2" -v 2 "$TMPDIR/f1.txt" "$TMPDIR/f2b.txt"
run_test "-v1 (attached)" -v1 "$TMPDIR/f1.txt" "$TMPDIR/f2b.txt"
run_test "-v2 (attached)" -v2 "$TMPDIR/f1.txt" "$TMPDIR/f2b.txt"
run_test "-v 1 disjoint" -v 1 "$TMPDIR/dis1.txt" "$TMPDIR/dis2.txt"
run_test "-v 2 disjoint" -v 2 "$TMPDIR/dis1.txt" "$TMPDIR/dis2.txt"
run_test "-v 1 identical" -v 1 "$TMPDIR/same1.txt" "$TMPDIR/same2.txt"

# ── -t (separator) ───────────────────────────────────────────
printf "1:alice\n2:bob\n3:carol\n" > "$TMPDIR/t1.txt"
printf "1:apples\n2:bananas\n3:cherries\n" > "$TMPDIR/t2.txt"
run_test "-t: basic" -t: "$TMPDIR/t1.txt" "$TMPDIR/t2.txt"
run_test "-t : space" -t ":" "$TMPDIR/t1.txt" "$TMPDIR/t2.txt"

printf "1|alice\n2|bob\n" > "$TMPDIR/tp1.txt"
printf "1|apples\n2|bananas\n" > "$TMPDIR/tp2.txt"
run_test "-t| pipe" -t "|" "$TMPDIR/tp1.txt" "$TMPDIR/tp2.txt"

printf "1,alice\n2,bob\n" > "$TMPDIR/tc1.txt"
printf "1,apples\n2,bananas\n" > "$TMPDIR/tc2.txt"
run_test "-t, comma" -t, "$TMPDIR/tc1.txt" "$TMPDIR/tc2.txt"

# Tab separator
printf "1\talice\n2\tbob\n" > "$TMPDIR/tt1.txt"
printf "1\tapples\n2\tbananas\n" > "$TMPDIR/tt2.txt"
run_test "-t tab" -t "	" "$TMPDIR/tt1.txt" "$TMPDIR/tt2.txt"

# ── -j (same join field) ─────────────────────────────────────
printf "alice 1\nbob 2\n" > "$TMPDIR/j1.txt"
printf "apples 1\nbananas 2\n" > "$TMPDIR/j2.txt"
run_test "-j 2" -j 2 "$TMPDIR/j1.txt" "$TMPDIR/j2.txt"
run_test "-j2 (attached)" -j2 "$TMPDIR/j1.txt" "$TMPDIR/j2.txt"

# ── -1 -2 (separate field selectors) ─────────────────────────
printf "a 1\nb 2\n" > "$TMPDIR/s1.txt"
printf "1 x\n2 y\n" > "$TMPDIR/s2.txt"
run_test "-1 2 -2 1" -1 2 -2 1 "$TMPDIR/s1.txt" "$TMPDIR/s2.txt"

printf "a 1 X\nb 2 Y\n" > "$TMPDIR/s3.txt"
printf "A 1 P\nB 2 Q\n" > "$TMPDIR/s4.txt"
run_test "-12 -22" -1 2 -2 2 "$TMPDIR/s3.txt" "$TMPDIR/s4.txt"

# ── -o (output format) ───────────────────────────────────────
printf "1 a b\n2 c d\n" > "$TMPDIR/o1.txt"
printf "1 x y\n2 w z\n" > "$TMPDIR/o2.txt"
run_test "-o 0,1.2,2.2" -o '0,1.2,2.2' "$TMPDIR/o1.txt" "$TMPDIR/o2.txt"
run_test "-o 1.1,2.1" -o '1.1,2.1' "$TMPDIR/o1.txt" "$TMPDIR/o2.txt"
run_test "-o 0,1.2,1.3,2.2,2.3" -o '0,1.2,1.3,2.2,2.3' "$TMPDIR/o1.txt" "$TMPDIR/o2.txt"
run_test "-o 2.1,1.1" -o '2.1,1.1' "$TMPDIR/o1.txt" "$TMPDIR/o2.txt"

# -o with -a (unpaired with format)
printf "1 a b\n2 c d\n" > "$TMPDIR/oa1.txt"
printf "1 x y\n3 w z\n" > "$TMPDIR/oa2.txt"
run_test "-o with -a1 -a2" -a 1 -a 2 -o '0,1.2,2.2' "$TMPDIR/oa1.txt" "$TMPDIR/oa2.txt"

# -o with -e
run_test "-o with -e EMPTY" -e EMPTY -a 1 -a 2 -o '0,1.2,1.3,2.2,2.3' "$TMPDIR/oa1.txt" "$TMPDIR/oa2.txt"

# -o auto
run_test "-o auto" -o auto "$TMPDIR/o1.txt" "$TMPDIR/o2.txt"

# -o with 0 (join field spec)
run_test "-o 0" -o '0' "$TMPDIR/o1.txt" "$TMPDIR/o2.txt"

# -o with 1.0/2.0 (also means join field)
run_test "-o 1.0,2.0" -o '1.0,2.0' "$TMPDIR/o1.txt" "$TMPDIR/o2.txt"

# ── -e (empty filler) ────────────────────────────────────────
run_test "-e MISS basic" -e MISS -a 1 -a 2 -o '0,1.2,2.2' "$TMPDIR/oa1.txt" "$TMPDIR/oa2.txt"
run_test "-e empty string" -e '' -a 1 -a 2 -o '0,1.2,2.2' "$TMPDIR/oa1.txt" "$TMPDIR/oa2.txt"

# ── -i (ignore case) ─────────────────────────────────────────
printf "A 1\nB 2\nC 3\n" > "$TMPDIR/i1.txt"
printf "a x\nb y\nc z\n" > "$TMPDIR/i2.txt"
run_test "-i basic" -i "$TMPDIR/i1.txt" "$TMPDIR/i2.txt"

printf "ABC 1\ndef 2\n" > "$TMPDIR/ic1.txt"
printf "abc x\nDEF y\n" > "$TMPDIR/ic2.txt"
run_test "-i mixed case" -i "$TMPDIR/ic1.txt" "$TMPDIR/ic2.txt"
run_test "--ignore-case" --ignore-case "$TMPDIR/ic1.txt" "$TMPDIR/ic2.txt"

# ── --header ──────────────────────────────────────────────────
printf "KEY VAL1\n1 alice\n2 bob\n" > "$TMPDIR/h1.txt"
printf "KEY VAL2\n1 apples\n2 bananas\n" > "$TMPDIR/h2.txt"
run_test "--header basic" --header "$TMPDIR/h1.txt" "$TMPDIR/h2.txt"

printf "NAME ID\nalice 1\nbob 2\n" > "$TMPDIR/hj1.txt"
printf "FRUIT ID\napples 1\nbananas 2\n" > "$TMPDIR/hj2.txt"
run_test "--header with -j2" --header -j 2 "$TMPDIR/hj1.txt" "$TMPDIR/hj2.txt"

# ── -z (zero-terminated) ─────────────────────────────────────
printf "1 a\0002 b\0003 c\000" > "$TMPDIR/z1.txt"
printf "2 x\0003 y\0004 z\000" > "$TMPDIR/z2.txt"
run_test_raw "-z basic" -z "$TMPDIR/z1.txt" "$TMPDIR/z2.txt"
run_test_raw "-z -a 1" -z -a 1 "$TMPDIR/z1.txt" "$TMPDIR/z2.txt"
run_test_raw "-z -a 1 -a 2" -z -a 1 -a 2 "$TMPDIR/z1.txt" "$TMPDIR/z2.txt"
run_test_raw "--zero-terminated" --zero-terminated "$TMPDIR/z1.txt" "$TMPDIR/z2.txt"

printf "1 a\000" > "$TMPDIR/zs.txt"
printf "" > "$TMPDIR/ze.txt"
run_test_raw "-z single" -z "$TMPDIR/zs.txt" "$TMPDIR/z2.txt"
run_test_raw "-z empty" -z "$TMPDIR/ze.txt" "$TMPDIR/z2.txt"

# ── --check-order / --nocheck-order ──────────────────────────
printf "3 carol\n1 alice\n2 bob\n" > "$TMPDIR/unsorted.txt"
printf "1 apples\n2 bananas\n3 cherries\n" > "$TMPDIR/sorted.txt"

run_test "--nocheck-order" --nocheck-order "$TMPDIR/unsorted.txt" "$TMPDIR/sorted.txt"

# --check-order exit code (should be 1 on unsorted)
$GNU --check-order "$TMPDIR/unsorted.txt" "$TMPDIR/sorted.txt" > /dev/null 2>&1
gnu_exit=$?
$BIN --check-order "$TMPDIR/unsorted.txt" "$TMPDIR/sorted.txt" > /dev/null 2>&1
our_exit=$?
if [ "$gnu_exit" = "$our_exit" ]; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: --check-order exit code")
    ERRORS+=("  expected: $gnu_exit, got: $our_exit")
fi

# Default order check (produce output but report error)
run_test "default order check" "$TMPDIR/unsorted.txt" "$TMPDIR/sorted.txt"

# Unsorted file 2
printf "3 z\n1 a\n" > "$TMPDIR/unsorted2.txt"
run_test "unsorted file 2" "$TMPDIR/sorted.txt" "$TMPDIR/unsorted2.txt"

# Sorted input — no error
run_test "sorted input" "$TMPDIR/sorted.txt" "$TMPDIR/f2.txt"

# ── stdin (-) ─────────────────────────────────────────────────
run_test_stdin "stdin file1" "$(printf '1 alice\n2 bob\n3 carol\n')" - "$TMPDIR/f2.txt"
run_test_stdin "stdin file2" "$(printf '1 apples\n2 bananas\n3 cherries\n')" "$TMPDIR/f1.txt" -

# ── -- (end of options) ──────────────────────────────────────
run_test "-- before files" -- "$TMPDIR/f1.txt" "$TMPDIR/f2.txt"

# ── Cross-product (many-to-many) ─────────────────────────────
printf "1 a\n1 b\n2 c\n" > "$TMPDIR/cp1.txt"
printf "1 x\n1 y\n2 z\n" > "$TMPDIR/cp2.txt"
run_test "cross-product" "$TMPDIR/cp1.txt" "$TMPDIR/cp2.txt"
run_test "cross-product -a1 -a2" -a 1 -a 2 "$TMPDIR/cp1.txt" "$TMPDIR/cp2.txt"

# Larger cross-product
printf "1 a\n1 b\n1 c\n2 d\n" > "$TMPDIR/cp3.txt"
printf "1 x\n1 y\n1 z\n2 w\n" > "$TMPDIR/cp4.txt"
run_test "3x3 cross-product" "$TMPDIR/cp3.txt" "$TMPDIR/cp4.txt"

# ── Whitespace handling ──────────────────────────────────────
printf "  1  alice  beta\n  2  bob  gamma\n" > "$TMPDIR/ws1.txt"
printf "1 apples\n2 bananas\n" > "$TMPDIR/ws2.txt"
run_test "leading whitespace" "$TMPDIR/ws1.txt" "$TMPDIR/ws2.txt"

# Multiple spaces between fields
printf "1   alice   beta\n2   bob   gamma\n" > "$TMPDIR/ws3.txt"
run_test "multiple spaces" "$TMPDIR/ws3.txt" "$TMPDIR/ws2.txt"

# ── Special characters in fields ─────────────────────────────
printf "hello_world 1\ntest 2\n" > "$TMPDIR/sp1.txt"
printf "hello_world x\ntest y\n" > "$TMPDIR/sp2.txt"
run_test "underscores in key" "$TMPDIR/sp1.txt" "$TMPDIR/sp2.txt"

# ── Large file test ──────────────────────────────────────────
seq 1 10000 | awk '{printf "%05d field_%s\n", $0, $0}' | sort > "$TMPDIR/large1.txt"
seq 5001 15000 | awk '{printf "%05d field_%s\n", $0, $0}' | sort > "$TMPDIR/large2.txt"
run_test "large files (10K lines)" "$TMPDIR/large1.txt" "$TMPDIR/large2.txt"
run_test "large -a 1 -a 2" -a 1 -a 2 "$TMPDIR/large1.txt" "$TMPDIR/large2.txt"

# ── Error cases ──────────────────────────────────────────────
# Missing operand
$GNU 2>/dev/null; gnu_exit=$?
$BIN 2>/dev/null; our_exit=$?
if [ "$gnu_exit" = "$our_exit" ]; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: missing operand exit code")
    ERRORS+=("  expected: $gnu_exit, got: $our_exit")
fi

# Missing second operand
$GNU "$TMPDIR/f1.txt" 2>/dev/null; gnu_exit=$?
$BIN "$TMPDIR/f1.txt" 2>/dev/null; our_exit=$?
if [ "$gnu_exit" = "$our_exit" ]; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: missing second operand exit code")
    ERRORS+=("  expected: $gnu_exit, got: $our_exit")
fi

# Extra operand
$GNU "$TMPDIR/f1.txt" "$TMPDIR/f2.txt" "$TMPDIR/f2.txt" 2>/dev/null; gnu_exit=$?
$BIN "$TMPDIR/f1.txt" "$TMPDIR/f2.txt" "$TMPDIR/f2.txt" 2>/dev/null; our_exit=$?
if [ "$gnu_exit" = "$our_exit" ]; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: extra operand exit code")
    ERRORS+=("  expected: $gnu_exit, got: $our_exit")
fi

# Nonexistent file
$GNU "$TMPDIR/f1.txt" "/nonexistent_file" 2>/dev/null; gnu_exit=$?
$BIN "$TMPDIR/f1.txt" "/nonexistent_file" 2>/dev/null; our_exit=$?
if [ "$gnu_exit" = "$our_exit" ]; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: nonexistent file exit code")
    ERRORS+=("  expected: $gnu_exit, got: $our_exit")
fi

# ── --help and --version ─────────────────────────────────────
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

# ── Long lines ────────────────────────────────────────────────
python3 -c "print('key ' + 'a'*10000)" > "$TMPDIR/long1.txt" 2>/dev/null || \
    perl -e "print 'key ' . 'a'x10000 . \"\n\"" > "$TMPDIR/long1.txt"
python3 -c "print('key ' + 'b'*10000)" > "$TMPDIR/long2.txt" 2>/dev/null || \
    perl -e "print 'key ' . 'b'x10000 . \"\n\"" > "$TMPDIR/long2.txt"
run_test "long lines" "$TMPDIR/long1.txt" "$TMPDIR/long2.txt"

# ── Blank/empty lines ────────────────────────────────────────
printf "\n\na 1\n" > "$TMPDIR/blank1.txt"
printf "\na 2\nb 3\n" > "$TMPDIR/blank2.txt"
run_test "blank lines" "$TMPDIR/blank1.txt" "$TMPDIR/blank2.txt"

# Single char key
printf "a 1\n" > "$TMPDIR/sc1.txt"
printf "a 2\n" > "$TMPDIR/sc2.txt"
run_test "single char key" "$TMPDIR/sc1.txt" "$TMPDIR/sc2.txt"

printf "a 1\n" > "$TMPDIR/sc3.txt"
printf "b 2\n" > "$TMPDIR/sc4.txt"
run_test "single char diff" "$TMPDIR/sc3.txt" "$TMPDIR/sc4.txt"

# ── -t with -o format ────────────────────────────────────────
printf "1:alice:extra\n2:bob:more\n" > "$TMPDIR/to1.txt"
printf "1:apples:info\n2:bananas:data\n" > "$TMPDIR/to2.txt"
run_test "-t: -o format" -t: -o '0,1.2,2.2' "$TMPDIR/to1.txt" "$TMPDIR/to2.txt"
run_test "-t: -a 1 -a 2" -t: -a 1 -a 2 "$TMPDIR/to1.txt" "$TMPDIR/to2.txt"

# ── Combined flags ────────────────────────────────────────────
run_test "-a 1 -a 2 -e X -o 0,1.2,2.2" -a 1 -a 2 -e X -o '0,1.2,2.2' "$TMPDIR/oa1.txt" "$TMPDIR/oa2.txt"
run_test "-t: -a 1 -e MISS -o 0,1.2,2.2" -t: -a 1 -e MISS -o '0,1.2,2.2' "$TMPDIR/to1.txt" "$TMPDIR/to2.txt"

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
