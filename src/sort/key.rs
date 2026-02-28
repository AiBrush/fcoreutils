/// Key definition parsing and field extraction for `sort -k`.
///
/// KEYDEF format: FIELD[.CHAR][OPTS],[FIELD[.CHAR][OPTS]]
/// Fields and characters are 1-indexed.

/// Per-key ordering options that can override global options.
#[derive(Debug, Clone, Default)]
pub struct KeyOpts {
    pub numeric: bool,
    pub general_numeric: bool,
    pub human_numeric: bool,
    pub month: bool,
    pub version: bool,
    pub random: bool,
    pub reverse: bool,
    pub ignore_leading_blanks: bool,
    pub dictionary_order: bool,
    pub ignore_case: bool,
    pub ignore_nonprinting: bool,
}

impl KeyOpts {
    /// Returns true if any sort-type option is set.
    pub fn has_sort_type(&self) -> bool {
        self.numeric
            || self.general_numeric
            || self.human_numeric
            || self.month
            || self.version
            || self.random
    }

    /// Returns true if any option at all is set (for key inheritance logic).
    pub fn has_any_option(&self) -> bool {
        self.has_sort_type()
            || self.ignore_case
            || self.dictionary_order
            || self.ignore_nonprinting
            || self.ignore_leading_blanks
            || self.reverse
    }

    /// Parse single-letter option flags from a string.
    pub fn parse_flags(&mut self, flags: &str) {
        for c in flags.chars() {
            match c {
                'b' => self.ignore_leading_blanks = true,
                'd' => self.dictionary_order = true,
                'f' => self.ignore_case = true,
                'g' => self.general_numeric = true,
                'h' => self.human_numeric = true,
                'i' => self.ignore_nonprinting = true,
                'M' => self.month = true,
                'n' => self.numeric = true,
                'R' => self.random = true,
                'r' => self.reverse = true,
                'V' => self.version = true,
                _ => {}
            }
        }
    }

    /// Validate that the set of options is compatible (GNU sort rules).
    /// Returns Err with a descriptive message if incompatible options are detected.
    ///
    /// GNU incompatibility rules:
    /// - At most one of {n, g, h, M} can be set (numeric sort types)
    /// - R is incompatible with {n, g, h, M}
    /// - V is incompatible with {n, g, h, M}
    /// - d is incompatible with {n, g, h, M}
    /// - i is incompatible with {n, g, h, M}
    ///
    /// GNU canonical order for error messages: d, g, h, i, M, n, R, V
    pub fn validate(&self) -> Result<(), String> {
        // Collect all active options in GNU canonical order: d, g, h, i, M, n, R, V
        // We only need to check options that participate in incompatibility.
        let mut active: Vec<char> = Vec::new();
        if self.dictionary_order {
            active.push('d');
        }
        if self.general_numeric {
            active.push('g');
        }
        if self.human_numeric {
            active.push('h');
        }
        if self.ignore_nonprinting {
            active.push('i');
        }
        if self.month {
            active.push('M');
        }
        if self.numeric {
            active.push('n');
        }
        if self.random {
            active.push('R');
        }
        if self.version {
            active.push('V');
        }

        // Define the incompatible pairs (canonical order: lower index in active list first)
        // Numeric-like types: g, h, M, n — at most one allowed
        // R, V each incompatible with g, h, M, n
        // d, i each incompatible with g, h, M, n
        let is_numeric_type = |c: char| matches!(c, 'g' | 'h' | 'M' | 'n');
        let incompatible_with_numeric = |c: char| matches!(c, 'd' | 'i' | 'R' | 'V');

        // Check all pairs in canonical order
        for i in 0..active.len() {
            for j in (i + 1)..active.len() {
                let a = active[i];
                let b = active[j];
                let conflict = (is_numeric_type(a) && is_numeric_type(b))
                    || (is_numeric_type(a) && incompatible_with_numeric(b))
                    || (incompatible_with_numeric(a) && is_numeric_type(b));
                if conflict {
                    return Err(format!("options '-{}{}' are incompatible", a, b));
                }
            }
        }

        Ok(())
    }
}

/// A parsed key specification from `-k START[,END]`.
#[derive(Debug, Clone)]
pub struct KeyDef {
    pub start_field: usize,
    pub start_char: usize,
    pub end_field: usize,
    pub end_char: usize,
    pub opts: KeyOpts,
}

impl KeyDef {
    /// Parse a KEYDEF string like "2,2n" or "1.3,1.5" or "3,3rn".
    pub fn parse(spec: &str) -> Result<KeyDef, String> {
        let parts: Vec<&str> = spec.splitn(2, ',').collect();

        let (start_field, start_char, start_opts) = parse_field_spec(parts[0])?;

        let (end_field, end_char, end_opts) = if parts.len() > 1 {
            parse_field_spec(parts[1])?
        } else {
            (0, 0, String::new())
        };

        let mut opts = KeyOpts::default();
        opts.parse_flags(&start_opts);
        opts.parse_flags(&end_opts);

        if start_field == 0 {
            return Err("field number is zero: invalid field specification".to_string());
        }

        // GNU sort rejects character offset 0 in the START position only.
        // A 0 in the end position is valid (treated as end of field).
        if start_char == 0 && parts[0].contains('.') {
            return Err(format!(
                "character offset is zero: invalid field specification '{}'",
                spec
            ));
        }

        // Validate per-key option compatibility
        opts.validate()?;

        Ok(KeyDef {
            start_field,
            start_char,
            end_field,
            end_char,
            opts,
        })
    }
}

/// Parse a single field spec like "2" or "1.3" or "2n" or "1.3bf".
fn parse_field_spec(s: &str) -> Result<(usize, usize, String), String> {
    let mut field_str = String::new();
    let mut char_str = String::new();
    let mut opts = String::new();
    let mut in_char = false;

    for c in s.chars() {
        if c == '.' && !in_char && opts.is_empty() {
            in_char = true;
        } else if c.is_ascii_digit() && opts.is_empty() {
            if in_char {
                char_str.push(c);
            } else {
                field_str.push(c);
            }
        } else if c.is_ascii_alphabetic() {
            opts.push(c);
        } else {
            return Err(format!("invalid character '{}' in key spec", c));
        }
    }

    let field = if field_str.is_empty() {
        0
    } else {
        field_str
            .parse::<usize>()
            .map_err(|_| "invalid field number".to_string())?
    };

    let char_pos = if char_str.is_empty() {
        0
    } else {
        char_str
            .parse::<usize>()
            .map_err(|_| "invalid character position".to_string())?
    };

    Ok((field, char_pos, opts))
}

/// Find the byte range of the Nth field (0-indexed) in a line.
/// Returns (start, end) byte offsets. Allocation-free.
/// Uses SIMD memchr for separator-based field finding.
/// Optimized: for small N with a separator, uses successive memchr calls
/// instead of memchr_iter to avoid iterator setup overhead.
#[inline]
fn find_nth_field(line: &[u8], n: usize, separator: Option<u8>) -> (usize, usize) {
    match separator {
        Some(sep) => {
            // For small field indices (N < 4), use successive memchr calls.
            // Each memchr call is SIMD-accelerated and avoids the iterator overhead.
            // For larger N, use memchr_iter which amortizes setup over many hits.
            if n < 4 {
                find_nth_field_memchr(line, n, sep)
            } else {
                find_nth_field_iter(line, n, sep)
            }
        }
        None => {
            let mut field = 0;
            let mut i = 0;
            let len = line.len();

            while i < len {
                let field_start = i;
                // Skip blanks (part of this field)
                while i < len && is_blank(line[i]) {
                    i += 1;
                }
                // Consume non-blanks
                while i < len && !is_blank(line[i]) {
                    i += 1;
                }
                if field == n {
                    return (field_start, i);
                }
                field += 1;
            }

            (line.len(), line.len())
        }
    }
}

/// Find the Nth field using successive memchr calls (optimal for small N).
/// Each memchr is a single SIMD scan that stops at the first separator.
#[inline(always)]
fn find_nth_field_memchr(line: &[u8], n: usize, sep: u8) -> (usize, usize) {
    let mut start = 0;
    // Skip past N separators to reach the start of field N
    for _ in 0..n {
        match memchr::memchr(sep, &line[start..]) {
            Some(pos) => start = start + pos + 1,
            None => return (line.len(), line.len()),
        }
    }
    // Find the end of field N (next separator or end of line)
    match memchr::memchr(sep, &line[start..]) {
        Some(pos) => (start, start + pos),
        None => (start, line.len()),
    }
}

/// Find the Nth field using memchr_iter (optimal for large N).
#[inline]
fn find_nth_field_iter(line: &[u8], n: usize, sep: u8) -> (usize, usize) {
    let mut field = 0;
    let mut start = 0;
    for pos in memchr::memchr_iter(sep, line) {
        if field == n {
            return (start, pos);
        }
        field += 1;
        start = pos + 1;
    }
    if field == n {
        (start, line.len())
    } else {
        (line.len(), line.len())
    }
}

#[inline]
fn is_blank(b: u8) -> bool {
    b == b' ' || b == b'\t'
}

/// In -z (zero-terminated) mode, newlines are treated as blanks for field splitting.
#[inline]
fn is_blank_z(b: u8) -> bool {
    b == b' ' || b == b'\t' || b == b'\n'
}

/// Skip leading blanks with a custom blank predicate.
#[inline]
fn skip_blanks_from_fn(line: &[u8], from: usize, end: usize, blank_fn: fn(u8) -> bool) -> usize {
    let mut i = from;
    while i < end && blank_fn(line[i]) {
        i += 1;
    }
    i
}

/// Find the Nth field with zero-terminated mode support.
#[inline]
fn find_nth_field_z(
    line: &[u8],
    n: usize,
    separator: Option<u8>,
    zero_terminated: bool,
) -> (usize, usize) {
    if !zero_terminated || separator.is_some() {
        return find_nth_field(line, n, separator);
    }
    // In -z mode without explicit separator, use is_blank_z (includes \n)
    let mut field = 0;
    let mut i = 0;
    let len = line.len();

    while i < len {
        let field_start = i;
        while i < len && is_blank_z(line[i]) {
            i += 1;
        }
        while i < len && !is_blank_z(line[i]) {
            i += 1;
        }
        if field == n {
            return (field_start, i);
        }
        field += 1;
    }
    (line.len(), line.len())
}

/// Extract the key portion of a line based on a KeyDef.
/// Allocation-free: uses find_nth_field instead of collecting all fields.
///
/// When `ignore_leading_blanks` is true (from the key's -b flag or global -b),
/// leading blanks in each field are skipped before applying character position
/// offsets. This matches GNU sort's behavior where `-b` affects where character
/// counting starts within a field.
pub fn extract_key<'a>(
    line: &'a [u8],
    key: &KeyDef,
    separator: Option<u8>,
    ignore_leading_blanks: bool,
) -> &'a [u8] {
    extract_key_z(line, key, separator, ignore_leading_blanks, false)
}

/// Extract key with zero-terminated mode support.
/// When `zero_terminated` is true and separator is None (default blank splitting),
/// newlines are treated as blanks, matching GNU sort -z behavior.
pub fn extract_key_z<'a>(
    line: &'a [u8],
    key: &KeyDef,
    separator: Option<u8>,
    ignore_leading_blanks: bool,
    zero_terminated: bool,
) -> &'a [u8] {
    let sf = key.start_field.saturating_sub(1);
    let (sf_start, sf_end) = find_nth_field_z(line, sf, separator, zero_terminated);

    if sf_start >= line.len() {
        return b"";
    }

    let blank_fn: fn(u8) -> bool = if zero_terminated && separator.is_none() {
        is_blank_z
    } else {
        is_blank
    };

    let start_byte = if key.start_char > 0 {
        let effective_start = if ignore_leading_blanks {
            skip_blanks_from_fn(line, sf_start, sf_end, blank_fn)
        } else {
            sf_start
        };
        let field_len = sf_end - effective_start;
        let char_offset = (key.start_char - 1).min(field_len);
        effective_start + char_offset
    } else {
        sf_start
    };

    let end_byte = if key.end_field > 0 {
        let ef = key.end_field.saturating_sub(1);
        let (ef_start, ef_end) = find_nth_field_z(line, ef, separator, zero_terminated);
        if key.end_char > 0 {
            let effective_start = if ignore_leading_blanks {
                skip_blanks_from_fn(line, ef_start, ef_end, blank_fn)
            } else {
                ef_start
            };
            let field_len = ef_end - effective_start;
            let char_offset = key.end_char.min(field_len);
            effective_start + char_offset
        } else {
            ef_end
        }
    } else {
        line.len()
    };

    if start_byte >= end_byte || start_byte >= line.len() {
        return b"";
    }

    &line[start_byte..end_byte.min(line.len())]
}
