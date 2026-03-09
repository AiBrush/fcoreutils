#!/bin/bash
# GNU compatibility tests for fnl (assembly)
# Compares byte-for-byte stdout and exit code against GNU nl
# Usage: bash test_fnl.sh [path-to-fnl]

BIN="${1:-../nl/fnl}"
GNU="/usr/bin/nl"

PASS=0
FAIL=0
ERRORS=()

TMPDIR=$(mktemp -d /tmp/test_fnl.XXXXXX)
trap "rm -rf $TMPDIR" EXIT

run_test() {
    local desc="$1"
    shift
    local args=("$@")

    $GNU "${args[@]}" > "$TMPDIR/expected" 2> "$TMPDIR/expected_err"
    local expected_exit=$?
    $BIN "${args[@]}" > "$TMPDIR/got" 2> "$TMPDIR/got_err"
    local got_exit=$?

    if diff -q "$TMPDIR/expected" "$TMPDIR/got" > /dev/null 2>&1 && \
       [ "$expected_exit" = "$got_exit" ]; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
        ERRORS+=("FAIL: $desc")
        if ! diff -q "$TMPDIR/expected" "$TMPDIR/got" > /dev/null 2>&1; then
            ERRORS+=("  expected first 3 lines: $(head -3 "$TMPDIR/expected")")
            ERRORS+=("  got first 3 lines:      $(head -3 "$TMPDIR/got")")
        fi
        if [ "$expected_exit" != "$got_exit" ]; then
            ERRORS+=("  expected exit: $expected_exit, got: $got_exit")
        fi
    fi
}

run_test_stdin() {
    local desc="$1"
    local input="$2"
    shift 2
    local args=("$@")

    printf '%b' "$input" | $GNU "${args[@]}" > "$TMPDIR/expected" 2> "$TMPDIR/expected_err"
    local expected_exit=$?
    printf '%b' "$input" | $BIN "${args[@]}" > "$TMPDIR/got" 2> "$TMPDIR/got_err"
    local got_exit=$?

    if diff -q "$TMPDIR/expected" "$TMPDIR/got" > /dev/null 2>&1 && \
       [ "$expected_exit" = "$got_exit" ]; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
        ERRORS+=("FAIL: $desc")
        if ! diff -q "$TMPDIR/expected" "$TMPDIR/got" > /dev/null 2>&1; then
            ERRORS+=("  expected first 3 lines: $(head -3 "$TMPDIR/expected")")
            ERRORS+=("  got first 3 lines:      $(head -3 "$TMPDIR/got")")
        fi
        if [ "$expected_exit" != "$got_exit" ]; then
            ERRORS+=("  expected exit: $expected_exit, got: $got_exit")
        fi
    fi
}

# ── Create test files ──
printf 'hello\nworld\n' > "$TMPDIR/basic.txt"
printf 'a\n\nb\n\n\nc\n' > "$TMPDIR/blanks.txt"
printf 'line1\nline2\nline3\nline4\nline5\n' > "$TMPDIR/5lines.txt"
printf '' > "$TMPDIR/empty.txt"
printf 'abc\n' > "$TMPDIR/single.txt"
printf '\n\n\n' > "$TMPDIR/onlyblanks.txt"
seq 1 100 > "$TMPDIR/100lines.txt"

echo "=== fnl GNU compatibility tests ==="
echo ""

# ── Basic functionality ──
echo "-- Basic functionality --"
run_test "basic default" "$TMPDIR/basic.txt"
run_test "5 lines default" "$TMPDIR/5lines.txt"
run_test "100 lines default" "$TMPDIR/100lines.txt"
run_test "single line" "$TMPDIR/single.txt"
run_test "empty file" "$TMPDIR/empty.txt"
run_test "only blank lines" "$TMPDIR/onlyblanks.txt"

# ── Empty lines not numbered by default ──
echo "-- Default blank handling --"
run_test "blanks not numbered by default" "$TMPDIR/blanks.txt"

# ── Body numbering: -b a (all lines) ──
echo "-- Body numbering styles --"
run_test "-b a (all lines)" -b a "$TMPDIR/blanks.txt"
run_test "-b n (no numbering)" -b n "$TMPDIR/basic.txt"
run_test "-b t (nonempty, default)" -b t "$TMPDIR/blanks.txt"

# ── Number formats ──
echo "-- Number formats --"
run_test "-n ln (left justified)" -n ln "$TMPDIR/basic.txt"
run_test "-n rn (right justified)" -n rn "$TMPDIR/basic.txt"
run_test "-n rz (right zero-padded)" -n rz "$TMPDIR/basic.txt"
run_test "-n ln with -b a" -n ln -b a "$TMPDIR/blanks.txt"
run_test "-n rz with -b a" -n rz -b a "$TMPDIR/blanks.txt"

# ── Width ──
echo "-- Width --"
run_test "-w 3" -w 3 "$TMPDIR/basic.txt"
run_test "-w 1" -w 1 "$TMPDIR/basic.txt"
run_test "-w 10" -w 10 "$TMPDIR/basic.txt"
run_test "-w 1 -n rz" -w 1 -n rz "$TMPDIR/basic.txt"
run_test "-w 3 -n ln" -w 3 -n ln "$TMPDIR/basic.txt"

# ── Separator ──
echo "-- Separator --"
run_test "-s ': '" -s ': ' "$TMPDIR/basic.txt"
run_test "-s ''" -s '' "$TMPDIR/basic.txt"
run_test "-s '---'" -s '---' "$TMPDIR/basic.txt"
run_test "-s with -b a" -s '| ' -b a "$TMPDIR/blanks.txt"

# ── Stdin ──
echo "-- Stdin --"
run_test_stdin "stdin default" "hello\nworld\n"
run_test_stdin "stdin -b a" "hello\n\nworld\n" -b a
run_test_stdin "stdin -n rz -w 3" "abc\ndef\n" -n rz -w 3
run_test_stdin "stdin empty" ""

# ── Combined options ──
echo "-- Combined options --"
run_test "combined -ba -nrz -w3" -ba -nrz -w3 "$TMPDIR/basic.txt"
run_test "all opts" -b a -n rz -w 3 -s ': ' -i 5 -v 10 "$TMPDIR/5lines.txt"

# ── Increment ──
echo "-- Increment --"
run_test "-i 5" -b a -i 5 "$TMPDIR/5lines.txt"
run_test "-i 10" -b a -i 10 "$TMPDIR/5lines.txt"

# ── Starting value ──
echo "-- Starting value --"
run_test "-v 0" -b a -v 0 "$TMPDIR/basic.txt"
run_test "-v 10" -b a -v 10 "$TMPDIR/basic.txt"
run_test "-v 100" -b a -v 100 "$TMPDIR/basic.txt"

# ── Error handling ──
echo "-- Error handling --"
run_test "nonexistent file" "$TMPDIR/nonexistent.txt"

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
