#!/bin/bash
# Test suite for fnice
# Usage: bash tests/run_tests.sh ./fnice

BIN="${1:-./fnice}"
GNU="nice"
PASS=0
FAIL=0
ERRORS=()

run_test() {
    local desc="$1"
    local args="$2"
    local input="$3"
    local timeout_val="${4:-10}"

    if [ -n "$input" ]; then
        expected=$(echo "$input" | timeout "$timeout_val" $GNU $args 2>&1)
        expected_exit=$?
        got=$(echo "$input" | timeout "$timeout_val" $BIN $args 2>&1)
        got_exit=$?
    else
        expected=$(timeout "$timeout_val" $GNU $args 2>&1)
        expected_exit=$?
        got=$(timeout "$timeout_val" $BIN $args 2>&1)
        got_exit=$?
    fi

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

# ── No command: print current niceness ──────────────────────
run_test "no arguments (print niceness)" "" ""

# ── Run a simple command ───────────────────────────────────
desc="run true with default adjustment"
expected=$(timeout 5 $GNU true 2>&1)
expected_exit=$?
got=$(timeout 5 $BIN true 2>&1)
got_exit=$?
if [ "$expected_exit" = "$got_exit" ]; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: $desc")
    ERRORS+=("  expected exit: $expected_exit, got: $got_exit")
fi

# ── Run command with -n adjustment ─────────────────────────
desc="run echo with -n 5"
expected=$(timeout 5 $GNU -n 5 echo hello 2>&1)
expected_exit=$?
got=$(timeout 5 $BIN -n 5 echo hello 2>&1)
got_exit=$?
if [ "$expected" = "$got" ] && [ "$expected_exit" = "$got_exit" ]; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: $desc")
    if [ "$expected" != "$got" ]; then
        ERRORS+=("  expected output: $expected")
        ERRORS+=("  got output:      $got")
    fi
    if [ "$expected_exit" != "$got_exit" ]; then
        ERRORS+=("  expected exit: $expected_exit, got: $got_exit")
    fi
fi

# ── Run command with --adjustment= ─────────────────────────
desc="run echo with --adjustment=5"
expected=$(timeout 5 $GNU --adjustment=5 echo world 2>&1)
expected_exit=$?
got=$(timeout 5 $BIN --adjustment=5 echo world 2>&1)
got_exit=$?
if [ "$expected" = "$got" ] && [ "$expected_exit" = "$got_exit" ]; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: $desc")
    if [ "$expected" != "$got" ]; then
        ERRORS+=("  expected output: $expected")
        ERRORS+=("  got output:      $got")
    fi
    if [ "$expected_exit" != "$got_exit" ]; then
        ERRORS+=("  expected exit: $expected_exit, got: $got_exit")
    fi
fi

# ── Run command with -n 0 ─────────────────────────────────
desc="run echo with -n 0"
expected=$(timeout 5 $GNU -n 0 echo zero 2>&1)
expected_exit=$?
got=$(timeout 5 $BIN -n 0 echo zero 2>&1)
got_exit=$?
if [ "$expected" = "$got" ] && [ "$expected_exit" = "$got_exit" ]; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: $desc")
    if [ "$expected" != "$got" ]; then
        ERRORS+=("  expected output: $expected")
        ERRORS+=("  got output:      $got")
    fi
    if [ "$expected_exit" != "$got_exit" ]; then
        ERRORS+=("  expected exit: $expected_exit, got: $got_exit")
    fi
fi

# ── Nonexistent command ────────────────────────────────────
desc="nonexistent command"
expected_exit=0
timeout 5 $GNU nonexistent_cmd_xyz 2>/dev/null
expected_exit=$?
timeout 5 $BIN nonexistent_cmd_xyz 2>/dev/null
got_exit=$?
if [ "$expected_exit" = "$got_exit" ]; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: $desc")
    ERRORS+=("  expected exit: $expected_exit, got: $got_exit")
fi

# ── Run /bin/echo directly (absolute path) ──────────────────
desc="run /bin/echo (absolute path)"
expected=$(timeout 5 $GNU /bin/echo test 2>&1)
expected_exit=$?
got=$(timeout 5 $BIN /bin/echo test 2>&1)
got_exit=$?
if [ "$expected" = "$got" ] && [ "$expected_exit" = "$got_exit" ]; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: $desc")
    if [ "$expected" != "$got" ]; then
        ERRORS+=("  expected output: $expected")
        ERRORS+=("  got output:      $got")
    fi
    if [ "$expected_exit" != "$got_exit" ]; then
        ERRORS+=("  expected exit: $expected_exit, got: $got_exit")
    fi
fi

# ── Double dash separator ──────────────────────────────────
desc="double dash separator"
expected=$(timeout 5 $GNU -- echo dashes 2>&1)
expected_exit=$?
got=$(timeout 5 $BIN -- echo dashes 2>&1)
got_exit=$?
if [ "$expected" = "$got" ] && [ "$expected_exit" = "$got_exit" ]; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: $desc")
    if [ "$expected" != "$got" ]; then
        ERRORS+=("  expected output: $expected")
        ERRORS+=("  got output:      $got")
    fi
    if [ "$expected_exit" != "$got_exit" ]; then
        ERRORS+=("  expected exit: $expected_exit, got: $got_exit")
    fi
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
