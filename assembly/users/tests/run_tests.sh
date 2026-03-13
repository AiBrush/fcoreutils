#!/bin/bash
# Test suite for fusers (assembly users command)
# Usage: bash tests/run_tests.sh [./fusers]

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BIN="${1:-$SCRIPT_DIR/fusers}"
GNU="users"
PASS=0
FAIL=0
ERRORS=()
TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT

# ── Helper: create a utmp entry (384 bytes) ──
# Usage: make_utmp_entry <ut_type> <user> <line>
make_utmp_entry() {
    local ut_type="$1"
    local user="$2"
    local line="$3"
    python3 -c "
import struct, sys
entry = bytearray(384)
struct.pack_into('<i', entry, 0, $ut_type)
struct.pack_into('<i', entry, 4, 1000)  # pid
line = b'${line}'[:31]
entry[8:8+len(line)] = line
user = b'${user}'[:31]
entry[44:44+len(user)] = user
sys.stdout.buffer.write(bytes(entry))
"
}

# Create test utmp files
# 1) Multi-user utmp (unsorted: charlie, alice, bob, alice)
{
    make_utmp_entry 2 "reboot" "~"         # BOOT_TIME
    make_utmp_entry 7 "charlie" "pts/0"    # USER_PROCESS
    make_utmp_entry 7 "alice" "pts/1"      # USER_PROCESS
    make_utmp_entry 7 "bob" "pts/2"        # USER_PROCESS
    make_utmp_entry 7 "alice" "pts/3"      # USER_PROCESS
    make_utmp_entry 8 "" "pts/4"           # DEAD_PROCESS
} > "$TMPDIR/test_multi.utmp"

# 2) Single user utmp
{
    make_utmp_entry 7 "testuser" "pts/0"
} > "$TMPDIR/test_single.utmp"

# 3) Empty utmp
> "$TMPDIR/test_empty.utmp"

# 4) No USER_PROCESS entries
{
    make_utmp_entry 2 "reboot" "~"
    make_utmp_entry 1 "runlevel" "~"
    make_utmp_entry 8 "" "pts/0"
} > "$TMPDIR/test_no_users.utmp"

# 5) Same user multiple times
{
    make_utmp_entry 7 "admin" "pts/0"
    make_utmp_entry 7 "admin" "pts/1"
    make_utmp_entry 7 "admin" "pts/2"
} > "$TMPDIR/test_same_user.utmp"

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
    got_err=$(echo "$got_err" | sed "s|$BIN|$GNU|g; s|./fusers|$GNU|g")

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

    # --help goes to stdout
    if echo "${args[@]}" | grep -q "\-\-help"; then
        if [ -s "$TMPDIR/stdout" ] && [ ! -s "$TMPDIR/stderr" ]; then
            PASS=$((PASS+1))
        else
            FAIL=$((FAIL+1))
            ERRORS+=("FAIL: $desc — --help should write to stdout only")
        fi
        return
    fi

    # --version goes to stdout
    if echo "${args[@]}" | grep -q "\-\-version"; then
        if [ -s "$TMPDIR/stdout" ] && [ ! -s "$TMPDIR/stderr" ]; then
            PASS=$((PASS+1))
        else
            FAIL=$((FAIL+1))
            ERRORS+=("FAIL: $desc — --version should write to stdout only")
        fi
        return
    fi

    # Error cases: stderr has content, stdout empty
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

# Compare stdout exactly with GNU for utmp file argument
run_test_utmp() {
    local desc="$1"
    local utmp_file="$2"

    $GNU "$utmp_file" > "$TMPDIR/expected" 2>/dev/null
    local expected_exit=$?
    $BIN "$utmp_file" > "$TMPDIR/got" 2>/dev/null
    local got_exit=$?

    local expected=$(cat "$TMPDIR/expected")
    local got=$(cat "$TMPDIR/got")

    if [ "$expected" = "$got" ] && [ "$expected_exit" = "$got_exit" ]; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
        ERRORS+=("FAIL: $desc")
        if [ "$expected" != "$got" ]; then
            ERRORS+=("  expected: '$expected'")
            ERRORS+=("  got:      '$got'")
        fi
        if [ "$expected_exit" != "$got_exit" ]; then
            ERRORS+=("  expected exit: $expected_exit, got: $got_exit")
        fi
    fi
}

echo "Testing: $BIN"
echo ""

# ── Standard flags ──
run_test_exit_only "--help exit code" --help
run_test_exit_only "--version exit code" --version

# ── FD isolation ──
run_test_fd "--help to stdout" --help
run_test_fd "--version to stdout" --version
run_test_fd "error to stderr" --badopt

# ── Error handling ──
run_test "unrecognized long option" --badopt
run_test "invalid short option -z" -z
run_test "extra operand" "$TMPDIR/test_multi.utmp" extra_arg

# ── Core utmp parsing ──
run_test_utmp "multi-user utmp (sorted)" "$TMPDIR/test_multi.utmp"
run_test_utmp "single user utmp" "$TMPDIR/test_single.utmp"
run_test_utmp "empty utmp file" "$TMPDIR/test_empty.utmp"
run_test_utmp "no USER_PROCESS entries" "$TMPDIR/test_no_users.utmp"
run_test_utmp "same user multiple times" "$TMPDIR/test_same_user.utmp"
run_test_utmp "nonexistent utmp file" "/tmp/nonexistent_utmp_999999"

# ── Double dash handling ──
run_test_utmp_dd() {
    local desc="$1"
    local utmp_file="$2"

    $GNU -- "$utmp_file" > "$TMPDIR/expected" 2>/dev/null
    local expected_exit=$?
    $BIN -- "$utmp_file" > "$TMPDIR/got" 2>/dev/null
    local got_exit=$?

    local expected=$(cat "$TMPDIR/expected")
    local got=$(cat "$TMPDIR/got")

    if [ "$expected" = "$got" ] && [ "$expected_exit" = "$got_exit" ]; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
        ERRORS+=("FAIL: $desc")
        if [ "$expected" != "$got" ]; then
            ERRORS+=("  expected: '$expected'")
            ERRORS+=("  got:      '$got'")
        fi
        if [ "$expected_exit" != "$got_exit" ]; then
            ERRORS+=("  expected exit: $expected_exit, got: $got_exit")
        fi
    fi
}

run_test_utmp_dd "double dash with file" "$TMPDIR/test_multi.utmp"

# ── Verify output format: space-separated, one line ──
line_count_test() {
    local desc="$1"
    local utmp_file="$2"
    local expected_lines="$3"

    local lines=$($BIN "$utmp_file" | wc -l)
    if [ "$lines" -eq "$expected_lines" ]; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
        ERRORS+=("FAIL: $desc — expected $expected_lines line(s), got $lines")
    fi
}

line_count_test "multi-user output is one line" "$TMPDIR/test_multi.utmp" 1
line_count_test "empty utmp output is one line (newline)" "$TMPDIR/test_empty.utmp" 1

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
