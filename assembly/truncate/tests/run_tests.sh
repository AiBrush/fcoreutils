#!/bin/bash
# Test suite for ftruncate
# Usage: bash tests/run_tests.sh ./ftruncate

BIN="${1:-./ftruncate}"
GNU="truncate"
PASS=0
FAIL=0
ERRORS=()
TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT

run_test() {
    local desc="$1"
    shift
    local args=("$@")

    # Set up fresh test files for each test
    $GNU "${args[@]}" 2> "$TMPDIR/expected_err"
    local expected_exit=$?
    local expected_err=$(cat "$TMPDIR/expected_err")

    # We need to undo what GNU did and redo with our tool
    # For file-modifying tests, we handle separately
    $BIN "${args[@]}" 2> "$TMPDIR/got_err"
    local got_exit=$?
    local got_err=$(cat "$TMPDIR/got_err")

    # Normalize tool name in error messages
    expected_err=$(echo "$expected_err" | sed "s|$(which $GNU)|$GNU|g")

    if [ "$expected_exit" = "$got_exit" ]; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
        ERRORS+=("FAIL: $desc")
        if [ "$expected_exit" != "$got_exit" ]; then
            ERRORS+=("  expected exit: $expected_exit, got: $got_exit")
        fi
        if [ "$expected_err" != "$got_err" ]; then
            ERRORS+=("  expected stderr: $(echo "$expected_err" | head -3)")
            ERRORS+=("  got stderr:      $(echo "$got_err" | head -3)")
        fi
    fi
}

run_test_truncate() {
    local desc="$1"
    shift
    local expected_size="$1"
    shift
    local args=("$@")

    # Create test file
    local testfile="$TMPDIR/test_$$_$RANDOM"

    # Check if args reference a file - replace placeholder
    local real_args=()
    for arg in "${args[@]}"; do
        if [ "$arg" = "TESTFILE" ]; then
            real_args+=("$testfile")
        else
            real_args+=("$arg")
        fi
    done

    # Create the test file with some initial content if it doesn't exist yet
    # (unless test specifically tests creation)
    if [ ! -f "$testfile" ]; then
        touch "$testfile"
    fi

    $BIN "${real_args[@]}" 2> "$TMPDIR/got_err"
    local got_exit=$?

    if [ $got_exit -ne 0 ]; then
        FAIL=$((FAIL+1))
        ERRORS+=("FAIL: $desc — exit code $got_exit")
        ERRORS+=("  stderr: $(cat "$TMPDIR/got_err" | head -3)")
        rm -f "$testfile"
        return
    fi

    local got_size=$(stat -c %s "$testfile" 2>/dev/null)

    if [ "$got_size" = "$expected_size" ]; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
        ERRORS+=("FAIL: $desc")
        ERRORS+=("  expected size: $expected_size, got: $got_size")
    fi

    rm -f "$testfile"
}

run_test_truncate_with_initial() {
    local desc="$1"
    local initial_size="$2"
    local expected_size="$3"
    shift 3
    local args=("$@")

    local testfile="$TMPDIR/test_$$_$RANDOM"

    # Create file with initial size
    dd if=/dev/zero of="$testfile" bs=1 count="$initial_size" 2>/dev/null

    # Replace TESTFILE placeholder
    local real_args=()
    for arg in "${args[@]}"; do
        if [ "$arg" = "TESTFILE" ]; then
            real_args+=("$testfile")
        else
            real_args+=("$arg")
        fi
    done

    $BIN "${real_args[@]}" 2> "$TMPDIR/got_err"
    local got_exit=$?

    if [ $got_exit -ne 0 ]; then
        FAIL=$((FAIL+1))
        ERRORS+=("FAIL: $desc — exit code $got_exit")
        ERRORS+=("  stderr: $(cat "$TMPDIR/got_err" | head -3)")
        rm -f "$testfile"
        return
    fi

    local got_size=$(stat -c %s "$testfile" 2>/dev/null)

    if [ "$got_size" = "$expected_size" ]; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
        ERRORS+=("FAIL: $desc")
        ERRORS+=("  expected size: $expected_size, got: $got_size")
    fi

    rm -f "$testfile"
}

# Separate test for help/version (text may differ)
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

# ── Standard flags ──
run_test_exit_only "--help exit code" --help
run_test_exit_only "--version exit code" --version
run_test "invalid long flag" --invalid-flag-xyz
run_test "no arguments"

# ── FD isolation ──
run_test_fd "--help to stdout" --help
run_test_fd "error to stderr"

# ── Core functionality: set exact size ──
run_test_truncate "set size to 100" 100 -s 100 TESTFILE
run_test_truncate "set size to 0" 0 -s 0 TESTFILE
run_test_truncate "set size to 1024" 1024 -s 1024 TESTFILE
run_test_truncate "set size to 1K suffix" 1024 -s 1K TESTFILE
run_test_truncate "set size to 1M suffix" 1048576 -s 1M TESTFILE
run_test_truncate "set size to 1KB suffix" 1000 -s 1KB TESTFILE
run_test_truncate "set size to 1MB suffix" 1000000 -s 1MB TESTFILE
run_test_truncate "set size to 2K suffix" 2048 -s 2K TESTFILE

# ── Relative sizes ──
run_test_truncate_with_initial "grow by 50 (+50)" 100 150 -s +50 TESTFILE
run_test_truncate_with_initial "shrink by 50 (-50)" 200 150 -s -50 TESTFILE
run_test_truncate_with_initial "shrink to zero (-200 from 100)" 100 0 -s -200 TESTFILE
run_test_truncate_with_initial "grow by 1K" 100 1124 -s +1K TESTFILE

# ── --size= long form ──
run_test_truncate "long form --size=100" 100 --size=100 TESTFILE
run_test_truncate "long form --size=1K" 1024 --size=1K TESTFILE

# ── -c / --no-create ──
run_test_no_create() {
    local desc="$1"
    local testfile="$TMPDIR/nonexistent_$$_$RANDOM"

    # File should NOT exist
    rm -f "$testfile"

    $BIN -c -s 100 "$testfile" 2> "$TMPDIR/got_err"
    local got_exit=$?

    if [ ! -f "$testfile" ] && [ $got_exit -eq 0 ]; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
        if [ -f "$testfile" ]; then
            ERRORS+=("FAIL: $desc — file was created despite -c flag")
        else
            ERRORS+=("FAIL: $desc — exit code $got_exit (expected 0)")
        fi
    fi
}

run_test_no_create "-c flag: don't create nonexistent file"

run_test_no_create_long() {
    local desc="$1"
    local testfile="$TMPDIR/nonexistent_$$_$RANDOM"

    rm -f "$testfile"

    $BIN --no-create -s 100 "$testfile" 2> "$TMPDIR/got_err"
    local got_exit=$?

    if [ ! -f "$testfile" ] && [ $got_exit -eq 0 ]; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
        ERRORS+=("FAIL: $desc")
    fi
}

run_test_no_create_long "--no-create flag: don't create nonexistent file"

# ── File creation (without -c) ──
run_test_create_file() {
    local desc="$1"
    local testfile="$TMPDIR/newfile_$$_$RANDOM"

    rm -f "$testfile"

    $BIN -s 100 "$testfile" 2> "$TMPDIR/got_err"
    local got_exit=$?

    if [ -f "$testfile" ] && [ $got_exit -eq 0 ]; then
        local got_size=$(stat -c %s "$testfile")
        if [ "$got_size" = "100" ]; then
            PASS=$((PASS+1))
        else
            FAIL=$((FAIL+1))
            ERRORS+=("FAIL: $desc — size $got_size, expected 100")
        fi
    else
        FAIL=$((FAIL+1))
        ERRORS+=("FAIL: $desc — file not created or bad exit code $got_exit")
    fi
    rm -f "$testfile"
}

run_test_create_file "create file if not exists"

# ── Reference file ──
run_test_reference() {
    local desc="$1"
    local ref_size="$2"
    local expected_size="$3"
    shift 3

    local reffile="$TMPDIR/ref_$$_$RANDOM"
    local testfile="$TMPDIR/test_$$_$RANDOM"

    dd if=/dev/zero of="$reffile" bs=1 count="$ref_size" 2>/dev/null
    touch "$testfile"

    # Replace placeholders
    local real_args=()
    for arg in "$@"; do
        arg="${arg//REFFILE/$reffile}"
        arg="${arg//TESTFILE/$testfile}"
        real_args+=("$arg")
    done

    $BIN "${real_args[@]}" 2> "$TMPDIR/got_err"
    local got_exit=$?

    if [ $got_exit -ne 0 ]; then
        FAIL=$((FAIL+1))
        ERRORS+=("FAIL: $desc — exit code $got_exit")
        ERRORS+=("  stderr: $(cat "$TMPDIR/got_err" | head -3)")
        rm -f "$reffile" "$testfile"
        return
    fi

    local got_size=$(stat -c %s "$testfile" 2>/dev/null)

    if [ "$got_size" = "$expected_size" ]; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
        ERRORS+=("FAIL: $desc")
        ERRORS+=("  expected size: $expected_size, got: $got_size")
    fi

    rm -f "$reffile" "$testfile"
}

run_test_reference "-r reference file" 500 500 -r REFFILE TESTFILE
run_test_reference "--reference= long form" 300 300 --reference=REFFILE TESTFILE

# ── Multiple files ──
run_test_multi_files() {
    local desc="$1"
    local f1="$TMPDIR/multi1_$$_$RANDOM"
    local f2="$TMPDIR/multi2_$$_$RANDOM"

    touch "$f1" "$f2"

    $BIN -s 200 "$f1" "$f2" 2> "$TMPDIR/got_err"
    local got_exit=$?

    local s1=$(stat -c %s "$f1" 2>/dev/null)
    local s2=$(stat -c %s "$f2" 2>/dev/null)

    if [ "$s1" = "200" ] && [ "$s2" = "200" ] && [ $got_exit -eq 0 ]; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
        ERRORS+=("FAIL: $desc — sizes: $s1, $s2 (expected 200, 200)")
    fi

    rm -f "$f1" "$f2"
}

run_test_multi_files "multiple files"

# ── Error handling ──
run_test "missing -s and -r" -c "$TMPDIR/somefile"
run_test "missing file operand" -s 100

# ── Error on nonexistent file without -c ──
run_test_err_noexist() {
    local desc="$1"
    $BIN -s 100 "/nonexistent/path/file" 2> "$TMPDIR/got_err"
    local got_exit=$?

    if [ $got_exit -ne 0 ]; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
        ERRORS+=("FAIL: $desc — expected non-zero exit")
    fi
}

run_test_err_noexist "error on nonexistent file"

# ── Double dash ──
run_test_double_dash() {
    local desc="$1"
    local testfile="$TMPDIR/dd_$$_$RANDOM"
    touch "$testfile"

    $BIN -s 50 -- "$testfile" 2> "$TMPDIR/got_err"
    local got_exit=$?
    local got_size=$(stat -c %s "$testfile" 2>/dev/null)

    if [ "$got_size" = "50" ] && [ $got_exit -eq 0 ]; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
        ERRORS+=("FAIL: $desc — size: $got_size, exit: $got_exit")
    fi

    rm -f "$testfile"
}

run_test_double_dash "-- separator"

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
