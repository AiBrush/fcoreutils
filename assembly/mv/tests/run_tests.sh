#!/bin/bash
# Test suite for fmv
# Usage: bash tests/run_tests.sh ./fmv

BIN="${1:-./fmv}"
GNU="mv"
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

run_test_custom() {
    local desc="$1"
    local expected_exit="$2"
    shift 2
    local args=("$@")

    $BIN "${args[@]}" > "$TMPDIR/got" 2> "$TMPDIR/got_err"
    local got_exit=$?

    if [ "$expected_exit" = "$got_exit" ]; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
        ERRORS+=("FAIL: $desc — expected exit: $expected_exit, got: $got_exit")
        if [ -s "$TMPDIR/got_err" ]; then
            ERRORS+=("  stderr: $(cat "$TMPDIR/got_err" | head -3)")
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

# ── Standard flags ──
run_test_exit_only "--help exit code" --help
run_test_exit_only "--version exit code" --version

# ── FD isolation ──
run_test_fd "--help to stdout" --help
run_test_fd "error to stderr"

# ── Error handling ──
run_test_exit_only "missing operand"

# ── Move file ──
echo "hello" > "$TMPDIR/src1"
run_test_custom "move file" 0 "$TMPDIR/src1" "$TMPDIR/dst1"
if [ ! -e "$TMPDIR/src1" ] && [ -f "$TMPDIR/dst1" ]; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: file not moved properly")
fi
CONTENT=$(cat "$TMPDIR/dst1" 2>/dev/null)
if [ "$CONTENT" = "hello" ]; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: moved file content mismatch")
fi
rm -f "$TMPDIR/dst1"

# ── Move overwrite ──
echo "old" > "$TMPDIR/ow_dst"
echo "new" > "$TMPDIR/ow_src"
run_test_custom "move overwrite" 0 "$TMPDIR/ow_src" "$TMPDIR/ow_dst"
CONTENT=$(cat "$TMPDIR/ow_dst" 2>/dev/null)
if [ "$CONTENT" = "new" ]; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: overwrite content mismatch: got '$CONTENT'")
fi
rm -f "$TMPDIR/ow_dst"

# ── No-clobber ──
echo "original" > "$TMPDIR/nc_dst"
echo "replacement" > "$TMPDIR/nc_src"
run_test_custom "no-clobber" 0 -n "$TMPDIR/nc_src" "$TMPDIR/nc_dst"
CONTENT=$(cat "$TMPDIR/nc_dst" 2>/dev/null)
if [ "$CONTENT" = "original" ]; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: no-clobber failed — content was overwritten")
fi
rm -f "$TMPDIR/nc_dst" "$TMPDIR/nc_src"

# ── Move into directory ──
echo "dirtest" > "$TMPDIR/dir_src"
mkdir -p "$TMPDIR/target_dir"
run_test_custom "move into directory" 0 "$TMPDIR/dir_src" "$TMPDIR/target_dir"
if [ -f "$TMPDIR/target_dir/dir_src" ]; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: file not moved into directory")
fi
rm -rf "$TMPDIR/target_dir"

# ── Move directory ──
mkdir -p "$TMPDIR/mvdir/sub"
echo "a" > "$TMPDIR/mvdir/f1"
run_test_custom "move directory" 0 "$TMPDIR/mvdir" "$TMPDIR/mvdir2"
if [ -d "$TMPDIR/mvdir2" ] && [ -f "$TMPDIR/mvdir2/f1" ] && [ ! -e "$TMPDIR/mvdir" ]; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: directory not moved properly")
fi
rm -rf "$TMPDIR/mvdir2"

# ── Verbose output ──
echo "verb" > "$TMPDIR/v_src"
$BIN -v "$TMPDIR/v_src" "$TMPDIR/v_dst" > "$TMPDIR/v_out" 2>&1
if grep -q "renamed" "$TMPDIR/v_out" && grep -q -- "->" "$TMPDIR/v_out"; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: verbose output missing expected format")
    ERRORS+=("  got: $(cat "$TMPDIR/v_out")")
fi
rm -f "$TMPDIR/v_dst"

# ── Move nonexistent source ──
run_test_custom "move nonexistent" 1 "$TMPDIR/nonexistent" "$TMPDIR/dst_ne"

# ── --help ──
$BIN --help > "$TMPDIR/help_out" 2>&1
if grep -q "Usage:" "$TMPDIR/help_out"; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: --help missing Usage:")
fi

# ── --version ──
$BIN --version > "$TMPDIR/ver_out" 2>&1
if grep -q "mv" "$TMPDIR/ver_out"; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: --version missing 'mv'")
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
