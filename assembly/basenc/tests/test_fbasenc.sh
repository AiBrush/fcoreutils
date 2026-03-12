#!/bin/bash
set -euo pipefail

# Find the tool - allow override via environment
TOOL="${TOOL:-./fbasenc}"
GNU="basenc"
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
echo " GNU Compatibility Tests: fbasenc"
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
# Z85 needs multiple-of-4 input
dd if=/dev/urandom bs=4 count=16 of="$TMPDIR/z85.bin" 2>/dev/null

# ── SECTION: Base64 encoding ──
echo "── Base64 encoding ──"
run_test "base64: hello world"         "Hello World" --base64
run_test "base64: empty"               "" --base64
run_test "base64: single byte"         "A" --base64
run_test "base64: two bytes"           "AB" --base64
run_test "base64: three bytes"         "ABC" --base64
run_test_file "base64: file"           "$TMPDIR/simple.txt" --base64
run_test_file "base64: binary file"    "$TMPDIR/binary.bin" --base64
run_test_file "base64: empty file"     "$TMPDIR/empty.txt" --base64

# ── SECTION: Base64url encoding ──
echo ""
echo "── Base64url encoding ──"
run_test "base64url: hello world"      "Hello World" --base64url
run_test "base64url: single byte"      "A" --base64url
run_test_file "base64url: file"        "$TMPDIR/binary.bin" --base64url

# ── SECTION: Base32 encoding ──
echo ""
echo "── Base32 encoding ──"
run_test "base32: hello world"         "Hello World" --base32
run_test "base32: empty"               "" --base32
run_test "base32: 1 byte"             "A" --base32
run_test "base32: 2 bytes"            "AB" --base32
run_test "base32: 3 bytes"            "ABC" --base32
run_test "base32: 4 bytes"            "ABCD" --base32
run_test "base32: 5 bytes"            "ABCDE" --base32
run_test_file "base32: file"           "$TMPDIR/simple.txt" --base32
run_test_file "base32: binary file"    "$TMPDIR/binary.bin" --base32

# ── SECTION: Base32hex encoding ──
echo ""
echo "── Base32hex encoding ──"
run_test "base32hex: hello world"      "Hello World" --base32hex
run_test "base32hex: 1 byte"          "A" --base32hex
run_test_file "base32hex: file"        "$TMPDIR/binary.bin" --base32hex

# ── SECTION: Base16 encoding ──
echo ""
echo "── Base16 encoding ──"
run_test "base16: hello world"         "Hello World" --base16
run_test "base16: empty"               "" --base16
run_test "base16: single byte"         "A" --base16
run_test "base16: null bytes"          $'\x00\x01\x02\x03' --base16
run_test_file "base16: file"           "$TMPDIR/binary.bin" --base16

# ── SECTION: Base2 encoding ──
echo ""
echo "── Base2 encoding ──"
run_test "base2msbf: A"                "A" --base2msbf
run_test "base2msbf: hello"            "Hello" --base2msbf
run_test "base2lsbf: A"                "A" --base2lsbf
run_test "base2lsbf: hello"            "Hello" --base2lsbf
run_test_file "base2msbf: file"        "$TMPDIR/small.bin" --base2msbf
run_test_file "base2lsbf: file"        "$TMPDIR/small.bin" --base2lsbf

# ── SECTION: Z85 encoding ──
echo ""
echo "── Z85 encoding ──"
run_test "z85: ABCD"                   "ABCD" --z85
run_test "z85: 8 bytes"               "ABCDABCD" --z85
run_test "z85: empty"                  "" --z85
run_test_file "z85: file"             "$TMPDIR/z85.bin" --z85
# Z85 non-multiple-of-4 should error
run_test "z85: 3 bytes (error)"        "ABC" --z85

# ── SECTION: Wrap modes ──
echo ""
echo "── Wrap modes ──"
for enc in base64 base32 base16 base2msbf; do
    run_test "$enc -w0"    "Hello World Hello World Hello World" --$enc -w0
    run_test "$enc -w10"   "Hello World Hello World Hello World" --$enc -w10
    run_test "$enc -w20"   "Hello World Hello World Hello World" --$enc -w20
    run_test "$enc -w76"   "Hello World Hello World Hello World" --$enc -w76
    run_test "$enc -w1"    "Hello World" --$enc -w1
    run_test "$enc -w4"    "Hello World" --$enc -w4
    run_test "$enc --wrap=20" "Hello World Hello World" --$enc --wrap=20
done
run_test "z85 -w0" "ABCDABCDABCDABCD" --z85 -w0
run_test "z85 -w10" "ABCDABCDABCDABCD" --z85 -w10

# ── SECTION: Decoding ──
echo ""
echo "── Decoding ──"
run_test_binary "base64 decode"          "SGVsbG8gV29ybGQ=" --base64 -d
run_test_binary "base64 decode multiline" "$(basenc --base64 "$TMPDIR/small.bin")" --base64 -d
run_test_binary "base64 decode empty"    "" --base64 -d
run_test_binary "base64url decode"       "SGVsbG8gV29ybGQ=" --base64url -d
run_test_binary "base32 decode"          "JBSWY3DPEBLW64TMMQ======" --base32 -d
run_test_binary "base32 decode 1 byte"   "IE======" --base32 -d
run_test_binary "base32 decode 2 bytes"  "IFBA====" --base32 -d
run_test_binary "base32 decode 3 bytes"  "IFBEG===" --base32 -d
run_test_binary "base32 decode 4 bytes"  "IFBEGRA=" --base32 -d
run_test_binary "base32hex decode"       "91IMOR3F41BMUSJCCG======" --base32hex -d
run_test_binary "base16 decode"          "48656C6C6F20576F726C64" --base16 -d
run_test_binary "base16 decode lowercase" "48656c6c6f" --base16 -d
run_test_binary "base2msbf decode"       "01000001" --base2msbf -d
run_test_binary "base2lsbf decode"       "10000010" --base2lsbf -d
run_test_binary "base2msbf decode multi" "$(basenc --base2msbf "$TMPDIR/small.bin")" --base2msbf -d
run_test_binary "base2lsbf decode multi" "$(basenc --base2lsbf "$TMPDIR/small.bin")" --base2lsbf -d
run_test_binary "z85 decode"             "$(basenc --z85 "$TMPDIR/z85.bin")" --z85 -d

# ── SECTION: Decode with ignore garbage ──
echo ""
echo "── Decode with ignore garbage ──"
run_test_binary "base64 -di"              "SGVs@@bG8g@@V29ybGQ=" --base64 -di
run_test_binary "base64 -d --ignore-garbage" "SGVs@@bG8g@@V29ybGQ=" --base64 -d --ignore-garbage
run_test_binary "base32 -di"              "JB@@SW@@Y3@@DP@@" --base32 -di
run_test_binary "base16 -di"              "48@@65@@6C" --base16 -di
run_test_binary "base2msbf -di"           "01@@00@@00@@01" --base2msbf -di

# ── SECTION: Error handling ──
echo ""
echo "── Error handling ──"
run_test_noargs "missing encoding"
run_test_noargs "nonexistent file"     --base64 /nonexistent/file
run_test_noargs "invalid option -x"    --base64 -x
run_test_noargs "invalid option -Z"    --base64 -Z
run_test_noargs "unrecognized --foo"   --foo
run_test "invalid base64 decode"       "!!!!" --base64 -d
run_test "invalid base32 decode"       "!!!!" --base32 -d
run_test "invalid base16 decode"       "ZZZZ" --base16 -d
run_test "invalid base2 decode"        "2222" --base2msbf -d
run_test_noargs "missing -w arg"       --base64 -w
run_test_noargs "invalid wrap: abc"    --base64 -wabc

# ── SECTION: Help and version ──
echo ""
echo "── Help and version ──"
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
run_test "base64 stdin dash"            "test" --base64 -
run_test "base64 encode stdin"          "Hello World" --base64
run_test_file "base64 64KB binary"      "$TMPDIR/binary.bin" --base64
run_test_file "base32 64KB binary"      "$TMPDIR/binary.bin" --base32

# ── SECTION: Roundtrip tests ──
echo ""
echo "── Roundtrip tests ──"
for enc in base64 base64url base32 base32hex base16 base2msbf base2lsbf; do
    for size in 0 1 2 3 4 5 10 100 1000 10000; do
        dd if=/dev/urandom bs=1 count=$size of="$TMPDIR/rt_$size" 2>/dev/null
        # GNU encode → our decode
        encoded=$($GNU --$enc "$TMPDIR/rt_$size")
        printf '%s' "$encoded" | $TOOL --$enc -d > "$TMPDIR/rt_decoded_$size" 2>/dev/null
        if diff "$TMPDIR/rt_$size" "$TMPDIR/rt_decoded_$size" > /dev/null 2>&1; then
            echo -e "  ${GREEN}PASS${NC}: roundtrip $enc $size bytes (GNU enc → our dec)"
            PASS=$((PASS + 1))
        else
            echo -e "  ${RED}FAIL${NC}: roundtrip $enc $size bytes (GNU enc → our dec)"
            FAIL=$((FAIL + 1))
        fi
        # Our encode → GNU decode
        our_encoded=$($TOOL --$enc "$TMPDIR/rt_$size")
        printf '%s' "$our_encoded" | $GNU --$enc -d > "$TMPDIR/rt_decoded2_$size" 2>/dev/null
        if diff "$TMPDIR/rt_$size" "$TMPDIR/rt_decoded2_$size" > /dev/null 2>&1; then
            echo -e "  ${GREEN}PASS${NC}: roundtrip $enc $size bytes (our enc → GNU dec)"
            PASS=$((PASS + 1))
        else
            echo -e "  ${RED}FAIL${NC}: roundtrip $enc $size bytes (our enc → GNU dec)"
            FAIL=$((FAIL + 1))
        fi
    done
done
# Z85 roundtrip (multiples of 4 only)
for size in 0 4 8 12 100 1000 10000; do
    dd if=/dev/urandom bs=1 count=$size of="$TMPDIR/rt_$size" 2>/dev/null
    encoded=$($GNU --z85 "$TMPDIR/rt_$size" 2>/dev/null) || continue
    printf '%s' "$encoded" | $TOOL --z85 -d > "$TMPDIR/rt_decoded_$size" 2>/dev/null
    if diff "$TMPDIR/rt_$size" "$TMPDIR/rt_decoded_$size" > /dev/null 2>&1; then
        echo -e "  ${GREEN}PASS${NC}: roundtrip z85 $size bytes (GNU enc → our dec)"
        PASS=$((PASS + 1))
    else
        echo -e "  ${RED}FAIL${NC}: roundtrip z85 $size bytes (GNU enc → our dec)"
        FAIL=$((FAIL + 1))
    fi
    our_encoded=$($TOOL --z85 "$TMPDIR/rt_$size" 2>/dev/null) || continue
    printf '%s' "$our_encoded" | $GNU --z85 -d > "$TMPDIR/rt_decoded2_$size" 2>/dev/null
    if diff "$TMPDIR/rt_$size" "$TMPDIR/rt_decoded2_$size" > /dev/null 2>&1; then
        echo -e "  ${GREEN}PASS${NC}: roundtrip z85 $size bytes (our enc → GNU dec)"
        PASS=$((PASS + 1))
    else
        echo -e "  ${RED}FAIL${NC}: roundtrip z85 $size bytes (our enc → GNU dec)"
        FAIL=$((FAIL + 1))
    fi
done

# ── SECTION: Large file test ──
echo ""
echo "── Large file test ──"
dd if=/dev/urandom bs=1M count=10 of="$TMPDIR/large.bin" 2>/dev/null
diff <(basenc --base64 "$TMPDIR/large.bin") <($TOOL --base64 "$TMPDIR/large.bin") > /dev/null 2>&1
if [ $? -eq 0 ]; then
    echo -e "  ${GREEN}PASS${NC}: 10MB file base64 encode matches GNU"
    PASS=$((PASS + 1))
else
    echo -e "  ${RED}FAIL${NC}: 10MB file base64 encode matches GNU"
    FAIL=$((FAIL + 1))
fi
diff "$TMPDIR/large.bin" <(basenc --base64 "$TMPDIR/large.bin" | $TOOL --base64 -d) > /dev/null 2>&1
if [ $? -eq 0 ]; then
    echo -e "  ${GREEN}PASS${NC}: 10MB file base64 roundtrip"
    PASS=$((PASS + 1))
else
    echo -e "  ${RED}FAIL${NC}: 10MB file base64 roundtrip"
    FAIL=$((FAIL + 1))
fi

# ── SECTION: Broken pipe ──
echo ""
echo "── Broken pipe ──"
bp_exit=0
(dd if=/dev/urandom bs=1M count=1 2>/dev/null | $TOOL --base64 | head -1 > /dev/null 2>&1) || bp_exit=$?
if [ "$bp_exit" -eq 0 ] || [ "$bp_exit" -eq 141 ]; then
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
