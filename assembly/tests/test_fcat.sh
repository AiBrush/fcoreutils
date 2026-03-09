#!/bin/bash
# GNU compatibility tests for fcat (assembly)
# Compares byte-for-byte stdout, stderr, and exit code against GNU cat
# Usage: bash test_fcat.sh [path-to-fcat]

BIN="${1:-../cat/fcat}"
GNU="/bin/cat"

PASS=0
FAIL=0
ERRORS=()

TMPDIR=$(mktemp -d /tmp/test_fcat.XXXXXX)
trap "rm -rf $TMPDIR" EXIT

# ── Helper: compare file-argument output ──
run_test() {
    local desc="$1"
    shift
    local args=("$@")

    $GNU "${args[@]}" > "$TMPDIR/expected" 2> "$TMPDIR/expected_err"
    local expected_exit=$?
    $BIN "${args[@]}" > "$TMPDIR/got" 2> "$TMPDIR/got_err"
    local got_exit=$?

    # Normalize error messages
    sed -i "s|$BIN|cat|g" "$TMPDIR/got_err"

    if diff -q "$TMPDIR/expected" "$TMPDIR/got" > /dev/null 2>&1 && \
       [ "$expected_exit" = "$got_exit" ]; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
        ERRORS+=("FAIL: $desc")
        if ! diff -q "$TMPDIR/expected" "$TMPDIR/got" > /dev/null 2>&1; then
            ERRORS+=("  output differs (first diff):")
            ERRORS+=("  $(diff "$TMPDIR/expected" "$TMPDIR/got" | head -5)")
        fi
        if [ "$expected_exit" != "$got_exit" ]; then
            ERRORS+=("  expected exit: $expected_exit, got: $got_exit")
        fi
    fi
}

# ── Helper: compare stdin-based output ──
run_test_stdin() {
    local desc="$1"
    local input_file="$2"
    shift 2
    local args=("$@")

    $GNU "${args[@]}" < "$input_file" > "$TMPDIR/expected" 2> "$TMPDIR/expected_err"
    local expected_exit=$?
    $BIN "${args[@]}" < "$input_file" > "$TMPDIR/got" 2> "$TMPDIR/got_err"
    local got_exit=$?

    sed -i "s|$BIN|cat|g" "$TMPDIR/got_err"

    if diff -q "$TMPDIR/expected" "$TMPDIR/got" > /dev/null 2>&1 && \
       [ "$expected_exit" = "$got_exit" ]; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
        ERRORS+=("FAIL: $desc")
        if ! diff -q "$TMPDIR/expected" "$TMPDIR/got" > /dev/null 2>&1; then
            ERRORS+=("  output differs (first diff):")
            ERRORS+=("  $(diff "$TMPDIR/expected" "$TMPDIR/got" | head -5)")
        fi
        if [ "$expected_exit" != "$got_exit" ]; then
            ERRORS+=("  expected exit: $expected_exit, got: $got_exit")
        fi
    fi
}

# ── Create test files ──
printf "hello\nworld\n" > "$TMPDIR/basic.txt"
printf "line1\nline2\nline3\n" > "$TMPDIR/three.txt"
printf "" > "$TMPDIR/empty.txt"
printf "no trailing newline" > "$TMPDIR/no_nl.txt"
printf "first\n" > "$TMPDIR/multi1.txt"
printf "second\n" > "$TMPDIR/multi2.txt"
printf '\x00\x01\xff' > "$TMPDIR/binary.bin"
printf 'hello\tworld\n' > "$TMPDIR/tabs.txt"

# 1MB random data
dd if=/dev/urandom of="$TMPDIR/random1m.bin" bs=1M count=1 2>/dev/null

echo "=== fcat GNU compatibility tests ==="
echo ""

# ── Basic file copy ──
echo "-- Basic file operations --"
run_test "basic file" "$TMPDIR/basic.txt"
run_test "three lines" "$TMPDIR/three.txt"
run_test "empty file" "$TMPDIR/empty.txt"
run_test "no trailing newline" "$TMPDIR/no_nl.txt"
run_test "1MB random binary" "$TMPDIR/random1m.bin"

# ── Multiple files ──
echo "-- Multiple files --"
run_test "two files" "$TMPDIR/multi1.txt" "$TMPDIR/multi2.txt"
run_test "three files" "$TMPDIR/multi1.txt" "$TMPDIR/multi2.txt" "$TMPDIR/basic.txt"

# ── /dev/null ──
echo "-- Special files --"
run_test "/dev/null" /dev/null

# ── Stdin ──
echo "-- Stdin tests --"
run_test_stdin "stdin basic" "$TMPDIR/basic.txt"
run_test_stdin "stdin empty" "$TMPDIR/empty.txt"
run_test_stdin "stdin no trailing newline" "$TMPDIR/no_nl.txt"
run_test_stdin "stdin binary" "$TMPDIR/random1m.bin"

# ── Binary data through pipe ──
echo "-- Binary data --"
printf '\x00\x01\xff' > "$TMPDIR/binpipe_input"
run_test_stdin "binary pipe (null, 0x01, 0xff)" "$TMPDIR/binpipe_input"

# ── Empty input ──
echo "-- Empty input --"
echo -n > "$TMPDIR/empty_pipe"
run_test_stdin "empty stdin" "$TMPDIR/empty_pipe"

# ── Dash for stdin ──
echo "-- Dash for stdin --"
printf "hi\n" > "$TMPDIR/dash_input"
$GNU - < "$TMPDIR/dash_input" > "$TMPDIR/expected" 2>/dev/null
gnu_exit=$?
$BIN - < "$TMPDIR/dash_input" > "$TMPDIR/got" 2>/dev/null
our_exit=$?
if diff -q "$TMPDIR/expected" "$TMPDIR/got" > /dev/null 2>&1 && [ "$gnu_exit" = "$our_exit" ]; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: dash (-) for stdin")
fi

# ── Nonexistent file (exit code 1) ──
echo "-- Error handling --"
run_test "nonexistent file" /tmp/fcat_nonexistent_xyz_123_test

# ── Continue after error: first file missing, second valid ──
run_test "error then valid file" /tmp/fcat_nonexistent_xyz_123_test "$TMPDIR/basic.txt"

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
