#!/bin/bash
# Test suite for finstall
# Usage: bash tests/run_tests.sh ./finstall

BIN="${1:-./finstall}"
GNU="install"
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

    if echo "${args[@]}" | grep -q "\-\-help"; then
        if [ -s "$TMPDIR/stdout" ] && [ ! -s "$TMPDIR/stderr" ]; then
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

# ── Basic file install ──
echo "test content" > "$TMPDIR/source.txt"
$BIN "$TMPDIR/source.txt" "$TMPDIR/dest.txt" 2>/dev/null
got=$(cat "$TMPDIR/dest.txt" 2>/dev/null)
if [ "$got" = "test content" ]; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: basic file install")
fi

# ── Default mode is 755 ──
$BIN "$TMPDIR/source.txt" "$TMPDIR/mode_test.txt" 2>/dev/null
perms=$(stat -c '%a' "$TMPDIR/mode_test.txt" 2>/dev/null)
if [ "$perms" = "755" ]; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: default mode should be 755, got: $perms")
fi

# ── Custom mode ──
$BIN -m 644 "$TMPDIR/source.txt" "$TMPDIR/mode644.txt" 2>/dev/null
perms=$(stat -c '%a' "$TMPDIR/mode644.txt" 2>/dev/null)
if [ "$perms" = "644" ]; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: -m 644 mode, got: $perms")
fi

# ── Create directory (-d) ──
$BIN -d "$TMPDIR/newdir" 2>/dev/null
if [ -d "$TMPDIR/newdir" ]; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: -d create directory")
fi

# ── Create nested directories (-d) ──
$BIN -d "$TMPDIR/nested/a/b/c" 2>/dev/null
if [ -d "$TMPDIR/nested/a/b/c" ]; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: -d create nested directories")
fi

# ── Install to directory ──
mkdir -p "$TMPDIR/target_dir"
$BIN "$TMPDIR/source.txt" "$TMPDIR/target_dir/" 2>/dev/null
if [ -f "$TMPDIR/target_dir/source.txt" ]; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: install to directory")
fi

# ── Install with -D (create leading dirs) ──
$BIN -D "$TMPDIR/source.txt" "$TMPDIR/deep/path/dest.txt" 2>/dev/null
if [ -f "$TMPDIR/deep/path/dest.txt" ]; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: -D create leading directories")
fi

# ── Verbose mode ──
output=$($BIN -v "$TMPDIR/source.txt" "$TMPDIR/verbose_dest.txt" 2>&1)
if [ -f "$TMPDIR/verbose_dest.txt" ]; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: verbose mode install")
fi

# ── Overwrite existing file ──
echo "old" > "$TMPDIR/overwrite.txt"
echo "new" > "$TMPDIR/new_source.txt"
$BIN "$TMPDIR/new_source.txt" "$TMPDIR/overwrite.txt" 2>/dev/null
got=$(cat "$TMPDIR/overwrite.txt")
if [ "$got" = "new" ]; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: overwrite existing file")
fi

# ── Missing operand ──
$BIN 2>/dev/null
if [ $? -ne 0 ]; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: missing operand should fail")
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
