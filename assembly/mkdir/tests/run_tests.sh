#!/bin/bash
# Test suite for fmkdir
# Usage: bash tests/run_tests.sh ./fmkdir

BIN="$(realpath "${1:-./fmkdir}")"
GNU="mkdir"
PASS=0
FAIL=0
ERRORS=()
TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT

run_test() {
    local desc="$1"
    shift
    local setup="$1"
    shift
    local args=("$@")

    eval "$setup" 2>/dev/null
    $GNU "${args[@]}" > "$TMPDIR/expected" 2> "$TMPDIR/expected_err"
    local expected_exit=$?

    eval "$setup" 2>/dev/null
    $BIN "${args[@]}" > "$TMPDIR/got" 2> "$TMPDIR/got_err"
    local got_exit=$?

    local expected=$(cat "$TMPDIR/expected")
    local got=$(cat "$TMPDIR/got")
    local expected_err=$(cat "$TMPDIR/expected_err")
    local got_err=$(cat "$TMPDIR/got_err")

    # Normalize tool name in error messages
    got_err=$(echo "$got_err" | sed "s|$(basename $BIN)|mkdir|g; s|$BIN|mkdir|g")

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

run_test_error() {
    local desc="$1"
    shift
    local args=("$@")

    $BIN "${args[@]}" > "$TMPDIR/got" 2> "$TMPDIR/got_err"
    local got_exit=$?
    $GNU "${args[@]}" > "$TMPDIR/expected" 2> "$TMPDIR/expected_err"
    local expected_exit=$?

    local got_err=$(cat "$TMPDIR/got_err")
    local expected_err=$(cat "$TMPDIR/expected_err")

    # Normalize tool name
    got_err=$(echo "$got_err" | sed "s|$(basename $BIN)|mkdir|g; s|$BIN|mkdir|g")

    if [ "$expected_exit" = "$got_exit" ] && [ "$expected_err" = "$got_err" ]; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
        ERRORS+=("FAIL: $desc")
        if [ "$expected_err" != "$got_err" ]; then
            ERRORS+=("  expected stderr: $(echo "$expected_err" | head -3)")
            ERRORS+=("  got stderr:      $(echo "$got_err" | head -3)")
        fi
        if [ "$expected_exit" != "$got_exit" ]; then
            ERRORS+=("  expected exit: $expected_exit, got: $got_exit")
        fi
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

run_mkdir_test() {
    local desc="$1"
    local setup="$2"
    local expected_exit="$3"
    local check_fn="$4"
    shift 4
    local args=("$@")

    eval "$setup" 2>/dev/null
    $BIN "${args[@]}" > "$TMPDIR/got" 2> "$TMPDIR/got_err"
    local got_exit=$?
    local got_err=$(cat "$TMPDIR/got_err")

    if [ "$expected_exit" = "$got_exit" ]; then
        if [ -n "$check_fn" ]; then
            eval "$check_fn"
            if [ $? -eq 0 ]; then
                PASS=$((PASS+1))
            else
                FAIL=$((FAIL+1))
                ERRORS+=("FAIL: $desc — post-check failed")
            fi
        else
            PASS=$((PASS+1))
        fi
    else
        FAIL=$((FAIL+1))
        ERRORS+=("FAIL: $desc — expected exit: $expected_exit, got: $got_exit")
        if [ -n "$got_err" ]; then
            ERRORS+=("  stderr: $(echo "$got_err" | head -3)")
        fi
    fi
}

# ── Standard flags ──
run_test_exit_only "--help exit code" --help
run_test_exit_only "--version exit code" --version

# ── FD isolation ──
run_test_fd "--help to stdout" --help
run_test_fd "error to stderr"

# ── Missing operand ──
run_test_error "missing operand (no args)"

# ── Create directory ──
run_mkdir_test "create simple dir" \
    "rm -rf $TMPDIR/test_create" \
    0 \
    "test -d $TMPDIR/test_create" \
    "$TMPDIR/test_create"
rm -rf "$TMPDIR/test_create"

# ── Already exists error ──
mkdir -p "$TMPDIR/exists_test"
$BIN "$TMPDIR/exists_test" > /dev/null 2> "$TMPDIR/exists_err"
got_exit=$?
got_err=$(cat "$TMPDIR/exists_err")
if [ "$got_exit" = "1" ] && echo "$got_err" | grep -qF "File exists"; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: dir already exists — expected exit 1 + 'File exists' in stderr")
    ERRORS+=("  exit=$got_exit, stderr='$got_err'")
fi
rm -rf "$TMPDIR/exists_test"

# ── Multiple directories ──
run_mkdir_test "multiple dirs" \
    "rm -rf $TMPDIR/multi1 $TMPDIR/multi2 $TMPDIR/multi3" \
    0 \
    "test -d $TMPDIR/multi1 && test -d $TMPDIR/multi2 && test -d $TMPDIR/multi3" \
    "$TMPDIR/multi1" "$TMPDIR/multi2" "$TMPDIR/multi3"
rm -rf "$TMPDIR/multi1" "$TMPDIR/multi2" "$TMPDIR/multi3"

# ── -p creates parents ──
run_mkdir_test "-p creates parents" \
    "rm -rf $TMPDIR/ptest" \
    0 \
    "test -d $TMPDIR/ptest/a/b/c" \
    -p "$TMPDIR/ptest/a/b/c"
rm -rf "$TMPDIR/ptest"

# ── -p no error if exists ──
mkdir -p "$TMPDIR/pexist"
$BIN -p "$TMPDIR/pexist" > /dev/null 2>&1
got_exit=$?
if [ "$got_exit" = "0" ]; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: -p no error if exists — expected exit 0, got $got_exit")
fi
rm -rf "$TMPDIR/pexist"

# ── -p deeply nested ──
run_mkdir_test "-p deeply nested" \
    "rm -rf $TMPDIR/deep" \
    0 \
    "test -d $TMPDIR/deep/a/b/c/d/e" \
    -p "$TMPDIR/deep/a/b/c/d/e"
rm -rf "$TMPDIR/deep"

# ── -v verbose output ──
rm -rf "$TMPDIR/verbose_test"
$BIN -v "$TMPDIR/verbose_test" > /dev/null 2> "$TMPDIR/verbose_err"
got_exit=$?
got_err=$(cat "$TMPDIR/verbose_err")
if [ "$got_exit" = "0" ] && echo "$got_err" | grep -q "created directory"; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: -v verbose — expected 'created directory' in stderr")
    ERRORS+=("  exit=$got_exit, stderr='$got_err'")
fi
rm -rf "$TMPDIR/verbose_test"

# ── -v verbose format ──
rm -rf "$TMPDIR/verbose_fmt"
$BIN -v "$TMPDIR/verbose_fmt" 2> "$TMPDIR/verbose_fmt_err"
got_err=$(cat "$TMPDIR/verbose_fmt_err")
expected_pattern="mkdir: created directory '$TMPDIR/verbose_fmt'"
if echo "$got_err" | grep -qF "$expected_pattern"; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: -v format — expected pattern: $expected_pattern")
    ERRORS+=("  got: $got_err")
fi
rm -rf "$TMPDIR/verbose_fmt"

# ── -m mode ──
rm -rf "$TMPDIR/mode_test"
$BIN -m 755 "$TMPDIR/mode_test" > /dev/null 2>&1
got_exit=$?
if [ "$got_exit" = "0" ] && [ -d "$TMPDIR/mode_test" ]; then
    perms=$(stat -c '%a' "$TMPDIR/mode_test" 2>/dev/null || stat -f '%Lp' "$TMPDIR/mode_test" 2>/dev/null)
    if [ "$perms" = "755" ]; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
        ERRORS+=("FAIL: -m 755 — got permissions $perms")
    fi
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: -m 755 — dir not created, exit=$got_exit")
fi
rm -rf "$TMPDIR/mode_test"

# ── -m700 (no space) ──
rm -rf "$TMPDIR/mode_nospace"
$BIN -m700 "$TMPDIR/mode_nospace" > /dev/null 2>&1
got_exit=$?
if [ "$got_exit" = "0" ] && [ -d "$TMPDIR/mode_nospace" ]; then
    perms=$(stat -c '%a' "$TMPDIR/mode_nospace" 2>/dev/null || stat -f '%Lp' "$TMPDIR/mode_nospace" 2>/dev/null)
    if [ "$perms" = "700" ]; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
        ERRORS+=("FAIL: -m700 — got permissions $perms")
    fi
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: -m700 — dir not created, exit=$got_exit")
fi
rm -rf "$TMPDIR/mode_nospace"

# ── --mode=755 ──
rm -rf "$TMPDIR/mode_long"
$BIN --mode=755 "$TMPDIR/mode_long" > /dev/null 2>&1
got_exit=$?
if [ "$got_exit" = "0" ] && [ -d "$TMPDIR/mode_long" ]; then
    perms=$(stat -c '%a' "$TMPDIR/mode_long" 2>/dev/null || stat -f '%Lp' "$TMPDIR/mode_long" 2>/dev/null)
    if [ "$perms" = "755" ]; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
        ERRORS+=("FAIL: --mode=755 — got permissions $perms")
    fi
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: --mode=755 — dir not created, exit=$got_exit")
fi
rm -rf "$TMPDIR/mode_long"

# ── Combined -pv ──
rm -rf "$TMPDIR/pv_test"
$BIN -pv "$TMPDIR/pv_test/a/b" > /dev/null 2> "$TMPDIR/pv_err"
got_exit=$?
got_err=$(cat "$TMPDIR/pv_err")
if [ "$got_exit" = "0" ] && echo "$got_err" | grep -qF "created directory"; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: -pv combined — expected verbose output and exit 0")
    ERRORS+=("  exit=$got_exit, stderr='$got_err'")
fi
rm -rf "$TMPDIR/pv_test"

# ── Double dash ──
run_mkdir_test "-- separator" \
    "rm -rf $TMPDIR/dashdash_test" \
    0 \
    "test -d $TMPDIR/dashdash_test" \
    -- "$TMPDIR/dashdash_test"
rm -rf "$TMPDIR/dashdash_test"

# ── Error message format: "mkdir: cannot create directory 'X': ..." ──
$BIN "$TMPDIR/no_such_parent/child" 2> "$TMPDIR/format_err"
got_err=$(cat "$TMPDIR/format_err")
got_err=$(echo "$got_err" | sed "s|$(basename $BIN)|mkdir|g; s|$BIN|mkdir|g")
if echo "$got_err" | grep -qF "mkdir: cannot create directory '"; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: error format — expected 'mkdir: cannot create directory' pattern")
    ERRORS+=("  got: $got_err")
fi

# ── Error: No such file or directory ──
$BIN "$TMPDIR/no_such_parent/child" 2> "$TMPDIR/noent_err"
got_err=$(cat "$TMPDIR/noent_err")
if echo "$got_err" | grep -qF "No such file or directory"; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: ENOENT message — expected 'No such file or directory'")
    ERRORS+=("  got: $got_err")
fi

# ── Multiple dirs with mixed success/failure ──
rm -rf "$TMPDIR/mixed_ok"
$BIN "$TMPDIR/mixed_ok" "$TMPDIR/no_such_parent_2/child" 2> "$TMPDIR/mixed_err"
got_exit=$?
if [ "$got_exit" = "1" ] && [ -d "$TMPDIR/mixed_ok" ]; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: mixed success/failure — expected exit 1, first dir created")
fi
rm -rf "$TMPDIR/mixed_ok"

# ── Invalid short flag ──
$BIN -Z "$TMPDIR/ztest" 2> "$TMPDIR/invalid_short_err"
got_exit=$?
got_err=$(cat "$TMPDIR/invalid_short_err")
got_err=$(echo "$got_err" | sed "s|$(basename $BIN)|mkdir|g; s|$BIN|mkdir|g")
# GNU mkdir on CI may accept -Z if SELinux is available — just check no crash
if [ "$got_exit" -lt 128 ]; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: flag -Z — signal death ($got_exit)")
fi
rm -rf "$TMPDIR/ztest"

# ── Invalid long flag ──
$BIN --bogus-flag 2> "$TMPDIR/invalid_long_err"
got_exit=$?
got_err=$(cat "$TMPDIR/invalid_long_err")
got_err=$(echo "$got_err" | sed "s|$(basename $BIN)|mkdir|g; s|$BIN|mkdir|g")
if [ "$got_exit" = "1" ] && echo "$got_err" | grep -qF "unrecognized option"; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: invalid long flag --bogus-flag")
    ERRORS+=("  exit=$got_exit, stderr='$got_err'")
fi

# ── Trailing slashes ──
rm -rf "$TMPDIR/trailing_test"
$BIN "$TMPDIR/trailing_test/" > /dev/null 2>&1
got_exit=$?
if [ "$got_exit" = "0" ] && [ -d "$TMPDIR/trailing_test" ]; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: trailing slash — expected dir created, got exit $got_exit")
fi
rm -rf "$TMPDIR/trailing_test"

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
