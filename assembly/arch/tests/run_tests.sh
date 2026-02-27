#!/bin/bash
# Test suite for farch
# Usage: bash tests/run_tests.sh ./farch

BIN="${1:-./farch}"
GNU="arch"
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

# ── Standard flags (required for ALL tools) ──────────────────
run_test "no arguments"
run_test "--help output"      --help
run_test "--version output"   --version
run_test "invalid long flag"  --invalid-flag-xyz

# ── Error handling tests ─────────────────────────────────────
run_test "invalid short flag -x"    -x
run_test "invalid short flag -a"    -a
run_test "extra operand 'foo'"      foo
run_test "extra operand 'bar'"      bar
run_test "double dash only"         --
run_test "double dash with arg"     -- foo

# ── Verify output goes to correct fd ─────────────────────────
# Help should be on stdout
help_stdout=$($BIN --help 2>/dev/null)
help_stderr=$($BIN --help 2>&1 >/dev/null)
if [ -n "$help_stdout" ] && [ -z "$help_stderr" ]; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: --help should write to stdout only")
fi

# Version should be on stdout
ver_stdout=$($BIN --version 2>/dev/null)
ver_stderr=$($BIN --version 2>&1 >/dev/null)
if [ -n "$ver_stdout" ] && [ -z "$ver_stderr" ]; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: --version should write to stdout only")
fi

# Error should be on stderr
err_stdout=$($BIN --badarg 2>/dev/null)
err_stderr=$($BIN --badarg 2>&1 >/dev/null)
if [ -z "$err_stdout" ] && [ -n "$err_stderr" ]; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: errors should write to stderr only")
fi

# ── Verify output matches uname -m ──────────────────────────
uname_output=$(uname -m)
arch_output=$($BIN)
if [ "$uname_output" = "$arch_output" ]; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: output should match uname -m")
    ERRORS+=("  uname -m: $uname_output")
    ERRORS+=("  farch:    $arch_output")
fi

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
