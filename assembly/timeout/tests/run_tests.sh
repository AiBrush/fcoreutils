#!/bin/bash
# Test suite for ftimeout
# Usage: bash tests/run_tests.sh ./ftimeout

BIN="${1:-./ftimeout}"
GNU="timeout"
PASS=0
FAIL=0
ERRORS=()

run_test() {
    local desc="$1"
    shift
    local timeout_val="${1:-10}"
    shift

    timeout "$timeout_val" $GNU "$@" > /tmp/to_gnu_out 2>/tmp/to_gnu_err
    local expected_exit=$?
    local expected=$(cat /tmp/to_gnu_out)

    timeout "$timeout_val" $BIN "$@" > /tmp/to_asm_out 2>/tmp/to_asm_err
    local got_exit=$?
    local got=$(cat /tmp/to_asm_out)

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

# ── Basic: command completes before timeout ──────────────────
run_test "true completes" 5 5 true
run_test "false completes" 5 5 false
run_test "echo completes" 5 5 echo hello

# ── Timeout fires ────────────────────────────────────────────
desc="timeout fires (sleep killed)"
start=$(date +%s)
$BIN 1 sleep 10 2>/dev/null
got_exit=$?
end=$(date +%s)
elapsed=$((end - start))
if [ "$got_exit" = "124" ] && [ "$elapsed" -le 3 ]; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: $desc (exit=$got_exit, elapsed=${elapsed}s)")
fi

# ── Exit code passthrough ────────────────────────────────────
desc="exit code passthrough (false -> 1)"
$BIN 5 false 2>/dev/null
got_exit=$?
if [ "$got_exit" = "1" ]; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: $desc (got exit=$got_exit)")
fi

desc="exit code passthrough (true -> 0)"
$BIN 5 true 2>/dev/null
got_exit=$?
if [ "$got_exit" = "0" ]; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: $desc (got exit=$got_exit)")
fi

# ── Nonexistent command ──────────────────────────────────────
desc="nonexistent command -> 127"
$BIN 5 nonexistent_cmd_xyz 2>/dev/null
got_exit=$?
$GNU 5 nonexistent_cmd_xyz 2>/dev/null
exp_exit=$?
if [ "$got_exit" = "$exp_exit" ]; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: $desc (expected=$exp_exit, got=$got_exit)")
fi

# ── --help and --version ─────────────────────────────────────
desc="--help exit 0"
$BIN --help > /dev/null 2>&1
got_exit=$?
if [ "$got_exit" = "0" ]; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: $desc (exit=$got_exit)")
fi

desc="--version exit 0"
$BIN --version > /dev/null 2>&1
got_exit=$?
if [ "$got_exit" = "0" ]; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: $desc (exit=$got_exit)")
fi

# ── Missing operand ──────────────────────────────────────────
desc="missing operand -> 125"
$BIN 2>/dev/null
got_exit=$?
if [ "$got_exit" = "125" ]; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: $desc (exit=$got_exit)")
fi

# ── -s signal option ─────────────────────────────────────────
desc="-s KILL signal"
$BIN -s KILL 1 sleep 10 2>/dev/null
got_exit=$?
# Should be 137 (128+9) or 124
if [ "$got_exit" = "137" ] || [ "$got_exit" = "124" ]; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: $desc (exit=$got_exit)")
fi

# ── --foreground option ──────────────────────────────────────
desc="--foreground option"
$BIN --foreground 1 sleep 10 2>/dev/null
got_exit=$?
if [ "$got_exit" = "124" ]; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: $desc (exit=$got_exit)")
fi

# ── Echo output preserved ────────────────────────────────────
desc="echo output preserved"
expected=$($GNU 5 echo "test output" 2>/dev/null)
got=$($BIN 5 echo "test output" 2>/dev/null)
if [ "$expected" = "$got" ]; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: $desc")
    ERRORS+=("  expected: $expected")
    ERRORS+=("  got: $got")
fi

# ── Absolute path command ────────────────────────────────────
desc="absolute path /bin/echo"
expected=$($GNU 5 /bin/echo abc 2>/dev/null)
got=$($BIN 5 /bin/echo abc 2>/dev/null)
if [ "$expected" = "$got" ]; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: $desc")
    ERRORS+=("  expected: $expected")
    ERRORS+=("  got: $got")
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
