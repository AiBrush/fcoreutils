/// Parse a tr character set string into a Vec<u8> of expanded characters.
///
/// Supports:
/// - Literal characters
/// - Escape sequences: \\, \a, \b, \f, \n, \r, \t, \v, \NNN (octal)
/// - Ranges: a-z, A-Z, 0-9
/// - Character classes: [:alnum:], [:alpha:], etc.
/// - Equivalence classes: [=c=]
/// - Repeat: [c*n] or [c*] (SET2 only, handled by caller)

/// Identifies a case-conversion character class and its position in the expanded set.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CaseClass {
    Upper,
    Lower,
}

/// Records the position and type of a [:upper:] or [:lower:] class in a set.
#[derive(Debug, Clone, Copy)]
pub struct CaseClassInfo {
    pub class: CaseClass,
    pub position: usize,
}

/// Build the complement of a character set: all bytes NOT in the given set.
/// Result is sorted ascending (0, 1, 2, ... 255 minus the set members).
pub fn complement(set: &[u8]) -> Vec<u8> {
    let mut member = [0u8; 32];
    for &ch in set {
        member[ch as usize >> 3] |= 1 << (ch & 7);
    }
    (0u8..=255)
        .filter(|&c| (member[c as usize >> 3] & (1 << (c & 7))) == 0)
        .collect()
}

/// Parse a SET string into expanded bytes.
pub fn parse_set(s: &str) -> Vec<u8> {
    let bytes = s.as_bytes();
    let mut result = Vec::with_capacity(bytes.len());
    let mut i = 0;

    while i < bytes.len() {
        if bytes[i] == b'[' && i + 1 < bytes.len() {
            // Try character class [:name:]
            if bytes.get(i + 1) == Some(&b':') {
                if let Some((class_bytes, end)) = parse_char_class(bytes, i) {
                    result.extend_from_slice(&class_bytes);
                    i = end;
                    continue;
                }
            }
            // Try equivalence class [=c=]
            if bytes.get(i + 1) == Some(&b'=') {
                if let Some((ch, end)) = parse_equiv_class(bytes, i) {
                    result.push(ch);
                    i = end;
                    continue;
                }
            }
            // Try repeat [c*n] or [c*]
            if let Some((ch, count, end)) = parse_repeat(bytes, i) {
                for _ in 0..count {
                    result.push(ch);
                }
                i = end;
                continue;
            }
        }

        // Escape sequence
        if bytes[i] == b'\\' && i + 1 < bytes.len() {
            let (ch, advance) = parse_escape(bytes, i);
            result.push(ch);
            i += advance;
            continue;
        }

        // Range: prev-next (only if we have a previous char and a next char)
        if bytes[i] == b'-' && !result.is_empty() && i + 1 < bytes.len() {
            let start = *result.last().unwrap();
            let (end_ch, advance) = if bytes[i + 1] == b'\\' && i + 2 < bytes.len() {
                let (ch, adv) = parse_escape(bytes, i + 1);
                (ch, adv)
            } else {
                (bytes[i + 1], 1)
            };
            if end_ch >= start {
                // Expand range (start is already in result)
                for c in (start + 1)..=end_ch {
                    result.push(c);
                }
                i += 1 + advance;
            } else {
                // Invalid range in GNU tr: still emit the characters
                // GNU tr treats invalid ranges as error, but let's be compatible
                // Actually GNU tr gives an error for descending ranges
                // We'll just push the literal '-'
                result.push(b'-');
                i += 1;
            }
            continue;
        }

        result.push(bytes[i]);
        i += 1;
    }

    result
}

/// Parse a SET string into expanded bytes AND track positions of [:upper:]/[:lower:] classes.
/// This is needed for GNU-compatible validation of case class alignment.
pub fn parse_set_with_classes(s: &str) -> (Vec<u8>, Vec<CaseClassInfo>) {
    let bytes = s.as_bytes();
    let mut result = Vec::with_capacity(bytes.len());
    let mut classes = Vec::new();
    let mut i = 0;

    while i < bytes.len() {
        if bytes[i] == b'[' && i + 1 < bytes.len() {
            // Try character class [:name:]
            if bytes.get(i + 1) == Some(&b':') {
                if let Some((class_bytes, end)) = parse_char_class(bytes, i) {
                    // Check if this is [:upper:] or [:lower:]
                    let name_start = i + 2;
                    let mut name_end = name_start;
                    while name_end < bytes.len() && bytes[name_end] != b':' {
                        name_end += 1;
                    }
                    let name = &bytes[name_start..name_end];
                    if name == b"upper" {
                        classes.push(CaseClassInfo {
                            class: CaseClass::Upper,
                            position: result.len(),
                        });
                    } else if name == b"lower" {
                        classes.push(CaseClassInfo {
                            class: CaseClass::Lower,
                            position: result.len(),
                        });
                    }
                    result.extend_from_slice(&class_bytes);
                    i = end;
                    continue;
                }
            }
            // Try equivalence class [=c=]
            if bytes.get(i + 1) == Some(&b'=') {
                if let Some((ch, end)) = parse_equiv_class(bytes, i) {
                    result.push(ch);
                    i = end;
                    continue;
                }
            }
            // Try repeat [c*n] or [c*]
            if let Some((ch, count, end)) = parse_repeat(bytes, i) {
                for _ in 0..count {
                    result.push(ch);
                }
                i = end;
                continue;
            }
        }

        // Escape sequence
        if bytes[i] == b'\\' && i + 1 < bytes.len() {
            let (ch, advance) = parse_escape(bytes, i);
            result.push(ch);
            i += advance;
            continue;
        }

        // Range: prev-next (only if we have a previous char and a next char)
        if bytes[i] == b'-' && !result.is_empty() && i + 1 < bytes.len() {
            let start = *result.last().unwrap();
            let (end_ch, advance) = if bytes[i + 1] == b'\\' && i + 2 < bytes.len() {
                let (ch, adv) = parse_escape(bytes, i + 1);
                (ch, adv)
            } else {
                (bytes[i + 1], 1)
            };
            if end_ch >= start {
                for c in (start + 1)..=end_ch {
                    result.push(c);
                }
                i += 1 + advance;
            } else {
                result.push(b'-');
                i += 1;
            }
            continue;
        }

        result.push(bytes[i]);
        i += 1;
    }

    (result, classes)
}

/// Parse SET2 string with class tracking, expanding to match SET1 length.
/// Returns (expanded_bytes, case_class_positions).
pub fn expand_set2_with_classes(set2_str: &str, set1_len: usize) -> (Vec<u8>, Vec<CaseClassInfo>) {
    let bytes = set2_str.as_bytes();

    // Check if there's a [c*] (fill repeat) in SET2
    // If so, we handle it specially. Otherwise, use parse_set_with_classes + extend.
    let mut has_fill = false;
    {
        let mut j = 0;
        while j < bytes.len() {
            if bytes[j] == b'[' {
                if let Some((_ch, count, _end)) = parse_repeat(bytes, j) {
                    if count == 0 {
                        has_fill = true;
                        break;
                    }
                    j = _end;
                    continue;
                }
            }
            if bytes[j] == b'\\' && j + 1 < bytes.len() {
                let (_ch, adv) = parse_escape(bytes, j);
                j += adv;
                continue;
            }
            j += 1;
        }
    }

    if has_fill {
        // When there's a fill repeat, expand_set2 handles it but we still need classes.
        // Parse the full set for class positions, then use expand_set2 for the bytes.
        let expanded = expand_set2(set2_str, set1_len);
        // Re-parse to find class positions (they won't be affected by fill repeats
        // since fills don't generate case classes)
        let (_raw, classes) = parse_set_with_classes(set2_str);
        (expanded, classes)
    } else {
        let (mut set2, classes) = parse_set_with_classes(set2_str);
        if set2.len() < set1_len && !set2.is_empty() {
            let last = *set2.last().unwrap();
            set2.resize(set1_len, last);
        }
        (set2, classes)
    }
}

/// Validate that [:upper:] and [:lower:] classes are properly paired between SET1 and SET2.
/// GNU tr requires that when [:upper:] appears in one set, [:lower:] must appear at the
/// same position in the other set (and vice versa). Returns an error message if misaligned.
pub fn validate_case_classes(
    set1_classes: &[CaseClassInfo],
    set2_classes: &[CaseClassInfo],
) -> Result<(), String> {
    // Check each class in SET1 has a matching partner in SET2 at the same position
    for c1 in set1_classes {
        let expected_partner = match c1.class {
            CaseClass::Upper => CaseClass::Lower,
            CaseClass::Lower => CaseClass::Upper,
        };
        let found = set2_classes
            .iter()
            .any(|c2| c2.class == expected_partner && c2.position == c1.position);
        if !found {
            return Err("misaligned [:upper:] and/or [:lower:] construct".to_string());
        }
    }

    // Check each class in SET2 has a matching partner in SET1 at the same position
    for c2 in set2_classes {
        let expected_partner = match c2.class {
            CaseClass::Upper => CaseClass::Lower,
            CaseClass::Lower => CaseClass::Upper,
        };
        let found = set1_classes
            .iter()
            .any(|c1| c1.class == expected_partner && c1.position == c2.position);
        if !found {
            return Err("misaligned [:upper:] and/or [:lower:] construct".to_string());
        }
    }

    Ok(())
}

/// Check if SET2 ends with a case class and SET1 is longer than SET2 (before expansion).
/// GNU tr: "when translating with string1 longer than string2, the latter string
/// must not end with a character class".
/// `set1_len` is the expanded length of SET1.
/// `set2_raw_len` is the expanded length of SET2 before extension to match SET1.
/// `set2_classes` are the case class positions in SET2.
pub fn validate_set2_class_at_end(
    set1_len: usize,
    set2_raw_len: usize,
    set2_classes: &[CaseClassInfo],
) -> Result<(), String> {
    if set1_len <= set2_raw_len || set2_classes.is_empty() {
        return Ok(());
    }
    // Check if the last class in SET2 ends exactly at the end of the raw (unexpanded) SET2
    let last_class = &set2_classes[set2_classes.len() - 1];
    // A case class always has 26 characters
    let class_end = last_class.position + 26;
    if class_end == set2_raw_len {
        return Err(
            "when translating with string1 longer than string2,\n\
             the latter string must not end with a character class"
                .to_string(),
        );
    }
    Ok(())
}

/// Parse escape sequence starting at position `i` (which points to '\').
/// Returns (byte_value, number_of_bytes_consumed).
fn parse_escape(bytes: &[u8], i: usize) -> (u8, usize) {
    debug_assert_eq!(bytes[i], b'\\');
    if i + 1 >= bytes.len() {
        return (b'\\', 1);
    }
    match bytes[i + 1] {
        b'\\' => (b'\\', 2),
        b'a' => (0x07, 2),
        b'b' => (0x08, 2),
        b'f' => (0x0C, 2),
        b'n' => (b'\n', 2),
        b'r' => (b'\r', 2),
        b't' => (b'\t', 2),
        b'v' => (0x0B, 2),
        // Octal: \NNN (1-3 octal digits)
        b'0'..=b'7' => {
            let mut val: u8 = bytes[i + 1] - b'0';
            let mut consumed = 2;
            if i + 2 < bytes.len() && bytes[i + 2] >= b'0' && bytes[i + 2] <= b'7' {
                val = val * 8 + (bytes[i + 2] - b'0');
                consumed = 3;
                if i + 3 < bytes.len() && bytes[i + 3] >= b'0' && bytes[i + 3] <= b'7' {
                    let new_val = val as u16 * 8 + (bytes[i + 3] - b'0') as u16;
                    if new_val <= 255 {
                        val = new_val as u8;
                        consumed = 4;
                    }
                }
            }
            (val, consumed)
        }
        // Unknown escape: just the char itself (GNU behavior)
        ch => (ch, 2),
    }
}

/// Try to parse a character class like [:alpha:] starting at position i.
/// Returns (expanded bytes, position after the closing ']').
fn parse_char_class(bytes: &[u8], i: usize) -> Option<(Vec<u8>, usize)> {
    // Format: [:name:]
    // bytes[i] = '[', bytes[i+1] = ':'
    let start = i + 2;
    let mut end = start;
    while end < bytes.len() && bytes[end] != b':' {
        end += 1;
    }
    // Need ':' followed by ']'
    if end + 1 >= bytes.len() || bytes[end] != b':' || bytes[end + 1] != b']' {
        return None;
    }
    let name = &bytes[start..end];
    let chars = expand_class(name)?;
    Some((chars, end + 2))
}

/// Expand a character class name to its bytes.
fn expand_class(name: &[u8]) -> Option<Vec<u8>> {
    match name {
        b"alnum" => Some(
            (b'0'..=b'9')
                .chain(b'A'..=b'Z')
                .chain(b'a'..=b'z')
                .collect(),
        ),
        b"alpha" => Some((b'A'..=b'Z').chain(b'a'..=b'z').collect()),
        b"blank" => Some(vec![b'\t', b' ']),
        b"cntrl" => Some((0u8..=31).chain(std::iter::once(127)).collect()),
        b"digit" => Some((b'0'..=b'9').collect()),
        b"graph" => Some((33u8..=126).collect()),
        b"lower" => Some((b'a'..=b'z').collect()),
        b"print" => Some((32u8..=126).collect()),
        b"punct" => Some(
            (33u8..=47)
                .chain(58u8..=64)
                .chain(91u8..=96)
                .chain(123u8..=126)
                .collect(),
        ),
        b"space" => Some(vec![b'\t', b'\n', 0x0B, 0x0C, b'\r', b' ']),
        b"upper" => Some((b'A'..=b'Z').collect()),
        b"xdigit" => Some(
            (b'0'..=b'9')
                .chain(b'A'..=b'F')
                .chain(b'a'..=b'f')
                .collect(),
        ),
        _ => None,
    }
}

/// Try to parse an equivalence class like [=c=] starting at position i.
fn parse_equiv_class(bytes: &[u8], i: usize) -> Option<(u8, usize)> {
    // Format: [=c=]
    // bytes[i] = '[', bytes[i+1] = '='
    if i + 4 >= bytes.len() {
        return None;
    }
    let ch = bytes[i + 2];
    if bytes[i + 3] == b'=' && bytes[i + 4] == b']' {
        Some((ch, i + 5))
    } else {
        None
    }
}

/// Try to parse a repeat construct like [c*n] or [c*] starting at position i.
/// Returns (character, count, position after ']').
/// A count of 0 means "fill to match SET1 length" (caller handles).
fn parse_repeat(bytes: &[u8], i: usize) -> Option<(u8, usize, usize)> {
    // Format: [c*n] or [c*]
    // bytes[i] = '['
    if i + 3 >= bytes.len() {
        return None;
    }

    // The char could be an escape
    let (ch, char_len) = if bytes[i + 1] == b'\\' && i + 2 < bytes.len() {
        let (c, adv) = parse_escape(bytes, i + 1);
        (c, adv)
    } else {
        (bytes[i + 1], 1)
    };

    let star_pos = i + 1 + char_len;
    if star_pos >= bytes.len() || bytes[star_pos] != b'*' {
        return None;
    }

    let after_star = star_pos + 1;
    if after_star >= bytes.len() {
        return None;
    }

    // [c*] - repeat to fill
    if bytes[after_star] == b']' {
        return Some((ch, 0, after_star + 1));
    }

    // [c*n] - repeat n times
    // n can be octal (starts with 0) or decimal
    let mut end = after_star;
    while end < bytes.len() && bytes[end] != b']' {
        end += 1;
    }
    if end >= bytes.len() {
        return None;
    }

    let num_str = std::str::from_utf8(&bytes[after_star..end]).ok()?;
    let count = if num_str.starts_with('0') && num_str.len() > 1 {
        usize::from_str_radix(num_str, 8).ok()?
    } else {
        num_str.parse::<usize>().ok()?
    };

    Some((ch, count, end + 1))
}

/// Expand SET2 to match SET1 length for translation.
/// If SET2 has [c*] repeats, fill them. Otherwise repeat last char.
pub fn expand_set2(set2_str: &str, set1_len: usize) -> Vec<u8> {
    let bytes = set2_str.as_bytes();

    // Check if there's a [c*] (fill repeat) in SET2
    // We need to parse SET2 specially: expand everything except [c*] fills,
    // then compute how many fill chars are needed.
    let mut before_fill = Vec::new();
    let mut fill_char: Option<u8> = None;
    let mut after_fill = Vec::new();
    let mut i = 0;
    let mut found_fill = false;

    while i < bytes.len() {
        if bytes[i] == b'[' && i + 1 < bytes.len() {
            if bytes.get(i + 1) == Some(&b':') {
                if let Some((class_bytes, end)) = parse_char_class(bytes, i) {
                    if found_fill {
                        after_fill.extend_from_slice(&class_bytes);
                    } else {
                        before_fill.extend_from_slice(&class_bytes);
                    }
                    i = end;
                    continue;
                }
            }
            if bytes.get(i + 1) == Some(&b'=') {
                if let Some((ch, end)) = parse_equiv_class(bytes, i) {
                    if found_fill {
                        after_fill.push(ch);
                    } else {
                        before_fill.push(ch);
                    }
                    i = end;
                    continue;
                }
            }
            if let Some((ch, count, end)) = parse_repeat(bytes, i) {
                if count == 0 && !found_fill {
                    fill_char = Some(ch);
                    found_fill = true;
                    i = end;
                    continue;
                } else {
                    let target = if found_fill {
                        &mut after_fill
                    } else {
                        &mut before_fill
                    };
                    for _ in 0..count {
                        target.push(ch);
                    }
                    i = end;
                    continue;
                }
            }
        }

        if bytes[i] == b'\\' && i + 1 < bytes.len() {
            let (ch, advance) = parse_escape(bytes, i);
            if found_fill {
                after_fill.push(ch);
            } else {
                before_fill.push(ch);
            }
            i += advance;
            continue;
        }

        if bytes[i] == b'-' && !before_fill.is_empty() && !found_fill && i + 1 < bytes.len() {
            let start = *before_fill.last().unwrap();
            let (end_ch, advance) = if bytes[i + 1] == b'\\' && i + 2 < bytes.len() {
                let (ch, adv) = parse_escape(bytes, i + 1);
                (ch, adv)
            } else {
                (bytes[i + 1], 1)
            };
            if end_ch >= start {
                for c in (start + 1)..=end_ch {
                    before_fill.push(c);
                }
                i += 1 + advance;
            } else {
                before_fill.push(b'-');
                i += 1;
            }
            continue;
        }
        if bytes[i] == b'-' && !after_fill.is_empty() && found_fill && i + 1 < bytes.len() {
            let start = *after_fill.last().unwrap();
            let (end_ch, advance) = if bytes[i + 1] == b'\\' && i + 2 < bytes.len() {
                let (ch, adv) = parse_escape(bytes, i + 1);
                (ch, adv)
            } else {
                (bytes[i + 1], 1)
            };
            if end_ch >= start {
                for c in (start + 1)..=end_ch {
                    after_fill.push(c);
                }
                i += 1 + advance;
            } else {
                after_fill.push(b'-');
                i += 1;
            }
            continue;
        }

        if found_fill {
            after_fill.push(bytes[i]);
        } else {
            before_fill.push(bytes[i]);
        }
        i += 1;
    }

    if let Some(fc) = fill_char {
        let fixed = before_fill.len() + after_fill.len();
        let fill_count = if set1_len > fixed {
            set1_len - fixed
        } else {
            0
        };
        let mut result = before_fill;
        result.resize(result.len() + fill_count, fc);
        result.extend_from_slice(&after_fill);
        result
    } else {
        // No fill repeat — use parse_set and extend with last char
        let mut set2 = parse_set(set2_str);
        if set2.len() < set1_len && !set2.is_empty() {
            let last = *set2.last().unwrap();
            set2.resize(set1_len, last);
        }
        set2
    }
}
