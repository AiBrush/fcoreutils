// fcksum — compute POSIX CRC-32 checksum and byte count (GNU cksum replacement)

use std::io::{self, BufRead, Read, Write};
use std::process;

const TOOL_NAME: &str = "cksum";
const VERSION: &str = env!("CARGO_PKG_VERSION");

/// POSIX CRC-32 slicing-by-8 lookup tables using polynomial 0x04C11DB7.
/// Table 0 is the standard byte-at-a-time table; tables 1-7 enable processing
/// 8 bytes per iteration, breaking the data dependency chain for ~2x throughput
/// over slice-by-4 (matches GNU cksum's software CRC algorithm).
const CRC_TABLES: [[u32; 256]; 8] = {
    let mut tables = [[0u32; 256]; 8];
    // Build the base table (table 0)
    let mut i = 0u32;
    while i < 256 {
        let mut crc = i << 24;
        let mut j = 0;
        while j < 8 {
            if crc & 0x8000_0000 != 0 {
                crc = (crc << 1) ^ 0x04C1_1DB7;
            } else {
                crc <<= 1;
            }
            j += 1;
        }
        tables[0][i as usize] = crc;
        i += 1;
    }
    // Build extended tables for slicing-by-8
    let mut t = 1;
    while t < 8 {
        let mut i = 0;
        while i < 256 {
            let prev = tables[t - 1][i];
            tables[t][i] = (prev << 8) ^ tables[0][(prev >> 24) as usize];
            i += 1;
        }
        t += 1;
    }
    tables
};

/// Backward-compatible alias for tests that reference CRC_TABLE
#[cfg(test)]
const CRC_TABLE: [u32; 256] = CRC_TABLES[0];

/// Compute the POSIX CRC-32 checksum using slicing-by-8 for high throughput.
/// Processes 8 bytes per iteration in the main loop, breaking the data dependency
/// chain across two u32 words for ~2x throughput over slice-by-4.
#[cfg(test)]
fn posix_cksum(data: &[u8]) -> u32 {
    let mut crc: u32 = 0;

    // Slicing-by-8: process 8 bytes per iteration
    let chunks = data.chunks_exact(8);
    let remainder = chunks.remainder();

    for chunk in chunks {
        crc = CRC_TABLES[7][((crc >> 24) ^ u32::from(chunk[0])) as usize]
            ^ CRC_TABLES[6][((crc >> 16) as u8 ^ chunk[1]) as usize]
            ^ CRC_TABLES[5][((crc >> 8) as u8 ^ chunk[2]) as usize]
            ^ CRC_TABLES[4][(crc as u8 ^ chunk[3]) as usize]
            ^ CRC_TABLES[3][chunk[4] as usize]
            ^ CRC_TABLES[2][chunk[5] as usize]
            ^ CRC_TABLES[1][chunk[6] as usize]
            ^ CRC_TABLES[0][chunk[7] as usize];
    }

    // Process remaining 0-7 bytes one at a time
    for &byte in remainder {
        crc = (crc << 8) ^ CRC_TABLES[0][((crc >> 24) ^ u32::from(byte)) as usize];
    }

    // Feed length bytes (big-endian, only the significant bytes)
    let mut len = data.len() as u64;
    while len > 0 {
        crc = (crc << 8) ^ CRC_TABLES[0][((crc >> 24) ^ (len & 0xFF) as u32) as usize];
        len >>= 8;
    }

    !crc
}

/// PCLMUL-accelerated POSIX CRC-32 for x86_64 with SSE4.1+PCLMULQDQ+SSSE3.
/// Uses carryless multiplication to fold 64 bytes per iteration (4x parallel),
/// matching GNU cksum's cksum_pclmul.c algorithm from the Intel whitepaper
/// "Fast CRC Computation for Generic Polynomials Using PCLMULQDQ Instruction".
#[cfg(target_arch = "x86_64")]
#[target_feature(enable = "sse2,ssse3,pclmulqdq")]
unsafe fn cksum_pclmul_chunk(buf: &mut [u8], mut crc: u32) -> u32 {
    unsafe {
        use core::arch::x86_64::*;

        // Constants from Intel whitepaper for POSIX CRC polynomial 0x04C11DB7
        let single_mult = _mm_set_epi64x(0xC5B9CD4Cu64 as i64, 0xE8A45605u64 as i64);
        let four_mult = _mm_set_epi64x(0x8833794Cu64 as i64, 0xE6228B11u64 as i64);
        // Byte-reverse constant (POSIX CRC is big-endian, SSE is little-endian)
        let shuffle = _mm_set_epi8(0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15);

        let ptr = buf.as_mut_ptr();
        let mut pos: usize = 0;
        let len = buf.len();

        // Phase 1: Four-way parallel fold (processes 64 bytes per iteration)
        if len >= 128 {
            let mut data = _mm_shuffle_epi8(_mm_loadu_si128(ptr as *const __m128i), shuffle);
            let xor_crc = _mm_set_epi32(crc as i32, 0, 0, 0);
            crc = 0;
            data = _mm_xor_si128(data, xor_crc);
            let mut data3 =
                _mm_shuffle_epi8(_mm_loadu_si128(ptr.add(16) as *const __m128i), shuffle);
            let mut data5 =
                _mm_shuffle_epi8(_mm_loadu_si128(ptr.add(32) as *const __m128i), shuffle);
            let mut data7 =
                _mm_shuffle_epi8(_mm_loadu_si128(ptr.add(48) as *const __m128i), shuffle);

            pos = 64;
            let mut remaining = len;

            while remaining >= 128 {
                let data2 = _mm_clmulepi64_si128(data, four_mult, 0x00);
                data = _mm_clmulepi64_si128(data, four_mult, 0x11);
                let data4 = _mm_clmulepi64_si128(data3, four_mult, 0x00);
                data3 = _mm_clmulepi64_si128(data3, four_mult, 0x11);
                let data6 = _mm_clmulepi64_si128(data5, four_mult, 0x00);
                data5 = _mm_clmulepi64_si128(data5, four_mult, 0x11);
                let data8 = _mm_clmulepi64_si128(data7, four_mult, 0x00);
                data7 = _mm_clmulepi64_si128(data7, four_mult, 0x11);

                data = _mm_xor_si128(data, data2);
                data = _mm_xor_si128(
                    data,
                    _mm_shuffle_epi8(_mm_loadu_si128(ptr.add(pos) as *const __m128i), shuffle),
                );
                data3 = _mm_xor_si128(data3, data4);
                data3 = _mm_xor_si128(
                    data3,
                    _mm_shuffle_epi8(
                        _mm_loadu_si128(ptr.add(pos + 16) as *const __m128i),
                        shuffle,
                    ),
                );
                data5 = _mm_xor_si128(data5, data6);
                data5 = _mm_xor_si128(
                    data5,
                    _mm_shuffle_epi8(
                        _mm_loadu_si128(ptr.add(pos + 32) as *const __m128i),
                        shuffle,
                    ),
                );
                data7 = _mm_xor_si128(data7, data8);
                data7 = _mm_xor_si128(
                    data7,
                    _mm_shuffle_epi8(
                        _mm_loadu_si128(ptr.add(pos + 48) as *const __m128i),
                        shuffle,
                    ),
                );

                pos += 64;
                remaining -= 64;
            }

            // Store folded results back into buffer (byte-swapped to native order)
            let store_pos = pos - 64;
            _mm_storeu_si128(
                ptr.add(store_pos) as *mut __m128i,
                _mm_shuffle_epi8(data, shuffle),
            );
            _mm_storeu_si128(
                ptr.add(store_pos + 16) as *mut __m128i,
                _mm_shuffle_epi8(data3, shuffle),
            );
            _mm_storeu_si128(
                ptr.add(store_pos + 32) as *mut __m128i,
                _mm_shuffle_epi8(data5, shuffle),
            );
            _mm_storeu_si128(
                ptr.add(store_pos + 48) as *mut __m128i,
                _mm_shuffle_epi8(data7, shuffle),
            );
            pos = store_pos;
        }

        // Phase 2: Single fold (processes 16 bytes per iteration)
        let remaining = len - pos;
        if remaining >= 32 {
            let mut data =
                _mm_shuffle_epi8(_mm_loadu_si128(ptr.add(pos) as *const __m128i), shuffle);
            let xor_crc = _mm_set_epi32(crc as i32, 0, 0, 0);
            crc = 0;
            data = _mm_xor_si128(data, xor_crc);
            pos += 16;

            let mut rem = len - pos;
            while rem >= 16 {
                let data2 = _mm_clmulepi64_si128(data, single_mult, 0x00);
                data = _mm_clmulepi64_si128(data, single_mult, 0x11);
                let fold_data =
                    _mm_shuffle_epi8(_mm_loadu_si128(ptr.add(pos) as *const __m128i), shuffle);
                data = _mm_xor_si128(data, data2);
                data = _mm_xor_si128(data, fold_data);
                pos += 16;
                rem -= 16;
            }

            // Store back (byte-swapped)
            _mm_storeu_si128(
                ptr.add(pos - 16) as *mut __m128i,
                _mm_shuffle_epi8(data, shuffle),
            );
            pos -= 16;
        }

        // Phase 3: Byte-by-byte for remaining 0-31 bytes
        for i in pos..len {
            crc = (crc << 8) ^ CRC_TABLES[0][((crc >> 24) ^ u32::from(buf[i])) as usize];
        }

        crc
    } // unsafe
}

/// Read as many bytes as possible into buf, retrying on EINTR.
#[cfg(target_arch = "x86_64")]
fn read_full<R: Read>(reader: &mut R, buf: &mut [u8]) -> io::Result<usize> {
    let mut total = 0;
    while total < buf.len() {
        match reader.read(&mut buf[total..]) {
            Ok(0) => break,
            Ok(n) => total += n,
            Err(e) if e.kind() == io::ErrorKind::Interrupted => continue,
            Err(e) => return Err(e),
        }
    }
    Ok(total)
}

/// PCLMUL-accelerated streaming CRC. Uses 64KB buffer matching GNU cksum.
#[cfg(target_arch = "x86_64")]
fn posix_cksum_streaming_pclmul<R: Read>(mut reader: R) -> io::Result<(u32, u64)> {
    const BUFLEN: usize = 1 << 16; // 64KB
    let mut buf = vec![0u8; BUFLEN];
    let mut crc: u32 = 0;
    let mut total_bytes: u64 = 0;

    loop {
        let n = read_full(&mut reader, &mut buf)?;
        if n == 0 {
            break;
        }
        total_bytes += n as u64;
        crc = unsafe { cksum_pclmul_chunk(&mut buf[..n], crc) };
    }

    // Feed length bytes
    let mut len = total_bytes;
    while len > 0 {
        crc = (crc << 8) ^ CRC_TABLES[0][((crc >> 24) ^ (len & 0xFF) as u32) as usize];
        len >>= 8;
    }

    Ok((!crc, total_bytes))
}

/// Streaming POSIX CRC-32: process data from a reader without loading everything into memory.
/// Uses slicing-by-8 table-based algorithm as fallback when PCLMUL is unavailable.
fn posix_cksum_streaming_table<R: Read>(reader: R) -> io::Result<(u32, u64)> {
    let mut reader = io::BufReader::with_capacity(8 * 1024 * 1024, reader);
    let mut crc: u32 = 0;
    let mut total_bytes: u64 = 0;

    loop {
        let buf = reader.fill_buf()?;
        if buf.is_empty() {
            break;
        }
        let n = buf.len();
        total_bytes += n as u64;

        // Slicing-by-8 on the buffer
        let chunks = buf.chunks_exact(8);
        let remainder = chunks.remainder();

        for chunk in chunks {
            crc = CRC_TABLES[7][((crc >> 24) ^ u32::from(chunk[0])) as usize]
                ^ CRC_TABLES[6][((crc >> 16) as u8 ^ chunk[1]) as usize]
                ^ CRC_TABLES[5][((crc >> 8) as u8 ^ chunk[2]) as usize]
                ^ CRC_TABLES[4][(crc as u8 ^ chunk[3]) as usize]
                ^ CRC_TABLES[3][chunk[4] as usize]
                ^ CRC_TABLES[2][chunk[5] as usize]
                ^ CRC_TABLES[1][chunk[6] as usize]
                ^ CRC_TABLES[0][chunk[7] as usize];
        }
        for &byte in remainder {
            crc = (crc << 8) ^ CRC_TABLES[0][((crc >> 24) ^ u32::from(byte)) as usize];
        }

        reader.consume(n);
    }

    // Feed length bytes
    let mut len = total_bytes;
    while len > 0 {
        crc = (crc << 8) ^ CRC_TABLES[0][((crc >> 24) ^ (len & 0xFF) as u32) as usize];
        len >>= 8;
    }

    Ok((!crc, total_bytes))
}

/// Streaming POSIX CRC-32 with runtime dispatch to PCLMUL or table-based path.
fn posix_cksum_streaming<R: Read>(reader: R) -> io::Result<(u32, u64)> {
    #[cfg(target_arch = "x86_64")]
    {
        if is_x86_feature_detected!("pclmulqdq") && is_x86_feature_detected!("ssse3") {
            return posix_cksum_streaming_pclmul(reader);
        }
    }
    posix_cksum_streaming_table(reader)
}

struct Cli {
    files: Vec<String>,
}

fn parse_args() -> Cli {
    let mut cli = Cli { files: Vec::new() };

    let mut args = std::env::args_os().skip(1);
    #[allow(clippy::while_let_on_iterator)]
    while let Some(arg) = args.next() {
        let bytes = arg.as_encoded_bytes();
        if bytes == b"--" {
            for f in args.by_ref() {
                cli.files.push(f.to_string_lossy().into_owned());
            }
            break;
        }
        if bytes.starts_with(b"--") {
            match bytes {
                b"--help" => {
                    print!(
                        "Usage: {} [FILE]...\n\
                         Print CRC checksum and byte counts of each FILE.\n\n\
                         With no FILE, or when FILE is -, read standard input.\n\n\
                         \x20     --help       display this help and exit\n\
                         \x20     --version    output version information and exit\n",
                        TOOL_NAME
                    );
                    process::exit(0);
                }
                b"--version" => {
                    println!("{} (fcoreutils) {}", TOOL_NAME, VERSION);
                    process::exit(0);
                }
                _ => {
                    eprintln!(
                        "{}: unrecognized option '{}'",
                        TOOL_NAME,
                        arg.to_string_lossy()
                    );
                    eprintln!("Try '{} --help' for more information.", TOOL_NAME);
                    process::exit(1);
                }
            }
        } else if bytes.len() > 1 && bytes[0] == b'-' {
            // cksum doesn't have short options
            eprintln!(
                "{}: invalid option -- '{}'",
                TOOL_NAME,
                arg.to_string_lossy()
            );
            eprintln!("Try '{} --help' for more information.", TOOL_NAME);
            process::exit(1);
        } else {
            cli.files.push(arg.to_string_lossy().into_owned());
        }
    }

    if cli.files.is_empty() {
        cli.files.push("-".to_string());
    }

    cli
}

fn main() {
    coreutils_rs::common::reset_sigpipe();

    let cli = parse_args();
    let stdout = io::stdout();
    let mut out = io::BufWriter::with_capacity(256 * 1024, stdout.lock());
    let mut exit_code = 0;

    for filename in &cli.files {
        let (crc, byte_count) = if filename == "-" {
            match posix_cksum_streaming(io::stdin().lock()) {
                Ok(v) => v,
                Err(e) => {
                    eprintln!(
                        "{}: -: {}",
                        TOOL_NAME,
                        coreutils_rs::common::io_error_msg(&e)
                    );
                    exit_code = 1;
                    continue;
                }
            }
        } else {
            match std::fs::File::open(filename) {
                Ok(file) => match posix_cksum_streaming(file) {
                    Ok(v) => v,
                    Err(e) => {
                        eprintln!(
                            "{}: {}: {}",
                            TOOL_NAME,
                            filename,
                            coreutils_rs::common::io_error_msg(&e)
                        );
                        exit_code = 1;
                        continue;
                    }
                },
                Err(e) => {
                    eprintln!(
                        "{}: {}: {}",
                        TOOL_NAME,
                        filename,
                        coreutils_rs::common::io_error_msg(&e)
                    );
                    exit_code = 1;
                    continue;
                }
            }
        };

        let result = if filename == "-" {
            writeln!(out, "{} {}", crc, byte_count)
        } else {
            writeln!(out, "{} {} {}", crc, byte_count, filename)
        };

        if let Err(e) = result {
            if e.kind() == io::ErrorKind::BrokenPipe {
                process::exit(0);
            }
            eprintln!("{}: write error: {}", TOOL_NAME, e);
            process::exit(1);
        }
    }

    if let Err(e) = out.flush()
        && e.kind() != io::ErrorKind::BrokenPipe
    {
        eprintln!("{}: write error: {}", TOOL_NAME, e);
        process::exit(1);
    }

    process::exit(exit_code);
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;
    use std::process::Command;

    fn cmd() -> Command {
        let mut path = std::env::current_exe().unwrap();
        path.pop();
        path.pop();
        path.push("fcksum");
        Command::new(path)
    }

    #[test]
    fn test_help() {
        let output = cmd().arg("--help").output().unwrap();
        assert!(output.status.success());
        let stdout = String::from_utf8_lossy(&output.stdout);
        assert!(stdout.contains("Usage:"));
        assert!(stdout.contains("CRC"));
    }

    #[test]
    fn test_version() {
        let output = cmd().arg("--version").output().unwrap();
        assert!(output.status.success());
        let stdout = String::from_utf8_lossy(&output.stdout);
        assert!(stdout.contains("cksum"));
        assert!(stdout.contains("fcoreutils"));
    }

    #[test]
    fn test_crc_table_correctness() {
        // Verify first and last entries of the CRC table
        assert_eq!(CRC_TABLE[0], 0);
        assert_ne!(CRC_TABLE[255], 0);
    }

    #[test]
    fn test_posix_cksum_empty() {
        // Empty input: CRC feeds only length (0), so only complement of 0
        let crc = posix_cksum(b"");
        assert_eq!(crc, 4294967295); // !0 = 0xFFFFFFFF
    }

    #[test]
    fn test_posix_cksum_hello() {
        // Known POSIX CRC for "hello\n"
        // GNU cksum gives: 3015617425 6
        let crc = posix_cksum(b"hello\n");
        assert_eq!(crc, 3015617425);
    }

    #[test]
    fn test_stdin() {
        let mut child = cmd()
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::piped())
            .spawn()
            .unwrap();
        child.stdin.take().unwrap().write_all(b"hello\n").unwrap();
        let output = child.wait_with_output().unwrap();
        assert!(output.status.success());
        let stdout = String::from_utf8_lossy(&output.stdout);
        let parts: Vec<&str> = stdout.split_whitespace().collect();
        assert_eq!(parts.len(), 2, "stdin should have no filename");
        assert_eq!(parts[0], "3015617425");
        assert_eq!(parts[1], "6");
    }

    #[test]
    fn test_file() {
        let dir = tempfile::tempdir().unwrap();
        let file_path = dir.path().join("test.txt");
        std::fs::write(&file_path, b"hello\n").unwrap();

        let output = cmd().arg(file_path.to_str().unwrap()).output().unwrap();
        assert!(output.status.success());
        let stdout = String::from_utf8_lossy(&output.stdout);
        let parts: Vec<&str> = stdout.split_whitespace().collect();
        assert_eq!(parts.len(), 3, "file should include filename");
        assert_eq!(parts[0], "3015617425");
        assert_eq!(parts[1], "6");
    }

    #[test]
    fn test_multiple_files() {
        let dir = tempfile::tempdir().unwrap();
        let file1 = dir.path().join("a.txt");
        let file2 = dir.path().join("b.txt");
        std::fs::write(&file1, b"hello\n").unwrap();
        std::fs::write(&file2, b"world\n").unwrap();

        let output = cmd()
            .arg(file1.to_str().unwrap())
            .arg(file2.to_str().unwrap())
            .output()
            .unwrap();
        assert!(output.status.success());
        let stdout = String::from_utf8_lossy(&output.stdout);
        let lines: Vec<&str> = stdout.trim().lines().collect();
        assert_eq!(lines.len(), 2, "should output one line per file");
    }

    #[test]
    fn test_nonexistent_file() {
        let output = cmd().arg("/nonexistent/file.txt").output().unwrap();
        assert!(!output.status.success());
        let stderr = String::from_utf8_lossy(&output.stderr);
        assert!(stderr.contains("cksum:"));
    }

    #[test]
    fn test_empty_file() {
        let dir = tempfile::tempdir().unwrap();
        let file_path = dir.path().join("empty.txt");
        std::fs::write(&file_path, b"").unwrap();

        let output = cmd().arg(file_path.to_str().unwrap()).output().unwrap();
        assert!(output.status.success());
        let stdout = String::from_utf8_lossy(&output.stdout);
        let parts: Vec<&str> = stdout.split_whitespace().collect();
        assert_eq!(parts[0], "4294967295");
        assert_eq!(parts[1], "0");
    }

    #[test]
    fn test_large_data() {
        let dir = tempfile::tempdir().unwrap();
        let file_path = dir.path().join("large.bin");
        // Create a 10KB file of zeros
        let data = vec![0u8; 10240];
        std::fs::write(&file_path, &data).unwrap();

        let output = cmd().arg(file_path.to_str().unwrap()).output().unwrap();
        assert!(output.status.success());
        let stdout = String::from_utf8_lossy(&output.stdout);
        let parts: Vec<&str> = stdout.split_whitespace().collect();
        let _crc: u32 = parts[0].parse().expect("CRC should be numeric");
        let byte_count: u64 = parts[1].parse().expect("byte count should be numeric");
        assert_eq!(byte_count, 10240);
    }

    #[test]
    fn test_compare_gnu_cksum() {
        let gnu = Command::new("cksum").output();
        if let Ok(_gnu_output) = gnu {
            let dir = tempfile::tempdir().unwrap();
            let file_path = dir.path().join("test.txt");
            std::fs::write(&file_path, b"The quick brown fox jumps over the lazy dog\n").unwrap();

            let gnu_out = Command::new("cksum")
                .arg(file_path.to_str().unwrap())
                .output();
            if let Ok(gnu_out) = gnu_out {
                let ours = cmd().arg(file_path.to_str().unwrap()).output().unwrap();
                assert_eq!(
                    String::from_utf8_lossy(&ours.stdout),
                    String::from_utf8_lossy(&gnu_out.stdout),
                    "CRC mismatch with GNU cksum"
                );
            }
        }
    }

    #[test]
    fn test_compare_gnu_cksum_empty() {
        let dir = tempfile::tempdir().unwrap();
        let file_path = dir.path().join("empty.txt");
        std::fs::write(&file_path, b"").unwrap();

        let gnu_out = Command::new("cksum")
            .arg(file_path.to_str().unwrap())
            .output();
        if let Ok(gnu_out) = gnu_out {
            let ours = cmd().arg(file_path.to_str().unwrap()).output().unwrap();
            assert_eq!(
                String::from_utf8_lossy(&ours.stdout),
                String::from_utf8_lossy(&gnu_out.stdout),
                "Empty file CRC mismatch with GNU cksum"
            );
        }
    }
}
