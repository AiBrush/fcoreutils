#!/bin/bash
# Test suite for fsum
# Usage: bash tests/run_tests.sh ./fsum

BIN="${1:-./fsum}"
GNU="sum"
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

run_test_stdin() {
    local desc="$1"
    local input="$2"
    shift 2
    local args=("$@")

    echo -n "$input" | $GNU "${args[@]}" > "$TMPDIR/expected" 2>/dev/null
    local expected_exit=$?
    echo -n "$input" | $BIN "${args[@]}" > "$TMPDIR/got" 2>/dev/null
    local got_exit=$?

    local expected=$(cat "$TMPDIR/expected")
    local got=$(cat "$TMPDIR/got")

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

# Separate test for help/version (text may differ)
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

# ── Create test files ──
echo -n "hello" > "$TMPDIR/hello.txt"
echo -n "world" > "$TMPDIR/world.txt"
echo -n "" > "$TMPDIR/empty.txt"
dd if=/dev/zero bs=1024 count=5 2>/dev/null > "$TMPDIR/5k.bin"
dd if=/dev/zero bs=1 count=1025 2>/dev/null > "$TMPDIR/1025.bin"
printf '\x01\x02\x03\x04\x05' > "$TMPDIR/bytes.bin"
dd if=/dev/urandom bs=1024 count=100 2>/dev/null > "$TMPDIR/random.bin"

# ── Standard flags ──
run_test_exit_only "--help exit code" --help
run_test_exit_only "--version exit code" --version
run_test "invalid long flag" --invalid-flag-xyz
run_test "invalid short flag" -x

# ── FD isolation ──
run_test_fd "--help to stdout" --help
run_test_fd "error to stderr" --invalid-flag-xyz

# ── BSD mode (default) ──
run_test "BSD single file" "$TMPDIR/hello.txt"
run_test "BSD explicit -r" -r "$TMPDIR/hello.txt"
run_test "BSD empty file" "$TMPDIR/empty.txt"
run_test "BSD 5K file" "$TMPDIR/5k.bin"
run_test "BSD 1025 byte file" "$TMPDIR/1025.bin"
run_test "BSD bytes file" "$TMPDIR/bytes.bin"
run_test "BSD random file" "$TMPDIR/random.bin"
run_test "BSD multiple files" "$TMPDIR/hello.txt" "$TMPDIR/world.txt"
run_test "BSD three files" "$TMPDIR/hello.txt" "$TMPDIR/world.txt" "$TMPDIR/empty.txt"

# ── SysV mode ──
run_test "SysV single file" -s "$TMPDIR/hello.txt"
run_test "SysV empty file" -s "$TMPDIR/empty.txt"
run_test "SysV 5K file" -s "$TMPDIR/5k.bin"
run_test "SysV 1025 byte file" -s "$TMPDIR/1025.bin"
run_test "SysV bytes file" -s "$TMPDIR/bytes.bin"
run_test "SysV random file" -s "$TMPDIR/random.bin"
run_test "SysV multiple files" -s "$TMPDIR/hello.txt" "$TMPDIR/world.txt"
run_test "SysV --sysv flag" --sysv "$TMPDIR/hello.txt"

# ── Stdin tests ──
run_test_stdin "BSD stdin (no args)" "hello"
run_test_stdin "BSD stdin empty" ""
run_test_stdin "SysV stdin" "hello" -s
run_test_stdin "SysV stdin empty" "" -s
run_test_stdin "BSD stdin with -" "hello" -

# ── Mixed flags ──
run_test "BSD -r -s uses last" -r -s "$TMPDIR/hello.txt"
run_test "SysV -s -r uses last" -s -r "$TMPDIR/hello.txt"

# ── Error handling ──
run_test "nonexistent file" "$TMPDIR/nonexistent_file_xyz"
run_test "nonexistent with valid" "$TMPDIR/nonexistent_file_xyz" "$TMPDIR/hello.txt"

# ── Large file ──
dd if=/dev/zero bs=1024 count=1000 2>/dev/null > "$TMPDIR/1M.bin"
run_test "BSD 1M file" "$TMPDIR/1M.bin"
run_test "SysV 1M file" -s "$TMPDIR/1M.bin"

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
