#!/bin/bash
set -uo pipefail

TOOL="./fwc"
GNU="/usr/bin/wc"
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

    # Compare stdout byte-for-byte
    if ! diff <(printf '%s' "$gnu_out") <(printf '%s' "$our_out") > /dev/null 2>&1; then
        failed=1
        ERRORS+="  STDOUT MISMATCH: $test_name\n"
        ERRORS+="    GNU: $(printf '%s' "$gnu_out" | head -c 200 | od -A x -t x1z 2>/dev/null | head -3)\n"
        ERRORS+="    OUR: $(printf '%s' "$our_out" | head -c 200 | od -A x -t x1z 2>/dev/null | head -3)\n"
    fi

    # Compare exit code
    if [ "$gnu_exit" != "$our_exit" ]; then
        failed=1
        ERRORS+="  EXIT CODE MISMATCH: $test_name (GNU=$gnu_exit, OURS=$our_exit)\n"
    fi

    # Compare stderr presence (not exact text since tool name differs)
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

    local gnu_out gnu_err gnu_exit=0
    gnu_out=$(printf '%s' "$input" | $GNU "${args[@]}" 2>/tmp/gnu_err) || gnu_exit=$?
    gnu_err=$(cat /tmp/gnu_err)

    local our_out our_err our_exit=0
    our_out=$(printf '%s' "$input" | $TOOL "${args[@]}" 2>/tmp/our_err) || our_exit=$?
    our_err=$(cat /tmp/our_err)

    compare "$test_name" "$gnu_out" "$gnu_err" "$gnu_exit" "$our_out" "$our_err" "$our_exit"
}

run_test_file() {
    local test_name="$1"
    local file="$2"
    shift 2
    local args=("$@")

    local gnu_out gnu_err gnu_exit=0
    gnu_out=$($GNU "${args[@]}" "$file" 2>/tmp/gnu_err) || gnu_exit=$?
    gnu_err=$(cat /tmp/gnu_err)

    local our_out our_err our_exit=0
    our_out=$($TOOL "${args[@]}" "$file" 2>/tmp/our_err) || our_exit=$?
    our_err=$(cat /tmp/our_err)

    compare "$test_name" "$gnu_out" "$gnu_err" "$gnu_exit" "$our_out" "$our_err" "$our_exit"
}

run_test_files() {
    local test_name="$1"
    shift
    local args=("$@")

    local gnu_out gnu_err gnu_exit=0
    gnu_out=$($GNU "${args[@]}" 2>/tmp/gnu_err) || gnu_exit=$?
    gnu_err=$(cat /tmp/gnu_err)

    local our_out our_err our_exit=0
    our_out=$($TOOL "${args[@]}" 2>/tmp/our_err) || our_exit=$?
    our_err=$(cat /tmp/our_err)

    compare "$test_name" "$gnu_out" "$gnu_err" "$gnu_exit" "$our_out" "$our_err" "$our_exit"
}

echo ""
echo "============================================"
echo " GNU Compatibility Tests: fwc"
echo "============================================"
echo ""

# Create test fixtures
TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT

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
echo -n "no trailing newline" > "$TMPDIR/nonewline.txt"
printf "short\nthis is a much longer line for testing\nmed\n" > "$TMPDIR/varlines.txt"
printf "a\tb\tc\n12345678\t\nX\tY\n" > "$TMPDIR/tabtests.txt"

# ── SECTION: Basic functionality ──
echo "── Basic functionality ──"
run_test "default (lines+words+bytes)" "hello world\n"
run_test "single line" "hello\n"
run_test "multiple lines" "line1\nline2\nline3\n"
run_test "empty input" ""
run_test "just newline" "\n"
run_test "no trailing newline" "hello"
run_test "spaces only" "   \n"
run_test "tabs and spaces" "a\tb\tc\n"

# ── SECTION: Individual flags ──
echo ""
echo "── Individual flags ──"
run_test "-l flag" "hello\nworld\n" -l
run_test "-w flag" "hello world foo\n" -w
run_test "-c flag" "hello\n" -c
run_test "-m flag" "hello\n" -m
run_test "-L flag" "hello\nhi\n" -L

# ── SECTION: Combined flags ──
echo ""
echo "── Combined flags ──"
run_test "-lw" "hello world\n" -lw
run_test "-lc" "hello world\n" -lc
run_test "-wc" "hello world\n" -wc
run_test "-lwc" "hello world\n" -lwc
run_test "-cm" "hello\n" -cm
run_test "-lL" "short\nlonger line\n" -lL
run_test "-lwcmL" "hello world\n" -lwcmL

# Long forms
run_test "--lines" "hello\n" --lines
run_test "--words" "hello world\n" --words
run_test "--bytes" "hello\n" --bytes
run_test "--chars" "hello\n" --chars
run_test "--max-line-length" "hello\nhi\n" --max-line-length

# ── SECTION: File operations ──
echo ""
echo "── File operations ──"
run_test_file "simple file" "$TMPDIR/simple.txt"
run_test_file "multi-line file" "$TMPDIR/multi.txt"
run_test_file "empty file" "$TMPDIR/empty.txt"
run_test_file "file -l" "$TMPDIR/multi.txt" -l
run_test_file "file -w" "$TMPDIR/multi.txt" -w
run_test_file "file -c" "$TMPDIR/multi.txt" -c
run_test_file "file -L" "$TMPDIR/varlines.txt" -L
run_test_file "binary file" "$TMPDIR/binary.bin"
run_test_file "long line file" "$TMPDIR/longline.txt"
run_test_file "null bytes" "$TMPDIR/nullbytes.txt"
run_test_file "no trailing newline" "$TMPDIR/nonewline.txt"
run_test_file "numbers file" "$TMPDIR/numbers.txt"
run_test_file "tab file -L" "$TMPDIR/tabtests.txt" -L

# ── SECTION: Multiple files ──
echo ""
echo "── Multiple files ──"
run_test_files "two files" "$TMPDIR/multi.txt" "$TMPDIR/five.txt"
run_test_files "three files" "$TMPDIR/multi.txt" "$TMPDIR/five.txt" "$TMPDIR/simple.txt"
run_test_files "two files -l" -l "$TMPDIR/multi.txt" "$TMPDIR/five.txt"
run_test_files "two files -w" -w "$TMPDIR/multi.txt" "$TMPDIR/five.txt"
run_test_files "file + empty" "$TMPDIR/multi.txt" "$TMPDIR/empty.txt"

# ── SECTION: Error handling ──
echo ""
echo "── Error handling ──"
run_test_files "nonexistent file" /nonexistent/file
run_test_files "error + valid file" /nonexistent "$TMPDIR/multi.txt"

# ── SECTION: --total flag ──
echo ""
echo "── --total flag ──"
run_test_files "--total=always single" --total=always "$TMPDIR/multi.txt"
run_test_files "--total=never multi" --total=never "$TMPDIR/multi.txt" "$TMPDIR/five.txt"
run_test_files "--total=only multi" --total=only "$TMPDIR/multi.txt" "$TMPDIR/five.txt"
run_test_files "--total=auto single" --total=auto "$TMPDIR/multi.txt"
run_test_files "--total=auto multi" --total=auto "$TMPDIR/multi.txt" "$TMPDIR/five.txt"

# ── SECTION: Edge cases ──
echo ""
echo "── Edge cases ──"
run_test "only whitespace" "   \t\n  \n"
run_test "many newlines" "\n\n\n\n\n"
run_test "word boundary - ctrl chars" "\x01\x02\x03"
run_test "printable+ctrl word" "a\x01b" -w
run_test "spaced ctrl chars" "a \x01 b" -w

# ── SECTION: stdin behaviors ──
echo ""
echo "── stdin behaviors ──"
run_test "implicit stdin" "hello\n"
run_test "implicit stdin -l" "hello\n" -l

# ── SECTION: -- end of options ──
echo ""
echo "── -- end of options ──"
run_test "-- no args" "hello\n" --

# ── SECTION: -c only fast path (fstat) ──
echo ""
echo "── -c only fast path ──"
run_test_file "-c fstat" /etc/passwd -c
run_test_file "-c empty" "$TMPDIR/empty.txt" -c
run_test_files "-c two files" -c "$TMPDIR/multi.txt" "$TMPDIR/five.txt"

# ── SECTION: Stress tests ──
echo ""
echo "── Stress tests ──"
# Large file
dd if=/dev/urandom bs=1M count=10 of="$TMPDIR/large.bin" 2>/dev/null
run_test_file "10MB binary" "$TMPDIR/large.bin"
run_test_file "10MB -l" "$TMPDIR/large.bin" -l
run_test_file "10MB -w" "$TMPDIR/large.bin" -w
run_test_file "10MB -c" "$TMPDIR/large.bin" -c

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
