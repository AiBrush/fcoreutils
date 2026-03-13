#!/bin/bash
# Test suite for fdate
# Usage: bash tests/run_tests.sh ./fdate

BIN="${1:-./fdate}"
GNU="date"
PASS=0
FAIL=0
ERRORS=()

# ── Test: default output format ─────────────────────────────
desc="default output format matches date -u pattern"
got=$($BIN 2>&1)
# Verify it matches: "Day Mon DD HH:MM:SS UTC YYYY"
if echo "$got" | grep -qE '^(Mon|Tue|Wed|Thu|Fri|Sat|Sun) (Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec) [ 0-9][0-9] [0-9]{2}:[0-9]{2}:[0-9]{2} UTC [0-9]{4}$'; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: $desc")
    ERRORS+=("  got: $got")
fi

# ── Test: +FORMAT with %Y-%m-%d ──────────────────────────────
desc="+%Y-%m-%d format"
expected=$(TZ=UTC $GNU -u '+%Y-%m-%d' 2>&1)
got=$($BIN '+%Y-%m-%d' 2>&1)
if [ "$expected" = "$got" ]; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: $desc")
    ERRORS+=("  expected: $expected")
    ERRORS+=("  got: $got")
fi

# ── Test: +FORMAT with %H:%M:%S ──────────────────────────────
desc="+%H:%M:%S format"
expected=$(TZ=UTC $GNU -u '+%H:%M:%S' 2>&1)
got=$($BIN '+%H:%M:%S' 2>&1)
# Compare hour and minute (second may differ by 1)
exp_hm=$(echo "$expected" | cut -d: -f1-2)
got_hm=$(echo "$got" | cut -d: -f1-2)
if [ "$exp_hm" = "$got_hm" ]; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: $desc")
    ERRORS+=("  expected: $expected")
    ERRORS+=("  got: $got")
fi

# ── Test: -R (RFC 5322) ──────────────────────────────────────
desc="-R RFC 5322 format"
got=$($BIN -R 2>&1)
if echo "$got" | grep -qE '^(Mon|Tue|Wed|Thu|Fri|Sat|Sun), [0-9]{2} (Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec) [0-9]{4} [0-9]{2}:[0-9]{2}:[0-9]{2} \+0000$'; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: $desc")
    ERRORS+=("  got: $got")
fi

# ── Test: -I (ISO 8601) ──────────────────────────────────────
desc="-I ISO 8601 format"
expected=$(TZ=UTC $GNU -u -I 2>&1)
got=$($BIN -I 2>&1)
# Our -I outputs YYYY-MM-DD, GNU may add timezone (+00:00)
# Just check we produce valid ISO date
if echo "$got" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: $desc")
    ERRORS+=("  expected pattern: YYYY-MM-DD")
    ERRORS+=("  got: $got")
fi

# ── Test: -u flag accepted ────────────────────────────────────
desc="-u flag accepted"
$BIN -u > /dev/null 2>&1
got_exit=$?
if [ "$got_exit" = "0" ]; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: $desc (exit: $got_exit)")
fi

# ── Test: +%F format ─────────────────────────────────────────
desc="+%F format"
expected=$(TZ=UTC $GNU -u '+%F' 2>&1)
got=$($BIN '+%F' 2>&1)
if [ "$expected" = "$got" ]; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: $desc")
    ERRORS+=("  expected: $expected")
    ERRORS+=("  got: $got")
fi

# ── Test: +%T format ─────────────────────────────────────────
desc="+%T format"
expected=$(TZ=UTC $GNU -u '+%T' 2>&1)
got=$($BIN '+%T' 2>&1)
exp_hm=$(echo "$expected" | cut -d: -f1-2)
got_hm=$(echo "$got" | cut -d: -f1-2)
if [ "$exp_hm" = "$got_hm" ]; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: $desc")
    ERRORS+=("  expected: $expected")
    ERRORS+=("  got: $got")
fi

# ── Test: +%s (epoch) ────────────────────────────────────────
desc="+%s epoch seconds"
expected=$(TZ=UTC $GNU -u '+%s' 2>&1)
got=$($BIN '+%s' 2>&1)
# Allow up to 2 seconds difference
diff=$((got - expected))
if [ "$diff" -ge -2 ] && [ "$diff" -le 2 ]; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: $desc")
    ERRORS+=("  expected: $expected")
    ERRORS+=("  got: $got (diff: $diff)")
fi

# ── Test: +%a weekday abbreviation ────────────────────────────
desc="+%a weekday"
expected=$(TZ=UTC $GNU -u '+%a' 2>&1)
got=$($BIN '+%a' 2>&1)
if [ "$expected" = "$got" ]; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: $desc")
    ERRORS+=("  expected: $expected")
    ERRORS+=("  got: $got")
fi

# ── Test: +%b month abbreviation ──────────────────────────────
desc="+%b month"
expected=$(TZ=UTC $GNU -u '+%b' 2>&1)
got=$($BIN '+%b' 2>&1)
if [ "$expected" = "$got" ]; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: $desc")
    ERRORS+=("  expected: $expected")
    ERRORS+=("  got: $got")
fi

# ── Test: +%j day of year ────────────────────────────────────
desc="+%j day of year"
expected=$(TZ=UTC $GNU -u '+%j' 2>&1)
got=$($BIN '+%j' 2>&1)
if [ "$expected" = "$got" ]; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: $desc")
    ERRORS+=("  expected: $expected")
    ERRORS+=("  got: $got")
fi

# ── Test: exit code 0 ────────────────────────────────────────
desc="exit code 0"
$BIN > /dev/null 2>&1
got_exit=$?
if [ "$got_exit" = "0" ]; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: $desc (exit: $got_exit)")
fi

# ── Test: --help exit code ────────────────────────────────────
desc="--help exit code"
$BIN --help > /dev/null 2>&1
got_exit=$?
if [ "$got_exit" = "0" ]; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: $desc (exit: $got_exit)")
fi

# ── Test: --version exit code ─────────────────────────────────
desc="--version exit code"
$BIN --version > /dev/null 2>&1
got_exit=$?
if [ "$got_exit" = "0" ]; then
    PASS=$((PASS+1))
else
    FAIL=$((FAIL+1))
    ERRORS+=("FAIL: $desc (exit: $got_exit)")
fi

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
