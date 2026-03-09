#!/bin/bash
# Test suite for fcat — compares byte-for-byte with GNU cat
# Usage: bash tests/run_tests.sh ./fcat

BIN="${1:-./fcat}"
GNU="/bin/cat"
TOOL="cat"

PASS=0
FAIL=0
ERRORS=()

TMPDIR=$(mktemp -d /tmp/fcat_test.XXXXXX)
trap "rm -rf $TMPDIR" EXIT

# ── Helper: compare file-based output ──
run_test() {
    local desc="$1"
    shift
    local args=("$@")

    $GNU "${args[@]}" > "$TMPDIR/expected" 2> "$TMPDIR/expected_err"
    local expected_exit=$?
    $BIN "${args[@]}" > "$TMPDIR/got" 2> "$TMPDIR/got_err"
    local got_exit=$?

    # Normalize error messages: replace binary path with "cat"
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
printf "a\n\n\n\nb\n\n\n\nc\n" > "$TMPDIR/blanks.txt"
printf "a\n\nb\n\nc\n" > "$TMPDIR/blanks2.txt"
printf "\n\n\n" > "$TMPDIR/allblank.txt"
printf "hello\tworld\n" > "$TMPDIR/tabs.txt"
printf "first\n" > "$TMPDIR/multi1.txt"
printf "second\n" > "$TMPDIR/multi2.txt"
printf "third\n" > "$TMPDIR/multi3.txt"

# All 256 byte values, one per line
python3 -c "
import sys
for i in range(256):
    sys.stdout.buffer.write(bytes([i]))
    sys.stdout.buffer.write(b'\n')
" > "$TMPDIR/allbytes.bin"

# Binary data with null bytes
printf '\x00\x01\x02\x03\x04\x05\x06\x07\x08\x09\x0a\x0b\x0c\x0d\x0e\x0f' > "$TMPDIR/ctrl.bin"
printf '\x80\x81\x9f\xa0\xfe\xff' > "$TMPDIR/high.bin"

# Large file (1MB random)
dd if=/dev/urandom of="$TMPDIR/random1m.bin" bs=1M count=1 2>/dev/null

# ── Zero-copy / sendfile path (no flags) ──
echo "=== Zero-copy path tests ==="
run_test "basic file" "$TMPDIR/basic.txt"
run_test "three lines" "$TMPDIR/three.txt"
run_test "empty file" "$TMPDIR/empty.txt"
run_test "no trailing newline" "$TMPDIR/no_nl.txt"
run_test "1MB random binary" "$TMPDIR/random1m.bin"
run_test "multiple files" "$TMPDIR/multi1.txt" "$TMPDIR/multi2.txt" "$TMPDIR/multi3.txt"

# ── stdin (no flags) ──
echo "=== Stdin tests ==="
run_test_stdin "stdin basic" "$TMPDIR/basic.txt"
run_test_stdin "stdin empty" "$TMPDIR/empty.txt"
run_test_stdin "stdin no-nl" "$TMPDIR/no_nl.txt"
run_test_stdin "stdin binary" "$TMPDIR/random1m.bin"

# ── -n flag (number all lines) ──
echo "=== -n flag tests ==="
run_test "-n basic" -n "$TMPDIR/basic.txt"
run_test "-n three lines" -n "$TMPDIR/three.txt"
run_test "-n empty file" -n "$TMPDIR/empty.txt"
run_test "-n no trailing newline" -n "$TMPDIR/no_nl.txt"
run_test "-n blanks" -n "$TMPDIR/blanks.txt"
run_test "-n all blank" -n "$TMPDIR/allblank.txt"
run_test "-n multi file" -n "$TMPDIR/multi1.txt" "$TMPDIR/multi2.txt"
run_test_stdin "-n stdin" "$TMPDIR/three.txt" -n

# ── -b flag (number non-blank lines) ──
echo "=== -b flag tests ==="
run_test "-b blanks" -b "$TMPDIR/blanks.txt"
run_test "-b blanks2" -b "$TMPDIR/blanks2.txt"
run_test "-b all blank" -b "$TMPDIR/allblank.txt"
run_test "-b basic" -b "$TMPDIR/basic.txt"
run_test "-b empty" -b "$TMPDIR/empty.txt"
run_test "-b no-nl" -b "$TMPDIR/no_nl.txt"
run_test_stdin "-b stdin" "$TMPDIR/blanks2.txt" -b

# ── -b overrides -n ──
echo "=== -b/-n interaction ==="
run_test "-bn interaction" -bn "$TMPDIR/blanks2.txt"
run_test "-nb interaction" -nb "$TMPDIR/blanks2.txt"

# ── -s flag (squeeze blank lines) ──
echo "=== -s flag tests ==="
run_test "-s blanks" -s "$TMPDIR/blanks.txt"
run_test "-s blanks2" -s "$TMPDIR/blanks2.txt"
run_test "-s all blank" -s "$TMPDIR/allblank.txt"
run_test "-s basic" -s "$TMPDIR/basic.txt"
run_test "-s empty" -s "$TMPDIR/empty.txt"
run_test "-sn blanks" -sn "$TMPDIR/blanks.txt"
run_test "-sb blanks" -sb "$TMPDIR/blanks.txt"
run_test_stdin "-s stdin" "$TMPDIR/blanks.txt" -s

# ── -E flag (show ends) ──
echo "=== -E flag tests ==="
run_test "-E basic" -E "$TMPDIR/basic.txt"
run_test "-E empty" -E "$TMPDIR/empty.txt"
run_test "-E no-nl" -E "$TMPDIR/no_nl.txt"
run_test "-E blanks" -E "$TMPDIR/blanks2.txt"
run_test "-En blanks" -En "$TMPDIR/blanks2.txt"

# ── -T flag (show tabs) ──
echo "=== -T flag tests ==="
run_test "-T tabs" -T "$TMPDIR/tabs.txt"
run_test "-Tn tabs" -Tn "$TMPDIR/tabs.txt"

# ── -v flag (show non-printing) ──
echo "=== -v flag tests ==="
run_test "-v all bytes" -v "$TMPDIR/allbytes.bin"
run_test "-v ctrl chars" -v "$TMPDIR/ctrl.bin"
run_test "-v high bytes" -v "$TMPDIR/high.bin"
run_test_stdin "-v stdin" "$TMPDIR/allbytes.bin" -v

# ── -A flag (= -vET) ──
echo "=== -A flag tests ==="
run_test "-A all bytes" -A "$TMPDIR/allbytes.bin"
run_test "-A tabs" -A "$TMPDIR/tabs.txt"
run_test "-A basic" -A "$TMPDIR/basic.txt"

# ── -e flag (= -vE) ──
echo "=== -e flag tests ==="
run_test "-e all bytes" -e "$TMPDIR/allbytes.bin"
run_test "-e basic" -e "$TMPDIR/basic.txt"

# ── -t flag (= -vT) ──
echo "=== -t flag tests ==="
run_test "-t all bytes" -t "$TMPDIR/allbytes.bin"
run_test "-t tabs" -t "$TMPDIR/tabs.txt"

# ── Combined flags ──
echo "=== Combined flags ==="
run_test "-svn blanks" -svn "$TMPDIR/blanks.txt"
run_test "-svb blanks" -svb "$TMPDIR/blanks.txt"
run_test "-snE blanks" -snE "$TMPDIR/blanks2.txt"
run_test "-bsET tabs blanks" -bsET "$TMPDIR/blanks.txt"
run_test "-A multi file" -A "$TMPDIR/multi1.txt" "$TMPDIR/multi2.txt"

# ── -u flag (ignored) ──
echo "=== -u flag (ignored) ==="
run_test "-u basic" -u "$TMPDIR/basic.txt"
run_test "-un basic" -un "$TMPDIR/basic.txt"

# ── -- ends option parsing ──
echo "=== -- tests ==="
run_test "-- then -n as file" -- -n "$TMPDIR/basic.txt"

# ── Error cases ──
echo "=== Error cases ==="
run_test "nonexistent file" /tmp/fcat_nonexistent_xyz_123

# ── Continue after error ──
echo "=== Continue after error ==="
run_test "error then valid file" /tmp/fcat_nonexistent_xyz_123 "$TMPDIR/basic.txt"

# ── Large file with -n ──
echo "=== Large file tests ==="
run_test "-n 1MB binary" -n "$TMPDIR/random1m.bin"
run_test "-v 1MB binary" -v "$TMPDIR/random1m.bin"

# ── Results ──
echo ""
echo "Results: $PASS passed, $FAIL failed out of $((PASS+FAIL)) tests"
for e in "${ERRORS[@]}"; do echo "$e"; done
echo ""

if [ $FAIL -eq 0 ]; then
    echo "ALL TESTS PASSED"
    exit 0
else
    echo "$FAIL TESTS FAILED"
    exit 1
fi
