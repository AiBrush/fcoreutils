use std::io::{self, BufWriter, Read, Write};

const BUF_SIZE: usize = 128 * 1024; // 128KB I/O buffer

/// Build a 256-byte lookup table mapping set1[i] -> set2[i].
/// Bytes not in SET1 map to themselves.
/// If SET1 is longer than SET2, extra SET1 chars map to last char of SET2.
fn build_translate_table(set1: &[u8], set2: &[u8]) -> [u8; 256] {
    let mut table: [u8; 256] = std::array::from_fn(|i| i as u8);
    let last = set2.last().copied();
    for (i, &from) in set1.iter().enumerate() {
        table[from as usize] = if i < set2.len() {
            set2[i]
        } else {
            last.unwrap_or(from)
        };
    }
    table
}

/// Build a 256-bit (32-byte) membership set for O(1) byte lookup.
#[inline]
fn build_member_set(chars: &[u8]) -> [u8; 32] {
    let mut set = [0u8; 32];
    for &ch in chars {
        set[ch as usize >> 3] |= 1 << (ch & 7);
    }
    set
}

#[inline(always)]
fn is_member(set: &[u8; 32], ch: u8) -> bool {
    (set[ch as usize >> 3] & (1 << (ch & 7))) != 0
}

/// Translate characters: read stdin, map through lookup table, write stdout.
/// Caller must provide final expanded set1 and set2 (same length).
pub fn translate(set1: &[u8], set2: &[u8]) -> io::Result<()> {
    let table = build_translate_table(set1, set2);

    let stdin = io::stdin();
    let stdout = io::stdout();
    let mut reader = stdin.lock();
    let mut writer = BufWriter::with_capacity(BUF_SIZE, stdout.lock());
    let mut buf = vec![0u8; BUF_SIZE];

    loop {
        let n = reader.read(&mut buf)?;
        if n == 0 {
            break;
        }
        // Apply lookup table in-place — single table lookup per byte, zero allocation
        for b in &mut buf[..n] {
            *b = table[*b as usize];
        }
        writer.write_all(&buf[..n])?;
    }
    writer.flush()?;
    Ok(())
}

/// Translate + squeeze: translate via table, then squeeze consecutive duplicates of SET2 chars.
pub fn translate_squeeze(set1: &[u8], set2: &[u8]) -> io::Result<()> {
    let table = build_translate_table(set1, set2);
    let squeeze_set = build_member_set(set2);

    let stdin = io::stdin();
    let stdout = io::stdout();
    let mut reader = stdin.lock();
    let mut writer = BufWriter::with_capacity(BUF_SIZE, stdout.lock());
    let mut inbuf = vec![0u8; BUF_SIZE];
    let mut outbuf = vec![0u8; BUF_SIZE];
    let mut last_squeezed: Option<u8> = None;

    loop {
        let n = reader.read(&mut inbuf)?;
        if n == 0 {
            break;
        }
        let mut out_pos = 0;
        for &b in &inbuf[..n] {
            let translated = table[b as usize];
            if is_member(&squeeze_set, translated) {
                if last_squeezed == Some(translated) {
                    continue;
                }
                last_squeezed = Some(translated);
            } else {
                last_squeezed = None;
            }
            outbuf[out_pos] = translated;
            out_pos += 1;
        }
        writer.write_all(&outbuf[..out_pos])?;
    }
    writer.flush()?;
    Ok(())
}

/// Delete all bytes that are members of delete_chars from stdin.
pub fn delete(delete_chars: &[u8]) -> io::Result<()> {
    let member = build_member_set(delete_chars);

    let stdin = io::stdin();
    let stdout = io::stdout();
    let mut reader = stdin.lock();
    let mut writer = BufWriter::with_capacity(BUF_SIZE, stdout.lock());
    let mut inbuf = vec![0u8; BUF_SIZE];
    let mut outbuf = vec![0u8; BUF_SIZE];

    loop {
        let n = reader.read(&mut inbuf)?;
        if n == 0 {
            break;
        }
        let mut out_pos = 0;
        for &b in &inbuf[..n] {
            if !is_member(&member, b) {
                outbuf[out_pos] = b;
                out_pos += 1;
            }
        }
        writer.write_all(&outbuf[..out_pos])?;
    }
    writer.flush()?;
    Ok(())
}

/// Delete bytes in delete_chars, then squeeze consecutive duplicates of squeeze_chars.
pub fn delete_squeeze(delete_chars: &[u8], squeeze_chars: &[u8]) -> io::Result<()> {
    let delete_set = build_member_set(delete_chars);
    let squeeze_set = build_member_set(squeeze_chars);

    let stdin = io::stdin();
    let stdout = io::stdout();
    let mut reader = stdin.lock();
    let mut writer = BufWriter::with_capacity(BUF_SIZE, stdout.lock());
    let mut inbuf = vec![0u8; BUF_SIZE];
    let mut outbuf = vec![0u8; BUF_SIZE];
    let mut last_squeezed: Option<u8> = None;

    loop {
        let n = reader.read(&mut inbuf)?;
        if n == 0 {
            break;
        }
        let mut out_pos = 0;
        for &b in &inbuf[..n] {
            // First: delete
            if is_member(&delete_set, b) {
                continue;
            }
            // Then: squeeze
            if is_member(&squeeze_set, b) {
                if last_squeezed == Some(b) {
                    continue;
                }
                last_squeezed = Some(b);
            } else {
                last_squeezed = None;
            }
            outbuf[out_pos] = b;
            out_pos += 1;
        }
        writer.write_all(&outbuf[..out_pos])?;
    }
    writer.flush()?;
    Ok(())
}

/// Squeeze consecutive duplicates of squeeze_chars to a single occurrence.
pub fn squeeze(squeeze_chars: &[u8]) -> io::Result<()> {
    let member = build_member_set(squeeze_chars);

    let stdin = io::stdin();
    let stdout = io::stdout();
    let mut reader = stdin.lock();
    let mut writer = BufWriter::with_capacity(BUF_SIZE, stdout.lock());
    let mut inbuf = vec![0u8; BUF_SIZE];
    let mut outbuf = vec![0u8; BUF_SIZE];
    let mut last_squeezed: Option<u8> = None;

    loop {
        let n = reader.read(&mut inbuf)?;
        if n == 0 {
            break;
        }
        let mut out_pos = 0;
        for &b in &inbuf[..n] {
            if is_member(&member, b) {
                if last_squeezed == Some(b) {
                    continue;
                }
                last_squeezed = Some(b);
            } else {
                last_squeezed = None;
            }
            outbuf[out_pos] = b;
            out_pos += 1;
        }
        writer.write_all(&outbuf[..out_pos])?;
    }
    writer.flush()?;
    Ok(())
}
