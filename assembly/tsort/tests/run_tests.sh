#!/bin/bash
# Test suite for ftsort (assembly tsort)
# Usage: bash tests/run_tests.sh ./ftsort

BIN="${1:-./ftsort}"
GNU="/usr/bin/tsort"
TOOL="tsort"

PASS=0
FAIL=0
ERRORS=()

normalize_gnu() {
    sed -e "s|$GNU|$TOOL|g" -e "s|^$TOOL:|$TOOL:|g"
}

normalize_our() {
    sed -e "s|$BIN|$TOOL|g" -e "s|^$TOOL:|$TOOL:|g"
}

# run_test_stdin DESC INPUT [ARGS...]
# Compare stdout+stderr+exit between GNU and our implementation
run_test_stdin() {
    local desc="$1"
    local input="$2"
    shift 2
    local args=("$@")

    local expected_out expected_err expected_exit
    local got_out got_err got_exit

    expected_out=$(printf '%s' "$input" | $GNU "${args[@]}" 2>/tmp/_tsort_gnu_err)
    expected_exit=$?
    expected_err=$(cat /tmp/_tsort_gnu_err | normalize_gnu)
    expected_out_norm=$(echo "$expected_out" | normalize_gnu)

    got_out=$(printf '%s' "$input" | $BIN "${args[@]}" 2>/tmp/_tsort_our_err)
    got_exit=$?
    got_err=$(cat /tmp/_tsort_our_err | normalize_our)
    got_out_norm=$(echo "$got_out" | normalize_our)

    local ok=true
    if [ "$expected_out_norm" != "$got_out_norm" ]; then ok=false; fi
    if [ "$expected_err" != "$got_err" ]; then ok=false; fi
    if [ "$expected_exit" != "$got_exit" ]; then ok=false; fi

    if $ok; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
        ERRORS+=("FAIL: $desc")
        if [ "$expected_out_norm" != "$got_out_norm" ]; then
            ERRORS+=("  stdout expected: $(echo "$expected_out_norm" | head -3 | tr '\n' '|')")
            ERRORS+=("  stdout got:      $(echo "$got_out_norm" | head -3 | tr '\n' '|')")
        fi
        if [ "$expected_err" != "$got_err" ]; then
            ERRORS+=("  stderr expected: $(echo "$expected_err" | head -3 | tr '\n' '|')")
            ERRORS+=("  stderr got:      $(echo "$got_err" | head -3 | tr '\n' '|')")
        fi
        if [ "$expected_exit" != "$got_exit" ]; then
            ERRORS+=("  exit expected: $expected_exit, got: $got_exit")
        fi
    fi
}

# run_test_file DESC FILE [ARGS...]
run_test_file() {
    local desc="$1"
    local file="$2"
    shift 2
    local args=("$@")

    local expected_out expected_err expected_exit
    local got_out got_err got_exit

    expected_out=$($GNU "${args[@]}" "$file" 2>/tmp/_tsort_gnu_err)
    expected_exit=$?
    expected_err=$(cat /tmp/_tsort_gnu_err | normalize_gnu)

    got_out=$($BIN "${args[@]}" "$file" 2>/tmp/_tsort_our_err)
    got_exit=$?
    got_err=$(cat /tmp/_tsort_our_err | normalize_our)

    local ok=true
    if [ "$expected_out" != "$got_out" ]; then ok=false; fi
    if [ "$expected_err" != "$got_err" ]; then ok=false; fi
    if [ "$expected_exit" != "$got_exit" ]; then ok=false; fi

    if $ok; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
        ERRORS+=("FAIL: $desc")
        if [ "$expected_out" != "$got_out" ]; then
            ERRORS+=("  stdout expected: $(echo "$expected_out" | head -3 | tr '\n' '|')")
            ERRORS+=("  stdout got:      $(echo "$got_out" | head -3 | tr '\n' '|')")
        fi
        if [ "$expected_err" != "$got_err" ]; then
            ERRORS+=("  stderr expected: $(echo "$expected_err" | head -3 | tr '\n' '|')")
            ERRORS+=("  stderr got:      $(echo "$got_err" | head -3 | tr '\n' '|')")
        fi
        if [ "$expected_exit" != "$got_exit" ]; then
            ERRORS+=("  exit expected: $expected_exit, got: $got_exit")
        fi
    fi
}

# ── Setup ─────────────────────────────────────────────────
TMPDIR=$(mktemp -d /tmp/tsort_test.XXXXXX)
trap "rm -rf $TMPDIR /tmp/_tsort_gnu_err /tmp/_tsort_our_err" EXIT

# ── Basic topological sort ────────────────────────────────
run_test_stdin "basic pair" "$(printf 'a b\n')"
run_test_stdin "basic chain" "$(printf 'a b\nb c\n')"
run_test_stdin "basic chain 3" "$(printf 'a b\nb c\nc d\n')"
run_test_stdin "empty input" ""
run_test_stdin "self loop" "$(printf 'a a\n')"
run_test_stdin "whitespace only" "$(printf '  \n \n')"

# ── Diamond dependency ────────────────────────────────────
run_test_stdin "diamond" "$(printf 'a b\na c\nb d\nc d\n')"
run_test_stdin "diamond reversed pairs" "$(printf 'a c\na b\nc d\nb d\n')"
run_test_stdin "diamond with extra" "$(printf 'a b\na c\nb d\nc d\nd e\n')"

# ── Independent nodes ────────────────────────────────────
run_test_stdin "independent nodes abc" "$(printf 'a a\nb b\nc c\n')"
run_test_stdin "independent nodes reverse" "$(printf 'c c\nb b\na a\n')"
run_test_stdin "independent nodes zyx" "$(printf 'z z\ny y\nx x\n')"

# ── Multiple independent chains ──────────────────────────
run_test_stdin "two chains" "$(printf 'a b\nc d\n')"
run_test_stdin "three chains" "$(printf 'e f\na b\nc d\n')"

# ── Cycle detection ──────────────────────────────────────
run_test_stdin "two node cycle" "$(printf 'a b\nb a\n')"
run_test_stdin "three node cycle" "$(printf 'a b\nb c\nc a\n')"
run_test_stdin "cycle with tail" "$(printf 'x y\na b\nb c\nc a\n')"
run_test_stdin "multiple cycles" "$(printf 'a b\nb a\nc d\nd c\n')"
run_test_stdin "complex cycle" "$(printf 'a b\nb c\nc a\nc d\n')"

# ── Numeric nodes ────────────────────────────────────────
run_test_stdin "numeric chain" "$(printf '1 2\n2 3\n3 4\n')"
run_test_stdin "numeric diamond" "$(printf '1 2\n1 3\n2 4\n3 4\n')"
run_test_stdin "numeric independent" "$(printf '3 3\n1 1\n2 2\n')"

# ── Whitespace handling ──────────────────────────────────
run_test_stdin "tab separated" "$(printf 'a\tb\nb\tc\n')"
run_test_stdin "multiple spaces" "$(printf '  a   b  \n  b    c  \n')"
run_test_stdin "mixed whitespace" "$(printf 'a \t b\nb  c\n')"

# ── Long node names ──────────────────────────────────────
run_test_stdin "long names" "$(printf 'abcdefghijklmnopqrstuvwxyz xyz\n')"
run_test_stdin "names with dots" "$(printf 'foo.c foo.o\nbar.c bar.o\n')"
run_test_stdin "names with numbers" "$(printf 'node1 node2\nnode2 node3\n')"

# ── Odd tokens error ─────────────────────────────────────
run_test_stdin "odd tokens 1" "$(printf 'a\n')"
run_test_stdin "odd tokens 3" "$(printf 'a b\nc\n')"

# ── File input ────────────────────────────────────────────
printf 'a b\nb c\nc d\n' > "$TMPDIR/basic.txt"
run_test_file "file basic" "$TMPDIR/basic.txt"

printf 'a b\nb c\nc a\n' > "$TMPDIR/cycle.txt"
run_test_file "file cycle" "$TMPDIR/cycle.txt"

printf 'a a\nb b\n' > "$TMPDIR/independent.txt"
run_test_file "file independent" "$TMPDIR/independent.txt"

printf '' > "$TMPDIR/empty.txt"
run_test_file "file empty" "$TMPDIR/empty.txt"

# ── Error cases ──────────────────────────────────────────
# File not found (normalize the error message)
got_exit_nf=$($BIN /tmp/nonexistent_tsort_file 2>/dev/null; echo $?)
if [ "$got_exit_nf" = "1" ]; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: file not found exit code (got $got_exit_nf)")
fi

# Extra operand
got_exit_extra=$($BIN /dev/null /dev/null 2>/dev/null; echo $?)
if [ "$got_exit_extra" = "1" ]; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: extra operand exit code (got $got_exit_extra)")
fi

# ── --help and --version ─────────────────────────────────
help_out=$($BIN --help 2>&1)
help_exit=$?
if [ "$help_exit" = "0" ] && echo "$help_out" | grep -q "Usage:"; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: --help")
fi

ver_out=$($BIN --version 2>&1)
ver_exit=$?
if [ "$ver_exit" = "0" ] && [ -n "$ver_out" ]; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: --version")
fi

# ── Duplicate edges ──────────────────────────────────────
run_test_stdin "duplicate edges" "$(printf 'a b\na b\na b\n')"

# ── Large input ──────────────────────────────────────────
# Chain of 1000 nodes
python3 -c "
for i in range(999):
    print(f'{i} {i+1}')
" > "$TMPDIR/large_chain.txt"
run_test_file "large chain (1000)" "$TMPDIR/large_chain.txt"

# ── stdin via - ──────────────────────────────────────────
run_test_stdin "stdin via dash" "$(printf 'a b\nb c\n')" -

# ── Results ──────────────────────────────────────────────
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
