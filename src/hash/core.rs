use std::fs::File;
use std::io::{self, BufRead, BufReader, Read, Write};
use std::path::Path;

use blake2::Blake2b512;
use md5::Md5;
use sha2::{Digest, Sha256};

/// Supported hash algorithms.
#[derive(Debug, Clone, Copy)]
pub enum HashAlgorithm {
    Sha256,
    Md5,
    Blake2b,
}

impl HashAlgorithm {
    pub fn name(self) -> &'static str {
        match self {
            HashAlgorithm::Sha256 => "SHA256",
            HashAlgorithm::Md5 => "MD5",
            HashAlgorithm::Blake2b => "BLAKE2b",
        }
    }
}

/// Compute hash of data from a reader, returning hex string.
pub fn hash_reader<R: Read>(algo: HashAlgorithm, mut reader: R) -> io::Result<String> {
    let mut buf = vec![0u8; 256 * 1024]; // 256KB buffer like GNU

    match algo {
        HashAlgorithm::Sha256 => {
            let mut hasher = Sha256::new();
            loop {
                let n = reader.read(&mut buf)?;
                if n == 0 {
                    break;
                }
                hasher.update(&buf[..n]);
            }
            Ok(hex_encode(&hasher.finalize()))
        }
        HashAlgorithm::Md5 => {
            let mut hasher = Md5::new();
            loop {
                let n = reader.read(&mut buf)?;
                if n == 0 {
                    break;
                }
                hasher.update(&buf[..n]);
            }
            Ok(hex_encode(&hasher.finalize()))
        }
        HashAlgorithm::Blake2b => {
            let mut hasher = Blake2b512::new();
            loop {
                let n = reader.read(&mut buf)?;
                if n == 0 {
                    break;
                }
                hasher.update(&buf[..n]);
            }
            Ok(hex_encode(&hasher.finalize()))
        }
    }
}

/// Hash a file by path. Returns the hex digest.
pub fn hash_file(algo: HashAlgorithm, path: &Path) -> io::Result<String> {
    let file = File::open(path)?;
    let reader = BufReader::with_capacity(256 * 1024, file);
    hash_reader(algo, reader)
}

/// Hash stdin. Returns the hex digest.
pub fn hash_stdin(algo: HashAlgorithm) -> io::Result<String> {
    hash_reader(algo, io::stdin().lock())
}

/// Print hash result in GNU format: "hash  filename\n"
pub fn print_hash(
    out: &mut impl Write,
    hash: &str,
    filename: &str,
    binary: bool,
) -> io::Result<()> {
    let mode_char = if binary { '*' } else { ' ' };
    writeln!(out, "{} {}{}", hash, mode_char, filename)
}

/// Print hash result in BSD tag format: "ALGO (filename) = hash\n"
pub fn print_hash_tag(
    out: &mut impl Write,
    algo: HashAlgorithm,
    hash: &str,
    filename: &str,
) -> io::Result<()> {
    writeln!(out, "{} ({}) = {}", algo.name(), filename, hash)
}

/// Options for check mode.
pub struct CheckOptions {
    pub quiet: bool,
    pub status_only: bool,
    pub strict: bool,
    pub warn: bool,
}

/// Verify checksums from a check file.
/// Each line should be "hash  filename" or "hash *filename".
/// Returns (ok_count, fail_count, error_count).
pub fn check_file<R: BufRead>(
    algo: HashAlgorithm,
    reader: R,
    opts: &CheckOptions,
    out: &mut impl Write,
    err_out: &mut impl Write,
) -> io::Result<(usize, usize, usize)> {
    let CheckOptions {
        quiet,
        status_only,
        strict,
        warn,
    } = *opts;
    let mut ok_count = 0;
    let mut fail_count = 0;
    let mut format_errors = 0;
    let mut line_num = 0;

    for line_result in reader.lines() {
        line_num += 1;
        let line = line_result?;
        let line = line.trim_end();

        if line.is_empty() {
            continue;
        }

        // Parse "hash  filename" or "hash *filename"
        let (expected_hash, filename) = match parse_check_line(line) {
            Some(v) => v,
            None => {
                format_errors += 1;
                if warn {
                    writeln!(
                        err_out,
                        "line {}: improperly formatted checksum line",
                        line_num
                    )?;
                }
                continue;
            }
        };

        // Compute actual hash
        let actual = match hash_file(algo, Path::new(filename)) {
            Ok(h) => h,
            Err(e) => {
                fail_count += 1;
                if !status_only {
                    writeln!(err_out, "{}: FAILED open or read: {}", filename, e)?;
                }
                continue;
            }
        };

        if actual == expected_hash {
            ok_count += 1;
            if !quiet && !status_only {
                writeln!(out, "{}: OK", filename)?;
            }
        } else {
            fail_count += 1;
            if !status_only {
                writeln!(out, "{}: FAILED", filename)?;
            }
        }
    }

    if strict && format_errors > 0 {
        fail_count += format_errors;
    }

    Ok((ok_count, fail_count, format_errors))
}

/// Parse a checksum line: "hash  filename" or "hash *filename"
pub(crate) fn parse_check_line(line: &str) -> Option<(&str, &str)> {
    // Find the two-space separator
    if let Some(idx) = line.find("  ") {
        let hash = &line[..idx];
        let rest = &line[idx + 2..];
        return Some((hash, rest));
    }
    // Try "hash *filename" (binary mode marker)
    if let Some(idx) = line.find(" *") {
        let hash = &line[..idx];
        let rest = &line[idx + 2..];
        return Some((hash, rest));
    }
    None
}

/// Convert bytes to lowercase hex string.
pub(crate) fn hex_encode(bytes: &[u8]) -> String {
    let mut s = String::with_capacity(bytes.len() * 2);
    for &b in bytes {
        s.push_str(&format!("{:02x}", b));
    }
    s
}
