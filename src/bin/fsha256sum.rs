use std::io::{self, BufReader, BufWriter, Write};
use std::path::Path;
use std::process;

use clap::Parser;
use rayon::prelude::*;

use coreutils_rs::hash::{self, HashAlgorithm};

const TOOL_NAME: &str = "fsha256sum";

#[derive(Parser)]
#[command(name = "fsha256sum", about = "Compute and check SHA256 message digest")]
struct Cli {
    /// Read in binary mode
    #[arg(short = 'b', long = "binary")]
    binary: bool,

    /// Read checksums from the FILEs and check them
    #[arg(short = 'c', long = "check")]
    check: bool,

    /// Create a BSD-style checksum
    #[arg(long = "tag")]
    tag: bool,

    /// Read in text mode (default)
    #[arg(short = 't', long = "text")]
    text: bool,

    /// Don't fail or report status for missing files (check mode)
    #[arg(long = "ignore-missing")]
    ignore_missing: bool,

    /// Don't print OK for each successfully verified file (check mode)
    #[arg(long = "quiet")]
    quiet: bool,

    /// Don't output anything, status code shows success (check mode)
    #[arg(long = "status")]
    status: bool,

    /// Exit non-zero for improperly formatted checksum lines (check mode)
    #[arg(long = "strict")]
    strict: bool,

    /// Warn about improperly formatted checksum lines (check mode)
    #[arg(short = 'w', long = "warn")]
    warn: bool,

    /// End each output line with NUL, not newline
    #[arg(short = 'z', long = "zero")]
    zero: bool,

    /// Files to process
    files: Vec<String>,
}

fn main() {
    let cli = Cli::parse();
    let algo = HashAlgorithm::Sha256;

    let files = if cli.files.is_empty() {
        vec!["-".to_string()]
    } else {
        cli.files.clone()
    };

    let stdout = io::stdout();
    let mut out = BufWriter::new(stdout.lock());
    let mut had_error = false;

    if cli.check {
        run_check_mode(&cli, algo, &files, &mut out, &mut had_error);
    } else {
        run_hash_mode(&cli, algo, &files, &mut out, &mut had_error);
    }

    let _ = out.flush();
    if had_error {
        process::exit(1);
    }
}

fn run_hash_mode(
    cli: &Cli,
    algo: HashAlgorithm,
    files: &[String],
    out: &mut impl Write,
    had_error: &mut bool,
) {
    let has_stdin = files.iter().any(|f| f == "-");

    if has_stdin || files.len() == 1 {
        // Sequential for stdin or single file
        for filename in files {
            let hash_result = if filename == "-" {
                hash::hash_stdin(algo)
            } else {
                hash::hash_file(algo, Path::new(filename))
            };

            match hash_result {
                Ok(h) => {
                    let name = if filename == "-" { "-" } else { filename.as_str() };
                    write_output(out, cli, algo, &h, name);
                }
                Err(e) => {
                    eprintln!("{}: {}: {}", TOOL_NAME, filename, e);
                    *had_error = true;
                }
            }
        }
    } else {
        // Parallel hashing for multiple files
        let results: Vec<(&str, Result<String, io::Error>)> = files
            .par_iter()
            .map(|filename| {
                let result = hash::hash_file(algo, Path::new(filename));
                (filename.as_str(), result)
            })
            .collect();

        for (filename, result) in results {
            match result {
                Ok(h) => {
                    write_output(out, cli, algo, &h, filename);
                }
                Err(e) => {
                    eprintln!("{}: {}: {}", TOOL_NAME, filename, e);
                    *had_error = true;
                }
            }
        }
    }
}

#[inline]
fn write_output(out: &mut impl Write, cli: &Cli, algo: HashAlgorithm, hash: &str, filename: &str) {
    if cli.tag {
        if cli.zero {
            let _ = write!(out, "{} ({}) = {}\0", algo.name(), filename, hash);
        } else {
            let _ = writeln!(out, "{} ({}) = {}", algo.name(), filename, hash);
        }
    } else {
        let mode_char = if cli.binary { '*' } else { ' ' };
        if cli.zero {
            let _ = write!(out, "{} {}{}\0", hash, mode_char, filename);
        } else {
            let _ = writeln!(out, "{} {}{}", hash, mode_char, filename);
        }
    }
}

fn run_check_mode(
    cli: &Cli,
    algo: HashAlgorithm,
    files: &[String],
    out: &mut impl Write,
    had_error: &mut bool,
) {
    let mut _total_ok: usize = 0;
    let mut total_mismatches: usize = 0;
    let mut total_fmt_errors: usize = 0;
    let mut total_read_errors: usize = 0;

    for filename in files {
        let reader: Box<dyn io::BufRead> = if filename == "-" {
            Box::new(BufReader::new(io::stdin().lock()))
        } else {
            match std::fs::File::open(filename) {
                Ok(f) => Box::new(BufReader::new(f)),
                Err(e) => {
                    eprintln!("{}: {}: {}", TOOL_NAME, filename, e);
                    *had_error = true;
                    continue;
                }
            }
        };

        let mut err_out = io::stderr();
        let opts = hash::CheckOptions {
            quiet: cli.quiet,
            status_only: cli.status,
            strict: cli.strict,
            warn: cli.warn,
            ignore_missing: cli.ignore_missing,
            warn_prefix: String::new(),
        };

        match hash::check_file(algo, reader, &opts, out, &mut err_out) {
            Ok(r) => {
                _total_ok += r.ok;
                total_mismatches += r.mismatches;
                total_fmt_errors += r.format_errors;
                total_read_errors += r.read_errors;
                if r.mismatches > 0 || r.read_errors > 0 {
                    *had_error = true;
                }
                if cli.strict && r.format_errors > 0 {
                    *had_error = true;
                }
            }
            Err(e) => {
                eprintln!("{}: {}: {}", TOOL_NAME, filename, e);
                *had_error = true;
            }
        }
    }

    // Print GNU-style summary warnings to stderr
    if !cli.status {
        if total_read_errors > 0 {
            let word = if total_read_errors == 1 {
                "listed file could not be read"
            } else {
                "listed files could not be read"
            };
            eprintln!(
                "{}: WARNING: {} {}",
                TOOL_NAME, total_read_errors, word
            );
        }

        if total_fmt_errors > 0 {
            let line_word = if total_fmt_errors == 1 {
                "line is"
            } else {
                "lines are"
            };
            eprintln!(
                "{}: WARNING: {} {} improperly formatted",
                TOOL_NAME, total_fmt_errors, line_word
            );
        }

        if total_mismatches > 0 {
            let checksum_word = if total_mismatches == 1 {
                "computed checksum did NOT match"
            } else {
                "computed checksums did NOT match"
            };
            eprintln!(
                "{}: WARNING: {} {}",
                TOOL_NAME, total_mismatches, checksum_word
            );
        }
    }
}
