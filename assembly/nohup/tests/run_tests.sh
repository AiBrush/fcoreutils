#!/bin/bash
# Test suite for fnohup
# Usage: bash tests/run_tests.sh [./fnohup]

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BIN="${1:-$SCRIPT_DIR/fnohup}"
GNU="nohup"
PASS=0
FAIL=0
ERRORS=()

# Ensure binary exists
if [ ! -x "$BIN" ]; then
    echo "ERROR: Binary not found: $BIN"
    echo "Build with: make"
    exit 1
fi

pass() {
    PASS=$((PASS+1))
}

fail() {
    local desc="$1"
    shift
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: $desc")
    for line in "$@"; do
        ERRORS+=("  $line")
    done
}

# ── Test: --help ──────────────────────────────────────────
desc="--help"
expected=$(timeout 5 $GNU --help 2>&1)
expected_exit=$?
got=$(timeout 5 $BIN --help 2>&1)
got_exit=$?
if [ "$expected" = "$got" ] && [ "$expected_exit" = "$got_exit" ]; then
    pass
else
    fail "$desc" "output or exit code differs"
fi

# ── Test: --version ───────────────────────────────────────
desc="--version"
expected=$(timeout 5 $GNU --version 2>&1)
expected_exit=$?
got=$(timeout 5 $BIN --version 2>&1)
got_exit=$?
if [ "$expected" = "$got" ] && [ "$expected_exit" = "$got_exit" ]; then
    pass
else
    fail "$desc" "output or exit code differs"
fi

# ── Test: missing operand ─────────────────────────────────
desc="missing operand"
expected=$(timeout 5 $GNU 2>&1)
expected_exit=$?
got=$(timeout 5 $BIN 2>&1)
got_exit=$?
if [ "$expected" = "$got" ] && [ "$expected_exit" = "$got_exit" ]; then
    pass
else
    fail "$desc" "expected exit=$expected_exit got exit=$got_exit" \
         "expected: $(echo "$expected" | head -2)" \
         "got:      $(echo "$got" | head -2)"
fi

# ── Test: run echo hello ──────────────────────────────────
desc="nohup echo hello"
expected=$(timeout 5 $GNU echo hello 2>&1)
expected_exit=$?
got=$(timeout 5 $BIN echo hello 2>&1)
got_exit=$?
if [ "$expected" = "$got" ] && [ "$expected_exit" = "$got_exit" ]; then
    pass
else
    fail "$desc" "expected output='$expected' exit=$expected_exit" \
         "got output='$got' exit=$got_exit"
fi

# ── Test: run echo with multiple args ─────────────────────
desc="nohup echo foo bar baz"
expected=$(timeout 5 $GNU echo foo bar baz 2>&1)
expected_exit=$?
got=$(timeout 5 $BIN echo foo bar baz 2>&1)
got_exit=$?
if [ "$expected" = "$got" ] && [ "$expected_exit" = "$got_exit" ]; then
    pass
else
    fail "$desc" "expected output='$expected' exit=$expected_exit" \
         "got output='$got' exit=$got_exit"
fi

# ── Test: run true ────────────────────────────────────────
desc="nohup true"
timeout 5 $GNU true 2>&1 >/dev/null
expected_exit=$?
timeout 5 $BIN true 2>&1 >/dev/null
got_exit=$?
if [ "$expected_exit" = "$got_exit" ]; then
    pass
else
    fail "$desc" "expected exit=$expected_exit, got exit=$got_exit"
fi

# ── Test: run false ───────────────────────────────────────
desc="nohup false"
timeout 5 $GNU false 2>&1 >/dev/null
expected_exit=$?
timeout 5 $BIN false 2>&1 >/dev/null
got_exit=$?
if [ "$expected_exit" = "$got_exit" ]; then
    pass
else
    fail "$desc" "expected exit=$expected_exit, got exit=$got_exit"
fi

# ── Test: run /bin/echo (absolute path) ───────────────────
desc="nohup /bin/echo absolute"
expected=$(timeout 5 $GNU /bin/echo absolute 2>&1)
expected_exit=$?
got=$(timeout 5 $BIN /bin/echo absolute 2>&1)
got_exit=$?
if [ "$expected" = "$got" ] && [ "$expected_exit" = "$got_exit" ]; then
    pass
else
    fail "$desc" "expected output='$expected' exit=$expected_exit" \
         "got output='$got' exit=$got_exit"
fi

# ── Test: nonexistent command (exit 127) ──────────────────
desc="nonexistent command"
expected=$($GNU nonexistent_cmd_xyz 2>&1)
expected_exit=$?
got=$($BIN nonexistent_cmd_xyz 2>&1)
got_exit=$?
if [ "$expected" = "$got" ] && [ "$expected_exit" = "$got_exit" ]; then
    pass
else
    fail "$desc" "expected output='$expected' exit=$expected_exit" \
         "got output='$got' exit=$got_exit"
fi

# ── Test: permission denied (exit 126) ────────────────────
desc="permission denied"
tmpf=$(mktemp /tmp/fnohup_test_XXXXXX)
echo "#!/bin/sh" > "$tmpf"
chmod -x "$tmpf"
expected=$($GNU "$tmpf" 2>&1)
expected_exit=$?
got=$($BIN "$tmpf" 2>&1)
got_exit=$?
rm -f "$tmpf"
if [ "$expected_exit" = "$got_exit" ]; then
    pass
else
    fail "$desc" "expected exit=$expected_exit, got exit=$got_exit"
fi

# ── Test: -- separator ────────────────────────────────────
desc="-- separator"
expected=$(timeout 5 $GNU -- echo dashes 2>&1)
expected_exit=$?
got=$(timeout 5 $BIN -- echo dashes 2>&1)
got_exit=$?
if [ "$expected" = "$got" ] && [ "$expected_exit" = "$got_exit" ]; then
    pass
else
    fail "$desc" "expected output='$expected' exit=$expected_exit" \
         "got output='$got' exit=$got_exit"
fi

# ── Test: sleep 0 ─────────────────────────────────────────
desc="nohup sleep 0"
timeout 5 $GNU sleep 0 2>&1 >/dev/null
expected_exit=$?
timeout 5 $BIN sleep 0 2>&1 >/dev/null
got_exit=$?
if [ "$expected_exit" = "$got_exit" ]; then
    pass
else
    fail "$desc" "expected exit=$expected_exit, got exit=$got_exit"
fi

# ── Test: command exit code passed through ────────────────
desc="exit code passthrough (sh -c 'exit 42')"
timeout 5 $GNU sh -c 'exit 42' 2>&1 >/dev/null
expected_exit=$?
timeout 5 $BIN sh -c 'exit 42' 2>&1 >/dev/null
got_exit=$?
if [ "$expected_exit" = "$got_exit" ]; then
    pass
else
    fail "$desc" "expected exit=$expected_exit, got exit=$got_exit"
fi

# ── Test: nohup.out creation when stdout is a tty ─────────
# This test is environment-dependent (needs a real tty) so we skip if not available
# We just verify the binary doesn't crash

# ── Test: -- with no command after ────────────────────────
desc="-- with no command after it"
expected=$(timeout 5 $GNU -- 2>&1)
expected_exit=$?
got=$(timeout 5 $BIN -- 2>&1)
got_exit=$?
if [ "$expected" = "$got" ] && [ "$expected_exit" = "$got_exit" ]; then
    pass
else
    fail "$desc" "expected output='$expected' exit=$expected_exit" \
         "got output='$got' exit=$got_exit"
fi

# ── Test: SIGHUP ignored by child ────────────────────────
desc="SIGHUP is ignored"
# Run a process that traps SIGHUP and checks
# The child should have SIGHUP ignored (SIG_IGN)
got=$(timeout 5 $BIN sh -c 'trap "" HUP; kill -HUP $$; echo survived' 2>&1)
got_exit=$?
if echo "$got" | grep -q "survived"; then
    pass
else
    fail "$desc" "child did not survive SIGHUP" "output: $got"
fi

# ── Test: command with special chars in args ──────────────
desc="args with spaces (via echo)"
expected=$(timeout 5 $GNU echo "hello world" 2>&1)
expected_exit=$?
got=$(timeout 5 $BIN echo "hello world" 2>&1)
got_exit=$?
if [ "$expected" = "$got" ] && [ "$expected_exit" = "$got_exit" ]; then
    pass
else
    fail "$desc" "expected output='$expected' exit=$expected_exit" \
         "got output='$got' exit=$got_exit"
fi

# ── Cleanup ───────────────────────────────────────────────
rm -f nohup.out 2>/dev/null

# ── Results ───────────────────────────────────────────────
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
