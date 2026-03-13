#!/bin/bash
# Test suite for fmknod
# Usage: bash tests/run_tests.sh ./fmknod

BIN="$(realpath "${1:-./fmknod}")"
GNU="mknod"
PASS=0
FAIL=0
ERRORS=()
TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT

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

# ── Standard flags ──
run_test_exit_only "--help exit code" --help
run_test_exit_only "--version exit code" --version

# ── FD isolation ──
run_test_fd "--help to stdout" --help
run_test_fd "error to stderr"

# ── Missing operand ──
$BIN > /dev/null 2> "$TMPDIR/missing_err"
got_exit=$?
got_err=$(cat "$TMPDIR/missing_err")
got_err=$(echo "$got_err" | sed "s|$(basename $BIN)|mknod|g; s|$BIN|mknod|g")
if [ "$got_exit" = "1" ] && echo "$got_err" | grep -qF "missing operand"; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: missing operand")
fi

# ── Create FIFO (pipe type) ──
rm -f "$TMPDIR/test_pipe"
$BIN "$TMPDIR/test_pipe" p > /dev/null 2>&1
got_exit=$?
if [ "$got_exit" = "0" ] && [ -p "$TMPDIR/test_pipe" ]; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: create pipe — expected exit 0 and pipe file, got exit=$got_exit")
fi
rm -f "$TMPDIR/test_pipe"

# ── Already exists ──
touch "$TMPDIR/exist_file"
$BIN "$TMPDIR/exist_file" p > /dev/null 2> "$TMPDIR/exist_err"
got_exit=$?
got_err=$(cat "$TMPDIR/exist_err")
if [ "$got_exit" = "1" ] && echo "$got_err" | grep -qF "File exists"; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: already exists — expected exit 1 + 'File exists'")
fi
rm -f "$TMPDIR/exist_file"

# ── Nonexistent parent ──
$BIN "$TMPDIR/noparent/node" p > /dev/null 2> "$TMPDIR/noent_err"
got_exit=$?
got_err=$(cat "$TMPDIR/noent_err")
if [ "$got_exit" = "1" ] && echo "$got_err" | grep -qF "No such file or directory"; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: nonexistent parent — expected ENOENT")
fi

# ── Invalid type ──
$BIN "$TMPDIR/test_bad" x > /dev/null 2> "$TMPDIR/badtype_err"
got_exit=$?
if [ "$got_exit" = "1" ]; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: invalid type — expected exit 1, got $got_exit")
fi

# ── Error format ──
$BIN "$TMPDIR/noparent2/node" p 2> "$TMPDIR/fmt_err"
got_err=$(cat "$TMPDIR/fmt_err")
got_err=$(echo "$got_err" | sed "s|$(basename $BIN)|mknod|g; s|$BIN|mknod|g")
# Note: GNU mknod uses "cannot create special file" in some versions
if echo "$got_err" | grep -qF "mknod:"; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: error format — expected 'mknod:' prefix")
    ERRORS+=("  got: $got_err")
fi

# ── Double dash ──
rm -f "$TMPDIR/dashdash_pipe"
$BIN -- "$TMPDIR/dashdash_pipe" p > /dev/null 2>&1
got_exit=$?
if [ "$got_exit" = "0" ] && [ -p "$TMPDIR/dashdash_pipe" ]; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: -- separator — expected pipe created, got exit=$got_exit")
fi
rm -f "$TMPDIR/dashdash_pipe"

# ── Invalid long flag ──
$BIN --bogus-flag 2> "$TMPDIR/invalid_long_err"
got_exit=$?
got_err=$(cat "$TMPDIR/invalid_long_err")
got_err=$(echo "$got_err" | sed "s|$(basename $BIN)|mknod|g; s|$BIN|mknod|g")
if [ "$got_exit" = "1" ] && echo "$got_err" | grep -qF "unrecognized option"; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: invalid long flag")
fi

# ── Extra operand for pipe ──
rm -f "$TMPDIR/extra_pipe"
$BIN "$TMPDIR/extra_pipe" p 1 2 > /dev/null 2> "$TMPDIR/extra_err"
got_exit=$?
if [ "$got_exit" = "1" ]; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: extra operand for pipe — expected exit 1, got $got_exit")
fi
rm -f "$TMPDIR/extra_pipe"

# ── -m mode for pipe ──
rm -f "$TMPDIR/mode_pipe"
$BIN -m 644 "$TMPDIR/mode_pipe" p > /dev/null 2>&1
got_exit=$?
if [ "$got_exit" = "0" ] && [ -p "$TMPDIR/mode_pipe" ]; then
    perms=$(stat -c '%a' "$TMPDIR/mode_pipe" 2>/dev/null || stat -f '%Lp' "$TMPDIR/mode_pipe" 2>/dev/null)
    if [ "$perms" = "644" ]; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
        ERRORS+=("FAIL: -m 644 pipe — got permissions $perms")
    fi
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: -m 644 pipe — not created, exit=$got_exit")
fi
rm -f "$TMPDIR/mode_pipe"

# ── Block/char device creation requires root, test error handling ──
# Try to create a block device without root (should fail with EPERM)
$BIN "$TMPDIR/test_block" b 1 0 > /dev/null 2> "$TMPDIR/block_err"
got_exit=$?
got_err=$(cat "$TMPDIR/block_err")
if [ "$got_exit" = "1" ]; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: block device without root — expected exit 1, got $got_exit")
fi

# ── Char device without root ──
$BIN "$TMPDIR/test_char" c 1 0 > /dev/null 2> "$TMPDIR/char_err"
got_exit=$?
if [ "$got_exit" = "1" ]; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: char device without root — expected exit 1, got $got_exit")
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
