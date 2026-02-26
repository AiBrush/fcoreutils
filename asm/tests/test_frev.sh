#!/bin/bash
set -uo pipefail

# Comprehensive GNU compatibility tests for frev
# Compares our assembly frev against GNU rev (util-linux) for text inputs,
# and validates behavior for binary/edge cases separately.

TOOL="${TOOL:-./frev}"
GNU="rev"
PASS=0
FAIL=0
ERRORS=""

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

compare_stdout() {
    local test_name="$1"
    local gnu_out="$2"
    local our_out="$3"
    local failed=0

    if [ "$gnu_out" != "$our_out" ]; then
        failed=1
        ERRORS+="  STDOUT MISMATCH: $test_name\n"
        ERRORS+="    GNU (${#gnu_out} bytes): $(echo -n "$gnu_out" | od -A n -t x1 | head -3)\n"
        ERRORS+="    OUR (${#our_out} bytes): $(echo -n "$our_out" | od -A n -t x1 | head -3)\n"
    fi

    if [ "$failed" -eq 0 ]; then
        echo -e "  ${GREEN}PASS${NC}: $test_name"
        ((PASS++))
    else
        echo -e "  ${RED}FAIL${NC}: $test_name"
        ((FAIL++))
    fi
}

# Compare stdin-based test (pipe input to both)
run_stdin_test() {
    local test_name="$1"
    local input="$2"

    local gnu_out our_out
    gnu_out=$(printf '%s' "$input" | timeout 2 $GNU 2>/dev/null) || true
    our_out=$(printf '%s' "$input" | $TOOL 2>/dev/null) || true
    compare_stdout "$test_name" "$gnu_out" "$our_out"
}

# Compare file-based test
run_file_test() {
    local test_name="$1"
    local file="$2"

    local gnu_out our_out
    gnu_out=$(timeout 2 $GNU "$file" 2>/dev/null) || true
    our_out=$($TOOL "$file" 2>/dev/null) || true
    compare_stdout "$test_name" "$gnu_out" "$our_out"
}

# Test that only checks our tool's output (for cases where GNU hangs)
check_exact() {
    local test_name="$1"
    local input="$2"
    local expected="$3"

    local our_out
    our_out=$(printf '%s' "$input" | $TOOL 2>/dev/null) || true

    if [ "$our_out" = "$expected" ]; then
        echo -e "  ${GREEN}PASS${NC}: $test_name"
        ((PASS++))
    else
        echo -e "  ${RED}FAIL${NC}: $test_name"
        ERRORS+="  OUTPUT MISMATCH: $test_name\n"
        ERRORS+="    Expected: $(echo -n "$expected" | od -A n -t x1 | head -3)\n"
        ERRORS+="    Got:      $(echo -n "$our_out" | od -A n -t x1 | head -3)\n"
        ((FAIL++))
    fi
}

# Test exit code
check_exit() {
    local test_name="$1"
    local expected_exit="$2"
    shift 2
    local args=("$@")

    $TOOL "${args[@]}" > /dev/null 2>/dev/null
    local actual_exit=$?

    if [ "$actual_exit" -eq "$expected_exit" ]; then
        echo -e "  ${GREEN}PASS${NC}: $test_name (exit=$actual_exit)"
        ((PASS++))
    else
        echo -e "  ${RED}FAIL${NC}: $test_name (expected exit=$expected_exit, got=$actual_exit)"
        ((FAIL++))
    fi
}

# Test stderr output exists
check_stderr() {
    local test_name="$1"
    local expected_pattern="$2"
    shift 2
    local args=("$@")

    local stderr_out
    stderr_out=$($TOOL "${args[@]}" 2>&1 >/dev/null) || true

    if echo "$stderr_out" | grep -q "$expected_pattern"; then
        echo -e "  ${GREEN}PASS${NC}: $test_name"
        ((PASS++))
    else
        echo -e "  ${RED}FAIL${NC}: $test_name"
        ERRORS+="  STDERR MISMATCH: $test_name\n"
        ERRORS+="    Expected pattern: $expected_pattern\n"
        ERRORS+="    Got: $stderr_out\n"
        ((FAIL++))
    fi
}

echo ""
echo "============================================"
echo " GNU Compatibility Tests: frev"
echo "============================================"
echo ""

# ── Create test fixtures ──
TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT

echo "hello world" > "$TMPDIR/simple.txt"
echo -e "line1\nline2\nline3" > "$TMPDIR/multi.txt"
printf "foo\tbar\tbaz\n" > "$TMPDIR/tabs.txt"
touch "$TMPDIR/empty.txt"
echo -e "a\nb\nc\nd\ne" > "$TMPDIR/five.txt"
seq 1 10000 > "$TMPDIR/numbers.txt"
printf '\x00\x01\x02\x03\n' > "$TMPDIR/nullbytes.txt"
echo -e "  leading spaces" > "$TMPDIR/spaces.txt"
printf 'no trailing newline' > "$TMPDIR/nonewline.txt"
python3 -c "print('a'*100000)" > "$TMPDIR/longline.txt"
echo -e "a\n\nb\n" > "$TMPDIR/emptylines.txt"
printf "single" > "$TMPDIR/single_nolf.txt"
echo "" > "$TMPDIR/just_newline.txt"
echo -e "\n\n\n" > "$TMPDIR/only_newlines.txt"
printf "abc\ndef\n" > "$TMPDIR/basic.txt"
# File with varied line lengths
python3 -c "
for i in range(1, 101):
    print('x' * i)
" > "$TMPDIR/varied.txt"

# ── SECTION: Basic functionality ──
echo "── Basic functionality ──"
run_stdin_test "simple string"          "hello world
"
run_stdin_test "abc"                    "abc
"
run_stdin_test "multiple lines"         "line1
line2
line3
"
run_stdin_test "single char lines"      "a
b
c
"
run_stdin_test "tabs in line"           "$(printf 'foo\tbar\tbaz\n')"
run_stdin_test "spaces in line"         "  hello  world
"
run_stdin_test "numbers"                "12345
67890
"

# ── File input ──
echo ""
echo "── File input ──"
run_file_test "simple file"             "$TMPDIR/simple.txt"
run_file_test "multi-line file"         "$TMPDIR/multi.txt"
run_file_test "tabs file"               "$TMPDIR/tabs.txt"
run_file_test "numbers file"            "$TMPDIR/numbers.txt"
run_file_test "varied line lengths"     "$TMPDIR/varied.txt"
run_file_test "/etc/passwd"             "/etc/passwd"

# ── Edge cases ──
echo ""
echo "── Edge cases ──"
run_file_test "empty file"              "$TMPDIR/empty.txt"
run_file_test "null bytes"              "$TMPDIR/nullbytes.txt"
run_file_test "very long line (100K)"   "$TMPDIR/longline.txt"
run_file_test "empty lines"             "$TMPDIR/emptylines.txt"
run_file_test "just a newline"          "$TMPDIR/just_newline.txt"
run_file_test "only newlines"           "$TMPDIR/only_newlines.txt"

# No trailing newline (must not add one)
echo -n "no newline" | $TOOL > "$TMPDIR/our_nonl.out" 2>/dev/null
echo -n "no newline" | $GNU > "$TMPDIR/gnu_nonl.out" 2>/dev/null
if cmp -s "$TMPDIR/our_nonl.out" "$TMPDIR/gnu_nonl.out"; then
    echo -e "  ${GREEN}PASS${NC}: no trailing newline preserved"
    ((PASS++))
else
    echo -e "  ${RED}FAIL${NC}: no trailing newline preserved"
    ((FAIL++))
fi

# Single char no newline
check_exact "single char no newline" "x" "x"

# Binary-safe (our tool handles this; GNU rev may hang)
check_exact "binary reversal" "$(printf '\x01\x02\x03\n')" "$(printf '\x03\x02\x01\n')"
check_exact "null byte reversal" "$(printf '\x00\x41\x42\n')" "$(printf '\x42\x41\x00\n')"

# ── Multiple files ──
echo ""
echo "── Multiple files ──"
echo "file1" > "$TMPDIR/f1.txt"
echo "file2" > "$TMPDIR/f2.txt"
echo "file3" > "$TMPDIR/f3.txt"

gnu_multi=$(timeout 2 $GNU "$TMPDIR/f1.txt" "$TMPDIR/f2.txt" "$TMPDIR/f3.txt" 2>/dev/null) || true
our_multi=$($TOOL "$TMPDIR/f1.txt" "$TMPDIR/f2.txt" "$TMPDIR/f3.txt" 2>/dev/null) || true
compare_stdout "three files" "$gnu_multi" "$our_multi"

# Multiple files with error (nonexistent mixed with valid)
$TOOL "$TMPDIR/f1.txt" /nonexistent "$TMPDIR/f2.txt" > "$TMPDIR/mixed_out.txt" 2>/dev/null
mixed_exit=$?
mixed_out=$(cat "$TMPDIR/mixed_out.txt")
if [ "$mixed_exit" -eq 1 ] && [ "$mixed_out" = "$(printf '1elif\n2elif')" ]; then
    echo -e "  ${GREEN}PASS${NC}: mixed valid/invalid files"
    ((PASS++))
else
    echo -e "  ${RED}FAIL${NC}: mixed valid/invalid files (exit=$mixed_exit)"
    ((FAIL++))
fi

# ── Stdin via - ──
echo ""
echo "── Stdin via - ──"
stdin_out=$(echo "dash test" | $TOOL - 2>/dev/null)
if [ "$stdin_out" = "tset hsad" ]; then
    echo -e "  ${GREEN}PASS${NC}: - reads stdin"
    ((PASS++))
else
    echo -e "  ${RED}FAIL${NC}: - reads stdin (got: $stdin_out)"
    ((FAIL++))
fi

# ── Option parsing ──
echo ""
echo "── Option parsing ──"

# --help
help_out=$($TOOL --help 2>/dev/null)
help_exit=$?
if [ "$help_exit" -eq 0 ] && echo "$help_out" | grep -q "Usage:"; then
    echo -e "  ${GREEN}PASS${NC}: --help prints usage and exits 0"
    ((PASS++))
else
    echo -e "  ${RED}FAIL${NC}: --help (exit=$help_exit)"
    ((FAIL++))
fi

# --version
ver_out=$($TOOL --version 2>/dev/null)
ver_exit=$?
if [ "$ver_exit" -eq 0 ] && echo "$ver_out" | grep -q "fcoreutils"; then
    echo -e "  ${GREEN}PASS${NC}: --version prints version and exits 0"
    ((PASS++))
else
    echo -e "  ${RED}FAIL${NC}: --version (exit=$ver_exit)"
    ((FAIL++))
fi

# Unknown long option
check_exit "unknown long option exits 1" 1 --foobar
check_stderr "unknown long option stderr" "unrecognized option" --foobar
check_stderr "unknown long option try help" "Try 'rev --help'" --foobar

# Unknown short option
check_exit "unknown short option exits 1" 1 -z
check_stderr "unknown short option stderr" "invalid option" -z
check_stderr "unknown short option try help" "Try 'rev --help'" -z

# -h (help)
h_out=$($TOOL -h 2>/dev/null)
h_exit=$?
if [ "$h_exit" -eq 0 ] && echo "$h_out" | grep -q "Usage:"; then
    echo -e "  ${GREEN}PASS${NC}: -h prints usage and exits 0"
    ((PASS++))
else
    echo -e "  ${RED}FAIL${NC}: -h (exit=$h_exit)"
    ((FAIL++))
fi

# -V (version)
V_out=$($TOOL -V 2>/dev/null)
V_exit=$?
if [ "$V_exit" -eq 0 ] && echo "$V_out" | grep -q "fcoreutils"; then
    echo -e "  ${GREEN}PASS${NC}: -V prints version and exits 0"
    ((PASS++))
else
    echo -e "  ${RED}FAIL${NC}: -V (exit=$V_exit)"
    ((FAIL++))
fi

# -- end of options
echo "after dash" > "$TMPDIR/dashdash.txt"
dd_out=$($TOOL -- "$TMPDIR/dashdash.txt" 2>/dev/null)
if [ "$dd_out" = "hsad retfa" ]; then
    echo -e "  ${GREEN}PASS${NC}: -- ends option parsing"
    ((PASS++))
else
    echo -e "  ${RED}FAIL${NC}: -- ends option parsing (got: $dd_out)"
    ((FAIL++))
fi

# -- alone reads stdin (no file operands after --)
dd_stdin_out=$(echo "hello" | $TOOL -- 2>/dev/null)
if [ "$dd_stdin_out" = "olleh" ]; then
    echo -e "  ${GREEN}PASS${NC}: -- alone reads stdin"
    ((PASS++))
else
    echo -e "  ${RED}FAIL${NC}: -- alone reads stdin (got: $dd_stdin_out)"
    ((FAIL++))
fi

# ── Error handling ──
echo ""
echo "── Error handling ──"
check_exit "nonexistent file exits 1" 1 /nonexistent/file
check_stderr "nonexistent file stderr" "No such file or directory" /nonexistent/file
check_stderr "nonexistent file 'cannot open'" "cannot open" /nonexistent/file

# /dev/null (empty input via file)
devnull_out=$($TOOL /dev/null 2>/dev/null)
devnull_exit=$?
if [ "$devnull_exit" -eq 0 ] && [ -z "$devnull_out" ]; then
    echo -e "  ${GREEN}PASS${NC}: /dev/null produces no output"
    ((PASS++))
else
    echo -e "  ${RED}FAIL${NC}: /dev/null (exit=$devnull_exit, output='$devnull_out')"
    ((FAIL++))
fi

# ── SIGPIPE / broken pipe ──
echo ""
echo "── SIGPIPE handling ──"
python3 -c "
for i in range(100000):
    print('a' * 100)
" > "$TMPDIR/big.txt"

$TOOL "$TMPDIR/big.txt" | head -1 > /dev/null 2>&1
pipe_exit=$?
# Should exit 0 or 141 (killed by SIGPIPE), not crash
if [ "$pipe_exit" -eq 0 ] || [ "$pipe_exit" -eq 141 ]; then
    echo -e "  ${GREEN}PASS${NC}: broken pipe handled (exit=$pipe_exit)"
    ((PASS++))
else
    echo -e "  ${RED}FAIL${NC}: broken pipe (exit=$pipe_exit)"
    ((FAIL++))
fi

# ── Large data correctness ──
echo ""
echo "── Large data ──"
python3 -c "
import random, string
random.seed(42)
for _ in range(100000):
    print(''.join(random.choices(string.ascii_letters + string.digits, k=random.randint(1,200))))
" > "$TMPDIR/large.txt"

gnu_large=$(timeout 10 $GNU "$TMPDIR/large.txt" 2>/dev/null | md5sum)
our_large=$($TOOL "$TMPDIR/large.txt" 2>/dev/null | md5sum)
if [ "$gnu_large" = "$our_large" ]; then
    echo -e "  ${GREEN}PASS${NC}: large file (100K lines) matches GNU"
    ((PASS++))
else
    echo -e "  ${RED}FAIL${NC}: large file mismatch"
    ERRORS+="  GNU md5: $gnu_large\n  OUR md5: $our_large\n"
    ((FAIL++))
fi

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
