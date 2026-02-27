#!/bin/bash
set -uo pipefail

TOOL="${TOOL:-./fhead}"
GNU="head"
PASS=0
FAIL=0
ERRORS=""

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

compare() {
    local test_name="$1"
    local gnu_out="$2"
    local gnu_err="$3"
    local gnu_exit="$4"
    local our_out="$5"
    local our_err="$6"
    local our_exit="$7"
    local failed=0

    if [ "$gnu_out" != "$our_out" ]; then
        failed=1
        ERRORS+="  STDOUT MISMATCH: $test_name\n"
        ERRORS+="    GNU (${#gnu_out} bytes): $(echo -n "$gnu_out" | od -c | head -3)\n"
        ERRORS+="    OUR (${#our_out} bytes): $(echo -n "$our_out" | od -c | head -3)\n"
    fi

    if [ "$gnu_exit" != "$our_exit" ]; then
        failed=1
        ERRORS+="  EXIT CODE MISMATCH: $test_name (GNU=$gnu_exit, OURS=$our_exit)\n"
    fi

    if [ -n "$gnu_err" ] && [ -z "$our_err" ]; then
        failed=1
        ERRORS+="  MISSING STDERR: $test_name\n"
        ERRORS+="    GNU stderr: $gnu_err\n"
    fi

    if [ "$failed" -eq 0 ]; then
        echo -e "  ${GREEN}PASS${NC}: $test_name"
        ((PASS++))
    else
        echo -e "  ${RED}FAIL${NC}: $test_name"
        ((FAIL++))
    fi
}

run_test() {
    local test_name="$1"
    shift
    local input="$1"
    shift
    local args=("$@")

    local gnu_out gnu_err gnu_exit
    gnu_out=$(echo -n "$input" | $GNU "${args[@]}" 2>/tmp/gnu_err) || gnu_exit=$?
    gnu_exit=${gnu_exit:-0}
    gnu_err=$(cat /tmp/gnu_err)

    local our_out our_err our_exit
    our_out=$(echo -n "$input" | $TOOL "${args[@]}" 2>/tmp/our_err) || our_exit=$?
    our_exit=${our_exit:-0}
    our_err=$(cat /tmp/our_err)

    compare "$test_name" "$gnu_out" "$gnu_err" "$gnu_exit" "$our_out" "$our_err" "$our_exit"
}

run_test_file() {
    local test_name="$1"
    local file="$2"
    shift 2
    local args=("$@")

    local gnu_out gnu_err gnu_exit
    gnu_out=$($GNU "${args[@]}" "$file" 2>/tmp/gnu_err) || gnu_exit=$?
    gnu_exit=${gnu_exit:-0}
    gnu_err=$(cat /tmp/gnu_err)

    local our_out our_err our_exit
    our_out=$($TOOL "${args[@]}" "$file" 2>/tmp/our_err) || our_exit=$?
    our_exit=${our_exit:-0}
    our_err=$(cat /tmp/our_err)

    compare "$test_name" "$gnu_out" "$gnu_err" "$gnu_exit" "$our_out" "$our_err" "$our_exit"
}

run_test_files() {
    local test_name="$1"
    shift
    local args=("$@")

    local gnu_out gnu_err gnu_exit
    gnu_out=$($GNU "${args[@]}" 2>/tmp/gnu_err) || gnu_exit=$?
    gnu_exit=${gnu_exit:-0}
    gnu_err=$(cat /tmp/gnu_err)

    local our_out our_err our_exit
    our_out=$($TOOL "${args[@]}" 2>/tmp/our_err) || our_exit=$?
    our_exit=${our_exit:-0}
    our_err=$(cat /tmp/our_err)

    compare "$test_name" "$gnu_out" "$gnu_err" "$gnu_exit" "$our_out" "$our_err" "$our_exit"
}

run_test_noargs() {
    local test_name="$1"
    shift
    local args=("$@")

    local gnu_out gnu_err gnu_exit
    gnu_out=$($GNU "${args[@]}" 2>/tmp/gnu_err) || gnu_exit=$?
    gnu_exit=${gnu_exit:-0}
    gnu_err=$(cat /tmp/gnu_err)

    local our_out our_err our_exit
    our_out=$($TOOL "${args[@]}" 2>/tmp/our_err) || our_exit=$?
    our_exit=${our_exit:-0}
    our_err=$(cat /tmp/our_err)

    compare "$test_name" "$gnu_out" "$gnu_err" "$gnu_exit" "$our_out" "$our_err" "$our_exit"
}

echo ""
echo "============================================"
echo " GNU Compatibility Tests: fhead"
echo "============================================"
echo ""

# Create test fixtures
TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR /tmp/gnu_err /tmp/our_err" EXIT

echo -n "hello world" > "$TMPDIR/simple.txt"
printf "line1\nline2\nline3\n" > "$TMPDIR/multi.txt"
printf "foo\tbar\tbaz\n" > "$TMPDIR/tabs.txt"
dd if=/dev/urandom bs=1024 count=64 of="$TMPDIR/binary.bin" 2>/dev/null
python3 -c "print('a'*100000)" > "$TMPDIR/longline.txt"
touch "$TMPDIR/empty.txt"
printf "a\nb\nc\nd\ne\n" > "$TMPDIR/five.txt"
seq 1 10000 > "$TMPDIR/numbers.txt"
printf '\x00\x01\x02\x03\n' > "$TMPDIR/nullbytes.txt"
printf "  leading spaces\n" > "$TMPDIR/spaces.txt"
printf "no trailing newline" > "$TMPDIR/nonewline.txt"
seq 1 100 > "$TMPDIR/hundred.txt"

# ── SECTION: Basic functionality ──
echo "── Basic functionality ──"
run_test "default 10 lines" "$(seq 1 20 | tr '\n' '\n')"
run_test "head -n 5" "$(seq 1 20 | tr '\n' '\n')" -n 5
run_test "head -n 1" "$(seq 1 20 | tr '\n' '\n')" -n 1
run_test "head -n 0" "$(seq 1 20 | tr '\n' '\n')" -n 0
run_test "head -c 10" "hello world test" -c 10
run_test "head -c 5" "hello world" -c 5
run_test "head -c 0" "hello" -c 0
run_test "head -n -3" "$(seq 1 10 | tr '\n' '\n')" -n -3
run_test "head -n -0" "$(seq 1 10 | tr '\n' '\n')" -n -0
run_test "head -c -5" "hello world" -c -5
run_test "head -c -0" "hello" -c -0
run_test "legacy -5" "$(seq 1 20 | tr '\n' '\n')" -5
run_test "legacy -1" "$(seq 1 20 | tr '\n' '\n')" -1

# ── SECTION: File operations ──
echo ""
echo "── File operations ──"
run_test_file "read from file" "$TMPDIR/multi.txt"
run_test_file "read 5 lines file" "$TMPDIR/five.txt" -n 3
run_test_file "read bytes from file" "$TMPDIR/multi.txt" -c 10
run_test_file "read large numbers file" "$TMPDIR/numbers.txt" -n 5
run_test_file "tabs in file" "$TMPDIR/tabs.txt"

# ── SECTION: Edge cases ──
echo ""
echo "── Edge cases ──"
run_test_file "empty file" "$TMPDIR/empty.txt"
run_test_file "binary input" "$TMPDIR/binary.bin" -n 5
run_test_file "null bytes" "$TMPDIR/nullbytes.txt"
run_test_file "very long line" "$TMPDIR/longline.txt"
run_test_file "no trailing newline" "$TMPDIR/nonewline.txt"
run_test "empty stdin" ""
run_test "single char" "x"
run_test "single newline" "$(printf '\n')"
run_test "many newlines" "$(printf '\n\n\n\n\n')" -n 3

# ── SECTION: Multiple files ──
echo ""
echo "── Multiple files ──"
run_test_files "two files" "$TMPDIR/multi.txt" "$TMPDIR/five.txt"
run_test_files "three files" "$TMPDIR/multi.txt" "$TMPDIR/five.txt" "$TMPDIR/tabs.txt"
run_test_files "two files with -n 2" -n 2 "$TMPDIR/multi.txt" "$TMPDIR/five.txt"
run_test_files "multi with nonexistent" "$TMPDIR/multi.txt" "/nonexistent" "$TMPDIR/five.txt"
run_test_files "quiet multi" -q "$TMPDIR/multi.txt" "$TMPDIR/five.txt"
run_test_files "verbose single" -v "$TMPDIR/multi.txt"

# ── SECTION: Zero-terminated mode ──
echo ""
echo "── Zero-terminated ──"
run_test "head -z -n 2" "$(printf 'a\0b\0c\0d\0e\0')" -z -n 2
run_test "head -z -n 1" "$(printf 'line1\0line2\0')" -z -n 1
run_test "head -z default" "$(printf 'a\0b\0c\0')" -z

# ── SECTION: Short option combinations ──
echo ""
echo "── Short option combinations ──"
run_test "-qn3" "$(seq 1 20 | tr '\n' '\n')" -qn3
run_test "-vn3" "$(seq 1 20 | tr '\n' '\n')" -vn3
run_test "-zn2" "$(printf 'a\0b\0c\0')" -zn2

# ── SECTION: Suffixes ──
echo ""
echo "── Numeric suffixes ──"
run_test_file "-c 1K" "$TMPDIR/numbers.txt" -c 1K
run_test_file "-c 1b (512)" "$TMPDIR/numbers.txt" -c 1b

# ── SECTION: Error handling ──
echo ""
echo "── Error handling ──"
run_test_noargs "nonexistent file" /nonexistent/file
run_test_noargs "invalid short option" -x
run_test_noargs "unrecognized long option" --foobar

# ── SECTION: Long options ──
echo ""
echo "── Long options ──"
run_test "--lines=5" "$(seq 1 20 | tr '\n' '\n')" --lines=5
run_test "--bytes=10" "hello world test" --bytes=10
run_test "--lines 5" "$(seq 1 20 | tr '\n' '\n')" --lines 5
run_test "--bytes 10" "hello world test" --bytes 10
run_test "--quiet multi" "$(seq 1 5 | tr '\n' '\n')" --quiet
run_test "--verbose" "$(seq 1 5 | tr '\n' '\n')" --verbose
run_test "--silent" "$(seq 1 5 | tr '\n' '\n')" --silent
run_test "--zero-terminated" "$(printf 'a\0b\0c\0')" --zero-terminated -n 2

# ── SECTION: -- end of options ──
echo ""
echo "── End of options (--) ──"
run_test_files "-- before filename" -- "$TMPDIR/multi.txt"

# ── SUMMARY ──
echo ""
echo "============================================"
echo -e " Results: ${GREEN}$PASS passed${NC}, ${RED}$FAIL failed${NC}"
echo "============================================"

if [ "$FAIL" -gt 0 ]; then
    echo ""
    echo -e "${RED}FAILURES:${NC}"
    echo -e "$ERRORS"
    exit 1
fi
