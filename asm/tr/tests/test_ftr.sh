#!/bin/bash
# Comprehensive GNU compatibility test suite for ftr (assembly tr)
set -uo pipefail

TOOL="${TOOL:-./ftr}"
GNU="tr"
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
        ERRORS+="    GNU: $(echo -n "$gnu_out" | od -A x -t x1z 2>/dev/null | head -3)\n"
        ERRORS+="    OUR: $(echo -n "$our_out" | od -A x -t x1z 2>/dev/null | head -3)\n"
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

    local gnu_out gnu_err gnu_exit=0
    gnu_out=$(echo -n "$input" | $GNU "${args[@]}" 2>/tmp/gnu_err) || gnu_exit=$?
    gnu_err=$(cat /tmp/gnu_err)

    local our_out our_err our_exit=0
    our_out=$(echo -n "$input" | $TOOL "${args[@]}" 2>/tmp/our_err) || our_exit=$?
    our_err=$(cat /tmp/our_err)

    compare "$test_name" "$gnu_out" "$gnu_err" "$gnu_exit" "$our_out" "$our_err" "$our_exit"
}

run_test_noargs() {
    local test_name="$1"
    shift
    local args=("$@")

    local gnu_out gnu_err gnu_exit=0
    gnu_out=$($GNU "${args[@]}" </dev/null 2>/tmp/gnu_err) || gnu_exit=$?
    gnu_err=$(cat /tmp/gnu_err)

    local our_out our_err our_exit=0
    our_out=$($TOOL "${args[@]}" </dev/null 2>/tmp/our_err) || our_exit=$?
    our_err=$(cat /tmp/our_err)

    compare "$test_name" "$gnu_out" "$gnu_err" "$gnu_exit" "$our_out" "$our_err" "$our_exit"
}

# Compare stderr output too
run_test_stderr() {
    local test_name="$1"
    shift

    local gnu_err gnu_exit=0
    if [ $# -eq 0 ]; then
        $GNU </dev/null >/dev/null 2>/tmp/gnu_err || gnu_exit=$?
    else
        $GNU "$@" </dev/null >/dev/null 2>/tmp/gnu_err || gnu_exit=$?
    fi
    gnu_err=$(cat /tmp/gnu_err)

    local our_err our_exit=0
    if [ $# -eq 0 ]; then
        $TOOL </dev/null >/dev/null 2>/tmp/our_err || our_exit=$?
    else
        $TOOL "$@" </dev/null >/dev/null 2>/tmp/our_err || our_exit=$?
    fi
    our_err=$(cat /tmp/our_err)

    local failed=0
    if [ "$gnu_exit" != "$our_exit" ]; then
        failed=1
        ERRORS+="  EXIT CODE MISMATCH: $test_name (GNU=$gnu_exit, OURS=$our_exit)\n"
    fi
    if [ "$gnu_err" != "$our_err" ]; then
        failed=1
        ERRORS+="  STDERR MISMATCH: $test_name\n"
        ERRORS+="    GNU: $gnu_err\n"
        ERRORS+="    OUR: $our_err\n"
    fi
    if [ "$failed" -eq 0 ]; then
        echo -e "  ${GREEN}PASS${NC}: $test_name"
        ((PASS++))
    else
        echo -e "  ${RED}FAIL${NC}: $test_name"
        ((FAIL++))
    fi
}

echo ""
echo "============================================"
echo " GNU Compatibility Tests: ftr"
echo "============================================"
echo ""

# ── SECTION: Basic translate ──
echo "── Basic translate ──"
run_test "lowercase to uppercase"      "hello world"       'a-z' 'A-Z'
run_test "uppercase to lowercase"      "HELLO WORLD"       'A-Z' 'a-z'
run_test "single char translate"       "aaa"               'a' 'b'
run_test "multi-char translate"        "abcdef"            'abc' 'xyz'
run_test "digit translate"             "abc123def"         '0-9' 'XXXXXXXXXX'
run_test "mixed range translate"       "Hello World 123"   'A-Za-z' 'a-zA-Z'
run_test "identity translate"          "hello"             'a-z' 'a-z'
run_test "set2 shorter than set1"      "abcde"             'a-e' 'xy'
run_test "set2 last char extends"      "abcde"             'abcde' 'x'

# ── SECTION: Escape sequences ──
echo ""
echo "── Escape sequences ──"
run_test "tab to space"                "$(printf 'a\tb')"  '\t' ' '
run_test "newline to space"            "$(printf 'a\nb')"  '\n' ' '
run_test "backslash escape"            'a\b'               '\\' 'X'
run_test "octal escape \\101=A"        "ABC"               '\101' 'X'
run_test "octal range \\141-\\172"     "hello"             '\141-\172' '\101-\132'
run_test "bell escape"                 "$(printf '\a')"    '\a' 'X'
run_test "carriage return"             "$(printf 'a\rb')"  '\r' ' '
run_test "form feed"                   "$(printf 'a\fb')"  '\f' ' '
run_test "vertical tab"               "$(printf 'a\vb')"  '\v' ' '

# ── SECTION: Character classes ──
echo ""
echo "── Character classes ──"
run_test "[:upper:] to [:lower:]"      "HELLO World"       '[:upper:]' '[:lower:]'
run_test "[:lower:] to [:upper:]"      "hello World"       '[:lower:]' '[:upper:]'
run_test "[:digit:] translate"         "abc123def"         '[:digit:]' 'X'
run_test "[:alpha:] translate"         "abc 123 DEF"       '[:alpha:]' '_'
run_test "[:space:] to space"          "$(printf 'a\t\nb')" '[:space:]' ' '
run_test "[:alnum:] translate"         "abc!123@"          '[:alnum:]' '_'
run_test "[:punct:] translate"         "a!b@c#d"           '[:punct:]' '_'

# ── SECTION: Delete mode ──
echo ""
echo "── Delete mode ──"
run_test "delete chars"                "hello world"       -d 'lo'
run_test "delete digits"               "abc123def"         -d '0-9'
run_test "delete newlines"             "$(printf 'a\nb\nc')" -d '\n'
run_test "delete class [:alpha:]"      "abc 123 DEF"       -d '[:alpha:]'
run_test "delete class [:digit:]"      "abc123def456"      -d '[:digit:]'
run_test "delete class [:space:]"      "hello world foo"   -d '[:space:]'

# ── SECTION: Complement ──
echo ""
echo "── Complement ──"
run_test "complement delete -cd"       "hello123world"     -cd '0-9'
run_test "complement delete alpha"     "abc!123@DEF"       -cd '[:alpha:]'
run_test "complement translate -c"     "hello123"          -c '[:alpha:]' '_'
run_test "complement + newline"        "$(printf 'hello\n123')" -cd "0-9\n"

# ── SECTION: Squeeze mode ──
echo ""
echo "── Squeeze mode ──"
run_test "squeeze basic"               "aaabbbccc"         -s 'abc'
run_test "squeeze spaces"              "a   b   c"         -s ' '
run_test "squeeze all lower"           "aabbccdd"          -s 'a-z'
run_test "squeeze no effect"           "abcdef"            -s 'abc'
run_test "squeeze class [:space:]"     "$(printf 'a  \t\t b')" -s '[:space:]'
run_test "squeeze single set"          "xxxyyyzzz"         -s 'xyz'

# ── SECTION: Translate + Squeeze ──
echo ""
echo "── Translate + Squeeze ──"
run_test "translate + squeeze"         "aabbcc"            -s 'abc' 'xyz'
run_test "tr+sq upper to lower"        "AABBCC xx"         -s 'A-Z' 'a-z'
run_test "tr+sq spaces"                "a   b"             -s ' ' '_'

# ── SECTION: Delete + Squeeze ──
echo ""
echo "── Delete + Squeeze ──"
run_test "delete + squeeze"            "aabbbccc 123"      -ds 'abc' ' '
run_test "ds complement"               "hello world 123"   -cds '[:alpha:]' ' '

# ── SECTION: Truncate ──
echo ""
echo "── Truncate flag ──"
run_test "truncate set1"               "abcde"             -t 'abcde' 'xy'
run_test "truncate no effect"          "ab"                -t 'ab' 'xy'

# ── SECTION: Edge cases ──
echo ""
echo "── Edge cases ──"
run_test "empty input"                 ""                  'a-z' 'A-Z'
run_test "single byte"                 "a"                 'a' 'b'
run_test "no trailing newline"         "hello"             'h' 'H'
run_test "all same chars"              "aaaaaaa"           'a' 'z'
run_test "newline-only input"          "$(printf '\n\n\n')" 'a-z' 'A-Z'
run_test "literal dash at end"         "a-b"               'a-' 'XY'
run_test "complement squeeze -cs"      "aaabbbccc"         -cs 'a' 'X'

# ── SECTION: Repeat constructs ──
echo ""
echo "── Repeat constructs ──"
run_test "[c*n] repeat"                "abcde"             'abcde' '[x*3]yz'
run_test "[c*] fill"                   "abcde"             'abcde' '[x*]'
run_test "[c*0] as fill"              "abcde"             'abcde' '[x*0]'

# ── SECTION: Equivalence classes ──
echo ""
echo "── Equivalence classes ──"
run_test "[=a=] equivalence"           "aAbBcC"            '[=a=]' 'X'

# ── SECTION: -- end of options ──
echo ""
echo "── End of options (--) ──"
run_test "-- with sets"                "hello"             -- 'h' 'H'

# ── SECTION: Error handling ──
echo ""
echo "── Error handling ──"
# run_test_stderr passes args to BOTH $GNU and $TOOL
# Do NOT include the command name as first arg
run_test_stderr "missing operand"
run_test_stderr "missing SET2 translate"         'a'
run_test_stderr "delete extra operand"           -d 'a' 'b'
run_test_stderr "extra operand translate"        'a' 'b' 'c'
run_test_stderr "extra operand squeeze"          -s 'a' 'b' 'c'
run_test_stderr "extra operand ds"               -ds 'a' 'b' 'c'
run_test_stderr "invalid option -z"              -z 'a'
run_test_stderr "unrecognized --bogus"           --bogus 'a'
run_test_stderr "delete+squeeze missing SET2"    -ds 'a'
run_test_stderr "reversed range"                 'z-a' 'x'

# ── SECTION: --help and --version ──
echo ""
echo "── Help/Version ──"
# Just check exit code for help (output will differ between GNU and ours)
our_help_exit=0
$TOOL --help >/dev/null 2>&1 || our_help_exit=$?
if [ "$our_help_exit" -eq 0 ]; then
    echo -e "  ${GREEN}PASS${NC}: --help exits 0"
    ((PASS++))
else
    echo -e "  ${RED}FAIL${NC}: --help exits $our_help_exit (expected 0)"
    ((FAIL++))
fi

our_ver_exit=0
$TOOL --version >/dev/null 2>&1 || our_ver_exit=$?
if [ "$our_ver_exit" -eq 0 ]; then
    echo -e "  ${GREEN}PASS${NC}: --version exits 0"
    ((PASS++))
else
    echo -e "  ${RED}FAIL${NC}: --version exits $our_ver_exit (expected 0)"
    ((FAIL++))
fi

# ── SECTION: Large input ──
echo ""
echo "── Large input ──"
# Generate 1MB of random lowercase text
python3 -c "
import random, string
data = ''.join(random.choices(string.ascii_lowercase + ' \n', k=1048576))
print(data, end='')
" > /tmp/ftr_large_input

gnu_large=$(tr 'a-z' 'A-Z' < /tmp/ftr_large_input | md5sum)
our_large=$($TOOL 'a-z' 'A-Z' < /tmp/ftr_large_input | md5sum)
if [ "$gnu_large" = "$our_large" ]; then
    echo -e "  ${GREEN}PASS${NC}: 1MB translate (md5 match)"
    ((PASS++))
else
    echo -e "  ${RED}FAIL${NC}: 1MB translate (md5 mismatch)"
    ERRORS+="  1MB translate: GNU=$gnu_large OUR=$our_large\n"
    ((FAIL++))
fi

gnu_del=$(tr -d 'aeiou' < /tmp/ftr_large_input | md5sum)
our_del=$($TOOL -d 'aeiou' < /tmp/ftr_large_input | md5sum)
if [ "$gnu_del" = "$our_del" ]; then
    echo -e "  ${GREEN}PASS${NC}: 1MB delete (md5 match)"
    ((PASS++))
else
    echo -e "  ${RED}FAIL${NC}: 1MB delete (md5 mismatch)"
    ERRORS+="  1MB delete: GNU=$gnu_del OUR=$our_del\n"
    ((FAIL++))
fi

gnu_sq=$(tr -s ' ' < /tmp/ftr_large_input | md5sum)
our_sq=$($TOOL -s ' ' < /tmp/ftr_large_input | md5sum)
if [ "$gnu_sq" = "$our_sq" ]; then
    echo -e "  ${GREEN}PASS${NC}: 1MB squeeze (md5 match)"
    ((PASS++))
else
    echo -e "  ${RED}FAIL${NC}: 1MB squeeze (md5 mismatch)"
    ERRORS+="  1MB squeeze: GNU=$gnu_sq OUR=$our_sq\n"
    ((FAIL++))
fi

# ── SECTION: Broken pipe ──
echo ""
echo "── Broken pipe ──"
yes "hello world" | head -1000 | $TOOL 'a-z' 'A-Z' | head -1 > /dev/null 2>&1
bp_exit=$?
if [ "$bp_exit" -eq 0 ] || [ "$bp_exit" -eq 141 ]; then
    echo -e "  ${GREEN}PASS${NC}: broken pipe handled (exit $bp_exit)"
    ((PASS++))
else
    echo -e "  ${RED}FAIL${NC}: broken pipe exit $bp_exit"
    ((FAIL++))
fi

# Cleanup
rm -f /tmp/ftr_large_input /tmp/gnu_err /tmp/our_err

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
