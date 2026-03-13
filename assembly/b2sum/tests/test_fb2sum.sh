#!/bin/bash
# Test suite for fb2sum (BLAKE2b)
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
B2SUM="${SCRIPT_DIR}/../fb2sum"

PASS=0
FAIL=0

check() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        echo "PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "FAIL: $desc"
        echo "  expected: $expected"
        echo "  actual:   $actual"
        FAIL=$((FAIL + 1))
    fi
}

# Test 1: Empty string
RESULT=$(echo -n "" | "$B2SUM" | cut -d' ' -f1)
check "BLAKE2b-512 empty string" \
    "786a02f742015903c6c6fd852552d272912f4740e15847618a86e217f71f5419d25e1031afee585313896444934eb04b903a685b1448b755d56f701afe9be2ce" \
    "$RESULT"

# Test 2: "abc"
RESULT=$(echo -n "abc" | "$B2SUM" | cut -d' ' -f1)
check "BLAKE2b-512 abc" \
    "ba80a53f981c4d0d6a2797b69f12f6e94c212f14685ac4b74b12bb6fdbffa2d17d87c5392aab792dc252d5de4533cc9518d38aa8dbf1925ab92386edd4009923" \
    "$RESULT"

# Test 3: Output format (hash + two spaces + filename)
RESULT=$(echo -n "" | "$B2SUM")
check "Output format has dash for stdin" \
    "786a02f742015903c6c6fd852552d272912f4740e15847618a86e217f71f5419d25e1031afee585313896444934eb04b903a685b1448b755d56f701afe9be2ce  -" \
    "$RESULT"

# Test 4: --help flag
RESULT=$("$B2SUM" --help 2>&1 | head -1)
check "--help shows usage" \
    "Usage: b2sum [OPTION]... [FILE]..." \
    "$RESULT"

# Test 5: --version flag
RESULT=$("$B2SUM" --version 2>&1 | head -1)
check "--version shows version" \
    "b2sum (GNU coreutils) 9.7" \
    "$RESULT"

# Test 6: File hashing
TMPFILE=$(mktemp)
echo -n "abc" > "$TMPFILE"
RESULT=$("$B2SUM" "$TMPFILE" | cut -d' ' -f1)
check "Hash file containing abc" \
    "ba80a53f981c4d0d6a2797b69f12f6e94c212f14685ac4b74b12bb6fdbffa2d17d87c5392aab792dc252d5de4533cc9518d38aa8dbf1925ab92386edd4009923" \
    "$RESULT"

# Test 7: Check mode
echo "ba80a53f981c4d0d6a2797b69f12f6e94c212f14685ac4b74b12bb6fdbffa2d17d87c5392aab792dc252d5de4533cc9518d38aa8dbf1925ab92386edd4009923  $TMPFILE" > "${TMPFILE}.sums"
RESULT=$("$B2SUM" -c "${TMPFILE}.sums" 2>&1)
check "Check mode" \
    "${TMPFILE}: OK" \
    "$RESULT"

rm -f "$TMPFILE" "${TMPFILE}.sums"

# Summary
echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
