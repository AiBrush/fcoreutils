#!/bin/bash
set -uo pipefail

TOOL="${TOOL:-./fmd5sum}"
GNU="md5sum"
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
        ERRORS+="    GNU: $(echo -n "$gnu_out" | head -c 200)\n"
        ERRORS+="    OUR: $(echo -n "$our_out" | head -c 200)\n"
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

run_test_stdin() {
    local test_name="$1"
    local input="$2"
    shift 2
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
echo " GNU Compatibility Tests: fmd5sum"
echo "============================================"
echo ""

# Create test fixtures
TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT

echo -n "hello world" > "$TMPDIR/simple.txt"
echo -e "line1\nline2\nline3" > "$TMPDIR/multi.txt"
dd if=/dev/urandom bs=1024 count=64 of="$TMPDIR/binary.bin" 2>/dev/null
python3 -c "print('a'*100000)" > "$TMPDIR/longline.txt"
touch "$TMPDIR/empty.txt"
seq 1 10000 > "$TMPDIR/numbers.txt"
printf '\x00\x01\x02\x03\n' > "$TMPDIR/nullbytes.txt"
echo -n "no trailing newline" > "$TMPDIR/nonewline.txt"
echo "test" > "$TMPDIR/test.txt"

# ── Basic functionality ──
echo "── Basic functionality ──"
run_test_stdin "stdin with newline"   "test
"
run_test_stdin "stdin no newline"     "test"
run_test_stdin "empty stdin"          ""
run_test_stdin "binary data"          "$(printf '\x00\x01\x02\x03')"
run_test_file  "simple file"          "$TMPDIR/simple.txt"
run_test_file  "multi-line file"      "$TMPDIR/multi.txt"
run_test_file  "binary file"          "$TMPDIR/binary.bin"
run_test_file  "empty file"           "$TMPDIR/empty.txt"
run_test_file  "null bytes"           "$TMPDIR/nullbytes.txt"
run_test_file  "long line"            "$TMPDIR/longline.txt"
run_test_file  "no trailing newline"  "$TMPDIR/nonewline.txt"
run_test_file  "large file"           "$TMPDIR/numbers.txt"
run_test_file  "/dev/null"            "/dev/null"

# ── Multiple files ──
echo ""
echo "── Multiple files ──"
run_test_files "two files"            "$TMPDIR/simple.txt" "$TMPDIR/multi.txt"
run_test_files "three files"          "$TMPDIR/simple.txt" "$TMPDIR/multi.txt" "$TMPDIR/empty.txt"
run_test_files "mixed exist/noexist"  "$TMPDIR/simple.txt" "/nonexistent"

# ── Flags ──
echo ""
echo "── Flags ──"
run_test_stdin "binary flag -b"       "test
" -b
run_test_stdin "text flag -t"         "test
" -t
run_test_stdin "tag format"           "test
" --tag
run_test_file  "tag format file"      "$TMPDIR/test.txt" --tag
run_test_file  "binary flag file"     "$TMPDIR/test.txt" -b
run_test_file  "text flag file"       "$TMPDIR/test.txt" -t

# ── Zero flag (compare raw bytes) ──
echo ""
echo "── Zero flag ──"
gnu_z=$(echo "test" | $GNU -z | od -c)
our_z=$(echo "test" | $TOOL -z | od -c)
if [ "$gnu_z" = "$our_z" ]; then
    echo -e "  ${GREEN}PASS${NC}: -z flag (NUL terminator)"
    ((PASS++))
else
    echo -e "  ${RED}FAIL${NC}: -z flag (NUL terminator)"
    ((FAIL++))
    ERRORS+="  -z FLAG: output differs\n"
fi

# ── Explicit stdin ──
echo ""
echo "── Explicit stdin ──"
run_test_stdin "dash stdin"           "test
" -

# ── Error handling ──
echo ""
echo "── Error handling ──"
run_test_files "nonexistent file"     /nonexistent/file
run_test_files "unrecognized option"  --unknown
run_test_files "invalid short opt"    -x

# ── Check mode ──
echo ""
echo "── Check mode ──"

# Create valid checksum file
$GNU "$TMPDIR/test.txt" > "$TMPDIR/checkfile.txt"

run_test_files "check correct"        -c "$TMPDIR/checkfile.txt"

# Wrong hash
echo "00000000000000000000000000000000  $TMPDIR/test.txt" > "$TMPDIR/bad_check.txt"
run_test_files "check wrong hash"     -c "$TMPDIR/bad_check.txt"

# Quiet check
run_test_files "check quiet ok"       -c --quiet "$TMPDIR/checkfile.txt"
run_test_files "check quiet fail"     -c --quiet "$TMPDIR/bad_check.txt"

# Status check
run_test_files "check status ok"      -c --status "$TMPDIR/checkfile.txt"
run_test_files "check status fail"    -c --status "$TMPDIR/bad_check.txt"

# Invalid format
echo "this is not a checksum" > "$TMPDIR/invalid_check.txt"
run_test_files "check invalid format" -c "$TMPDIR/invalid_check.txt"

# Warn
run_test_files "check warn"           -c -w "$TMPDIR/invalid_check.txt"

# BSD format
echo "MD5 ($TMPDIR/test.txt) = d8e8fca2dc0f896fd7cb4cb0031ba249" > "$TMPDIR/bsd_check.txt"
run_test_files "check BSD format"     -c "$TMPDIR/bsd_check.txt"

# Tag + check conflict
run_test_files "tag+check conflict"   --tag -c "$TMPDIR/checkfile.txt"

# ignore-missing
echo "d8e8fca2dc0f896fd7cb4cb0031ba249  /nonexistent_file_12345" > "$TMPDIR/missing_check.txt"
run_test_files "check ignore-missing" -c --ignore-missing "$TMPDIR/missing_check.txt"

# ── Double dash ──
echo ""
echo "── Double dash ──"
echo "test" > "$TMPDIR/--test.txt"
run_test_files "double dash file"     -- "$TMPDIR/--test.txt"

# ── Large file correctness ──
echo ""
echo "── Large file correctness ──"
dd if=/dev/urandom bs=1M count=10 of="$TMPDIR/large.bin" 2>/dev/null
gnu_hash=$($GNU "$TMPDIR/large.bin")
our_hash=$($TOOL "$TMPDIR/large.bin")
if [ "$gnu_hash" = "$our_hash" ]; then
    echo -e "  ${GREEN}PASS${NC}: 10MB file"
    ((PASS++))
else
    echo -e "  ${RED}FAIL${NC}: 10MB file"
    ((FAIL++))
    ERRORS+="  10MB FILE: GNU=$gnu_hash, OUR=$our_hash\n"
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
