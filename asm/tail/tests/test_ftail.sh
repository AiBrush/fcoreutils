#!/bin/bash
set -uo pipefail

TOOL="${TOOL:-./ftail}"
GNU="tail"
PASS=0
FAIL=0
ERRORS=""

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
        ERRORS+="    GNU (${#gnu_out} bytes): $(echo -n "$gnu_out" | head -c 200 | cat -v | head -1)\n"
        ERRORS+="    OUR (${#our_out} bytes): $(echo -n "$our_out" | head -c 200 | cat -v | head -1)\n"
    fi

    if [ "$gnu_exit" != "$our_exit" ]; then
        failed=1
        ERRORS+="  EXIT CODE MISMATCH: $test_name (GNU=$gnu_exit, OURS=$our_exit)\n"
    fi

    if [ -n "$gnu_err" ] && [ -z "$our_err" ]; then
        failed=1
        ERRORS+="  MISSING STDERR: $test_name\n"
        ERRORS+="    GNU stderr: $(echo -n "$gnu_err" | head -c 200)\n"
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
    gnu_out=$(echo -n "$input" | $GNU "${args[@]}" 2>/tmp/gnu_err) || gnu_exit=$?
    gnu_err=$(cat /tmp/gnu_err)

    local our_out our_err our_exit=0
    our_out=$(echo -n "$input" | $TOOL "${args[@]}" 2>/tmp/our_err) || our_exit=$?
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
echo " GNU Compatibility Tests: ftail"
echo "============================================"
echo ""

# Create test fixtures
TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT

seq 1 5 > "$TMPDIR/five.txt"
seq 1 20 > "$TMPDIR/twenty.txt"
seq 1 100 > "$TMPDIR/hundred.txt"
seq 1 10000 > "$TMPDIR/numbers.txt"
echo -n "no trailing newline" > "$TMPDIR/nonewline.txt"
echo -e "line1\nline2\nline3" > "$TMPDIR/multi.txt"
touch "$TMPDIR/empty.txt"
echo -e "a\nb\nc\nd\ne" > "$TMPDIR/five_letters.txt"
echo "single line" > "$TMPDIR/single.txt"
printf '\x00\x01\x02\n\x03\x04' > "$TMPDIR/binary.txt"
python3 -c "print('a'*100000)" > "$TMPDIR/longline.txt"
printf 'a\x00b\x00c\x00d\x00e\x00f\x00g\x00h\x00i\x00j\x00k\x00' > "$TMPDIR/nulterm.txt"
echo "aaa" > "$TMPDIR/t1.txt"
echo "bbb" > "$TMPDIR/t2.txt"
echo "ccc" > "$TMPDIR/t3.txt"

# ── SECTION: Basic functionality (stdin) ──
echo "── Basic functionality (stdin) ──"

run_test "default 10 lines" "$(seq 1 20)"
run_test "default fewer than 10" "$(echo -e 'a\nb\nc')"
run_test "default single line" "$(echo 'hello')"
run_test "default empty" ""
run_test "-n 5" "$(seq 1 20)" -n 5
run_test "-n 1" "$(seq 1 20)" -n 1
run_test "-n 0" "$(seq 1 20)" -n 0
run_test "-n 100 (more than input)" "$(seq 1 5)" -n 100
run_test "-n +1 (whole file)" "$(echo -e 'a\nb\nc')" -n +1
run_test "-n +3 (from line 3)" "$(seq 1 10)" -n +3
run_test "-n +100 (past end)" "$(seq 1 5)" -n +100
run_test "-c 5" "$(echo 'hello world')" -c 5
run_test "-c 0" "$(echo 'hello')" -c 0
run_test "-c 100 (more than input)" "$(echo 'hi')" -c 100
run_test "-c +1 (whole file)" "$(echo 'hello')" -c +1
run_test "-c +5" "$(echo 'hello world')" -c +5
run_test "-c +100 (past end)" "$(echo 'hi')" -c +100
run_test "no trailing newline" "$(printf 'abc\ndef')" -n 1
run_test "binary data" "$(printf '\x00\x01\x02\n\x03\x04')" -n 1

# ── SECTION: File operations ──
echo ""
echo "── File operations ──"

run_test_file "file: default" "$TMPDIR/twenty.txt"
run_test_file "file: -n 5" "$TMPDIR/twenty.txt" -n 5
run_test_file "file: -n +3" "$TMPDIR/twenty.txt" -n +3
run_test_file "file: -c 10" "$TMPDIR/twenty.txt" -c 10
run_test_file "file: -c +5" "$TMPDIR/twenty.txt" -c +5
run_test_file "file: empty" "$TMPDIR/empty.txt"
run_test_file "file: no newline" "$TMPDIR/nonewline.txt"
run_test_file "file: no newline -n 1" "$TMPDIR/nonewline.txt" -n 1
run_test_file "file: long line" "$TMPDIR/longline.txt"
run_test_file "file: large" "$TMPDIR/numbers.txt" -n 50

# ── SECTION: Multiple files ──
echo ""
echo "── Multiple files ──"

run_test_files "two files" "$TMPDIR/t1.txt" "$TMPDIR/t2.txt"
run_test_files "three files" "$TMPDIR/t1.txt" "$TMPDIR/t2.txt" "$TMPDIR/t3.txt"
run_test_files "files -n 2" -n 2 "$TMPDIR/twenty.txt" "$TMPDIR/five.txt"
run_test_files "files -c 5" -c 5 "$TMPDIR/t1.txt" "$TMPDIR/t2.txt"
run_test_files "mixed valid/invalid (stdout)" "$TMPDIR/t1.txt" /nonexistent "$TMPDIR/t2.txt"

# ── SECTION: Flags ──
echo ""
echo "── Flags ──"

run_test_files "-q two files" -q "$TMPDIR/t1.txt" "$TMPDIR/t2.txt"
run_test_files "-v single file" -v "$TMPDIR/t1.txt"
run_test_files "-v two files" -v "$TMPDIR/t1.txt" "$TMPDIR/t2.txt"
run_test "-z (NUL delimiter)" "$(printf 'a\x00b\x00c\x00d\x00e\x00')" -z -n 2

# ── SECTION: Number suffixes ──
echo ""
echo "── Number suffixes ──"

run_test "-n 1K" "$(seq 1 2000)" -n 1K
run_test "-c 1K" "$(seq 1 10000)" -c 1K
run_test "-n 1b" "$(seq 1 1000)" -n 1b

# ── SECTION: Combined short options ──
echo ""
echo "── Combined short options ──"

run_test "-qn5" "$(seq 1 20)" -qn5
run_test "-vn3" "$(seq 1 10)" -vn3

# ── SECTION: Long options ──
echo ""
echo "── Long options ──"

run_test "--lines=5" "$(seq 1 20)" --lines=5
run_test "--lines 5" "$(seq 1 20)" --lines 5
run_test "--bytes=5" "$(echo 'hello world')" --bytes=5
run_test "--bytes 5" "$(echo 'hello world')" --bytes 5
run_test "--lines=+3" "$(seq 1 10)" --lines=+3
run_test "--bytes=+5" "$(echo 'hello world')" --bytes=+5

# ── SECTION: Legacy syntax ──
echo ""
echo "── Legacy syntax ──"

run_test "-5 (legacy)" "$(seq 1 20)" -5

# ── SECTION: Edge cases ──
echo ""
echo "── Edge cases ──"

run_test_file "empty file" "$TMPDIR/empty.txt"
run_test_file "binary input" "$TMPDIR/binary.txt"
run_test_file "very long line" "$TMPDIR/longline.txt"
run_test_file "no trailing newline" "$TMPDIR/nonewline.txt"

# ── SECTION: Error handling ──
echo ""
echo "── Error handling ──"

run_test_files "nonexistent file" /nonexistent/file

# ── SECTION: Stdin marker ──
echo ""
echo "── Stdin marker ──"

run_test "stdin via -" "$(echo hello)" -

# ── SECTION: End of options ──
echo ""
echo "── End of options ──"

# Create a file that starts with -
echo "test" > "$TMPDIR/-n.txt"
run_test_files "-- then file" -- "$TMPDIR/t1.txt"

# ── SECTION: Large file (seekable) ──
echo ""
echo "── Large file tests ──"

seq 1 100000 > "$TMPDIR/large.txt"
run_test_file "large file default" "$TMPDIR/large.txt"
run_test_file "large file -n 50" "$TMPDIR/large.txt" -n 50
run_test_file "large file -n +99990" "$TMPDIR/large.txt" -n +99990
run_test_file "large file -c 100" "$TMPDIR/large.txt" -c 100
run_test_file "large file -c +100" "$TMPDIR/large.txt" -c +100

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
