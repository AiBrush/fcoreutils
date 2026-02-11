use std::io::{self, Read, Write};
use std::mem::ManuallyDrop;
#[cfg(unix)]
use std::os::unix::io::FromRawFd;

const BUF_SIZE: usize = 64 * 1024; // 64KB — fits in L2 cache for processing

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

/// Try to mmap stdin if it's a regular file.
#[cfg(unix)]
fn try_mmap_stdin() -> Option<memmap2::Mmap> {
    use std::os::unix::io::AsRawFd;
    let stdin = io::stdin();
    let fd = stdin.as_raw_fd();
    let file = ManuallyDrop::new(unsafe { std::fs::File::from_raw_fd(fd) });
    let metadata = file.metadata().ok()?;
    if !metadata.file_type().is_file() || metadata.len() == 0 {
        return None;
    }
    let mmap = unsafe { memmap2::Mmap::map(&*file).ok()? };
    #[cfg(target_os = "linux")]
    { let _ = mmap.advise(memmap2::Advice::Sequential); }
    Some(mmap)
}

#[cfg(not(unix))]
fn try_mmap_stdin() -> Option<memmap2::Mmap> {
    None
}

#[cfg(unix)]
#[inline]
fn raw_stdout() -> ManuallyDrop<std::fs::File> {
    unsafe { ManuallyDrop::new(std::fs::File::from_raw_fd(1)) }
}

#[cfg(unix)]
#[inline]
fn raw_stdin() -> ManuallyDrop<std::fs::File> {
    unsafe { ManuallyDrop::new(std::fs::File::from_raw_fd(0)) }
}

// === Translate ===

pub fn translate(set1: &[u8], set2: &[u8]) -> io::Result<()> {
    let table = build_translate_table(set1, set2);
    let mut outbuf = vec![0u8; BUF_SIZE];
    let mut writer = raw_stdout();

    if let Some(mmap) = try_mmap_stdin() {
        for chunk in mmap.chunks(BUF_SIZE) {
            let out = &mut outbuf[..chunk.len()];
            for (i, &b) in chunk.iter().enumerate() {
                unsafe { *out.get_unchecked_mut(i) = *table.get_unchecked(b as usize); }
            }
            writer.write_all(out)?;
        }
        return Ok(());
    }

    let mut reader = raw_stdin();
    let mut buf = vec![0u8; BUF_SIZE];
    loop {
        let n = reader.read(&mut buf)?;
        if n == 0 { break; }
        let chunk = &mut buf[..n];
        for b in chunk.iter_mut() {
            *b = unsafe { *table.get_unchecked(*b as usize) };
        }
        writer.write_all(chunk)?;
    }
    Ok(())
}

// === Translate + Squeeze ===

pub fn translate_squeeze(set1: &[u8], set2: &[u8]) -> io::Result<()> {
    let table = build_translate_table(set1, set2);
    let squeeze_set = build_member_set(set2);
    let mut outbuf = vec![0u8; BUF_SIZE];
    let mut writer = raw_stdout();
    let mut last_squeezed: u16 = 256;

    if let Some(mmap) = try_mmap_stdin() {
        for chunk in mmap.chunks(BUF_SIZE) {
            let mut out_pos = 0;
            for &b in chunk {
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
        return Ok(());
    }

    let mut reader = raw_stdin();
    let mut inbuf = vec![0u8; BUF_SIZE];
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

pub fn delete(delete_chars: &[u8]) -> io::Result<()> {
    let member = build_member_set(delete_chars);
    let mut outbuf = vec![0u8; BUF_SIZE];
    let mut writer = raw_stdout();

    if let Some(mmap) = try_mmap_stdin() {
        for chunk in mmap.chunks(BUF_SIZE) {
            let mut out_pos = 0;
            for &b in chunk {
                if !is_member(&member, b) {
                    unsafe { *outbuf.get_unchecked_mut(out_pos) = b; }
                    out_pos += 1;
                }
            }
            writer.write_all(&outbuf[..out_pos])?;
        }
        return Ok(());
    }

    let mut reader = raw_stdin();
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

pub fn delete_squeeze(delete_chars: &[u8], squeeze_chars: &[u8]) -> io::Result<()> {
    let delete_set = build_member_set(delete_chars);
    let squeeze_set = build_member_set(squeeze_chars);
    let mut outbuf = vec![0u8; BUF_SIZE];
    let mut writer = raw_stdout();
    let mut last_squeezed: u16 = 256;

    if let Some(mmap) = try_mmap_stdin() {
        for chunk in mmap.chunks(BUF_SIZE) {
            let mut out_pos = 0;
            for &b in chunk {
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
        return Ok(());
    }

    let mut reader = raw_stdin();
    let mut inbuf = vec![0u8; BUF_SIZE];
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

pub fn squeeze(squeeze_chars: &[u8]) -> io::Result<()> {
    let member = build_member_set(squeeze_chars);
    let mut outbuf = vec![0u8; BUF_SIZE];
    let mut writer = raw_stdout();
    let mut last_squeezed: u16 = 256;

    if let Some(mmap) = try_mmap_stdin() {
        for chunk in mmap.chunks(BUF_SIZE) {
            let mut out_pos = 0;
            for &b in chunk {
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
        return Ok(());
    }

    let mut reader = raw_stdin();
    let mut inbuf = vec![0u8; BUF_SIZE];
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
