#!/bin/bash
# Test suite for frmdir
# Usage: bash tests/run_tests.sh ./frmdir

BIN="$(realpath "${1:-./frmdir}")"
GNU="rmdir"
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

    # Run setup for both GNU and our tool
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
    got_err=$(echo "$got_err" | sed "s|$(basename $BIN)|rmdir|g; s|$BIN|rmdir|g")

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

# Simple test that only checks exit code
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

# Test that checks exit code and stderr pattern
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
    got_err=$(echo "$got_err" | sed "s|$(basename $BIN)|rmdir|g; s|$BIN|rmdir|g")

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

# Custom test function for rmdir-specific tests
run_rmdir_test() {
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

# ── Remove empty directory ──
run_rmdir_test "remove empty dir" \
    "mkdir -p $TMPDIR/test_empty" \
    0 \
    "test ! -d $TMPDIR/test_empty" \
    "$TMPDIR/test_empty"

# ── Nonexistent directory ──
run_test_error "nonexistent dir" "$TMPDIR/nonexistent_dir_xyz"

# ── Non-empty directory ──
mkdir -p "$TMPDIR/notempty/child"
run_test_error "non-empty dir" "$TMPDIR/notempty"
rm -rf "$TMPDIR/notempty"

# ── Not a directory (file) ──
touch "$TMPDIR/afile"
run_test_error "not a directory" "$TMPDIR/afile"
rm -f "$TMPDIR/afile"

# ── Multiple directories ──
run_rmdir_test "multiple empty dirs" \
    "mkdir -p $TMPDIR/multi1 $TMPDIR/multi2 $TMPDIR/multi3" \
    0 \
    "test ! -d $TMPDIR/multi1 && test ! -d $TMPDIR/multi2 && test ! -d $TMPDIR/multi3" \
    "$TMPDIR/multi1" "$TMPDIR/multi2" "$TMPDIR/multi3"

# ── -p removes parent chain (using relative path to avoid climbing into /tmp) ──
mkdir -p "$TMPDIR/ptest/a/b/c"
(cd "$TMPDIR" && $BIN -p ptest/a/b/c) > /dev/null 2>&1
got_exit=$?
if [ "$got_exit" = "0" ] && [ ! -d "$TMPDIR/ptest/a" ]; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: -p removes parent chain — expected exit 0 and dirs removed, got exit $got_exit")
fi

# ── -p with partial chain (parent non-empty) ──
mkdir -p "$TMPDIR/ptest2/a/b/c"
touch "$TMPDIR/ptest2/a/somefile"
# This should remove c and b, but fail on a (non-empty) with exit 1
$BIN -p "$TMPDIR/ptest2/a/b/c" > /dev/null 2>&1
got_exit=$?
if [ ! -d "$TMPDIR/ptest2/a/b" ] && [ -d "$TMPDIR/ptest2/a" ] && [ "$got_exit" = "1" ]; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: -p partial chain — expected b removed, a kept, exit 1")
fi
rm -rf "$TMPDIR/ptest2"

# ── --ignore-fail-on-non-empty ──
mkdir -p "$TMPDIR/ignore_test/child"
$BIN --ignore-fail-on-non-empty "$TMPDIR/ignore_test" > /dev/null 2> "$TMPDIR/ignore_err"
got_exit=$?
got_err=$(cat "$TMPDIR/ignore_err")
if [ "$got_exit" = "0" ] && [ -z "$got_err" ] && [ -d "$TMPDIR/ignore_test" ]; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: --ignore-fail-on-non-empty — expected exit 0, no stderr, dir kept")
    ERRORS+=("  exit=$got_exit, stderr='$got_err', dir_exists=$(test -d $TMPDIR/ignore_test && echo yes || echo no)")
fi
rm -rf "$TMPDIR/ignore_test"

# ── --ignore-fail-on-non-empty does NOT suppress other errors ──
$BIN --ignore-fail-on-non-empty "$TMPDIR/nonexistent_xyz" > /dev/null 2> "$TMPDIR/ignore_err2"
got_exit=$?
if [ "$got_exit" = "1" ]; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: --ignore-fail-on-non-empty nonexistent — expected exit 1, got $got_exit")
fi

# ── -v verbose output ──
mkdir -p "$TMPDIR/verbose_test"
$BIN -v "$TMPDIR/verbose_test" > /dev/null 2> "$TMPDIR/verbose_err"
got_exit=$?
got_err=$(cat "$TMPDIR/verbose_err")
if [ "$got_exit" = "0" ] && echo "$got_err" | grep -q "removing directory"; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: -v verbose — expected 'removing directory' in stderr")
    ERRORS+=("  exit=$got_exit, stderr='$got_err'")
fi

# ── -v verbose format check ──
mkdir -p "$TMPDIR/verbose_fmt"
$BIN -v "$TMPDIR/verbose_fmt" 2> "$TMPDIR/verbose_fmt_err"
got_err=$(cat "$TMPDIR/verbose_fmt_err")
expected_pattern="rmdir: removing directory, '$TMPDIR/verbose_fmt'"
if echo "$got_err" | grep -qF "$expected_pattern"; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: -v format — expected pattern: $expected_pattern")
    ERRORS+=("  got: $got_err")
fi

# ── Combined -pv ──
mkdir -p "$TMPDIR/pv_test/a/b"
(cd "$TMPDIR" && $BIN -pv pv_test/a/b) > /dev/null 2> "$TMPDIR/pv_err"
got_exit=$?
got_err=$(cat "$TMPDIR/pv_err")
# Should have verbose output for each dir removed
if [ "$got_exit" = "0" ] && echo "$got_err" | grep -qF "removing directory"; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: -pv combined — expected verbose output and exit 0")
    ERRORS+=("  exit=$got_exit, stderr='$got_err'")
fi
rm -rf "$TMPDIR/pv_test"

# ── Double dash ──
run_rmdir_test "-- separator" \
    "mkdir -p $TMPDIR/dashdash_test" \
    0 \
    "test ! -d $TMPDIR/dashdash_test" \
    -- "$TMPDIR/dashdash_test"

# ── Error message format: "rmdir: failed to remove 'X': ..." ──
$BIN "$TMPDIR/nonexistent_format_test" 2> "$TMPDIR/format_err"
got_err=$(cat "$TMPDIR/format_err")
if echo "$got_err" | grep -qF "rmdir: failed to remove '"; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: error format — expected 'rmdir: failed to remove' pattern")
    ERRORS+=("  got: $got_err")
fi

# ── Error message: No such file or directory ──
$BIN "$TMPDIR/no_such_dir" 2> "$TMPDIR/noent_err"
got_err=$(cat "$TMPDIR/noent_err")
if echo "$got_err" | grep -qF "No such file or directory"; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: ENOENT message — expected 'No such file or directory'")
    ERRORS+=("  got: $got_err")
fi

# ── Error message: Directory not empty ──
mkdir -p "$TMPDIR/notempty2/child"
$BIN "$TMPDIR/notempty2" 2> "$TMPDIR/notempty_err"
got_err=$(cat "$TMPDIR/notempty_err")
if echo "$got_err" | grep -qF "Directory not empty"; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: ENOTEMPTY message — expected 'Directory not empty'")
    ERRORS+=("  got: $got_err")
fi
rm -rf "$TMPDIR/notempty2"

# ── Error message: Not a directory ──
touch "$TMPDIR/notadir_file"
$BIN "$TMPDIR/notadir_file" 2> "$TMPDIR/notdir_err"
got_err=$(cat "$TMPDIR/notdir_err")
if echo "$got_err" | grep -qF "Not a directory"; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: ENOTDIR message — expected 'Not a directory'")
    ERRORS+=("  got: $got_err")
fi
rm -f "$TMPDIR/notadir_file"

# ── Multiple dirs with mixed success/failure ──
mkdir -p "$TMPDIR/mixed_ok"
$BIN "$TMPDIR/mixed_ok" "$TMPDIR/mixed_no_exist" 2> "$TMPDIR/mixed_err"
got_exit=$?
if [ "$got_exit" = "1" ] && [ ! -d "$TMPDIR/mixed_ok" ]; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: mixed success/failure — expected exit 1, first dir removed")
fi

# ── Invalid short flag ──
$BIN -Z "$TMPDIR" 2> "$TMPDIR/invalid_short_err"
got_exit=$?
got_err=$(cat "$TMPDIR/invalid_short_err")
if [ "$got_exit" = "1" ] && echo "$got_err" | grep -qF "invalid option"; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: invalid short flag -Z")
    ERRORS+=("  exit=$got_exit, stderr='$got_err'")
fi

# ── Invalid long flag ──
$BIN --bogus-flag 2> "$TMPDIR/invalid_long_err"
got_exit=$?
got_err=$(cat "$TMPDIR/invalid_long_err")
if [ "$got_exit" = "1" ] && echo "$got_err" | grep -qF "unrecognized option"; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: invalid long flag --bogus-flag")
    ERRORS+=("  exit=$got_exit, stderr='$got_err'")
fi

# ── -p with deeply nested dirs ──
mkdir -p "$TMPDIR/deep/a/b/c/d/e"
(cd "$TMPDIR" && $BIN -p deep/a/b/c/d/e) > /dev/null 2>&1
got_exit=$?
if [ "$got_exit" = "0" ] && [ ! -d "$TMPDIR/deep/a" ]; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: -p deep nesting — expected exit 0 and dirs removed, got exit $got_exit")
fi

# ── Trailing slashes in path ──
run_rmdir_test "trailing slashes" \
    "mkdir -p $TMPDIR/trailing_test" \
    0 \
    "test ! -d $TMPDIR/trailing_test" \
    "$TMPDIR/trailing_test/"

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
