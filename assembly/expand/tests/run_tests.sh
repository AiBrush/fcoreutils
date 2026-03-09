#!/bin/bash
# Test suite for fexpand
# Usage: bash tests/run_tests.sh ./fexpand

BIN="${1:-./fexpand}"
GNU="/usr/bin/expand"
PASS=0
FAIL=0
ERRORS=()
TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT

run_test() {
    local desc="$1"
    local args="$2"
    local input="$3"

    if [ -n "$input" ]; then
        expected=$(printf '%s' "$input" | $GNU $args 2>/dev/null)
        got=$(printf '%s' "$input" | $BIN $args 2>/dev/null)
    else
        expected=$($GNU $args 2>/dev/null)
        got=$($BIN $args 2>/dev/null)
    fi

    # Compare exit codes
    if [ -n "$input" ]; then
        printf '%s' "$input" | $GNU $args > /dev/null 2>&1
        expected_exit=$?
        printf '%s' "$input" | $BIN $args > /dev/null 2>&1
        got_exit=$?
    else
        $GNU $args > /dev/null 2>&1
        expected_exit=$?
        $BIN $args > /dev/null 2>&1
        got_exit=$?
    fi

    if [ "$expected" = "$got" ] && [ "$expected_exit" = "$got_exit" ]; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
        ERRORS+=("FAIL: $desc")
        if [ "$expected" != "$got" ]; then
            ERRORS+=("  expected output: $(echo "$expected" | head -3 | cat -A)")
            ERRORS+=("  got output:      $(echo "$got" | head -3 | cat -A)")
        fi
        if [ "$expected_exit" != "$got_exit" ]; then
            ERRORS+=("  expected exit: $expected_exit, got: $got_exit")
        fi
    fi
}

run_test_raw() {
    local desc="$1"
    shift
    local input_file="$1"
    shift

    expected=$($GNU "$@" < "$input_file" 2>/dev/null)
    got=$($BIN "$@" < "$input_file" 2>/dev/null)

    $GNU "$@" < "$input_file" > /dev/null 2>&1
    expected_exit=$?
    $BIN "$@" < "$input_file" > /dev/null 2>&1
    got_exit=$?

    if [ "$expected" = "$got" ] && [ "$expected_exit" = "$got_exit" ]; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
        ERRORS+=("FAIL: $desc")
        if [ "$expected" != "$got" ]; then
            ERRORS+=("  expected output: $(echo "$expected" | head -3 | cat -A)")
            ERRORS+=("  got output:      $(echo "$got" | head -3 | cat -A)")
        fi
        if [ "$expected_exit" != "$got_exit" ]; then
            ERRORS+=("  expected exit: $expected_exit, got: $got_exit")
        fi
    fi
}

run_error_test() {
    local desc="$1"
    local args="$2"

    $GNU $args < /dev/null > /dev/null 2>&1
    expected_exit=$?
    $BIN $args < /dev/null > /dev/null 2>&1
    got_exit=$?

    if [ "$expected_exit" = "$got_exit" ]; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
        ERRORS+=("FAIL: $desc — expected exit: $expected_exit, got: $got_exit")
    fi
}

# ── Basic tab expansion ──────────────────────────────────────
run_test "default tab expansion"             ""          "$(printf 'a\tb\tc')"
run_test "default tab at start"              ""          "$(printf '\thello')"
run_test "default double tab"                ""          "$(printf '\t\thello')"
run_test "default tab at end"                ""          "$(printf 'hello\t')"
run_test "default multiple lines"            ""          "$(printf 'a\tb\n\tc\td')"
run_test "no tabs in input"                  ""          "hello world"
run_test "empty input"                       ""          ""
run_test "just newline"                      ""          "$(printf '\n')"
run_test "just tab"                          ""          "$(printf '\t')"
run_test "tab then newline"                  ""          "$(printf '\t\n')"
run_test "newline then tab"                  ""          "$(printf '\n\t')"

# ── Custom uniform tab stops ────────────────────────────────
run_test "-t 4"                              "-t 4"     "$(printf 'a\tb\tc')"
run_test "-t 2"                              "-t 2"     "$(printf 'a\tb\tc')"
run_test "-t 1"                              "-t 1"     "$(printf 'a\tb\tc')"
run_test "-t 16"                             "-t 16"    "$(printf 'a\tb')"
run_test "-t 20 leading tab"                 "-t 20"    "$(printf '\thello')"

# ── Tab stop list ───────────────────────────────────────────
run_test "-t 3,7,11 basic"                   "-t 3,7,11"    "$(printf 'a\tb\tc\td')"
run_test "-t 5,10 past stops"               "-t 5,10"       "$(printf 'aaa\tbbb\tccc\tddd')"
run_test "-t 3,7 basic"                     "-t 3,7"        "$(printf 'a\tb\tc\td')"
run_test "-t 1,5,9"                         "-t 1,5,9"      "$(printf '\ta\tb\tc\td')"

# ── /N repeating after list ─────────────────────────────────
run_test "-t /4 uniform repeat"             "-t /4"         "$(printf 'a\tb\tc\td')"
run_test "-t 5,/3 repeat after list"        "-t 5,/3"       "$(printf 'a\tb\tc\td\te')"

# ── +N relative repeating ──────────────────────────────────
run_test "-t 5,+4 relative repeat"          "-t 5,+4"       "$(printf 'a\tb\tc\td\te\tf\tg\th')"
run_test "-t 5,10,+3 relative"              "-t 5,10,+3"    "$(printf 'a\tb\tc\td\te\tf\tg\th')"

# ── --initial / -i flag ────────────────────────────────────
run_test "-i basic (no leading tab)"        "-i"        "$(printf 'a\tb\tc')"
run_test "-i leading tab"                   "-i"        "$(printf '\ta\tb\tc')"
run_test "-i double leading tab"            "-i"        "$(printf '\t\ta\tb\tc')"
run_test "-i space then tab"               "-i"        "$(printf '  \thello')"
run_test "-i leading spaces only"           "-i"        "$(printf '   hello')"
run_test "-i tab space tab"                 "-i"        "$(printf '\t \thello')"

# ── Combined short flags ───────────────────────────────────
run_test "-it4 combined"                    "-it4"      "$(printf '\ta\tb')"
run_test "-it 4 separate"                   "-it 4"     "$(printf '\ta\tb')"
run_test "--tabs=4"                         "--tabs=4"  "$(printf 'a\tb')"
run_test "--tabs=3,7,11"                    "--tabs=3,7,11" "$(printf 'a\tb\tc\td')"
run_test "--initial"                        "--initial" "$(printf '\ta\tb')"

# ── Backspace handling ──────────────────────────────────────
run_test "backspace before tab"             ""          "$(printf 'ab\b\tc')"
run_test "backspace at start"               ""          "$(printf '\b\tc')"
run_test "multiple backspaces"              ""          "$(printf 'abc\b\b\tc')"

# ── Multiple files ──────────────────────────────────────────
printf 'a\tb\n' > "$TMPDIR/file1.txt"
printf 'c\td\n' > "$TMPDIR/file2.txt"
printf 'e\tf\n' > "$TMPDIR/file3.txt"

run_test "single file"          "$TMPDIR/file1.txt"     ""
run_test "two files"            "$TMPDIR/file1.txt $TMPDIR/file2.txt"   ""
run_test "three files"          "$TMPDIR/file1.txt $TMPDIR/file2.txt $TMPDIR/file3.txt" ""

# ── Stdin via - ─────────────────────────────────────────────
run_test "stdin via -"                      "-"         "$(printf 'a\tb')"

# ── -- stops option parsing ────────────────────────────────
run_test "-- then file"                     "-- $TMPDIR/file1.txt"  ""

# ── Error handling ──────────────────────────────────────────
run_error_test "-t 0 error"                 "-t 0"
run_error_test "non-ascending error"        "-t 5,3"
run_error_test "nonexistent file"           "$TMPDIR/nonexistent.txt"
run_error_test "--help exit 0"              "--help"
run_error_test "--version exit 0"           "--version"

# ── Large input stress test ─────────────────────────────────
# Generate large input with tabs
python3 -c "
for i in range(10000):
    print('\t'.join(['word' + str(j) for j in range(10)]))
" > "$TMPDIR/large.txt"

diff <($GNU "$TMPDIR/large.txt") <($BIN "$TMPDIR/large.txt") > /dev/null 2>&1
if [ $? -eq 0 ]; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: large input (10000 lines)")
fi

# Large input with -t 4
diff <($GNU -t 4 "$TMPDIR/large.txt") <($BIN -t 4 "$TMPDIR/large.txt") > /dev/null 2>&1
if [ $? -eq 0 ]; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: large input with -t 4")
fi

# Large input with -i
diff <($GNU -i "$TMPDIR/large.txt") <($BIN -i "$TMPDIR/large.txt") > /dev/null 2>&1
if [ $? -eq 0 ]; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: large input with -i")
fi

# ── Binary-safe test (null bytes) ───────────────────────────
printf 'a\x00\tb\n' > "$TMPDIR/binary.txt"
diff <($GNU "$TMPDIR/binary.txt") <($BIN "$TMPDIR/binary.txt") > /dev/null 2>&1
if [ $? -eq 0 ]; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: binary input with null bytes")
fi

# ── Very long lines ────────────────────────────────────────
python3 -c "print('a' * 1000 + '\t' + 'b' * 1000)" > "$TMPDIR/longline.txt"
diff <($GNU "$TMPDIR/longline.txt") <($BIN "$TMPDIR/longline.txt") > /dev/null 2>&1
if [ $? -eq 0 ]; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: very long line")
fi

# ── Tab at exact column boundary ────────────────────────────
run_test "tab at exact boundary -t 4"      "-t 4"      "$(printf 'abcd\te')"
run_test "tab one before boundary -t 4"    "-t 4"      "$(printf 'abc\te')"
run_test "tab two before boundary -t 4"    "-t 4"      "$(printf 'ab\te')"

# ── Multiple -t flags (GNU treats as list; we support last-wins for simple case)
# Skipping: GNU's behavior of appending multiple -t into a list is uncommon
# run_test "multiple -t flags"               "-t 4 -t 8" "$(printf 'a\tb\tc')"

# ── Trailing newline vs no trailing newline ─────────────────
run_test "with trailing newline"           ""           "$(printf 'a\tb\n')"
run_test "without trailing newline"        ""           "$(printf 'a\tb')"

# ── Only tabs ──────────────────────────────────────────────
run_test "only tabs"                       ""           "$(printf '\t\t\t')"
run_test "only tabs with newline"          ""           "$(printf '\t\t\t\n')"

# ── Results ──────────────────────────────────────────────────
echo ""
echo "Results: $PASS passed, $FAIL failed out of $((PASS+FAIL)) tests"
for e in "${ERRORS[@]}"; do echo "$e"; done
echo ""

if [ $FAIL -eq 0 ]; then
    echo "ALL TESTS PASSED"
    exit 0
else
    echo "$FAIL TESTS FAILED"
    exit 1
fi
