#!/bin/bash
# run_tests.sh — Comprehensive test suite for fpr (assembly pr)
# Usage: bash tests/run_tests.sh ./fpr

set -uo pipefail

FPR="${1:?Usage: $0 <fpr-binary>}"
PASS=0
FAIL=0
SKIP=0
ERRORS=""

run_test() {
    local name="$1"
    local expected="$2"
    local actual="$3"

    if [ "$expected" = "$actual" ]; then
        PASS=$((PASS + 1))
        echo "  PASS: $name"
    else
        FAIL=$((FAIL + 1))
        ERRORS="${ERRORS}FAIL: ${name}\n"
        echo "  FAIL: $name"
        diff <(echo "$expected") <(echo "$actual") | head -20
    fi
}

run_test_raw() {
    local name="$1"
    local expected="$2"
    local actual="$3"

    if [ "$expected" = "$actual" ]; then
        PASS=$((PASS + 1))
        echo "  PASS: $name"
    else
        FAIL=$((FAIL + 1))
        ERRORS="${ERRORS}FAIL: ${name}\n"
        echo "  FAIL: $name"
        diff <(printf '%s' "$expected") <(printf '%s' "$actual") | head -20
    fi
}

echo "=== fpr Test Suite ==="
echo "Binary: $FPR"
echo ""

# ── 1. Basic -t passthrough ──
echo "--- 1. Basic -t passthrough ---"
input="hello\nworld\n"
expected=$(printf "$input" | pr -t 2>/dev/null)
actual=$(printf "$input" | "$FPR" -t 2>/dev/null)
run_test "basic -t passthrough" "$expected" "$actual"

# ── 2. Multiple lines -t ──
echo "--- 2. Multiple lines -t ---"
input=$(seq 1 20 | tr '\n' '\n')
expected=$(seq 1 20 | pr -t 2>/dev/null)
actual=$(seq 1 20 | "$FPR" -t 2>/dev/null)
run_test "seq 1-20 -t" "$expected" "$actual"

# ── 3. Double space -d ──
echo "--- 3. Double space -d ---"
expected=$(printf 'a\nb\nc\n' | pr -t -d 2>/dev/null)
actual=$(printf 'a\nb\nc\n' | "$FPR" -t -d 2>/dev/null)
run_test "-t -d double space" "$expected" "$actual"

# ── 4. Double space with more lines ──
echo "--- 4. Double space more lines ---"
expected=$(printf 'a\nb\nc\nd\ne\n' | pr -t -d 2>/dev/null)
actual=$(printf 'a\nb\nc\nd\ne\n' | "$FPR" -t -d 2>/dev/null)
run_test "-t -d 5 lines" "$expected" "$actual"

# ── 5. Multi-column -2 ──
echo "--- 5. Multi-column -2 ---"
expected=$(printf '1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n' | pr -t -2 2>/dev/null)
actual=$(printf '1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n' | "$FPR" -t -2 2>/dev/null)
run_test "-t -2 multi-column" "$expected" "$actual"

# ── 6. Multi-column -3 ──
echo "--- 6. Multi-column -3 ---"
expected=$(seq 1 12 | pr -t -3 2>/dev/null)
actual=$(seq 1 12 | "$FPR" -t -3 2>/dev/null)
run_test "-t -3 multi-column" "$expected" "$actual"

# ── 7. Multi-column across -a -2 ──
echo "--- 7. Across mode -a -2 ---"
expected=$(printf '1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n' | pr -t -a -2 2>/dev/null)
actual=$(printf '1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n' | "$FPR" -t -a -2 2>/dev/null)
run_test "-t -a -2 across" "$expected" "$actual"

# ── 8. Across -a -3 ──
echo "--- 8. Across -a -3 ---"
expected=$(seq 1 12 | pr -t -a -3 2>/dev/null)
actual=$(seq 1 12 | "$FPR" -t -a -3 2>/dev/null)
run_test "-t -a -3 across" "$expected" "$actual"

# ── 9. Separator -s with tab ──
echo "--- 9. Separator -s (tab) ---"
expected=$(printf '1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n' | pr -t -2 -s 2>/dev/null)
actual=$(printf '1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n' | "$FPR" -t -2 -s 2>/dev/null)
run_test "-t -2 -s tab separator" "$expected" "$actual"

# ── 10. Separator -s: colon ──
echo "--- 10. Separator -s: ---"
expected=$(printf '1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n' | pr -t -2 -s: 2>/dev/null)
actual=$(printf '1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n' | "$FPR" -t -2 -s: 2>/dev/null)
run_test "-t -2 -s: colon separator" "$expected" "$actual"

# ── 11. Separator -S string ──
echo "--- 11. Separator -S string ---"
expected=$(printf '1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n' | pr -t -2 -S' | ' 2>/dev/null)
actual=$(printf '1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n' | "$FPR" -t -2 -S' | ' 2>/dev/null)
run_test "-t -2 -S' | ' string separator" "$expected" "$actual"

# ── 12. Line numbering -n ──
echo "--- 12. Line numbering -n ---"
expected=$(printf 'aaa\nbbb\nccc\n' | pr -t -n 2>/dev/null)
actual=$(printf 'aaa\nbbb\nccc\n' | "$FPR" -t -n 2>/dev/null)
run_test "-t -n line numbering" "$expected" "$actual"

# ── 13. Indent -o ──
echo "--- 13. Indent -o ---"
expected=$(printf 'hello\nworld\n' | pr -t -o5 2>/dev/null)
actual=$(printf 'hello\nworld\n' | "$FPR" -t -o5 2>/dev/null)
run_test "-t -o5 indent" "$expected" "$actual"

# ── 14. Page width -w ──
echo "--- 14. Page width -w ---"
expected=$(seq 1 10 | pr -t -2 -w 40 2>/dev/null)
actual=$(seq 1 10 | "$FPR" -t -2 -w 40 2>/dev/null)
run_test "-t -2 -w 40 page width" "$expected" "$actual"

# ── 15. File input (not stdin) ──
echo "--- 15. File input ---"
tmpfile=$(mktemp)
seq 1 5 > "$tmpfile"
expected=$(pr -t "$tmpfile" 2>/dev/null)
actual=$("$FPR" -t "$tmpfile" 2>/dev/null)
run_test "-t with file input" "$expected" "$actual"
rm -f "$tmpfile"

# ── 16. Empty input ──
echo "--- 16. Empty input ---"
expected=$(printf '' | pr -t 2>/dev/null)
actual=$(printf '' | "$FPR" -t 2>/dev/null)
run_test "-t empty input" "$expected" "$actual"

# ── 17. Single line ──
echo "--- 17. Single line ---"
expected=$(printf 'one\n' | pr -t 2>/dev/null)
actual=$(printf 'one\n' | "$FPR" -t 2>/dev/null)
run_test "-t single line" "$expected" "$actual"

# ── 18. Multi-column with odd line count ──
echo "--- 18. Multi-column odd lines ---"
expected=$(seq 1 7 | pr -t -2 2>/dev/null)
actual=$(seq 1 7 | "$FPR" -t -2 2>/dev/null)
run_test "-t -2 with 7 lines (odd)" "$expected" "$actual"

# ── 19. Across with odd lines ──
echo "--- 19. Across with odd lines ---"
expected=$(seq 1 7 | pr -t -a -2 2>/dev/null)
actual=$(seq 1 7 | "$FPR" -t -a -2 2>/dev/null)
run_test "-t -a -2 with 7 lines" "$expected" "$actual"

# ── 20. Three columns with separator ──
echo "--- 20. Three columns -s ---"
expected=$(seq 1 9 | pr -t -3 -s: 2>/dev/null)
actual=$(seq 1 9 | "$FPR" -t -3 -s: 2>/dev/null)
run_test "-t -3 -s: three columns" "$expected" "$actual"

# ── 21. Header page output (no -t) ──
echo "--- 21. Header page output ---"
tmpfile=$(mktemp)
seq 1 5 > "$tmpfile"
expected_lines=$(pr "$tmpfile" 2>/dev/null | wc -l)
actual_lines=$("$FPR" "$tmpfile" 2>/dev/null | wc -l)
if [ "$expected_lines" = "$actual_lines" ]; then
    PASS=$((PASS + 1))
    echo "  PASS: header page line count ($expected_lines)"
else
    FAIL=$((FAIL + 1))
    ERRORS="${ERRORS}FAIL: header page line count (expected $expected_lines, got $actual_lines)\n"
    echo "  FAIL: header page line count (expected $expected_lines, got $actual_lines)"
fi
rm -f "$tmpfile"

# ── 22. --help ──
echo "--- 22. --help ---"
help_output=$("$FPR" --help 2>/dev/null || true)
if echo "$help_output" | grep -qi "usage\|paginate\|print\|pr"; then
    PASS=$((PASS + 1))
    echo "  PASS: --help produces usage info"
else
    FAIL=$((FAIL + 1))
    ERRORS="${ERRORS}FAIL: --help\n"
    echo "  FAIL: --help doesn't produce usage info"
fi

# ── 23. --version ──
echo "--- 23. --version ---"
ver_output=$("$FPR" --version 2>/dev/null || true)
if echo "$ver_output" | grep -qi "pr\|fpr\|version\|fcoreutils"; then
    PASS=$((PASS + 1))
    echo "  PASS: --version produces version info"
else
    FAIL=$((FAIL + 1))
    ERRORS="${ERRORS}FAIL: --version\n"
    echo "  FAIL: --version doesn't produce version info"
fi

# ── 24. Exit code 0 on success ──
echo "--- 24. Exit codes ---"
printf 'test\n' | "$FPR" -t 2>/dev/null
if [ $? -eq 0 ]; then
    PASS=$((PASS + 1))
    echo "  PASS: exit code 0 on success"
else
    FAIL=$((FAIL + 1))
    ERRORS="${ERRORS}FAIL: exit code on success\n"
    echo "  FAIL: exit code on success"
fi

# ── 25. Exit code non-zero on missing file ──
echo "--- 25. Exit code on missing file ---"
"$FPR" /nonexistent/file 2>/dev/null
rc=$?
if [ $rc -ne 0 ]; then
    PASS=$((PASS + 1))
    echo "  PASS: non-zero exit on missing file ($rc)"
else
    FAIL=$((FAIL + 1))
    ERRORS="${ERRORS}FAIL: exit code on missing file\n"
    echo "  FAIL: exit code 0 on missing file"
fi

# ── 26. Large input ──
echo "--- 26. Large input ---"
expected=$(seq 1 10000 | pr -t 2>/dev/null | wc -l)
actual=$(seq 1 10000 | "$FPR" -t 2>/dev/null | wc -l)
run_test "large input (10000 lines) count" "$expected" "$actual"

# ── 27. Multi-column with headers (no -t) ──
echo "--- 27. Multi-column with headers ---"
tmpfile=$(mktemp)
seq 1 100 > "$tmpfile"
expected_lines=$(pr -2 "$tmpfile" 2>/dev/null | wc -l)
actual_lines=$("$FPR" -2 "$tmpfile" 2>/dev/null | wc -l)
if [ "$expected_lines" = "$actual_lines" ]; then
    PASS=$((PASS + 1))
    echo "  PASS: multi-col header line count ($expected_lines)"
else
    FAIL=$((FAIL + 1))
    ERRORS="${ERRORS}FAIL: multi-col header line count (expected $expected_lines, got $actual_lines)\n"
    echo "  FAIL: multi-col header line count (expected $expected_lines, got $actual_lines)"
fi
rm -f "$tmpfile"

# ── 28. Across with headers ──
echo "--- 28. Across with separator and headers ---"
tmpfile=$(mktemp)
seq 1 20 > "$tmpfile"
expected_lines=$(pr -a -2 -s: "$tmpfile" 2>/dev/null | wc -l)
actual_lines=$("$FPR" -a -2 -s: "$tmpfile" 2>/dev/null | wc -l)
if [ "$expected_lines" = "$actual_lines" ]; then
    PASS=$((PASS + 1))
    echo "  PASS: across header line count ($expected_lines)"
else
    FAIL=$((FAIL + 1))
    ERRORS="${ERRORS}FAIL: across header line count (expected $expected_lines, got $actual_lines)\n"
    echo "  FAIL: across header line count (expected $expected_lines, got $actual_lines)"
fi
rm -f "$tmpfile"

# ── 29. Long lines truncation with -w ──
echo "--- 29. Long lines truncation ---"
expected=$(printf 'abcdefghijklmnopqrstuvwxyz\n' | pr -t -2 -w 20 2>/dev/null)
actual=$(printf 'abcdefghijklmnopqrstuvwxyz\n' | "$FPR" -t -2 -w 20 2>/dev/null)
run_test "long line truncation -w 20" "$expected" "$actual"

# ── 30. Form feed -f ──
echo "--- 30. Form feed -f ---"
tmpfile=$(mktemp)
seq 1 5 > "$tmpfile"
expected_ff=$(pr -f "$tmpfile" 2>/dev/null | od -An -tx1 | tr -d ' \n' | grep -c '0c' || true)
actual_ff=$("$FPR" -f "$tmpfile" 2>/dev/null | od -An -tx1 | tr -d ' \n' | grep -c '0c' || true)
if [ "$expected_ff" = "$actual_ff" ]; then
    PASS=$((PASS + 1))
    echo "  PASS: form feed count ($expected_ff)"
else
    FAIL=$((FAIL + 1))
    ERRORS="${ERRORS}FAIL: form feed (expected $expected_ff, got $actual_ff)\n"
    echo "  FAIL: form feed count (expected $expected_ff, got $actual_ff)"
fi
rm -f "$tmpfile"

# ── 31. Multi-column 4 columns ──
echo "--- 31. Four columns ---"
expected=$(seq 1 20 | pr -t -4 2>/dev/null)
actual=$(seq 1 20 | "$FPR" -t -4 2>/dev/null)
run_test "-t -4 four columns" "$expected" "$actual"

# ── 32. Across 4 columns ──
echo "--- 32. Across 4 columns ---"
expected=$(seq 1 20 | pr -t -a -4 2>/dev/null)
actual=$(seq 1 20 | "$FPR" -t -a -4 2>/dev/null)
run_test "-t -a -4 four columns across" "$expected" "$actual"

# ── 33. Multi-column with few lines (less than columns) ──
echo "--- 33. Fewer lines than columns ---"
expected=$(printf 'A\n' | pr -t -3 2>/dev/null)
actual=$(printf 'A\n' | "$FPR" -t -3 2>/dev/null)
run_test "-t -3 with 1 line" "$expected" "$actual"

# ── 34. Line numbering width -n:5 ──
echo "--- 34. Line numbering custom width ---"
expected=$(seq 1 5 | pr -t -n:3 2>/dev/null)
actual=$(seq 1 5 | "$FPR" -t -n:3 2>/dev/null)
run_test "-t -n:3 custom number width" "$expected" "$actual"

# ── 35. Multi-column with long content ──
echo "--- 35. Multi-column long content truncation ---"
expected=$(printf 'abcdefghij\nklmnopqrst\nuvwxyz1234\n56789abcde\n' | pr -t -2 -w 30 2>/dev/null)
actual=$(printf 'abcdefghij\nklmnopqrst\nuvwxyz1234\n56789abcde\n' | "$FPR" -t -2 -w 30 2>/dev/null)
run_test "-t -2 -w 30 content truncation" "$expected" "$actual"

# ── 36. First line number -N ──
echo "--- 36. First line number ---"
expected=$(printf 'a\nb\nc\n' | pr -t -n -N 10 2>/dev/null)
actual=$(printf 'a\nb\nc\n' | "$FPR" -t -n -N 10 2>/dev/null)
run_test "-t -n -N 10 first line number" "$expected" "$actual"

# ── 37. Multiple pages ──
echo "--- 37. Multiple pages ---"
tmpfile=$(mktemp)
seq 1 200 > "$tmpfile"
expected_lines=$(pr "$tmpfile" 2>/dev/null | wc -l)
actual_lines=$("$FPR" "$tmpfile" 2>/dev/null | wc -l)
if [ "$expected_lines" = "$actual_lines" ]; then
    PASS=$((PASS + 1))
    echo "  PASS: multiple pages line count ($expected_lines)"
else
    FAIL=$((FAIL + 1))
    ERRORS="${ERRORS}FAIL: multiple pages (expected $expected_lines, got $actual_lines)\n"
    echo "  FAIL: multiple pages line count (expected $expected_lines, got $actual_lines)"
fi
rm -f "$tmpfile"

# ── 38. Custom page length -l ──
echo "--- 38. Custom page length ---"
tmpfile=$(mktemp)
seq 1 20 > "$tmpfile"
expected_lines=$(pr -l 20 "$tmpfile" 2>/dev/null | wc -l)
actual_lines=$("$FPR" -l 20 "$tmpfile" 2>/dev/null | wc -l)
if [ "$expected_lines" = "$actual_lines" ]; then
    PASS=$((PASS + 1))
    echo "  PASS: custom page length -l 20 ($expected_lines)"
else
    FAIL=$((FAIL + 1))
    ERRORS="${ERRORS}FAIL: -l 20 (expected $expected_lines, got $actual_lines)\n"
    echo "  FAIL: custom page length -l 20 (expected $expected_lines, got $actual_lines)"
fi
rm -f "$tmpfile"

# ── 39. -r no error on missing file ──
echo "--- 39. -r suppress file errors ---"
err_output=$("$FPR" -r /nonexistent/file 2>&1)
rc=$?
if [ -z "$err_output" ]; then
    PASS=$((PASS + 1))
    echo "  PASS: -r suppresses error messages"
else
    FAIL=$((FAIL + 1))
    ERRORS="${ERRORS}FAIL: -r should suppress errors\n"
    echo "  FAIL: -r should suppress errors (got: $err_output)"
fi

# ── 40. Multi-column across with separator ──
echo "--- 40. Across with colon separator ---"
expected=$(seq 1 9 | pr -t -a -3 -s: 2>/dev/null)
actual=$(seq 1 9 | "$FPR" -t -a -3 -s: 2>/dev/null)
run_test "-t -a -3 -s: across separator" "$expected" "$actual"

# ── 41. -S string separator with multi-column ──
echo "--- 41. -S separator with truncation ---"
expected=$(printf 'abcdefghijklmnopqrstuvwxyz\nabcdefghijklmnopqrstuvwxyz\n' | pr -t -2 -S'|' -w 30 2>/dev/null)
actual=$(printf 'abcdefghijklmnopqrstuvwxyz\nabcdefghijklmnopqrstuvwxyz\n' | "$FPR" -t -2 -S'|' -w 30 2>/dev/null)
run_test "-t -2 -S'|' -w 30" "$expected" "$actual"

# ── 42. Large multi-column ──
echo "--- 42. Large multi-column ---"
expected=$(seq 1 1000 | pr -t -3 2>/dev/null | wc -l)
actual=$(seq 1 1000 | "$FPR" -t -3 2>/dev/null | wc -l)
run_test "large -t -3 (1000 lines) count" "$expected" "$actual"

# ── 43. Double space with headers ──
echo "--- 43. Double space with headers ---"
tmpfile=$(mktemp)
seq 1 10 > "$tmpfile"
expected_lines=$(pr -d "$tmpfile" 2>/dev/null | wc -l)
actual_lines=$("$FPR" -d "$tmpfile" 2>/dev/null | wc -l)
if [ "$expected_lines" = "$actual_lines" ]; then
    PASS=$((PASS + 1))
    echo "  PASS: -d with headers line count ($expected_lines)"
else
    FAIL=$((FAIL + 1))
    ERRORS="${ERRORS}FAIL: -d with headers (expected $expected_lines, got $actual_lines)\n"
    echo "  FAIL: -d with headers line count (expected $expected_lines, got $actual_lines)"
fi
rm -f "$tmpfile"

# ── 44. Byte-for-byte multi-column default ──
echo "--- 44. Byte-for-byte multi-column ---"
expected=$(seq 1 10 | pr -t -2 | od -An -tx1)
actual=$(seq 1 10 | "$FPR" -t -2 2>/dev/null | od -An -tx1)
run_test "-t -2 byte-for-byte" "$expected" "$actual"

# ── 45. Byte-for-byte across ──
echo "--- 45. Byte-for-byte across ---"
expected=$(seq 1 10 | pr -t -a -2 | od -An -tx1)
actual=$(seq 1 10 | "$FPR" -t -a -2 2>/dev/null | od -An -tx1)
run_test "-t -a -2 byte-for-byte" "$expected" "$actual"

# ── 46. Byte-for-byte separator ──
echo "--- 46. Byte-for-byte separator ---"
expected=$(seq 1 10 | pr -t -2 -s | od -An -tx1)
actual=$(seq 1 10 | "$FPR" -t -2 -s 2>/dev/null | od -An -tx1)
run_test "-t -2 -s byte-for-byte" "$expected" "$actual"

# ── 47. Byte-for-byte -S string ──
echo "--- 47. Byte-for-byte -S ---"
expected=$(seq 1 10 | pr -t -2 -S'||' | od -An -tx1)
actual=$(seq 1 10 | "$FPR" -t -2 -S'||' 2>/dev/null | od -An -tx1)
run_test "-t -2 -S'||' byte-for-byte" "$expected" "$actual"

# ── 48. Page width -W truncation ──
echo "--- 48. -W truncation ---"
expected=$(printf 'abcdefghijklmnopqrstuvwxyz\n' | pr -t -W 10 2>/dev/null)
actual=$(printf 'abcdefghijklmnopqrstuvwxyz\n' | "$FPR" -t -W 10 2>/dev/null)
run_test "-t -W 10 truncation" "$expected" "$actual"

# ── 49. Page number format in header ──
echo "--- 49. Header format ---"
tmpfile=$(mktemp)
seq 1 5 > "$tmpfile"
expected_page=$(pr "$tmpfile" 2>/dev/null | head -3 | tail -1 | grep -c 'Page 1' || true)
actual_page=$("$FPR" "$tmpfile" 2>/dev/null | head -3 | tail -1 | grep -c 'Page 1' || true)
if [ "$expected_page" = "$actual_page" ] && [ "$expected_page" = "1" ]; then
    PASS=$((PASS + 1))
    echo "  PASS: header contains 'Page 1'"
else
    FAIL=$((FAIL + 1))
    ERRORS="${ERRORS}FAIL: header format\n"
    echo "  FAIL: header format (expected Page 1)"
fi
rm -f "$tmpfile"

# ── 50. Stdin - flag ──
echo "--- 50. Stdin - flag ---"
expected=$(printf 'test\n' | pr -t - 2>/dev/null)
actual=$(printf 'test\n' | "$FPR" -t - 2>/dev/null)
run_test "-t - stdin flag" "$expected" "$actual"

# ── Summary ──
echo ""
echo "================================="
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
echo "================================="
if [ $FAIL -gt 0 ]; then
    echo ""
    echo "Failures:"
    printf "$ERRORS"
fi
exit $FAIL
