/// Prime factorization using trial division for small factors and
/// Pollard's rho algorithm with Miller-Rabin primality testing for larger factors.
/// Supports numbers up to u128.
///
/// Uses a u64 fast path for numbers ≤ u64::MAX (hardware div is ~5x faster
/// than the software __udivti3 needed for u128).

// Primes up to 251 (54 primes). Trial division by these covers all composites
// up to 251² = 63001. For the "factor 1-100000" benchmark, sqrt(100000) ≈ 316,
// so we only need primes up to 316. These 54 primes replace the naive loop that
// tested every odd number (6k±1 pattern = ~53% wasted composite divisors).
const SMALL_PRIMES_U64: [u64; 54] = [
    2, 3, 5, 7, 11, 13, 17, 19, 23, 29, 31, 37, 41, 43, 47, 53, 59, 61, 67, 71, 73, 79, 83, 89, 97,
    101, 103, 107, 109, 113, 127, 131, 137, 139, 149, 151, 157, 163, 167, 173, 179, 181, 191, 193,
    197, 199, 211, 223, 227, 229, 233, 239, 241, 251,
];

// Extended primes for u128 trial division (up to 997, covering sqrt up to ~994009).
const PRIMES_TO_997: [u64; 168] = [
    2, 3, 5, 7, 11, 13, 17, 19, 23, 29, 31, 37, 41, 43, 47, 53, 59, 61, 67, 71, 73, 79, 83, 89, 97,
    101, 103, 107, 109, 113, 127, 131, 137, 139, 149, 151, 157, 163, 167, 173, 179, 181, 191, 193,
    197, 199, 211, 223, 227, 229, 233, 239, 241, 251, 257, 263, 269, 271, 277, 281, 283, 293, 307,
    311, 313, 317, 331, 337, 347, 349, 353, 359, 367, 373, 379, 383, 389, 397, 401, 409, 419, 421,
    431, 433, 439, 443, 449, 457, 461, 463, 467, 479, 487, 491, 499, 503, 509, 521, 523, 541, 547,
    557, 563, 569, 571, 577, 587, 593, 599, 601, 607, 613, 617, 619, 631, 641, 643, 647, 653, 659,
    661, 673, 677, 683, 691, 701, 709, 719, 727, 733, 739, 743, 751, 757, 761, 769, 773, 787, 797,
    809, 811, 821, 823, 827, 829, 839, 853, 857, 859, 863, 877, 881, 883, 887, 907, 911, 919, 929,
    937, 941, 947, 953, 967, 971, 977, 983, 991, 997,
];

// ── u64 fast path ────────────────────────────────────────────────────────

/// Modular multiplication for u64 using u128 intermediate.
/// Hardware mul + div on u128 is still much faster than software u128×u128.
#[inline(always)]
fn mod_mul_u64(a: u64, b: u64, m: u64) -> u64 {
    ((a as u128) * (b as u128) % (m as u128)) as u64
}

/// Modular exponentiation for u64.
#[inline]
fn mod_pow_u64(mut base: u64, mut exp: u64, m: u64) -> u64 {
    if m == 1 {
        return 0;
    }
    let mut result: u64 = 1;
    base %= m;
    while exp > 0 {
        if exp & 1 == 1 {
            result = mod_mul_u64(result, base, m);
        }
        exp >>= 1;
        base = mod_mul_u64(base, base, m);
    }
    result
}

/// Deterministic Miller-Rabin for u64. Uses minimal witness set.
fn is_prime_u64(n: u64) -> bool {
    if n < 2 {
        return false;
    }
    if n < 4 {
        return true;
    }
    if n.is_multiple_of(2) || n.is_multiple_of(3) {
        return false;
    }
    // Quick check against small primes (5 through 47)
    for &p in &SMALL_PRIMES_U64[2..15] {
        if n == p {
            return true;
        }
        if n.is_multiple_of(p) {
            return false;
        }
    }
    if n < 2809 {
        return true; // All composites < 53² have a prime factor ≤ 47
    }

    let mut d = n - 1;
    let mut r = 0u32;
    while d.is_multiple_of(2) {
        d /= 2;
        r += 1;
    }

    // Witnesses sufficient for all n < 3,215,031,751: {2, 3, 5, 7}
    // For all n < 3,317,044,064,679,887,385,961,981: {2, 3, 5, 7, 11, 13, 17, 19, 23, 29, 31, 37}
    let witnesses: &[u64] = if n < 3_215_031_751 {
        &[2, 3, 5, 7]
    } else {
        &[2, 3, 5, 7, 11, 13, 17, 19, 23, 29, 31, 37]
    };

    'witness: for &a in witnesses {
        if a >= n {
            continue;
        }
        let mut x = mod_pow_u64(a, d, n);
        if x == 1 || x == n - 1 {
            continue;
        }
        for _ in 0..r - 1 {
            x = mod_mul_u64(x, x, n);
            if x == n - 1 {
                continue 'witness;
            }
        }
        return false;
    }
    true
}

/// GCD for u64 using binary algorithm.
fn gcd_u64(mut a: u64, mut b: u64) -> u64 {
    if a == 0 {
        return b;
    }
    if b == 0 {
        return a;
    }
    let shift = (a | b).trailing_zeros();
    a >>= a.trailing_zeros();
    loop {
        b >>= b.trailing_zeros();
        if a > b {
            std::mem::swap(&mut a, &mut b);
        }
        b -= a;
        if b == 0 {
            break;
        }
    }
    a << shift
}

/// Pollard's rho for u64 with Brent's variant + batch GCD.
fn pollard_rho_u64(n: u64) -> u64 {
    if n.is_multiple_of(2) {
        return 2;
    }

    for c_offset in 1u64..n {
        let c = c_offset;
        let mut x: u64 = c_offset.wrapping_mul(6364136223846793005).wrapping_add(1) % n;
        let mut y = x;
        let mut ys = x;
        let mut q: u64 = 1;
        let mut r: u64 = 1;
        let mut d: u64 = 1;

        while d == 1 {
            x = y;
            for _ in 0..r {
                y = (mod_mul_u64(y, y, n)).wrapping_add(c) % n;
            }
            let mut k: u64 = 0;
            while k < r && d == 1 {
                ys = y;
                let m = (r - k).min(128);
                for _ in 0..m {
                    y = (mod_mul_u64(y, y, n)).wrapping_add(c) % n;
                    q = mod_mul_u64(q, x.abs_diff(y), n);
                }
                d = gcd_u64(q, n);
                k += m;
            }
            r *= 2;
        }

        if d == n {
            loop {
                ys = (mod_mul_u64(ys, ys, n)).wrapping_add(c) % n;
                d = gcd_u64(x.abs_diff(ys), n);
                if d > 1 {
                    break;
                }
            }
        }

        if d != n {
            return d;
        }
    }
    n
}

/// Recursive factorization for u64.
fn factor_recursive_u64(n: u64, factors: &mut Vec<u128>) {
    if n <= 1 {
        return;
    }
    if is_prime_u64(n) {
        factors.push(n as u128);
        return;
    }
    let d = pollard_rho_u64(n);
    if d == n {
        // Brute force fallback
        let mut d = 2u64;
        while d * d <= n {
            if n.is_multiple_of(d) {
                factor_recursive_u64(d, factors);
                factor_recursive_u64(n / d, factors);
                return;
            }
            d += 1;
        }
        factors.push(n as u128);
        return;
    }
    factor_recursive_u64(d, factors);
    factor_recursive_u64(n / d, factors);
}

/// Fast factorization for u64 numbers. Uses hardware div throughout.
fn factorize_u64(n: u64) -> Vec<u128> {
    if n <= 1 {
        return vec![];
    }

    let mut factors = Vec::new();
    let mut n = n;

    // Special-case 2: bit shift is faster than hardware div
    while n & 1 == 0 {
        factors.push(2);
        n >>= 1;
    }

    // Trial division by odd primes 3..997 (covers sqrt up to ~994009)
    for &p in &PRIMES_TO_997[1..] {
        if p as u128 * p as u128 > n as u128 {
            break;
        }
        while n.is_multiple_of(p) {
            factors.push(p as u128);
            n /= p;
        }
    }

    if n > 1 {
        if n <= 994009 || is_prime_u64(n) {
            factors.push(n as u128);
        } else {
            factor_recursive_u64(n, &mut factors);
            factors.sort();
        }
    }

    factors
}

// ── u128 path (for numbers > u64::MAX) ───────────────────────────────────

/// Modular multiplication for u128 that avoids overflow.
fn mod_mul(mut a: u128, mut b: u128, m: u128) -> u128 {
    if a.leading_zeros() + b.leading_zeros() >= 128 {
        return (a * b) % m;
    }
    a %= m;
    b %= m;
    let mut result: u128 = 0;
    while b > 0 {
        if b & 1 == 1 {
            result = result.wrapping_add(a);
            if result >= m {
                result -= m;
            }
        }
        a <<= 1;
        if a >= m {
            a -= m;
        }
        b >>= 1;
    }
    result
}

/// Modular exponentiation for u128.
fn mod_pow(mut base: u128, mut exp: u128, m: u128) -> u128 {
    if m == 1 {
        return 0;
    }
    let mut result: u128 = 1;
    base %= m;
    while exp > 0 {
        if exp & 1 == 1 {
            result = mod_mul(result, base, m);
        }
        exp >>= 1;
        base = mod_mul(base, base, m);
    }
    result
}

/// Deterministic Miller-Rabin primality test for u128.
fn is_prime_miller_rabin(n: u128) -> bool {
    if n < 2 {
        return false;
    }
    if n <= u64::MAX as u128 {
        return is_prime_u64(n as u64);
    }
    if n.is_multiple_of(2) || n.is_multiple_of(3) {
        return false;
    }

    for &p in &PRIMES_TO_997[3..] {
        if n == p as u128 {
            return true;
        }
        if n.is_multiple_of(p as u128) {
            return false;
        }
    }

    let mut d = n - 1;
    let mut r = 0u32;
    while d.is_multiple_of(2) {
        d /= 2;
        r += 1;
    }

    let witnesses: &[u128] = &[2, 3, 5, 7, 11, 13, 17, 19, 23, 29, 31, 37];

    'witness: for &a in witnesses {
        if a >= n {
            continue;
        }
        let mut x = mod_pow(a, d, n);
        if x == 1 || x == n - 1 {
            continue;
        }
        for _ in 0..r - 1 {
            x = mod_mul(x, x, n);
            if x == n - 1 {
                continue 'witness;
            }
        }
        return false;
    }
    true
}

/// GCD for u128.
fn gcd(mut a: u128, mut b: u128) -> u128 {
    if a == 0 {
        return b;
    }
    if b == 0 {
        return a;
    }
    let shift = (a | b).trailing_zeros();
    a >>= a.trailing_zeros();
    loop {
        b >>= b.trailing_zeros();
        if a > b {
            std::mem::swap(&mut a, &mut b);
        }
        b -= a;
        if b == 0 {
            break;
        }
    }
    a << shift
}

/// Pollard's rho for u128.
fn pollard_rho(n: u128) -> u128 {
    if n.is_multiple_of(2) {
        return 2;
    }

    for c_offset in 1u128..n {
        let c = c_offset;
        let mut x: u128 = c_offset.wrapping_mul(6364136223846793005).wrapping_add(1) % n;
        let mut y = x;
        let mut ys = x;
        let mut q: u128 = 1;
        let mut r: u128 = 1;
        let mut d: u128 = 1;

        while d == 1 {
            x = y;
            for _ in 0..r {
                y = mod_mul(y, y, n).wrapping_add(c) % n;
            }
            let mut k: u128 = 0;
            while k < r && d == 1 {
                ys = y;
                let m = (r - k).min(128);
                for _ in 0..m {
                    y = mod_mul(y, y, n).wrapping_add(c) % n;
                    q = mod_mul(q, x.abs_diff(y), n);
                }
                d = gcd(q, n);
                k += m;
            }
            r *= 2;
        }

        if d == n {
            loop {
                ys = mod_mul(ys, ys, n).wrapping_add(c) % n;
                d = gcd(x.abs_diff(ys), n);
                if d > 1 {
                    break;
                }
            }
        }

        if d != n {
            return d;
        }
    }
    n
}

/// Recursively factor n (u128 path).
fn factor_recursive(n: u128, factors: &mut Vec<u128>) {
    if n <= 1 {
        return;
    }
    if n <= u64::MAX as u128 {
        factor_recursive_u64(n as u64, factors);
        return;
    }
    if is_prime_miller_rabin(n) {
        factors.push(n);
        return;
    }

    let mut d = pollard_rho(n);
    if d == n {
        d = 2;
        while d * d <= n {
            if n.is_multiple_of(d) {
                break;
            }
            d += 1;
        }
        if d * d > n {
            factors.push(n);
            return;
        }
    }
    factor_recursive(d, factors);
    factor_recursive(n / d, factors);
}

// ── Public API ───────────────────────────────────────────────────────────

/// Return the sorted list of prime factors of n (with repetition).
pub fn factorize(n: u128) -> Vec<u128> {
    if n <= u64::MAX as u128 {
        return factorize_u64(n as u64);
    }

    let mut factors = Vec::new();
    let mut n = n;

    // Trial division by precomputed primes
    for &p in &PRIMES_TO_997 {
        let p128 = p as u128;
        if p128 * p128 > n {
            break;
        }
        while n.is_multiple_of(p128) {
            factors.push(p128);
            n /= p128;
        }
    }

    if n > 1 {
        factor_recursive(n, &mut factors);
        factors.sort();
    }

    factors
}

/// Format a factorization result as "NUMBER: FACTOR FACTOR ..." matching GNU factor output.
/// Writes directly to a buffer to avoid per-number String allocation.
pub fn format_factors(n: u128) -> String {
    let factors = factorize(n);
    let mut result = String::with_capacity(64);
    if n <= u64::MAX as u128 {
        let mut buf = itoa::Buffer::new();
        result.push_str(buf.format(n as u64));
    } else {
        use std::fmt::Write;
        let _ = write!(result, "{}", n);
    }
    result.push(':');
    for f in &factors {
        result.push(' ');
        if *f <= u64::MAX as u128 {
            let mut buf = itoa::Buffer::new();
            result.push_str(buf.format(*f as u64));
        } else {
            use std::fmt::Write;
            let _ = write!(result, "{}", f);
        }
    }
    result
}

/// Write factorization of a u64 directly to a buffer.
/// Zero-allocation hot path for the common case (numbers up to 2^64-1).
pub fn write_factors_u64(n: u64, out: &mut Vec<u8>) {
    let mut buf = itoa::Buffer::new();
    out.extend_from_slice(buf.format(n).as_bytes());
    out.push(b':');
    if n <= 1 {
        out.push(b'\n');
        return;
    }
    write_factors_u64_inline(n, out);
    out.push(b'\n');
}

/// Write factorization of a u128 to a buffer.
/// Falls through to the u64 fast path when possible.
pub fn write_factors(n: u128, out: &mut Vec<u8>) {
    if n <= u64::MAX as u128 {
        write_factors_u64(n as u64, out);
        return;
    }
    let mut buf = itoa::Buffer::new();
    {
        use std::fmt::Write;
        let mut s = String::new();
        let _ = write!(s, "{}", n);
        out.extend_from_slice(s.as_bytes());
    }
    out.push(b':');

    let factors = factorize(n);
    for f in &factors {
        out.push(b' ');
        if *f <= u64::MAX as u128 {
            out.extend_from_slice(buf.format(*f as u64).as_bytes());
        } else {
            use std::fmt::Write;
            let mut s = String::new();
            let _ = write!(s, "{}", *f);
            out.extend_from_slice(s.as_bytes());
        }
    }
    out.push(b'\n');
}

/// Inline factoring + direct writing for u64 numbers.
/// Uses extended primes table (to 997) so numbers up to ~994009 are fully
/// factored by trial division alone, avoiding expensive Miller-Rabin/Pollard's rho.
fn write_factors_u64_inline(mut n: u64, out: &mut Vec<u8>) {
    let mut buf = itoa::Buffer::new();

    // Special-case 2: bit shift is ~5x faster than hardware div
    while n & 1 == 0 {
        out.extend_from_slice(b" 2");
        n >>= 1;
    }

    // Special-case 3: very common factor
    while n.is_multiple_of(3) {
        out.extend_from_slice(b" 3");
        n /= 3;
    }

    // Trial division by primes from 5 to 997. Skip 2 and 3 (already done).
    // The break condition p*p > n ensures we only test relevant primes.
    for &p in &PRIMES_TO_997[2..] {
        if p * p > n {
            break;
        }
        while n.is_multiple_of(p) {
            out.push(b' ');
            out.extend_from_slice(buf.format(p).as_bytes());
            n /= p;
        }
    }

    if n <= 1 {
        return;
    }

    // After trial division by primes to 997, if n ≤ 997² ≈ 994009 it must be prime.
    if n <= 994009 || is_prime_u64(n) {
        out.push(b' ');
        out.extend_from_slice(buf.format(n).as_bytes());
    } else {
        // n has multiple large factors (all > 997) needing Pollard's rho.
        let mut factors = Vec::new();
        factor_recursive_u64(n, &mut factors);
        factors.sort();
        for f in &factors {
            out.push(b' ');
            out.extend_from_slice(buf.format(*f as u64).as_bytes());
        }
    }
}
