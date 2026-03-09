#!/bin/bash
# GNU compatibility tests for ffold (assembly)
# Compares byte-for-byte stdout and exit code against GNU fold
# Usage: bash test_ffold.sh [path-to-ffold]

BIN="${1:-../fold/ffold}"
GNU="/usr/bin/fold"

PASS=0
FAIL=0
ERRORS=()

TMPDIR=$(mktemp -d /tmp/test_ffold.XXXXXX)
trap "rm -rf $TMPDIR" EXIT

run_test_stdin() {
    local desc="$1"
    local input="$2"
    shift 2
    local args=("$@")

    printf "$input" | $GNU "${args[@]}" > "$TMPDIR/expected" 2> "$TMPDIR/expected_err"
    local expected_exit=$?
    printf "$input" | $BIN "${args[@]}" > "$TMPDIR/got" 2> "$TMPDIR/got_err"
    local got_exit=$?

    if diff -q "$TMPDIR/expected" "$TMPDIR/got" > /dev/null 2>&1 && \
       [ "$expected_exit" = "$got_exit" ]; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
        ERRORS+=("FAIL: $desc")
        if ! diff -q "$TMPDIR/expected" "$TMPDIR/got" > /dev/null 2>&1; then
            ERRORS+=("  expected (hex): $(head -c 200 "$TMPDIR/expected" | od -A n -t x1 | head -2)")
            ERRORS+=("  got (hex):      $(head -c 200 "$TMPDIR/got" | od -A n -t x1 | head -2)")
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
            ERRORS+=("  expected (hex): $(head -c 200 "$TMPDIR/expected" | od -A n -t x1 | head -2)")
            ERRORS+=("  got (hex):      $(head -c 200 "$TMPDIR/got" | od -A n -t x1 | head -2)")
        fi
        if [ "$expected_exit" != "$got_exit" ]; then
            ERRORS+=("  expected exit: $expected_exit, got: $got_exit")
        fi
    fi
}

run_test_exit() {
    local desc="$1"
    shift
    local args=("$@")

    $GNU "${args[@]}" < /dev/null > /dev/null 2>&1
    local expected_exit=$?
    $BIN "${args[@]}" < /dev/null > /dev/null 2>&1
    local got_exit=$?

    if [ "$expected_exit" = "$got_exit" ]; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
        ERRORS+=("FAIL: $desc (expected exit=$expected_exit, got=$got_exit)")
    fi
}

# ── Create test files ──
python3 -c "print('a'*100)" > "$TMPDIR/long.txt"
printf "hello\nworld\n" > "$TMPDIR/basic.txt"
printf "" > "$TMPDIR/empty.txt"
printf "line with spaces in it\n" > "$TMPDIR/spaces.txt"
printf "1234567890" > "$TMPDIR/nonewline.txt"
printf "x" > "$TMPDIR/single_char.txt"

echo "=== ffold GNU compatibility tests ==="
echo ""

# ── Basic fold (default width 80) ──
echo "-- Basic fold (default width 80) --"
run_test_stdin "default width 80" "$(python3 -c "print('a'*100)")"
run_test_stdin "short line passthrough" "hello\n"
run_test_stdin "empty input" ""
run_test_stdin "just newline" "\n"
run_test_stdin "multiple newlines" "\n\n\n"
run_test_stdin "no trailing newline" "hello"
run_test_stdin "width 80 exact" "$(python3 -c "print('a'*80)")"
run_test_stdin "width 80 + 1" "$(python3 -c "print('a'*81)")"
run_test_stdin "long line 200 chars" "$(python3 -c "print('x'*200)")"

# ── Width option -w 20 (narrow) ──
echo "-- Width option --"
run_test_stdin "-w 20" "$(python3 -c "print('a'*60)")" -w 20
run_test_stdin "-w 5" "1234567890\n" -w 5
run_test_stdin "-w 1" "abc\n" -w 1
run_test_stdin "-w 10" "1234567890\n" -w 10
run_test_stdin "-w 999 (no fold)" "hello world\n" -w 999

# ── Break at spaces (-s) ──
echo "-- Break at spaces (-s) --"
run_test_stdin "-s -w 15" "hello world this is a test\n" -s -w 15
run_test_stdin "-s no space (hard break)" "abcdefghij\n" -s -w 5
run_test_stdin "-s at boundary" "ab cd\n" -s -w 3
run_test_stdin "-s longer text" "abc def ghi jkl mno\n" -s -w 8
run_test_stdin "-s multiple spaces" "a b c d\n" -s -w 4

# ── Byte mode (-b) ──
echo "-- Byte mode (-b) --"
run_test_stdin "-b -w 5" "1234567890\n" -b -w 5
run_test_stdin "-b -w 1" "abc\n" -b -w 1
run_test_stdin "-b default" "$(python3 -c "print('a'*100)")" -b
run_test_stdin "-b tab is 1 byte" "1234\tabc\n" -b -w 5

# ── Long line without newlines ──
echo "-- Long line without newlines --"
run_test_stdin "long no newline" "$(python3 -c "import sys; sys.stdout.write('a'*500)")" -w 80

# ── Empty input ──
echo "-- Empty and single char --"
run_test_stdin "empty input" ""
run_test_file "empty file" "$TMPDIR/empty.txt"
run_test_file "single char file" "$TMPDIR/single_char.txt"
run_test_stdin "single char stdin" "x"

# ── File arguments ──
echo "-- File arguments --"
run_test_file "file default width" "$TMPDIR/long.txt"
run_test_file "file -w 5" -w 5 "$TMPDIR/long.txt"
run_test_file "file basic" "$TMPDIR/basic.txt"

# ── Combined flags ──
echo "-- Combined flags --"
run_test_stdin "-bs -w 5" "ab cd efgh\n" -bs -w 5
run_test_stdin "-bsw5" "ab cd efgh\n" -bsw5

# ── Error cases ──
echo "-- Error cases --"
run_test_exit "invalid -w 0" -w 0
run_test_exit "invalid option -x" -x

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
