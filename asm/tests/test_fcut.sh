#!/bin/bash
set -uo pipefail

TOOL="./fcut"
GNU="cut"
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
        ERRORS+="    GNU: $(echo -n "$gnu_out" | head -c 200 | od -A x -t x1z | head -3)\n"
        ERRORS+="    OUR: $(echo -n "$our_out" | head -c 200 | od -A x -t x1z | head -3)\n"
    fi

    if [ "$gnu_exit" != "$our_exit" ]; then
        failed=1
        ERRORS+="  EXIT CODE MISMATCH: $test_name (GNU=$gnu_exit, OURS=$our_exit)\n"
    fi

    # Check stderr presence matches
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

run_test_noargs() {
    local test_name="$1"
    shift
    local args=("$@")

    local gnu_out gnu_err gnu_exit=0
    gnu_out=$($GNU "${args[@]}" 2>/tmp/gnu_err </dev/null) || gnu_exit=$?
    gnu_err=$(cat /tmp/gnu_err)

    local our_out our_err our_exit=0
    our_out=$($TOOL "${args[@]}" 2>/tmp/our_err </dev/null) || our_exit=$?
    our_err=$(cat /tmp/our_err)

    compare "$test_name" "$gnu_out" "$gnu_err" "$gnu_exit" "$our_out" "$our_err" "$our_exit"
}

echo ""
echo "============================================"
echo " GNU Compatibility Tests: fcut"
echo "============================================"
echo ""

# Create test fixtures
TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT

echo -e "a,b,c,d,e" > "$TMPDIR/csv.txt"
echo -e "f,g,h,i,j" >> "$TMPDIR/csv.txt"
printf "a\tb\tc\td\n" > "$TMPDIR/tabs.txt"
printf "e\tf\tg\th\n" >> "$TMPDIR/tabs.txt"
echo -e "line1\nline2\nline3" > "$TMPDIR/multi.txt"
touch "$TMPDIR/empty.txt"
echo -n "no trailing newline" > "$TMPDIR/nonewline.txt"
printf '\x00\x01\x02\x03\n' > "$TMPDIR/nullbytes.txt"
python3 -c "print('a'*100000)" > "$TMPDIR/longline.txt"
echo -e "no-delimiter-here" > "$TMPDIR/nodelim.txt"
echo -e "a:b:c:d:e" > "$TMPDIR/colon.txt"
echo -e ",,," > "$TMPDIR/emptyfields.txt"
echo -e "a,,c,,e" > "$TMPDIR/sparsefields.txt"

# Second CSV file for multi-file tests
echo -e "x,y,z" > "$TMPDIR/csv2.txt"

# ── SECTION: Fields mode (-f) basic ──
echo "── Fields mode (-f) basic ──"
run_test "f: single field -f1"       "a,b,c,d,e"  -f1 -d,
run_test "f: single field -f3"       "a,b,c,d,e"  -f3 -d,
run_test "f: last field -f5"         "a,b,c,d,e"  -f5 -d,
run_test "f: past-end field -f10"    "a,b,c,d,e"  -f10 -d,
run_test "f: range -f2-4"           "a,b,c,d,e"  -f2-4 -d,
run_test "f: open-end -f3-"         "a,b,c,d,e"  -f3- -d,
run_test "f: open-start -f-3"       "a,b,c,d,e"  -f-3 -d,
run_test "f: multiple -f1,3,5"      "a,b,c,d,e"  -f1,3,5 -d,
run_test "f: overlapping -f1-3,2-5" "a,b,c,d,e"  -f1-3,2-5 -d,
run_test "f: all fields -f1-"       "a,b,c,d,e"  -f1- -d,

# ── SECTION: Fields mode with tab delimiter (default) ──
echo ""
echo "── Fields mode (default tab delimiter) ──"
run_test "f: tab default -f1"     "$(printf 'a\tb\tc')"  -f1
run_test "f: tab default -f2"     "$(printf 'a\tb\tc')"  -f2
run_test "f: tab default -f1,3"   "$(printf 'a\tb\tc')"  -f1,3

# ── SECTION: Fields mode -s (suppress no-delim) ──
echo ""
echo "── Fields mode (-s suppress) ──"
run_test "f: no-delim without -s"  "no-delimiter-here"  -f1 -d,
run_test "f: no-delim with -s"     "no-delimiter-here"  -f1 -d, -s
run_test "f: mixed delim with -s"  "$(printf 'a,b\nno-delim\nc,d')" -f1 -d, -s

# ── SECTION: Bytes mode (-b) ──
echo ""
echo "── Bytes mode (-b) ──"
run_test "b: single byte -b1"      "hello"  -b1
run_test "b: single byte -b5"      "hello"  -b5
run_test "b: past-end -b10"        "hello"  -b10
run_test "b: range -b1-3"          "hello"  -b1-3
run_test "b: range -b2-4"          "hello"  -b2-4
run_test "b: open-end -b3-"        "hello"  -b3-
run_test "b: open-start -b-3"      "hello"  -b-3
run_test "b: multiple -b1,3,5"     "hello"  -b1,3,5
run_test "b: overlapping -b1-3,2-5" "hello" -b1-3,2-5

# ── SECTION: Characters mode (-c) ──
echo ""
echo "── Characters mode (-c) ──"
run_test "c: single -c1"           "hello"  -c1
run_test "c: range -c2-4"          "hello"  -c2-4
run_test "c: multiple -c1,3,5"     "hello"  -c1,3,5

# ── SECTION: Complement (--complement) ──
echo ""
echo "── Complement (--complement) ──"
run_test "comp: f complement -f2"          "a,b,c,d,e"  -f2 -d, --complement
run_test "comp: f complement -f1,3,5"      "a,b,c,d,e"  -f1,3,5 -d, --complement
run_test "comp: f complement -f2-4"        "a,b,c,d,e"  -f2-4 -d, --complement
run_test "comp: b complement -b2-4"        "hello"       -b2-4 --complement
run_test "comp: b complement -b1,3,5"      "hello"       -b1,3,5 --complement

# ── SECTION: Output delimiter ──
echo ""
echo "── Output delimiter ──"
run_test "outdelim: f with :"       "a,b,c,d,e"  -f1,3,5 -d, --output-delimiter=:
run_test "outdelim: f with multi"   "a,b,c,d,e"  -f1,3 -d, --output-delimiter='::'
run_test "outdelim: b with :"       "hello"       -b1,3,5 --output-delimiter=:
run_test "outdelim: b with empty"   "hello"       -b1,3,5 --output-delimiter=''

# ── SECTION: Custom delimiter ──
echo ""
echo "── Custom delimiter (-d) ──"
run_test "delim: colon"             "a:b:c:d"  -f2 -d:
run_test "delim: space"             "a b c d"  -f2 "-d "
run_test "delim: pipe"              "a|b|c"    -f1,3 "-d|"

# ── SECTION: Empty fields ──
echo ""
echo "── Empty fields ──"
run_test "empty: all empty"         ",,,"       -f1,2,3 -d,
run_test "empty: sparse"            "a,,c,,e"   -f1,2,3 -d,
run_test "empty: first empty"       ",b,c"      -f1 -d,
run_test "empty: last empty"        "a,b,"      -f3 -d,

# ── SECTION: Multi-line input ──
echo ""
echo "── Multi-line input ──"
run_test "multi: csv"    "$(printf 'a,b,c\nd,e,f\ng,h,i')"  -f2 -d,
run_test "multi: bytes"  "$(printf 'hello\nworld\ntest!')"   -b1-3

# ── SECTION: Edge cases ──
echo ""
echo "── Edge cases ──"
run_test_file "empty file"                "$TMPDIR/empty.txt" -b1
run_test_file "file no trailing newline"  "$TMPDIR/nonewline.txt" -b1-5
run_test_file "null bytes"                "$TMPDIR/nullbytes.txt" -b1-3
run_test_file "very long line bytes"      "$TMPDIR/longline.txt" -b1-10
run_test_file "very long line fields"     "$TMPDIR/longline.txt" -f1

# ── SECTION: Multiple files ──
echo ""
echo "── Multiple files ──"
run_test_noargs "multi file"     -f2 -d, "$TMPDIR/csv.txt" "$TMPDIR/csv2.txt"

# ── SECTION: Error handling ──
echo ""
echo "── Error handling ──"
run_test_noargs "no mode"           2>/dev/null
run_test_noargs "nonexistent file"  -f1 -d, /nonexistent/file
run_test_noargs "multi mode -b -f"  -b1 -f1
run_test_noargs "bad range 0"       -b0
run_test_noargs "decreasing range"  -b3-1
run_test_noargs "bad delimiter"     -f1 -d,,

# ── SECTION: Stdin and - ──
echo ""
echo "── Stdin handling ──"
run_test "stdin: basic"          "a,b,c"  -f1 -d,
run_test "stdin: with -"        "a,b,c"  -f1 -d, -

# ── SECTION: Combined short options ──
echo ""
echo "── Combined short options ──"
run_test "combined: -sf1"        "$(printf 'a,b\nnone\nc,d')"  -sf1 -d,
run_test "combined: -snf1"       "$(printf 'a,b\nnone\nc,d')"  -snf1 -d,

# ── SECTION: Long options with separate values ──
echo ""
echo "── Long options with separate values ──"
run_test "long: --bytes 1"        "hello"       --bytes 1
run_test "long: --bytes 1-3"      "hello"       --bytes 1-3
run_test "long: --characters 2"   "hello"       --characters 2
run_test "long: --fields 2 --delimiter ,"  "a,b,c"  --fields 2 --delimiter ,
run_test "long: --output-delimiter" "a,b,c"  --fields=1,3 --delimiter=, --output-delimiter ::

# ── SECTION: Unrecognized options ──
echo ""
echo "── Unrecognized options ──"
run_test_noargs "unrec: --xyz"       --xyz
run_test_noargs "unrec: --bad-opt"   --bad-opt

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
