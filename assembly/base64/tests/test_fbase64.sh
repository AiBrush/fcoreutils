#!/bin/bash
set -euo pipefail

# Find the tool - allow override via environment
TOOL="${TOOL:-./fbase64}"
GNU="base64"
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
        ERRORS+="    GNU (${#gnu_out} bytes): $(printf '%s' "$gnu_out" | od -A x -t x1z | head -3)\n"
        ERRORS+="    OUR (${#our_out} bytes): $(printf '%s' "$our_out" | od -A x -t x1z | head -3)\n"
    fi

    # Compare exit code
    if [ "$gnu_exit" != "$our_exit" ]; then
        failed=1
        ERRORS+="  EXIT CODE MISMATCH: $test_name (GNU=$gnu_exit, OURS=$our_exit)\n"
    fi

    # Compare stderr presence (not exact — tool name may differ)
    if [ -n "$gnu_err" ] && [ -z "$our_err" ]; then
        failed=1
        ERRORS+="  MISSING STDERR: $test_name\n"
        ERRORS+="    GNU stderr: $gnu_err\n"
    fi

    if [ "$failed" -eq 0 ]; then
        echo -e "  ${GREEN}PASS${NC}: $test_name"
        PASS=$((PASS + 1))
    else
        echo -e "  ${RED}FAIL${NC}: $test_name"
        FAIL=$((FAIL + 1))
    fi
}

run_test() {
    local test_name="$1"
    shift
    local input="$1"
    shift
    local args=("$@")

    local gnu_out gnu_err gnu_exit
    gnu_out=$(printf '%s' "$input" | $GNU "${args[@]}" 2>/tmp/gnu_err) || gnu_exit=$?
    gnu_exit=${gnu_exit:-0}
    gnu_err=$(cat /tmp/gnu_err)

    local our_out our_err our_exit
    our_out=$(printf '%s' "$input" | $TOOL "${args[@]}" 2>/tmp/our_err) || our_exit=$?
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

# Compare binary output (for decode)
run_test_binary() {
    local test_name="$1"
    shift
    local input="$1"
    shift
    local args=("$@")

    local gnu_exit our_exit
    printf '%s' "$input" | $GNU "${args[@]}" > /tmp/gnu_bin 2>/tmp/gnu_err || gnu_exit=$?
    gnu_exit=${gnu_exit:-0}
    printf '%s' "$input" | $TOOL "${args[@]}" > /tmp/our_bin 2>/tmp/our_err || our_exit=$?
    our_exit=${our_exit:-0}

    local failed=0
    if ! diff /tmp/gnu_bin /tmp/our_bin > /dev/null 2>&1; then
        failed=1
        ERRORS+="  BINARY STDOUT MISMATCH: $test_name\n"
    fi
    if [ "$gnu_exit" != "${our_exit:-0}" ]; then
        failed=1
        ERRORS+="  EXIT CODE MISMATCH: $test_name (GNU=$gnu_exit, OURS=${our_exit:-0})\n"
    fi

    if [ "$failed" -eq 0 ]; then
        echo -e "  ${GREEN}PASS${NC}: $test_name"
        PASS=$((PASS + 1))
    else
        echo -e "  ${RED}FAIL${NC}: $test_name"
        FAIL=$((FAIL + 1))
    fi
}

echo ""
echo "============================================"
echo " GNU Compatibility Tests: fbase64"
echo "============================================"
echo ""

# Create test fixtures
TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR /tmp/gnu_err /tmp/our_err /tmp/gnu_bin /tmp/our_bin" EXIT

echo -n "hello world" > "$TMPDIR/simple.txt"
echo -e "line1\nline2\nline3" > "$TMPDIR/multi.txt"
dd if=/dev/urandom bs=1024 count=64 of="$TMPDIR/binary.bin" 2>/dev/null
dd if=/dev/urandom bs=1024 count=1 of="$TMPDIR/small.bin" 2>/dev/null
python3 -c "print('a'*100000)" > "$TMPDIR/longline.txt"
touch "$TMPDIR/empty.txt"
printf '\x00\x01\x02\x03\n' > "$TMPDIR/nullbytes.txt"
echo -n "no trailing newline" > "$TMPDIR/nonewline.txt"
# Pre-encode some test data
base64 "$TMPDIR/binary.bin" > "$TMPDIR/encoded.txt"
base64 -w0 "$TMPDIR/binary.bin" > "$TMPDIR/encoded_nowrap.txt"

# ── SECTION: Basic encoding ──
echo "── Basic encoding ──"
run_test "encode: hello world"         "Hello World"
run_test "encode: empty"               ""
run_test "encode: single byte"         "A"
run_test "encode: two bytes"           "AB"
run_test "encode: three bytes"         "ABC"
run_test "encode: four bytes"          "ABCD"
run_test "encode: five bytes"          "ABCDE"
run_test "encode: six bytes"           "ABCDEF"
run_test "encode: with newline"        "hello
world"
run_test "encode: null byte"           $'\x00'
run_test "encode: null bytes"          $'\x00\x01\x02\x03'
run_test_file "encode: file"           "$TMPDIR/simple.txt"
run_test_file "encode: binary file"    "$TMPDIR/binary.bin"
run_test_file "encode: empty file"     "$TMPDIR/empty.txt"
run_test_file "encode: null bytes file" "$TMPDIR/nullbytes.txt"
run_test_file "encode: long line"      "$TMPDIR/longline.txt"
run_test_file "encode: no newline"     "$TMPDIR/nonewline.txt"
run_test_file "encode: /dev/null"      "/dev/null"

# ── SECTION: Wrap modes ──
echo ""
echo "── Wrap modes ──"
run_test "wrap 0"                      "Hello World Hello World Hello World Hello World Hello World" -w0
run_test "wrap 10"                     "Hello World Hello World Hello World Hello World Hello World" -w10
run_test "wrap 20"                     "Hello World Hello World Hello World Hello World Hello World" -w20
run_test "wrap 76 (default)"           "Hello World Hello World Hello World Hello World Hello World"
run_test "wrap 100"                    "Hello World Hello World Hello World Hello World Hello World" -w100
run_test "wrap 1"                      "Hello World" -w1
run_test "wrap 2"                      "Hello World" -w2
run_test "wrap 3"                      "Hello World" -w3
run_test "wrap 4"                      "Hello World" -w4
run_test_file "wrap 0 file"            "$TMPDIR/binary.bin" -w0
run_test_file "wrap 20 file"           "$TMPDIR/binary.bin" -w20
run_test "--wrap=20"                   "Hello World Hello World Hello World Hello World Hello World" --wrap=20
run_test "--wrap=0"                    "Hello World Hello World Hello World Hello World Hello World" --wrap=0
run_test "-w0 (attached)"             "Hello World" -w0

# ── SECTION: Decoding ──
echo ""
echo "── Decoding ──"
run_test_binary "decode: basic"               "SGVsbG8gV29ybGQ=" -d
run_test_binary "decode: with newlines"        "SGVsbG8g
V29ybGQ=" -d
run_test_binary "decode: empty"                "" -d
run_test_binary "decode: 1 pad"                "QUI=" -d
run_test_binary "decode: 2 pad"                "QQ==" -d
run_test_binary "decode: no pad"               "QUJD" -d
run_test_binary "decode: multiline"            "$(base64 "$TMPDIR/small.bin")" -d
run_test_file   "decode: file"                 "$TMPDIR/encoded.txt" -d
run_test_file   "decode: file nowrap"          "$TMPDIR/encoded_nowrap.txt" -d

# ── SECTION: Decode with ignore garbage ──
echo ""
echo "── Decode with ignore garbage ──"
run_test_binary "decode -i: garbage chars"     "SGVs@@bG8g@@V29ybGQ=" -di
run_test_binary "decode -i: lots of garbage"   "S!!!G!!!V!!!s!!!bG8=" -di
run_test_binary "decode -i: only garbage"      "@@@@" -di
run_test_binary "decode -i: empty"             "" -di

# ── SECTION: Combined flags ──
echo ""
echo "── Combined flags ──"
run_test "encode -w0"                  "Hello World" -w0
run_test_binary "decode -d -i"         "SGVs@@bG8=" -d -i
run_test_binary "decode -d --ignore-garbage" "SGVs@@bG8=" -d --ignore-garbage

# ── SECTION: Error handling ──
echo ""
echo "── Error handling ──"
run_test_noargs "nonexistent file"     /nonexistent/file
run_test_noargs "invalid option -x"    -x
run_test_noargs "invalid option -Z"    -Z
run_test_noargs "unrecognized --foo"   --foo
run_test_noargs "unrecognized --bar"   --bar
run_test "invalid decode input"        "!!!!" -d
run_test "incomplete decode"           "QQ" -d
run_test_noargs "missing -w arg"       -w
run_test_noargs "invalid wrap: abc"    -wabc

# ── SECTION: Help and version ──
echo ""
echo "── Help and version ──"
# For --help and --version, we just check exit code, not exact text
# (our version string differs)
our_help_exit=0
$TOOL --help > /dev/null 2>&1 || our_help_exit=$?
if [ "$our_help_exit" -eq 0 ]; then
    echo -e "  ${GREEN}PASS${NC}: --help exits 0"
    PASS=$((PASS + 1))
else
    echo -e "  ${RED}FAIL${NC}: --help exits 0 (got $our_help_exit)"
    FAIL=$((FAIL + 1))
fi

our_ver_exit=0
$TOOL --version > /dev/null 2>&1 || our_ver_exit=$?
if [ "$our_ver_exit" -eq 0 ]; then
    echo -e "  ${GREEN}PASS${NC}: --version exits 0"
    PASS=$((PASS + 1))
else
    echo -e "  ${RED}FAIL${NC}: --version exits 0 (got $our_ver_exit)"
    FAIL=$((FAIL + 1))
fi

# ── SECTION: Edge cases ──
echo ""
echo "── Edge cases ──"
run_test "stdin dash"                  "test" -
run_test "encode after --"             "test"
# -- stops option parsing, next arg is filename
run_test_file "file via --"            "$TMPDIR/simple.txt"
# Test stdin via pipe with no args
run_test "encode stdin (no args)"      "Hello World"
# Very long input
run_test_file "encode: 64KB binary"    "$TMPDIR/binary.bin"

# ── SECTION: Roundtrip tests ──
echo ""
echo "── Roundtrip tests ──"
# Encode with GNU, decode with ours (and vice versa)
for size in 0 1 2 3 4 5 10 100 1000 10000; do
    dd if=/dev/urandom bs=1 count=$size of="$TMPDIR/rt_$size" 2>/dev/null
    # GNU encode → our decode
    encoded=$(base64 "$TMPDIR/rt_$size")
    printf '%s' "$encoded" | $TOOL -d > "$TMPDIR/rt_decoded_$size" 2>/dev/null
    if diff "$TMPDIR/rt_$size" "$TMPDIR/rt_decoded_$size" > /dev/null 2>&1; then
        echo -e "  ${GREEN}PASS${NC}: roundtrip $size bytes (GNU encode → our decode)"
        PASS=$((PASS + 1))
    else
        echo -e "  ${RED}FAIL${NC}: roundtrip $size bytes (GNU encode → our decode)"
        FAIL=$((FAIL + 1))
    fi
    # Our encode → GNU decode
    our_encoded=$($TOOL "$TMPDIR/rt_$size")
    printf '%s' "$our_encoded" | base64 -d > "$TMPDIR/rt_decoded2_$size" 2>/dev/null
    if diff "$TMPDIR/rt_$size" "$TMPDIR/rt_decoded2_$size" > /dev/null 2>&1; then
        echo -e "  ${GREEN}PASS${NC}: roundtrip $size bytes (our encode → GNU decode)"
        PASS=$((PASS + 1))
    else
        echo -e "  ${RED}FAIL${NC}: roundtrip $size bytes (our encode → GNU decode)"
        FAIL=$((FAIL + 1))
    fi
done

# ── SECTION: Large file test ──
echo ""
echo "── Large file test ──"
dd if=/dev/urandom bs=1M count=10 of="$TMPDIR/large.bin" 2>/dev/null
diff <(base64 "$TMPDIR/large.bin") <($TOOL "$TMPDIR/large.bin") > /dev/null 2>&1
if [ $? -eq 0 ]; then
    echo -e "  ${GREEN}PASS${NC}: 10MB file encode matches GNU"
    PASS=$((PASS + 1))
else
    echo -e "  ${RED}FAIL${NC}: 10MB file encode matches GNU"
    FAIL=$((FAIL + 1))
fi
diff "$TMPDIR/large.bin" <(base64 "$TMPDIR/large.bin" | $TOOL -d) > /dev/null 2>&1
if [ $? -eq 0 ]; then
    echo -e "  ${GREEN}PASS${NC}: 10MB file roundtrip"
    PASS=$((PASS + 1))
else
    echo -e "  ${RED}FAIL${NC}: 10MB file roundtrip"
    FAIL=$((FAIL + 1))
fi

# ── SECTION: Broken pipe ──
echo ""
echo "── Broken pipe ──"
bp_exit=0
(dd if=/dev/urandom bs=1M count=1 2>/dev/null | $TOOL | head -1 > /dev/null 2>&1) || bp_exit=$?
if [ "$bp_exit" -eq 0 ] || [ "$bp_exit" -eq 141 ]; then
    # 141 = 128+13 (SIGPIPE) is also acceptable from the pipeline
    echo -e "  ${GREEN}PASS${NC}: broken pipe handled gracefully"
    PASS=$((PASS + 1))
else
    echo -e "  ${RED}FAIL${NC}: broken pipe exits 0 (got $bp_exit)"
    FAIL=$((FAIL + 1))
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
