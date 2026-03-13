#!/bin/bash
# Test suite for frm
# Usage: bash tests/run_tests.sh ./frm

BIN="${1:-./frm}"
GNU="rm"
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

# ── Missing operand ──
run_test_exit_only "missing operand (no args)"

# ── -f no args exits 0 ──
run_test_custom "-f with no args" 0 -f

# ── Remove single file ──
echo "hello" > "$TMPDIR/f1"
run_test_custom "remove file" 0 "$TMPDIR/f1"
if [ ! -e "$TMPDIR/f1" ]; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: file not removed")
fi

# ── Remove multiple files ──
echo "a" > "$TMPDIR/m1"
echo "b" > "$TMPDIR/m2"
echo "c" > "$TMPDIR/m3"
run_test_custom "remove multiple files" 0 "$TMPDIR/m1" "$TMPDIR/m2" "$TMPDIR/m3"
if [ ! -e "$TMPDIR/m1" ] && [ ! -e "$TMPDIR/m2" ] && [ ! -e "$TMPDIR/m3" ]; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: not all files removed")
fi

# ── Remove nonexistent file ──
run_test_custom "remove nonexistent" 1 "$TMPDIR/nonexistent"

# ── Force nonexistent ──
run_test_custom "force nonexistent" 0 -f "$TMPDIR/nonexistent"

# ── Remove directory without -r fails ──
mkdir -p "$TMPDIR/dir1"
run_test_custom "remove dir without -r" 1 "$TMPDIR/dir1"
# Dir should still exist
if [ -d "$TMPDIR/dir1" ]; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: dir removed without -r")
fi
rmdir "$TMPDIR/dir1"

# ── Remove empty directory with -d ──
mkdir -p "$TMPDIR/emptydir"
run_test_custom "remove empty dir with -d" 0 -d "$TMPDIR/emptydir"
if [ ! -e "$TMPDIR/emptydir" ]; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: empty dir not removed with -d")
fi

# ── Recursive remove ──
mkdir -p "$TMPDIR/rdir/sub1/sub2"
echo "a" > "$TMPDIR/rdir/f1"
echo "b" > "$TMPDIR/rdir/sub1/f2"
echo "c" > "$TMPDIR/rdir/sub1/sub2/f3"
run_test_custom "recursive remove" 0 -r "$TMPDIR/rdir"
if [ ! -e "$TMPDIR/rdir" ]; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: recursive remove incomplete")
fi

# ── Recursive remove with -v ──
mkdir -p "$TMPDIR/vdir/sub"
echo "a" > "$TMPDIR/vdir/f1"
echo "b" > "$TMPDIR/vdir/sub/f2"
$BIN -rv "$TMPDIR/vdir" > "$TMPDIR/verbose_out" 2>&1
if grep -q "removed" "$TMPDIR/verbose_out"; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: verbose output missing 'removed'")
fi

# ── Remove symlink (not its target) ──
echo "target" > "$TMPDIR/link_target"
ln -s "$TMPDIR/link_target" "$TMPDIR/link_sym"
run_test_custom "remove symlink" 0 "$TMPDIR/link_sym"
if [ ! -L "$TMPDIR/link_sym" ] && [ -f "$TMPDIR/link_target" ]; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: symlink removal failed or target removed")
fi
rm -f "$TMPDIR/link_target"

# ── --help produces output ──
$BIN --help > "$TMPDIR/help_out" 2>&1
if grep -q "Usage:" "$TMPDIR/help_out"; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: --help missing Usage:")
fi

# ── --version produces output ──
$BIN --version > "$TMPDIR/ver_out" 2>&1
if grep -q "rm" "$TMPDIR/ver_out"; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: --version missing 'rm'")
fi

# ── Error message contains path ──
$BIN "$TMPDIR/nofile_xyz" 2> "$TMPDIR/err_out"
if grep -q "nofile_xyz" "$TMPDIR/err_out"; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: error msg doesn't contain filename")
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
