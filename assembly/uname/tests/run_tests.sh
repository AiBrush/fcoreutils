#!/bin/bash
# Test suite for funame
# Usage: bash tests/run_tests.sh ./funame

BIN="${1:-./funame}"
GNU="uname"
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
    local expected_err=$(cat "$TMPDIR/expected_err")
    local got_err=$(cat "$TMPDIR/got_err")

    # Normalize tool name in error messages
    expected_err=$(echo "$expected_err" | sed "s|$(which $GNU)|$GNU|g")

    if [ "$expected" = "$got" ] && [ "$expected_exit" = "$got_exit" ] && [ "$expected_err" = "$got_err" ]; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
        ERRORS+=("FAIL: $desc")
        if [ "$expected" != "$got" ]; then
            ERRORS+=("  expected stdout: $(echo "$expected" | head -3)")
            ERRORS+=("  got stdout:      $(echo "$got" | head -3)")
        fi
        if [ "$expected_err" != "$got_err" ]; then
            ERRORS+=("  expected stderr: $(echo "$expected_err" | head -3)")
            ERRORS+=("  got stderr:      $(echo "$got_err" | head -3)")
        fi
        if [ "$expected_exit" != "$got_exit" ]; then
            ERRORS+=("  expected exit: $expected_exit, got: $got_exit")
        fi
    fi
}

# Like run_test but normalizes -p/-i platform differences.
# GNU coreutils returns "unknown" for -p/-i on some distros (Debian) but
# returns the machine type on others (Ubuntu). Our assembly always returns
# the machine type. Normalize both outputs so the comparison works everywhere.
# For -a output, GNU on Debian omits -p/-i entirely; we insert them for normalization.
MACHINE=$(uname -m)
normalize_pi() {
    local text="$1"
    # Replace standalone "unknown" with machine type
    text=$(echo "$text" | sed "s/unknown/$MACHINE/g")
    # For -a output: if machine field is followed directly by GNU/Linux (missing -p/-i),
    # insert the processor and hardware-platform fields
    text=$(echo "$text" | sed "s/$MACHINE GNU\/Linux/$MACHINE $MACHINE $MACHINE GNU\/Linux/g")
    # The above might triple-expand if already present; collapse back
    # Expected final form: ... $MACHINE $MACHINE $MACHINE GNU/Linux
    text=$(echo "$text" | sed "s/$MACHINE $MACHINE $MACHINE $MACHINE $MACHINE GNU\/Linux/$MACHINE $MACHINE $MACHINE GNU\/Linux/g")
    echo "$text"
}
run_test_pi() {
    local desc="$1"
    shift
    local args=("$@")

    $GNU "${args[@]}" > "$TMPDIR/expected" 2> "$TMPDIR/expected_err"
    local expected_exit=$?
    $BIN "${args[@]}" > "$TMPDIR/got" 2> "$TMPDIR/got_err"
    local got_exit=$?

    # Normalize: handle unknown/machine-type differences for -p/-i
    local expected=$(normalize_pi "$(cat "$TMPDIR/expected")")
    local got=$(normalize_pi "$(cat "$TMPDIR/got")")
    local expected_err=$(cat "$TMPDIR/expected_err")
    local got_err=$(cat "$TMPDIR/got_err")

    expected_err=$(echo "$expected_err" | sed "s|$(which $GNU)|$GNU|g")

    if [ "$expected" = "$got" ] && [ "$expected_exit" = "$got_exit" ] && [ "$expected_err" = "$got_err" ]; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
        ERRORS+=("FAIL: $desc")
        if [ "$expected" != "$got" ]; then
            ERRORS+=("  expected stdout: $(echo "$expected" | head -3)")
            ERRORS+=("  got stdout:      $(echo "$got" | head -3)")
        fi
        if [ "$expected_err" != "$got_err" ]; then
            ERRORS+=("  expected stderr: $(echo "$expected_err" | head -3)")
            ERRORS+=("  got stderr:      $(echo "$got_err" | head -3)")
        fi
        if [ "$expected_exit" != "$got_exit" ]; then
            ERRORS+=("  expected exit: $expected_exit, got: $got_exit")
        fi
    fi
}

# Separate test for help/version (text may differ between builds)
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

# Test stdout-only output (no stderr)
run_test_stdout_only() {
    local desc="$1"
    shift
    local args=("$@")

    $BIN "${args[@]}" > "$TMPDIR/stdout" 2> "$TMPDIR/stderr"
    local exit_code=$?

    if [ $exit_code -eq 0 ] && [ -s "$TMPDIR/stdout" ] && [ ! -s "$TMPDIR/stderr" ]; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
        ERRORS+=("FAIL: $desc — expected exit 0, stdout output, no stderr")
    fi
}

# ── Standard flags ──
run_test_exit_only "--help exit code" --help
run_test_exit_only "--version exit code" --version
run_test "invalid long flag" --invalid-flag-xyz
run_test "invalid short flag" -Z

# ── FD isolation ──
run_test_fd "--help to stdout" --help
run_test_fd "error to stderr" --invalid-flag-xyz

# ── Core functionality: no flags (default -s) ──
run_test "no flags (default -s)"

# ── Individual flags ──
run_test "-s kernel name" -s
run_test "-n nodename" -n
run_test "-r kernel release" -r
run_test "-v kernel version" -v
run_test "-m machine" -m
run_test_pi "-p processor" -p
run_test_pi "-i hardware platform" -i
run_test "-o operating system" -o

# ── All flags ──
run_test_pi "-a all info" -a

# ── Combined flags ──
run_test "-sn sysname+nodename" -sn
run_test "-sr sysname+release" -sr
run_test "-snrvm all standard" -snrvm
run_test "-mo machine+os" -mo
run_test_pi "-pi processor+platform" -pi
run_test_pi "-snrvmpio all individual" -snrvmpio

# ── Long flags ──
run_test "--kernel-name" --kernel-name
run_test "--nodename" --nodename
run_test "--kernel-release" --kernel-release
run_test "--kernel-version" --kernel-version
run_test "--machine" --machine
run_test_pi "--processor" --processor
run_test_pi "--hardware-platform" --hardware-platform
run_test "--operating-system" --operating-system
run_test_pi "--all" --all

# ── Error handling ──
run_test "extra operand" extraarg
run_test "invalid short -Z" -Z
run_test "invalid short -x" -x

# ── FD isolation for normal output ──
run_test_stdout_only "normal output to stdout only" -s
run_test_stdout_only "-a output to stdout only" -a

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
