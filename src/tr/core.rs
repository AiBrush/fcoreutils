use std::io::{self, Read, Write};
use std::mem::ManuallyDrop;
#[cfg(unix)]
use std::os::unix::io::FromRawFd;
use rayon::prelude::*;

const BUF_SIZE: usize = 256 * 1024;
const WRITE_CHUNK: usize = 256 * 1024;
const PAR_CHUNK: usize = 1024 * 1024; // 1MB chunks for parallel processing

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
    unsafe { memmap2::Mmap::map(&*file).ok() }
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

/// Apply table lookup to a chunk (used in parallel).
#[inline]
fn translate_apply(table: &[u8; 256], input: &[u8], output: &mut [u8]) {
    for (i, &b) in input.iter().enumerate() {
        unsafe {
            *output.get_unchecked_mut(i) = *table.get_unchecked(b as usize);
        }
    }
}

// === Translate (parallel for mmap, in-place for pipes) ===

pub fn translate(set1: &[u8], set2: &[u8]) -> io::Result<()> {
    let table = build_translate_table(set1, set2);

    if let Some(mmap) = try_mmap_stdin() {
        let mut writer = raw_stdout();
        let input = &mmap[..];
        let mut output = vec![0u8; input.len()];

        // Parallel translate: split into 1MB chunks, process on all cores
        input.par_chunks(PAR_CHUNK)
            .zip(output.par_chunks_mut(PAR_CHUNK))
            .for_each(|(inp, out)| {
                translate_apply(&table, inp, out);
            });

        // Write output in large sequential chunks
        for chunk in output.chunks(WRITE_CHUNK) {
            writer.write_all(chunk)?;
        }
        return Ok(());
    }

    // Fallback: buffered I/O for pipes
    let mut reader = raw_stdin();
    let mut writer = raw_stdout();
    let mut buf = vec![0u8; BUF_SIZE];

    loop {
        let n = reader.read(&mut buf)?;
        if n == 0 {
            break;
        }
        let chunk = &mut buf[..n];
        for b in chunk.iter_mut() {
            *b = unsafe { *table.get_unchecked(*b as usize) };
        }
        writer.write_all(chunk)?;
    }
    Ok(())
}

// === Translate + Squeeze (sequential - has state dependency) ===

pub fn translate_squeeze(set1: &[u8], set2: &[u8]) -> io::Result<()> {
    let table = build_translate_table(set1, set2);
    let squeeze_set = build_member_set(set2);

    if let Some(mmap) = try_mmap_stdin() {
        let mut writer = raw_stdout();
        let mut outbuf = vec![0u8; WRITE_CHUNK];
        let mut out_pos = 0;
        let mut last_squeezed: u16 = 256;

        for &b in mmap.iter() {
            let translated = unsafe { *table.get_unchecked(b as usize) };
            if is_member(&squeeze_set, translated) {
                if last_squeezed == translated as u16 {
                    continue;
                }
                last_squeezed = translated as u16;
            } else {
                last_squeezed = 256;
            }
            unsafe { *outbuf.get_unchecked_mut(out_pos) = translated; }
            out_pos += 1;
            if out_pos == WRITE_CHUNK {
                writer.write_all(&outbuf)?;
                out_pos = 0;
            }
        }
        if out_pos > 0 {
            writer.write_all(&outbuf[..out_pos])?;
        }
        return Ok(());
    }

    let mut reader = raw_stdin();
    let mut writer = raw_stdout();
    let mut inbuf = vec![0u8; BUF_SIZE];
    let mut outbuf = vec![0u8; BUF_SIZE];
    let mut last_squeezed: u16 = 256;

    loop {
        let n = reader.read(&mut inbuf)?;
        if n == 0 {
            break;
        }
        let mut out_pos = 0;
        for &b in &inbuf[..n] {
            let translated = unsafe { *table.get_unchecked(b as usize) };
            if is_member(&squeeze_set, translated) {
                if last_squeezed == translated as u16 {
                    continue;
                }
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

// === Delete (parallel for mmap) ===

pub fn delete(delete_chars: &[u8]) -> io::Result<()> {
    let member = build_member_set(delete_chars);

    if let Some(mmap) = try_mmap_stdin() {
        let mut writer = raw_stdout();
        // Parallel: each chunk independently filters, then write in order
        let input = &mmap[..];
        let chunks: Vec<&[u8]> = input.chunks(PAR_CHUNK).collect();
        let results: Vec<Vec<u8>> = chunks.par_iter().map(|chunk| {
            let mut out = Vec::with_capacity(chunk.len());
            for &b in chunk.iter() {
                if !is_member(&member, b) {
                    out.push(b);
                }
            }
            out
        }).collect();

        for result in &results {
            writer.write_all(result)?;
        }
        return Ok(());
    }

    let mut reader = raw_stdin();
    let mut writer = raw_stdout();
    let mut inbuf = vec![0u8; BUF_SIZE];
    let mut outbuf = vec![0u8; BUF_SIZE];

    loop {
        let n = reader.read(&mut inbuf)?;
        if n == 0 {
            break;
        }
        let mut out_pos = 0;
        for &b in &inbuf[..n] {
            unsafe { *outbuf.get_unchecked_mut(out_pos) = b; }
            out_pos += !is_member(&member, b) as usize;
        }
        writer.write_all(&outbuf[..out_pos])?;
    }
    Ok(())
}

// === Delete + Squeeze (sequential - has state dependency) ===

pub fn delete_squeeze(delete_chars: &[u8], squeeze_chars: &[u8]) -> io::Result<()> {
    let delete_set = build_member_set(delete_chars);
    let squeeze_set = build_member_set(squeeze_chars);

    if let Some(mmap) = try_mmap_stdin() {
        let mut writer = raw_stdout();
        let mut outbuf = vec![0u8; WRITE_CHUNK];
        let mut out_pos = 0;
        let mut last_squeezed: u16 = 256;

        for &b in mmap.iter() {
            if is_member(&delete_set, b) {
                continue;
            }
            if is_member(&squeeze_set, b) {
                if last_squeezed == b as u16 {
                    continue;
                }
                last_squeezed = b as u16;
            } else {
                last_squeezed = 256;
            }
            unsafe { *outbuf.get_unchecked_mut(out_pos) = b; }
            out_pos += 1;
            if out_pos == WRITE_CHUNK {
                writer.write_all(&outbuf)?;
                out_pos = 0;
            }
        }
        if out_pos > 0 {
            writer.write_all(&outbuf[..out_pos])?;
        }
        return Ok(());
    }

    let mut reader = raw_stdin();
    let mut writer = raw_stdout();
    let mut inbuf = vec![0u8; BUF_SIZE];
    let mut outbuf = vec![0u8; BUF_SIZE];
    let mut last_squeezed: u16 = 256;

    loop {
        let n = reader.read(&mut inbuf)?;
        if n == 0 {
            break;
        }
        let mut out_pos = 0;
        for &b in &inbuf[..n] {
            if is_member(&delete_set, b) {
                continue;
            }
            if is_member(&squeeze_set, b) {
                if last_squeezed == b as u16 {
                    continue;
                }
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

// === Squeeze (sequential - has state dependency) ===

pub fn squeeze(squeeze_chars: &[u8]) -> io::Result<()> {
    let member = build_member_set(squeeze_chars);

    if let Some(mmap) = try_mmap_stdin() {
        let mut writer = raw_stdout();
        let mut outbuf = vec![0u8; WRITE_CHUNK];
        let mut out_pos = 0;
        let mut last_squeezed: u16 = 256;

        for &b in mmap.iter() {
            if is_member(&member, b) {
                if last_squeezed == b as u16 {
                    continue;
                }
                last_squeezed = b as u16;
            } else {
                last_squeezed = 256;
            }
            unsafe { *outbuf.get_unchecked_mut(out_pos) = b; }
            out_pos += 1;
            if out_pos == WRITE_CHUNK {
                writer.write_all(&outbuf)?;
                out_pos = 0;
            }
        }
        if out_pos > 0 {
            writer.write_all(&outbuf[..out_pos])?;
        }
        return Ok(());
    }

    let mut reader = raw_stdin();
    let mut writer = raw_stdout();
    let mut inbuf = vec![0u8; BUF_SIZE];
    let mut outbuf = vec![0u8; BUF_SIZE];
    let mut last_squeezed: u16 = 256;

    loop {
        let n = reader.read(&mut inbuf)?;
        if n == 0 {
            break;
        }
        let mut out_pos = 0;
        for &b in &inbuf[..n] {
            if is_member(&member, b) {
                if last_squeezed == b as u16 {
                    continue;
                }
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
