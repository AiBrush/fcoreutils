#!/bin/bash
# Quick test vectors for fsha256sum
# Usage: bash tests/test_fsha256sum.sh [./fsha256sum]

BIN="${1:-./fsha256sum}"
PASS=0
FAIL=0

check() {
    local desc="$1"
    local expected="$2"
    local got="$3"

    if [ "$expected" = "$got" ]; then
        PASS=$((PASS+1))
        echo "[PASS] $desc"
    else
        FAIL=$((FAIL+1))
        echo "[FAIL] $desc"
        echo "  expected: $expected"
        echo "  got:      $got"
    fi
}

# Test vector 1: empty string
got=$(echo -n "" | $BIN | cut -d' ' -f1)
check "SHA256('') = e3b0c442..." \
    "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855" "$got"

# Test vector 2: "abc"
got=$(echo -n "abc" | $BIN | cut -d' ' -f1)
check "SHA256('abc') = ba7816bf..." \
    "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad" "$got"

# Test vector 3: "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"
got=$(echo -n "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq" | $BIN | cut -d' ' -f1)
check "SHA256('abcdbcde...nopq') = 248d6a61..." \
    "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1" "$got"

# Test vector 4: "hello world"
got=$(echo -n "hello world" | $BIN | cut -d' ' -f1)
check "SHA256('hello world') = b94d27b9..." \
    "b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9" "$got"

# Test: output format "HASH  -"
got=$(echo -n "abc" | $BIN)
check "output format 'HASH  -'" \
    "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad  -" "$got"

# Test: --tag format
got=$(echo -n "abc" | $BIN --tag)
check "--tag format" \
    "SHA256 (-) = ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad" "$got"

# Test: -b binary mode marker
got=$(echo -n "abc" | $BIN -b)
check "-b binary mode marker" \
    "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad *-" "$got"

# Summary
echo ""
echo "Results: $PASS passed, $FAIL failed out of $((PASS+FAIL)) tests"
[ $FAIL -eq 0 ] && echo "ALL TESTS PASSED" && exit 0
echo "$FAIL TESTS FAILED"
exit 1
