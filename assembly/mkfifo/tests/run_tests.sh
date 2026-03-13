#!/bin/bash
# Test suite for fmkfifo
# Usage: bash tests/run_tests.sh ./fmkfifo

BIN="$(realpath "${1:-./fmkfifo}")"
GNU="mkfifo"
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
got_err=$(echo "$got_err" | sed "s|$(basename $BIN)|mkfifo|g; s|$BIN|mkfifo|g")
if [ "$got_exit" = "1" ] && echo "$got_err" | grep -qF "missing operand"; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: missing operand")
fi

# ── Create FIFO ──
rm -f "$TMPDIR/test_fifo"
$BIN "$TMPDIR/test_fifo" > /dev/null 2>&1
got_exit=$?
if [ "$got_exit" = "0" ] && [ -p "$TMPDIR/test_fifo" ]; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: create fifo — expected exit 0 and pipe file")
fi
rm -f "$TMPDIR/test_fifo"

# ── FIFO already exists ──
$GNU "$TMPDIR/exist_fifo" 2>/dev/null
$BIN "$TMPDIR/exist_fifo" > /dev/null 2> "$TMPDIR/exist_err"
got_exit=$?
got_err=$(cat "$TMPDIR/exist_err")
if [ "$got_exit" = "1" ] && echo "$got_err" | grep -qF "File exists"; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: already exists — expected exit 1 + 'File exists'")
fi
rm -f "$TMPDIR/exist_fifo"

# ── Multiple FIFOs ──
rm -f "$TMPDIR/fifo1" "$TMPDIR/fifo2" "$TMPDIR/fifo3"
$BIN "$TMPDIR/fifo1" "$TMPDIR/fifo2" "$TMPDIR/fifo3" > /dev/null 2>&1
got_exit=$?
if [ "$got_exit" = "0" ] && [ -p "$TMPDIR/fifo1" ] && [ -p "$TMPDIR/fifo2" ] && [ -p "$TMPDIR/fifo3" ]; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: multiple fifos — expected all created")
fi
rm -f "$TMPDIR/fifo1" "$TMPDIR/fifo2" "$TMPDIR/fifo3"

# ── -m mode ──
rm -f "$TMPDIR/mode_fifo"
$BIN -m 644 "$TMPDIR/mode_fifo" > /dev/null 2>&1
got_exit=$?
if [ "$got_exit" = "0" ] && [ -p "$TMPDIR/mode_fifo" ]; then
    perms=$(stat -c '%a' "$TMPDIR/mode_fifo" 2>/dev/null || stat -f '%Lp' "$TMPDIR/mode_fifo" 2>/dev/null)
    if [ "$perms" = "644" ]; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
        ERRORS+=("FAIL: -m 644 — got permissions $perms")
    fi
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: -m 644 — fifo not created, exit=$got_exit")
fi
rm -f "$TMPDIR/mode_fifo"

# ── --mode=600 ──
rm -f "$TMPDIR/mode_long_fifo"
$BIN --mode=600 "$TMPDIR/mode_long_fifo" > /dev/null 2>&1
got_exit=$?
if [ "$got_exit" = "0" ] && [ -p "$TMPDIR/mode_long_fifo" ]; then
    perms=$(stat -c '%a' "$TMPDIR/mode_long_fifo" 2>/dev/null || stat -f '%Lp' "$TMPDIR/mode_long_fifo" 2>/dev/null)
    if [ "$perms" = "600" ]; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
        ERRORS+=("FAIL: --mode=600 — got permissions $perms")
    fi
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: --mode=600 — fifo not created, exit=$got_exit")
fi
rm -f "$TMPDIR/mode_long_fifo"

# ── Nonexistent parent ──
$BIN "$TMPDIR/noparent/fifo" > /dev/null 2> "$TMPDIR/noent_err"
got_exit=$?
got_err=$(cat "$TMPDIR/noent_err")
if [ "$got_exit" = "1" ] && echo "$got_err" | grep -qF "No such file or directory"; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: nonexistent parent — expected ENOENT")
fi

# ── Error format ──
$BIN "$TMPDIR/noparent2/fifo" 2> "$TMPDIR/fmt_err"
got_err=$(cat "$TMPDIR/fmt_err")
got_err=$(echo "$got_err" | sed "s|$(basename $BIN)|mkfifo|g; s|$BIN|mkfifo|g")
if echo "$got_err" | grep -qF "mkfifo: cannot create fifo '"; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: error format — expected 'mkfifo: cannot create fifo'")
    ERRORS+=("  got: $got_err")
fi

# ── Double dash ──
rm -f "$TMPDIR/dashdash_fifo"
$BIN -- "$TMPDIR/dashdash_fifo" > /dev/null 2>&1
got_exit=$?
if [ "$got_exit" = "0" ] && [ -p "$TMPDIR/dashdash_fifo" ]; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: -- separator — expected fifo created")
fi
rm -f "$TMPDIR/dashdash_fifo"

# ── Invalid long flag ──
$BIN --bogus-flag 2> "$TMPDIR/invalid_long_err"
got_exit=$?
got_err=$(cat "$TMPDIR/invalid_long_err")
got_err=$(echo "$got_err" | sed "s|$(basename $BIN)|mkfifo|g; s|$BIN|mkfifo|g")
if [ "$got_exit" = "1" ] && echo "$got_err" | grep -qF "unrecognized option"; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: invalid long flag")
    ERRORS+=("  exit=$got_exit, stderr='$got_err'")
fi

# ── Mixed success/failure ──
rm -f "$TMPDIR/mixed_ok_fifo"
$BIN "$TMPDIR/mixed_ok_fifo" "$TMPDIR/noparent3/bad" 2> /dev/null
got_exit=$?
if [ "$got_exit" = "1" ] && [ -p "$TMPDIR/mixed_ok_fifo" ]; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: mixed success/failure")
fi
rm -f "$TMPDIR/mixed_ok_fifo"

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
