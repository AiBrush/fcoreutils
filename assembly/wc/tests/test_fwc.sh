#!/bin/bash
set -uo pipefail

TOOL="./fwc"
GNU="wc"
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
    if [ "$gnu_out" != "$our_out" ]; then
        failed=1
        ERRORS+="  STDOUT MISMATCH: $test_name\n"
        ERRORS+="    GNU: $(echo -n "$gnu_out" | od -c | head -5)\n"
        ERRORS+="    OUR: $(echo -n "$our_out" | od -c | head -5)\n"
    fi

    # Compare exit code
    if [ "$gnu_exit" != "$our_exit" ]; then
        failed=1
        ERRORS+="  EXIT CODE MISMATCH: $test_name (GNU=$gnu_exit, OURS=$our_exit)\n"
    fi

    # Compare stderr presence
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
echo " GNU Compatibility Tests: fwc"
echo "============================================"
echo ""

# Create test fixtures
TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT

echo -n "hello world" > "$TMPDIR/simple.txt"
echo -e "line1\nline2\nline3" > "$TMPDIR/multi.txt"
echo -e "foo\tbar\tbaz" > "$TMPDIR/tabs.txt"
dd if=/dev/urandom bs=1024 count=64 of="$TMPDIR/binary.bin" 2>/dev/null
python3 -c "print('a'*100000)" > "$TMPDIR/longline.txt"
touch "$TMPDIR/empty.txt"
echo -e "a\nb\nc\nd\ne" > "$TMPDIR/five.txt"
seq 1 10000 > "$TMPDIR/numbers.txt"
printf '\x00\x01\x02\x03\n' > "$TMPDIR/nullbytes.txt"
echo -e "  leading spaces" > "$TMPDIR/spaces.txt"
echo -n "no trailing newline" > "$TMPDIR/nonewline.txt"
echo -e "one two three\nfour five\nsix" > "$TMPDIR/words.txt"
echo -e "short\na very long line here\nmed" > "$TMPDIR/maxline.txt"

# ── SECTION: Basic functionality ──
echo "── Basic functionality ──"
run_test "stdin default"                "hello world\n"
run_test "stdin -l"                     "line1\nline2\nline3\n" -l
run_test "stdin -w"                     "hello world foo\n" -w
run_test "stdin -c"                     "hello\n" -c
run_test "stdin -m"                     "hello\n" -m
run_test "stdin -L"                     "hello world\n" -L
run_test "stdin -lw"                    "hello world\n" -lw
run_test "stdin -lwc"                   "hello world\n" -lwc
run_test "stdin -lc"                    "hello world\n" -lc
run_test "stdin -wc"                    "hello world\n" -wc
run_test "stdin -cm"                    "hello\n" -cm

run_test_file "file default"            "$TMPDIR/multi.txt"
run_test_file "file -l"                 -l "$TMPDIR/multi.txt"
run_test_file "file -w"                 -w "$TMPDIR/multi.txt"
run_test_file "file -c"                 -c "$TMPDIR/multi.txt"
run_test_file "file -m"                 -m "$TMPDIR/multi.txt"
run_test_file "file -L"                 -L "$TMPDIR/multi.txt"

# ── SECTION: Edge cases ──
echo ""
echo "── Edge cases ──"
run_test_file "empty file"              "$TMPDIR/empty.txt"
run_test_file "binary input"            "$TMPDIR/binary.bin"
run_test_file "null bytes"              "$TMPDIR/nullbytes.txt"
run_test_file "very long line"          "$TMPDIR/longline.txt"
run_test_file "no trailing newline"     "$TMPDIR/nonewline.txt"
run_test "empty stdin"                  ""
run_test "stdin single char"            "x"
run_test "stdin single newline"         "\n"
run_test "stdin only spaces"            "   "
run_test "stdin tabs"                   "\t\t\t"

# ── SECTION: Error handling ──
echo ""
echo "── Error handling ──"
run_test_file "nonexistent file"        /nonexistent/file

# ── SECTION: Multiple files ──
echo ""
echo "── Multiple files ──"
run_test_file "two files"               "$TMPDIR/multi.txt" "$TMPDIR/words.txt"
run_test_file "three files"             "$TMPDIR/empty.txt" "$TMPDIR/multi.txt" "$TMPDIR/words.txt"
run_test_file "two files -l"            -l "$TMPDIR/multi.txt" "$TMPDIR/words.txt"
run_test_file "two files -w"            -w "$TMPDIR/multi.txt" "$TMPDIR/words.txt"
run_test_file "two files -c"            -c "$TMPDIR/multi.txt" "$TMPDIR/words.txt"
run_test_file "file + nonexistent"      "$TMPDIR/multi.txt" /nonexistent/path

# ── SECTION: All flags ──
echo ""
echo "── All flags ──"
run_test "flag --lines"                 "a\nb\nc\n" --lines
run_test "flag --words"                 "a b c\n" --words
run_test "flag --bytes"                 "hello\n" --bytes
run_test "flag --chars"                 "hello\n" --chars
run_test "flag --max-line-length"       "hello world\n" --max-line-length

# ── SECTION: --total ──
echo ""
echo "── --total modes ──"
run_test_file "total=auto 1 file"       --total=auto "$TMPDIR/multi.txt"
run_test_file "total=auto 2 files"      --total=auto "$TMPDIR/multi.txt" "$TMPDIR/words.txt"
run_test_file "total=always 1 file"     --total=always "$TMPDIR/multi.txt"
run_test_file "total=never 2 files"     --total=never "$TMPDIR/multi.txt" "$TMPDIR/words.txt"
run_test_file "total=only 2 files"      --total=only "$TMPDIR/multi.txt" "$TMPDIR/words.txt"

# ── SECTION: Explicit stdin ──
echo ""
echo "── Explicit stdin ──"
run_test "explicit dash"                "hello\n" -

# ── SECTION: Large data ──
echo ""
echo "── Large data ──"
run_test_file "numbers file"            "$TMPDIR/numbers.txt"
run_test_file "numbers -l"              -l "$TMPDIR/numbers.txt"
run_test_file "numbers -w"              -w "$TMPDIR/numbers.txt"
run_test_file "numbers -c"              -c "$TMPDIR/numbers.txt"

# ── SECTION: Word counting edge cases ──
echo ""
echo "── Word counting ──"
run_test "multiple spaces"              "hello    world"
run_test "leading spaces"               "  hello"
run_test "trailing spaces"              "hello  "
run_test "mixed whitespace"             "a\tb\nc\rd"
run_test "single word"                  "hello"
run_test "empty lines"                  "\n\n\n"
run_test "words across lines"           "hello\nworld\nfoo"

# ── SECTION: Max line length ──
echo ""
echo "── Max line length ──"
run_test "max line length -L"           "short\na very long line here\nmed" -L
run_test "max line empty"               "" -L
run_test "max line no newline"          "hello world" -L
run_test_file "max line file"           -L "$TMPDIR/maxline.txt"
run_test_file "max line long"           -L "$TMPDIR/longline.txt"

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
