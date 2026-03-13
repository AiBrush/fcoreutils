#!/bin/bash
# Test suite for fptx
# Usage: bash tests/run_tests.sh ./fptx

BIN="${1:-./fptx}"
GNU="ptx"
PASS=0
FAIL=0
ERRORS=()

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

run_test_fd() {
    local desc="$1"
    shift
    local args=("$@")
    local TMPDIR=$(mktemp -d)
    trap "rm -rf $TMPDIR" RETURN

    $BIN "${args[@]}" > "$TMPDIR/stdout" 2> "$TMPDIR/stderr"
    local exit_code=$?

    if echo "${args[@]}" | grep -q "\-\-help"; then
        if [ -s "$TMPDIR/stdout" ] && [ ! -s "$TMPDIR/stderr" ]; then
            PASS=$((PASS+1))
        else
            FAIL=$((FAIL+1))
            ERRORS+=("FAIL: $desc — --help should write to stdout only")
        fi
        return
    fi

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

# ── Standard flags ──
run_test_exit_only "--help exit code" --help
run_test_exit_only "--version exit code" --version

# ── FD isolation ──
run_test_fd "--help to stdout" --help

# ── Basic input processing ──
desc="basic stdin processing"
expected_exit=0
echo "hello world" | timeout 5 $BIN > /dev/null 2>&1
got_exit=$?
if [ "$got_exit" = "$expected_exit" ]; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: $desc — expected exit: $expected_exit, got: $got_exit")
fi

# ── File input ──
TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT
echo "the quick brown fox" > "$TMPDIR/input.txt"
desc="file input"
timeout 5 $BIN "$TMPDIR/input.txt" > /dev/null 2>&1
got_exit=$?
if [ "$got_exit" = "0" ]; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: $desc — expected exit: 0, got: $got_exit")
fi

# ── Nonexistent file ──
desc="nonexistent file"
timeout 5 $BIN /nonexistent_file_xyz > /dev/null 2>&1
got_exit=$?
if [ "$got_exit" != "0" ]; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: $desc — should fail for nonexistent file")
fi

# ── Empty input ──
desc="empty input"
echo -n "" | timeout 5 $BIN > /dev/null 2>&1
got_exit=$?
if [ "$got_exit" = "0" ]; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: $desc — expected exit: 0, got: $got_exit")
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
