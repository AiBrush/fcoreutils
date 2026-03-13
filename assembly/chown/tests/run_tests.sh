#!/bin/bash
# Test suite for fchown (assembly chown)
# Usage: bash tests/run_tests.sh ./fchown

BIN="$(realpath "${1:-./fchown}")"
GNU="chown"
PASS=0
FAIL=0
ERRORS=()
TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT

ME=$(whoami)
MY_GROUP=$(id -gn)
MY_UID=$(id -u)
MY_GID=$(id -g)

run_test() {
    local desc="$1"
    shift
    local gnu_exit our_exit

    "$GNU" "$@" 2>/dev/null
    gnu_exit=$?
    "$BIN" "$@" 2>/dev/null
    our_exit=$?

    if [ "$gnu_exit" = "$our_exit" ]; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
        ERRORS+=("FAIL: $desc — expected exit $gnu_exit, got $our_exit")
    fi
}

check_owner() {
    local desc="$1"
    local file="$2"
    local expected_uid="$3"
    local expected_gid="$4"
    local got_uid got_gid
    got_uid=$(stat -c '%u' "$file" 2>/dev/null)
    got_gid=$(stat -c '%g' "$file" 2>/dev/null)
    if [ "$expected_uid" = "$got_uid" ] && [ "$expected_gid" = "$got_gid" ]; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
        ERRORS+=("FAIL: $desc — expected uid:gid=$expected_uid:$expected_gid, got $got_uid:$got_gid")
    fi
}

echo "=== Help/Version ==="
run_test "--help" --help
run_test "--version" --version

echo "=== Basic chown ==="
touch "$TMPDIR/f1"
$BIN "$ME" "$TMPDIR/f1" 2>/dev/null
check_owner "chown user" "$TMPDIR/f1" "$MY_UID" "$MY_GID"

touch "$TMPDIR/f2"
$BIN "$ME:$MY_GROUP" "$TMPDIR/f2" 2>/dev/null
check_owner "chown user:group" "$TMPDIR/f2" "$MY_UID" "$MY_GID"

touch "$TMPDIR/f3"
$BIN ":$MY_GROUP" "$TMPDIR/f3" 2>/dev/null
check_owner "chown :group" "$TMPDIR/f3" "$MY_UID" "$MY_GID"

echo "=== Numeric UID:GID ==="
touch "$TMPDIR/f4"
$BIN "$MY_UID:$MY_GID" "$TMPDIR/f4" 2>/dev/null
check_owner "chown uid:gid" "$TMPDIR/f4" "$MY_UID" "$MY_GID"

echo "=== Error handling ==="
run_test "nonexistent file" "$ME" "$TMPDIR/nonexistent_file_xyz"
run_test "no arguments" 2>/dev/null

echo "=== Multiple files ==="
touch "$TMPDIR/m1" "$TMPDIR/m2" "$TMPDIR/m3"
$BIN "$ME" "$TMPDIR/m1" "$TMPDIR/m2" "$TMPDIR/m3" 2>/dev/null
rc=$?
if [ "$rc" = "0" ]; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: multiple files — exit $rc")
fi

echo "=== Verbose ==="
touch "$TMPDIR/vf"
out=$($BIN -v "$ME" "$TMPDIR/vf" 2>&1)
rc=$?
if [ "$rc" = "0" ]; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: verbose mode — exit $rc")
fi

echo "=== No-dereference ==="
touch "$TMPDIR/target"
ln -s "$TMPDIR/target" "$TMPDIR/link"
$BIN -h "$ME" "$TMPDIR/link" 2>/dev/null
rc=$?
if [ "$rc" = "0" ]; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: no-dereference — exit $rc")
fi

echo ""
echo "Results: $PASS passed, $FAIL failed out of $((PASS+FAIL)) tests"
echo ""
if [ ${#ERRORS[@]} -gt 0 ]; then
    for e in "${ERRORS[@]}"; do
        echo "  $e"
    done
    echo ""
    echo "$FAIL TESTS FAILED"
    exit 1
else
    echo "ALL TESTS PASSED"
fi
