#!/bin/bash
# Test suite for fshred
# Usage: bash tests/run_tests.sh ./fshred

BIN="${1:-./fshred}"
GNU="/usr/bin/shred"
TOOL="shred"

PASS=0
FAIL=0
ERRORS=()

TMPDIR=$(mktemp -d /tmp/fshred_test.XXXXXX)
trap "rm -rf $TMPDIR" EXIT

run_test() {
    local desc="$1"
    shift
    local expected_pass="$1"
    shift

    eval "$@"
    local result=$?

    if [ "$result" -eq 0 ]; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
        ERRORS+=("FAIL: $desc")
    fi
}

# ── --help ────────────────────────────────────────────────
run_test "--help exits 0" true \
    '$BIN --help > /dev/null 2>&1'

run_test "--help output non-empty" true \
    'test -n "$($BIN --help 2>&1)"'

run_test "--help contains Usage" true \
    '$BIN --help 2>&1 | grep -q "Usage:"'

# ── --version ─────────────────────────────────────────────
run_test "--version exits 0" true \
    '$BIN --version > /dev/null 2>&1'

run_test "--version contains shred" true \
    '$BIN --version 2>&1 | grep -q "shred"'

# ── no args ───────────────────────────────────────────────
run_test "no args exits 1" true \
    '! $BIN 2>/dev/null'

run_test "no args prints missing file operand" true \
    '$BIN 2>&1 | grep -q "missing file operand"'

run_test "no args prints try help" true \
    '$BIN 2>&1 | grep -q "Try .* --help"'

# ── basic overwrite ───────────────────────────────────────
echo "This is secret data that should be overwritten" > "$TMPDIR/overwrite.txt"
ORIG_CONTENT=$(cat "$TMPDIR/overwrite.txt")

run_test "basic overwrite exits 0" true \
    '$BIN "$TMPDIR/overwrite.txt"'

run_test "file still exists after overwrite" true \
    'test -f "$TMPDIR/overwrite.txt"'

run_test "content changed after overwrite" true \
    'test "$(cat "$TMPDIR/overwrite.txt" | head -c 48)" != "$ORIG_CONTENT"'

# ── -n iterations ─────────────────────────────────────────
echo "iter test" > "$TMPDIR/iter.txt"

run_test "-n 5 exits 0" true \
    '$BIN -n 5 "$TMPDIR/iter.txt"'

run_test "-n 5 verbose shows 5 passes" true \
    'echo "data" > "$TMPDIR/iter2.txt" && test "$($BIN -v -n 5 "$TMPDIR/iter2.txt" 2>&1 | grep -c "pass")" -eq 5'

# ── -z zero pass ──────────────────────────────────────────
echo "zero test data" > "$TMPDIR/zero.txt"

run_test "-z exits 0" true \
    '$BIN -z -x "$TMPDIR/zero.txt"'

run_test "-z leaves file with all zeros" true \
    'test "$(od -A n -t x1 "$TMPDIR/zero.txt" | tr -d " \n" | tr -d "0")" = ""'

# ── -z verbose shows 000000 ──────────────────────────────
echo "verbose zero" > "$TMPDIR/vzero.txt"

run_test "-z verbose shows (000000)" true \
    '$BIN -v -n 1 -z "$TMPDIR/vzero.txt" 2>&1 | grep -q "(000000)"'

run_test "-z verbose shows (random)" true \
    '$BIN -v -n 1 -z "$TMPDIR/vzero.txt" 2>&1 | grep -q "(random)"'

# ── pass count with -z ────────────────────────────────────
echo "count" > "$TMPDIR/count.txt"

run_test "-n 2 -z shows 3 total passes" true \
    'test "$($BIN -v -n 2 -z "$TMPDIR/count.txt" 2>&1 | grep -c "pass")" -eq 3'

run_test "-n 2 -z last pass is 3/3 (000000)" true \
    '$BIN -v -n 2 -z "$TMPDIR/count.txt" 2>&1 | grep -q "pass 3/3 (000000)"'

# ── -n 0 -z (only zero pass) ─────────────────────────────
echo "only zero" > "$TMPDIR/onlyzero.txt"

run_test "-n 0 -z exits 0" true \
    '$BIN -v -n 0 -z "$TMPDIR/onlyzero.txt" 2>&1 | grep -q "pass 1/1 (000000)"'

# ── -u remove ─────────────────────────────────────────────
echo "remove me" > "$TMPDIR/remove.txt"

run_test "-u exits 0" true \
    '$BIN -u "$TMPDIR/remove.txt"'

run_test "-u removes file" true \
    '! test -f "$TMPDIR/remove.txt"'

# ── --remove=unlink ───────────────────────────────────────
echo "unlink me" > "$TMPDIR/unlink.txt"

run_test "--remove=unlink exits 0" true \
    '$BIN --remove=unlink "$TMPDIR/unlink.txt"'

run_test "--remove=unlink removes file" true \
    '! test -f "$TMPDIR/unlink.txt"'

# ── --remove=wipe ─────────────────────────────────────────
echo "wipe me" > "$TMPDIR/wipe.txt"

run_test "--remove=wipe exits 0" true \
    '$BIN --remove=wipe "$TMPDIR/wipe.txt"'

run_test "--remove=wipe removes file" true \
    '! test -f "$TMPDIR/wipe.txt"'

# ── --remove=wipesync ─────────────────────────────────────
echo "wipesync me" > "$TMPDIR/wipesync.txt"

run_test "--remove=wipesync exits 0" true \
    '$BIN --remove=wipesync "$TMPDIR/wipesync.txt"'

run_test "--remove=wipesync removes file" true \
    '! test -f "$TMPDIR/wipesync.txt"'

# ── -u verbose ────────────────────────────────────────────
echo "verbose remove" > "$TMPDIR/vremove.txt"

run_test "-u -v shows removing" true \
    '$BIN -v -n 1 -u "$TMPDIR/vremove.txt" 2>&1 | grep -q "removing"'

echo "verbose remove 2" > "$TMPDIR/vremove2.txt"

run_test "-u -v shows removed" true \
    '$BIN -v -n 1 -u "$TMPDIR/vremove2.txt" 2>&1 | grep -q "removed"'

echo "verbose remove 3" > "$TMPDIR/vremove3.txt"

run_test "-u -v shows renamed to" true \
    '$BIN -v -n 1 -u "$TMPDIR/vremove3.txt" 2>&1 | grep -q "renamed to"'

# ── --remove=unlink verbose ───────────────────────────────
echo "unlink verbose" > "$TMPDIR/uvremove.txt"

run_test "--remove=unlink -v shows removing" true \
    '$BIN -v -n 1 --remove=unlink "$TMPDIR/uvremove.txt" 2>&1 | grep -q "removing"'

echo "unlink verbose2" > "$TMPDIR/uvremove2.txt"

run_test "--remove=unlink -v does NOT show renamed" true \
    '! $BIN -v -n 1 --remove=unlink "$TMPDIR/uvremove2.txt" 2>&1 | grep -q "renamed"'

# ── -x exact ──────────────────────────────────────────────
dd if=/dev/zero of="$TMPDIR/exact.txt" bs=1 count=11 2>/dev/null

run_test "-x -z exact file size" true \
    '$BIN -x -z "$TMPDIR/exact.txt" && test "$(wc -c < "$TMPDIR/exact.txt")" -eq 11'

# ── without -x, rounds up ────────────────────────────────
dd if=/dev/zero of="$TMPDIR/roundup.txt" bs=1 count=11 2>/dev/null

run_test "without -x rounds up file size" true \
    '$BIN -z "$TMPDIR/roundup.txt" && test "$(wc -c < "$TMPDIR/roundup.txt")" -gt 11'

# ── -s size override ─────────────────────────────────────
echo "size" > "$TMPDIR/sized.txt"

run_test "-s 1024 -z -x writes exact 1024 bytes" true \
    '$BIN -s 1024 -z "$TMPDIR/sized.txt" && test "$(wc -c < "$TMPDIR/sized.txt")" -eq 1024'

# ── -s with K suffix ─────────────────────────────────────
echo "size k" > "$TMPDIR/sizedk.txt"

run_test "-s 2K writes 2048 bytes" true \
    '$BIN -s 2K -z "$TMPDIR/sizedk.txt" && test "$(wc -c < "$TMPDIR/sizedk.txt")" -eq 2048'

# ── -f force on read-only file ───────────────────────────
echo "readonly" > "$TMPDIR/readonly.txt"
chmod 444 "$TMPDIR/readonly.txt"

run_test "-f on read-only file exits 0" true \
    '$BIN -f "$TMPDIR/readonly.txt"'

# ── without -f on read-only ──────────────────────────────
echo "readonly2" > "$TMPDIR/readonly2.txt"
chmod 444 "$TMPDIR/readonly2.txt"

run_test "without -f on read-only exits 1" true \
    '! $BIN "$TMPDIR/readonly2.txt" 2>/dev/null'

# ── nonexistent file ──────────────────────────────────────
run_test "nonexistent file exits 1" true \
    '! $BIN "$TMPDIR/nonexistent_xyz" 2>/dev/null'

run_test "nonexistent file error message" true \
    '$BIN "$TMPDIR/nonexistent_xyz" 2>&1 | grep -q "failed to open for writing"'

run_test "nonexistent file error mentions No such file" true \
    '$BIN "$TMPDIR/nonexistent_xyz" 2>&1 | grep -q "No such file"'

# ── invalid option ────────────────────────────────────────
run_test "invalid short option -q" true \
    '! $BIN -q file 2>/dev/null'

run_test "invalid option shows error" true \
    '$BIN -q file 2>&1 | grep -q "invalid option"'

# ── invalid long option ──────────────────────────────────
run_test "invalid long option" true \
    '! $BIN --invalid-opt file 2>/dev/null'

run_test "unrecognized option message" true \
    '$BIN --invalid-opt file 2>&1 | grep -q "unrecognized option"'

# ── --remove with invalid HOW ─────────────────────────────
run_test "--remove=invalid exits 1" true \
    '! $BIN --remove=invalid file 2>/dev/null'

# ── combined flags ────────────────────────────────────────
echo "combined" > "$TMPDIR/combined.txt"

run_test "-vfzn2 combined flags" true \
    'test "$($BIN -vfzn2 "$TMPDIR/combined.txt" 2>&1 | grep -c "pass")" -eq 3'

# ── multiple files ────────────────────────────────────────
echo "file1" > "$TMPDIR/multi1.txt"
echo "file2" > "$TMPDIR/multi2.txt"

run_test "multiple files exits 0" true \
    '$BIN -n 1 "$TMPDIR/multi1.txt" "$TMPDIR/multi2.txt"'

run_test "multiple files both overwritten" true \
    'test "$(cat "$TMPDIR/multi1.txt")" != "file1" && test "$(cat "$TMPDIR/multi2.txt")" != "file2"'

# ── -- separator ──────────────────────────────────────────
echo "dashdash" > "$TMPDIR/dashdash.txt"

run_test "-- separator works" true \
    '$BIN -n 1 -- "$TMPDIR/dashdash.txt"'

# ── --iterations=N ────────────────────────────────────────
echo "longopt" > "$TMPDIR/longiter.txt"

run_test "--iterations=3 shows 3 passes" true \
    'test "$($BIN -v --iterations=3 "$TMPDIR/longiter.txt" 2>&1 | grep -c "pass")" -eq 3'

# ── --random-source accepted ──────────────────────────────
echo "randsrc" > "$TMPDIR/randsrc.txt"

run_test "--random-source accepted" true \
    '$BIN --random-source=/dev/urandom -n 1 "$TMPDIR/randsrc.txt"'

# ── file in subdirectory ──────────────────────────────────
mkdir -p "$TMPDIR/subdir"
echo "subdir file" > "$TMPDIR/subdir/test.txt"

run_test "file in subdirectory works" true \
    '$BIN -n 1 -u "$TMPDIR/subdir/test.txt" && ! test -f "$TMPDIR/subdir/test.txt"'

# ── verbose rename with directory ─────────────────────────
mkdir -p "$TMPDIR/subdir2"
echo "subdir rename" > "$TMPDIR/subdir2/myfile.txt"

run_test "verbose rename shows directory prefix" true \
    '$BIN -v -n 1 -u "$TMPDIR/subdir2/myfile.txt" 2>&1 | grep "renamed to" | head -1 | grep -q "subdir2/"'

# ── -s with M suffix ─────────────────────────────────────
echo "size M" > "$TMPDIR/sizedm.txt"

run_test "-s 1M writes 1048576 bytes" true \
    '$BIN -s 1M -z "$TMPDIR/sizedm.txt" && test "$(wc -c < "$TMPDIR/sizedm.txt")" -eq 1048576'

# ── match GNU behavior on pass format ─────────────────────
echo "format" > "$TMPDIR/format.txt"

run_test "verbose format: 'shred: FILE: pass N/T (random)...'" true \
    '$BIN -v -n 1 "$TMPDIR/format.txt" 2>&1 | grep -qE "^shred: .+: pass [0-9]+/[0-9]+ \(random\)\.\.\.$"'

echo "format2" > "$TMPDIR/format2.txt"

run_test "verbose format: 'shred: FILE: pass N/T (000000)...'" true \
    '$BIN -v -n 0 -z "$TMPDIR/format2.txt" 2>&1 | grep -qE "^shred: .+: pass [0-9]+/[0-9]+ \(000000\)\.\.\.$"'

# ── Results ───────────────────────────────────────────────
echo ""
echo "=== Results: $PASS passed, $FAIL failed out of $((PASS+FAIL)) ==="

if [ ${#ERRORS[@]} -gt 0 ]; then
    echo ""
    for err in "${ERRORS[@]}"; do
        echo "  $err"
    done
fi

exit $FAIL
