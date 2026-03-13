#!/bin/bash
# Test suite for fcp
# Usage: bash tests/run_tests.sh ./fcp

BIN="${1:-./fcp}"
GNU="cp"
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

# ── Copy file ──
echo "hello world" > "$TMPDIR/src1"
run_test_custom "copy file" 0 "$TMPDIR/src1" "$TMPDIR/dst1"
if [ -f "$TMPDIR/src1" ] && [ -f "$TMPDIR/dst1" ]; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: copy failed — source or dest missing")
fi
CONTENT=$(cat "$TMPDIR/dst1" 2>/dev/null)
if [ "$CONTENT" = "hello world" ]; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: copied content mismatch: '$CONTENT'")
fi
rm -f "$TMPDIR/dst1"

# ── Copy preserves source ──
if [ -f "$TMPDIR/src1" ]; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: source file removed after copy")
fi

# ── Copy overwrites existing ──
echo "old" > "$TMPDIR/ow_dst"
run_test_custom "copy overwrite" 0 "$TMPDIR/src1" "$TMPDIR/ow_dst"
CONTENT=$(cat "$TMPDIR/ow_dst" 2>/dev/null)
if [ "$CONTENT" = "hello world" ]; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: overwrite content mismatch")
fi
rm -f "$TMPDIR/ow_dst"

# ── No-clobber ──
echo "original" > "$TMPDIR/nc_dst"
run_test_custom "no-clobber" 0 -n "$TMPDIR/src1" "$TMPDIR/nc_dst"
CONTENT=$(cat "$TMPDIR/nc_dst" 2>/dev/null)
if [ "$CONTENT" = "original" ]; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: no-clobber failed")
fi
rm -f "$TMPDIR/nc_dst"

# ── Copy into directory ──
mkdir -p "$TMPDIR/target_dir"
run_test_custom "copy into directory" 0 "$TMPDIR/src1" "$TMPDIR/target_dir"
if [ -f "$TMPDIR/target_dir/src1" ]; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: file not copied into directory")
fi
rm -rf "$TMPDIR/target_dir"

# ── Hard link ──
run_test_custom "hard link copy" 0 -l "$TMPDIR/src1" "$TMPDIR/hl_dst"
if [ -f "$TMPDIR/hl_dst" ]; then
    SRC_INO=$(stat -c %i "$TMPDIR/src1" 2>/dev/null)
    DST_INO=$(stat -c %i "$TMPDIR/hl_dst" 2>/dev/null)
    if [ "$SRC_INO" = "$DST_INO" ]; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
        ERRORS+=("FAIL: hard link inode mismatch")
    fi
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: hard link not created")
fi
rm -f "$TMPDIR/hl_dst"

# ── Recursive copy ──
mkdir -p "$TMPDIR/rdir/sub1/sub2"
echo "a" > "$TMPDIR/rdir/f1"
echo "b" > "$TMPDIR/rdir/sub1/f2"
echo "c" > "$TMPDIR/rdir/sub1/sub2/f3"
run_test_custom "recursive copy" 0 -r "$TMPDIR/rdir" "$TMPDIR/rdir2"
if [ -d "$TMPDIR/rdir2" ] && [ -f "$TMPDIR/rdir2/f1" ] && [ -f "$TMPDIR/rdir2/sub1/f2" ] && [ -f "$TMPDIR/rdir2/sub1/sub2/f3" ]; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: recursive copy incomplete")
fi
# Check content
C1=$(cat "$TMPDIR/rdir2/f1" 2>/dev/null)
C2=$(cat "$TMPDIR/rdir2/sub1/f2" 2>/dev/null)
C3=$(cat "$TMPDIR/rdir2/sub1/sub2/f3" 2>/dev/null)
if [ "$C1" = "a" ] && [ "$C2" = "b" ] && [ "$C3" = "c" ]; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: recursive copy content mismatch")
fi
# Original preserved
if [ -d "$TMPDIR/rdir" ] && [ -f "$TMPDIR/rdir/f1" ]; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: original directory modified after copy")
fi
rm -rf "$TMPDIR/rdir" "$TMPDIR/rdir2"

# ── Copy without -r on directory ──
mkdir -p "$TMPDIR/norecur"
run_test_custom "dir without -r" 1 "$TMPDIR/norecur" "$TMPDIR/norecur2"
rmdir "$TMPDIR/norecur"

# ── Verbose ──
$BIN -v "$TMPDIR/src1" "$TMPDIR/v_dst" > "$TMPDIR/v_out" 2>&1
if grep -q "'" "$TMPDIR/v_out" && grep -q -- "->" "$TMPDIR/v_out"; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: verbose output format incorrect")
    ERRORS+=("  got: $(cat "$TMPDIR/v_out")")
fi
rm -f "$TMPDIR/v_dst"

# ── Copy nonexistent source ──
run_test_custom "nonexistent source" 1 "$TMPDIR/nonexistent" "$TMPDIR/ne_dst"

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
if grep -q "cp" "$TMPDIR/ver_out"; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: --version missing 'cp'")
fi

# ── Large file copy ──
dd if=/dev/urandom of="$TMPDIR/large" bs=1024 count=100 2>/dev/null
run_test_custom "copy 100KB file" 0 "$TMPDIR/large" "$TMPDIR/large_dst"
if cmp -s "$TMPDIR/large" "$TMPDIR/large_dst"; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: large file copy content mismatch")
fi
rm -f "$TMPDIR/large" "$TMPDIR/large_dst"

# Clean up
rm -f "$TMPDIR/src1"

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
