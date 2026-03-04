use std::fs::{self, File};
use std::io::{self, BufRead, BufReader, BufWriter, Read, Write};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

#[cfg(unix)]
use rayon::prelude::*;

/// Suffix type for output filenames.
#[derive(Clone, Debug, PartialEq)]
pub enum SuffixType {
    /// Alphabetic suffixes: aa, ab, ..., zz, aaa, ...
    Alphabetic,
    /// Numeric suffixes: 00, 01, ..., 99, 000, ...
    Numeric(u64),
    /// Hexadecimal suffixes: 00, 01, ..., ff, 000, ...
    Hex(u64),
}

/// Split mode: how to divide the input.
#[derive(Clone, Debug)]
pub enum SplitMode {
    /// Split every N lines (default 1000).
    Lines(u64),
    /// Split every N bytes.
    Bytes(u64),
    /// Split at line boundaries, at most N bytes per file.
    LineBytes(u64),
    /// Split into exactly N output files (by byte count).
    Number(u64),
    /// Extract Kth chunk of N total (K/N format, 1-indexed).
    NumberExtract(u64, u64),
    /// Split into N output files by line boundaries (l/N format).
    LineChunks(u64),
    /// Extract Kth line-based chunk of N total (l/K/N format).
    LineChunkExtract(u64, u64),
    /// Round-robin distribute lines across N output files (r/N format).
    RoundRobin(u64),
    /// Extract Kth round-robin chunk of N total (r/K/N format).
    RoundRobinExtract(u64, u64),
}

/// Configuration for the split command.
#[derive(Clone, Debug)]
pub struct SplitConfig {
    pub mode: SplitMode,
    pub suffix_type: SuffixType,
    pub suffix_length: usize,
    pub additional_suffix: String,
    pub prefix: String,
    pub elide_empty: bool,
    pub verbose: bool,
    pub filter: Option<String>,
    pub separator: u8,
}

impl Default for SplitConfig {
    fn default() -> Self {
        Self {
            mode: SplitMode::Lines(1000),
            suffix_type: SuffixType::Alphabetic,
            suffix_length: 2,
            additional_suffix: String::new(),
            prefix: "x".to_string(),
            elide_empty: false,
            verbose: false,
            filter: None,
            separator: b'\n',
        }
    }
}

/// Parse a SIZE string with optional suffix.
/// Supports: K=1024, M=1024^2, G=1024^3, T=1024^4, P=1024^5, E=1024^6
/// Also: KB=1000, MB=1000^2, GB=1000^3, etc.
/// Also: b=512, KiB=1024, MiB=1024^2, etc.
pub fn parse_size(s: &str) -> Result<u64, String> {
    let s = s.trim();
    if s.is_empty() {
        return Err("empty size".to_string());
    }

    // Find where the numeric part ends
    let mut num_end = 0;
    for (i, c) in s.char_indices() {
        if c.is_ascii_digit() || (i == 0 && (c == '+' || c == '-')) {
            num_end = i + c.len_utf8();
        } else {
            break;
        }
    }

    if num_end == 0 {
        return Err(format!("invalid number: '{}'", s));
    }

    let num_str = &s[..num_end];
    let suffix = &s[num_end..];

    let num: u64 = num_str
        .parse()
        .map_err(|_| format!("invalid number: '{}'", num_str))?;

    let multiplier: u64 = match suffix {
        "" => 1,
        "b" => 512,
        "kB" | "KB" => 1000,
        "k" | "K" | "KiB" => 1024,
        "MB" => 1_000_000,
        "m" | "M" | "MiB" => 1_048_576,
        "GB" => 1_000_000_000,
        "g" | "G" | "GiB" => 1_073_741_824,
        "TB" => 1_000_000_000_000,
        "t" | "T" | "TiB" => 1_099_511_627_776,
        "PB" => 1_000_000_000_000_000,
        "p" | "P" | "PiB" => 1_125_899_906_842_624,
        "EB" => 1_000_000_000_000_000_000,
        "e" | "E" | "EiB" => 1_152_921_504_606_846_976,
        "ZB" | "z" | "Z" | "ZiB" | "YB" | "y" | "Y" | "YiB" => {
            if num > 0 {
                return Ok(u64::MAX);
            }
            return Ok(0);
        }
        _ => return Err(format!("invalid suffix in '{}'", s)),
    };

    num.checked_mul(multiplier)
        .ok_or_else(|| format!("number too large: '{}'", s))
}

/// Generate the suffix string for a given chunk index.
pub fn generate_suffix(index: u64, suffix_type: &SuffixType, suffix_length: usize) -> String {
    match suffix_type {
        SuffixType::Alphabetic => {
            let mut result = Vec::with_capacity(suffix_length);
            let mut remaining = index;
            for _ in 0..suffix_length {
                result.push(b'a' + (remaining % 26) as u8);
                remaining /= 26;
            }
            result.reverse();
            String::from_utf8(result).unwrap()
        }
        SuffixType::Numeric(start) => {
            let val = start + index;
            format!("{:0>width$}", val, width = suffix_length)
        }
        SuffixType::Hex(start) => {
            let val = start + index;
            format!("{:0>width$x}", val, width = suffix_length)
        }
    }
}

/// Compute the maximum number of chunks supported for a given suffix configuration.
pub fn max_chunks(suffix_type: &SuffixType, suffix_length: usize) -> u64 {
    match suffix_type {
        SuffixType::Alphabetic => 26u64.saturating_pow(suffix_length as u32),
        SuffixType::Numeric(_) | SuffixType::Hex(_) => 10u64.saturating_pow(suffix_length as u32),
    }
}

/// Build the output file path for a given chunk index.
fn output_path(config: &SplitConfig, index: u64) -> String {
    let suffix = generate_suffix(index, &config.suffix_type, config.suffix_length);
    format!("{}{}{}", config.prefix, suffix, config.additional_suffix)
}

/// Trait for output sinks: either a file or a filter command pipe.
trait ChunkWriter: Write {
    fn finish(&mut self) -> io::Result<()>;
}

/// Writes chunks to files on disk.
struct FileChunkWriter {
    writer: BufWriter<File>,
}

impl FileChunkWriter {
    fn create(path: &str) -> io::Result<Self> {
        let file = File::create(path)?;
        Ok(Self {
            writer: BufWriter::with_capacity(1024 * 1024, file), // 1MB output buffer
        })
    }
}

impl Write for FileChunkWriter {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        self.writer.write(buf)
    }

    fn flush(&mut self) -> io::Result<()> {
        self.writer.flush()
    }
}

impl ChunkWriter for FileChunkWriter {
    fn finish(&mut self) -> io::Result<()> {
        self.writer.flush()
    }
}

/// Writes chunks to a filter command via pipe.
struct FilterChunkWriter {
    child: std::process::Child,
    _stdin_taken: bool,
}

impl FilterChunkWriter {
    fn create(filter_cmd: &str, output_path: &str) -> io::Result<Self> {
        let child = Command::new("sh")
            .arg("-c")
            .arg(filter_cmd)
            .env("FILE", output_path)
            .stdin(Stdio::piped())
            .spawn()?;
        Ok(Self {
            child,
            _stdin_taken: false,
        })
    }
}

impl Write for FilterChunkWriter {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        if let Some(ref mut stdin) = self.child.stdin {
            stdin.write(buf)
        } else {
            Err(io::Error::new(io::ErrorKind::BrokenPipe, "stdin closed"))
        }
    }

    fn flush(&mut self) -> io::Result<()> {
        if let Some(ref mut stdin) = self.child.stdin {
            stdin.flush()
        } else {
            Ok(())
        }
    }
}

impl ChunkWriter for FilterChunkWriter {
    fn finish(&mut self) -> io::Result<()> {
        // Close stdin so the child can finish
        self.child.stdin.take();
        let status = self.child.wait()?;
        if !status.success() {
            return Err(io::Error::other(format!(
                "filter command exited with status {}",
                status
            )));
        }
        Ok(())
    }
}

/// Create a chunk writer for the given chunk index.
fn create_writer(config: &SplitConfig, index: u64) -> io::Result<Box<dyn ChunkWriter>> {
    let path = output_path(config, index);
    if config.verbose {
        eprintln!("creating file '{}'", path);
    }
    if let Some(ref filter_cmd) = config.filter {
        Ok(Box::new(FilterChunkWriter::create(filter_cmd, &path)?))
    } else {
        Ok(Box::new(FileChunkWriter::create(&path)?))
    }
}

/// Split input by line count.
/// Uses bulk memchr scanning to count lines within large buffer slices,
/// writing contiguous multi-line slices instead of copying line-by-line.
fn split_by_lines(
    reader: &mut dyn BufRead,
    config: &SplitConfig,
    lines_per_chunk: u64,
) -> io::Result<()> {
    let limit = max_chunks(&config.suffix_type, config.suffix_length);
    let mut chunk_index: u64 = 0;
    let mut lines_in_chunk: u64 = 0;
    let mut writer: Option<Box<dyn ChunkWriter>> = None;
    let sep = config.separator;

    loop {
        let available = match reader.fill_buf() {
            Ok([]) => break,
            Ok(b) => b,
            Err(ref e) if e.kind() == io::ErrorKind::Interrupted => continue,
            Err(e) => return Err(e),
        };

        let mut pos = 0;
        let buf_len = available.len();

        while pos < buf_len {
            if writer.is_none() {
                if chunk_index >= limit {
                    return Err(io::Error::other("output file suffixes exhausted"));
                }
                writer = Some(create_writer(config, chunk_index)?);
                lines_in_chunk = 0;
            }

            // How many lines left before we need a new chunk?
            let lines_needed = lines_per_chunk - lines_in_chunk;
            let slice = &available[pos..];

            // Use memchr_iter for bulk SIMD scanning — finds all separator
            // positions in one pass instead of N individual memchr calls.
            let mut found = 0u64;
            let mut last_sep_end = 0;

            for offset in memchr::memchr_iter(sep, slice) {
                found += 1;
                last_sep_end = offset + 1;
                if found >= lines_needed {
                    break;
                }
            }

            if found >= lines_needed {
                // We found enough lines - write the contiguous slice
                writer.as_mut().unwrap().write_all(&slice[..last_sep_end])?;
                pos += last_sep_end;
                // Close this chunk
                writer.as_mut().unwrap().finish()?;
                writer = None;
                chunk_index += 1;
            } else {
                // Not enough lines in this buffer - write everything and get more
                writer.as_mut().unwrap().write_all(slice)?;
                lines_in_chunk += found;
                pos = buf_len;
            }
        }

        let consumed = buf_len;
        reader.consume(consumed);
    }

    // Handle final partial chunk (data without trailing separator)
    if let Some(ref mut w) = writer {
        w.finish()?;
    }

    Ok(())
}

/// Split input by byte count.
fn split_by_bytes(
    reader: &mut dyn Read,
    config: &SplitConfig,
    bytes_per_chunk: u64,
) -> io::Result<()> {
    let limit = max_chunks(&config.suffix_type, config.suffix_length);
    let mut chunk_index: u64 = 0;
    let mut bytes_in_chunk: u64 = 0;
    let mut writer: Option<Box<dyn ChunkWriter>> = None;

    let mut read_buf = vec![0u8; 1024 * 1024]; // 1MB read buffer for fewer syscalls
    loop {
        let bytes_read = match reader.read(&mut read_buf) {
            Ok(0) => break,
            Ok(n) => n,
            Err(ref e) if e.kind() == io::ErrorKind::Interrupted => continue,
            Err(e) => return Err(e),
        };

        let mut offset = 0usize;
        while offset < bytes_read {
            if writer.is_none() {
                if chunk_index >= limit {
                    return Err(io::Error::other("output file suffixes exhausted"));
                }
                writer = Some(create_writer(config, chunk_index)?);
                bytes_in_chunk = 0;
            }

            let remaining_in_chunk = (bytes_per_chunk - bytes_in_chunk) as usize;
            let remaining_in_buf = bytes_read - offset;
            let to_write = remaining_in_chunk.min(remaining_in_buf);

            writer
                .as_mut()
                .unwrap()
                .write_all(&read_buf[offset..offset + to_write])?;
            bytes_in_chunk += to_write as u64;
            offset += to_write;

            if bytes_in_chunk >= bytes_per_chunk {
                writer.as_mut().unwrap().finish()?;
                writer = None;
                chunk_index += 1;
            }
        }
    }

    if let Some(ref mut w) = writer {
        if config.elide_empty && bytes_in_chunk == 0 {
            w.finish()?;
            // Remove the empty file
            let path = output_path(config, chunk_index);
            let _ = fs::remove_file(&path);
        } else {
            w.finish()?;
        }
    }

    Ok(())
}

/// Split input by line-bytes: at most N bytes per file, breaking at line boundaries.
/// GNU split uses a buffer-based approach: for each chunk-sized window, it finds
/// the last newline using memrchr and breaks there. When no newline exists within
/// the window (line longer than max_bytes), it breaks at the byte boundary.
fn split_by_line_bytes(
    reader: &mut dyn Read,
    config: &SplitConfig,
    max_bytes: u64,
) -> io::Result<()> {
    let limit = max_chunks(&config.suffix_type, config.suffix_length);
    let max = max_bytes as usize;
    let sep = config.separator;

    // Read all input data for simplicity (matches other modes)
    let mut data = Vec::new();
    reader.read_to_end(&mut data)?;

    if data.is_empty() {
        return Ok(());
    }

    let total = data.len();
    let mut chunk_index: u64 = 0;
    let mut offset = 0;

    while offset < total {
        if chunk_index >= limit {
            return Err(io::Error::other("output file suffixes exhausted"));
        }

        let remaining = total - offset;
        let window = remaining.min(max);
        let slice = &data[offset..offset + window];

        // Find the last separator in this window.
        // GNU split uses memrchr to find the last newline within the window,
        // breaking there. If no separator exists, write the full window.
        // When remaining data is strictly smaller than max_bytes, take everything
        // as the final chunk (matches GNU behavior).
        let end = if remaining < max {
            offset + window
        } else if let Some(pos) = memchr::memrchr(sep, slice) {
            // Break at the last separator within the window
            offset + pos + 1
        } else {
            // No separator found: write the full window (line > max_bytes)
            offset + window
        };

        let chunk_data = &data[offset..end];

        let mut writer = create_writer(config, chunk_index)?;
        writer.write_all(chunk_data)?;
        writer.finish()?;

        offset = end;
        chunk_index += 1;
    }

    Ok(())
}

/// Split input into exactly N chunks by byte count.
/// Reads the whole file to determine size, then distributes bytes evenly.
fn split_by_number(input_path: &str, config: &SplitConfig, n_chunks: u64) -> io::Result<()> {
    let limit = max_chunks(&config.suffix_type, config.suffix_length);
    if n_chunks > limit {
        return Err(io::Error::other("output file suffixes exhausted"));
    }
    if n_chunks == 0 {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "invalid number of chunks: 0",
        ));
    }

    // Read input data (mmap for regular files, read for stdin)
    let data: crate::common::io::FileData = if input_path == "-" {
        let mut buf = Vec::new();
        io::stdin().lock().read_to_end(&mut buf)?;
        crate::common::io::FileData::Owned(buf)
    } else {
        crate::common::io::read_file(Path::new(input_path))?
    };

    let total = data.len() as u64;
    let base_chunk_size = total / n_chunks;
    let remainder = total % n_chunks;

    let mut offset: u64 = 0;
    for i in 0..n_chunks {
        // First `remainder` chunks get one extra byte
        let chunk_size = base_chunk_size + if i < remainder { 1 } else { 0 };

        if config.elide_empty && chunk_size == 0 {
            continue;
        }

        let mut writer = create_writer(config, i)?;
        if chunk_size > 0 {
            let start = offset as usize;
            let end = start + chunk_size as usize;
            writer.write_all(&data[start..end])?;
        }
        writer.finish()?;
        offset += chunk_size;
    }

    Ok(())
}

/// Extract Kth chunk of N from input (K/N format). Output goes to stdout.
fn split_by_number_extract(input_path: &str, k: u64, n: u64) -> io::Result<()> {
    let data: crate::common::io::FileData = if input_path == "-" {
        let mut buf = Vec::new();
        io::stdin().lock().read_to_end(&mut buf)?;
        crate::common::io::FileData::Owned(buf)
    } else {
        crate::common::io::read_file(Path::new(input_path))?
    };

    let total = data.len() as u64;
    let base_chunk_size = total / n;
    let remainder = total % n;

    let mut offset: u64 = 0;
    for i in 0..n {
        let chunk_size = base_chunk_size + if i < remainder { 1 } else { 0 };
        if i + 1 == k {
            if chunk_size > 0 {
                let start = offset as usize;
                let end = start + chunk_size as usize;
                let stdout = io::stdout();
                let mut out = stdout.lock();
                out.write_all(&data[start..end])?;
            }
            return Ok(());
        }
        offset += chunk_size;
    }
    Ok(())
}

/// Read all input data into a buffer.
fn read_input_data(input_path: &str) -> io::Result<Vec<u8>> {
    if input_path == "-" {
        let mut buf = Vec::new();
        io::stdin().lock().read_to_end(&mut buf)?;
        Ok(buf)
    } else {
        let data = crate::common::io::read_file(Path::new(input_path))?;
        Ok(data.to_vec())
    }
}

/// Compute chunk boundary offsets for line-based N-way splitting.
/// GNU split distributes lines to chunks by reading sequentially:
/// each line goes to the current chunk until accumulated bytes reach
/// or exceed the chunk's target end boundary, then the chunk is closed.
fn compute_line_chunk_boundaries(data: &[u8], n_chunks: u64, sep: u8) -> Vec<u64> {
    let total = data.len() as u64;
    let base_chunk_size = total / n_chunks;
    let remainder = total % n_chunks;

    // Precompute target end boundaries for each chunk
    let mut boundaries = Vec::with_capacity(n_chunks as usize);
    let mut target_end: u64 = 0;
    for i in 0..n_chunks {
        target_end += base_chunk_size + if i < remainder { 1 } else { 0 };
        boundaries.push(target_end);
    }

    // Now read lines and assign to chunks
    let mut chunk_ends = Vec::with_capacity(n_chunks as usize);
    let mut pos: u64 = 0;
    let mut chunk_idx: u64 = 0;

    for sep_pos in memchr::memchr_iter(sep, data) {
        let line_end = sep_pos as u64 + 1; // inclusive of separator
        pos = line_end;

        // If we've reached or passed this chunk's target boundary, close it
        while chunk_idx < n_chunks && pos >= boundaries[chunk_idx as usize] {
            chunk_ends.push(pos);
            chunk_idx += 1;
        }
    }

    // Handle trailing data without separator
    if pos < total {
        pos = total;
        while chunk_idx < n_chunks && pos >= boundaries[chunk_idx as usize] {
            chunk_ends.push(pos);
            chunk_idx += 1;
        }
    }

    // Any remaining chunks get the same end position (at end of data or last line)
    while (chunk_ends.len() as u64) < n_chunks {
        chunk_ends.push(pos);
    }

    chunk_ends
}

/// Split into N output files by line count (l/N format).
fn split_by_line_chunks(input_path: &str, config: &SplitConfig, n_chunks: u64) -> io::Result<()> {
    let data = read_input_data(input_path)?;
    let sep = config.separator;

    let chunk_ends = compute_line_chunk_boundaries(&data, n_chunks, sep);

    let mut offset: u64 = 0;
    for i in 0..n_chunks {
        let end = chunk_ends[i as usize];
        let chunk_size = end - offset;

        if config.elide_empty && chunk_size == 0 {
            continue;
        }

        let mut writer = create_writer(config, i)?;
        if chunk_size > 0 {
            writer.write_all(&data[offset as usize..end as usize])?;
        }
        writer.finish()?;
        offset = end;
    }
    Ok(())
}

/// Extract Kth line-based chunk of N (l/K/N format). Output goes to stdout.
fn split_by_line_chunk_extract(
    input_path: &str,
    config: &SplitConfig,
    k: u64,
    n_chunks: u64,
) -> io::Result<()> {
    let data = read_input_data(input_path)?;
    let sep = config.separator;

    let chunk_ends = compute_line_chunk_boundaries(&data, n_chunks, sep);

    let mut offset: u64 = 0;
    for i in 0..n_chunks {
        let end = chunk_ends[i as usize];
        if i + 1 == k {
            let chunk_size = end - offset;
            if chunk_size > 0 {
                let stdout = io::stdout();
                let mut out = stdout.lock();
                out.write_all(&data[offset as usize..end as usize])?;
            }
            return Ok(());
        }
        offset = end;
    }
    Ok(())
}

/// Round-robin distribute lines across N output files (r/N format).
fn split_by_round_robin(input_path: &str, config: &SplitConfig, n_chunks: u64) -> io::Result<()> {
    let data = read_input_data(input_path)?;
    let sep = config.separator;

    // Collect lines
    let mut lines: Vec<&[u8]> = Vec::new();
    let mut start = 0;
    for pos in memchr::memchr_iter(sep, &data) {
        lines.push(&data[start..=pos]);
        start = pos + 1;
    }
    if start < data.len() {
        lines.push(&data[start..]);
    }

    // Create writers for each chunk
    let mut writers: Vec<Option<Box<dyn ChunkWriter>>> = (0..n_chunks)
        .map(|i| {
            if config.elide_empty && lines.len() as u64 <= i {
                None
            } else {
                Some(create_writer(config, i).unwrap())
            }
        })
        .collect();

    // Distribute lines round-robin
    for (idx, line) in lines.iter().enumerate() {
        let chunk_idx = (idx as u64) % n_chunks;
        if let Some(ref mut writer) = writers[chunk_idx as usize] {
            writer.write_all(line)?;
        }
    }

    // Finish all writers
    for writer in &mut writers {
        if let Some(mut w) = writer.take() {
            w.finish()?;
        }
    }

    Ok(())
}

/// Extract Kth round-robin chunk of N (r/K/N format). Output goes to stdout.
fn split_by_round_robin_extract(input_path: &str, k: u64, n: u64) -> io::Result<()> {
    let data = read_input_data(input_path)?;
    let sep = b'\n';

    let stdout = io::stdout();
    let mut out = stdout.lock();

    let mut start = 0;
    let mut line_idx: u64 = 0;
    for pos in memchr::memchr_iter(sep, &data) {
        if line_idx % n == k - 1 {
            out.write_all(&data[start..=pos])?;
        }
        start = pos + 1;
        line_idx += 1;
    }
    if start < data.len() && line_idx % n == k - 1 {
        out.write_all(&data[start..])?;
    }

    Ok(())
}

/// Fast pre-loaded line splitting: scans mmap/buffer for line boundaries,
/// then uses copy_file_range on Linux (zero-copy) or write_all on other platforms.
/// Uses parallel file creation for many chunks to amortize rayon overhead.
#[cfg(unix)]
fn split_lines_preloaded(
    data: &[u8],
    config: &SplitConfig,
    lines_per_chunk: u64,
    #[cfg(target_os = "linux")] input_fd: Option<std::os::unix::io::RawFd>,
) -> io::Result<()> {
    let limit = max_chunks(&config.suffix_type, config.suffix_length);
    let sep = config.separator;

    // First pass: compute chunk boundaries (start, end) without I/O
    let mut chunks: Vec<(usize, usize)> = Vec::new();
    let mut chunk_start: usize = 0;
    let mut lines_in_chunk: u64 = 0;

    for offset in memchr::memchr_iter(sep, data) {
        lines_in_chunk += 1;
        if lines_in_chunk >= lines_per_chunk {
            let chunk_end = offset + 1;
            if chunks.len() as u64 >= limit {
                return Err(io::Error::other("output file suffixes exhausted"));
            }
            chunks.push((chunk_start, chunk_end));
            chunk_start = chunk_end;
            lines_in_chunk = 0;
        }
    }

    // Remaining data (partial chunk)
    if chunk_start < data.len() {
        if chunks.len() as u64 >= limit {
            return Err(io::Error::other("output file suffixes exhausted"));
        }
        chunks.push((chunk_start, data.len()));
    }

    if chunks.is_empty() {
        return Ok(());
    }

    // Pre-compute all output paths
    let paths: Vec<String> = chunks
        .iter()
        .enumerate()
        .map(|(i, _)| output_path(config, i as u64))
        .collect();

    if config.verbose {
        for path in &paths {
            eprintln!("creating file '{}'", path);
        }
    }

    // On Linux with a file fd, use copy_file_range for zero-copy output
    #[cfg(target_os = "linux")]
    if let Some(in_fd) = input_fd {
        use std::os::unix::io::AsRawFd;

        let write_chunk =
            |in_fd: i32, chunk_off: usize, chunk_len: usize, path: &str| -> io::Result<()> {
                let out_file = File::create(path)?;
                let out_fd = out_file.as_raw_fd();
                unsafe { libc::fallocate(out_fd, 0, 0, chunk_len as libc::off_t) };

                let mut off_in = chunk_off as i64;
                let mut copied = 0usize;
                while copied < chunk_len {
                    let n = unsafe {
                        libc::copy_file_range(
                            in_fd,
                            &mut off_in as *mut i64 as *mut libc::off64_t,
                            out_fd,
                            std::ptr::null_mut(),
                            chunk_len - copied,
                            0,
                        )
                    };
                    if n > 0 {
                        copied += n as usize;
                    } else if n == 0 {
                        break;
                    } else {
                        let err = io::Error::last_os_error();
                        if err.raw_os_error() == Some(libc::EINTR) {
                            continue;
                        }
                        // Fallback to write_all from mmap
                        let out_file2 =
                            unsafe { std::os::unix::io::FromRawFd::from_raw_fd(out_fd) };
                        let mut f: File = out_file2;
                        f.write_all(&data[chunk_off + copied..chunk_off + chunk_len])?;
                        std::mem::forget(f); // Don't double-close
                        break;
                    }
                }
                Ok(())
            };

        if chunks.len() >= 64 && !config.verbose {
            chunks
                .par_iter()
                .zip(paths.par_iter())
                .try_for_each(|(&(start, end), path)| {
                    write_chunk(in_fd, start, end - start, path)
                })?;
        } else {
            for (i, &(start, end)) in chunks.iter().enumerate() {
                write_chunk(in_fd, start, end - start, &paths[i])?;
            }
        }
        return Ok(());
    }

    // Fallback: write from mmap/buffer data
    if chunks.len() >= 64 && !config.verbose {
        chunks.par_iter().zip(paths.par_iter()).try_for_each(
            |(&(start, end), path)| -> io::Result<()> {
                let mut file = File::create(path)?;
                file.write_all(&data[start..end])?;
                Ok(())
            },
        )?;
    } else {
        for (i, &(start, end)) in chunks.iter().enumerate() {
            let mut file = File::create(&paths[i])?;
            file.write_all(&data[start..end])?;
        }
    }

    Ok(())
}

/// Zero-copy byte splitting using copy_file_range. Data moves kernel-to-kernel
/// without entering userspace. Falls back to sendfile, then read/write.
/// Parallelizes across chunks when there are enough to amortize rayon overhead.
#[cfg(target_os = "linux")]
fn split_bytes_zero_copy(
    input_fd: std::os::unix::io::RawFd,
    file_size: u64,
    config: &SplitConfig,
    bytes_per_chunk: u64,
) -> io::Result<()> {
    use std::os::unix::io::AsRawFd;
    let limit = max_chunks(&config.suffix_type, config.suffix_length);
    let chunk_size = bytes_per_chunk as usize;
    let total = file_size as usize;

    // Pre-compute chunk boundaries: (offset, size)
    let mut chunks: Vec<(usize, usize)> = Vec::new();
    let mut off = 0usize;
    while off < total {
        if chunks.len() as u64 >= limit {
            return Err(io::Error::other("output file suffixes exhausted"));
        }
        let remaining = total - off;
        let sz = remaining.min(chunk_size);
        chunks.push((off, sz));
        off += sz;
    }

    if chunks.is_empty() {
        return Ok(());
    }

    // Pre-compute output paths
    let paths: Vec<String> = (0..chunks.len())
        .map(|i| output_path(config, i as u64))
        .collect();

    if config.verbose {
        for path in &paths {
            eprintln!("creating file '{}'", path);
        }
    }

    // Helper: copy one chunk using copy_file_range with fallback to sendfile
    let copy_chunk =
        |input_fd: i32, chunk_offset: usize, chunk_len: usize, path: &str| -> io::Result<()> {
            let out_file = File::create(path)?;
            let out_fd = out_file.as_raw_fd();

            // Pre-allocate output file to avoid block allocation during write
            unsafe { libc::fallocate(out_fd, 0, 0, chunk_len as libc::off_t) };

            let mut off_in = chunk_offset as i64;
            let mut copied = 0usize;
            while copied < chunk_len {
                let n = unsafe {
                    libc::copy_file_range(
                        input_fd,
                        &mut off_in as *mut i64 as *mut libc::off64_t,
                        out_fd,
                        std::ptr::null_mut(),
                        chunk_len - copied,
                        0,
                    )
                };
                if n > 0 {
                    copied += n as usize;
                } else if n == 0 {
                    break;
                } else {
                    let err = io::Error::last_os_error();
                    if err.raw_os_error() == Some(libc::EINTR) {
                        continue;
                    }
                    // Fallback to sendfile
                    while copied < chunk_len {
                        let n = unsafe {
                            libc::sendfile(
                                out_fd,
                                input_fd,
                                &mut off_in as *mut i64 as *mut libc::off_t,
                                chunk_len - copied,
                            )
                        };
                        if n > 0 {
                            copied += n as usize;
                        } else if n == 0 {
                            break;
                        } else {
                            let err2 = io::Error::last_os_error();
                            if err2.raw_os_error() == Some(libc::EINTR) {
                                continue;
                            }
                            return Err(err2);
                        }
                    }
                    break;
                }
            }
            Ok(())
        };

    // Parallel file creation for many chunks (rayon overhead ~1ms, amortized at ≥64 chunks)
    if chunks.len() >= 64 && !config.verbose {
        chunks.par_iter().zip(paths.par_iter()).try_for_each(
            |(&(chunk_off, chunk_len), path)| copy_chunk(input_fd, chunk_off, chunk_len, path),
        )?;
    } else {
        for (i, &(chunk_off, chunk_len)) in chunks.iter().enumerate() {
            copy_chunk(input_fd, chunk_off, chunk_len, &paths[i])?;
        }
    }

    Ok(())
}

/// Fast pre-loaded byte splitting: writes each chunk directly from mmap data
/// with a single write_all() per output file (no BufWriter needed).
/// Uses parallel writes when there are enough chunks (≥16) to amortize rayon overhead.
#[cfg(all(unix, not(target_os = "linux")))]
fn split_bytes_preloaded(
    data: &[u8],
    config: &SplitConfig,
    bytes_per_chunk: u64,
) -> io::Result<()> {
    let limit = max_chunks(&config.suffix_type, config.suffix_length);
    let chunk_size = bytes_per_chunk as usize;

    // Compute chunk boundaries
    let mut chunks: Vec<(usize, usize)> = Vec::new();
    let mut offset = 0;
    while offset < data.len() {
        if chunks.len() as u64 >= limit {
            return Err(io::Error::other("output file suffixes exhausted"));
        }
        let end = (offset + chunk_size).min(data.len());
        chunks.push((offset, end));
        offset = end;
    }

    if chunks.is_empty() {
        return Ok(());
    }

    // Pre-compute all output paths
    let paths: Vec<String> = chunks
        .iter()
        .enumerate()
        .map(|(i, _)| output_path(config, i as u64))
        .collect();

    if config.verbose {
        for path in &paths {
            eprintln!("creating file '{}'", path);
        }
    }

    // Parallel write: each chunk is independent, write them concurrently
    if chunks.len() >= 4 && !config.verbose {
        chunks.par_iter().zip(paths.par_iter()).try_for_each(
            |(&(start, end), path)| -> io::Result<()> {
                let mut file = File::create(path)?;
                file.write_all(&data[start..end])?;
                Ok(())
            },
        )?;
    } else {
        for (i, &(start, end)) in chunks.iter().enumerate() {
            let mut file = File::create(&paths[i])?;
            file.write_all(&data[start..end])?;
        }
    }

    Ok(())
}

/// Fast pre-loaded line-bytes splitting: mmap + memrchr for separator-aware chunking.
#[cfg(unix)]
fn split_line_bytes_preloaded(data: &[u8], config: &SplitConfig, max_bytes: u64) -> io::Result<()> {
    let limit = max_chunks(&config.suffix_type, config.suffix_length);
    let max = max_bytes as usize;
    let sep = config.separator;

    let mut chunks: Vec<(usize, usize)> = Vec::new();
    let mut offset = 0;

    while offset < data.len() {
        if chunks.len() as u64 >= limit {
            return Err(io::Error::other("output file suffixes exhausted"));
        }
        let remaining = data.len() - offset;
        let window = remaining.min(max);
        let slice = &data[offset..offset + window];

        let end = if remaining < max {
            // Final chunk: take everything (matches GNU behavior)
            offset + window
        } else if let Some(pos) = memchr::memrchr(sep, slice) {
            offset + pos + 1
        } else {
            offset + window
        };

        chunks.push((offset, end));
        offset = end;
    }

    if chunks.is_empty() {
        return Ok(());
    }

    let paths: Vec<String> = chunks
        .iter()
        .enumerate()
        .map(|(i, _)| output_path(config, i as u64))
        .collect();

    if config.verbose {
        for path in &paths {
            eprintln!("creating file '{}'", path);
        }
    }

    if chunks.len() >= 4 && !config.verbose {
        chunks.par_iter().zip(paths.par_iter()).try_for_each(
            |(&(start, end), path)| -> io::Result<()> {
                let mut file = File::create(path)?;
                file.write_all(&data[start..end])?;
                Ok(())
            },
        )?;
    } else {
        for (i, &(start, end)) in chunks.iter().enumerate() {
            let mut file = File::create(&paths[i])?;
            file.write_all(&data[start..end])?;
        }
    }

    Ok(())
}

/// Main entry point: split a file according to the given configuration.
/// `input_path` is the path to the input file, or "-" for stdin.
pub fn split_file(input_path: &str, config: &SplitConfig) -> io::Result<()> {
    // For number-based splitting, we need to read the whole file to know size.
    if let SplitMode::Number(n) = config.mode {
        return split_by_number(input_path, config, n);
    }
    if let SplitMode::NumberExtract(k, n) = config.mode {
        return split_by_number_extract(input_path, k, n);
    }
    if let SplitMode::LineChunks(n) = config.mode {
        return split_by_line_chunks(input_path, config, n);
    }
    if let SplitMode::LineChunkExtract(k, n) = config.mode {
        return split_by_line_chunk_extract(input_path, config, k, n);
    }
    if let SplitMode::RoundRobin(n) = config.mode {
        return split_by_round_robin(input_path, config, n);
    }
    if let SplitMode::RoundRobinExtract(k, n) = config.mode {
        return split_by_round_robin_extract(input_path, k, n);
    }

    // Fast path: mmap+memchr line splitting for regular files (no filter).
    // Scans mmap for line boundaries, then uses copy_file_range (Linux) or
    // write_all (other platforms) for zero-copy output.
    #[cfg(unix)]
    if let SplitMode::Lines(n) = config.mode {
        if input_path != "-" && config.filter.is_none() {
            const FAST_PATH_LIMIT: u64 = 512 * 1024 * 1024;
            if let Ok(file) = File::open(input_path) {
                if let Ok(meta) = file.metadata() {
                    if meta.file_type().is_file() && meta.len() <= FAST_PATH_LIMIT && meta.len() > 0
                    {
                        // Use mmap for zero-copy scanning of line boundaries
                        if let Ok(mmap) = unsafe { memmap2::MmapOptions::new().map(&file) } {
                            let _ = mmap.advise(memmap2::Advice::Sequential);
                            #[cfg(target_os = "linux")]
                            {
                                let _ = mmap.advise(memmap2::Advice::WillNeed);
                            }
                            #[cfg(not(target_os = "linux"))]
                            {
                                let _ = mmap.advise(memmap2::Advice::WillNeed);
                            }
                            #[cfg(target_os = "linux")]
                            {
                                use std::os::unix::io::AsRawFd;
                                return split_lines_preloaded(
                                    &mmap,
                                    config,
                                    n,
                                    Some(file.as_raw_fd()),
                                );
                            }
                            #[cfg(not(target_os = "linux"))]
                            {
                                return split_lines_preloaded(&mmap, config, n);
                            }
                        }
                        // Fallback: read into Vec
                        let len = meta.len() as usize;
                        let mut buf = vec![0u8; len];
                        let mut total = 0;
                        let mut f = &file;
                        while total < buf.len() {
                            match f.read(&mut buf[total..]) {
                                Ok(0) => break,
                                Ok(n) => total += n,
                                Err(ref e) if e.kind() == io::ErrorKind::Interrupted => {
                                    continue;
                                }
                                Err(e) => return Err(e),
                            }
                        }
                        buf.truncate(total);
                        #[cfg(target_os = "linux")]
                        {
                            return split_lines_preloaded(&buf, config, n, None);
                        }
                        #[cfg(not(target_os = "linux"))]
                        {
                            return split_lines_preloaded(&buf, config, n);
                        }
                    }
                }
            }
        }
    }

    // Fast path: zero-copy byte splitting for regular files on Linux.
    // Uses copy_file_range to move data kernel-to-kernel without userspace copies.
    #[cfg(target_os = "linux")]
    if let SplitMode::Bytes(bytes_per_chunk) = config.mode {
        if input_path != "-" && config.filter.is_none() {
            if let Ok(file) = File::open(input_path) {
                if let Ok(meta) = file.metadata() {
                    if meta.file_type().is_file() && meta.len() > 0 {
                        use std::os::unix::io::AsRawFd;
                        unsafe {
                            libc::posix_fadvise(
                                file.as_raw_fd(),
                                0,
                                0,
                                libc::POSIX_FADV_SEQUENTIAL,
                            );
                        }
                        return split_bytes_zero_copy(
                            file.as_raw_fd(),
                            meta.len(),
                            config,
                            bytes_per_chunk,
                        );
                    }
                }
            }
        }
    }

    // Fast path: mmap-based byte splitting for regular files (no filter).
    // Writes each chunk directly from the mmap with a single write_all() call.
    #[cfg(all(unix, not(target_os = "linux")))]
    if let SplitMode::Bytes(bytes_per_chunk) = config.mode {
        if input_path != "-" && config.filter.is_none() {
            const FAST_PATH_LIMIT: u64 = 512 * 1024 * 1024;
            if let Ok(file) = File::open(input_path) {
                if let Ok(meta) = file.metadata() {
                    if meta.file_type().is_file() && meta.len() <= FAST_PATH_LIMIT && meta.len() > 0
                    {
                        if let Ok(mmap) = unsafe { memmap2::MmapOptions::new().map(&file) } {
                            let _ = mmap.advise(memmap2::Advice::Sequential);
                            #[cfg(not(target_os = "linux"))]
                            {
                                let _ = mmap.advise(memmap2::Advice::WillNeed);
                            }
                            return split_bytes_preloaded(&mmap, config, bytes_per_chunk);
                        }
                    }
                }
            }
        }
    }

    // Fast path: mmap-based line-bytes splitting for regular files (no filter).
    #[cfg(unix)]
    if let SplitMode::LineBytes(max_bytes) = config.mode {
        if input_path != "-" && config.filter.is_none() {
            const FAST_PATH_LIMIT: u64 = 512 * 1024 * 1024;
            if let Ok(file) = File::open(input_path) {
                if let Ok(meta) = file.metadata() {
                    if meta.file_type().is_file() && meta.len() <= FAST_PATH_LIMIT && meta.len() > 0
                    {
                        if let Ok(mmap) = unsafe { memmap2::MmapOptions::new().map(&file) } {
                            let _ = mmap.advise(memmap2::Advice::Sequential);
                            #[cfg(target_os = "linux")]
                            {
                                let len = mmap.len();
                                if len >= 2 * 1024 * 1024 {
                                    let _ = mmap.advise(memmap2::Advice::HugePage);
                                }
                                if len >= 4 * 1024 * 1024 {
                                    if mmap.advise(memmap2::Advice::PopulateRead).is_err() {
                                        let _ = mmap.advise(memmap2::Advice::WillNeed);
                                    }
                                } else {
                                    let _ = mmap.advise(memmap2::Advice::WillNeed);
                                }
                            }
                            #[cfg(not(target_os = "linux"))]
                            {
                                let _ = mmap.advise(memmap2::Advice::WillNeed);
                            }
                            return split_line_bytes_preloaded(&mmap, config, max_bytes);
                        }
                    }
                }
            }
        }
    }

    // Open input
    let reader: Box<dyn Read> = if input_path == "-" {
        Box::new(io::stdin().lock())
    } else {
        let path = Path::new(input_path);
        if !path.exists() {
            return Err(io::Error::new(
                io::ErrorKind::NotFound,
                format!(
                    "cannot open '{}' for reading: No such file or directory",
                    input_path
                ),
            ));
        }
        let file = File::open(path)?;
        // Hint kernel to readahead sequentially for better I/O throughput
        #[cfg(target_os = "linux")]
        {
            use std::os::unix::io::AsRawFd;
            unsafe {
                libc::posix_fadvise(file.as_raw_fd(), 0, 0, libc::POSIX_FADV_SEQUENTIAL);
            }
        }
        Box::new(file)
    };

    match config.mode {
        SplitMode::Lines(n) => {
            let mut buf_reader = BufReader::with_capacity(1024 * 1024, reader);
            split_by_lines(&mut buf_reader, config, n)
        }
        SplitMode::Bytes(n) => {
            let mut reader = reader;
            split_by_bytes(&mut reader, config, n)
        }
        SplitMode::LineBytes(n) => {
            let mut reader = reader;
            split_by_line_bytes(&mut reader, config, n)
        }
        SplitMode::Number(_)
        | SplitMode::NumberExtract(_, _)
        | SplitMode::LineChunks(_)
        | SplitMode::LineChunkExtract(_, _)
        | SplitMode::RoundRobin(_)
        | SplitMode::RoundRobinExtract(_, _) => unreachable!(),
    }
}

/// Get the list of output file paths that would be generated for given config and chunk count.
pub fn output_paths(config: &SplitConfig, count: u64) -> Vec<PathBuf> {
    (0..count)
        .map(|i| PathBuf::from(output_path(config, i)))
        .collect()
}
