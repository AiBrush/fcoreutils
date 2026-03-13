#!/bin/bash
# Test suite for fvdir (assembly vdir)
# Usage: bash tests/run_tests.sh ./fvdir

BIN="${1:-./fvdir}"
GNU="vdir"
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

run_test_names() {
    local desc="$1"
    shift
    local args=("$@")

    # Extract just filenames from long format (last field)
    $GNU "${args[@]}" 2>/dev/null | tail -n +2 | awk '{print $NF}' | sort > "$TMPDIR/expected_names"
    $BIN "${args[@]}" 2>/dev/null | tail -n +2 | awk '{print $NF}' | sort > "$TMPDIR/got_names"

    local expected=$(cat "$TMPDIR/expected_names")
    local got=$(cat "$TMPDIR/got_names")

    if [ "$expected" = "$got" ]; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
        ERRORS+=("FAIL: $desc")
        ERRORS+=("  expected: $(echo "$expected" | head -5)")
        ERRORS+=("  got:      $(echo "$got" | head -5)")
    fi
}

# ── Setup ──
mkdir -p "$TMPDIR/testdir/subdir"
echo "hello" > "$TMPDIR/testdir/file1.txt"
echo "world" > "$TMPDIR/testdir/file2.txt"
touch "$TMPDIR/testdir/.hidden"

# ── Standard flags ──
run_test_exit_only "--help exit code" --help
run_test_exit_only "--version exit code" --version

# ── vdir default is long format ──
run_test_exit_only "default listing" "$TMPDIR/testdir"

# Check that default output starts with "total"
$BIN "$TMPDIR/testdir" > "$TMPDIR/vdir_out" 2>/dev/null
if head -1 "$TMPDIR/vdir_out" | grep -q "^total"; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: vdir default should start with 'total' line")
fi

# ── Names match ──
run_test_names "names in testdir" "$TMPDIR/testdir"
run_test_names "-a names" -a "$TMPDIR/testdir"

# ── Non-existent ──
run_test_exit_only "nonexistent" "$TMPDIR/nonexistent_$$"

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
