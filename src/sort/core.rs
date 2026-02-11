/// Core sorting logic for fsort.
use std::cmp::Ordering;
use std::fs::File;
use std::io::{self, BufRead, BufReader, BufWriter, Read, Write};

use rayon::prelude::*;

use super::compare::compare_with_opts;
use super::key::{KeyDef, KeyOpts, extract_key};

/// Configuration for a sort operation.
#[derive(Debug, Clone)]
pub struct SortConfig {
    pub keys: Vec<KeyDef>,
    pub separator: Option<u8>,
    pub global_opts: KeyOpts,
    pub unique: bool,
    pub stable: bool,
    pub reverse: bool,
    pub check: CheckMode,
    pub merge: bool,
    pub output_file: Option<String>,
    pub zero_terminated: bool,
    pub parallel: Option<usize>,
    pub buffer_size: Option<usize>,
    pub temp_dir: Option<String>,
    pub random_seed: u64,
}

#[derive(Debug, Clone, PartialEq)]
pub enum CheckMode {
    None,
    Diagnose,
    Quiet,
}

impl Default for SortConfig {
    fn default() -> Self {
        SortConfig {
            keys: Vec::new(),
            separator: None,
            global_opts: KeyOpts::default(),
            unique: false,
            stable: false,
            reverse: false,
            check: CheckMode::None,
            merge: false,
            output_file: None,
            zero_terminated: false,
            parallel: None,
            buffer_size: None,
            temp_dir: None,
            random_seed: 0,
        }
    }
}

/// Compare two lines using the full key chain and global options.
pub fn compare_lines(a: &[u8], b: &[u8], config: &SortConfig) -> Ordering {
    if !config.keys.is_empty() {
        for key in &config.keys {
            let ka = extract_key(a, key, config.separator);
            let kb = extract_key(b, key, config.separator);

            let opts = if key.opts.has_sort_type()
                || key.opts.ignore_case
                || key.opts.dictionary_order
                || key.opts.ignore_nonprinting
                || key.opts.ignore_leading_blanks
                || key.opts.reverse
            {
                &key.opts
            } else {
                &config.global_opts
            };

            let result = compare_with_opts(ka, kb, opts, config.random_seed);

            if result != Ordering::Equal {
                return result;
            }
        }

        // All keys equal: last-resort comparison (whole line) unless -s
        if !config.stable {
            return a.cmp(b);
        }

        Ordering::Equal
    } else {
        // No keys: compare whole line with global opts
        let mut result = compare_with_opts(a, b, &config.global_opts, config.random_seed);
        if config.reverse && !config.global_opts.reverse {
            result = result.reverse();
        }
        result
    }
}

/// Read all lines from inputs.
pub fn read_lines(inputs: &[String], zero_terminated: bool) -> io::Result<Vec<Vec<u8>>> {
    let delimiter = if zero_terminated { b'\0' } else { b'\n' };
    let mut lines = Vec::new();

    for input in inputs {
        if input == "-" {
            let stdin = io::stdin();
            let reader = BufReader::new(stdin.lock());
            read_delimited_lines(reader, delimiter, &mut lines)?;
        } else {
            let file = File::open(input).map_err(|e| {
                io::Error::new(e.kind(), format!("open failed: {}: {}", input, e))
            })?;
            let reader = BufReader::with_capacity(256 * 1024, file);
            read_delimited_lines(reader, delimiter, &mut lines)?;
        }
    }

    Ok(lines)
}

fn read_delimited_lines<R: Read>(
    mut reader: BufReader<R>,
    delimiter: u8,
    lines: &mut Vec<Vec<u8>>,
) -> io::Result<()> {
    let mut buf = Vec::with_capacity(256);
    loop {
        buf.clear();
        let n = reader.read_until(delimiter, &mut buf)?;
        if n == 0 {
            break;
        }
        if buf.last() == Some(&delimiter) {
            buf.pop();
        }
        if delimiter == b'\n' && buf.last() == Some(&b'\r') {
            buf.pop();
        }
        lines.push(buf.clone());
    }
    Ok(())
}

/// Check if input is sorted.
pub fn check_sorted(inputs: &[String], config: &SortConfig) -> io::Result<bool> {
    let lines = read_lines(inputs, config.zero_terminated)?;

    for i in 1..lines.len() {
        let cmp = compare_lines(&lines[i - 1], &lines[i], config);
        let bad = if config.unique {
            cmp != Ordering::Less
        } else {
            cmp == Ordering::Greater
        };
        if bad {
            if config.check == CheckMode::Diagnose {
                let line_display = String::from_utf8_lossy(&lines[i]);
                let filename = if inputs.is_empty() || inputs[0] == "-" {
                    "-"
                } else {
                    &inputs[0]
                };
                eprintln!("fsort: {}:{}: disorder: {}", filename, i + 1, line_display);
            }
            return Ok(false);
        }
    }
    Ok(true)
}

/// Merge already-sorted files.
pub fn merge_sorted(
    inputs: &[String],
    config: &SortConfig,
    writer: &mut impl Write,
) -> io::Result<()> {
    let delimiter = if config.zero_terminated { b'\0' } else { b'\n' };
    let mut all_lines: Vec<Vec<Vec<u8>>> = Vec::new();

    for input in inputs {
        let mut file_lines = Vec::new();
        if input == "-" {
            let reader = BufReader::new(io::stdin().lock());
            read_delimited_lines(reader, delimiter, &mut file_lines)?;
        } else {
            let file = File::open(input)?;
            let reader = BufReader::with_capacity(256 * 1024, file);
            read_delimited_lines(reader, delimiter, &mut file_lines)?;
        }
        all_lines.push(file_lines);
    }

    let mut indices: Vec<usize> = vec![0; all_lines.len()];
    let mut prev_line: Option<Vec<u8>> = None;
    let terminator: &[u8] = if config.zero_terminated { b"\0" } else { b"\n" };

    loop {
        let mut best: Option<(usize, &[u8])> = None;
        for (i, file_lines) in all_lines.iter().enumerate() {
            if indices[i] < file_lines.len() {
                let line = &file_lines[indices[i]];
                match best {
                    None => best = Some((i, line)),
                    Some((_, best_line)) => {
                        if compare_lines(line, best_line, config) == Ordering::Less {
                            best = Some((i, line));
                        }
                    }
                }
            }
        }

        match best {
            None => break,
            Some((idx, line)) => {
                let should_output = if config.unique {
                    match &prev_line {
                        Some(prev) => compare_lines(prev, line, config) != Ordering::Equal,
                        None => true,
                    }
                } else {
                    true
                };

                if should_output {
                    writer.write_all(line)?;
                    writer.write_all(terminator)?;
                    prev_line = Some(line.to_vec());
                }
                indices[idx] += 1;
            }
        }
    }

    Ok(())
}

/// Main sort entry point.
pub fn sort_and_output(inputs: &[String], config: &SortConfig) -> io::Result<()> {
    if let Some(n) = config.parallel {
        let n = n.max(1);
        rayon::ThreadPoolBuilder::new()
            .num_threads(n)
            .build_global()
            .ok();
    }

    if config.check != CheckMode::None {
        let sorted = check_sorted(inputs, config)?;
        if !sorted {
            std::process::exit(1);
        }
        return Ok(());
    }

    let stdout = io::stdout();
    let output: Box<dyn Write> = if let Some(ref path) = config.output_file {
        Box::new(BufWriter::with_capacity(256 * 1024, File::create(path)?))
    } else {
        Box::new(BufWriter::with_capacity(256 * 1024, stdout.lock()))
    };
    let mut writer = output;

    if config.merge {
        return merge_sorted(inputs, config, &mut writer);
    }

    let mut lines = read_lines(inputs, config.zero_terminated)?;

    let config_ref = config;
    if lines.len() > 10_000 {
        lines.par_sort_by(|a, b| compare_lines(a, b, config_ref));
    } else {
        lines.sort_by(|a, b| compare_lines(a, b, config_ref));
    }

    let terminator: &[u8] = if config.zero_terminated { b"\0" } else { b"\n" };

    if config.unique {
        let mut prev: Option<&[u8]> = None;
        for line in &lines {
            let should_output = match prev {
                Some(p) => compare_lines(p, line, config_ref) != Ordering::Equal,
                None => true,
            };
            if should_output {
                writer.write_all(line)?;
                writer.write_all(terminator)?;
                prev = Some(line);
            }
        }
    } else {
        for line in &lines {
            writer.write_all(line)?;
            writer.write_all(terminator)?;
        }
    }

    writer.flush()?;
    Ok(())
}

/// Parse a buffer size string like "10K", "1M", "1G".
pub fn parse_buffer_size(s: &str) -> Result<usize, String> {
    let s = s.trim();
    if s.is_empty() {
        return Err("empty buffer size".to_string());
    }

    let (num_part, suffix) = if s.ends_with(|c: char| c.is_ascii_alphabetic()) {
        let (n, s) = s.split_at(s.len() - 1);
        (n, s.chars().next())
    } else {
        (s, None)
    };

    let base: usize = num_part
        .parse()
        .map_err(|_| format!("invalid buffer size: {}", s))?;

    let multiplier = match suffix {
        Some('K') | Some('k') => 1024,
        Some('M') | Some('m') => 1024 * 1024,
        Some('G') | Some('g') => 1024 * 1024 * 1024,
        Some('T') | Some('t') => 1024usize.pow(4),
        Some('b') => 512,
        Some(c) => return Err(format!("invalid suffix '{}' in buffer size", c)),
        None => 1,
    };

    Ok(base * multiplier)
}
