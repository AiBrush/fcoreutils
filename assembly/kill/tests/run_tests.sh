#!/bin/bash
# Test suite for fkill
# Usage: bash tests/run_tests.sh ./fkill

BIN="${1:-./fkill}"
PASS=0
FAIL=0
ERRORS=()

check() {
    local desc="$1" expected_exit="$2"
    shift 2
    $BIN "$@" > /dev/null 2>&1
    local got=$?
    if [ "$got" = "$expected_exit" ]; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
        ERRORS+=("FAIL: $desc — expected exit $expected_exit, got $got")
    fi
}

# List signals
check "-l lists signals" 0 -l

# --help / --version
check "--help exits 0" 0 --help
check "--version exits 0" 0 --version

# Invalid PID
check "invalid PID" 1 99999999

echo ""
echo "Results: $PASS passed, $FAIL failed out of $((PASS+FAIL)) tests"
for e in "${ERRORS[@]}"; do echo "  $e"; done
echo ""
[ $FAIL -eq 0 ] && echo "ALL TESTS PASSED" && exit 0
echo "$FAIL TESTS FAILED" && exit 1
