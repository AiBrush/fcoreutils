#!/bin/bash
# Test suite for fchgrp (assembly chgrp)
# Usage: bash tests/run_tests.sh [./fchgrp]

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TOOL_DIR="$(dirname "$SCRIPT_DIR")"

BIN="${1:-$TOOL_DIR/fchgrp}"
if [ ! -x "$BIN" ]; then
    BIN="$(realpath "${1:-./fchgrp}" 2>/dev/null)"
fi
GNU="chgrp"
PASS=0
FAIL=0
ERRORS=()
TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT

MY_GROUP=$(id -gn)
MY_GID=$(id -g)

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

check_group() {
    local desc="$1"
    local file="$2"
    local expected_gid="$3"
    local got_gid
    got_gid=$(stat -c '%g' "$file" 2>/dev/null)
    if [ "$expected_gid" = "$got_gid" ]; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
        ERRORS+=("FAIL: $desc — expected gid $expected_gid, got $got_gid")
    fi
}

echo "=== fchgrp Test Suite ==="
echo "Binary: $BIN"
echo ""

# ── Standard flags ──
run_test_exit_only "--help exit code" --help
run_test_exit_only "--version exit code" --version

# ── Basic group change by name ──
touch "$TMPDIR/f1"
$BIN "$MY_GROUP" "$TMPDIR/f1" 2>/dev/null
check_group "chgrp by name" "$TMPDIR/f1" "$MY_GID"

# ── Basic group change by numeric gid ──
touch "$TMPDIR/f2"
$BIN "$MY_GID" "$TMPDIR/f2" 2>/dev/null
check_group "chgrp by numeric gid" "$TMPDIR/f2" "$MY_GID"

# ── Multiple files ──
touch "$TMPDIR/f3" "$TMPDIR/f4"
$BIN "$MY_GROUP" "$TMPDIR/f3" "$TMPDIR/f4" 2>/dev/null
rc=$?
check_group "chgrp multiple files (f3)" "$TMPDIR/f3" "$MY_GID"
check_group "chgrp multiple files (f4)" "$TMPDIR/f4" "$MY_GID"

# ── Missing operand ──
$BIN 2>/dev/null
rc=$?
if [ "$rc" -ne 0 ]; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: missing operand — expected nonzero exit, got 0")
fi

# ── Missing file operand ──
$BIN "$MY_GROUP" 2>/dev/null
rc=$?
if [ "$rc" -ne 0 ]; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: missing file operand — expected nonzero exit, got 0")
fi

# ── Nonexistent file ──
$BIN "$MY_GROUP" "$TMPDIR/nonexistent_$$" 2>/dev/null
rc=$?
if [ "$rc" -ne 0 ]; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: nonexistent file — expected nonzero exit, got 0")
fi

# ── Invalid group ──
$BIN "nonexistent_group_xyz_$$" "$TMPDIR/f1" 2>/dev/null
rc=$?
if [ "$rc" -ne 0 ]; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: invalid group — expected nonzero exit, got 0")
fi

# ── --reference ──
touch "$TMPDIR/ref_file" "$TMPDIR/target_file"
$GNU "$MY_GROUP" "$TMPDIR/ref_file" 2>/dev/null
$BIN --reference="$TMPDIR/ref_file" "$TMPDIR/target_file" 2>/dev/null
ref_gid=$(stat -c '%g' "$TMPDIR/ref_file")
target_gid=$(stat -c '%g' "$TMPDIR/target_file")
if [ "$ref_gid" = "$target_gid" ]; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: --reference — expected gid $ref_gid, got $target_gid")
fi

# ── Verbose flag produces output ──
touch "$TMPDIR/f5"
output=$($BIN -v "$MY_GROUP" "$TMPDIR/f5" 2>&1)
if [ -n "$output" ]; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: -v flag — expected verbose output, got none")
fi

# ── Double dash ──
touch "$TMPDIR/f6"
$BIN -- "$MY_GROUP" "$TMPDIR/f6" 2>/dev/null
rc=$?
if [ "$rc" -eq 0 ]; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: double dash — expected exit 0, got $rc")
fi

# ── Unknown option ──
$BIN -Z "$MY_GROUP" "$TMPDIR/f1" 2>/dev/null
rc=$?
if [ "$rc" -ne 0 ]; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: unknown option -Z — expected nonzero exit, got 0")
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
