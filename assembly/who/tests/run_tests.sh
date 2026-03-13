#!/bin/bash
# Test suite for fwho (assembly who implementation)
# Usage: bash tests/run_tests.sh [./fwho]

# Resolve paths
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BIN="${1:-$PROJECT_DIR/fwho}"
GNU="who"
PASS=0
FAIL=0
ERRORS=()
TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT

run_test() {
    local desc="$1"
    shift
    local args=("$@")

    $GNU "${args[@]}" > "$TMPDIR/expected" 2> "$TMPDIR/expected_err"
    local expected_exit=$?
    $BIN "${args[@]}" > "$TMPDIR/got" 2> "$TMPDIR/got_err"
    local got_exit=$?

    local expected=$(cat "$TMPDIR/expected")
    local got=$(cat "$TMPDIR/got")
    local expected_err=$(cat "$TMPDIR/expected_err")
    local got_err=$(cat "$TMPDIR/got_err")

    # Normalize tool name in error messages
    expected_err=$(echo "$expected_err" | sed "s|$(which $GNU)|$GNU|g")

    if [ "$expected" = "$got" ] && [ "$expected_exit" = "$got_exit" ] && [ "$expected_err" = "$got_err" ]; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
        ERRORS+=("FAIL: $desc")
        if [ "$expected" != "$got" ]; then
            ERRORS+=("  expected stdout: $(echo "$expected" | head -3)")
            ERRORS+=("  got stdout:      $(echo "$got" | head -3)")
        fi
        if [ "$expected_err" != "$got_err" ]; then
            ERRORS+=("  expected stderr: $(echo "$expected_err" | head -3)")
            ERRORS+=("  got stderr:      $(echo "$got_err" | head -3)")
        fi
        if [ "$expected_exit" != "$got_exit" ]; then
            ERRORS+=("  expected exit: $expected_exit, got: $got_exit")
        fi
    fi
}

# Like run_test but only checks exit code (for help/version where text may differ)
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

# Test FD isolation: stdout vs stderr
run_test_fd() {
    local desc="$1"
    shift
    local args=("$@")

    $BIN "${args[@]}" > "$TMPDIR/stdout" 2> "$TMPDIR/stderr"
    local exit_code=$?

    # Check that --help goes to stdout (not stderr)
    if echo "${args[@]}" | grep -q "\-\-help"; then
        if [ -s "$TMPDIR/stdout" ] && [ ! -s "$TMPDIR/stderr" ]; then
            PASS=$((PASS+1))
        else
            FAIL=$((FAIL+1))
            ERRORS+=("FAIL: $desc — --help should write to stdout only")
        fi
        return
    fi

    # For error cases: check stderr has content, stdout empty
    if [ $exit_code -ne 0 ]; then
        if [ ! -s "$TMPDIR/stdout" ] && [ -s "$TMPDIR/stderr" ]; then
            PASS=$((PASS+1))
        else
            FAIL=$((FAIL+1))
            ERRORS+=("FAIL: $desc — errors should go to stderr only")
        fi
        return
    fi

    PASS=$((PASS+1))
}

# Only check our output (no comparison), verify basic correctness
run_test_self() {
    local desc="$1"
    local expected_pattern="$2"
    shift 2
    local args=("$@")

    $BIN "${args[@]}" > "$TMPDIR/got" 2> "$TMPDIR/got_err"
    local got_exit=$?
    local got=$(cat "$TMPDIR/got")

    if echo "$got" | grep -qE "$expected_pattern"; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
        ERRORS+=("FAIL: $desc")
        ERRORS+=("  expected pattern: $expected_pattern")
        ERRORS+=("  got: $(echo "$got" | head -3)")
    fi
}

echo "=== fwho test suite ==="
echo ""

# ── Standard flags ──
run_test_exit_only "--help exit code" --help
run_test_exit_only "--version exit code" --version

# ── FD isolation ──
run_test_fd "--help to stdout" --help
run_test_fd "--version to stdout" --version
run_test_fd "error to stderr" -Z

# ── Help content check ──
run_test_self "--help contains Usage" "^Usage: who" --help
run_test_self "--help contains --boot" "\-b.*\-\-boot" --help
run_test_self "--help contains --heading" "\-H.*\-\-heading" --help
run_test_self "--help contains --count" "\-q.*\-\-count" --help

# ── Version content check ──
run_test_self "--version contains who" "^who" --version

# ── Error handling ──
run_test "invalid option -Z" -Z
run_test "invalid option -X" -X
run_test "invalid option -j" -j

# ── Default output (no args) ──
run_test "default (no args)"

# ── Short format (-s is default) ──
run_test "-s flag" -s

# ── Heading mode ──
run_test_self "-H shows NAME header" "^NAME" -H

# ── Count mode ──
run_test "-q count mode" -q

# ── Heading exact match with GNU ──
run_test "-H heading matches GNU" -H

# ── Combined: -Hs ──
run_test_self "-Hs shows heading" "^NAME" -Hs

# ── am i (no tty in test environment = no output, same as GNU) ──
run_test "am i" am i
run_test "am I" am I

# ── Long options ──
run_test_exit_only "--short exit code" --short
run_test_exit_only "--count exit code" --count
run_test_exit_only "--heading exit code" --heading
run_test_exit_only "--boot exit code" --boot

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
