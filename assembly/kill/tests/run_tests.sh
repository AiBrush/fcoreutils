#!/bin/bash
# Test suite for fkill (assembly)
# Usage: bash tests/run_tests.sh ./fkill_release
#
# Note: System 'kill' may be from procps-ng, not GNU coreutils.
# We test our binary's own behavior and basic signal functionality.

BIN="${1:-./fkill_release}"
PASS=0
FAIL=0
ERRORS=()
TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT

run_test() {
    local desc="$1"
    local expected_exit="$2"
    local expected_stdout="$3"  # regex or empty to skip stdout check
    local expected_stderr="$4"  # regex or empty to skip stderr check
    shift 4
    local args=("$@")

    $BIN "${args[@]}" > "$TMPDIR/got_out" 2> "$TMPDIR/got_err"
    local got_exit=$?
    local got_out=$(cat "$TMPDIR/got_out")
    local got_err=$(cat "$TMPDIR/got_err")

    local ok=1

    if [ "$expected_exit" != "" ] && [ "$expected_exit" != "$got_exit" ]; then
        ok=0
    fi

    if [ "$expected_stdout" != "" ] && ! echo "$got_out" | grep -qE "$expected_stdout"; then
        ok=0
    fi

    if [ "$expected_stderr" != "" ] && ! echo "$got_err" | grep -qE "$expected_stderr"; then
        ok=0
    fi

    if [ "$ok" = "1" ]; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
        ERRORS+=("FAIL: $desc")
        if [ "$expected_exit" != "" ] && [ "$expected_exit" != "$got_exit" ]; then
            ERRORS+=("  expected exit: $expected_exit, got: $got_exit")
        fi
        if [ "$expected_stdout" != "" ] && ! echo "$got_out" | grep -qE "$expected_stdout"; then
            ERRORS+=("  expected stdout matching: $expected_stdout")
            ERRORS+=("  got stdout: $(echo "$got_out" | head -3)")
        fi
        if [ "$expected_stderr" != "" ] && ! echo "$got_err" | grep -qE "$expected_stderr"; then
            ERRORS+=("  expected stderr matching: $expected_stderr")
            ERRORS+=("  got stderr: $(echo "$got_err" | head -3)")
        fi
    fi
}

# Test that sends a signal to a process and checks the result
run_signal_test() {
    local desc="$1"
    shift
    local args=("$@")

    # Start a background sleep process
    sleep 999 &
    local PID=$!

    # Send signal using our tool
    $BIN "${args[@]}" "$PID" > "$TMPDIR/sig_out" 2> "$TMPDIR/sig_err"
    local exit_code=$?
    sleep 0.1

    # Check if process was killed
    local alive=0
    if kill -0 "$PID" 2>/dev/null; then
        alive=1
        kill -9 "$PID" 2>/dev/null
    fi
    wait "$PID" 2>/dev/null

    if [ "$exit_code" = "0" ] && [ "$alive" = "0" ]; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
        ERRORS+=("FAIL: $desc (exit=$exit_code, alive=$alive)")
    fi
}

# Test that sends signal 0 (check if process exists)
run_signal0_test() {
    local desc="$1"
    local expect_exit="$2"
    shift 2
    local args=("$@")

    $BIN "${args[@]}" > "$TMPDIR/sig0_out" 2> "$TMPDIR/sig0_err"
    local exit_code=$?

    if [ "$exit_code" = "$expect_exit" ]; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
        ERRORS+=("FAIL: $desc (expected exit=$expect_exit, got=$exit_code)")
    fi
}

# ── FD isolation tests ──
run_fd_test() {
    local desc="$1"
    shift
    local args=("$@")

    $BIN "${args[@]}" > "$TMPDIR/fd_stdout" 2> "$TMPDIR/fd_stderr"
    local exit_code=$?

    # If success (--help, --version), output should be on stdout
    if [ $exit_code -eq 0 ]; then
        if [ -s "$TMPDIR/fd_stdout" ] && [ ! -s "$TMPDIR/fd_stderr" ]; then
            PASS=$((PASS+1))
        else
            FAIL=$((FAIL+1))
            ERRORS+=("FAIL: $desc — expected stdout only on success")
        fi
    else
        # On error, stderr should have content
        if [ -s "$TMPDIR/fd_stderr" ]; then
            PASS=$((PASS+1))
        else
            FAIL=$((FAIL+1))
            ERRORS+=("FAIL: $desc — expected stderr on error")
        fi
    fi
}

echo "=== fkill functional tests ==="
echo ""

# ── 1. Help and Version ──
echo "--- Help/Version ---"
run_test "--help exits 0" "0" "Usage: kill" "" --help
run_test "--help shows options" "0" "\-s SIGNAL" "" --help
run_test "--help shows -l" "0" "\-l" "" --help
run_test "--version exits 0" "0" "kill.*coreutils" "" --version
run_test "--version shows version number" "0" "9\." "" --version

# ── 2. FD isolation ──
echo "--- FD Isolation ---"
run_fd_test "--help to stdout" --help
run_fd_test "--version to stdout" --version
run_fd_test "error to stderr (no args)"

# ── 3. Signal listing: -l ──
echo "--- Signal Listing ---"
run_test "-l lists HUP" "0" "HUP" "" -l
run_test "-l lists INT" "0" "INT" "" -l
run_test "-l lists TERM" "0" "TERM" "" -l
run_test "-l lists KILL" "0" "KILL" "" -l
run_test "-l lists all 31 signals" "0" "31\) SYS" "" -l

# ── 4. Signal number to name: -l NUMBER ──
echo "--- Signal Number to Name ---"
run_test "-l 1 -> HUP" "0" "^HUP$" "" -l 1
run_test "-l 2 -> INT" "0" "^INT$" "" -l 2
run_test "-l 9 -> KILL" "0" "^KILL$" "" -l 9
run_test "-l 15 -> TERM" "0" "^TERM$" "" -l 15
run_test "-l 31 -> SYS" "0" "^SYS$" "" -l 31

# ── 5. Signal name to number: -l NAME ──
echo "--- Signal Name to Number ---"
run_test "-l HUP -> 1" "0" "^1$" "" -l HUP
run_test "-l INT -> 2" "0" "^2$" "" -l INT
run_test "-l KILL -> 9" "0" "^9$" "" -l KILL
run_test "-l TERM -> 15" "0" "^15$" "" -l TERM
run_test "-l SYS -> 31" "0" "^31$" "" -l SYS

# Case-insensitive
run_test "-l hup (lowercase) -> 1" "0" "^1$" "" -l hup
run_test "-l term (lowercase) -> 15" "0" "^15$" "" -l term

# With SIG prefix
run_test "-l SIGHUP -> 1" "0" "^1$" "" -l SIGHUP
run_test "-l SIGTERM -> 15" "0" "^15$" "" -l SIGTERM
run_test "-l sigterm (lowercase) -> 15" "0" "^15$" "" -l sigterm

# ── 6. Signal number with 128+ offset: -l 128+N ──
echo "--- 128+N Signal Lookup ---"
run_test "-l 129 -> HUP (128+1)" "0" "^HUP$" "" -l 129
run_test "-l 143 -> TERM (128+15)" "0" "^TERM$" "" -l 143

# ── 7. Sending signals to processes ──
echo "--- Signal Sending ---"
run_signal_test "kill PID (default SIGTERM)"
run_signal_test "kill -9 PID" -9
run_signal_test "kill -TERM PID" -TERM
run_signal_test "kill -HUP PID" -HUP
run_signal_test "kill -s TERM PID" -s TERM
run_signal_test "kill -s HUP PID" -s HUP
run_signal_test "kill -s 9 PID" -s 9
run_signal_test "kill -s SIGTERM PID" -s SIGTERM

# Signal 0 (check process existence)
sleep 999 &
ALIVE_PID=$!
run_signal0_test "kill -0 existing PID" "0" -0 $ALIVE_PID
kill -9 $ALIVE_PID 2>/dev/null
wait $ALIVE_PID 2>/dev/null

run_signal0_test "kill -0 nonexistent PID" "1" -0 99999999

# ── 8. Error handling ──
echo "--- Error Handling ---"
run_test "no arguments" "1" "" "not enough arguments"
run_test "missing PID after -s" "1" "" "not enough arguments" -s TERM
run_test "invalid PID" "1" "" "arguments must be process" abc
run_test "nonexistent process" "1" "" "No such process" 99999999
run_test "invalid signal name" "1" "" "invalid signal" -s BOGUS
run_test "invalid signal: -BOGUS" "1" "" "invalid signal" -BOGUS

# ── 9. Multiple PIDs ──
echo "--- Multiple PIDs ---"
sleep 999 &
PID1=$!
sleep 999 &
PID2=$!
$BIN $PID1 $PID2 > "$TMPDIR/multi_out" 2> "$TMPDIR/multi_err"
MULTI_EXIT=$?
sleep 0.1
ALIVE1=0
ALIVE2=0
kill -0 $PID1 2>/dev/null && ALIVE1=1
kill -0 $PID2 2>/dev/null && ALIVE2=1
kill -9 $PID1 $PID2 2>/dev/null
wait $PID1 $PID2 2>/dev/null

if [ "$MULTI_EXIT" = "0" ] && [ "$ALIVE1" = "0" ] && [ "$ALIVE2" = "0" ]; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: kill multiple PIDs (exit=$MULTI_EXIT, alive1=$ALIVE1, alive2=$ALIVE2)")
fi

# ── 10. Mixed valid/invalid PIDs ──
echo "--- Mixed PIDs ---"
sleep 999 &
VALID_PID=$!
$BIN $VALID_PID 99999999 > "$TMPDIR/mixed_out" 2> "$TMPDIR/mixed_err"
MIXED_EXIT=$?
sleep 0.1
VALID_ALIVE=0
kill -0 $VALID_PID 2>/dev/null && VALID_ALIVE=1
kill -9 $VALID_PID 2>/dev/null
wait $VALID_PID 2>/dev/null

if [ "$MIXED_EXIT" = "1" ] && [ "$VALID_ALIVE" = "0" ]; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: mixed valid+invalid PIDs (exit=$MIXED_EXIT, valid_alive=$VALID_ALIVE)")
fi

# ── 11. Negative PID (process group) ──
echo "--- Process Group ---"
# Sending to -1 should fail for non-root (EPERM)
$BIN -0 -1 > /dev/null 2> "$TMPDIR/pgrp_err"
PGRP_EXIT=$?
# Should not crash (exit 0 or 1, not >= 128)
if [ "$PGRP_EXIT" -lt 128 ]; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: negative PID (process group) crashed with exit $PGRP_EXIT")
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
