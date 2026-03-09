#!/bin/bash
# Test suite for fnl — assembly nl implementation
# Usage: bash tests/run_tests.sh ./fnl

BIN="${1:-./fnl}"
GNU="/usr/bin/nl"
TOOL="nl"

PASS=0
FAIL=0
ERRORS=()

# Normalize: replace tool paths with PROG
normalize_gnu() {
    sed -e "s|$GNU|PROG|g" -e "s|^$TOOL:|PROG:|g" -e "s|'$TOOL |'PROG |g" -e "s|Usage: $TOOL|Usage: PROG|g"
}

normalize_our() {
    sed -e "s|$BIN|PROG|g" -e "s|^$TOOL:|PROG:|g" -e "s|'$TOOL |'PROG |g" -e "s|Usage: $TOOL|Usage: PROG|g"
}

run_test() {
    local desc="$1"
    shift
    local args=("$@")

    expected=$($GNU "${args[@]}" 2>&1 | normalize_gnu)
    expected_exit=$?
    got=$($BIN "${args[@]}" 2>&1 | normalize_our)
    got_exit=$?

    if [ "$expected" = "$got" ] && [ "$expected_exit" = "$got_exit" ]; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
        ERRORS+=("FAIL: $desc")
        if [ "$expected" != "$got" ]; then
            ERRORS+=("  expected output: $(echo "$expected" | head -3)")
            ERRORS+=("  got output:      $(echo "$got" | head -3)")
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

    expected=$(printf '%b' "$input" | $GNU "${args[@]}" 2>&1 | normalize_gnu)
    expected_exit=$?
    got=$(printf '%b' "$input" | $BIN "${args[@]}" 2>&1 | normalize_our)
    got_exit=$?

    if [ "$expected" = "$got" ] && [ "$expected_exit" = "$got_exit" ]; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
        ERRORS+=("FAIL: $desc")
        if [ "$expected" != "$got" ]; then
            ERRORS+=("  expected output: $(echo "$expected" | head -3)")
            ERRORS+=("  got output:      $(echo "$got" | head -3)")
        fi
        if [ "$expected_exit" != "$got_exit" ]; then
            ERRORS+=("  expected exit: $expected_exit, got: $got_exit")
        fi
    fi
}

# ── Setup temp files ─────────────────────────────────────────
TMPDIR=$(mktemp -d /tmp/nl_test.XXXXXX)
trap "rm -rf $TMPDIR" EXIT

printf 'hello\nworld\n' > "$TMPDIR/basic.txt"
printf 'a\n\nb\n\n\nc\n' > "$TMPDIR/blanks.txt"
printf 'line1\nline2\nline3\nline4\nline5\n' > "$TMPDIR/5lines.txt"
printf '\\:\\:\\:\nheader\n\\:\\:\nbody1\nbody2\n\\:\nfooter\n' > "$TMPDIR/sections.txt"
printf 'hello' > "$TMPDIR/notrail.txt"
printf '' > "$TMPDIR/empty.txt"
seq 1 100 > "$TMPDIR/100lines.txt"
printf 'a\nb\nc\nd\ne\nf\ng\nh\ni\nj\n' > "$TMPDIR/10lines.txt"
printf '\n\n\n' > "$TMPDIR/onlyblanks.txt"
printf 'abc\n' > "$TMPDIR/single.txt"

# ── Basic functionality ──────────────────────────────────────
echo "=== Basic Functionality ==="

run_test "basic default" "$TMPDIR/basic.txt"
run_test "5 lines default" "$TMPDIR/5lines.txt"
run_test "100 lines default" "$TMPDIR/100lines.txt"
run_test "single line" "$TMPDIR/single.txt"
run_test "empty file" "$TMPDIR/empty.txt"
run_test "no trailing newline" "$TMPDIR/notrail.txt"
run_test "only blank lines" "$TMPDIR/onlyblanks.txt"

# ── Body numbering styles ────────────────────────────────────
echo "=== Body Numbering Styles ==="

run_test "-b a (all)" -b a "$TMPDIR/blanks.txt"
run_test "-b t (nonempty, default)" -b t "$TMPDIR/blanks.txt"
run_test "-b n (none)" -b n "$TMPDIR/basic.txt"
run_test "-ba (no space)" -ba "$TMPDIR/blanks.txt"
run_test_stdin "-b a stdin" "hello\n\nworld\n" -b a
run_test_stdin "-b n stdin" "hello\nworld\n" -b n

# ── Number formats ───────────────────────────────────────────
echo "=== Number Formats ==="

run_test "-n rn (right)" -n rn "$TMPDIR/basic.txt"
run_test "-n ln (left)" -n ln "$TMPDIR/basic.txt"
run_test "-n rz (zero)" -n rz "$TMPDIR/basic.txt"
run_test "-nrz (no space)" -nrz "$TMPDIR/basic.txt"
run_test "-n ln with blanks" -n ln -b a "$TMPDIR/blanks.txt"
run_test "-n rz with blanks" -n rz -b a "$TMPDIR/blanks.txt"

# ── Width ─────────────────────────────────────────────────────
echo "=== Width ==="

run_test "-w 1" -w 1 "$TMPDIR/basic.txt"
run_test "-w 3" -w 3 "$TMPDIR/basic.txt"
run_test "-w 10" -w 10 "$TMPDIR/basic.txt"
run_test "-w3 (no space)" -w3 "$TMPDIR/basic.txt"
run_test "-w 1 -n rz" -w 1 -n rz "$TMPDIR/basic.txt"
run_test "-w 3 -n ln" -w 3 -n ln "$TMPDIR/basic.txt"

# ── Separator ─────────────────────────────────────────────────
echo "=== Separator ==="

run_test "-s ': '" -s ': ' "$TMPDIR/basic.txt"
run_test "-s ''" -s '' "$TMPDIR/basic.txt"
run_test "-s '---'" -s '---' "$TMPDIR/basic.txt"
run_test "-s with blanks" -s '| ' -b a "$TMPDIR/blanks.txt"
run_test_stdin "-s with -b n" "hello\n" -s '::' -b n

# ── Increment ─────────────────────────────────────────────────
echo "=== Increment ==="

run_test "-i 1 (default)" -b a -i 1 "$TMPDIR/5lines.txt"
run_test "-i 5" -b a -i 5 "$TMPDIR/5lines.txt"
run_test "-i 10" -b a -i 10 "$TMPDIR/5lines.txt"

# ── Starting value ─────────────────────────────────────────────
echo "=== Starting Value ==="

run_test "-v 0" -b a -v 0 "$TMPDIR/basic.txt"
run_test "-v 1 (default)" -b a -v 1 "$TMPDIR/basic.txt"
run_test "-v 10" -b a -v 10 "$TMPDIR/basic.txt"
run_test "-v 100" -b a -v 100 "$TMPDIR/basic.txt"

# ── Blank line counting ──────────────────────────────────────
echo "=== Blank Line Counting ==="

run_test "-l 1 (default)" -b a -l 1 "$TMPDIR/blanks.txt"
run_test "-l 2" -b a -l 2 "$TMPDIR/blanks.txt"
run_test "-l 3" -b a -l 3 "$TMPDIR/blanks.txt"
run_test "-l with -b t" -b t -l 2 "$TMPDIR/blanks.txt"

# ── Section delimiters ───────────────────────────────────────
echo "=== Section Delimiters ==="

run_test "sections default" "$TMPDIR/sections.txt"
run_test "sections -b a -h a -f a" -b a -h a -f a "$TMPDIR/sections.txt"
run_test "sections with -p" -b a -h a -f a -p "$TMPDIR/sections.txt"
run_test "sections -h a only" -h a "$TMPDIR/sections.txt"
run_test "sections -f a only" -f a "$TMPDIR/sections.txt"

# ── Multiple files ────────────────────────────────────────────
echo "=== Multiple Files ==="

run_test "two files" "$TMPDIR/basic.txt" "$TMPDIR/5lines.txt"
run_test "three files" "$TMPDIR/basic.txt" "$TMPDIR/single.txt" "$TMPDIR/5lines.txt"
run_test "same file twice" "$TMPDIR/basic.txt" "$TMPDIR/basic.txt"

# ── Stdin ──────────────────────────────────────────────────────
echo "=== Stdin ==="

run_test_stdin "stdin default" "hello\nworld\n"
run_test_stdin "stdin -b a" "hello\n\nworld\n" -b a
run_test_stdin "stdin -n rz -w 3" "abc\ndef\n" -n rz -w 3
run_test_stdin "stdin empty" ""
run_test_stdin "stdin single line no nl" "hello"

# ── Dash argument ──────────────────────────────────────────────
echo "=== Dash Argument ==="

run_test_stdin "stdin via -" "hello\nworld\n" -

# ── Double dash ──────────────────────────────────────────────
echo "=== Double Dash ==="

run_test "-- file" -- "$TMPDIR/basic.txt"

# ── Combined options ─────────────────────────────────────────
echo "=== Combined Options ==="

run_test "combined -ba -nrz -w3" -ba -nrz -w3 "$TMPDIR/basic.txt"
run_test "all opts" -b a -n rz -w 3 -s ': ' -i 5 -v 10 "$TMPDIR/5lines.txt"
run_test "rz + blanks" -b a -n rz -w 4 "$TMPDIR/blanks.txt"
run_test "ln + separator" -n ln -s ' | ' "$TMPDIR/basic.txt"

# ── Error handling ────────────────────────────────────────────
echo "=== Error Handling ==="

run_test "nonexistent file" "$TMPDIR/nonexistent.txt"
run_test_stdin "invalid opt -Z" "hello\n" -Z

# ── Long options ──────────────────────────────────────────────
echo "=== Long Options ==="

run_test "--body-numbering=a" --body-numbering=a "$TMPDIR/blanks.txt"
run_test "--number-format=rz" --number-format=rz "$TMPDIR/basic.txt"
run_test "--number-width=3" --number-width=3 "$TMPDIR/basic.txt"
run_test "--number-separator=': '" --number-separator=': ' "$TMPDIR/basic.txt"
run_test "--line-increment=5" --line-increment=5 -b a "$TMPDIR/5lines.txt"
run_test "--starting-line-number=10" --starting-line-number=10 -b a "$TMPDIR/basic.txt"
run_test "--no-renumber" --no-renumber -b a -h a -f a "$TMPDIR/sections.txt"

# ── Summary ──────────────────────────────────────────────────
echo ""
echo "================================"
echo "Results: $PASS passed, $FAIL failed"
echo "================================"

if [ ${#ERRORS[@]} -gt 0 ]; then
    echo ""
    echo "Failures:"
    for err in "${ERRORS[@]}"; do
        echo "  $err"
    done
fi

exit $FAIL
