#!/bin/bash
# Test suite for ftest
# Usage: bash tests/run_tests.sh ./ftest

BIN="${1:-./ftest}"
GNU="test"
PASS=0
FAIL=0
ERRORS=()
TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT

run_test() {
    local desc="$1"
    shift
    local args=("$@")

    $GNU "${args[@]}" > /dev/null 2>/dev/null
    local expected_exit=$?
    $BIN "${args[@]}" > /dev/null 2>/dev/null
    local got_exit=$?

    if [ "$expected_exit" = "$got_exit" ]; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
        ERRORS+=("FAIL: $desc — expected exit: $expected_exit, got: $got_exit")
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
        ERRORS+=("FAIL: $desc — expected exit: $expected_exit, got: $got_exit")
    fi
}

# ── Standard flags ──
run_test_exit_only "--help exit code" --help
run_test_exit_only "--version exit code" --version

# ── No arguments = false ──
run_test "no args"

# ── File tests ──
touch "$TMPDIR/exists"
mkdir "$TMPDIR/dir"
echo "content" > "$TMPDIR/nonempty"
touch "$TMPDIR/empty"
ln -s "$TMPDIR/exists" "$TMPDIR/link"
chmod 755 "$TMPDIR/exists"

run_test "-e exists" -e "$TMPDIR/exists"
run_test "-e nonexistent" -e "$TMPDIR/nonexistent"
run_test "-f regular" -f "$TMPDIR/exists"
run_test "-f directory" -f "$TMPDIR/dir"
run_test "-d directory" -d "$TMPDIR/dir"
run_test "-d regular" -d "$TMPDIR/exists"
run_test "-r readable" -r "$TMPDIR/exists"
run_test "-w writable" -w "$TMPDIR/exists"
run_test "-x executable" -x "$TMPDIR/exists"
run_test "-s nonempty" -s "$TMPDIR/nonempty"
run_test "-s empty" -s "$TMPDIR/empty"
run_test "-L symlink" -L "$TMPDIR/link"
run_test "-L regular" -L "$TMPDIR/exists"
run_test "-h symlink" -h "$TMPDIR/link"

# ── String tests ──
run_test "-n nonempty" -n "hello"
run_test "-n empty" -n ""
run_test "-z empty" -z ""
run_test "-z nonempty" -z "hello"
run_test "= equal" "hello" = "hello"
run_test "= not equal" "hello" = "world"
run_test "!= not equal" "hello" != "world"
run_test "!= equal" "hello" != "hello"
run_test "bare string true" "hello"
run_test "bare string empty" ""

# ── Integer tests ──
run_test "-eq equal" 5 -eq 5
run_test "-eq not equal" 5 -eq 6
run_test "-ne not equal" 5 -ne 6
run_test "-ne equal" 5 -ne 5
run_test "-lt true" 3 -lt 5
run_test "-lt false" 5 -lt 3
run_test "-le true" 3 -le 5
run_test "-le equal" 5 -le 5
run_test "-gt true" 5 -gt 3
run_test "-gt false" 3 -gt 5
run_test "-ge true" 5 -ge 3
run_test "-ge equal" 5 -ge 5

# ── Negative numbers ──
run_test "-eq negative" -1 -eq -1
run_test "-lt negative" -5 -lt 0

# ── Logic ──
run_test "NOT true" "!" -e "$TMPDIR/nonexistent"
run_test "NOT false" "!" -e "$TMPDIR/exists"
run_test "AND true" -e "$TMPDIR/exists" -a -d "$TMPDIR/dir"
run_test "AND false" -e "$TMPDIR/exists" -a -e "$TMPDIR/nonexistent"
run_test "OR true" -e "$TMPDIR/nonexistent" -o -e "$TMPDIR/exists"
run_test "OR false" -e "$TMPDIR/nonexistent" -o -e "$TMPDIR/also_nonexistent"

# ── File comparisons ──
touch "$TMPDIR/newer"
sleep 1
touch "$TMPDIR/oldest"
# Note: touch order means 'oldest' is actually newer, so we need to reverse
touch -t 202001010000 "$TMPDIR/older_file"
run_test "-ef same file" "$TMPDIR/exists" -ef "$TMPDIR/exists"
run_test "-ef diff files" "$TMPDIR/exists" -ef "$TMPDIR/dir"

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
