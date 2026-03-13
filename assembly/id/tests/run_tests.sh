#!/bin/bash
# Test suite for fid
# Usage: bash tests/run_tests.sh ./fid

BIN="${1:-./fid}"
GNU="id"
PASS=0
FAIL=0
ERRORS=()

run_test() {
    local desc="$1"
    shift
    local args=("$@")

    expected=$($GNU "${args[@]}" 2>&1)
    expected_exit=$?
    got=$($BIN "${args[@]}" 2>&1)
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

# ── Core id behavior ──
run_test "basic id (no args)"
run_test "-u (effective uid)" -u
run_test "-g (effective gid)" -g
run_test "-G (all groups)" -G
run_test "-un (effective username)" -un
run_test "-gn (effective group name)" -gn
run_test "-Gn (all group names)" -Gn
run_test "-ur (real uid)" -ur
run_test "-gr (real gid)" -gr
run_test "-urn (real username)" -urn
run_test "-grn (real group name)" -grn

# ── With username ──
CURRENT_USER=$(whoami)
run_test "id USER" "$CURRENT_USER"
run_test "id -u USER" -u "$CURRENT_USER"
run_test "id -g USER" -g "$CURRENT_USER"
run_test "id -G USER" -G "$CURRENT_USER"
run_test "id -un USER" -un "$CURRENT_USER"
run_test "id -gn USER" -gn "$CURRENT_USER"

# ── Error cases ──
run_test_exit_only "nonexistent user" nonexistent_user_xyz_12345

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
