#!/bin/bash
# Test suite for fchmod (assembly chmod)
# Usage: bash tests/run_tests.sh ./fchmod

BIN="$(realpath "${1:-./fchmod}")"
GNU="chmod"
PASS=0
FAIL=0
ERRORS=()
TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT

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

check_mode() {
    local desc="$1"
    local file="$2"
    local expected="$3"
    local got
    got=$(stat -c '%a' "$file" 2>/dev/null)
    if [ "$expected" = "$got" ]; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
        ERRORS+=("FAIL: $desc — expected perms $expected, got $got")
    fi
}

# ── Standard flags ──
run_test_exit_only "--help exit code" --help
run_test_exit_only "--version exit code" --version

# ── Octal mode changes ──
touch "$TMPDIR/f1" && chmod 644 "$TMPDIR/f1"
$BIN 755 "$TMPDIR/f1" 2>/dev/null
check_mode "chmod 755" "$TMPDIR/f1" "755"

touch "$TMPDIR/f2" && chmod 755 "$TMPDIR/f2"
$BIN 644 "$TMPDIR/f2" 2>/dev/null
check_mode "chmod 644" "$TMPDIR/f2" "644"

touch "$TMPDIR/f3" && chmod 644 "$TMPDIR/f3"
$BIN 600 "$TMPDIR/f3" 2>/dev/null
check_mode "chmod 600" "$TMPDIR/f3" "600"

touch "$TMPDIR/f4" && chmod 644 "$TMPDIR/f4"
$BIN 777 "$TMPDIR/f4" 2>/dev/null
check_mode "chmod 777" "$TMPDIR/f4" "777"

touch "$TMPDIR/f5" && chmod 777 "$TMPDIR/f5"
$BIN 000 "$TMPDIR/f5" 2>/dev/null
check_mode "chmod 000" "$TMPDIR/f5" "0"

# ── Missing operand ──
$BIN 2>/dev/null
rc=$?
if [ "$rc" -ne 0 ]; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: missing operand — expected nonzero exit, got 0")
fi

# ── Nonexistent file ──
$BIN 644 "$TMPDIR/nonexistent_$$" 2>/dev/null
rc=$?
if [ "$rc" -ne 0 ]; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: nonexistent file — expected nonzero exit, got 0")
fi

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
