#!/bin/bash
# Test suite for ffmt
# Usage: bash tests/run_tests.sh ./ffmt

BIN="${1:-./ffmt}"
GNU="fmt"
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

    local expected=$(cat "$TMPDIR/expected")
    local got=$(cat "$TMPDIR/got")

    if [ "$expected" = "$got" ] && [ "$expected_exit" = "$got_exit" ]; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
        ERRORS+=("FAIL: $desc")
        if [ "$expected" != "$got" ]; then
            ERRORS+=("  expected stdout: $(echo "$expected" | head -3)")
            ERRORS+=("  got stdout:      $(echo "$got" | head -3)")
        fi
        if [ "$expected_exit" != "$got_exit" ]; then
            ERRORS+=("  expected exit: $expected_exit, got: $got_exit")
        fi
    fi
}

run_test_stdin() {
    local desc="$1"
    local input="$2"
    shift 2
    local args=("$@")

    echo -e "$input" | $GNU "${args[@]}" > "$TMPDIR/expected" 2>/dev/null
    local expected_exit=$?
    echo -e "$input" | $BIN "${args[@]}" > "$TMPDIR/got" 2>/dev/null
    local got_exit=$?

    local expected=$(cat "$TMPDIR/expected")
    local got=$(cat "$TMPDIR/got")

    if [ "$expected" = "$got" ] && [ "$expected_exit" = "$got_exit" ]; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
        ERRORS+=("FAIL: $desc")
        if [ "$expected" != "$got" ]; then
            ERRORS+=("  expected stdout: $(echo "$expected" | head -3)")
            ERRORS+=("  got stdout:      $(echo "$got" | head -3)")
        fi
        if [ "$expected_exit" != "$got_exit" ]; then
            ERRORS+=("  expected exit: $expected_exit, got: $got_exit")
        fi
    fi
}

run_test_printf() {
    local desc="$1"
    local input="$2"
    shift 2
    local args=("$@")

    printf "%s" "$input" | $GNU "${args[@]}" > "$TMPDIR/expected" 2>/dev/null
    local expected_exit=$?
    printf "%s" "$input" | $BIN "${args[@]}" > "$TMPDIR/got" 2>/dev/null
    local got_exit=$?

    local expected=$(cat "$TMPDIR/expected")
    local got=$(cat "$TMPDIR/got")

    if [ "$expected" = "$got" ] && [ "$expected_exit" = "$got_exit" ]; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
        ERRORS+=("FAIL: $desc")
        if [ "$expected" != "$got" ]; then
            ERRORS+=("  expected stdout: $(echo "$expected" | head -3)")
            ERRORS+=("  got stdout:      $(echo "$got" | head -3)")
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
        ERRORS+=("FAIL: $desc -- expected exit: $expected_exit, got: $got_exit")
    fi
}

# ── Setup test files ─────────────────────────────────────────
# Simple text file
cat > "$TMPDIR/simple.txt" <<'EOF'
This is a simple test. It has some words that should be reformatted
when the width is changed. Let us see how the tool handles it.
EOF

# Long line
python3 -c "print('word ' * 100)" > "$TMPDIR/longline.txt"

# Multiple paragraphs
cat > "$TMPDIR/paragraphs.txt" <<'EOF'
This is the first paragraph. It has several sentences that should
be formatted together into a single block of text.

This is the second paragraph. It should remain separate from the
first paragraph because of the blank line.

And here is a third one.
EOF

# Indented text
cat > "$TMPDIR/indented.txt" <<'EOF'
    This line is indented with spaces.
    This one too.
Not indented.
    Indented again.
EOF

# Empty file
echo -n "" > "$TMPDIR/empty.txt"

# Single line
echo "hello world" > "$TMPDIR/single.txt"

# ── Standard flags ──
run_test_exit_only "--help exit code" --help
run_test_exit_only "--version exit code" --version

# ── Basic formatting ──────────────────────────────────────────
run_test "simple file" "$TMPDIR/simple.txt"
run_test "long line" "$TMPDIR/longline.txt"
run_test "paragraphs" "$TMPDIR/paragraphs.txt"
run_test "empty file" "$TMPDIR/empty.txt"
run_test "single line" "$TMPDIR/single.txt"

# ── Width option ──────────────────────────────────────────────
run_test "-w 40" -w 40 "$TMPDIR/simple.txt"
run_test "-w 20" -w 20 "$TMPDIR/simple.txt"
run_test "-w 80" -w 80 "$TMPDIR/simple.txt"
run_test "-w 10" -w 10 "$TMPDIR/longline.txt"
run_test "--width=40" --width=40 "$TMPDIR/simple.txt"

# ── Stdin tests ───────────────────────────────────────────────
run_test_stdin "stdin: short text" "hello world"
run_test_stdin "stdin: long text" "This is a longer piece of text that should be reformatted by the fmt command when we process it"
run_test_stdin "stdin: with -w 20" "This is a longer piece of text that should be reformatted" -w 20
run_test_stdin "stdin: empty" ""
run_test_stdin "stdin: multiple lines" "line one\nline two\nline three"
run_test_stdin "stdin: multiple paragraphs" "first paragraph text\n\nsecond paragraph text"

# ── Indented text ─────────────────────────────────────────────
run_test "indented text" "$TMPDIR/indented.txt"

# ── Multiple files ────────────────────────────────────────────
run_test "multiple files" "$TMPDIR/simple.txt" "$TMPDIR/single.txt"

# ── Prefix options ────────────────────────────────────────────
run_test_stdin "-p prefix" "# comment line one that is pretty long and should wrap\n# comment line two" -p "# "

# ── Split only (-s) ──────────────────────────────────────────
run_test_stdin "-s split only" "This is a very long line that should only be split and not joined with any other lines at all" -s
run_test_stdin "-s -w 20" "This is a very long line that should only be split" -s -w 20

# ── Uniform spacing (-u) ─────────────────────────────────────
run_test_stdin "-u uniform spacing" "Hello    world.   How  are   you?"
run_test_stdin "-u flag explicit" "Hello    world.   How  are   you?" -u

# ── Crown margin (-c) ────────────────────────────────────────
run_test_stdin "-c crown margin" "  First line of paragraph.\nContinuation of the same paragraph." -c

# ── Error handling ────────────────────────────────────────────
run_test "nonexistent file" /nonexistent/file/path

# ── /dev/null ─────────────────────────────────────────────────
run_test "/dev/null" /dev/null

# ── Large file ────────────────────────────────────────────────
python3 -c "
for i in range(100):
    print('word' + str(i) + ' ', end='')
    if i % 20 == 19:
        print()
print()
" > "$TMPDIR/large.txt"
run_test "large file" "$TMPDIR/large.txt"

# ── Binary content (should not crash) ─────────────────────────
printf '\x00\x01\x02\xff\xfe\xfd\n' > "$TMPDIR/binary.dat"
run_test "binary content" "$TMPDIR/binary.dat"

# ── Goal width (-g) ──────────────────────────────────────────
run_test_stdin "-g 50 goal width" "This is a test of the goal width option which should try to format text" -g 50

# ── Results ──────────────────────────────────────────────────
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
