#!/bin/bash
# Master test runner for all assembly coreutils GNU compatibility tests
# Runs each tool's test script and reports overall results
# Usage: bash run_all_tests.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

TOTAL_PASS=0
TOTAL_FAIL=0
TOOL_RESULTS=()

run_tool_test() {
    local tool="$1"
    local script="$2"
    local binary="$3"

    if [ ! -f "$SCRIPT_DIR/$script" ]; then
        echo "  SKIP: $script not found"
        TOOL_RESULTS+=("SKIP  $tool -- $script not found")
        return
    fi

    if [ ! -x "$binary" ] && [ ! -f "$binary" ]; then
        echo "  SKIP: $tool binary not found at $binary"
        TOOL_RESULTS+=("SKIP  $tool -- binary not found at $binary")
        return
    fi

    echo "--- Testing $tool ---"
    output=$(bash "$SCRIPT_DIR/$script" "$binary" 2>&1)
    local exit_code=$?

    # Extract pass/fail counts from output
    local results_line=$(echo "$output" | grep -E '^Results:')
    local pass=$(echo "$results_line" | grep -oP '\d+ passed' | grep -oP '\d+')
    local fail=$(echo "$results_line" | grep -oP '\d+ failed' | grep -oP '\d+')

    pass=${pass:-0}
    fail=${fail:-0}

    TOTAL_PASS=$((TOTAL_PASS + pass))
    TOTAL_FAIL=$((TOTAL_FAIL + fail))

    if [ "$exit_code" -eq 0 ]; then
        echo "  $tool: $pass passed, $fail failed -- ALL PASSED"
        TOOL_RESULTS+=("PASS  $tool -- $pass passed")
    else
        echo "  $tool: $pass passed, $fail failed -- FAILURES"
        TOOL_RESULTS+=("FAIL  $tool -- $pass passed, $fail failed")
        # Show failure details
        echo "$output" | grep -A1 "^  FAIL:" | head -20
    fi
    echo ""
}

echo "============================================"
echo " Assembly Coreutils GNU Compatibility Tests"
echo "============================================"
echo ""

ASM_DIR="$SCRIPT_DIR/.."

run_tool_test "ffalse"    "test_ffalse.sh"    "$ASM_DIR/false/ffalse"
run_tool_test "fcat"      "test_fcat.sh"      "$ASM_DIR/cat/fcat"
run_tool_test "fseq"      "test_fseq.sh"      "$ASM_DIR/seq/fseq"
run_tool_test "fnl"       "test_fnl.sh"       "$ASM_DIR/nl/fnl"
run_tool_test "fexpand"   "test_fexpand.sh"   "$ASM_DIR/expand/fexpand"
run_tool_test "funexpand" "test_funexpand.sh" "$ASM_DIR/unexpand/funexpand"
run_tool_test "ffold"     "test_ffold.sh"     "$ASM_DIR/fold/ffold"
run_tool_test "funiq"     "test_funiq.sh"     "$ASM_DIR/uniq/funiq"
run_tool_test "fod"       "test_fod.sh"       "$ASM_DIR/od/fod"
run_tool_test "fsort"     "test_fsort.sh"     "$ASM_DIR/sort/fsort"

echo "============================================"
echo " Overall Results"
echo "============================================"
echo ""
echo "Total: $TOTAL_PASS passed, $TOTAL_FAIL failed out of $((TOTAL_PASS + TOTAL_FAIL)) tests"
echo ""

echo "Per-tool summary:"
for r in "${TOOL_RESULTS[@]}"; do
    echo "  $r"
done
echo ""

if [ $TOTAL_FAIL -eq 0 ]; then
    echo "ALL TOOLS PASSED"
    exit 0
else
    echo "$TOTAL_FAIL TOTAL FAILURES"
    exit 1
fi
