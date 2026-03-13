#!/bin/bash
# Test suite for fbasenc
# Usage: bash tests/run_tests.sh ./fbasenc

BIN="${1:-./fbasenc}"
GNU="basenc"
PASS=0
FAIL=0
ERRORS=()
TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT

run_test_stdin() {
    local desc="$1"
    local input="$2"
    shift 2
    local args=("$@")

    printf '%s' "$input" | $GNU "${args[@]}" > "$TMPDIR/expected" 2> "$TMPDIR/expected_err"
    local expected_exit=$?
    printf '%s' "$input" | $BIN "${args[@]}" > "$TMPDIR/got" 2> "$TMPDIR/got_err"
    local got_exit=$?

    if diff "$TMPDIR/expected" "$TMPDIR/got" > /dev/null 2>&1 && [ "$expected_exit" = "$got_exit" ]; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
        ERRORS+=("FAIL: $desc")
        if ! diff "$TMPDIR/expected" "$TMPDIR/got" > /dev/null 2>&1; then
            ERRORS+=("  expected stdout: $(head -3 "$TMPDIR/expected")")
            ERRORS+=("  got stdout:      $(head -3 "$TMPDIR/got")")
        fi
        if [ "$expected_exit" != "$got_exit" ]; then
            ERRORS+=("  expected exit: $expected_exit, got: $got_exit")
        fi
    fi
}

run_test_file() {
    local desc="$1"
    local file="$2"
    shift 2
    local args=("$@")

    $GNU "${args[@]}" "$file" > "$TMPDIR/expected" 2> "$TMPDIR/expected_err"
    local expected_exit=$?
    $BIN "${args[@]}" "$file" > "$TMPDIR/got" 2> "$TMPDIR/got_err"
    local got_exit=$?

    if diff "$TMPDIR/expected" "$TMPDIR/got" > /dev/null 2>&1 && [ "$expected_exit" = "$got_exit" ]; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
        ERRORS+=("FAIL: $desc")
        if ! diff "$TMPDIR/expected" "$TMPDIR/got" > /dev/null 2>&1; then
            ERRORS+=("  expected stdout: $(head -3 "$TMPDIR/expected")")
            ERRORS+=("  got stdout:      $(head -3 "$TMPDIR/got")")
        fi
        if [ "$expected_exit" != "$got_exit" ]; then
            ERRORS+=("  expected exit: $expected_exit, got: $got_exit")
        fi
    fi
}

run_test_noargs() {
    local desc="$1"
    shift
    local args=("$@")

    $GNU "${args[@]}" > "$TMPDIR/expected" 2> "$TMPDIR/expected_err"
    local expected_exit=$?
    $BIN "${args[@]}" > "$TMPDIR/got" 2> "$TMPDIR/got_err"
    local got_exit=$?

    if [ "$expected_exit" = "$got_exit" ]; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
        ERRORS+=("FAIL: $desc")
        ERRORS+=("  expected exit: $expected_exit, got: $got_exit")
    fi
}

run_test_binary_decode() {
    local desc="$1"
    local input="$2"
    shift 2
    local args=("$@")

    printf '%s' "$input" | $GNU "${args[@]}" > "$TMPDIR/expected_bin" 2>/dev/null
    local expected_exit=$?
    printf '%s' "$input" | $BIN "${args[@]}" > "$TMPDIR/got_bin" 2>/dev/null
    local got_exit=$?

    if diff "$TMPDIR/expected_bin" "$TMPDIR/got_bin" > /dev/null 2>&1 && [ "$expected_exit" = "$got_exit" ]; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
        ERRORS+=("FAIL: $desc")
        if ! diff "$TMPDIR/expected_bin" "$TMPDIR/got_bin" > /dev/null 2>&1; then
            ERRORS+=("  binary output mismatch")
        fi
        if [ "$expected_exit" != "$got_exit" ]; then
            ERRORS+=("  expected exit: $expected_exit, got: $got_exit")
        fi
    fi
}

run_test_exit_only() {
    local desc="$1"
    shift
    local args=("$@")

    $GNU "${args[@]}" > /dev/null 2>&1
    local expected_exit=$?
    $BIN "${args[@]}" > /dev/null 2>&1
    local got_exit=$?

    if [ "$expected_exit" = "$got_exit" ]; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
        ERRORS+=("FAIL: $desc -- expected exit: $expected_exit, got: $got_exit")
    fi
}

# ── Create test fixtures ──
echo -n "hello world" > "$TMPDIR/simple.txt"
echo -e "line1\nline2\nline3" > "$TMPDIR/multi.txt"
dd if=/dev/urandom bs=1024 count=64 of="$TMPDIR/binary.bin" 2>/dev/null
dd if=/dev/urandom bs=1024 count=1 of="$TMPDIR/small.bin" 2>/dev/null
touch "$TMPDIR/empty.txt"
dd if=/dev/urandom bs=4 count=16 of="$TMPDIR/z85.bin" 2>/dev/null

# ── Standard flags ──
run_test_exit_only "--help exit code" --help
run_test_exit_only "--version exit code" --version

# ── Base64 encoding ──
echo "=== Base64 encoding ==="
run_test_stdin "base64: hello world" "Hello World" --base64
run_test_stdin "base64: empty" "" --base64
run_test_stdin "base64: single byte" "A" --base64
run_test_stdin "base64: two bytes" "AB" --base64
run_test_stdin "base64: three bytes" "ABC" --base64
run_test_file "base64: file" "$TMPDIR/simple.txt" --base64
run_test_file "base64: binary file" "$TMPDIR/binary.bin" --base64
run_test_file "base64: empty file" "$TMPDIR/empty.txt" --base64

# ── Base64url encoding ──
echo "=== Base64url encoding ==="
run_test_stdin "base64url: hello world" "Hello World" --base64url
run_test_stdin "base64url: single byte" "A" --base64url
run_test_file "base64url: binary file" "$TMPDIR/binary.bin" --base64url

# ── Base32 encoding ──
echo "=== Base32 encoding ==="
run_test_stdin "base32: hello world" "Hello World" --base32
run_test_stdin "base32: empty" "" --base32
run_test_stdin "base32: 1 byte" "A" --base32
run_test_stdin "base32: 2 bytes" "AB" --base32
run_test_stdin "base32: 3 bytes" "ABC" --base32
run_test_stdin "base32: 4 bytes" "ABCD" --base32
run_test_stdin "base32: 5 bytes" "ABCDE" --base32
run_test_file "base32: file" "$TMPDIR/simple.txt" --base32
run_test_file "base32: binary file" "$TMPDIR/binary.bin" --base32

# ── Base32hex encoding ──
echo "=== Base32hex encoding ==="
run_test_stdin "base32hex: hello world" "Hello World" --base32hex
run_test_stdin "base32hex: 1 byte" "A" --base32hex
run_test_file "base32hex: binary file" "$TMPDIR/binary.bin" --base32hex

# ── Base16 encoding ──
echo "=== Base16 encoding ==="
run_test_stdin "base16: hello world" "Hello World" --base16
run_test_stdin "base16: empty" "" --base16
run_test_stdin "base16: single byte" "A" --base16
run_test_file "base16: binary file" "$TMPDIR/binary.bin" --base16

# ── Base2 encoding ──
echo "=== Base2 encoding ==="
run_test_stdin "base2msbf: A" "A" --base2msbf
run_test_stdin "base2msbf: hello" "Hello" --base2msbf
run_test_stdin "base2lsbf: A" "A" --base2lsbf
run_test_stdin "base2lsbf: hello" "Hello" --base2lsbf
run_test_file "base2msbf: file" "$TMPDIR/small.bin" --base2msbf
run_test_file "base2lsbf: file" "$TMPDIR/small.bin" --base2lsbf

# ── Z85 encoding ──
echo "=== Z85 encoding ==="
run_test_stdin "z85: ABCD" "ABCD" --z85
run_test_stdin "z85: 8 bytes" "ABCDABCD" --z85
run_test_stdin "z85: empty" "" --z85
run_test_file "z85: file" "$TMPDIR/z85.bin" --z85
run_test_stdin "z85: 3 bytes (error)" "ABC" --z85

# ── Wrap modes ──
echo "=== Wrap modes ==="
for enc in base64 base32 base16 base2msbf; do
    run_test_stdin "$enc -w0" "Hello World Hello World Hello World" --$enc -w0
    run_test_stdin "$enc -w10" "Hello World Hello World Hello World" --$enc -w10
    run_test_stdin "$enc -w20" "Hello World Hello World Hello World" --$enc -w20
    run_test_stdin "$enc -w76" "Hello World Hello World Hello World" --$enc -w76
done

# ── Decoding ──
echo "=== Decoding ==="
run_test_binary_decode "base64 decode" "SGVsbG8gV29ybGQ=" --base64 -d
run_test_binary_decode "base64 decode empty" "" --base64 -d
run_test_binary_decode "base64url decode" "SGVsbG8gV29ybGQ=" --base64url -d
run_test_binary_decode "base32 decode" "JBSWY3DPEBLW64TMMQ======" --base32 -d
run_test_binary_decode "base32hex decode" "91IMOR3F41BMUSJCCG======" --base32hex -d
run_test_binary_decode "base16 decode" "48656C6C6F20576F726C64" --base16 -d
run_test_binary_decode "base2msbf decode" "01000001" --base2msbf -d
run_test_binary_decode "base2lsbf decode" "10000010" --base2lsbf -d

# ── Decode with ignore garbage ──
echo "=== Decode with ignore garbage ==="
run_test_binary_decode "base64 -di" "SGVs@@bG8g@@V29ybGQ=" --base64 -di
run_test_binary_decode "base32 -di" "JB@@SW@@Y3@@DP@@" --base32 -di
run_test_binary_decode "base16 -di" "48@@65@@6C" --base16 -di

# ── Error handling ──
echo "=== Error handling ==="
run_test_noargs "missing encoding"
run_test_noargs "nonexistent file" --base64 /nonexistent/file
run_test_noargs "invalid option -Z" --base64 -Z
run_test_noargs "unrecognized --foo" --foo
run_test_stdin "invalid base64 decode" "!!!!" --base64 -d
run_test_stdin "invalid base32 decode" "!!!!" --base32 -d
run_test_stdin "invalid base16 decode" "ZZZZ" --base16 -d

# ── Roundtrip tests ──
echo "=== Roundtrip tests ==="
for enc in base64 base64url base32 base32hex base16 base2msbf base2lsbf; do
    for size in 0 1 2 3 4 5 10 100 1000; do
        dd if=/dev/urandom bs=1 count=$size of="$TMPDIR/rt_$size" 2>/dev/null
        # GNU encode -> our decode
        $GNU --$enc "$TMPDIR/rt_$size" | $BIN --$enc -d > "$TMPDIR/rt_decoded_$size" 2>/dev/null
        if diff "$TMPDIR/rt_$size" "$TMPDIR/rt_decoded_$size" > /dev/null 2>&1; then
            PASS=$((PASS+1))
        else
            FAIL=$((FAIL+1))
            ERRORS+=("FAIL: roundtrip $enc $size bytes (GNU enc -> our dec)")
        fi
        # Our encode -> GNU decode
        $BIN --$enc "$TMPDIR/rt_$size" | $GNU --$enc -d > "$TMPDIR/rt_decoded2_$size" 2>/dev/null
        if diff "$TMPDIR/rt_$size" "$TMPDIR/rt_decoded2_$size" > /dev/null 2>&1; then
            PASS=$((PASS+1))
        else
            FAIL=$((FAIL+1))
            ERRORS+=("FAIL: roundtrip $enc $size bytes (our enc -> GNU dec)")
        fi
    done
done

# Z85 roundtrip (multiples of 4 only)
for size in 0 4 8 12 100; do
    dd if=/dev/urandom bs=1 count=$size of="$TMPDIR/rt_z85_$size" 2>/dev/null
    encoded=$($GNU --z85 "$TMPDIR/rt_z85_$size" 2>/dev/null) || continue
    printf '%s' "$encoded" | $BIN --z85 -d > "$TMPDIR/rt_z85_dec_$size" 2>/dev/null
    if diff "$TMPDIR/rt_z85_$size" "$TMPDIR/rt_z85_dec_$size" > /dev/null 2>&1; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
        ERRORS+=("FAIL: roundtrip z85 $size bytes")
    fi
done

# ── Results ──
echo ""
echo "Results: $PASS passed, $FAIL failed out of $((PASS+FAIL)) tests"
for e in "${ERRORS[@]}"; do echo "  $e"; done
echo ""

if [ $FAIL -eq 0 ]; then
    echo "ALL TESTS PASSED"
    exit 0
else
    echo "$FAIL TESTS FAILED"
    exit 1
fi
