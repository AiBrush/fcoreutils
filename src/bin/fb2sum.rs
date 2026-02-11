use std::io::{self, BufRead, BufReader, BufWriter, Write};
use std::path::Path;
use std::process;

use clap::Parser;

use coreutils_rs::hash;

#[derive(Parser)]
#[command(
    name = "fb2sum",
    about = "Compute and check BLAKE2b message digest",
    after_help = "With no FILE, or when FILE is -, read standard input."
)]
struct Cli {
    /// Read in binary mode
    #[arg(short = 'b', long = "binary")]
    binary: bool,

    /// Read checksums from the FILEs and check them
    #[arg(short = 'c', long = "check")]
    check: bool,

    /// Don't fail or report status for missing files
    #[arg(long = "ignore-missing")]
    ignore_missing: bool,

    /// Digest length in bits; must not exceed 512 and must be a multiple of 8
    #[arg(short = 'l', long = "length", default_value = "0")]
    length: usize,

    /// Don't print OK for each successfully verified file
    #[arg(long = "quiet")]
    quiet: bool,

    /// Don't output anything, status code shows success
    #[arg(long = "status")]
    status: bool,

    /// Exit non-zero for improperly formatted checksum lines
    #[arg(long = "strict")]
    strict: bool,

    /// Read in text mode (default)
    #[arg(short = 't', long = "text")]
    text: bool,

    /// Create a BSD-style checksum
    #[arg(long = "tag")]
    tag: bool,

    /// Warn about improperly formatted checksum lines
    #[arg(short = 'w', long = "warn")]
    warn: bool,

    /// End each output line with NUL, not newline, and disable file name escaping
    #[arg(short = 'z', long = "zero")]
    zero: bool,

    /// Files to process
    files: Vec<String>,
}

/// Check if a filename needs escaping (contains backslash or newline).
fn needs_escape(name: &str) -> bool {
    name.bytes().any(|b| b == b'\\' || b == b'\n')
}

/// Escape a filename: replace `\` with `\\` and `\n` with `\n` (literal).
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

fn main() {
    let cli = Cli::parse();

    // -l 0 means use default (512), matching GNU behavior
    let length = if cli.length == 0 { 512 } else { cli.length };

    // Validate length
    if length > 512 {
        // GNU silently uses 512 for values > 512
        // We match that behavior
    }
    let length = if length > 512 { 512 } else { length };

    if length % 8 != 0 {
        eprintln!("fb2sum: invalid length: '{}'", cli.length);
        eprintln!("fb2sum: length is not a multiple of 8");
        process::exit(1);
    }

    // Validate flag combinations
    if cli.tag && cli.check {
        eprintln!("fb2sum: the --tag option is meaningless when verifying checksums");
        process::exit(1);
    }

    let output_bytes = length / 8;
    let files = if cli.files.is_empty() {
        vec!["-".to_string()]
    } else {
        cli.files.clone()
    };

    let stdout = io::stdout();
    let mut out = BufWriter::new(stdout.lock());

    let had_error = if cli.check {
        run_check_mode(&cli, &files, &mut out)
    } else {
        run_hash_mode(&cli, &files, output_bytes, &mut out)
    };

    let _ = out.flush();
    if had_error {
        process::exit(1);
    }
}

fn run_hash_mode(cli: &Cli, files: &[String], output_bytes: usize, out: &mut impl Write) -> bool {
    let mut had_error = false;

    for filename in files {
        let hash_result = if filename == "-" {
            hash::blake2b_hash_stdin(output_bytes)
        } else {
            hash::blake2b_hash_file(Path::new(filename), output_bytes)
        };

        match hash_result {
            Ok(h) => {
                let display_name = if filename == "-" {
                    "-"
                } else {
                    filename.as_str()
                };
                if cli.tag {
                    // Tag mode: no escaping needed per GNU behavior
                    if cli.zero {
                        let _ =
                            hash::print_hash_tag_b2sum_zero(out, &h, display_name, output_bytes * 8);
                    } else {
                        let _ =
                            hash::print_hash_tag_b2sum(out, &h, display_name, output_bytes * 8);
                    }
                } else if cli.zero {
                    // -z mode: no escaping, NUL terminator
                    let _ = hash::print_hash_zero(out, &h, display_name, cli.binary);
                } else if needs_escape(display_name) {
                    // Escape filename and prefix with backslash
                    let escaped = escape_filename(display_name);
                    let mode_char = if cli.binary { '*' } else { ' ' };
                    let _ = writeln!(out, "\\{}  {}{}", h, mode_char, escaped);
                } else {
                    let _ = hash::print_hash(out, &h, display_name, cli.binary);
                }
            }
            Err(e) => {
                eprintln!("fb2sum: {}: {}", filename, io_error_msg(&e));
                had_error = true;
            }
        }
    }

    had_error
}

fn run_check_mode(cli: &Cli, files: &[String], out: &mut impl Write) -> bool {
    let mut had_error = false;
    let mut total_ok: usize = 0;
    let mut total_fail: usize = 0;
    let mut total_fmt_errors: usize = 0;
    let mut total_missing: usize = 0;
    let mut _total_read_errors: usize = 0;

    for filename in files {
        let reader: Box<dyn BufRead> = if filename == "-" {
            Box::new(BufReader::new(io::stdin().lock()))
        } else {
            match std::fs::File::open(filename) {
                Ok(f) => Box::new(BufReader::new(f)),
                Err(e) => {
                    eprintln!("fb2sum: {}: {}", filename, io_error_msg(&e));
                    had_error = true;
                    continue;
                }
            }
        };

        let mut file_ok: usize = 0;
        let mut file_fail: usize = 0;
        let mut file_fmt_errors: usize = 0;
        let mut line_num: usize = 0;

        for line_result in reader.lines() {
            line_num += 1;
            let line = match line_result {
                Ok(l) => l,
                Err(e) => {
                    eprintln!("fb2sum: {}: {}", filename, io_error_msg(&e));
                    had_error = true;
                    break;
                }
            };
            let line = line.trim_end_matches(['\r', '\n']);
            if line.is_empty() {
                continue;
            }

            // Handle backslash-escaped lines
            let line_content = line.strip_prefix('\\').unwrap_or(line);

            // Try parsing: standard format, then BSD tag format
            let (expected_hash, check_filename) =
                if let Some((h, f)) = hash::parse_check_line(line_content) {
                    (h.to_string(), f.to_string())
                } else if let Some((h, f, _bits)) = hash::parse_check_line_tag(line_content) {
                    (h.to_string(), f.to_string())
                } else {
                    file_fmt_errors += 1;
                    if cli.warn {
                        eprintln!(
                            "fb2sum: {}: {}: improperly formatted BLAKE2b checksum line",
                            filename, line_num
                        );
                    }
                    continue;
                };

            // Validate hash: must be valid hex, even length, max 128 hex chars (64 bytes = 512 bits)
            if expected_hash.is_empty()
                || expected_hash.len() % 2 != 0
                || expected_hash.len() > 128
                || !expected_hash.bytes().all(|b| b.is_ascii_hexdigit())
            {
                file_fmt_errors += 1;
                if cli.warn {
                    eprintln!(
                        "fb2sum: {}: {}: improperly formatted BLAKE2b checksum line",
                        filename, line_num
                    );
                }
                continue;
            }
            let hash_bytes = expected_hash.len() / 2;

            // Unescape filename if original line was backslash-prefixed
            let check_filename = if line.starts_with('\\') {
                unescape_filename(&check_filename)
            } else {
                check_filename
            };

            // Hash the file with inferred length
            let actual =
                match hash::blake2b_hash_file(Path::new(&check_filename), hash_bytes) {
                    Ok(h) => h,
                    Err(e) => {
                        if e.kind() == io::ErrorKind::NotFound {
                            if cli.ignore_missing {
                                total_missing += 1;
                                continue;
                            }
                        }
                        _total_read_errors += 1;
                        file_fail += 1;
                        if !cli.status {
                            eprintln!("fb2sum: {}: {}", check_filename, io_error_msg(&e));
                            writeln!(out, "{}: FAILED open or read", check_filename).ok();
                        }
                        continue;
                    }
                };

            if actual.eq_ignore_ascii_case(&expected_hash) {
                file_ok += 1;
                if !cli.quiet && !cli.status {
                    writeln!(out, "{}: OK", check_filename).ok();
                }
            } else {
                file_fail += 1;
                if !cli.status {
                    writeln!(out, "{}: FAILED", check_filename).ok();
                }
            }
        }

        // Per-file: "no properly formatted checksum lines found"
        if file_ok == 0 && file_fail == 0 && file_fmt_errors > 0 {
            if !cli.status {
                eprintln!(
                    "fb2sum: {}: no properly formatted BLAKE2b checksum lines found",
                    filename
                );
            }
            had_error = true;
        }

        total_ok += file_ok;
        total_fail += file_fail;
        total_fmt_errors += file_fmt_errors;
    }

    // Print summary messages
    if !cli.status {
        if total_fail > 0 {
            eprintln!(
                "fb2sum: WARNING: {} computed checksum{} did NOT match",
                total_fail,
                if total_fail == 1 { "" } else { "s" }
            );
        }
        if total_fmt_errors > 0 && (cli.warn || cli.strict) {
            eprintln!(
                "fb2sum: WARNING: {} line{} {} improperly formatted",
                total_fmt_errors,
                if total_fmt_errors == 1 { "" } else { "s" },
                if total_fmt_errors == 1 { "is" } else { "are" }
            );
        }
        if cli.ignore_missing && total_missing > 0 && total_ok == 0 && total_fail == 0 {
            eprintln!("fb2sum: WARNING: no file was verified");
            had_error = true;
        }
    }

    if total_fail > 0 {
        had_error = true;
    }
    if cli.strict && total_fmt_errors > 0 {
        had_error = true;
    }

    had_error
}

/// Unescape a checksum-line filename: `\\` -> `\`, `\n` -> newline
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

/// Format an IO error message without the "(os error N)" suffix.
fn io_error_msg(e: &io::Error) -> String {
    // Use the OS-level description when available for cleaner messages
    if let Some(raw) = e.raw_os_error() {
        // Get the raw OS error message
        let os_err = io::Error::from_raw_os_error(raw);
        format!("{}", os_err).replace(&format!(" (os error {})", raw), "")
    } else {
        format!("{}", e)
    }
}
