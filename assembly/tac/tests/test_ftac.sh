#!/bin/bash
set -uo pipefail

TOOL="${TOOL:-./ftac}"
GNU="tac"
PASS=0
FAIL=0
ERRORS=""

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

compare() {
    local test_name="$1"
    local gnu_out="$2"
    local our_out="$3"
    local gnu_exit="${4:-0}"
    local our_exit="${5:-0}"

    local failed=0

    if [ "$gnu_out" != "$our_out" ]; then
        failed=1
        ERRORS+="  STDOUT MISMATCH: $test_name\n"
    fi

    if [ "$gnu_exit" != "$our_exit" ]; then
        failed=1
        ERRORS+="  EXIT CODE MISMATCH: $test_name (GNU=$gnu_exit, OURS=$our_exit)\n"
    fi

    if [ "$failed" -eq 0 ]; then
        echo -e "  ${GREEN}PASS${NC}: $test_name"
        ((PASS++))
    else
        echo -e "  ${RED}FAIL${NC}: $test_name"
        ((FAIL++))
    fi
}

run_stdin() {
    local test_name="$1"
    local input="$2"
    shift 2
    local args=("$@")

    local gnu_out gnu_exit our_out our_exit
    gnu_exit=0; our_exit=0
    gnu_out=$(printf '%b' "$input" | $GNU "${args[@]}" 2>/dev/null) || gnu_exit=$?
    our_out=$(printf '%b' "$input" | $TOOL "${args[@]}" 2>/dev/null) || our_exit=$?

    compare "$test_name" "$gnu_out" "$our_out" "$gnu_exit" "$our_exit"
}

run_file() {
    local test_name="$1"
    local file="$2"
    shift 2
    local args=("$@")

    local gnu_out gnu_exit our_out our_exit
    gnu_out=$($GNU "${args[@]}" "$file" 2>/dev/null) || gnu_exit=$?
    gnu_exit=${gnu_exit:-0}
    our_out=$($TOOL "${args[@]}" "$file" 2>/dev/null) || our_exit=$?
    our_exit=${our_exit:-0}

    compare "$test_name" "$gnu_out" "$our_out" "$gnu_exit" "$our_exit"
}

run_noargs() {
    local test_name="$1"
    shift
    local args=("$@")

    local gnu_out gnu_exit our_out our_exit
    gnu_out=$($GNU "${args[@]}" 2>/dev/null) || gnu_exit=$?
    gnu_exit=${gnu_exit:-0}
    our_out=$($TOOL "${args[@]}" 2>/dev/null) || our_exit=$?
    our_exit=${our_exit:-0}

    compare "$test_name" "$gnu_out" "$our_out" "$gnu_exit" "$our_exit"
}

echo ""
echo "============================================"
echo " GNU Compatibility Tests: ftac"
echo "============================================"
echo ""

# Create test fixtures
TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT

printf 'line1\nline2\nline3\n' > "$TMPDIR/multi.txt"
printf 'first\nsecond\nthird\n' > "$TMPDIR/three.txt"
printf 'alpha\nbeta\n' > "$TMPDIR/two.txt"
printf 'hello world\n' > "$TMPDIR/simple.txt"
printf 'no trailing newline' > "$TMPDIR/nonewline.txt"
printf '' > "$TMPDIR/empty.txt"
printf '\n' > "$TMPDIR/onenl.txt"
printf '\n\n\n' > "$TMPDIR/multinl.txt"
printf '\x00\x01\x02\n\x03\x04\x05\n' > "$TMPDIR/binary.txt"
seq 1 10000 > "$TMPDIR/numbers.txt"
python3 -c "print('a'*100000)" > "$TMPDIR/longline.txt"

# ── SECTION: Basic functionality ──
echo "── Basic functionality ──"
run_stdin "3 lines"               "line1\nline2\nline3\n"
run_stdin "no trailing newline"   "line1\nline2\nline3"
run_stdin "empty input"           ""
run_stdin "single line"           "hello\n"
run_stdin "single char"           "x"
run_stdin "just newline"          "\n"
run_stdin "3 newlines"            "\n\n\n"
run_stdin "two lines"             "a\nb\n"
run_stdin "long content"          "$(seq 1 1000 | tr '\n' 'X' | sed 's/X$/\n/')"
run_file  "file basic"            "$TMPDIR/three.txt"
run_file  "file numbers"          "$TMPDIR/numbers.txt"

# ── SECTION: Before mode ──
echo ""
echo "── Before mode (-b) ──"
run_stdin "before 3 lines"        "line1\nline2\nline3\n" -b
run_stdin "before no trail NL"    "line1\nline2\nline3" -b
run_stdin "before empty"          "" -b
run_stdin "before single line"    "hello\n" -b
run_stdin "before 3 newlines"     "\n\n\n" -b
run_stdin "before just newline"   "\n" -b
run_file  "before file"           "$TMPDIR/three.txt" -b

# ── SECTION: Custom separator ──
echo ""
echo "── Custom separator (-s) ──"
run_stdin "sep X after"           "aXbXc" -s X
run_stdin "sep X before"          "aXbXc" -b -s X
run_stdin "sep at start"          "XaXb" -s X
run_stdin "sep at end"            "aXbX" -s X
run_stdin "sep = inline"          "a=b=c" -s=
run_stdin "sep -sX attached"      "aXbXc" -sX
run_stdin "multi-byte sep"        "aXYbXYc\n" -s XY
run_stdin "multi-byte before"     "aXYbXYc" -b -s XY
run_stdin "sep in word"           "line1\nline2\n" -s in
run_stdin "sep ABC"               "oneABCtwoABCthree" -s ABC
run_stdin "sep ABC before"        "oneABCtwoABCthree" -b -s ABC
run_stdin "overlap sep after"     "aXaXaXa" -s XaX
run_stdin "overlap sep before"    "aXaXaXa" -b -s XaX
run_stdin "consecutive seps"      "XYXY" -s XY
run_stdin "sep same as input"     "XY" -s XY

# ── SECTION: Combined flags ──
echo ""
echo "── Combined flags ──"
run_stdin "combined -bs"          "aXbXc" -bs X
run_stdin "combined -b -sX"       "aXbXc" -b -sX

# ── SECTION: Edge cases ──
echo ""
echo "── Edge cases ──"
run_stdin "empty separator"        "hello" -s ""
run_file  "empty file"            "$TMPDIR/empty.txt"
run_file  "binary input"          "$TMPDIR/binary.txt"
run_file  "very long line"        "$TMPDIR/longline.txt"
run_file  "no trailing newline"   "$TMPDIR/nonewline.txt"
run_file  "/dev/null"             "/dev/null"

# ── SECTION: Multiple files ──
echo ""
echo "── Multiple files ──"
run_noargs "two files" "$TMPDIR/three.txt" "$TMPDIR/two.txt"
run_noargs "file + error + file" "$TMPDIR/three.txt" "/nonexistent" "$TMPDIR/two.txt"

# ── SECTION: Error handling ──
echo ""
echo "── Error handling ──"
run_noargs "nonexistent file"     /nonexistent/file
run_noargs "--help flag"          --help
run_noargs "--version flag"       --version

# Error message comparison
echo ""
echo "── Error messages ──"
diff <($GNU --foo 2>&1) <($TOOL --foo 2>&1) > /dev/null 2>&1
if [ $? -eq 0 ]; then echo -e "  ${GREEN}PASS${NC}: unrecognized option msg"; ((PASS++)); else echo -e "  ${RED}FAIL${NC}: unrecognized option msg"; ((FAIL++)); fi

diff <($GNU -x 2>&1) <($TOOL -x 2>&1) > /dev/null 2>&1
if [ $? -eq 0 ]; then echo -e "  ${GREEN}PASS${NC}: invalid short option msg"; ((PASS++)); else echo -e "  ${RED}FAIL${NC}: invalid short option msg"; ((FAIL++)); fi

diff <($GNU -s 2>&1) <($TOOL -s 2>&1) > /dev/null 2>&1
if [ $? -eq 0 ]; then echo -e "  ${GREEN}PASS${NC}: -s missing arg msg"; ((PASS++)); else echo -e "  ${RED}FAIL${NC}: -s missing arg msg"; ((FAIL++)); fi

diff <($GNU --separator 2>&1) <($TOOL --separator 2>&1) > /dev/null 2>&1
if [ $? -eq 0 ]; then echo -e "  ${GREEN}PASS${NC}: --separator missing arg msg"; ((PASS++)); else echo -e "  ${RED}FAIL${NC}: --separator missing arg msg"; ((FAIL++)); fi

# ── SECTION: Stress tests ──
echo ""
echo "── Stress tests ──"
# Large file
diff <($GNU "$TMPDIR/numbers.txt") <($TOOL "$TMPDIR/numbers.txt") > /dev/null 2>&1
if [ $? -eq 0 ]; then echo -e "  ${GREEN}PASS${NC}: 10K lines file"; ((PASS++)); else echo -e "  ${RED}FAIL${NC}: 10K lines file"; ((FAIL++)); fi

# Broken pipe
$TOOL "$TMPDIR/numbers.txt" 2>/dev/null | head -1 > /dev/null 2>&1
if [ $? -eq 0 ]; then echo -e "  ${GREEN}PASS${NC}: broken pipe"; ((PASS++)); else echo -e "  ${RED}FAIL${NC}: broken pipe"; ((FAIL++)); fi

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
