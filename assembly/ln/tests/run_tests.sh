#!/bin/bash
# Test suite for fln
# Usage: bash tests/run_tests.sh ./fln

BIN="${1:-./fln}"
GNU="ln"
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

    LC_ALL=C sed -i "s|$(which $GNU)|$GNU|g" "$TMPDIR/expected_err"

    local stdout_match=true
    local stderr_match=true

    if ! cmp -s "$TMPDIR/expected" "$TMPDIR/got"; then
        stdout_match=false
    fi
    # For stderr, don't compare exact messages (GNU has different wording)
    # Just check exit codes match

    if $stdout_match && [ "$expected_exit" = "$got_exit" ]; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
        ERRORS+=("FAIL: $desc")
        if ! $stdout_match; then
            ERRORS+=("  expected stdout: $(head -3 "$TMPDIR/expected")")
            ERRORS+=("  got stdout:      $(head -3 "$TMPDIR/got")")
        fi
        if [ "$expected_exit" != "$got_exit" ]; then
            ERRORS+=("  expected exit: $expected_exit, got: $got_exit")
        fi
    fi
}

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
run_test_exit_only "missing operand (no args)"

# ── Core functionality: create hard link ──
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
rm -f "$DST"

# ── Create symbolic link ──
SYMDST="$TMPDIR/test_sym"
run_test_custom "create symbolic link" 0 -s "$SRC" "$SYMDST"

if [ -L "$SYMDST" ]; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: symbolic link not created")
fi
rm -f "$SYMDST"

# ── Force flag ──
echo "existing" > "$DST"
run_test_custom "force remove existing" 0 -f "$SRC" "$DST"
if [ -f "$DST" ]; then
    SRC_INODE=$(stat -c %i "$SRC" 2>/dev/null)
    DST_INODE=$(stat -c %i "$DST" 2>/dev/null)
    if [ "$SRC_INODE" = "$DST_INODE" ]; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
        ERRORS+=("FAIL: force hard link inode mismatch")
    fi
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: force hard link not created")
fi
rm -f "$DST"

# ── Force symlink ──
echo "existing" > "$TMPDIR/sym_dst"
run_test_custom "force symbolic link" 0 -sf "$SRC" "$TMPDIR/sym_dst"
if [ -L "$TMPDIR/sym_dst" ]; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: force symbolic link not created")
fi
rm -f "$TMPDIR/sym_dst"

# ── Verbose flag ──
VERB_DST="$TMPDIR/test_verb"
$BIN -v "$SRC" "$VERB_DST" > "$TMPDIR/verb_out" 2>&1
if grep -q "'$VERB_DST' -> '$SRC'" "$TMPDIR/verb_out"; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: verbose output missing expected format")
    ERRORS+=("  got: $(cat "$TMPDIR/verb_out")")
fi
rm -f "$VERB_DST"

# ── Error: link to existing file without -f ──
echo "existing" > "$DST"
run_test_custom "link to existing file fails" 1 "$SRC" "$DST"
rm -f "$DST"

# ── Error: link to nonexistent source ──
run_test_custom "hard link nonexistent source" 1 "$TMPDIR/nonexistent" "$TMPDIR/dst_noexist"

# ── Symbolic link to nonexistent target (should succeed!) ──
run_test_custom "symlink to nonexistent target" 0 -s "$TMPDIR/nonexistent" "$TMPDIR/sym_noexist"
if [ -L "$TMPDIR/sym_noexist" ]; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: symlink to nonexistent target not created")
fi
rm -f "$TMPDIR/sym_noexist"

# ── Link into directory ──
mkdir -p "$TMPDIR/target_dir"
run_test_custom "link into directory" 0 "$SRC" "$TMPDIR/target_dir"
BASE=$(basename "$SRC")
if [ -f "$TMPDIR/target_dir/$BASE" ]; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: link into directory — file not found in target dir")
fi
rm -rf "$TMPDIR/target_dir"

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
if grep -q "ln" "$TMPDIR/ver_out"; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: --version missing 'ln'")
fi

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
