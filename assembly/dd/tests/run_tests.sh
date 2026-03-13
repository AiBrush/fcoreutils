#!/bin/bash
# Test suite for fdd
# Usage: bash tests/run_tests.sh ./fdd

BIN="${1:-./fdd}"
GNU="dd"
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

run_test_output() {
    local desc="$1"
    shift
    local args=("$@")

    $GNU "${args[@]}" > "$TMPDIR/expected" 2>/dev/null
    local expected_exit=$?
    $BIN "${args[@]}" > "$TMPDIR/got" 2>/dev/null
    local got_exit=$?

    if cmp -s "$TMPDIR/expected" "$TMPDIR/got" && [ "$expected_exit" = "$got_exit" ]; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
        ERRORS+=("FAIL: $desc")
        if ! cmp -s "$TMPDIR/expected" "$TMPDIR/got"; then
            local exp_sz=$(wc -c < "$TMPDIR/expected")
            local got_sz=$(wc -c < "$TMPDIR/got")
            ERRORS+=("  expected $exp_sz bytes, got $got_sz bytes")
        fi
        if [ "$expected_exit" != "$got_exit" ]; then
            ERRORS+=("  expected exit: $expected_exit, got: $got_exit")
        fi
    fi
}

# ── Standard flags ──
run_test_exit_only "--help exit code" --help
run_test_exit_only "--version exit code" --version

# ── Basic copy from stdin ──
echo "hello world" > "$TMPDIR/input.txt"
run_test_output "basic stdin copy" if="$TMPDIR/input.txt"

# ── Copy file to file ──
$BIN if="$TMPDIR/input.txt" of="$TMPDIR/output.txt" 2>/dev/null
got=$(cat "$TMPDIR/output.txt")
if [ "$got" = "hello world" ]; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: copy file to file")
fi

# ── bs= option ──
dd if=/dev/zero bs=1024 count=1 of="$TMPDIR/zeros.bin" 2>/dev/null
$BIN if="$TMPDIR/zeros.bin" of="$TMPDIR/zeros_out.bin" bs=1024 2>/dev/null
if cmp -s "$TMPDIR/zeros.bin" "$TMPDIR/zeros_out.bin"; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: bs=1024 copy")
fi

# ── count= option ──
seq 100 > "$TMPDIR/seq100.txt"
$GNU if="$TMPDIR/seq100.txt" bs=1 count=10 > "$TMPDIR/expected_count" 2>/dev/null
$BIN if="$TMPDIR/seq100.txt" bs=1 count=10 > "$TMPDIR/got_count" 2>/dev/null
if cmp -s "$TMPDIR/expected_count" "$TMPDIR/got_count"; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: count=10")
fi

# ── skip= option ──
$GNU if="$TMPDIR/seq100.txt" bs=1 skip=5 count=5 > "$TMPDIR/expected_skip" 2>/dev/null
$BIN if="$TMPDIR/seq100.txt" bs=1 skip=5 count=5 > "$TMPDIR/got_skip" 2>/dev/null
if cmp -s "$TMPDIR/expected_skip" "$TMPDIR/got_skip"; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: skip=5")
fi

# ── status=none ──
$BIN if="$TMPDIR/input.txt" status=none > "$TMPDIR/got_none" 2>"$TMPDIR/stderr_none"
if [ ! -s "$TMPDIR/stderr_none" ]; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: status=none should suppress stderr")
fi

# ── conv=notrunc ──
echo "existing" > "$TMPDIR/notrunc.txt"
echo "new" | $BIN of="$TMPDIR/notrunc.txt" conv=notrunc 2>/dev/null
got=$(cat "$TMPDIR/notrunc.txt")
echo "existing" > "$TMPDIR/notrunc2.txt"
echo "new" | $GNU of="$TMPDIR/notrunc2.txt" conv=notrunc 2>/dev/null
expected=$(cat "$TMPDIR/notrunc2.txt")
if [ "$got" = "$expected" ]; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: conv=notrunc")
fi

# ── Records in/out stats ──
$BIN if="$TMPDIR/input.txt" of=/dev/null 2>"$TMPDIR/stats"
if grep -q "records in" "$TMPDIR/stats" && grep -q "records out" "$TMPDIR/stats"; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: stats should show records in/out")
fi

# ── Empty input ──
echo -n "" | $BIN > "$TMPDIR/empty_out" 2>/dev/null
if [ ! -s "$TMPDIR/empty_out" ]; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: empty input should produce empty output")
fi

# ── Large copy ──
dd if=/dev/zero bs=65536 count=2 of="$TMPDIR/large.bin" 2>/dev/null
$BIN if="$TMPDIR/large.bin" of="$TMPDIR/large_out.bin" bs=65536 2>/dev/null
if cmp -s "$TMPDIR/large.bin" "$TMPDIR/large_out.bin"; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: large file copy (128KB)")
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
