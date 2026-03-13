#!/bin/bash
# Test suite for fdircolors
# Usage: bash tests/run_tests.sh ./fdircolors

BIN="${1:-./fdircolors}"
GNU="dircolors"
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

    expected_err=$(echo "$expected_err" | sed "s|$(which $GNU)|$GNU|g")

    if [ "$expected" = "$got" ] && [ "$expected_exit" = "$got_exit" ]; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
        ERRORS+=("FAIL: $desc")
        if [ "$expected" != "$got" ]; then
            ERRORS+=("  expected stdout: $(echo "$expected" | head -3)")
            ERRORS+=("  got stdout:      $(echo "$got" | head -3)")
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

run_test_fd() {
    local desc="$1"
    shift
    local args=("$@")

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

# Test output format (structure check, not exact match)
run_test_structure() {
    local desc="$1"
    shift
    local args=("$@")

    $BIN "${args[@]}" > "$TMPDIR/got" 2> "$TMPDIR/got_err"
    local got_exit=$?
    local got=$(cat "$TMPDIR/got")

    if [ $got_exit -eq 0 ] && [ -n "$got" ]; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
        ERRORS+=("FAIL: $desc — expected exit 0 with output")
    fi
}

# ── Standard flags ──
run_test_exit_only "--help exit code" --help
run_test_exit_only "--version exit code" --version
run_test_exit_only "invalid short flag" -Z

# ── FD isolation ──
run_test_fd "--help to stdout" --help
run_test_fd "error to stderr" -Z

# ── Bourne shell output ──
run_test_structure "default output"
run_test_structure "-b output" -b
run_test_structure "--sh output" --sh
run_test_structure "--bourne-shell output" --bourne-shell

# Verify Bourne shell format
$BIN -b > "$TMPDIR/sh_out" 2>/dev/null
if grep -q "^LS_COLORS=" "$TMPDIR/sh_out" && grep -q "export LS_COLORS" "$TMPDIR/sh_out"; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: -b output missing LS_COLORS= or export")
fi

# ── C shell output ──
run_test_structure "-c output" -c
run_test_structure "--csh output" --csh
run_test_structure "--c-shell output" --c-shell

# Verify C shell format
$BIN -c > "$TMPDIR/csh_out" 2>/dev/null
if grep -q "^setenv LS_COLORS" "$TMPDIR/csh_out"; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: -c output missing setenv LS_COLORS")
fi

# ── Print database ──
run_test_structure "-p print database" -p
run_test_structure "--print-database" --print-database

# Verify database has key entries
$BIN -p > "$TMPDIR/db_out" 2>/dev/null
for keyword in "NORMAL" "DIR" "LINK" "EXEC" ".tar" ".gz" ".jpg"; do
    if grep -q "$keyword" "$TMPDIR/db_out"; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
        ERRORS+=("FAIL: -p database missing keyword: $keyword")
    fi
done

# ── LS_COLORS content checks ──
$BIN -b > "$TMPDIR/ls_out" 2>/dev/null
for entry in "di=01;34" "ln=01;36" "ex=01;32" "*.tar=01;31"; do
    if grep -q "$entry" "$TMPDIR/ls_out"; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
        ERRORS+=("FAIL: LS_COLORS missing entry: $entry")
    fi
done

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
