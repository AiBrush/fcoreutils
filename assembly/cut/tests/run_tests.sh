#!/bin/bash
# Test suite for fcut
# Usage: bash tests/run_tests.sh ./fcut

BIN="${1:-./fcut}"
GNU="/usr/bin/cut"
TOOL="cut"

PASS=0
FAIL=0
ERRORS=()

normalize_gnu() {
    sed -e "s|$GNU|PROG|g" -e "s|Usage: $TOOL|Usage: PROG|g" -e "s|^$TOOL:|PROG:|g"
}

normalize_our() {
    sed -e "s|$BIN|PROG|g" -e "s|Usage: $TOOL|Usage: PROG|g" -e "s|^$TOOL:|PROG:|g"
}

run_test() {
    local desc="$1"
    shift
    local args=("$@")

    expected=$($GNU "${args[@]}" 2>&1 | normalize_gnu)
    expected_exit=$?
    got=$($BIN "${args[@]}" 2>&1 | normalize_our)
    got_exit=$?

    if [ "$expected" = "$got" ] && [ "$expected_exit" = "$got_exit" ]; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
        ERRORS+=("FAIL: $desc")
        if [ "$expected" != "$got" ]; then
            ERRORS+=("  expected output: $(echo "$expected" | head -3)")
            ERRORS+=("  got output:      $(echo "$got" | head -3)")
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

    expected=$(echo -e "$input" | $GNU "${args[@]}" 2>&1 | normalize_gnu)
    expected_exit=$?
    got=$(echo -e "$input" | $BIN "${args[@]}" 2>&1 | normalize_our)
    got_exit=$?

    if [ "$expected" = "$got" ] && [ "$expected_exit" = "$got_exit" ]; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
        ERRORS+=("FAIL: $desc")
        if [ "$expected" != "$got" ]; then
            ERRORS+=("  expected output: $(echo "$expected" | head -3)")
            ERRORS+=("  got output:      $(echo "$got" | head -3)")
        fi
        if [ "$expected_exit" != "$got_exit" ]; then
            ERRORS+=("  expected exit: $expected_exit, got: $got_exit")
        fi
    fi
}

# ── Setup temp files ─────────────────────────────────────────
TMPDIR=$(mktemp -d /tmp/cut_test.XXXXXX)
trap "rm -rf $TMPDIR" EXIT

printf "a:b:c\nd:e:f\ng:h:i\n" > "$TMPDIR/colon.txt"
printf "one\ttwo\tthree\nfour\tfive\tsix\n" > "$TMPDIR/tab.txt"
echo -n "" > "$TMPDIR/empty.txt"

# ── Standard flags ───────────────────────────────────────────
run_test "--help output" --help
run_test "--version output" --version

# ── Field extraction with delimiter ──────────────────────────
run_test_stdin "-d: -f2 (second field)" "a:b:c\nd:e:f" -d: -f2
run_test_stdin "-d: -f1 (first field)" "a:b:c\nd:e:f" -d: -f1
run_test_stdin "-d: -f3 (third field)" "a:b:c\nd:e:f" -d: -f3

# ── Multiple fields ──────────────────────────────────────────
run_test_stdin "-d: -f1,3 (fields 1 and 3)" "a:b:c\nd:e:f" -d: -f1,3
run_test_stdin "-d: -f1,2 (fields 1 and 2)" "a:b:c\nd:e:f" -d: -f1,2

# ── Field range ──────────────────────────────────────────────
run_test_stdin "-d: -f2- (field 2 onwards)" "a:b:c\nd:e:f" -d: -f2-
run_test_stdin "-d: -f-2 (up to field 2)" "a:b:c\nd:e:f" -d: -f-2
run_test_stdin "-d: -f2-3 (fields 2 to 3)" "a:b:c:d\ne:f:g:h" -d: -f2-3

# ── Character range ──────────────────────────────────────────
run_test_stdin "-c1-5 (chars 1-5)" "hello world\nfoo bar" -c1-5
run_test_stdin "-c1 (first char)" "hello\nworld" -c1
run_test_stdin "-c3- (char 3 onwards)" "hello\nworld" -c3-

# ── Byte range ───────────────────────────────────────────────
run_test_stdin "-b1-5 (bytes 1-5)" "hello world\nfoo bar" -b1-5
run_test_stdin "-b1 (first byte)" "hello\nworld" -b1
run_test_stdin "-b3- (byte 3 onwards)" "hello\nworld" -b3-

# ── Complement ───────────────────────────────────────────────
run_test_stdin "--complement -d: -f2" "a:b:c\nd:e:f" -d: --complement -f2
run_test_stdin "--complement -c1-3" "hello\nworld" --complement -c1-3

# ── Tab delimiter (default) ──────────────────────────────────
run_test_stdin "tab delimiter -f2" "one\ttwo\tthree\nfour\tfive\tsix" -f2
run_test_stdin "tab delimiter -f1,3" "one\ttwo\tthree\nfour\tfive\tsix" -f1,3

# ── File arguments ───────────────────────────────────────────
run_test "file with colon delimiter" -d: -f2 "$TMPDIR/colon.txt"
run_test "file with tab delimiter" -f2 "$TMPDIR/tab.txt"

# ── Empty input ──────────────────────────────────────────────
run_test_stdin "empty stdin" "" -d: -f1
run_test "empty file" -d: -f1 "$TMPDIR/empty.txt"

# ── Lines without delimiter (pass through by default) ────────
run_test_stdin "line without delimiter" "no_delimiter_here\na:b:c" -d: -f2

# ── -s (only-delimited) ─────────────────────────────────────
run_test_stdin "-s suppress lines without delimiter" "no_delimiter\na:b:c" -d: -f2 -s

# ── Results ──────────────────────────────────────────────────
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
