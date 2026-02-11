use std::io::{self, Read, Write};

const BUF_SIZE: usize = 1024 * 1024; // 1MB — reduces syscall overhead vs GNU's 8KB

/// Build a 256-byte lookup table mapping set1[i] -> set2[i].
#[inline]
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
    unsafe { (*set.get_unchecked(ch as usize >> 3) & (1 << (ch & 7))) != 0 }
}

/// Fill buffer completely from reader (handles short reads from pipes).
fn fill_buf(reader: &mut impl Read, buf: &mut [u8]) -> io::Result<usize> {
    let mut filled = 0;
    while filled < buf.len() {
        match reader.read(&mut buf[filled..]) {
            Ok(0) => break,
            Ok(n) => filled += n,
            Err(ref e) if e.kind() == io::ErrorKind::Interrupted => continue,
            Err(e) => return Err(e),
        }
    }
    Ok(filled)
}

// === Translate ===

pub fn translate(set1: &[u8], set2: &[u8], reader: &mut impl Read, writer: &mut impl Write) -> io::Result<()> {
    let table = build_translate_table(set1, set2);
    let mut buf = vec![0u8; BUF_SIZE];
    loop {
        let n = fill_buf(reader, &mut buf)?;
        if n == 0 {
            break;
        }
        let chunk = &mut buf[..n];
        // In-place translation (unrolled 8-byte loop)
        let len = chunk.len();
        let mut i = 0;
        while i + 7 < len {
            unsafe {
                let p = chunk.as_mut_ptr().add(i);
                *p = *table.get_unchecked(*p as usize);
                *p.add(1) = *table.get_unchecked(*p.add(1) as usize);
                *p.add(2) = *table.get_unchecked(*p.add(2) as usize);
                *p.add(3) = *table.get_unchecked(*p.add(3) as usize);
                *p.add(4) = *table.get_unchecked(*p.add(4) as usize);
                *p.add(5) = *table.get_unchecked(*p.add(5) as usize);
                *p.add(6) = *table.get_unchecked(*p.add(6) as usize);
                *p.add(7) = *table.get_unchecked(*p.add(7) as usize);
            }
            i += 8;
        }
        while i < len {
            unsafe {
                let p = chunk.as_mut_ptr().add(i);
                *p = *table.get_unchecked(*p as usize);
            }
            i += 1;
        }
        writer.write_all(chunk)?;
    }
    Ok(())
}

// === Translate + Squeeze ===

pub fn translate_squeeze(set1: &[u8], set2: &[u8], reader: &mut impl Read, writer: &mut impl Write) -> io::Result<()> {
    let table = build_translate_table(set1, set2);
    let squeeze_set = build_member_set(set2);
    let mut outbuf = vec![0u8; BUF_SIZE];
    let mut inbuf = vec![0u8; BUF_SIZE];
    let mut last_squeezed: u16 = 256;

    loop {
        let n = reader.read(&mut inbuf)?;
        if n == 0 { break; }
        let mut out_pos = 0;
        for &b in &inbuf[..n] {
            let translated = unsafe { *table.get_unchecked(b as usize) };
            if is_member(&squeeze_set, translated) {
                if last_squeezed == translated as u16 { continue; }
                last_squeezed = translated as u16;
            } else {
                last_squeezed = 256;
            }
            unsafe { *outbuf.get_unchecked_mut(out_pos) = translated; }
            out_pos += 1;
        }
        writer.write_all(&outbuf[..out_pos])?;
    }
    Ok(())
}

// === Delete ===

pub fn delete(delete_chars: &[u8], reader: &mut impl Read, writer: &mut impl Write) -> io::Result<()> {
    let member = build_member_set(delete_chars);
    let mut outbuf = vec![0u8; BUF_SIZE];
    let mut inbuf = vec![0u8; BUF_SIZE];

    loop {
        let n = reader.read(&mut inbuf)?;
        if n == 0 { break; }
        let mut out_pos = 0;
        for &b in &inbuf[..n] {
            if !is_member(&member, b) {
                unsafe { *outbuf.get_unchecked_mut(out_pos) = b; }
                out_pos += 1;
            }
        }
        writer.write_all(&outbuf[..out_pos])?;
    }
    Ok(())
}

// === Delete + Squeeze ===

pub fn delete_squeeze(delete_chars: &[u8], squeeze_chars: &[u8], reader: &mut impl Read, writer: &mut impl Write) -> io::Result<()> {
    let delete_set = build_member_set(delete_chars);
    let squeeze_set = build_member_set(squeeze_chars);
    let mut outbuf = vec![0u8; BUF_SIZE];
    let mut inbuf = vec![0u8; BUF_SIZE];
    let mut last_squeezed: u16 = 256;

    loop {
        let n = reader.read(&mut inbuf)?;
        if n == 0 { break; }
        let mut out_pos = 0;
        for &b in &inbuf[..n] {
            if is_member(&delete_set, b) { continue; }
            if is_member(&squeeze_set, b) {
                if last_squeezed == b as u16 { continue; }
                last_squeezed = b as u16;
            } else {
                last_squeezed = 256;
            }
            unsafe { *outbuf.get_unchecked_mut(out_pos) = b; }
            out_pos += 1;
        }
        writer.write_all(&outbuf[..out_pos])?;
    }
    Ok(())
}

// === Squeeze ===

pub fn squeeze(squeeze_chars: &[u8], reader: &mut impl Read, writer: &mut impl Write) -> io::Result<()> {
    let member = build_member_set(squeeze_chars);
    let mut outbuf = vec![0u8; BUF_SIZE];
    let mut inbuf = vec![0u8; BUF_SIZE];
    let mut last_squeezed: u16 = 256;

    loop {
        let n = reader.read(&mut inbuf)?;
        if n == 0 { break; }
        let mut out_pos = 0;
        for &b in &inbuf[..n] {
            if is_member(&member, b) {
                if last_squeezed == b as u16 { continue; }
                last_squeezed = b as u16;
            } else {
                last_squeezed = 256;
            }
            unsafe { *outbuf.get_unchecked_mut(out_pos) = b; }
            out_pos += 1;
        }
        writer.write_all(&outbuf[..out_pos])?;
    }
    Ok(())
}
