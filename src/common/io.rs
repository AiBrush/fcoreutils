use std::fs::File;
use std::io::{self, Read};
use std::path::Path;

use memmap2::Mmap;

/// Threshold above which we use mmap instead of buffered read.
/// mmap has overhead from page table setup; for small files buffered read wins.
const MMAP_THRESHOLD: u64 = 64 * 1024; // 64KB

/// Read a file, choosing mmap for large files and buffered read for small ones.
///
/// Returns the file contents as a byte vector. For mmap, we keep the mapping
/// alive by returning the data; callers that need zero-copy access should use
/// `mmap_file` directly.
pub fn read_file_bytes(path: &Path) -> io::Result<Vec<u8>> {
    let metadata = std::fs::metadata(path)?;

    if metadata.len() >= MMAP_THRESHOLD {
        let file = File::open(path)?;
        // SAFETY: We only read the file; we don't modify it. The file must not
        // be truncated while the mapping is alive, but this is acceptable for
        // our use case (we process and drop immediately).
        let mmap = unsafe { Mmap::map(&file)? };
        Ok(mmap.to_vec())
    } else {
        std::fs::read(path)
    }
}

/// Memory-map a file for zero-copy access.
///
/// Returns the Mmap handle. Caller must ensure the file is not modified
/// while the mapping is alive.
pub fn mmap_file(path: &Path) -> io::Result<Mmap> {
    let file = File::open(path)?;
    // SAFETY: read-only mapping; file must not be truncated during use.
    unsafe { Mmap::map(&file) }
}

/// Read all bytes from stdin into a Vec.
pub fn read_stdin() -> io::Result<Vec<u8>> {
    let mut buf = Vec::new();
    io::stdin().lock().read_to_end(&mut buf)?;
    Ok(buf)
}
