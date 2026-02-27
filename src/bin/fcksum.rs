// fcksum — compute checksums (GNU cksum replacement with multi-algorithm support)
//
// Supports POSIX CRC-32 (default), plus -a {md5,sha1,sha256,sha512,blake2b,bsd,sysv,crc}
// for GNU coreutils 9.0+ compatibility. Hash algorithms delegate to the shared hash
// infrastructure; CRC/BSD/SysV use dedicated fast paths.

use std::io::{self, BufRead, BufReader, Read, Write};
use std::path::Path;
use std::process;

use coreutils_rs::common::io_error_msg;
use coreutils_rs::hash::{self, HashAlgorithm};

const TOOL_NAME: &str = "cksum";
const VERSION: &str = env!("CARGO_PKG_VERSION");

// ── Algorithm enum ──────────────────────────────────────────────────

#[derive(Debug, Clone, Copy, PartialEq)]
enum Algorithm {
    Crc,
    Md5,
    Sha1,
    Sha256,
    Sha512,
    Blake2b,
    Bsd,
    SysV,
}

impl Algorithm {
    fn from_name(s: &str) -> Option<Self> {
        match s {
            "crc" => Some(Algorithm::Crc),
            "md5" => Some(Algorithm::Md5),
            "sha1" => Some(Algorithm::Sha1),
            "sha256" => Some(Algorithm::Sha256),
            "sha512" => Some(Algorithm::Sha512),
            "blake2b" => Some(Algorithm::Blake2b),
            "bsd" => Some(Algorithm::Bsd),
            "sysv" => Some(Algorithm::SysV),
            _ => None,
        }
    }

    fn is_hash(self) -> bool {
        matches!(
            self,
            Algorithm::Md5
                | Algorithm::Sha1
                | Algorithm::Sha256
                | Algorithm::Sha512
                | Algorithm::Blake2b
        )
    }

    fn to_hash_algo(self) -> Option<HashAlgorithm> {
        match self {
            Algorithm::Md5 => Some(HashAlgorithm::Md5),
            Algorithm::Sha1 => Some(HashAlgorithm::Sha1),
            Algorithm::Sha256 => Some(HashAlgorithm::Sha256),
            Algorithm::Sha512 => Some(HashAlgorithm::Sha512),
            Algorithm::Blake2b => Some(HashAlgorithm::Blake2b),
            _ => None,
        }
    }

    #[allow(dead_code)]
    fn tag_name(self) -> &'static str {
        match self {
            Algorithm::Crc => "CRC",
            Algorithm::Md5 => "MD5",
            Algorithm::Sha1 => "SHA1",
            Algorithm::Sha256 => "SHA256",
            Algorithm::Sha512 => "SHA512",
            Algorithm::Blake2b => "BLAKE2b",
            Algorithm::Bsd => "BSD",
            Algorithm::SysV => "SYSV",
        }
    }
}

// ── CLI parsing ─────────────────────────────────────────────────────

struct Cli {
    algorithm: Algorithm,
    algorithm_explicit: bool,
    check: bool,
    tag: bool,
    untagged: bool,
    binary: bool,
    text: bool,
    length: Option<usize>,
    ignore_missing: bool,
    quiet: bool,
    status: bool,
    strict: bool,
    warn: bool,
    zero: bool,
    files: Vec<String>,
}

fn parse_args() -> Cli {
    let mut cli = Cli {
        algorithm: Algorithm::Crc,
        algorithm_explicit: false,
        check: false,
        tag: false,
        untagged: false,
        binary: false,
        text: false,
        length: None,
        ignore_missing: false,
        quiet: false,
        status: false,
        strict: false,
        warn: false,
        zero: false,
        files: Vec::new(),
    };

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
            let s = arg.to_string_lossy();
            if let Some(val) = s.strip_prefix("--algorithm=") {
                match Algorithm::from_name(val) {
                    Some(a) => {
                        cli.algorithm = a;
                        cli.algorithm_explicit = true;
                    }
                    None => {
                        eprintln!("{}: unknown algorithm: {}", TOOL_NAME, val);
                        eprintln!("Try '{} --help' for more information.", TOOL_NAME);
                        process::exit(1);
                    }
                }
            } else if let Some(val) = s.strip_prefix("--length=") {
                match val.parse::<usize>() {
                    Ok(n) => cli.length = Some(n),
                    Err(_) => {
                        eprintln!("{}: invalid length: '{}'", TOOL_NAME, val);
                        process::exit(1);
                    }
                }
            } else {
                match bytes {
                    b"--check" => cli.check = true,
                    b"--tag" => cli.tag = true,
                    b"--untagged" => cli.untagged = true,
                    b"--binary" => cli.binary = true,
                    b"--text" => cli.text = true,
                    b"--ignore-missing" => cli.ignore_missing = true,
                    b"--quiet" => cli.quiet = true,
                    b"--status" => cli.status = true,
                    b"--strict" => cli.strict = true,
                    b"--warn" => cli.warn = true,
                    b"--zero" => cli.zero = true,
                    b"--raw" => { /* accept silently for compat */ }
                    b"--base64" => { /* accept silently for compat */ }
                    b"--help" => {
                        print!(
                            "Usage: {} [OPTION]... [FILE]...\n\
                             Print or check checksums.\n\
                             By default use the 32 bit CRC algorithm.\n\n\
                             With no FILE, or when FILE is -, read standard input.\n\n\
                             \x20 -a, --algorithm=TYPE  select the digest type to use. See DIGEST below.\n\
                             \x20 -b, --binary         read in binary mode\n\
                             \x20 -c, --check          read checksums from the FILEs and check them\n\
                             \x20     --tag             create a BSD-style checksum (the default)\n\
                             \x20     --untagged        create a reverse style checksum, without digest type\n\
                             \x20 -l, --length=BITS    digest length in bits; must not exceed the max for\n\
                             \x20                       the blake2 algorithm and must be a multiple of 8\n\
                             \x20 -t, --text           read in text mode (default)\n\
                             \x20 -z, --zero           end each output line with NUL, not newline,\n\
                             \x20                       and disable file name escaping\n\n\
                             The following five options are useful only when verifying checksums:\n\
                             \x20     --ignore-missing  don't fail or report status for missing files\n\
                             \x20     --quiet           don't print OK for each successfully verified file\n\
                             \x20     --status          don't output anything, status code shows success\n\
                             \x20     --strict          exit non-zero for improperly formatted checksum lines\n\
                             \x20 -w, --warn           warn about improperly formatted checksum lines\n\n\
                             \x20     --help            display this help and exit\n\
                             \x20     --version         output version information and exit\n\n\
                             DIGEST determines the digest algorithm and default output format:\n\
                             \x20 sysv     (equivalent to sum -s)\n\
                             \x20 bsd      (equivalent to sum -r)\n\
                             \x20 crc      (equivalent to cksum)\n\
                             \x20 md5      (equivalent to md5sum)\n\
                             \x20 sha1     (equivalent to sha1sum)\n\
                             \x20 sha256   (equivalent to sha256sum)\n\
                             \x20 sha512   (equivalent to sha512sum)\n\
                             \x20 blake2b  (equivalent to b2sum)\n",
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
            }
        } else if bytes.len() > 1 && bytes[0] == b'-' {
            let mut i = 1;
            while i < bytes.len() {
                match bytes[i] {
                    b'a' => {
                        // -a ALGO (value in next arg or rest of current)
                        let val = if i + 1 < bytes.len() {
                            String::from_utf8_lossy(&bytes[i + 1..]).into_owned()
                        } else {
                            match args.next() {
                                Some(v) => v.to_string_lossy().into_owned(),
                                None => {
                                    eprintln!("{}: option requires an argument -- 'a'", TOOL_NAME);
                                    eprintln!("Try '{} --help' for more information.", TOOL_NAME);
                                    process::exit(1);
                                }
                            }
                        };
                        match Algorithm::from_name(&val) {
                            Some(a) => {
                                cli.algorithm = a;
                                cli.algorithm_explicit = true;
                            }
                            None => {
                                eprintln!("{}: unknown algorithm: {}", TOOL_NAME, val);
                                eprintln!("Try '{} --help' for more information.", TOOL_NAME);
                                process::exit(1);
                            }
                        }
                        break; // consumed rest of arg
                    }
                    b'l' => {
                        let val = if i + 1 < bytes.len() {
                            String::from_utf8_lossy(&bytes[i + 1..]).into_owned()
                        } else {
                            match args.next() {
                                Some(v) => v.to_string_lossy().into_owned(),
                                None => {
                                    eprintln!("{}: option requires an argument -- 'l'", TOOL_NAME);
                                    process::exit(1);
                                }
                            }
                        };
                        match val.parse::<usize>() {
                            Ok(n) => cli.length = Some(n),
                            Err(_) => {
                                eprintln!("{}: invalid length: '{}'", TOOL_NAME, val);
                                process::exit(1);
                            }
                        }
                        break;
                    }
                    b'b' => cli.binary = true,
                    b'c' => cli.check = true,
                    b't' => cli.text = true,
                    b'w' => cli.warn = true,
                    b'z' => cli.zero = true,
                    _ => {
                        eprintln!("{}: invalid option -- '{}'", TOOL_NAME, bytes[i] as char);
                        eprintln!("Try '{} --help' for more information.", TOOL_NAME);
                        process::exit(1);
                    }
                }
                i += 1;
            }
        } else {
            cli.files.push(arg.to_string_lossy().into_owned());
        }
    }

    if cli.files.is_empty() {
        cli.files.push("-".to_string());
    }

    cli
}

// ── POSIX CRC-32 implementation ─────────────────────────────────────

/// POSIX CRC-32 slicing-by-8 lookup tables using polynomial 0x04C11DB7.
/// Table 0 is the standard byte-at-a-time table; tables 1-7 enable processing
/// 8 bytes per iteration, breaking the data dependency chain for ~2x throughput
/// over slice-by-4 (matches GNU cksum's software CRC algorithm).
const CRC_TABLES: [[u32; 256]; 8] = {
    let mut tables = [[0u32; 256]; 8];
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

#[cfg(test)]
const CRC_TABLE: [u32; 256] = CRC_TABLES[0];

#[cfg(test)]
fn posix_cksum(data: &[u8]) -> u32 {
    let mut crc: u32 = 0;
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
    for &byte in remainder {
        crc = (crc << 8) ^ CRC_TABLES[0][((crc >> 24) ^ u32::from(byte)) as usize];
    }
    let mut len = data.len() as u64;
    while len > 0 {
        crc = (crc << 8) ^ CRC_TABLES[0][((crc >> 24) ^ (len & 0xFF) as u32) as usize];
        len >>= 8;
    }
    !crc
}

#[cfg(target_arch = "x86_64")]
#[target_feature(enable = "sse2,ssse3,pclmulqdq")]
unsafe fn cksum_pclmul_chunk(buf: &mut [u8], mut crc: u32) -> u32 {
    unsafe {
        use core::arch::x86_64::*;
        let single_mult = _mm_set_epi64x(0xC5B9CD4Cu64 as i64, 0xE8A45605u64 as i64);
        let four_mult = _mm_set_epi64x(0x8833794Cu64 as i64, 0xE6228B11u64 as i64);
        let shuffle = _mm_set_epi8(0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15);

        let ptr = buf.as_mut_ptr();
        let mut pos: usize = 0;
        let len = buf.len();

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

            _mm_storeu_si128(
                ptr.add(pos - 16) as *mut __m128i,
                _mm_shuffle_epi8(data, shuffle),
            );
            pos -= 16;
        }

        for i in pos..len {
            crc = (crc << 8) ^ CRC_TABLES[0][((crc >> 24) ^ u32::from(buf[i])) as usize];
        }

        crc
    }
}

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

#[cfg(target_arch = "x86_64")]
fn posix_cksum_streaming_pclmul<R: Read>(mut reader: R) -> io::Result<(u32, u64)> {
    const BUFLEN: usize = 1 << 16;
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

    let mut len = total_bytes;
    while len > 0 {
        crc = (crc << 8) ^ CRC_TABLES[0][((crc >> 24) ^ (len & 0xFF) as u32) as usize];
        len >>= 8;
    }

    Ok((!crc, total_bytes))
}

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

    let mut len = total_bytes;
    while len > 0 {
        crc = (crc << 8) ^ CRC_TABLES[0][((crc >> 24) ^ (len & 0xFF) as u32) as usize];
        len >>= 8;
    }

    Ok((!crc, total_bytes))
}

fn posix_cksum_streaming<R: Read>(reader: R) -> io::Result<(u32, u64)> {
    #[cfg(target_arch = "x86_64")]
    {
        if is_x86_feature_detected!("pclmulqdq") && is_x86_feature_detected!("ssse3") {
            return posix_cksum_streaming_pclmul(reader);
        }
    }
    posix_cksum_streaming_table(reader)
}

// ── BSD/SysV checksum helpers ───────────────────────────────────────

#[inline(always)]
fn bsd_step(checksum: u32, byte: u8) -> u32 {
    let rotated = (checksum >> 1) + ((checksum & 1) << 15);
    (rotated + u32::from(byte)) & 0xFFFF
}

#[inline(always)]
fn sysv_sum_bytes(data: &[u8]) -> u64 {
    let mut sum: u64 = 0;
    let chunks = data.chunks_exact(8);
    let remainder = chunks.remainder();
    for chunk in chunks {
        sum += u64::from(chunk[0])
            + u64::from(chunk[1])
            + u64::from(chunk[2])
            + u64::from(chunk[3])
            + u64::from(chunk[4])
            + u64::from(chunk[5])
            + u64::from(chunk[6])
            + u64::from(chunk[7]);
    }
    for &byte in remainder {
        sum += u64::from(byte);
    }
    sum
}

#[inline(always)]
fn sysv_fold(sum: u64) -> u32 {
    let mut r = sum as u32;
    r = (r & 0xFFFF) + (r >> 16);
    r = (r & 0xFFFF) + (r >> 16);
    r
}

fn bsd_checksum_streaming<R: Read>(reader: R) -> io::Result<(u32, u64)> {
    let mut reader = BufReader::with_capacity(8 * 1024 * 1024, reader);
    let mut checksum: u32 = 0;
    let mut total_bytes: u64 = 0;
    loop {
        let buf = reader.fill_buf()?;
        if buf.is_empty() {
            break;
        }
        let n = buf.len();
        total_bytes += n as u64;
        for &byte in buf {
            checksum = bsd_step(checksum, byte);
        }
        reader.consume(n);
    }
    let blocks = total_bytes.div_ceil(1024);
    Ok((checksum, blocks))
}

fn bsd_checksum_data(data: &[u8]) -> (u32, u64) {
    let mut checksum: u32 = 0;
    for &byte in data {
        checksum = bsd_step(checksum, byte);
    }
    let blocks = (data.len() as u64).div_ceil(1024);
    (checksum, blocks)
}

fn sysv_checksum_streaming<R: Read>(reader: R) -> io::Result<(u32, u64)> {
    let mut reader = BufReader::with_capacity(8 * 1024 * 1024, reader);
    let mut sum: u64 = 0;
    let mut total_bytes: u64 = 0;
    loop {
        let buf = reader.fill_buf()?;
        if buf.is_empty() {
            break;
        }
        let n = buf.len();
        total_bytes += n as u64;
        sum += sysv_sum_bytes(buf);
        reader.consume(n);
    }
    let checksum = sysv_fold(sum);
    let blocks = total_bytes.div_ceil(512);
    Ok((checksum, blocks))
}

fn sysv_checksum_data(data: &[u8]) -> (u32, u64) {
    let checksum = sysv_fold(sysv_sum_bytes(data));
    let blocks = (data.len() as u64).div_ceil(512);
    (checksum, blocks)
}

// ── Output formatting ───────────────────────────────────────────────

fn write_crc_line(
    out: &mut impl Write,
    crc: u32,
    byte_count: u64,
    filename: &str,
    is_stdin: bool,
) -> io::Result<()> {
    if is_stdin {
        writeln!(out, "{} {}", crc, byte_count)
    } else {
        writeln!(out, "{} {} {}", crc, byte_count, filename)
    }
}

fn write_sum_line(
    out: &mut impl Write,
    checksum: u32,
    blocks: u64,
    filename: &str,
    is_stdin: bool,
    bsd: bool,
) -> io::Result<()> {
    if bsd {
        if is_stdin {
            writeln!(out, "{:05} {:5}", checksum, blocks)
        } else {
            writeln!(out, "{:05} {:5} {}", checksum, blocks, filename)
        }
    } else if is_stdin {
        writeln!(out, "{} {}", checksum, blocks)
    } else {
        writeln!(out, "{} {} {}", checksum, blocks, filename)
    }
}

// ── Filename escaping (GNU compat) ──────────────────────────────────

fn needs_escape(name: &str) -> bool {
    name.bytes().any(|b| b == b'\\' || b == b'\n')
}

fn escape_filename(name: &str) -> String {
    let mut out = String::with_capacity(name.len() + 8);
    for b in name.bytes() {
        match b {
            b'\\' => out.push_str("\\\\"),
            b'\n' => out.push_str("\\n"),
            _ => out.push(b as char),
        }
    }
    out
}

#[allow(dead_code)]
fn unescape_filename(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut chars = s.chars();
    while let Some(c) = chars.next() {
        if c == '\\' {
            match chars.next() {
                Some('\\') => out.push('\\'),
                Some('n') => out.push('\n'),
                Some(other) => {
                    out.push('\\');
                    out.push(other);
                }
                None => out.push('\\'),
            }
        } else {
            out.push(c);
        }
    }
    out
}

// ── Main ────────────────────────────────────────────────────────────

fn main() {
    coreutils_rs::common::reset_sigpipe();

    let cli = parse_args();
    let stdout = io::stdout();
    let mut out = io::BufWriter::with_capacity(256 * 1024, stdout.lock());

    // Validate flag combinations
    if cli.tag && cli.check {
        eprintln!(
            "{}: the --tag option is meaningless when verifying checksums",
            TOOL_NAME
        );
        eprintln!("Try '{} --help' for more information.", TOOL_NAME);
        process::exit(1);
    }
    // GNU cksum 9.x: --text --tag is allowed (silently accepts)
    if cli.length.is_some() && cli.algorithm != Algorithm::Blake2b {
        eprintln!(
            "{}: --length is only supported with --algorithm=blake2b",
            TOOL_NAME
        );
        process::exit(1);
    }
    // GNU cksum: --check with explicitly specified bsd/sysv/crc is not supported
    // When no algorithm is specified, --check auto-detects from the checksum file
    if cli.check
        && cli.algorithm_explicit
        && matches!(
            cli.algorithm,
            Algorithm::Bsd | Algorithm::SysV | Algorithm::Crc
        )
    {
        eprintln!(
            "{}: --check is not supported with --algorithm={{bsd,sysv,crc}}",
            TOOL_NAME
        );
        process::exit(1);
    }

    if cli.check {
        let exit_code = run_check_mode(&cli, &mut out);
        let _ = out.flush();
        process::exit(exit_code);
    }

    let exit_code = match cli.algorithm {
        Algorithm::Crc => run_crc_mode(&cli, &mut out),
        Algorithm::Bsd | Algorithm::SysV => run_sum_mode(&cli, &mut out),
        _ => run_hash_mode(&cli, &mut out),
    };

    if let Err(e) = out.flush()
        && e.kind() != io::ErrorKind::BrokenPipe
    {
        eprintln!("{}: write error: {}", TOOL_NAME, e);
        process::exit(1);
    }

    process::exit(exit_code);
}

// ── CRC mode (default) ─────────────────────────────────────────────

fn run_crc_mode(cli: &Cli, out: &mut impl Write) -> i32 {
    let mut exit_code = 0;

    for filename in &cli.files {
        let (crc, byte_count) = if filename == "-" {
            match posix_cksum_streaming(io::stdin().lock()) {
                Ok(v) => v,
                Err(e) => {
                    eprintln!("{}: -: {}", TOOL_NAME, io_error_msg(&e));
                    exit_code = 1;
                    continue;
                }
            }
        } else {
            match std::fs::File::open(filename) {
                Ok(file) => match posix_cksum_streaming(file) {
                    Ok(v) => v,
                    Err(e) => {
                        eprintln!("{}: {}: {}", TOOL_NAME, filename, io_error_msg(&e));
                        exit_code = 1;
                        continue;
                    }
                },
                Err(e) => {
                    eprintln!("{}: {}: {}", TOOL_NAME, filename, io_error_msg(&e));
                    exit_code = 1;
                    continue;
                }
            }
        };

        let result = write_crc_line(out, crc, byte_count, filename, filename == "-");
        if let Err(e) = result {
            if e.kind() == io::ErrorKind::BrokenPipe {
                process::exit(0);
            }
            eprintln!("{}: write error: {}", TOOL_NAME, e);
            process::exit(1);
        }
    }

    exit_code
}

// ── Sum mode (BSD/SysV) ────────────────────────────────────────────

fn run_sum_mode(cli: &Cli, out: &mut impl Write) -> i32 {
    let mut exit_code = 0;
    let bsd = cli.algorithm == Algorithm::Bsd;

    for filename in &cli.files {
        let result = if filename == "-" {
            if bsd {
                bsd_checksum_streaming(io::stdin().lock())
            } else {
                sysv_checksum_streaming(io::stdin().lock())
            }
        } else {
            match coreutils_rs::common::io::read_file(Path::new(filename)) {
                Ok(data) => {
                    if bsd {
                        Ok(bsd_checksum_data(&data))
                    } else {
                        Ok(sysv_checksum_data(&data))
                    }
                }
                Err(e) => {
                    eprintln!("{}: {}: {}", TOOL_NAME, filename, io_error_msg(&e));
                    exit_code = 1;
                    continue;
                }
            }
        };

        let (checksum, blocks) = match result {
            Ok(v) => v,
            Err(e) => {
                let name = if filename == "-" {
                    "-"
                } else {
                    filename.as_str()
                };
                eprintln!("{}: {}: {}", TOOL_NAME, name, io_error_msg(&e));
                exit_code = 1;
                continue;
            }
        };

        let result = write_sum_line(out, checksum, blocks, filename, filename == "-", bsd);
        if let Err(e) = result {
            if e.kind() == io::ErrorKind::BrokenPipe {
                process::exit(0);
            }
            eprintln!("{}: write error: {}", TOOL_NAME, e);
            process::exit(1);
        }
    }

    exit_code
}

// ── Hash mode (md5, sha1, sha256, sha512, blake2b) ─────────────────

fn run_hash_mode(cli: &Cli, out: &mut impl Write) -> i32 {
    let algo = cli.algorithm.to_hash_algo().unwrap();
    let mut exit_code = 0;
    // In cksum, tagged output is the default (--untagged opts out)
    let tagged = !cli.untagged;

    for filename in &cli.files {
        let hash_result = if filename == "-" {
            if cli.algorithm == Algorithm::Blake2b {
                let bits = cli.length.unwrap_or(512);
                hash::blake2b_hash_stdin(bits / 8)
            } else {
                hash::hash_stdin(algo)
            }
        } else if cli.algorithm == Algorithm::Blake2b {
            let bits = cli.length.unwrap_or(512);
            hash::blake2b_hash_file(Path::new(filename), bits / 8)
        } else {
            hash::hash_file(algo, Path::new(filename))
        };

        match hash_result {
            Ok(h) => {
                let name = if filename == "-" {
                    "-"
                } else {
                    filename.as_str()
                };
                let result = if tagged {
                    if cli.algorithm == Algorithm::Blake2b {
                        let bits = cli.length.unwrap_or(512);
                        if bits == 512 {
                            hash::write_hash_tag_line(out, "BLAKE2b", &h, name, cli.zero)
                        } else {
                            let tag = format!("BLAKE2b-{}", bits);
                            hash::write_hash_tag_line(out, &tag, &h, name, cli.zero)
                        }
                    } else {
                        hash::write_hash_tag_line(out, algo.name(), &h, name, cli.zero)
                    }
                } else {
                    let binary = cli.binary || (!cli.text && cfg!(windows));
                    if !cli.zero && needs_escape(name) {
                        let escaped = escape_filename(name);
                        hash::write_hash_line(out, &h, &escaped, binary, cli.zero, true)
                    } else {
                        hash::write_hash_line(out, &h, name, binary, cli.zero, false)
                    }
                };
                if let Err(e) = result {
                    if e.kind() == io::ErrorKind::BrokenPipe {
                        process::exit(0);
                    }
                    eprintln!("{}: write error: {}", TOOL_NAME, e);
                    process::exit(1);
                }
            }
            Err(e) => {
                let _ = out.flush();
                eprintln!("{}: {}: {}", TOOL_NAME, filename, io_error_msg(&e));
                exit_code = 1;
            }
        }
    }

    exit_code
}

// ── Check mode ──────────────────────────────────────────────────────

fn run_check_mode(cli: &Cli, out: &mut impl Write) -> i32 {
    // When a hash algorithm is explicitly selected, use it directly.
    // When algorithm is CRC (default) and --check is used, GNU cksum auto-detects
    // the algorithm from the tag format in each line.
    if cli.algorithm.is_hash() {
        return run_check_hash(cli, out);
    }
    // Default (CRC): auto-detect from file content
    run_check_autodetect(cli, out)
}

fn run_check_hash(cli: &Cli, out: &mut impl Write) -> i32 {
    let algo = cli.algorithm.to_hash_algo().unwrap();
    let mut exit_code = 0;

    for filename in &cli.files {
        let reader: Box<dyn BufRead> = if filename == "-" {
            Box::new(BufReader::new(io::stdin().lock()))
        } else {
            match std::fs::File::open(filename) {
                Ok(f) => Box::new(BufReader::new(f)),
                Err(e) => {
                    eprintln!("{}: {}: {}", TOOL_NAME, filename, io_error_msg(&e));
                    exit_code = 1;
                    continue;
                }
            }
        };

        let opts_local = hash::CheckOptions {
            quiet: cli.quiet,
            status_only: cli.status,
            strict: cli.strict,
            warn: cli.warn || cli.strict,
            ignore_missing: cli.ignore_missing,
            warn_prefix: if filename == "-" {
                format!("{}: standard input", TOOL_NAME)
            } else {
                format!("{}: {}", TOOL_NAME, filename)
            },
        };

        let mut err_buf = io::stderr();
        match hash::check_file(algo, reader, &opts_local, out, &mut err_buf) {
            Ok(result) => {
                if result.mismatches > 0 || result.read_errors > 0 {
                    exit_code = 1;
                }
                if cli.strict && result.format_errors > 0 {
                    exit_code = 1;
                }
                if result.ok == 0
                    && result.mismatches == 0
                    && result.read_errors == 0
                    && result.format_errors > 0
                {
                    if !cli.status {
                        let display = if filename == "-" {
                            "standard input"
                        } else {
                            filename.as_str()
                        };
                        let _ = out.flush();
                        eprintln!(
                            "{}: {}: no properly formatted {} checksum lines found",
                            TOOL_NAME,
                            display,
                            algo.name()
                        );
                    }
                    exit_code = 1;
                }
                // Print summary warnings
                if !cli.status {
                    let _ = out.flush();
                    if result.mismatches > 0 {
                        let word = if result.mismatches == 1 {
                            "computed checksum did NOT match"
                        } else {
                            "computed checksums did NOT match"
                        };
                        eprintln!("{}: WARNING: {} {}", TOOL_NAME, result.mismatches, word);
                    }
                    if result.read_errors > 0 {
                        let word = if result.read_errors == 1 {
                            "listed file could not be read"
                        } else {
                            "listed files could not be read"
                        };
                        eprintln!("{}: WARNING: {} {}", TOOL_NAME, result.read_errors, word);
                    }
                }
            }
            Err(e) => {
                eprintln!("{}: {}: {}", TOOL_NAME, filename, io_error_msg(&e));
                exit_code = 1;
            }
        }
    }

    exit_code
}

/// Auto-detect the algorithm from tagged checksum lines.
/// Supports "ALGO (filename) = hash" and "hash  filename" formats.
fn run_check_autodetect(cli: &Cli, out: &mut impl Write) -> i32 {
    let mut exit_code = 0;

    for filename in &cli.files {
        let reader: Box<dyn BufRead> = if filename == "-" {
            Box::new(BufReader::new(io::stdin().lock()))
        } else {
            match std::fs::File::open(filename) {
                Ok(f) => Box::new(BufReader::new(f)),
                Err(e) => {
                    eprintln!("{}: {}: {}", TOOL_NAME, filename, io_error_msg(&e));
                    exit_code = 1;
                    continue;
                }
            }
        };

        let mut ok_count = 0usize;
        let mut mismatch_count = 0usize;
        let mut format_errors = 0usize;
        let mut read_errors = 0usize;

        for line_result in reader.lines() {
            let line = match line_result {
                Ok(l) => l,
                Err(e) => {
                    eprintln!("{}: {}: {}", TOOL_NAME, filename, io_error_msg(&e));
                    break;
                }
            };
            let line = line.trim_end();
            if line.is_empty() {
                continue;
            }

            // Try to detect algorithm from tag format
            if let Some((algo, expected_hash, check_filename)) = detect_check_line(line) {
                let actual = match algo {
                    Algorithm::Md5 | Algorithm::Sha1 | Algorithm::Sha256 | Algorithm::Sha512 => {
                        hash::hash_file(algo.to_hash_algo().unwrap(), Path::new(check_filename))
                    }
                    Algorithm::Blake2b => {
                        // Detect bit length from tag (e.g., BLAKE2b-256)
                        let bits = detect_blake2b_bits(line).unwrap_or(512);
                        hash::blake2b_hash_file(Path::new(check_filename), bits / 8)
                    }
                    _ => {
                        format_errors += 1;
                        continue;
                    }
                };

                match actual {
                    Ok(h) => {
                        if h.eq_ignore_ascii_case(expected_hash) {
                            ok_count += 1;
                            if !cli.quiet && !cli.status {
                                let _ = writeln!(out, "{}: OK", check_filename);
                            }
                        } else {
                            mismatch_count += 1;
                            if !cli.status {
                                let _ = writeln!(out, "{}: FAILED", check_filename);
                            }
                        }
                    }
                    Err(e) => {
                        if cli.ignore_missing && e.kind() == io::ErrorKind::NotFound {
                            continue;
                        }
                        read_errors += 1;
                        if !cli.status {
                            let _ = out.flush();
                            eprintln!("{}: {}: {}", TOOL_NAME, check_filename, io_error_msg(&e));
                            let _ = writeln!(out, "{}: FAILED open or read", check_filename);
                        }
                    }
                }
            } else {
                format_errors += 1;
                if cli.warn {
                    let _ = out.flush();
                    let display = if filename == "-" {
                        "standard input"
                    } else {
                        filename.as_str()
                    };
                    eprintln!(
                        "{}: {}: improperly formatted checksum line",
                        TOOL_NAME, display
                    );
                }
            }
        }

        if mismatch_count > 0 || read_errors > 0 {
            exit_code = 1;
        }
        if cli.strict && format_errors > 0 {
            exit_code = 1;
        }
        if ok_count == 0 && mismatch_count == 0 && read_errors == 0 && format_errors > 0 {
            if !cli.status {
                let _ = out.flush();
                let display = if filename == "-" {
                    "standard input"
                } else {
                    filename.as_str()
                };
                eprintln!(
                    "{}: {}: no properly formatted checksum lines found",
                    TOOL_NAME, display
                );
            }
            exit_code = 1;
        }

        // Summary warnings
        if !cli.status {
            let _ = out.flush();
            if mismatch_count > 0 {
                let word = if mismatch_count == 1 {
                    "computed checksum did NOT match"
                } else {
                    "computed checksums did NOT match"
                };
                eprintln!("{}: WARNING: {} {}", TOOL_NAME, mismatch_count, word);
            }
            if read_errors > 0 {
                let word = if read_errors == 1 {
                    "listed file could not be read"
                } else {
                    "listed files could not be read"
                };
                eprintln!("{}: WARNING: {} {}", TOOL_NAME, read_errors, word);
            }
        }
    }

    exit_code
}

/// Detect algorithm from a tagged checksum line.
/// Returns (algorithm, hash, filename) if parseable.
fn detect_check_line(line: &str) -> Option<(Algorithm, &str, &str)> {
    // Try BSD tag format: "ALGO (filename) = hash"
    let tag_prefixes = [
        ("MD5 (", Algorithm::Md5),
        ("SHA1 (", Algorithm::Sha1),
        ("SHA256 (", Algorithm::Sha256),
        ("SHA512 (", Algorithm::Sha512),
        ("BLAKE2b (", Algorithm::Blake2b),
    ];

    for (prefix, algo) in &tag_prefixes {
        if let Some(rest) = line.strip_prefix(prefix)
            && let Some(paren_idx) = rest.find(") = ")
        {
            let filename = &rest[..paren_idx];
            let hash_val = &rest[paren_idx + 4..];
            return Some((*algo, hash_val, filename));
        }
    }

    // Handle BLAKE2b-NNN (filename) = hash
    if let Some(after) = line.strip_prefix("BLAKE2b-")
        && let Some(sp) = after.find(" (")
        && after[..sp].bytes().all(|b| b.is_ascii_digit())
    {
        let rest = &after[sp + 2..];
        if let Some(paren_idx) = rest.find(") = ") {
            let filename = &rest[..paren_idx];
            let hash_val = &rest[paren_idx + 4..];
            return Some((Algorithm::Blake2b, hash_val, filename));
        }
    }

    // Try standard format: "hash  filename" — detect algo from hash length
    let stripped = line.strip_prefix('\\').unwrap_or(line);
    if let Some(idx) = stripped.find("  ").or_else(|| stripped.find(" *")) {
        let hash_part = &stripped[..idx];
        let filename_part = &stripped[idx + 2..];
        if hash_part.bytes().all(|b| b.is_ascii_hexdigit()) {
            let algo = match hash_part.len() {
                32 => Some(Algorithm::Md5),
                40 => Some(Algorithm::Sha1),
                64 => Some(Algorithm::Sha256),
                128 => Some(Algorithm::Sha512),
                _ => None,
            };
            if let Some(algo) = algo {
                return Some((algo, hash_part, filename_part));
            }
        }
    }

    None
}

/// Detect BLAKE2b bit length from a tag line (e.g., "BLAKE2b-256 (...) = ...").
fn detect_blake2b_bits(line: &str) -> Option<usize> {
    let after = line.strip_prefix("BLAKE2b-")?;
    let sp = after.find(' ')?;
    after[..sp].parse::<usize>().ok()
}

#[allow(dead_code)]
fn run_check_legacy(cli: &Cli, out: &mut impl Write) -> i32 {
    let mut exit_code = 0;

    for filename in &cli.files {
        let reader: Box<dyn BufRead> = if filename == "-" {
            Box::new(BufReader::new(io::stdin().lock()))
        } else {
            match std::fs::File::open(filename) {
                Ok(f) => Box::new(BufReader::new(f)),
                Err(e) => {
                    eprintln!("{}: {}: {}", TOOL_NAME, filename, io_error_msg(&e));
                    exit_code = 1;
                    continue;
                }
            }
        };

        let mut ok_count = 0usize;
        let mut mismatch_count = 0usize;
        let mut format_errors = 0usize;

        for line_result in reader.lines() {
            let line = match line_result {
                Ok(l) => l,
                Err(e) => {
                    eprintln!("{}: {}: {}", TOOL_NAME, filename, io_error_msg(&e));
                    break;
                }
            };
            let line = line.trim_end();
            if line.is_empty() {
                continue;
            }

            // Parse "checksum size filename" format
            let parts: Vec<&str> = line.splitn(3, char::is_whitespace).collect();
            if parts.len() < 3 {
                format_errors += 1;
                continue;
            }
            let expected_cksum: u32 = match parts[0].parse() {
                Ok(v) => v,
                Err(_) => {
                    format_errors += 1;
                    continue;
                }
            };
            let _expected_size: u64 = match parts[1].trim().parse() {
                Ok(v) => v,
                Err(_) => {
                    format_errors += 1;
                    continue;
                }
            };
            let check_filename = parts[2].trim();

            // Recompute
            let actual = if check_filename == "-" {
                match posix_cksum_streaming(io::stdin().lock()) {
                    Ok(v) => v,
                    Err(e) => {
                        eprintln!("{}: -: {}", TOOL_NAME, io_error_msg(&e));
                        mismatch_count += 1;
                        continue;
                    }
                }
            } else {
                match std::fs::File::open(check_filename) {
                    Ok(file) => match posix_cksum_streaming(file) {
                        Ok(v) => v,
                        Err(e) => {
                            eprintln!("{}: {}: {}", TOOL_NAME, check_filename, io_error_msg(&e));
                            mismatch_count += 1;
                            continue;
                        }
                    },
                    Err(e) => {
                        eprintln!("{}: {}: {}", TOOL_NAME, check_filename, io_error_msg(&e));
                        mismatch_count += 1;
                        continue;
                    }
                }
            };

            if actual.0 == expected_cksum {
                ok_count += 1;
                if !cli.quiet && !cli.status {
                    let _ = writeln!(out, "{}: OK", check_filename);
                }
            } else {
                mismatch_count += 1;
                if !cli.status {
                    let _ = writeln!(out, "{}: FAILED", check_filename);
                }
            }
        }

        if mismatch_count > 0 {
            exit_code = 1;
        }
        if ok_count == 0 && mismatch_count == 0 && format_errors > 0 {
            if !cli.status {
                let _ = out.flush();
                eprintln!(
                    "{}: {}: no properly formatted checksum lines found",
                    TOOL_NAME,
                    if filename == "-" {
                        "standard input"
                    } else {
                        filename.as_str()
                    }
                );
            }
            exit_code = 1;
        }
    }

    exit_code
}

// ── Tests ───────────────────────────────────────────────────────────

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
        assert!(stdout.contains("--algorithm"));
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
        assert_eq!(CRC_TABLE[0], 0);
        assert_ne!(CRC_TABLE[255], 0);
    }

    #[test]
    fn test_posix_cksum_empty() {
        let crc = posix_cksum(b"");
        assert_eq!(crc, 4294967295);
    }

    #[test]
    fn test_posix_cksum_hello() {
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

    // ── Multi-algorithm tests ───────────────────────────────────────

    #[test]
    fn test_sha256_empty() {
        let dir = tempfile::tempdir().unwrap();
        let file_path = dir.path().join("empty.txt");
        std::fs::write(&file_path, b"").unwrap();

        let output = cmd()
            .args(["-a", "sha256", file_path.to_str().unwrap()])
            .output()
            .unwrap();
        assert!(output.status.success());
        let stdout = String::from_utf8_lossy(&output.stdout);
        // Tagged format: "SHA256 (file) = hash"
        assert!(stdout.contains("SHA256 ("));
        assert!(
            stdout.contains("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        );
    }

    #[test]
    fn test_md5_empty() {
        let dir = tempfile::tempdir().unwrap();
        let file_path = dir.path().join("empty.txt");
        std::fs::write(&file_path, b"").unwrap();

        let output = cmd()
            .args(["-a", "md5", file_path.to_str().unwrap()])
            .output()
            .unwrap();
        assert!(output.status.success());
        let stdout = String::from_utf8_lossy(&output.stdout);
        assert!(stdout.contains("MD5 ("));
        assert!(stdout.contains("d41d8cd98f00b204e9800998ecf8427e"));
    }

    #[test]
    fn test_untagged_sha256() {
        let dir = tempfile::tempdir().unwrap();
        let file_path = dir.path().join("empty.txt");
        std::fs::write(&file_path, b"").unwrap();

        let output = cmd()
            .args(["--untagged", "-a", "sha256", file_path.to_str().unwrap()])
            .output()
            .unwrap();
        assert!(output.status.success());
        let stdout = String::from_utf8_lossy(&output.stdout);
        // Untagged format: "hash  filename"
        assert!(!stdout.contains("SHA256"));
        assert!(
            stdout.contains("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        );
    }

    #[test]
    fn test_sysv_algorithm() {
        let dir = tempfile::tempdir().unwrap();
        let file_path = dir.path().join("test.txt");
        std::fs::write(&file_path, b"hello\n").unwrap();

        let output = cmd()
            .args(["-a", "sysv", file_path.to_str().unwrap()])
            .output()
            .unwrap();
        assert!(output.status.success());
        let stdout = String::from_utf8_lossy(&output.stdout);
        let parts: Vec<&str> = stdout.split_whitespace().collect();
        assert_eq!(parts[0], "542");
        assert_eq!(parts[1], "1");
    }

    #[test]
    fn test_bsd_algorithm() {
        let dir = tempfile::tempdir().unwrap();
        let file_path = dir.path().join("test.txt");
        std::fs::write(&file_path, b"hello\n").unwrap();

        let output = cmd()
            .args(["-a", "bsd", file_path.to_str().unwrap()])
            .output()
            .unwrap();
        assert!(output.status.success());
    }

    #[test]
    fn test_check_sha256() {
        let dir = tempfile::tempdir().unwrap();
        let input_path = dir.path().join("input.txt");
        std::fs::write(&input_path, b"hello\n").unwrap();

        // Create checksum file in tagged format
        let gen_output = cmd()
            .args(["-a", "sha256", input_path.to_str().unwrap()])
            .output()
            .unwrap();
        assert!(gen_output.status.success());

        let cksum_path = dir.path().join("checksums.sha256");
        std::fs::write(&cksum_path, &gen_output.stdout).unwrap();

        // Verify
        let check_output = cmd()
            .args(["--check", cksum_path.to_str().unwrap()])
            .output()
            .unwrap();
        assert!(
            check_output.status.success(),
            "check mode failed: {}",
            String::from_utf8_lossy(&check_output.stderr)
        );
        let stdout = String::from_utf8_lossy(&check_output.stdout);
        assert!(stdout.contains("OK"));
    }

    #[test]
    fn test_text_tag_accepted() {
        // GNU cksum accepts --text --tag without error
        let dir = tempfile::tempdir().unwrap();
        let file_path = dir.path().join("test.txt");
        std::fs::write(&file_path, b"hello\n").unwrap();

        let output = cmd()
            .args([
                "--text",
                "--tag",
                "-a",
                "sha256",
                file_path.to_str().unwrap(),
            ])
            .output()
            .unwrap();
        assert!(output.status.success());
    }
}
