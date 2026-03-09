#!/bin/bash
# Test suite for funiq
# Usage: bash tests/run_tests.sh ./funiq

BIN="${1:-./funiq}"
GNU="/usr/bin/uniq"
TOOL="uniq"

PASS=0
FAIL=0
ERRORS=()

normalize_gnu() {
    sed -e "s|$GNU|PROG|g" -e "s|^$TOOL:|PROG:|g"
}

normalize_our() {
    sed -e "s|$BIN|PROG|g" -e "s|^$TOOL:|PROG:|g"
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

    expected=$(printf "%s" "$input" | $GNU "${args[@]}" 2>&1 | normalize_gnu)
    expected_exit=$?
    got=$(printf "%s" "$input" | $BIN "${args[@]}" 2>&1 | normalize_our)
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

# Test with raw bytes (for -z option)
run_test_raw() {
    local desc="$1"
    local input="$2"
    shift 2
    local args=("$@")

    expected=$(printf "$input" | $GNU "${args[@]}" 2>&1 | od -c | normalize_gnu)
    expected_exit=$?
    got=$(printf "$input" | $BIN "${args[@]}" 2>&1 | od -c | normalize_our)
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

# ── Setup temp files ─────────────────────────────────────────
TMPDIR=$(mktemp -d /tmp/uniq_test.XXXXXX)
trap "rm -rf $TMPDIR" EXIT

printf "a\na\na\nb\nc\nc\n" > "$TMPDIR/basic.txt"
printf "a\na\nb\nc\nc\n" > "$TMPDIR/basic2.txt"
printf "" > "$TMPDIR/empty.txt"
printf "hello\n" > "$TMPDIR/single.txt"
printf "Hello\nhello\nHELLO\nworld\n" > "$TMPDIR/case.txt"
printf "  foo bar\n  foo baz\n  bar qux\n" > "$TMPDIR/fields.txt"
printf "Xhello\nYhello\nZworld\n" > "$TMPDIR/chars.txt"

# ── Basic operation ──────────────────────────────────────────
run_test_stdin "basic dedup" "$(printf 'a\na\na\nb\nc\nc\n')"
run_test "basic dedup from file" "$TMPDIR/basic.txt"
run_test_stdin "single line" "$(printf 'hello\n')"
run_test_stdin "empty input" ""
run_test_stdin "no trailing newline" "hello"
run_test_stdin "all same" "$(printf 'a\na\na\na\n')"
run_test_stdin "all different" "$(printf 'a\nb\nc\nd\n')"

# ── -c (count) ──────────────────────────────────────────────
run_test_stdin "-c basic" "$(printf 'a\na\na\nb\nc\nc\n')" -c
run_test_stdin "-c single" "$(printf 'hello\n')" -c
run_test_stdin "-c all same" "$(printf 'a\na\na\na\na\n')" -c
run_test_stdin "-c all different" "$(printf 'a\nb\nc\n')" -c
run_test "-c from file" -c "$TMPDIR/basic.txt"

# ── -d (repeated only) ──────────────────────────────────────
run_test_stdin "-d basic" "$(printf 'a\na\na\nb\nc\nc\n')" -d
run_test_stdin "-d no repeats" "$(printf 'a\nb\nc\n')" -d
run_test_stdin "-d all same" "$(printf 'a\na\na\n')" -d
run_test "-d from file" -d "$TMPDIR/basic.txt"

# ── -u (unique only) ────────────────────────────────────────
run_test_stdin "-u basic" "$(printf 'a\na\na\nb\nc\nc\n')" -u
run_test_stdin "-u no repeats" "$(printf 'a\nb\nc\n')" -u
run_test_stdin "-u all same" "$(printf 'a\na\na\n')" -u
run_test "-u from file" -u "$TMPDIR/basic.txt"

# ── -D (all duplicates) ─────────────────────────────────────
run_test_stdin "-D basic" "$(printf 'a\na\na\nb\nc\nc\n')" -D
run_test_stdin "-D no repeats" "$(printf 'a\nb\nc\n')" -D
run_test_stdin "-D all same" "$(printf 'a\na\na\n')" -D

# ── -d -u combined (print nothing) ──────────────────────────
run_test_stdin "-du" "$(printf 'a\na\nb\nc\nc\n')" -d -u
run_test_stdin "-ud" "$(printf 'a\na\nb\nc\nc\n')" -u -d
run_test_stdin "-du combined" "$(printf 'a\na\nb\nc\nc\n')" -du

# ── -i (case insensitive) ───────────────────────────────────
run_test_stdin "-i basic" "$(printf 'Hello\nhello\nHELLO\nworld\n')" -i
run_test_stdin "-ci" "$(printf 'Hello\nhello\nHELLO\nworld\n')" -c -i
run_test_stdin "-di" "$(printf 'Hello\nhello\nHELLO\nworld\n')" -d -i
run_test_stdin "-ui" "$(printf 'Hello\nhello\nHELLO\nworld\n')" -u -i
run_test "-i from file" -i "$TMPDIR/case.txt"

# ── -f N (skip fields) ──────────────────────────────────────
run_test_stdin "-f 1" "$(printf 'one two\none three\ntwo two\n')" -f 1
run_test_stdin "-f 0" "$(printf 'a\na\nb\n')" -f 0
run_test_stdin "-f 2" "$(printf 'a b c\nx y c\n')" -f 2
run_test_stdin "-f leading blanks" "$(printf '  foo bar\n  foo baz\n')" -f 1
run_test "--skip-fields=1" --skip-fields=1 "$TMPDIR/fields.txt"

# ── -s N (skip chars) ───────────────────────────────────────
run_test_stdin "-s 1" "$(printf 'Xhello\nYhello\nZworld\n')" -s 1
run_test_stdin "-s 0" "$(printf 'hello\nhello\n')" -s 0
run_test_stdin "-s 3" "$(printf 'abcdef\nxyzdef\n')" -s 3
run_test "--skip-chars=1" --skip-chars=1 "$TMPDIR/chars.txt"

# ── -w N (check chars) ──────────────────────────────────────
run_test_stdin "-w 3" "$(printf 'abcdef\nabcxyz\nxyzabc\n')" -w 3
run_test_stdin "-w 0" "$(printf 'abc\nxyz\n')" -w 0
run_test_stdin "-w 1" "$(printf 'abc\nabc\nbbc\n')" -w 1
run_test_stdin "--check-chars=3" "$(printf 'abcdef\nabcxyz\nxyzabc\n')" --check-chars=3

# ── Combined field/char/width skipping ──────────────────────
run_test_stdin "-f 1 -s 1" "$(printf 'x ab\ny bc\ny cc\n')" -f 1 -s 1
run_test_stdin "-f 1 -w 2" "$(printf 'x abc\ny abx\nz xyz\n')" -f 1 -w 2

# ── --all-repeated ──────────────────────────────────────────
run_test_stdin "--all-repeated" "$(printf 'a\na\nb\nc\nc\n')" --all-repeated
run_test_stdin "--all-repeated=none" "$(printf 'a\na\nb\nc\nc\n')" --all-repeated=none
run_test_stdin "--all-repeated=prepend" "$(printf 'a\na\nb\nc\nc\n')" --all-repeated=prepend
run_test_stdin "--all-repeated=separate" "$(printf 'a\na\nb\nc\nc\n')" --all-repeated=separate
run_test_stdin "--all-repeated no dups" "$(printf 'a\nb\nc\n')" --all-repeated=prepend
run_test_stdin "--all-repeated all same" "$(printf 'a\na\na\n')" --all-repeated=separate

# ── --group ────────────────────────────────────────────────
run_test_stdin "--group" "$(printf 'a\na\nb\nc\nc\n')" --group
run_test_stdin "--group=separate" "$(printf 'a\na\nb\nc\nc\n')" --group=separate
run_test_stdin "--group=prepend" "$(printf 'a\na\nb\nc\nc\n')" --group=prepend
run_test_stdin "--group=append" "$(printf 'a\na\nb\nc\nc\n')" --group=append
run_test_stdin "--group=both" "$(printf 'a\na\nb\nc\nc\n')" --group=both
run_test_stdin "--group single" "$(printf 'a\n')" --group
run_test_stdin "--group all same" "$(printf 'a\na\na\n')" --group
run_test_stdin "--group all different" "$(printf 'a\nb\nc\n')" --group=separate
run_test_stdin "--group=both single" "$(printf 'a\n')" --group=both
run_test_stdin "--group=prepend single" "$(printf 'a\n')" --group=prepend
run_test_stdin "--group=append single" "$(printf 'a\n')" --group=append

# ── -z (zero terminated) ────────────────────────────────────
run_test_raw "-z basic" "a\x00a\x00b\x00b\x00c\x00" -z
run_test_raw "-z count" "a\x00a\x00b\x00c\x00c\x00" -c -z
run_test_raw "-z repeated" "a\x00a\x00b\x00c\x00c\x00" -d -z
run_test_raw "-z unique" "a\x00a\x00b\x00c\x00c\x00" -u -z

# ── File I/O ────────────────────────────────────────────────
# Test stdin with - as operand
expected=$(cat "$TMPDIR/basic.txt" | $GNU - 2>&1 | normalize_gnu)
got=$(cat "$TMPDIR/basic.txt" | $BIN - 2>&1 | normalize_our)
if [ "$expected" = "$got" ]; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: stdin with -")
    ERRORS+=("  expected: $(echo "$expected" | head -3)")
    ERRORS+=("  got:      $(echo "$got" | head -3)")
fi

# Output file test
out_gnu="$TMPDIR/out_gnu.txt"
out_ours="$TMPDIR/out_ours.txt"
$GNU "$TMPDIR/basic.txt" "$out_gnu" 2>&1
$BIN "$TMPDIR/basic.txt" "$out_ours" 2>&1
if diff -q "$out_gnu" "$out_ours" > /dev/null 2>&1; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: output file")
fi

# ── Edge cases ──────────────────────────────────────────────
run_test_stdin "long line" "$(python3 -c "print('a'*10000); print('a'*10000); print('b'*10000)" 2>/dev/null || perl -e "print 'a'x10000 . \"\n\" . 'a'x10000 . \"\n\" . 'b'x10000 . \"\n\"")"
run_test_stdin "whitespace lines" "$(printf '  \n  \n\t\n')"
run_test_stdin "blank line" "$(printf '\n\n\na\n')"

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
