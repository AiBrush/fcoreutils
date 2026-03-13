#!/bin/bash
# Test suite for fprintenv
# Usage: bash tests/run_tests.sh ./fprintenv

BIN="${1:-./fprintenv}"
GNU="printenv"
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

# Separate test for help/version (text is patched by build_tool.py)
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

# Test for NUL-byte output
run_test_null() {
    local desc="$1"
    shift
    local args=("$@")

    $GNU "${args[@]}" > "$TMPDIR/expected_raw" 2>/dev/null
    local expected_exit=$?
    $BIN "${args[@]}" > "$TMPDIR/got_raw" 2>/dev/null
    local got_exit=$?

    # For "all env" tests (no specific var), filter out _= which differs per invocation
    local cmp_expected="$TMPDIR/expected_raw"
    local cmp_got="$TMPDIR/got_raw"
    if [ ${#args[@]} -le 1 ] || ( [ ${#args[@]} -eq 1 ] && [[ "${args[0]}" == -* ]] ); then
        # This might be an all-env test; filter _= from both
        # For NUL-delimited output, use tr to convert to newlines for filtering
        if [[ " ${args[*]} " == *" -0 "* ]] || [[ " ${args[*]} " == *" --null "* ]]; then
            tr '\0' '\n' < "$TMPDIR/expected_raw" | grep -v '^_=' | sort > "$TMPDIR/expected_filtered"
            tr '\0' '\n' < "$TMPDIR/got_raw" | grep -v '^_=' | sort > "$TMPDIR/got_filtered"
        else
            grep -v '^_=' "$TMPDIR/expected_raw" | sort > "$TMPDIR/expected_filtered"
            grep -v '^_=' "$TMPDIR/got_raw" | sort > "$TMPDIR/got_filtered"
        fi
        cmp_expected="$TMPDIR/expected_filtered"
        cmp_got="$TMPDIR/got_filtered"
    fi

    if cmp -s "$cmp_expected" "$cmp_got" && [ "$expected_exit" = "$got_exit" ]; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
        ERRORS+=("FAIL: $desc")
        if ! cmp -s "$TMPDIR/expected_raw" "$TMPDIR/got_raw"; then
            ERRORS+=("  stdout differs (binary compare)")
        fi
        if [ "$expected_exit" != "$got_exit" ]; then
            ERRORS+=("  expected exit: $expected_exit, got: $got_exit")
        fi
    fi
}

# Test that compares sorted output (for "no args" mode where env order may differ)
run_test_sorted() {
    local desc="$1"
    shift
    local args=("$@")

    $GNU "${args[@]}" 2>/dev/null | grep -v '^_=' | sort > "$TMPDIR/expected_sorted"
    local expected_exit=${PIPESTATUS[0]}
    $BIN "${args[@]}" 2>/dev/null | grep -v '^_=' | sort > "$TMPDIR/got_sorted"
    local got_exit=${PIPESTATUS[0]}

    if cmp -s "$TMPDIR/expected_sorted" "$TMPDIR/got_sorted" && [ "$expected_exit" = "$got_exit" ]; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
        ERRORS+=("FAIL: $desc")
        if ! cmp -s "$TMPDIR/expected_sorted" "$TMPDIR/got_sorted"; then
            ERRORS+=("  sorted output differs")
        fi
        if [ "$expected_exit" != "$got_exit" ]; then
            ERRORS+=("  expected exit: $expected_exit, got: $got_exit")
        fi
    fi
}

# ── Standard flags ──
run_test_exit_only "--help exit code" --help
run_test_exit_only "--version exit code" --version
run_test "invalid long flag" --invalid-flag-xyz
run_test "invalid short flag" -Z

# ── FD isolation ──
run_test_fd "--help to stdout" --help
run_test_fd "error to stderr" --invalid-flag-xyz

# ── No args: print all env (sorted comparison) ──
run_test_sorted "no args: print all env vars"

# ── Single known var ──
run_test "single var: HOME" HOME
run_test "single var: PATH" PATH

# ── Multiple vars ──
run_test "multiple vars: HOME PATH" HOME PATH

# ── Nonexistent var → exit 1 ──
run_test "nonexistent var" NONEXISTENT_VAR_XYZ_12345

# ── Mix of existing and nonexistent → exit 1 ──
run_test "mixed existing/nonexistent" HOME NONEXISTENT_VAR_XYZ_12345

# ── NUL terminator with -0 ──
run_test_null "-0 single var" -0 HOME
run_test_null "-0 multiple vars" -0 HOME PATH
run_test_null "-0 no args (all env)" -0

# ── --null long form ──
run_test_null "--null single var" --null HOME
run_test_null "--null no args" --null

# ── Error cases (invalid flags) ──
run_test "unrecognized long option --foo" --foo
run_test "invalid short option -X" -X

# ── Double dash ──
run_test "-- separator with var" -- HOME

# ── Edge cases ──
run_test "nonexistent var exit code" THIS_SHOULD_NOT_EXIST_EVER
run_test_exit_only "multiple nonexistent vars" NONEXIST1 NONEXIST2

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
