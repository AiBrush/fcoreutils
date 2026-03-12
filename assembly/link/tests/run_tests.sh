#!/bin/bash
# Test suite for flink
# Usage: bash tests/run_tests.sh ./flink

BIN="${1:-./flink}"
GNU="link"
PASS=0
FAIL=0
ERRORS=()
TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT

run_test() {
    local desc="$1"
    shift
    local args=("$@")

    $GNU "${args[@]}" > "$TMPDIR/expected" 2> "$TMPDIR/expected_err"
    local expected_exit=$?
    $BIN "${args[@]}" > "$TMPDIR/got" 2> "$TMPDIR/got_err"
    local got_exit=$?

    # Normalize tool name in error messages (use sed -i on file to preserve bytes)
    LC_ALL=C sed -i "s|$(which $GNU)|$GNU|g" "$TMPDIR/expected_err"

    local stdout_match=true
    local stderr_match=true

    if ! cmp -s "$TMPDIR/expected" "$TMPDIR/got"; then
        stdout_match=false
    fi
    if ! cmp -s "$TMPDIR/expected_err" "$TMPDIR/got_err"; then
        stderr_match=false
    fi

    if $stdout_match && $stderr_match && [ "$expected_exit" = "$got_exit" ]; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
        ERRORS+=("FAIL: $desc")
        if ! $stdout_match; then
            ERRORS+=("  expected stdout: $(head -3 "$TMPDIR/expected")")
            ERRORS+=("  got stdout:      $(head -3 "$TMPDIR/got")")
        fi
        if ! $stderr_match; then
            ERRORS+=("  expected stderr: $(head -3 "$TMPDIR/expected_err")")
            ERRORS+=("  got stderr:      $(head -3 "$TMPDIR/got_err")")
        fi
        if [ "$expected_exit" != "$got_exit" ]; then
            ERRORS+=("  expected exit: $expected_exit, got: $got_exit")
        fi
    fi
}

# Separate test for help/version (text is patched by build_tool.py)
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

# Custom test for link-specific behavior (no GNU comparison needed)
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

# ── Standard flags ──
run_test_exit_only "--help exit code" --help
run_test_exit_only "--version exit code" --version

# ── FD isolation ──
run_test_fd "--help to stdout" --help
run_test_fd "error to stderr"

# ── Error handling: missing operand ──
run_test "missing operand (no args)"
run_test "missing operand after file" a

# ── Error handling: extra operand ──
run_test "extra operand" a b c
run_test "extra operand (4 args)" a b c d

# ── Core functionality: create hard link ──
# Test creating a hard link
SRC="$TMPDIR/test_src"
DST="$TMPDIR/test_dst"
echo "hello" > "$SRC"

run_test_custom "create hard link" 0 "$SRC" "$DST"

# Verify the link was actually created
if [ -f "$DST" ]; then
    SRC_INODE=$(stat -c %i "$SRC" 2>/dev/null)
    DST_INODE=$(stat -c %i "$DST" 2>/dev/null)
    if [ "$SRC_INODE" = "$DST_INODE" ]; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
        ERRORS+=("FAIL: hard link inode mismatch — src=$SRC_INODE dst=$DST_INODE")
    fi
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: hard link destination not created")
fi

# Verify content matches
SRC_CONTENT=$(cat "$SRC")
DST_CONTENT=$(cat "$DST")
if [ "$SRC_CONTENT" = "$DST_CONTENT" ]; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: hard link content mismatch")
fi

# Clean up for next test
rm -f "$DST"

# ── Error: link to existing file ──
echo "existing" > "$DST"
run_test_custom "link to existing file fails" 1 "$SRC" "$DST"
rm -f "$DST"

# ── Error: link to nonexistent source ──
run_test_custom "link nonexistent source" 1 "$TMPDIR/nonexistent" "$TMPDIR/dst_noexist"

# ── Error: link to nonexistent directory ──
run_test_custom "link to nonexistent dir" 1 "$SRC" "$TMPDIR/nodir/dst"

# ── Error message format: compare with GNU ──
# Test that error messages match GNU exactly
NONEXIST_SRC="$TMPDIR/nosuch_file"
NONEXIST_DST="$TMPDIR/nosuch_dst"

# GNU link error for nonexistent source
$GNU "$NONEXIST_SRC" "$NONEXIST_DST" > "$TMPDIR/expected" 2> "$TMPDIR/expected_err"
expected_exit=$?
$BIN "$NONEXIST_SRC" "$NONEXIST_DST" > "$TMPDIR/got" 2> "$TMPDIR/got_err"
got_exit=$?

expected_err=$(cat "$TMPDIR/expected_err" | sed "s|$(which $GNU)|$GNU|g")
got_err=$(cat "$TMPDIR/got_err")

if [ "$expected_err" = "$got_err" ] && [ "$expected_exit" = "$got_exit" ]; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: error message mismatch for nonexistent source")
    ERRORS+=("  expected: $expected_err")
    ERRORS+=("  got:      $got_err")
fi

# Test link to existing destination (EEXIST)
echo "src" > "$TMPDIR/eexist_src"
echo "dst" > "$TMPDIR/eexist_dst"

$GNU "$TMPDIR/eexist_src" "$TMPDIR/eexist_dst" > "$TMPDIR/expected" 2> "$TMPDIR/expected_err"
expected_exit=$?
$BIN "$TMPDIR/eexist_src" "$TMPDIR/eexist_dst" > "$TMPDIR/got" 2> "$TMPDIR/got_err"
got_exit=$?

expected_err=$(cat "$TMPDIR/expected_err" | sed "s|$(which $GNU)|$GNU|g")
got_err=$(cat "$TMPDIR/got_err")

if [ "$expected_err" = "$got_err" ] && [ "$expected_exit" = "$got_exit" ]; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: error message mismatch for EEXIST")
    ERRORS+=("  expected: $expected_err")
    ERRORS+=("  got:      $got_err")
fi

rm -f "$TMPDIR/eexist_src" "$TMPDIR/eexist_dst"

# ── Verify link count increases ──
echo "linkcount" > "$TMPDIR/lc_src"
BEFORE=$(stat -c %h "$TMPDIR/lc_src" 2>/dev/null)
$BIN "$TMPDIR/lc_src" "$TMPDIR/lc_dst"
AFTER=$(stat -c %h "$TMPDIR/lc_src" 2>/dev/null)
if [ "$AFTER" = "$((BEFORE + 1))" ]; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: link count didn't increase — before=$BEFORE after=$AFTER")
fi
rm -f "$TMPDIR/lc_src" "$TMPDIR/lc_dst"

# Clean up source
rm -f "$SRC"

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
