#!/bin/bash
# Test suite for fcsplit
# Usage: bash tests/run_tests.sh ./fcsplit

BIN="${1:-./fcsplit}"
GNU="csplit"
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

# ── Basic split at line number ──
seq 10 > "$TMPDIR/input.txt"
cd "$TMPDIR"

mkdir -p "$TMPDIR/gnu_dir" "$TMPDIR/bin_dir"

# GNU test
cd "$TMPDIR/gnu_dir"
$GNU "$TMPDIR/input.txt" 5 > "$TMPDIR/gnu_stdout" 2>/dev/null
gnu_exit=$?

# Our test
cd "$TMPDIR/bin_dir"
$BIN "$TMPDIR/input.txt" 5 > "$TMPDIR/bin_stdout" 2>/dev/null
bin_exit=$?

# Check file count
gnu_count=$(ls "$TMPDIR/gnu_dir"/xx* 2>/dev/null | wc -l)
bin_count=$(ls "$TMPDIR/bin_dir"/xx* 2>/dev/null | wc -l)

if [ "$gnu_count" = "$bin_count" ] && [ "$gnu_exit" = "$bin_exit" ]; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: basic split — gnu_count=$gnu_count bin_count=$bin_count")
fi

# Check file contents match
all_match=true
for f in "$TMPDIR/gnu_dir"/xx*; do
    base=$(basename "$f")
    if [ -f "$TMPDIR/bin_dir/$base" ]; then
        if ! cmp -s "$f" "$TMPDIR/bin_dir/$base"; then
            all_match=false
        fi
    else
        all_match=false
    fi
done
if $all_match; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: split file contents mismatch")
fi

# ── Custom prefix ──
rm -f "$TMPDIR/gnu_dir"/* "$TMPDIR/bin_dir"/*
cd "$TMPDIR/gnu_dir"
$GNU -f out "$TMPDIR/input.txt" 5 > /dev/null 2>/dev/null
cd "$TMPDIR/bin_dir"
$BIN -f out "$TMPDIR/input.txt" 5 > /dev/null 2>/dev/null

if [ -f "$TMPDIR/bin_dir/out00" ]; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: custom prefix -f out")
fi

# ── Quiet mode ──
rm -f "$TMPDIR/bin_dir"/*
cd "$TMPDIR/bin_dir"
output=$($BIN -s "$TMPDIR/input.txt" 5 2>/dev/null)
if [ -z "$output" ]; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: -s quiet mode should suppress stdout")
fi

# ── Missing operand ──
$BIN 2>/dev/null
if [ $? -ne 0 ]; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: missing operand should exit non-zero")
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
