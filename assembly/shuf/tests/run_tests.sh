#!/bin/bash
# Test suite for fshuf
# Usage: bash tests/run_tests.sh ./fshuf
#
# Note: shuf output is random, so we test behavior (line counts, element
# membership, exit codes, error messages) rather than exact output.

BIN="${1:-./fshuf}"
GNU="/usr/bin/shuf"
TOOL="shuf"

PASS=0
FAIL=0
ERRORS=()

# ── Utility functions ────────────────────────────────────────────

normalize_gnu() {
    sed -e "s|$GNU|$TOOL|g" -e "s|Usage: $TOOL|Usage: PROG|g" -e "s|^$TOOL:|PROG:|g" -e "s|'$TOOL |'PROG |g" -e "s|  or:  $TOOL|  or:  PROG|g"
}

normalize_our() {
    sed -e "s|$BIN|$TOOL|g" -e "s|Usage: $TOOL|Usage: PROG|g" -e "s|^$TOOL:|PROG:|g" -e "s|'$TOOL |'PROG |g" -e "s|  or:  $TOOL|  or:  PROG|g"
}

# Test that exit code and stderr match GNU
run_test_exit() {
    local desc="$1"
    shift
    local args=("$@")

    expected_err=$($GNU "${args[@]}" 2>&1 >/dev/null | normalize_gnu)
    expected_exit=$?
    got_err=$($BIN "${args[@]}" 2>&1 >/dev/null | normalize_our)
    got_exit=$?

    if [ "$expected_err" = "$got_err" ] && [ "$expected_exit" = "$got_exit" ]; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
        ERRORS+=("FAIL: $desc")
        if [ "$expected_err" != "$got_err" ]; then
            ERRORS+=("  expected stderr: $(echo "$expected_err" | head -3)")
            ERRORS+=("  got stderr:      $(echo "$got_err" | head -3)")
        fi
        if [ "$expected_exit" != "$got_exit" ]; then
            ERRORS+=("  expected exit: $expected_exit, got: $got_exit")
        fi
    fi
}

# Test exit code and stderr for stdin-fed commands
run_test_exit_stdin() {
    local desc="$1"
    local input="$2"
    shift 2
    local args=("$@")

    expected_err=$(printf '%s' "$input" | $GNU "${args[@]}" 2>&1 >/dev/null | normalize_gnu)
    expected_exit=$?
    got_err=$(printf '%s' "$input" | $BIN "${args[@]}" 2>&1 >/dev/null | normalize_our)
    got_exit=$?

    if [ "$expected_err" = "$got_err" ] && [ "$expected_exit" = "$got_exit" ]; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
        ERRORS+=("FAIL: $desc")
        if [ "$expected_err" != "$got_err" ]; then
            ERRORS+=("  expected stderr: $(echo "$expected_err" | head -3)")
            ERRORS+=("  got stderr:      $(echo "$got_err" | head -3)")
        fi
        if [ "$expected_exit" != "$got_exit" ]; then
            ERRORS+=("  expected exit: $expected_exit, got: $got_exit")
        fi
    fi
}

# Test that output has expected line count
assert_line_count() {
    local desc="$1"
    local expected_count="$2"
    shift 2

    got=$("$@" 2>/dev/null)
    got_exit=$?
    got_count=$(printf '%s\n' "$got" | grep -c .)

    if [ "$got_exit" = "0" ] && [ "$got_count" = "$expected_count" ]; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
        ERRORS+=("FAIL: $desc")
        ERRORS+=("  expected count: $expected_count, got: $got_count (exit: $got_exit)")
    fi
}

# Test that output line count is 0 (empty output, success)
assert_empty_output() {
    local desc="$1"
    shift

    got=$("$@" 2>/dev/null)
    got_exit=$?

    if [ "$got_exit" = "0" ] && [ -z "$got" ]; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
        ERRORS+=("FAIL: $desc")
        ERRORS+=("  expected empty output with exit 0, got exit: $got_exit, output length: ${#got}")
    fi
}

# Test that sorted output of our tool matches sorted output of GNU
# (same set of elements, different order is ok)
assert_same_elements() {
    local desc="$1"
    shift

    expected=$($GNU "$@" 2>/dev/null | sort)
    got=$($BIN "$@" 2>/dev/null | sort)

    if [ "$expected" = "$got" ]; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
        ERRORS+=("FAIL: $desc")
        ERRORS+=("  expected elements: $(echo "$expected" | head -5)")
        ERRORS+=("  got elements:      $(echo "$got" | head -5)")
    fi
}

# Test with stdin that sorted output matches
assert_same_elements_stdin() {
    local desc="$1"
    local input="$2"
    shift 2

    expected=$(printf '%s' "$input" | $GNU "$@" 2>/dev/null | sort)
    got=$(printf '%s' "$input" | $BIN "$@" 2>/dev/null | sort)

    if [ "$expected" = "$got" ]; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
        ERRORS+=("FAIL: $desc")
        ERRORS+=("  expected: $(echo "$expected" | head -5)")
        ERRORS+=("  got:      $(echo "$got" | head -5)")
    fi
}

# Test that all output lines are within expected set
assert_elements_in_set() {
    local desc="$1"
    local set_file="$2"  # file containing valid elements, one per line
    shift 2

    got=$("$@" 2>/dev/null)
    got_exit=$?

    if [ "$got_exit" != "0" ]; then
        FAIL=$((FAIL+1))
        ERRORS+=("FAIL: $desc (exit: $got_exit)")
        return
    fi

    invalid=""
    while IFS= read -r line; do
        if ! grep -qxF "$line" "$set_file"; then
            invalid="$line"
            break
        fi
    done <<< "$got"

    if [ -z "$invalid" ]; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
        ERRORS+=("FAIL: $desc")
        ERRORS+=("  invalid element: '$invalid'")
    fi
}

# ── Setup temp files ─────────────────────────────────────────────
TMPDIR=$(mktemp -d /tmp/shuf_test.XXXXXX)
trap "rm -rf $TMPDIR" EXIT

printf "alpha\nbeta\ngamma\ndelta\nepsilon\n" > "$TMPDIR/five.txt"
printf "" > "$TMPDIR/empty.txt"
printf "one\n" > "$TMPDIR/single.txt"
seq 1 100 > "$TMPDIR/hundred.txt"
seq 1 1000 > "$TMPDIR/thousand.txt"

# Valid elements files for membership testing
seq 1 5 > "$TMPDIR/valid_1_5.txt"
seq 1 10 > "$TMPDIR/valid_1_10.txt"
seq 1 100 > "$TMPDIR/valid_1_100.txt"
printf "a\nb\n" > "$TMPDIR/valid_ab.txt"
printf "x\ny\nz\n" > "$TMPDIR/valid_xyz.txt"
printf "alpha\nbeta\ngamma\ndelta\nepsilon\n" > "$TMPDIR/valid_five.txt"

# ══════════════════════════════════════════════════════════════════
# TESTS
# ══════════════════════════════════════════════════════════════════

# ── --help and --version ─────────────────────────────────────────
run_test_exit "--help exits 0" --help
run_test_exit "--version exits 0" --version

# Compare help output (normalize binary paths)
gnu_help=$($GNU --help 2>&1 | normalize_gnu)
our_help=$($BIN --help 2>&1 | normalize_our)
if [ "$gnu_help" = "$our_help" ]; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: --help output mismatch")
    ERRORS+=("  expected first line: $(echo "$gnu_help" | head -1)")
    ERRORS+=("  got first line:      $(echo "$our_help" | head -1)")
fi

# Compare version output (normalize binary paths and Debian packaging line)
gnu_ver=$($GNU --version 2>&1 | normalize_gnu | grep -v "^Packaged by")
our_ver=$($BIN --version 2>&1 | normalize_our | grep -v "^Packaged by")
if [ "$gnu_ver" = "$our_ver" ]; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: --version output mismatch")
    ERRORS+=("  expected: $(echo "$gnu_ver" | head -3)")
    ERRORS+=("  got:      $(echo "$our_ver" | head -3)")
fi

# ── Error cases ──────────────────────────────────────────────────
run_test_exit "invalid option -x" -x
run_test_exit "invalid option -X" -X
run_test_exit "invalid option -1" -1
run_test_exit "cannot combine -e and -i" -e -i 1-5
run_test_exit "invalid range: abc" -i abc
run_test_exit "invalid range: reversed 5-1" -i 5-1
run_test_exit "extra operand with -i" -i 1-5 foo
run_test_exit "file not found" /nonexistent_file_12345
run_test_exit "multiple files" "$TMPDIR/five.txt" "$TMPDIR/five.txt"
run_test_exit "invalid count" -n abc -i 1-5

# ── Basic shuffle (-i range) ────────────────────────────────────
assert_same_elements "-i 1-5 has all elements" -i 1-5
assert_same_elements "-i 1-10 has all elements" -i 1-10
assert_same_elements "-i 0-0 single element" -i 0-0
assert_same_elements "-i 100-100 single element" -i 100-100

assert_line_count "-i 1-5 produces 5 lines" 5 $BIN -i 1-5
assert_line_count "-i 1-100 produces 100 lines" 100 $BIN -i 1-100

# ── Echo mode (-e) ──────────────────────────────────────────────
assert_same_elements "-e x y z" -e x y z
assert_same_elements "-e single" -e single
assert_empty_output "-e no args" $BIN -e

assert_line_count "-e a b c produces 3 lines" 3 $BIN -e a b c
assert_line_count "-e single element" 1 $BIN -e only

# ── File/stdin mode ─────────────────────────────────────────────
assert_same_elements_stdin "stdin 5 lines" "$(cat "$TMPDIR/five.txt")"
assert_same_elements_stdin "stdin single line" "one"
assert_same_elements "file 5 lines" "$TMPDIR/five.txt"

assert_line_count "file produces correct count" 5 $BIN "$TMPDIR/five.txt"
assert_line_count "stdin single line" 1 $BIN <<< "single"

# Empty input
printf '' | $BIN > "$TMPDIR/empty_out.txt" 2>/dev/null
empty_exit=$?
empty_out=$(cat "$TMPDIR/empty_out.txt")
if [ "$empty_exit" = "0" ] && [ -z "$empty_out" ]; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: empty stdin should produce empty output")
fi

# Stdin via -
printf "a\nb\nc\n" | $BIN - > "$TMPDIR/dash_out.txt" 2>/dev/null
dash_count=$(wc -l < "$TMPDIR/dash_out.txt")
if [ "$dash_count" = "3" ]; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: stdin via '-' should produce 3 lines, got $dash_count")
fi

# ── -n (head count) ─────────────────────────────────────────────
assert_line_count "-n 3 from range 1-10" 3 $BIN -n 3 -i 1-10
assert_line_count "-n 1 from range 1-100" 1 $BIN -n 1 -i 1-100
assert_empty_output "-n 0 produces nothing" $BIN -n 0 -i 1-10
assert_line_count "-n larger than input" 5 $BIN -n 100 -i 1-5
assert_line_count "-n with file" 2 $BIN -n 2 "$TMPDIR/five.txt"

# Multiple -n should use minimum
assert_line_count "multiple -n uses minimum" 2 $BIN -n 5 -n 2 -i 1-100
assert_line_count "multiple -n uses minimum (reversed)" 3 $BIN -n 3 -n 10 -i 1-100

# -n with stdin
got_n_stdin=$(printf 'a\nb\nc\nd\ne\n' | $BIN -n 3 2>/dev/null | wc -l)
if [ "$got_n_stdin" = "3" ]; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: -n 3 with stdin should produce 3 lines, got $got_n_stdin")
fi

# All elements from -n should be valid
assert_elements_in_set "-n elements valid" "$TMPDIR/valid_1_10.txt" $BIN -n 3 -i 1-10

# ── -r (repeat) ─────────────────────────────────────────────────
assert_line_count "-r -n 10 with echo" 10 $BIN -e -r -n 10 a b
assert_line_count "-r -n 20 with range" 20 $BIN -r -n 20 -i 1-5
assert_line_count "-r -n 5 with file" 5 $BIN -r -n 5 "$TMPDIR/five.txt"
assert_empty_output "-r -n 0" $BIN -e -r -n 0 a b

# -r elements should be from valid set
assert_elements_in_set "-r elements valid" "$TMPDIR/valid_ab.txt" $BIN -e -r -n 20 a b
assert_elements_in_set "-r range elements valid" "$TMPDIR/valid_1_5.txt" $BIN -r -n 20 -i 1-5

# -r with stdin
got_r_stdin=$(printf 'x\ny\nz\n' | $BIN -r -n 15 2>/dev/null | wc -l)
if [ "$got_r_stdin" = "15" ]; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: -r -n 15 with stdin should produce 15 lines, got $got_r_stdin")
fi

# -r with empty input and -n 0 should succeed
printf '' | $BIN -r -n 0 > /dev/null 2>/dev/null
if [ $? -eq 0 ]; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: -r -n 0 with empty stdin should exit 0")
fi

# ── -z (zero-terminated) ────────────────────────────────────────
# Input with NUL separators
got_z=$(printf 'a\0b\0c\0' | $BIN -z 2>/dev/null | od -c)
expected_z=$(printf 'a\0b\0c\0' | $GNU -z 2>/dev/null | od -c)
# Both should have 3 NUL-separated items
got_z_count=$(printf 'a\0b\0c\0' | $BIN -z 2>/dev/null | tr '\0' '\n' | grep -c .)
if [ "$got_z_count" = "3" ]; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: -z should produce 3 NUL-terminated items, got $got_z_count")
fi

# -z with echo
got_ze=$(printf '' | $BIN -z -e a b c 2>/dev/null | tr '\0' '\n' | sort)
expected_ze=$(printf '' | $GNU -z -e a b c 2>/dev/null | tr '\0' '\n' | sort)
if [ "$got_ze" = "$expected_ze" ]; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: -z -e should produce same elements")
fi

# ── -o (output file) ────────────────────────────────────────────
$BIN -e alpha beta gamma -o "$TMPDIR/out1.txt" 2>/dev/null
out1_count=$(wc -l < "$TMPDIR/out1.txt")
out1_sorted=$(sort "$TMPDIR/out1.txt")
expected1_sorted=$(printf 'alpha\nbeta\ngamma' | sort)
if [ "$out1_count" = "3" ] && [ "$out1_sorted" = "$expected1_sorted" ]; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: -o output file (got $out1_count lines)")
fi

$BIN -i 1-5 -o "$TMPDIR/out2.txt" 2>/dev/null
out2_sorted=$(sort -n "$TMPDIR/out2.txt" | tr '\n' ' ')
if [ "$out2_sorted" = "1 2 3 4 5 " ]; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: -o with -i range (got: '$out2_sorted')")
fi

# ── Combined short options ───────────────────────────────────────
assert_line_count "-rn5 combined" 5 $BIN -rn5 -e a b c
assert_line_count "-ern10 combined" 10 $BIN -ern10 a b c
# -ze combined (NUL-separated): verify elements by converting to newline first
got_ze_combo=$($BIN -z -e a b c 2>/dev/null | tr '\0' '\n' | sort)
exp_ze_combo=$(printf 'a\nb\nc' | sort)
if [ "$got_ze_combo" = "$exp_ze_combo" ]; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: -ze combined")
fi

# -i with value attached
got_i_val=$($BIN -i1-3 2>/dev/null | sort -n | tr '\n' ' ')
if [ "$got_i_val" = "1 2 3 " ]; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: -i1-3 short combined (got: '$got_i_val')")
fi

# ── End of options (--) ─────────────────────────────────────────
got_eo=$(printf 'a\nb\n' | $BIN -- 2>/dev/null | sort)
if [ "$got_eo" = "$(printf 'a\nb')" ]; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: -- end of options")
fi

# ── Large input ──────────────────────────────────────────────────
# 1000 lines: verify all present
got_thou=$($BIN "$TMPDIR/thousand.txt" 2>/dev/null | sort -n | md5sum)
exp_thou=$(sort -n "$TMPDIR/thousand.txt" | md5sum)
if [ "$got_thou" = "$exp_thou" ]; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: 1000-line shuffle missing elements")
fi

# 100 lines: verify all present
got_hun=$($BIN "$TMPDIR/hundred.txt" 2>/dev/null | sort -n | md5sum)
exp_hun=$(sort -n "$TMPDIR/hundred.txt" | md5sum)
if [ "$got_hun" = "$exp_hun" ]; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: 100-line shuffle missing elements")
fi

# Large range
got_lr=$($BIN -i 1-10000 2>/dev/null | sort -n | tail -1)
if [ "$got_lr" = "10000" ]; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: -i 1-10000 last element should be 10000, got '$got_lr'")
fi

got_lr_count=$($BIN -i 1-10000 2>/dev/null | wc -l)
if [ "$got_lr_count" = "10000" ]; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: -i 1-10000 should produce 10000 lines, got $got_lr_count")
fi

# ── Pipe (SIGPIPE / broken pipe) ────────────────────────────────
$BIN -i 1-1000000 2>/dev/null | head -1 > /dev/null
pipe_exit=$?
if [ "$pipe_exit" = "0" ]; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: broken pipe should exit 0, got $pipe_exit")
fi

# ── Randomness check ────────────────────────────────────────────
# Run 10 times, at least 2 should differ (extremely likely for 10 elements)
declare -A seen
for i in $(seq 1 10); do
    out=$($BIN -i 1-10 2>/dev/null | tr '\n' ',')
    seen["$out"]=1
done
unique_count=${#seen[@]}
if [ "$unique_count" -ge 2 ]; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: randomness check - all 10 runs produced identical output")
fi

# ── No trailing newline input ────────────────────────────────────
got_nt=$(printf 'a\nb\nc' | $BIN 2>/dev/null | sort)
exp_nt=$(printf 'a\nb\nc' | $GNU 2>/dev/null | sort)
if [ "$got_nt" = "$exp_nt" ]; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: input without trailing newline")
    ERRORS+=("  expected: $(echo "$exp_nt")")
    ERRORS+=("  got:      $(echo "$got_nt")")
fi

# ── Single line input ────────────────────────────────────────────
assert_same_elements "single line file" "$TMPDIR/single.txt"

# ── Results ──────────────────────────────────────────────────────
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
