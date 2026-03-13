#!/bin/bash
# Test suite for fmktemp
# Usage: bash tests/run_tests.sh ./fmktemp

BIN="$(realpath "${1:-./fmktemp}")"
GNU="mktemp"
PASS=0
FAIL=0
ERRORS=()
TMPDIR_T=$(mktemp -d)
trap "rm -rf $TMPDIR_T" EXIT

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

    $BIN "${args[@]}" > "$TMPDIR_T/stdout" 2> "$TMPDIR_T/stderr"
    local exit_code=$?

    if echo "${args[@]}" | grep -q "\-\-help"; then
        if [ -s "$TMPDIR_T/stdout" ] && [ ! -s "$TMPDIR_T/stderr" ]; then
            PASS=$((PASS+1))
        else
            FAIL=$((FAIL+1))
            ERRORS+=("FAIL: $desc — --help should write to stdout only")
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

# ── Default temp file creation ──
RESULT=$($BIN 2>&1)
got_exit=$?
if [ "$got_exit" = "0" ] && [ -f "$RESULT" ]; then
    PASS=$((PASS+1))
    rm -f "$RESULT"
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: default temp file — expected file created, exit=$got_exit, result='$RESULT'")
fi

# ── Output format: starts with /tmp/ ──
RESULT=$($BIN 2>&1)
got_exit=$?
if [ "$got_exit" = "0" ] && echo "$RESULT" | grep -q "^/tmp/tmp\."; then
    PASS=$((PASS+1))
    rm -f "$RESULT"
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: output format — expected /tmp/tmp.*, got '$RESULT'")
    rm -f "$RESULT" 2>/dev/null
fi

# ── Uniqueness: 10 files all different ──
UNIQUE=()
ALL_OK=true
for i in $(seq 1 10); do
    RESULT=$($BIN 2>/dev/null)
    if [ -f "$RESULT" ]; then
        UNIQUE+=("$RESULT")
    else
        ALL_OK=false
    fi
done
UNIQUE_COUNT=$(printf '%s\n' "${UNIQUE[@]}" | sort -u | wc -l)
if [ "$UNIQUE_COUNT" = "10" ] && [ "$ALL_OK" = "true" ]; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: uniqueness — expected 10 unique files, got $UNIQUE_COUNT")
fi
for f in "${UNIQUE[@]}"; do rm -f "$f"; done

# ── -d creates directory ──
RESULT=$($BIN -d 2>&1)
got_exit=$?
if [ "$got_exit" = "0" ] && [ -d "$RESULT" ]; then
    PASS=$((PASS+1))
    rmdir "$RESULT"
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: -d directory — expected dir created")
    rm -rf "$RESULT" 2>/dev/null
fi

# ── -u dry run (no file created) ──
RESULT=$($BIN -u 2>&1)
got_exit=$?
if [ "$got_exit" = "0" ] && [ ! -e "$RESULT" ]; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: -u dry run — expected no file created")
    rm -f "$RESULT" 2>/dev/null
fi

# ── -p DIR ──
RESULT=$($BIN -p "$TMPDIR_T" 2>&1)
got_exit=$?
if [ "$got_exit" = "0" ] && echo "$RESULT" | grep -q "^$TMPDIR_T/"; then
    PASS=$((PASS+1))
    rm -f "$RESULT"
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: -p DIR — expected file in $TMPDIR_T, got '$RESULT'")
    rm -f "$RESULT" 2>/dev/null
fi

# ── --tmpdir=DIR ──
RESULT=$($BIN --tmpdir="$TMPDIR_T" 2>&1)
got_exit=$?
if [ "$got_exit" = "0" ] && echo "$RESULT" | grep -q "^$TMPDIR_T/"; then
    PASS=$((PASS+1))
    rm -f "$RESULT"
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: --tmpdir=DIR — expected file in $TMPDIR_T, got '$RESULT'")
    rm -f "$RESULT" 2>/dev/null
fi

# ── Custom template ──
RESULT=$($BIN "$TMPDIR_T/myfileXXXXXX" 2>&1)
got_exit=$?
if [ "$got_exit" = "0" ] && echo "$RESULT" | grep -q "^$TMPDIR_T/myfile"; then
    PASS=$((PASS+1))
    rm -f "$RESULT"
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: custom template — expected myfile* in $TMPDIR_T, got '$RESULT'")
    rm -f "$RESULT" 2>/dev/null
fi

# ── --suffix=.txt ──
RESULT=$($BIN --suffix=.txt 2>&1)
got_exit=$?
if [ "$got_exit" = "0" ] && echo "$RESULT" | grep -q "\.txt$"; then
    PASS=$((PASS+1))
    rm -f "$RESULT"
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: --suffix=.txt — expected .txt suffix, got '$RESULT'")
    rm -f "$RESULT" 2>/dev/null
fi

# ── -q suppresses errors ──
$BIN -q "/nonexistent_dir/testXXXXXX" > "$TMPDIR_T/q_out" 2> "$TMPDIR_T/q_err"
got_exit=$?
got_err=$(cat "$TMPDIR_T/q_err")
if [ "$got_exit" = "1" ] && [ -z "$got_err" ]; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: -q quiet — expected exit 1, no stderr, got exit=$got_exit, stderr='$got_err'")
fi

# ── Error on nonexistent dir ──
$BIN "/nonexistent_dir/testXXXXXX" > /dev/null 2> "$TMPDIR_T/nodir_err"
got_exit=$?
got_err=$(cat "$TMPDIR_T/nodir_err")
if [ "$got_exit" = "1" ] && [ -n "$got_err" ]; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: nonexistent dir error — expected exit 1 + stderr")
fi

# ── Too few X's ──
$BIN "$TMPDIR_T/noXs" > /dev/null 2> "$TMPDIR_T/fewx_err"
got_exit=$?
if [ "$got_exit" = "1" ]; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: too few X's — expected exit 1, got $got_exit")
fi

# ── Combined -du (dry-run directory) ──
RESULT=$($BIN -du 2>&1)
got_exit=$?
if [ "$got_exit" = "0" ] && [ ! -e "$RESULT" ]; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: -du combined — expected no dir created")
    rm -rf "$RESULT" 2>/dev/null
fi

# ── Invalid long flag ──
$BIN --bogus-flag 2> "$TMPDIR_T/invalid_err"
got_exit=$?
got_err=$(cat "$TMPDIR_T/invalid_err")
got_err=$(echo "$got_err" | sed "s|$(basename $BIN)|mktemp|g; s|$BIN|mktemp|g")
if [ "$got_exit" = "1" ] && echo "$got_err" | grep -qF "unrecognized option"; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: invalid long flag")
fi

# ── TMPDIR env var ──
RESULT=$(TMPDIR="$TMPDIR_T" $BIN 2>&1)
got_exit=$?
if [ "$got_exit" = "0" ] && echo "$RESULT" | grep -q "^$TMPDIR_T/"; then
    PASS=$((PASS+1))
    rm -f "$RESULT"
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: TMPDIR env var — expected file in $TMPDIR_T, got '$RESULT'")
    rm -f "$RESULT" 2>/dev/null
fi

# ── File permissions (0600) ──
RESULT=$($BIN 2>&1)
got_exit=$?
if [ "$got_exit" = "0" ] && [ -f "$RESULT" ]; then
    perms=$(stat -c '%a' "$RESULT" 2>/dev/null || stat -f '%Lp' "$RESULT" 2>/dev/null)
    if [ "$perms" = "600" ]; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
        ERRORS+=("FAIL: file permissions — expected 600, got $perms")
    fi
    rm -f "$RESULT"
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: file permissions — file not created")
fi

# ── Dir permissions (0700) ──
RESULT=$($BIN -d 2>&1)
got_exit=$?
if [ "$got_exit" = "0" ] && [ -d "$RESULT" ]; then
    perms=$(stat -c '%a' "$RESULT" 2>/dev/null || stat -f '%Lp' "$RESULT" 2>/dev/null)
    if [ "$perms" = "700" ]; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
        ERRORS+=("FAIL: dir permissions — expected 700, got $perms")
    fi
    rmdir "$RESULT"
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: dir permissions — dir not created")
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
