use std::io::{self, Write};
use std::path::Path;
use std::process;

use clap::Parser;

use coreutils_rs::common::io::{read_file_bytes, read_stdin};
use coreutils_rs::wc;

#[derive(Parser)]
#[command(name = "fwc", about = "Print newline, word, and byte counts for each FILE")]
struct Cli {
    /// Print the byte counts
    #[arg(short = 'c', long = "bytes")]
    bytes: bool,

    /// Print the character counts
    #[arg(short = 'm', long = "chars")]
    chars: bool,

    /// Print the newline counts
    #[arg(short = 'l', long = "lines")]
    lines: bool,

    /// Print the maximum display width
    #[arg(short = 'L', long = "max-line-length")]
    max_line_length: bool,

    /// Print the word counts
    #[arg(short = 'w', long = "words")]
    words: bool,

    /// Read input from the files specified by NUL-terminated names in file F
    #[arg(long = "files0-from", value_name = "F")]
    files0_from: Option<String>,

    /// When to print a line with total counts; WHEN can be: auto, always, never, only
    #[arg(long = "total", value_name = "WHEN", default_value = "auto")]
    total: String,

    /// Files to process (reads stdin if none given)
    files: Vec<String>,
}

/// Which fields to display.
struct ShowFlags {
    lines: bool,
    words: bool,
    bytes: bool,
    chars: bool,
    max_line_length: bool,
}

/// Compute number of decimal digits needed to display a value.
fn num_width(n: u64) -> usize {
    if n == 0 {
        return 1;
    }
    ((n as f64).log10().floor() as usize) + 1
}

fn main() {
    let cli = Cli::parse();

    // If no flags specified, default to -lwc (lines, words, bytes)
    let no_explicit = !cli.bytes && !cli.chars && !cli.words && !cli.lines && !cli.max_line_length;
    let show = ShowFlags {
        lines: cli.lines || no_explicit,
        words: cli.words || no_explicit,
        bytes: cli.bytes || (no_explicit && !cli.chars),
        chars: cli.chars,
        max_line_length: cli.max_line_length,
    };

    // Collect files to process
    let files: Vec<String> = if let Some(ref f0f) = cli.files0_from {
        read_files0_from(f0f)
    } else if cli.files.is_empty() {
        vec!["-".to_string()] // stdin
    } else {
        cli.files.clone()
    };

    // Phase 1: Compute all counts
    let mut results: Vec<(wc::WcCounts, String)> = Vec::new();
    let mut total = wc::WcCounts::default();
    let mut had_error = false;
    let mut has_stdin = false;

    for filename in &files {
        if filename == "-" {
            has_stdin = true;
        }

        let data = if filename == "-" {
            match read_stdin() {
                Ok(d) => d,
                Err(e) => {
                    eprintln!("fwc: standard input: {}", e);
                    had_error = true;
                    continue;
                }
            }
        } else {
            match read_file_bytes(Path::new(filename)) {
                Ok(d) => d,
                Err(e) => {
                    eprintln!("fwc: {}: {}", filename, e);
                    had_error = true;
                    continue;
                }
            }
        };

        let counts = if show.max_line_length || (show.lines && show.words && show.chars) {
            wc::count_all(&data)
        } else {
            wc::WcCounts {
                lines: if show.lines { wc::count_lines(&data) } else { 0 },
                words: if show.words { wc::count_words(&data) } else { 0 },
                bytes: if show.bytes { wc::count_bytes(&data) } else { 0 },
                chars: if show.chars { wc::count_chars(&data) } else { 0 },
                max_line_length: 0,
            }
        };

        total.lines += counts.lines;
        total.words += counts.words;
        total.bytes += counts.bytes;
        total.chars += counts.chars;
        if counts.max_line_length > total.max_line_length {
            total.max_line_length = counts.max_line_length;
        }

        let display_name = if filename == "-" {
            String::new()
        } else {
            filename.clone()
        };
        results.push((counts, display_name));
    }

    // Phase 2: Compute column width
    // GNU wc uses the digit width of the largest value across totals.
    // For stdin with no files, GNU uses a default minimum width of 7.
    let min_width = if has_stdin && results.len() == 1 { 7 } else { 1 };

    let max_val = [total.lines, total.words, total.bytes, total.chars, total.max_line_length]
        .into_iter()
        .max()
        .unwrap_or(0);

    let width = num_width(max_val).max(min_width);

    // Phase 3: Print results
    let show_total = match cli.total.as_str() {
        "always" => true,
        "never" => false,
        "only" => true,
        _ => results.len() > 1, // "auto"
    };

    let stdout = io::stdout();
    let mut out = stdout.lock();

    for (counts, name) in &results {
        print_counts_fmt(&mut out, counts, name, width, &show);
    }

    if show_total {
        print_counts_fmt(&mut out, &total, "total", width, &show);
    }

    if had_error {
        process::exit(1);
    }
}

/// Print count values in GNU-compatible format.
/// GNU wc format: first field right-aligned to `width`, subsequent fields
/// preceded by a space and right-aligned to `width`.
fn print_counts_fmt(
    out: &mut impl Write,
    counts: &wc::WcCounts,
    filename: &str,
    width: usize,
    show: &ShowFlags,
) {
    let mut first = true;

    macro_rules! field {
        ($val:expr) => {
            if first {
                let _ = write!(out, "{:>w$}", $val, w = width);
            } else {
                let _ = write!(out, " {:>w$}", $val, w = width);
            }
            #[allow(unused_assignments)]
            {
                first = false;
            }
        };
    }

    if show.lines {
        field!(counts.lines);
    }
    if show.words {
        field!(counts.words);
    }
    if show.bytes {
        field!(counts.bytes);
    }
    if show.chars {
        field!(counts.chars);
    }
    if show.max_line_length {
        field!(counts.max_line_length);
    }

    if !filename.is_empty() {
        let _ = write!(out, " {}", filename);
    }
    let _ = writeln!(out);
}

/// Read NUL-terminated filenames from a file (or stdin if "-").
fn read_files0_from(path: &str) -> Vec<String> {
    let data = if path == "-" {
        read_stdin().unwrap_or_default()
    } else {
        std::fs::read(path).unwrap_or_else(|e| {
            eprintln!("fwc: cannot open '{}' for reading: {}", path, e);
            process::exit(1);
        })
    };

    data.split(|&b| b == 0)
        .filter(|s| !s.is_empty())
        .map(|s| String::from_utf8_lossy(s).into_owned())
        .collect()
}
