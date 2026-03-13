#!/bin/bash
# Test suite for fexpr
# Usage: bash tests/run_tests.sh ./fexpr

BIN="${1:-./fexpr}"
GNU="expr"
PASS=0
FAIL=0
ERRORS=()
TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT

run_test() {
    local desc="$1"
    shift
    local args=("$@")

    $GNU "${args[@]}" > "$TMPDIR/expected" 2>/dev/null
    local expected_exit=$?
    $BIN "${args[@]}" > "$TMPDIR/got" 2>/dev/null
    local got_exit=$?

    local expected=$(cat "$TMPDIR/expected")
    local got=$(cat "$TMPDIR/got")

    if [ "$expected" = "$got" ] && [ "$expected_exit" = "$got_exit" ]; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
        ERRORS+=("FAIL: $desc")
        if [ "$expected" != "$got" ]; then
            ERRORS+=("  expected stdout: '$expected'")
            ERRORS+=("  got stdout:      '$got'")
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
        ERRORS+=("FAIL: $desc — expected exit: $expected_exit, got: $got_exit")
    fi
}

# ── Standard flags ──
run_test_exit_only "--help exit code" --help
run_test_exit_only "--version exit code" --version

# ── Arithmetic ──
run_test "addition" 1 + 1
run_test "subtraction" 10 - 3
run_test "multiplication" 3 '*' 4
run_test "division" 10 / 3
run_test "modulo" 10 % 3
run_test "negative result" 1 - 5
run_test "large addition" 1000000 + 999999

# ── Comparison ──
run_test "equal true" 5 = 5
run_test "equal false" 5 = 6
run_test "not-equal true" 5 != 6
run_test "not-equal false" 5 != 5
run_test "less-than true" 3 '<' 5
run_test "less-than false" 5 '<' 3
run_test "greater-than true" 5 '>' 3
run_test "greater-than false" 3 '>' 5
run_test "le true" 3 '<=' 5
run_test "le equal" 5 '<=' 5
run_test "ge true" 5 '>=' 3
run_test "ge equal" 5 '>=' 5

# ── String operations ──
run_test "length" length hello
run_test "length empty" length ""
run_test "index found" index hello l
run_test "index not found" index hello z
run_test "substr" substr hello 2 3

# ── Logical ──
run_test "or first nonzero" 5 '|' 0
run_test "or second nonzero" 0 '|' 3
run_test "and both nonzero" 5 '&' 3
run_test "and one zero" 5 '&' 0

# ── Parentheses ──
run_test "parens" '(' 2 + 3 ')' '*' 4

# ── String values ──
run_test "string value" hello
run_test "empty string" ""

# ── Exit codes ──
run_test_exit_only "nonzero exit 0" 1
run_test_exit_only "zero exit 1" 0
run_test_exit_only "empty exit 1" ""

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
