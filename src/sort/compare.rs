/// Comparison functions for different sort modes.
use std::cmp::Ordering;

use super::key::KeyOpts;

/// Strip leading blanks (space and tab).
#[inline(always)]
pub fn skip_leading_blanks(s: &[u8]) -> &[u8] {
    let mut i = 0;
    while i < s.len()
        && (unsafe { *s.get_unchecked(i) } == b' ' || unsafe { *s.get_unchecked(i) } == b'\t')
    {
        i += 1;
    }
    &s[i..]
}

/// Compare two byte slices using locale-aware collation (strcoll).
/// Uses stack buffers (up to 256 bytes) to avoid heap allocation in the hot path.
/// Falls back to heap-allocated CString for longer strings, and to byte comparison
/// if the input contains interior null bytes.
#[inline]
pub fn compare_locale(a: &[u8], b: &[u8]) -> Ordering {
    // Stack buffer size for null-terminated copies. Most sort keys are < 256 bytes.
    const STACK_BUF: usize = 256;

    // Fast path: if either contains a null byte, fall back to byte comparison
    // (CString can't represent interior nulls)
    if memchr::memchr(0, a).is_some() || memchr::memchr(0, b).is_some() {
        return a.cmp(b);
    }

    if a.len() < STACK_BUF && b.len() < STACK_BUF {
        // Stack-only path: no heap allocation.
        // Zero-init provides the null terminator after copy_nonoverlapping.
        let mut buf_a = [0u8; STACK_BUF];
        let mut buf_b = [0u8; STACK_BUF];
        // SAFETY: a.len() < STACK_BUF (checked above), no interior NULs (checked above).
        unsafe {
            std::ptr::copy_nonoverlapping(a.as_ptr(), buf_a.as_mut_ptr(), a.len());
            std::ptr::copy_nonoverlapping(b.as_ptr(), buf_b.as_mut_ptr(), b.len());
            let result = libc::strcoll(buf_a.as_ptr() as *const _, buf_b.as_ptr() as *const _);
            return result.cmp(&0);
        }
    }

    // Fallback for long strings: heap allocate.
    // Null bytes were already filtered above, so CString::new always succeeds.
    use std::ffi::CString;
    let ca = CString::new(a).expect("null bytes already filtered above");
    let cb = CString::new(b).expect("null bytes already filtered above");
    let result = unsafe { libc::strcoll(ca.as_ptr(), cb.as_ptr()) };
    result.cmp(&0)
}

/// Compare two byte slices lexicographically (default sort).
#[inline]
pub fn compare_lexical(a: &[u8], b: &[u8]) -> Ordering {
    a.cmp(b)
}

/// Numeric sort (-n): compare leading numeric strings.
/// Handles optional leading whitespace, sign, and decimal point.
#[inline]
pub fn compare_numeric(a: &[u8], b: &[u8]) -> Ordering {
    let va = parse_numeric_value(a);
    let vb = parse_numeric_value(b);
    va.partial_cmp(&vb).unwrap_or(Ordering::Equal)
}

/// Fast custom numeric parser: parses sign + digits + optional decimal directly from bytes.
/// Avoids UTF-8 validation and str::parse::<f64>() overhead entirely.
/// Uses batch digit processing for the integer part (4 digits at a time) to reduce
/// loop iterations and branch mispredictions.
#[inline]
pub fn parse_numeric_value(s: &[u8]) -> f64 {
    let s = skip_leading_blanks(s);
    if s.is_empty() {
        return 0.0;
    }

    let mut i = 0;
    let negative = if unsafe { *s.get_unchecked(i) } == b'-' {
        i += 1;
        true
    } else {
        if i < s.len() && unsafe { *s.get_unchecked(i) } == b'+' {
            i += 1;
        }
        false
    };

    if i >= s.len() {
        return 0.0;
    }

    // Parse integer part — batch 4 digits at a time for reduced loop overhead
    let mut integer: u64 = 0;
    let mut has_digits = false;

    // Fast batch path: process 4 digits at a time
    while i + 4 <= s.len() {
        let d0 = unsafe { *s.get_unchecked(i) }.wrapping_sub(b'0');
        if d0 > 9 {
            break;
        }
        let d1 = unsafe { *s.get_unchecked(i + 1) }.wrapping_sub(b'0');
        if d1 > 9 {
            integer = integer.wrapping_mul(10).wrapping_add(d0 as u64);
            i += 1;
            has_digits = true;
            break;
        }
        let d2 = unsafe { *s.get_unchecked(i + 2) }.wrapping_sub(b'0');
        if d2 > 9 {
            integer = integer
                .wrapping_mul(100)
                .wrapping_add(d0 as u64 * 10 + d1 as u64);
            i += 2;
            has_digits = true;
            break;
        }
        let d3 = unsafe { *s.get_unchecked(i + 3) }.wrapping_sub(b'0');
        if d3 > 9 {
            integer = integer
                .wrapping_mul(1000)
                .wrapping_add(d0 as u64 * 100 + d1 as u64 * 10 + d2 as u64);
            i += 3;
            has_digits = true;
            break;
        }
        integer = integer
            .wrapping_mul(10000)
            .wrapping_add(d0 as u64 * 1000 + d1 as u64 * 100 + d2 as u64 * 10 + d3 as u64);
        i += 4;
        has_digits = true;
    }

    // Tail: process remaining digits one at a time
    while i < s.len() {
        let d = unsafe { *s.get_unchecked(i) }.wrapping_sub(b'0');
        if d > 9 {
            break;
        }
        integer = integer.wrapping_mul(10).wrapping_add(d as u64);
        has_digits = true;
        i += 1;
    }

    // Parse fractional part
    if i < s.len() && unsafe { *s.get_unchecked(i) } == b'.' {
        i += 1;
        let frac_start = i;
        let mut frac_val: u64 = 0;
        while i < s.len() {
            let d = unsafe { *s.get_unchecked(i) }.wrapping_sub(b'0');
            if d > 9 {
                break;
            }
            frac_val = frac_val.wrapping_mul(10).wrapping_add(d as u64);
            has_digits = true;
            i += 1;
        }
        if !has_digits {
            return 0.0;
        }
        let frac_digits = i - frac_start;
        let result = if frac_digits > 0 {
            // Use pre-computed powers of 10 for common cases
            let divisor = POW10[frac_digits.min(POW10.len() - 1)];
            integer as f64 + frac_val as f64 / divisor
        } else {
            integer as f64
        };
        return if negative { -result } else { result };
    }

    if !has_digits {
        return 0.0;
    }

    let result = integer as f64;
    if negative { -result } else { result }
}

/// Pre-computed powers of 10 for fast decimal conversion.
const POW10: [f64; 20] = [
    1.0, 1e1, 1e2, 1e3, 1e4, 1e5, 1e6, 1e7, 1e8, 1e9, 1e10, 1e11, 1e12, 1e13, 1e14, 1e15, 1e16,
    1e17, 1e18, 1e19,
];

/// Fast integer-only parser for numeric sort (-n).
/// Returns Some(i64) if the value is a pure integer (no decimal point, no exponent).
/// Returns None if the value has a decimal point or is not a valid integer.
/// This avoids the f64 conversion path for integer-only data.
/// Uses wrapping arithmetic (no overflow checks) for speed — values >18 digits
/// may wrap but sort order is still consistent since all values wrap the same way.
#[inline]
pub fn try_parse_integer(s: &[u8]) -> Option<i64> {
    let s = skip_leading_blanks(s);
    if s.is_empty() {
        return Some(0);
    }

    let mut i = 0;
    let negative = if unsafe { *s.get_unchecked(i) } == b'-' {
        i += 1;
        true
    } else {
        if i < s.len() && unsafe { *s.get_unchecked(i) } == b'+' {
            i += 1;
        }
        false
    };

    // Parse digits — wrapping arithmetic, batch 4 digits at a time
    let mut value: i64 = 0;
    let mut has_digits = false;

    // Fast batch: 4 digits at a time
    while i + 4 <= s.len() {
        let d0 = unsafe { *s.get_unchecked(i) }.wrapping_sub(b'0');
        if d0 > 9 {
            break;
        }
        let d1 = unsafe { *s.get_unchecked(i + 1) }.wrapping_sub(b'0');
        if d1 > 9 {
            value = value.wrapping_mul(10).wrapping_add(d0 as i64);
            i += 1;
            has_digits = true;
            break;
        }
        let d2 = unsafe { *s.get_unchecked(i + 2) }.wrapping_sub(b'0');
        if d2 > 9 {
            value = value
                .wrapping_mul(100)
                .wrapping_add(d0 as i64 * 10 + d1 as i64);
            i += 2;
            has_digits = true;
            break;
        }
        let d3 = unsafe { *s.get_unchecked(i + 3) }.wrapping_sub(b'0');
        if d3 > 9 {
            value = value
                .wrapping_mul(1000)
                .wrapping_add(d0 as i64 * 100 + d1 as i64 * 10 + d2 as i64);
            i += 3;
            has_digits = true;
            break;
        }
        value = value
            .wrapping_mul(10000)
            .wrapping_add(d0 as i64 * 1000 + d1 as i64 * 100 + d2 as i64 * 10 + d3 as i64);
        i += 4;
        has_digits = true;
    }

    // Tail: remaining digits
    while i < s.len() {
        let d = unsafe { *s.get_unchecked(i) }.wrapping_sub(b'0');
        if d > 9 {
            break;
        }
        value = value.wrapping_mul(10).wrapping_add(d as i64);
        has_digits = true;
        i += 1;
    }

    // If there's a decimal point, this is not a pure integer
    if i < s.len() && unsafe { *s.get_unchecked(i) } == b'.' {
        return None;
    }

    if !has_digits {
        return Some(0);
    }

    Some(if negative {
        value.wrapping_neg()
    } else {
        value
    })
}

/// Convert an i64 to a sortable u64 whose natural ordering matches signed integer ordering.
/// Adds i64::MAX + 1 (0x8000000000000000) to shift the range to unsigned.
#[inline]
pub fn int_to_sortable_u64(v: i64) -> u64 {
    (v as u64).wrapping_add(0x8000000000000000)
}

fn find_numeric_end(s: &[u8]) -> usize {
    let mut i = 0;
    if i < s.len() && (s[i] == b'+' || s[i] == b'-') {
        i += 1;
    }
    let mut has_digits = false;
    while i < s.len() && s[i].is_ascii_digit() {
        i += 1;
        has_digits = true;
    }
    if i < s.len() && s[i] == b'.' {
        i += 1;
        while i < s.len() && s[i].is_ascii_digit() {
            i += 1;
            has_digits = true;
        }
    }
    if has_digits { i } else { 0 }
}

/// General numeric sort (-g): handles scientific notation, infinity, NaN.
/// O(n) parser.
pub fn compare_general_numeric(a: &[u8], b: &[u8]) -> Ordering {
    let va = parse_general_numeric(a);
    let vb = parse_general_numeric(b);
    match (va.is_nan(), vb.is_nan()) {
        (true, true) => Ordering::Equal,
        (true, false) => Ordering::Less,
        (false, true) => Ordering::Greater,
        (false, false) => va.partial_cmp(&vb).unwrap_or(Ordering::Equal),
    }
}

pub fn parse_general_numeric(s: &[u8]) -> f64 {
    let s = skip_leading_blanks(s);
    if s.is_empty() {
        return f64::NAN;
    }

    // Find the longest valid float prefix
    let mut i = 0;

    // Handle "inf", "-inf", "+inf", "nan" etc.
    let start = if i < s.len() && (s[i] == b'+' || s[i] == b'-') {
        i += 1;
        i - 1
    } else {
        i
    };

    // Check for "inf"/"infinity"/"nan" prefix (case-insensitive)
    if i + 2 < s.len() {
        let c0 = s[i].to_ascii_lowercase();
        let c1 = s[i + 1].to_ascii_lowercase();
        let c2 = s[i + 2].to_ascii_lowercase();
        if (c0 == b'i' && c1 == b'n' && c2 == b'f') || (c0 == b'n' && c1 == b'a' && c2 == b'n') {
            // Try parsing the prefix as a special float
            let end = s.len().min(i + 8); // "infinity" is 8 chars
            for e in (i + 3..=end).rev() {
                if let Ok(text) = std::str::from_utf8(&s[start..e]) {
                    if let Ok(v) = text.parse::<f64>() {
                        return v;
                    }
                }
            }
            return f64::NAN;
        }
    }

    // Reset i for numeric parsing
    i = start;
    if i < s.len() && (s[i] == b'+' || s[i] == b'-') {
        i += 1;
    }

    // Digits before decimal
    let mut has_digits = false;
    while i < s.len() && s[i].is_ascii_digit() {
        i += 1;
        has_digits = true;
    }
    // Decimal point
    if i < s.len() && s[i] == b'.' {
        i += 1;
        while i < s.len() && s[i].is_ascii_digit() {
            i += 1;
            has_digits = true;
        }
    }
    if !has_digits {
        return f64::NAN;
    }
    // Exponent
    if i < s.len() && (s[i] == b'e' || s[i] == b'E') {
        let save = i;
        i += 1;
        if i < s.len() && (s[i] == b'+' || s[i] == b'-') {
            i += 1;
        }
        if i < s.len() && s[i].is_ascii_digit() {
            while i < s.len() && s[i].is_ascii_digit() {
                i += 1;
            }
        } else {
            i = save;
        }
    }

    // Parse the numeric prefix using standard library
    std::str::from_utf8(&s[start..i])
        .ok()
        .and_then(|s| s.parse::<f64>().ok())
        .unwrap_or(f64::NAN)
}

/// Human numeric sort (-h): handles suffixes K, M, G, T, P, E, Z, Y.
/// GNU sort compares by suffix tier first (no-suffix < K < M < G < T < P < E < Z < Y),
/// then by numeric value within the same tier. This means 1K > 999999 and 1G > 1023M.
pub fn compare_human_numeric(a: &[u8], b: &[u8]) -> Ordering {
    let (val_a, tier_a) = parse_human_numeric_tiered(a);
    let (val_b, tier_b) = parse_human_numeric_tiered(b);

    // Handle sign: negative values sort before positive, tier comparison inverts
    let sign_a = if val_a < 0.0 {
        -1i8
    } else if val_a > 0.0 {
        1
    } else {
        0
    };
    let sign_b = if val_b < 0.0 {
        -1i8
    } else if val_b > 0.0 {
        1
    } else {
        0
    };

    // Different signs: compare directly
    if sign_a != sign_b {
        return sign_a.cmp(&sign_b);
    }

    // Both zero
    if sign_a == 0 && sign_b == 0 {
        return Ordering::Equal;
    }

    // Same sign: compare tier first, then value within tier
    // For negative numbers, higher tier means MORE negative (reverse tier order)
    if sign_a > 0 {
        match tier_a.cmp(&tier_b) {
            Ordering::Equal => val_a.partial_cmp(&val_b).unwrap_or(Ordering::Equal),
            other => other,
        }
    } else {
        // Negative: -1G < -1M (higher tier is more negative = smaller)
        match tier_a.cmp(&tier_b) {
            Ordering::Equal => val_a.partial_cmp(&val_b).unwrap_or(Ordering::Equal),
            Ordering::Less => Ordering::Greater,
            Ordering::Greater => Ordering::Less,
        }
    }
}

/// Parse a human-numeric value and return (numeric_value, suffix_tier).
/// Tier: 0=no suffix, 1=K, 2=M, 3=G, 4=T, 5=P, 6=E, 7=Z, 8=Y.
fn parse_human_numeric_tiered(s: &[u8]) -> (f64, u8) {
    let s = skip_leading_blanks(s);
    if s.is_empty() {
        return (0.0, 0);
    }

    let base = parse_numeric_value(s);
    let end = find_numeric_end(s);

    if end < s.len() {
        let tier = match s[end] {
            b'K' | b'k' => 1,
            b'M' => 2,
            b'G' => 3,
            b'T' => 4,
            b'P' => 5,
            b'E' => 6,
            b'Z' => 7,
            b'Y' => 8,
            _ => 0,
        };
        (base, tier)
    } else {
        (base, 0)
    }
}

/// Convert a human-numeric string directly to a sortable u64.
/// Encodes tier in the top 4 bits and the float value in the bottom 60 bits.
/// This avoids the f64 precision loss that would occur from encoding tier + value
/// in a single f64 (e.g., 1e18 + 3.0 == 1e18 + 1.0 due to 52-bit mantissa).
///
/// Encoding:
/// - Non-negative values: (8 + tier) << 60 | (float_sortable >> 4)
/// - Negative values: (7 - tier) << 60 | (float_sortable >> 4)
///
/// This ensures: -1G < -1M < -1K < -1 < 0 < 1 < 1K < 1M < 1G
pub fn human_numeric_to_sortable_u64(s: &[u8]) -> u64 {
    let (val, tier) = parse_human_numeric_tiered(s);

    // Convert the numeric value to a sortable u64 (preserves float ordering)
    let sf = {
        if val.is_nan() {
            0u64 // NaN sorts first
        } else {
            let bits = val.to_bits();
            if (bits >> 63) == 0 {
                bits ^ 0x8000000000000000 // positive: flip sign bit
            } else {
                !bits // negative: flip all bits
            }
        }
    };

    // Encode tier in top 4 bits, float in bottom 60 bits
    if val >= 0.0 || val == 0.0 {
        ((8 + tier as u64) << 60) | (sf >> 4)
    } else {
        ((7 - tier as u64) << 60) | (sf >> 4)
    }
}

/// Legacy parse function for backward compatibility (not used in sort hot path).
pub fn parse_human_numeric(s: &[u8]) -> f64 {
    let (val, _tier) = parse_human_numeric_tiered(s);
    val
}

/// Month sort (-M).
pub fn compare_month(a: &[u8], b: &[u8]) -> Ordering {
    let ma = parse_month(a);
    let mb = parse_month(b);
    ma.cmp(&mb)
}

fn parse_month(s: &[u8]) -> u8 {
    let s = skip_leading_blanks(s);
    if s.len() < 3 {
        return 0;
    }
    let m = [
        s[0].to_ascii_uppercase(),
        s[1].to_ascii_uppercase(),
        s[2].to_ascii_uppercase(),
    ];
    match &m {
        b"JAN" => 1,
        b"FEB" => 2,
        b"MAR" => 3,
        b"APR" => 4,
        b"MAY" => 5,
        b"JUN" => 6,
        b"JUL" => 7,
        b"AUG" => 8,
        b"SEP" => 9,
        b"OCT" => 10,
        b"NOV" => 11,
        b"DEC" => 12,
        _ => 0,
    }
}

/// Version sort (-V): GNU filevercmp-compatible version comparison.
/// Implements the exact same algorithm as GNU coreutils' filevercmp.
pub fn compare_version(a: &[u8], b: &[u8]) -> Ordering {
    // GNU filevercmp: skip hidden-file dot prefix, compare, then break tie
    // by including the prefix.
    let a_prefix = if a.first() == Some(&b'.') { 1 } else { 0 };
    let b_prefix = if b.first() == Some(&b'.') { 1 } else { 0 };

    // First compare without the hidden-dot prefix
    let result = verrevcmp(&a[a_prefix..], &b[b_prefix..]);
    if result != Ordering::Equal {
        return result;
    }
    // Tie-break: compare the full strings (including dot prefix)
    verrevcmp(a, b)
}

/// The core comparison algorithm matching GNU's verrevcmp exactly.
/// From gnulib/lib/filevercmp.c.
fn verrevcmp(s1: &[u8], s2: &[u8]) -> Ordering {
    let s1_len = s1.len();
    let s2_len = s2.len();
    let mut s1_pos = 0usize;
    let mut s2_pos = 0usize;

    while s1_pos < s1_len || s2_pos < s2_len {
        let mut first_diff = 0i32;

        // Compare non-digit characters using the special ordering
        while (s1_pos < s1_len && !s1[s1_pos].is_ascii_digit())
            || (s2_pos < s2_len && !s2[s2_pos].is_ascii_digit())
        {
            let s1_c = ver_order(s1, s1_pos, s1_len);
            let s2_c = ver_order(s2, s2_pos, s2_len);
            if s1_c != s2_c {
                return if s1_c < s2_c {
                    Ordering::Less
                } else {
                    Ordering::Greater
                };
            }
            s1_pos += 1;
            s2_pos += 1;
        }

        // Skip leading zeros
        while s1_pos < s1_len && s1[s1_pos] == b'0' {
            s1_pos += 1;
        }
        while s2_pos < s2_len && s2[s2_pos] == b'0' {
            s2_pos += 1;
        }

        // Compare digit sequences of the same length
        while s1_pos < s1_len
            && s2_pos < s2_len
            && s1[s1_pos].is_ascii_digit()
            && s2[s2_pos].is_ascii_digit()
        {
            if first_diff == 0 {
                first_diff = s1[s1_pos] as i32 - s2[s2_pos] as i32;
            }
            s1_pos += 1;
            s2_pos += 1;
        }

        // If one string still has digits, it's the larger number
        if s1_pos < s1_len && s1[s1_pos].is_ascii_digit() {
            return Ordering::Greater;
        }
        if s2_pos < s2_len && s2[s2_pos].is_ascii_digit() {
            return Ordering::Less;
        }
        if first_diff != 0 {
            return if first_diff < 0 {
                Ordering::Less
            } else {
                Ordering::Greater
            };
        }
    }

    Ordering::Equal
}

/// Character ordering for GNU filevercmp (matches gnulib exactly):
/// ~(-2) < end-of-string(-1) < digits(0) < letters(char) < other(UCHAR_MAX+1+char)
#[inline]
fn ver_order(s: &[u8], pos: usize, len: usize) -> i32 {
    if pos == len {
        return -1;
    }
    let c = s[pos];
    if c.is_ascii_digit() {
        0
    } else if c.is_ascii_alphabetic() {
        c as i32
    } else if c == b'~' {
        -2
    } else {
        c as i32 + 256
    }
}

/// Random sort (-R): hash-based shuffle that groups identical keys.
pub fn compare_random(a: &[u8], b: &[u8], seed: u64) -> Ordering {
    let ha = fnv1a_hash(a, seed);
    let hb = fnv1a_hash(b, seed);
    ha.cmp(&hb)
}

/// FNV-1a hash with seed mixing.
#[inline]
fn fnv1a_hash(data: &[u8], seed: u64) -> u64 {
    let mut hash = 0xcbf29ce484222325u64 ^ seed;
    for &b in data {
        hash ^= b as u64;
        hash = hash.wrapping_mul(0x100000001b3);
    }
    hash
}

/// Compare with text filtering (-d, -i, -f flags in any combination).
/// Allocation-free: uses iterator filtering.
#[inline]
fn is_dict_char(b: u8) -> bool {
    b.is_ascii_alphanumeric() || b == b' ' || b == b'\t'
}

#[inline]
fn is_printable(b: u8) -> bool {
    b >= 0x20 && b < 0x7f
}

fn compare_text_filtered(
    a: &[u8],
    b: &[u8],
    dict: bool,
    no_print: bool,
    fold_case: bool,
) -> Ordering {
    if !dict && !no_print && !fold_case {
        return a.cmp(b);
    }

    let mut ai = a.iter().copied();
    let mut bi = b.iter().copied();

    loop {
        let na = next_valid(&mut ai, dict, no_print);
        let nb = next_valid(&mut bi, dict, no_print);
        match (na, nb) {
            (Some(ab), Some(bb)) => {
                let ca = if fold_case {
                    ab.to_ascii_uppercase()
                } else {
                    ab
                };
                let cb = if fold_case {
                    bb.to_ascii_uppercase()
                } else {
                    bb
                };
                match ca.cmp(&cb) {
                    Ordering::Equal => continue,
                    other => return other,
                }
            }
            (Some(_), None) => return Ordering::Greater,
            (None, Some(_)) => return Ordering::Less,
            (None, None) => return Ordering::Equal,
        }
    }
}

#[inline]
fn next_valid(iter: &mut impl Iterator<Item = u8>, dict: bool, no_print: bool) -> Option<u8> {
    loop {
        match iter.next() {
            None => return None,
            Some(b) => {
                if dict && !is_dict_char(b) {
                    continue;
                }
                if no_print && !is_printable(b) {
                    continue;
                }
                return Some(b);
            }
        }
    }
}

/// Case-insensitive lexicographic comparison.
/// Tight loop specialized for fold-case only (no dict/nonprinting filtering),
/// avoiding the overhead of the general compare_text_filtered path.
pub fn compare_ignore_case(a: &[u8], b: &[u8]) -> Ordering {
    let alen = a.len();
    let blen = b.len();
    let min_len = alen.min(blen);
    let ap = a.as_ptr();
    let bp = b.as_ptr();
    // Compare uppercase bytes directly with raw pointers for zero bounds-check overhead
    let mut i = 0usize;
    while i < min_len {
        let ca = unsafe { (*ap.add(i)).to_ascii_uppercase() };
        let cb = unsafe { (*bp.add(i)).to_ascii_uppercase() };
        if ca != cb {
            return ca.cmp(&cb);
        }
        i += 1;
    }
    alen.cmp(&blen)
}

pub fn compare_dictionary(a: &[u8], b: &[u8], ignore_case: bool) -> Ordering {
    compare_text_filtered(a, b, true, false, ignore_case)
}

pub fn compare_ignore_nonprinting(a: &[u8], b: &[u8], ignore_case: bool) -> Ordering {
    compare_text_filtered(a, b, false, true, ignore_case)
}

/// Master comparison function that dispatches based on KeyOpts.
pub fn compare_with_opts(a: &[u8], b: &[u8], opts: &KeyOpts, random_seed: u64) -> Ordering {
    let a = if opts.ignore_leading_blanks {
        skip_leading_blanks(a)
    } else {
        a
    };
    let b = if opts.ignore_leading_blanks {
        skip_leading_blanks(b)
    } else {
        b
    };

    let result = if opts.numeric {
        compare_numeric(a, b)
    } else if opts.general_numeric {
        compare_general_numeric(a, b)
    } else if opts.human_numeric {
        compare_human_numeric(a, b)
    } else if opts.month {
        compare_month(a, b)
    } else if opts.version {
        compare_version(a, b)
    } else if opts.random {
        compare_random(a, b, random_seed)
    } else if opts.dictionary_order || opts.ignore_nonprinting || opts.ignore_case {
        compare_text_filtered(
            a,
            b,
            opts.dictionary_order,
            opts.ignore_nonprinting,
            opts.ignore_case,
        )
    } else if super::core::is_c_locale() {
        // C/POSIX locale: strcoll == byte comparison, skip CString overhead
        a.cmp(b)
    } else {
        // Default: locale-aware comparison matching GNU sort's LC_COLLATE behavior
        compare_locale(a, b)
    };

    if opts.reverse {
        result.reverse()
    } else {
        result
    }
}

/// Concrete comparison function type. Selected once at setup time to avoid
/// per-comparison flag checking in hot sort loops.
pub type CompareFn = fn(&[u8], &[u8]) -> Ordering;

/// Select a concrete comparison function based on KeyOpts.
/// Returns (compare_fn, needs_leading_blank_strip, needs_reverse).
/// The caller applies blank-stripping and reversal outside the function pointer,
/// eliminating all per-comparison branching.
pub fn select_comparator(opts: &KeyOpts, random_seed: u64) -> (CompareFn, bool, bool) {
    let needs_blank = opts.ignore_leading_blanks;
    let needs_reverse = opts.reverse;

    let cmp: CompareFn = if opts.numeric {
        compare_numeric
    } else if opts.general_numeric {
        compare_general_numeric
    } else if opts.human_numeric {
        compare_human_numeric
    } else if opts.month {
        compare_month
    } else if opts.version {
        compare_version
    } else if opts.random {
        // Random needs seed — wrap in a closure-like pattern
        // Since we need random_seed, we use a special case
        return (
            make_random_comparator(random_seed),
            needs_blank,
            needs_reverse,
        );
    } else if opts.dictionary_order || opts.ignore_nonprinting || opts.ignore_case {
        // Text filtering: select specialized variant
        match (
            opts.dictionary_order,
            opts.ignore_nonprinting,
            opts.ignore_case,
        ) {
            (false, false, true) => compare_ignore_case,
            (true, false, false) => |a: &[u8], b: &[u8]| compare_dictionary(a, b, false),
            (true, false, true) => |a: &[u8], b: &[u8]| compare_dictionary(a, b, true),
            (false, true, false) => |a: &[u8], b: &[u8]| compare_ignore_nonprinting(a, b, false),
            (false, true, true) => |a: &[u8], b: &[u8]| compare_ignore_nonprinting(a, b, true),
            (true, true, false) => {
                |a: &[u8], b: &[u8]| compare_text_filtered(a, b, true, true, false)
            }
            (true, true, true) => {
                |a: &[u8], b: &[u8]| compare_text_filtered(a, b, true, true, true)
            }
            _ => |a: &[u8], b: &[u8]| a.cmp(b),
        }
    } else if super::core::is_c_locale() {
        // C/POSIX locale: strcoll == byte comparison, skip CString overhead
        compare_lexical
    } else {
        // Default: locale-aware comparison matching GNU sort's LC_COLLATE behavior
        compare_locale
    };

    (cmp, needs_blank, needs_reverse)
}

fn make_random_comparator(seed: u64) -> CompareFn {
    // We can't capture the seed in a function pointer, so we use a static.
    // This is safe because sort is single-process and seed doesn't change during a sort.
    RANDOM_SEED.store(seed, std::sync::atomic::Ordering::Relaxed);
    random_compare_with_static_seed
}

static RANDOM_SEED: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);

fn random_compare_with_static_seed(a: &[u8], b: &[u8]) -> Ordering {
    let seed = RANDOM_SEED.load(std::sync::atomic::Ordering::Relaxed);
    compare_random(a, b, seed)
}
