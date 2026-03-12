#!/bin/bash
# Test suite for fpaste — compares byte-for-byte with GNU paste
# Usage: bash tests/run_tests.sh ./fpaste

BIN="${1:-./fpaste}"
GNU="/usr/bin/paste"
TOOL="paste"

PASS=0
FAIL=0
ERRORS=()

TMPDIR=$(mktemp -d /tmp/fpaste_test.XXXXXX)
trap "rm -rf $TMPDIR" EXIT

# ── Helper: compare file-based output ──
run_test() {
    local desc="$1"
    shift
    local args=("$@")

    $GNU "${args[@]}" > "$TMPDIR/expected" 2> "$TMPDIR/expected_err"
    local expected_exit=$?
    $BIN "${args[@]}" > "$TMPDIR/got" 2> "$TMPDIR/got_err"
    local got_exit=$?

    # Normalize error messages: replace binary path with tool name
    sed -i "s|$BIN|$TOOL|g" "$TMPDIR/got_err"

    if diff -q "$TMPDIR/expected" "$TMPDIR/got" > /dev/null 2>&1 && \
       [ "$expected_exit" = "$got_exit" ]; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
        ERRORS+=("FAIL: $desc")
        if ! diff -q "$TMPDIR/expected" "$TMPDIR/got" > /dev/null 2>&1; then
            ERRORS+=("  output differs:")
            ERRORS+=("  expected: $(od -A x -t x1z < "$TMPDIR/expected" | head -3)")
            ERRORS+=("  got:      $(od -A x -t x1z < "$TMPDIR/got" | head -3)")
        fi
        if [ "$expected_exit" != "$got_exit" ]; then
            ERRORS+=("  expected exit: $expected_exit, got: $got_exit")
        fi
    fi
}

# ── Helper: compare stdin-based output ──
run_test_stdin() {
    local desc="$1"
    local input_file="$2"
    shift 2
    local args=("$@")

    $GNU "${args[@]}" < "$input_file" > "$TMPDIR/expected" 2> "$TMPDIR/expected_err"
    local expected_exit=$?
    $BIN "${args[@]}" < "$input_file" > "$TMPDIR/got" 2> "$TMPDIR/got_err"
    local got_exit=$?

    sed -i "s|$BIN|$TOOL|g" "$TMPDIR/got_err"

    if diff -q "$TMPDIR/expected" "$TMPDIR/got" > /dev/null 2>&1 && \
       [ "$expected_exit" = "$got_exit" ]; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
        ERRORS+=("FAIL: $desc")
        if ! diff -q "$TMPDIR/expected" "$TMPDIR/got" > /dev/null 2>&1; then
            ERRORS+=("  output differs:")
            ERRORS+=("  expected: $(od -A x -t x1z < "$TMPDIR/expected" | head -3)")
            ERRORS+=("  got:      $(od -A x -t x1z < "$TMPDIR/got" | head -3)")
        fi
        if [ "$expected_exit" != "$got_exit" ]; then
            ERRORS+=("  expected exit: $expected_exit, got: $got_exit")
        fi
    fi
}

# ── Helper: compare with piped stdin ──
run_test_pipe_stdin() {
    local desc="$1"
    local input_data="$2"
    shift 2
    local args=("$@")

    echo -e "$input_data" | $GNU "${args[@]}" > "$TMPDIR/expected" 2> "$TMPDIR/expected_err"
    local expected_exit=$?
    echo -e "$input_data" | $BIN "${args[@]}" > "$TMPDIR/got" 2> "$TMPDIR/got_err"
    local got_exit=$?

    sed -i "s|$BIN|$TOOL|g" "$TMPDIR/got_err"

    if diff -q "$TMPDIR/expected" "$TMPDIR/got" > /dev/null 2>&1 && \
       [ "$expected_exit" = "$got_exit" ]; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
        ERRORS+=("FAIL: $desc")
        if ! diff -q "$TMPDIR/expected" "$TMPDIR/got" > /dev/null 2>&1; then
            ERRORS+=("  output differs:")
            ERRORS+=("  expected: $(od -A x -t x1z < "$TMPDIR/expected" | head -3)")
            ERRORS+=("  got:      $(od -A x -t x1z < "$TMPDIR/got" | head -3)")
        fi
        if [ "$expected_exit" != "$got_exit" ]; then
            ERRORS+=("  expected exit: $expected_exit, got: $got_exit")
        fi
    fi
}

# ── Create test files ──
printf "1\n2\n3\n" > "$TMPDIR/a.txt"
printf "a\nb\nc\n" > "$TMPDIR/b.txt"
printf "x\ny\nz\n" > "$TMPDIR/c.txt"
printf "" > "$TMPDIR/empty.txt"
printf "hello" > "$TMPDIR/notl.txt"
printf "1\n2\n3" > "$TMPDIR/a_notl.txt"
printf "a\nb\n" > "$TMPDIR/b2.txt"
printf "a\n" > "$TMPDIR/b_short.txt"
printf "\n" > "$TMPDIR/newline.txt"
printf "\n\n\n" > "$TMPDIR/blanks.txt"
printf "hello\n" > "$TMPDIR/one.txt"
printf "1\n" > "$TMPDIR/f1.txt"
printf "2\n" > "$TMPDIR/f2.txt"
printf "3\n" > "$TMPDIR/f3.txt"
printf "4\n" > "$TMPDIR/f4.txt"

# Binary data
printf '\x00\x01\x02\x03\x04\x05\n\x06\x07\x08\n' > "$TMPDIR/bin_a.txt"
printf '\xfe\xff\x80\x81\n\x90\x91\n' > "$TMPDIR/bin_b.txt"

# Stdin test data
printf "1\n2\n3\n4\n5\n6\n" > "$TMPDIR/stdin_data.txt"

# Large test data
python3 -c "
for i in range(10000):
    print(f'line{i:06d}')
" > "$TMPDIR/large_a.txt"
python3 -c "
for i in range(10000):
    print(f'data{i:06d}')
" > "$TMPDIR/large_b.txt"

# Zero-terminated test data
printf "a\0b\0c" > "$TMPDIR/z.txt"
printf "a\0b\0c\0d" > "$TMPDIR/z2.txt"

# ── Basic parallel mode tests ──
echo "=== Basic parallel mode ==="
run_test "two files" "$TMPDIR/a.txt" "$TMPDIR/b.txt"
run_test "three files" "$TMPDIR/a.txt" "$TMPDIR/b.txt" "$TMPDIR/c.txt"
run_test "single file" "$TMPDIR/a.txt"
run_test "empty file" "$TMPDIR/empty.txt"
run_test "two empty files" "$TMPDIR/empty.txt" "$TMPDIR/empty.txt"
run_test "no trailing newline" "$TMPDIR/notl.txt"
run_test "both no trailing newline" "$TMPDIR/notl.txt" "$TMPDIR/a_notl.txt"
run_test "one line file" "$TMPDIR/one.txt"

# ── Unequal files ──
echo "=== Unequal files ==="
run_test "unequal: long + short" "$TMPDIR/a.txt" "$TMPDIR/b_short.txt"
run_test "unequal: short + long" "$TMPDIR/b_short.txt" "$TMPDIR/a.txt"
run_test "unequal: normal + empty" "$TMPDIR/a.txt" "$TMPDIR/empty.txt"
run_test "unequal: empty + normal" "$TMPDIR/empty.txt" "$TMPDIR/a.txt"

# ── Delimiter tests ──
echo "=== Delimiter tests ==="
run_test "custom delim :" -d ':' "$TMPDIR/a.txt" "$TMPDIR/b.txt"
run_test "custom delim |" -d '|' "$TMPDIR/a.txt" "$TMPDIR/b.txt"
run_test "multi-char delim :," -d ':,' "$TMPDIR/a.txt" "$TMPDIR/b.txt" "$TMPDIR/c.txt"
run_test "empty delim" -d '' "$TMPDIR/a.txt" "$TMPDIR/b.txt"
run_test "backslash n delim" -d '\n' "$TMPDIR/a.txt" "$TMPDIR/b.txt"
run_test "backslash t delim" -d '\t' "$TMPDIR/a.txt" "$TMPDIR/b.txt"
run_test "backslash backslash delim" -d '\\' "$TMPDIR/a.txt" "$TMPDIR/b.txt"
run_test "NUL delim" -d '\0' "$TMPDIR/a.txt" "$TMPDIR/b.txt"
run_test "delimiter cycling 4 files" -d ':,;' "$TMPDIR/f1.txt" "$TMPDIR/f2.txt" "$TMPDIR/f3.txt" "$TMPDIR/f4.txt"
run_test "single char delim with 4 files" -d ':' "$TMPDIR/f1.txt" "$TMPDIR/f2.txt" "$TMPDIR/f3.txt" "$TMPDIR/f4.txt"

# ── Serial mode ──
echo "=== Serial mode ==="
run_test "serial single file" -s "$TMPDIR/a.txt"
run_test "serial multiple files" -s "$TMPDIR/a.txt" "$TMPDIR/b.txt"
run_test "serial empty file" -s "$TMPDIR/empty.txt"
run_test "serial no trailing nl" -s "$TMPDIR/notl.txt"
run_test "serial blanks" -s "$TMPDIR/blanks.txt"
run_test "serial newline only" -s "$TMPDIR/newline.txt"
run_test "serial custom delim" -s -d ':' "$TMPDIR/a.txt"
run_test "serial multi-char delim" -s -d ':,' "$TMPDIR/a.txt"
run_test "serial empty delim" -s -d '' "$TMPDIR/a.txt"
run_test "serial multiple with custom delim" -s -d ':' "$TMPDIR/a.txt" "$TMPDIR/b.txt"

# ── Stdin tests ──
echo "=== Stdin tests ==="
run_test_stdin "stdin basic" "$TMPDIR/a.txt" -
run_test_stdin "stdin paired" "$TMPDIR/stdin_data.txt" - -
run_test_stdin "stdin triple" "$TMPDIR/stdin_data.txt" - - -
run_test_stdin "stdin with file" "$TMPDIR/b2.txt" "$TMPDIR/a.txt" -
run_test_stdin "stdin serial" "$TMPDIR/a.txt" -s -
run_test_stdin "stdin no args" "$TMPDIR/a.txt"
run_test_pipe_stdin "pipe stdin only" "hello\nworld" -
run_test_pipe_stdin "pipe stdin paired" "1\n2\n3\n4" - -

# ── -z flag tests ──
echo "=== Zero-terminated tests ==="
run_test_stdin "-z basic" "$TMPDIR/z.txt" -z -
run_test_stdin "-z paired" "$TMPDIR/z2.txt" -z - -
run_test_stdin "-z serial" "$TMPDIR/z.txt" -z -s -

# ── Large file tests ──
echo "=== Large file tests ==="
run_test "large two files" "$TMPDIR/large_a.txt" "$TMPDIR/large_b.txt"
run_test "large serial" -s "$TMPDIR/large_a.txt"
run_test "large serial multi" -s "$TMPDIR/large_a.txt" "$TMPDIR/large_b.txt"

# ── Binary data ──
echo "=== Binary data ==="
run_test "binary files" "$TMPDIR/bin_a.txt" "$TMPDIR/bin_b.txt"
run_test "binary serial" -s "$TMPDIR/bin_a.txt"

# ── Error handling ──
echo "=== Error handling ==="
run_test "nonexistent file" /nonexistent_xyz_paste_test
run_test "directory" /tmp

# ── -- end of options ──
echo "=== -- end of options ==="
run_test "dashdash then files" -- "$TMPDIR/a.txt"

# ── Combined flags ──
echo "=== Combined flags ==="
run_test "-sd:" -s -d ':' "$TMPDIR/a.txt" "$TMPDIR/b.txt"
run_test "-d: -s together" -d ':' -s "$TMPDIR/a.txt"

# ── Help/Version ──
echo "=== Help/Version ==="
$BIN --help > /dev/null 2>&1; help_exit=$?
if [ "$help_exit" = "0" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); ERRORS+=("FAIL: --help exit code"); fi

$BIN --version > /dev/null 2>&1; ver_exit=$?
if [ "$ver_exit" = "0" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); ERRORS+=("FAIL: --version exit code"); fi

# ── --help/--version produce non-empty output ──
help_out=$($BIN --help 2>/dev/null)
if [ -n "$help_out" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); ERRORS+=("FAIL: --help empty output"); fi

ver_out=$($BIN --version 2>/dev/null)
if [ -n "$ver_out" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); ERRORS+=("FAIL: --version empty output"); fi

# ── Broken pipe ──
echo "=== Broken pipe ==="
$BIN "$TMPDIR/large_a.txt" 2>/dev/null | head -1 > /dev/null
pipe_exit=$?
# GNU paste exits 0 on SIGPIPE (signal caught)
if [ "$pipe_exit" -lt 2 ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); ERRORS+=("FAIL: broken pipe exit=$pipe_exit"); fi

# ── Results ──
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
