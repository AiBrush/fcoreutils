#!/bin/bash
# Test suite for ftouch
# Usage: bash tests/run_tests.sh [./ftouch]

BIN="${1:-./ftouch}"
GNU="touch"
PASS=0
FAIL=0
ERRORS=()
TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT

# ── Helpers ──

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

    if echo "${args[@]}" | grep -q "\-\-version"; then
        if [ -s "$TMPDIR/stdout" ] && [ ! -s "$TMPDIR/stderr" ]; then
            PASS=$((PASS+1))
        else
            FAIL=$((FAIL+1))
            ERRORS+=("FAIL: $desc — --version should write to stdout only")
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

run_test_error() {
    local desc="$1"
    shift
    local args=("$@")

    $GNU "${args[@]}" 2> /dev/null
    local expected_exit=$?
    $BIN "${args[@]}" 2> /dev/null
    local got_exit=$?

    if [ "$expected_exit" = "$got_exit" ]; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
        ERRORS+=("FAIL: $desc — expected exit: $expected_exit, got: $got_exit")
    fi
}

# ── Standard flags ──
echo "=== Standard flags ==="
run_test_exit_only "--help exit code" --help
run_test_exit_only "--version exit code" --version
run_test_error "no arguments"
run_test_error "invalid long flag" --invalid-flag-xyz

# ── FD isolation ──
echo "=== FD isolation ==="
run_test_fd "--help to stdout" --help
run_test_fd "--version to stdout" --version
run_test_fd "error to stderr"

# ── Basic file creation ──
echo "=== Basic file creation ==="

run_test_create() {
    local desc="$1"
    local testfile="$TMPDIR/create_$$_$RANDOM"
    rm -f "$testfile"

    $BIN "$testfile" 2> "$TMPDIR/got_err"
    local got_exit=$?

    if [ -f "$testfile" ] && [ $got_exit -eq 0 ]; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
        ERRORS+=("FAIL: $desc — file not created or bad exit: $got_exit")
        ERRORS+=("  stderr: $(cat "$TMPDIR/got_err" | head -3)")
    fi
    rm -f "$testfile"
}

run_test_create "create new file"

# ── Update existing file timestamps ──
echo "=== Timestamp update ==="

run_test_update_both() {
    local desc="$1"
    local testfile="$TMPDIR/both_$$_$RANDOM"
    touch -t 202001011200 "$testfile" 2>/dev/null

    sleep 0.1
    $BIN "$testfile" 2> "$TMPDIR/got_err"
    local got_exit=$?

    # Both atime and mtime should be newer than 2020
    local atime=$(stat -c %X "$testfile" 2>/dev/null)
    local mtime=$(stat -c %Y "$testfile" 2>/dev/null)
    # 2020-01-01 12:00 epoch = 1577880000 (approx)
    if [ $got_exit -eq 0 ] && [ "$atime" -gt 1577880000 ] && [ "$mtime" -gt 1577880000 ]; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
        ERRORS+=("FAIL: $desc — exit: $got_exit, atime: $atime, mtime: $mtime")
    fi
    rm -f "$testfile"
}

run_test_update_both "update both atime and mtime"

# ── -a flag (atime only) ──
echo "=== -a flag ==="

run_test_atime_only() {
    local desc="$1"
    local testfile="$TMPDIR/aonly_$$_$RANDOM"
    # Set known times
    touch -t 202001011200 "$testfile" 2>/dev/null
    local orig_mtime=$(stat -c %Y "$testfile" 2>/dev/null)

    sleep 0.1
    $BIN -a "$testfile" 2> "$TMPDIR/got_err"
    local got_exit=$?

    local new_atime=$(stat -c %X "$testfile" 2>/dev/null)
    local new_mtime=$(stat -c %Y "$testfile" 2>/dev/null)

    if [ $got_exit -eq 0 ] && [ "$new_atime" -gt 1577880000 ] && [ "$new_mtime" = "$orig_mtime" ]; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
        ERRORS+=("FAIL: $desc — exit: $got_exit, atime: $new_atime, mtime: $new_mtime (orig_mtime: $orig_mtime)")
    fi
    rm -f "$testfile"
}

run_test_atime_only "-a changes atime only"

# ── -m flag (mtime only) ──
echo "=== -m flag ==="

run_test_mtime_only() {
    local desc="$1"
    local testfile="$TMPDIR/monly_$$_$RANDOM"
    touch -t 202001011200 "$testfile" 2>/dev/null
    local orig_atime=$(stat -c %X "$testfile" 2>/dev/null)

    sleep 0.1
    $BIN -m "$testfile" 2> "$TMPDIR/got_err"
    local got_exit=$?

    local new_atime=$(stat -c %X "$testfile" 2>/dev/null)
    local new_mtime=$(stat -c %Y "$testfile" 2>/dev/null)

    if [ $got_exit -eq 0 ] && [ "$new_atime" = "$orig_atime" ] && [ "$new_mtime" -gt 1577880000 ]; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
        ERRORS+=("FAIL: $desc — exit: $got_exit, atime: $new_atime (orig: $orig_atime), mtime: $new_mtime")
    fi
    rm -f "$testfile"
}

run_test_mtime_only "-m changes mtime only"

# ── -am flag (both explicitly) ──
echo "=== -am flag ==="

run_test_am() {
    local desc="$1"
    local testfile="$TMPDIR/am_$$_$RANDOM"
    touch -t 202001011200 "$testfile" 2>/dev/null

    sleep 0.1
    $BIN -am "$testfile" 2> "$TMPDIR/got_err"
    local got_exit=$?

    local new_atime=$(stat -c %X "$testfile" 2>/dev/null)
    local new_mtime=$(stat -c %Y "$testfile" 2>/dev/null)

    if [ $got_exit -eq 0 ] && [ "$new_atime" -gt 1577880000 ] && [ "$new_mtime" -gt 1577880000 ]; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
        ERRORS+=("FAIL: $desc — exit: $got_exit, atime: $new_atime, mtime: $new_mtime")
    fi
    rm -f "$testfile"
}

run_test_am "-am changes both times"

# ── -c / --no-create ──
echo "=== -c flag ==="

run_test_no_create() {
    local desc="$1"
    local flag="$2"
    local testfile="$TMPDIR/nocreate_$$_$RANDOM"
    rm -f "$testfile"

    $BIN $flag "$testfile" 2> "$TMPDIR/got_err"
    local got_exit=$?

    if [ ! -f "$testfile" ] && [ $got_exit -eq 0 ]; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
        if [ -f "$testfile" ]; then
            ERRORS+=("FAIL: $desc — file was created despite $flag")
        else
            ERRORS+=("FAIL: $desc — exit code $got_exit (expected 0)")
        fi
    fi
}

run_test_no_create "-c does not create" "-c"
run_test_no_create "--no-create does not create" "--no-create"

# ── -c with existing file (should still update) ──
run_test_no_create_existing() {
    local desc="$1"
    local testfile="$TMPDIR/ncexist_$$_$RANDOM"
    touch -t 202001011200 "$testfile" 2>/dev/null

    $BIN -c "$testfile" 2> "$TMPDIR/got_err"
    local got_exit=$?

    local new_mtime=$(stat -c %Y "$testfile" 2>/dev/null)

    if [ $got_exit -eq 0 ] && [ "$new_mtime" -gt 1577880000 ]; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
        ERRORS+=("FAIL: $desc — exit: $got_exit, mtime: $new_mtime")
    fi
    rm -f "$testfile"
}

run_test_no_create_existing "-c with existing file updates times"

# ── -r / --reference ──
echo "=== -r flag ==="

run_test_reference() {
    local desc="$1"
    local ref_stamp="$2"
    shift 2
    local extra_args=("$@")

    local reffile="$TMPDIR/ref_$$_$RANDOM"
    local testfile="$TMPDIR/target_$$_$RANDOM"

    touch -t "$ref_stamp" "$reffile" 2>/dev/null
    touch "$testfile"

    local ref_atime=$(stat -c %X "$reffile" 2>/dev/null)
    local ref_mtime=$(stat -c %Y "$reffile" 2>/dev/null)

    # Build args with actual file paths
    local real_args=()
    for arg in "${extra_args[@]}"; do
        arg="${arg//REFFILE/$reffile}"
        arg="${arg//TESTFILE/$testfile}"
        real_args+=("$arg")
    done

    $BIN "${real_args[@]}" 2> "$TMPDIR/got_err"
    local got_exit=$?

    local got_atime=$(stat -c %X "$testfile" 2>/dev/null)
    local got_mtime=$(stat -c %Y "$testfile" 2>/dev/null)

    if [ $got_exit -eq 0 ] && [ "$got_atime" = "$ref_atime" ] && [ "$got_mtime" = "$ref_mtime" ]; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
        ERRORS+=("FAIL: $desc — exit: $got_exit")
        ERRORS+=("  expected atime=$ref_atime mtime=$ref_mtime")
        ERRORS+=("  got      atime=$got_atime mtime=$got_mtime")
        ERRORS+=("  stderr: $(cat "$TMPDIR/got_err" | head -1)")
    fi
    rm -f "$reffile" "$testfile"
}

run_test_reference "-r short form" "202506151430.00" -r REFFILE TESTFILE
run_test_reference "--reference= long form" "202312251800.30" --reference=REFFILE TESTFILE

# ── -r with nonexistent reference ──
run_test_ref_noexist() {
    local desc="$1"
    local testfile="$TMPDIR/rne_$$_$RANDOM"
    touch "$testfile"

    $BIN -r /nonexistent/ref "$testfile" 2> "$TMPDIR/got_err"
    local got_exit=$?

    if [ $got_exit -ne 0 ]; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
        ERRORS+=("FAIL: $desc — expected non-zero exit")
    fi
    rm -f "$testfile"
}

run_test_ref_noexist "-r with nonexistent reference fails"

# ── -t STAMP ──
echo "=== -t flag ==="

run_test_stamp() {
    local desc="$1"
    local stamp="$2"

    local testfile_gnu="$TMPDIR/tgnu_$$_$RANDOM"
    local testfile_asm="$TMPDIR/tasm_$$_$RANDOM"
    touch "$testfile_gnu" "$testfile_asm"

    $GNU -t "$stamp" "$testfile_gnu" 2>/dev/null
    local gnu_exit=$?
    $BIN -t "$stamp" "$testfile_asm" 2>"$TMPDIR/got_err"
    local asm_exit=$?

    local gnu_atime=$(stat -c %X "$testfile_gnu" 2>/dev/null)
    local gnu_mtime=$(stat -c %Y "$testfile_gnu" 2>/dev/null)
    local asm_atime=$(stat -c %X "$testfile_asm" 2>/dev/null)
    local asm_mtime=$(stat -c %Y "$testfile_asm" 2>/dev/null)

    if [ "$gnu_exit" = "$asm_exit" ] && [ "$gnu_atime" = "$asm_atime" ] && [ "$gnu_mtime" = "$asm_mtime" ]; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
        ERRORS+=("FAIL: $desc — stamp=$stamp")
        ERRORS+=("  GNU: exit=$gnu_exit atime=$gnu_atime mtime=$gnu_mtime")
        ERRORS+=("  ASM: exit=$asm_exit atime=$asm_atime mtime=$asm_mtime")
        ERRORS+=("  stderr: $(cat "$TMPDIR/got_err" | head -1)")
    fi
    rm -f "$testfile_gnu" "$testfile_asm"
}

run_test_stamp "-t CCYYMMDDhhmm" "202506151430"
run_test_stamp "-t CCYYMMDDhhmm.ss" "202506151430.45"
run_test_stamp "-t YYMMDDhhmm" "2506151430"
run_test_stamp "-t YYMMDDhhmm.ss" "2506151430.30"

# ── -d DATE ──
echo "=== -d flag ==="

run_test_date() {
    local desc="$1"
    local datestr="$2"

    local testfile_gnu="$TMPDIR/dgnu_$$_$RANDOM"
    local testfile_asm="$TMPDIR/dasm_$$_$RANDOM"
    touch "$testfile_gnu" "$testfile_asm"

    $GNU -d "$datestr" "$testfile_gnu" 2>/dev/null
    local gnu_exit=$?
    $BIN -d "$datestr" "$testfile_asm" 2>"$TMPDIR/got_err"
    local asm_exit=$?

    local gnu_atime=$(stat -c %X "$testfile_gnu" 2>/dev/null)
    local gnu_mtime=$(stat -c %Y "$testfile_gnu" 2>/dev/null)
    local asm_atime=$(stat -c %X "$testfile_asm" 2>/dev/null)
    local asm_mtime=$(stat -c %Y "$testfile_asm" 2>/dev/null)

    if [ "$gnu_exit" = "$asm_exit" ] && [ "$gnu_atime" = "$asm_atime" ] && [ "$gnu_mtime" = "$asm_mtime" ]; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
        ERRORS+=("FAIL: $desc — date='$datestr'")
        ERRORS+=("  GNU: exit=$gnu_exit atime=$gnu_atime mtime=$gnu_mtime")
        ERRORS+=("  ASM: exit=$asm_exit atime=$asm_atime mtime=$asm_mtime")
        ERRORS+=("  stderr: $(cat "$TMPDIR/got_err" | head -1)")
    fi
    rm -f "$testfile_gnu" "$testfile_asm"
}

run_test_date "-d YYYY-MM-DD" "2025-06-15"
run_test_date "-d YYYY-MM-DDThh:mm:ss" "2025-06-15T14:30:45"
run_test_date "-d 'YYYY-MM-DD hh:mm:ss'" "2025-06-15 14:30:45"

# ── Multiple files ──
echo "=== Multiple files ==="

run_test_multi() {
    local desc="$1"
    local f1="$TMPDIR/m1_$$_$RANDOM"
    local f2="$TMPDIR/m2_$$_$RANDOM"
    local f3="$TMPDIR/m3_$$_$RANDOM"

    rm -f "$f1" "$f2" "$f3"

    $BIN "$f1" "$f2" "$f3" 2> "$TMPDIR/got_err"
    local got_exit=$?

    if [ -f "$f1" ] && [ -f "$f2" ] && [ -f "$f3" ] && [ $got_exit -eq 0 ]; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
        ERRORS+=("FAIL: $desc — exit: $got_exit, files exist: $(ls "$f1" "$f2" "$f3" 2>&1)")
    fi
    rm -f "$f1" "$f2" "$f3"
}

run_test_multi "create multiple files"

# ── Double dash ──
echo "=== Double dash ==="

run_test_double_dash() {
    local desc="$1"
    local testfile="$TMPDIR/dd_$$_$RANDOM"
    rm -f "$testfile"

    $BIN -- "$testfile" 2> "$TMPDIR/got_err"
    local got_exit=$?

    if [ -f "$testfile" ] && [ $got_exit -eq 0 ]; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
        ERRORS+=("FAIL: $desc — exit: $got_exit")
    fi
    rm -f "$testfile"
}

run_test_double_dash "-- separator"

# ── Combined short options ──
echo "=== Combined short options ==="

run_test_combined_ac() {
    local desc="$1"
    local testfile="$TMPDIR/ac_$$_$RANDOM"
    rm -f "$testfile"

    $BIN -ac "$testfile" 2> "$TMPDIR/got_err"
    local got_exit=$?

    if [ ! -f "$testfile" ] && [ $got_exit -eq 0 ]; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
        if [ -f "$testfile" ]; then
            ERRORS+=("FAIL: $desc — file was created despite -c in -ac")
        else
            ERRORS+=("FAIL: $desc — exit code $got_exit")
        fi
    fi
}

run_test_combined_ac "-ac combined flags"

# ── Error on nonexistent path without -c ──
echo "=== Error handling ==="

run_test_err_noexist() {
    local desc="$1"
    $BIN "/nonexistent/deep/path/file" 2> "$TMPDIR/got_err"
    local got_exit=$?

    if [ $got_exit -ne 0 ]; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
        ERRORS+=("FAIL: $desc — expected non-zero exit")
    fi
}

run_test_err_noexist "error on impossible path"

# ── -h / --no-dereference with symlinks ──
echo "=== -h flag ==="

run_test_no_deref() {
    local desc="$1"
    local realfile="$TMPDIR/real_$$_$RANDOM"
    local linkfile="$TMPDIR/link_$$_$RANDOM"
    touch -t 202001011200 "$realfile"
    ln -sf "$realfile" "$linkfile"

    local orig_mtime=$(stat -c %Y "$realfile" 2>/dev/null)

    # Use -h to affect the symlink, not the target
    # Note: not all filesystems support changing symlink times
    $BIN -h "$linkfile" 2> "$TMPDIR/got_err"
    local got_exit=$?

    # The real file's mtime should NOT have changed
    local new_mtime=$(stat -c %Y "$realfile" 2>/dev/null)

    if [ $got_exit -eq 0 ] && [ "$new_mtime" = "$orig_mtime" ]; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
        ERRORS+=("FAIL: $desc — exit: $got_exit, orig_mtime: $orig_mtime, new_mtime: $new_mtime")
        ERRORS+=("  stderr: $(cat "$TMPDIR/got_err" | head -1)")
    fi
    rm -f "$realfile" "$linkfile"
}

run_test_no_deref "-h affects symlink not target"

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
