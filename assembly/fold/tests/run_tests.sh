#!/bin/bash
# Test suite for ffold — compare against GNU fold
# Usage: bash tests/run_tests.sh ./ffold

BIN="${1:-./ffold}"
GNU="/usr/bin/fold"
TOOL="fold"

PASS=0
FAIL=0
ERRORS=()

normalize_gnu() {
    sed -e "s|$GNU|PROG|g" -e "s|Usage: $TOOL|Usage: PROG|g" -e "s|^$TOOL |PROG |g"
}

normalize_our() {
    sed -e "s|$BIN|PROG|g" -e "s|Usage: $TOOL|Usage: PROG|g" -e "s|^$TOOL |PROG |g"
}

run_test_stdin() {
    local desc="$1"
    local input="$2"
    shift 2
    local args=("$@")

    expected=$(printf "$input" | $GNU "${args[@]}" 2>&1 | normalize_gnu)
    expected_exit=$?
    got=$(printf "$input" | $BIN "${args[@]}" 2>&1 | normalize_our)
    got_exit=$?

    if [ "$expected" = "$got" ] && [ "$expected_exit" = "$got_exit" ]; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
        ERRORS+=("FAIL: $desc")
        if [ "$expected" != "$got" ]; then
            ERRORS+=("  expected: $(echo -n "$expected" | head -c 200 | od -A n -t x1 | head -2)")
            ERRORS+=("  got:      $(echo -n "$got" | head -c 200 | od -A n -t x1 | head -2)")
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
            ERRORS+=("  expected: $(echo -n "$expected" | head -c 200 | od -A n -t x1 | head -2)")
            ERRORS+=("  got:      $(echo -n "$got" | head -c 200 | od -A n -t x1 | head -2)")
        fi
        if [ "$expected_exit" != "$got_exit" ]; then
            ERRORS+=("  expected exit: $expected_exit, got: $got_exit")
        fi
    fi
}

run_test_noargs() {
    local desc="$1"
    shift
    local args=("$@")

    expected=$($GNU "${args[@]}" </dev/null 2>&1 | normalize_gnu)
    expected_exit=$?
    got=$($BIN "${args[@]}" </dev/null 2>&1 | normalize_our)
    got_exit=$?

    if [ "$expected_exit" = "$got_exit" ]; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
        ERRORS+=("FAIL: $desc (exit: expected=$expected_exit got=$got_exit)")
    fi
}

# ── Setup temp files ─────────────────────────────────────────
TMPDIR=$(mktemp -d /tmp/fold_test.XXXXXX)
trap "rm -rf $TMPDIR" EXIT

python3 -c "print('a'*100)" > "$TMPDIR/long.txt"
printf "hello\nworld\n" > "$TMPDIR/basic.txt"
printf "abc\n" > "$TMPDIR/f1.txt"
printf "def\n" > "$TMPDIR/f2.txt"
echo -n "" > "$TMPDIR/empty.txt"
printf "line with spaces in it\n" > "$TMPDIR/spaces.txt"
printf "1234567890" > "$TMPDIR/nonewline.txt"

echo ""
echo "============================================"
echo " GNU Compatibility Tests: ffold"
echo "============================================"
echo ""

# ── Basic fold (default width 80) ──
echo "── Basic fold ──"
run_test_stdin "default width 80" "$(python3 -c "print('a'*100)")"
run_test_stdin "short line passthrough" "hello\n"
run_test_stdin "empty input" ""
run_test_stdin "just newline" "\n"
run_test_stdin "multiple newlines" "\n\n\n"
run_test_stdin "multiple lines" "hello\nworld\nfoo\n"
run_test_stdin "no trailing newline" "hello"
run_test_stdin "width 80 exact" "$(python3 -c "print('a'*80)")"
run_test_stdin "width 80 + 1" "$(python3 -c "print('a'*81)")"
run_test_stdin "long line 200" "$(python3 -c "print('x'*200)")"

# ── Width option ──
echo "── Width option ──"
run_test_stdin "-w 5" "1234567890\n" -w 5
run_test_stdin "-w 1" "abc\n" -w 1
run_test_stdin "-w 2" "abcdef\n" -w 2
run_test_stdin "-w 3" "1234567890\n" -w 3
run_test_stdin "-w 10" "1234567890\n" -w 10
run_test_stdin "-w 999 (no fold)" "hello world\n" -w 999
run_test_stdin "--width=5" "1234567890\n" --width=5
run_test_stdin "--width 5" "1234567890\n" --width 5

# ── Byte mode (-b) ──
echo "── Byte mode (-b) ──"
run_test_stdin "-b -w 5" "1234567890\n" -b -w 5
run_test_stdin "-b -w 1" "abc\n" -b -w 1
run_test_stdin "-b default" "$(python3 -c "print('a'*100)")" -b
run_test_stdin "-b no fold needed" "hello\n" -b
run_test_stdin "-b tab is 1 byte" "1234\tabc\n" -b -w 5

# ── Space-break mode (-s) ──
echo "── Space-break mode (-s) ──"
run_test_stdin "-s -w 15" "hello world this is a test\n" -s -w 15
run_test_stdin "-s no space (hard break)" "abcdefghij\n" -s -w 5
run_test_stdin "-s at boundary" "ab cd\n" -s -w 3
run_test_stdin "-s multiple spaces" "a b c d\n" -s -w 4
run_test_stdin "-s longer text" "abc def ghi jkl mno\n" -s -w 8
run_test_stdin "-s space at width" "1234 678\n" -s -w 4
run_test_stdin "-s -b -w 5" "ab cd efgh\n" -b -s -w 5
run_test_stdin "-s -b -w 6" "ab cd efgh\n" -b -s -w 6
run_test_stdin "-s tab break" "abc\tdef ghi jkl\n" -s -w 10
run_test_stdin "-s tab only" "abc\tdef\n" -s -w 5

# ── Tab handling ──
echo "── Tab handling ──"
run_test_stdin "tab basic" "a\tb\n" -w 10
run_test_stdin "tab at width" "1234567\t\n" -w 8
run_test_stdin "tab push past width" "12345\tXYZ\n" -w 8
run_test_stdin "tab col 6 width 7" "123456\tXYZ\n" -w 7
run_test_stdin "tab at start" "\thello\n" -w 10
run_test_stdin "two tabs no fold" "\t\t\n" -w 16
run_test_stdin "two tabs fold" "\t\t\n" -w 10
run_test_stdin "tab col 0 width 3" "\tX\n" -w 3
run_test_stdin "tab col 1 width 3" "1\tX\n" -w 3
run_test_stdin "tab col 2 width 3" "12\tX\n" -w 3

# ── Backspace handling ──
echo "── Backspace handling ──"
run_test_stdin "backspace" "abc\010def\n" -w 5
run_test_stdin "backspace at col 0" "\010abc\n" -w 3

# ── Carriage return ──
echo "── Carriage return ──"
run_test_stdin "cr" "abcde\rXY\n" -w 5
run_test_stdin "cr long" "abcde\rXYZWQRSTU\n" -w 5

# ── Combined flags ──
echo "── Combined flags ──"
run_test_stdin "-bsw5" "ab cd efgh\n" -bsw5
run_test_stdin "-bs -w 5" "ab cd efgh\n" -bs -w 5
run_test_stdin "-w5 -b" "1234567890\n" -w5 -b

# ── File arguments ──
echo "── File arguments ──"
run_test_file "single file" "$TMPDIR/long.txt"
run_test_file "multiple files" "$TMPDIR/f1.txt" "$TMPDIR/f2.txt"
run_test_file "empty file" "$TMPDIR/empty.txt"
run_test_file "file with -w 5" -w 5 "$TMPDIR/long.txt"
run_test_file "stdin dash" -w 5 -

# ── Error cases ──
echo "── Error cases ──"
run_test_noargs "unrecognized --xyz" --xyz
run_test_noargs "invalid -x" -x
run_test_noargs "invalid width 0" -w 0

# ── Summary ──────────────────────────────────────────────────
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
