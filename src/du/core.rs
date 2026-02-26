use std::collections::HashSet;
use std::io::{self, BufRead, Write};
use std::os::unix::fs::MetadataExt;
use std::path::{Path, PathBuf};
use std::time::SystemTime;

/// Configuration for the `du` command.
pub struct DuConfig {
    /// Show counts for all files, not just directories.
    pub all: bool,
    /// Print apparent sizes rather than disk usage.
    pub apparent_size: bool,
    /// Block size for output scaling.
    pub block_size: u64,
    /// Human-readable output (powers of 1024).
    pub human_readable: bool,
    /// Human-readable output (powers of 1000).
    pub si: bool,
    /// Produce a grand total.
    pub total: bool,
    /// Maximum depth of directory traversal to display.
    pub max_depth: Option<usize>,
    /// Only display a total for each argument.
    pub summarize: bool,
    /// Stay on the same filesystem.
    pub one_file_system: bool,
    /// Dereference all symbolic links.
    pub dereference: bool,
    /// Dereference only command-line symlink arguments (-D / -H / --dereference-args).
    pub dereference_args: bool,
    /// For directories, do not include size of subdirectories.
    pub separate_dirs: bool,
    /// Count sizes of hard-linked files multiple times.
    pub count_links: bool,
    /// End output lines with NUL instead of newline.
    pub null_terminator: bool,
    /// Exclude entries smaller (or larger if negative) than this threshold.
    pub threshold: Option<i64>,
    /// Show modification time of entries.
    pub show_time: bool,
    /// Time format style (full-iso, long-iso, iso).
    pub time_style: String,
    /// Glob patterns to exclude.
    pub exclude_patterns: Vec<String>,
    /// Count inodes instead of sizes.
    pub inodes: bool,
}

impl Default for DuConfig {
    fn default() -> Self {
        DuConfig {
            all: false,
            apparent_size: false,
            block_size: 1024,
            human_readable: false,
            si: false,
            total: false,
            max_depth: None,
            summarize: false,
            one_file_system: false,
            dereference: false,
            dereference_args: false,
            separate_dirs: false,
            count_links: false,
            null_terminator: false,
            threshold: None,
            show_time: false,
            time_style: "long-iso".to_string(),
            exclude_patterns: Vec::new(),
            inodes: false,
        }
    }
}

/// A single entry produced by `du` traversal.
pub struct DuEntry {
    /// Size in bytes (or inode count if inodes mode).
    pub size: u64,
    /// Path of the entry.
    pub path: PathBuf,
    /// Modification time (seconds since epoch), if available.
    pub mtime: Option<i64>,
}

/// Traverse `path` and collect `DuEntry` results according to `config`.
pub fn du_path(path: &Path, config: &DuConfig) -> io::Result<Vec<DuEntry>> {
    let mut seen_inodes: HashSet<(u64, u64)> = HashSet::new();
    let mut had_error = false;
    du_path_with_seen(path, config, &mut seen_inodes, &mut had_error)
}

/// Traverse `path` with a shared inode set (for deduplication across multiple arguments).
/// Sets `had_error` to true if any permission or access errors are encountered.
pub fn du_path_with_seen(
    path: &Path,
    config: &DuConfig,
    seen_inodes: &mut HashSet<(u64, u64)>,
    had_error: &mut bool,
) -> io::Result<Vec<DuEntry>> {
    let mut entries = Vec::new();
    du_recursive(path, config, seen_inodes, &mut entries, 0, None, had_error)?;
    Ok(entries)
}

/// Check whether a path should be excluded by any of the exclude patterns.
/// GNU du matches the pattern against the basename and the full path.
fn is_excluded(path: &Path, config: &DuConfig) -> bool {
    if config.exclude_patterns.is_empty() {
        return false;
    }
    let path_str = path.to_string_lossy();
    let basename = path
        .file_name()
        .map(|n| n.to_string_lossy())
        .unwrap_or_default();
    config
        .exclude_patterns
        .iter()
        .any(|pat| glob_match(pat, &basename) || glob_match(pat, &path_str))
}

/// Recursive traversal core. Returns the cumulative size of the subtree at `path`.
fn du_recursive(
    path: &Path,
    config: &DuConfig,
    seen: &mut HashSet<(u64, u64)>,
    entries: &mut Vec<DuEntry>,
    depth: usize,
    root_dev: Option<u64>,
    had_error: &mut bool,
) -> io::Result<u64> {
    // Check exclude patterns against this path (GNU du applies exclude to all entries
    // including the root argument itself).
    if is_excluded(path, config) {
        return Ok(0);
    }

    // For depth 0 (command-line arguments), dereference_args means follow symlinks.
    let meta = if config.dereference || (depth == 0 && config.dereference_args) {
        std::fs::metadata(path)?
    } else {
        std::fs::symlink_metadata(path)?
    };

    // Check one-file-system: skip entries on different devices.
    if let Some(dev) = root_dev {
        if meta.dev() != dev && config.one_file_system {
            return Ok(0);
        }
    }

    // Track hard links: skip files we have already counted (unless --count-links).
    let ino_key = (meta.dev(), meta.ino());
    if meta.nlink() > 1 && !config.count_links {
        if !seen.insert(ino_key) {
            return Ok(0);
        }
    }

    let size = if config.inodes {
        1
    } else if config.apparent_size {
        // GNU du uses 0 for directory entries themselves in apparent-size mode;
        // only file content sizes are counted.
        if meta.is_dir() { 0 } else { meta.len() }
    } else {
        meta.blocks() * 512
    };

    let mtime = meta.mtime();

    if meta.is_dir() {
        // Track the full subtree size (for returning to parent)
        // and the display size (what we show for this directory).
        let mut subtree_size: u64 = size;
        // For separate_dirs, display size only includes this dir + direct files, not subdirs.
        let mut display_size: u64 = size;

        let read_dir = match std::fs::read_dir(path) {
            Ok(rd) => rd,
            Err(e) => {
                eprintln!(
                    "du: cannot read directory '{}': {}",
                    path.display(),
                    format_io_error(&e)
                );
                *had_error = true;
                // Still report what we can for this directory.
                if should_report_dir(config, depth) {
                    entries.push(DuEntry {
                        size,
                        path: path.to_path_buf(),
                        mtime: if config.show_time { Some(mtime) } else { None },
                    });
                }
                return Ok(size);
            }
        };

        for entry in read_dir {
            let entry = match entry {
                Ok(e) => e,
                Err(e) => {
                    eprintln!(
                        "du: cannot access entry in '{}': {}",
                        path.display(),
                        format_io_error(&e)
                    );
                    *had_error = true;
                    continue;
                }
            };
            let child_path = entry.path();

            // Check exclude patterns against both basename and full path (GNU compat).
            if is_excluded(&child_path, config) {
                continue;
            }

            // Check if child is a directory (for separate_dirs logic).
            let child_is_dir = child_path.symlink_metadata().map_or(false, |m| m.is_dir());

            let child_size = du_recursive(
                &child_path,
                config,
                seen,
                entries,
                depth + 1,
                Some(root_dev.unwrap_or(meta.dev())),
                had_error,
            )?;
            subtree_size += child_size;
            if config.separate_dirs && child_is_dir {
                // Don't add subdirectory sizes to display size.
            } else {
                display_size += child_size;
            }
        }

        // Emit an entry for this directory if within display depth.
        if should_report_dir(config, depth) {
            entries.push(DuEntry {
                size: display_size,
                path: path.to_path_buf(),
                mtime: if config.show_time { Some(mtime) } else { None },
            });
        }

        Ok(subtree_size)
    } else {
        // Regular file / symlink / special file.
        // Always report top-level arguments (depth 0), or all files if --all.
        if (depth == 0 || config.all) && within_depth(config, depth) {
            entries.push(DuEntry {
                size,
                path: path.to_path_buf(),
                mtime: if config.show_time { Some(mtime) } else { None },
            });
        }
        Ok(size)
    }
}

/// Whether a directory entry at `depth` should be reported.
fn should_report_dir(config: &DuConfig, depth: usize) -> bool {
    if config.summarize {
        return depth == 0;
    }
    within_depth(config, depth)
}

/// Whether `depth` is within the configured max_depth.
fn within_depth(config: &DuConfig, depth: usize) -> bool {
    match config.max_depth {
        Some(max) => depth <= max,
        None => true,
    }
}

/// Glob matching supporting `*`, `?`, and `[...]`/`[^...]` character classes.
/// Compatible with fnmatch(3) FNM_PATHNAME-less matching used by GNU du.
pub fn glob_match(pattern: &str, text: &str) -> bool {
    let pat: Vec<char> = pattern.chars().collect();
    let txt: Vec<char> = text.chars().collect();
    glob_match_inner(&pat, &txt)
}

/// Try to match a `[...]` or `[^...]` bracket expression starting at `pat[start]` (which is `[`).
/// Returns `Some((matched_char, end_index))` where `end_index` is the index after `]`,
/// or `None` if the bracket expression is malformed.
fn match_bracket_class(pat: &[char], start: usize, ch: char) -> Option<(bool, usize)> {
    let mut i = start + 1; // skip the opening `[`
    if i >= pat.len() {
        return None;
    }

    // Check for negation: `[^...]` or `[!...]`
    let negate = if pat[i] == '^' || pat[i] == '!' {
        i += 1;
        true
    } else {
        false
    };

    // A `]` immediately after `[` (or `[^`) is treated as a literal character in the class.
    let mut found = false;
    let mut first = true;
    while i < pat.len() {
        if pat[i] == ']' && !first {
            // End of bracket expression.
            let matched = if negate { !found } else { found };
            return Some((matched, i + 1));
        }
        // Check for range: a-z
        if i + 2 < pat.len() && pat[i + 1] == '-' && pat[i + 2] != ']' {
            let lo = pat[i];
            let hi = pat[i + 2];
            if ch >= lo && ch <= hi {
                found = true;
            }
            i += 3;
        } else {
            if pat[i] == ch {
                found = true;
            }
            i += 1;
        }
        first = false;
    }

    // No closing `]` found — malformed bracket expression.
    None
}

fn glob_match_inner(pat: &[char], txt: &[char]) -> bool {
    let mut pi = 0;
    let mut ti = 0;
    let mut star_pi = usize::MAX;
    let mut star_ti = 0;

    while ti < txt.len() {
        if pi < pat.len() && pat[pi] == '[' {
            // Try to match a bracket expression.
            if let Some((matched, end)) = match_bracket_class(pat, pi, txt[ti]) {
                if matched {
                    pi = end;
                    ti += 1;
                    continue;
                }
                // Not matched — fall through to star backtrack.
            }
            // Malformed bracket or no match — try star backtrack.
            if star_pi != usize::MAX {
                pi = star_pi + 1;
                star_ti += 1;
                ti = star_ti;
            } else {
                return false;
            }
        } else if pi < pat.len() && (pat[pi] == '?' || pat[pi] == txt[ti]) {
            pi += 1;
            ti += 1;
        } else if pi < pat.len() && pat[pi] == '*' {
            star_pi = pi;
            star_ti = ti;
            pi += 1;
        } else if star_pi != usize::MAX {
            pi = star_pi + 1;
            star_ti += 1;
            ti = star_ti;
        } else {
            return false;
        }
    }

    while pi < pat.len() && pat[pi] == '*' {
        pi += 1;
    }
    pi == pat.len()
}

/// Format a size value for display according to the config.
pub fn format_size(raw_bytes: u64, config: &DuConfig) -> String {
    if config.human_readable {
        human_readable(raw_bytes, 1024)
    } else if config.si {
        human_readable(raw_bytes, 1000)
    } else if config.inodes {
        raw_bytes.to_string()
    } else {
        // Scale by block_size, rounding up.
        let scaled = (raw_bytes + config.block_size - 1) / config.block_size;
        scaled.to_string()
    }
}

/// Format a byte count in human-readable form (e.g., 1.5K, 23M).
/// GNU du uses ceiling rounding and always shows one decimal for values < 10.
fn human_readable(bytes: u64, base: u64) -> String {
    let suffixes = if base == 1024 {
        &["", "K", "M", "G", "T", "P", "E"]
    } else {
        &["", "k", "M", "G", "T", "P", "E"]
    };

    if bytes < base {
        return format!("{}", bytes);
    }

    let mut value = bytes as f64;
    let mut idx = 0;
    while value >= base as f64 && idx + 1 < suffixes.len() {
        value /= base as f64;
        idx += 1;
    }

    if value >= 10.0 {
        format!("{:.0}{}", value.ceil(), suffixes[idx])
    } else {
        // Show one decimal place for values < 10 (GNU keeps the .0).
        let rounded = (value * 10.0).ceil() / 10.0;
        if rounded >= 10.0 {
            format!("{:.0}{}", rounded.ceil(), suffixes[idx])
        } else {
            format!("{:.1}{}", rounded, suffixes[idx])
        }
    }
}

/// Format a modification time for display.
pub fn format_time(epoch_secs: i64, style: &str) -> String {
    // Convert epoch seconds to a broken-down time.
    let secs = epoch_secs;
    let st = match SystemTime::UNIX_EPOCH.checked_add(std::time::Duration::from_secs(secs as u64)) {
        Some(t) => t,
        None => return String::from("?"),
    };

    // Use libc localtime_r for correct timezone handling.
    let mut tm: libc::tm = unsafe { std::mem::zeroed() };
    let time_t = secs as libc::time_t;
    unsafe {
        libc::localtime_r(&time_t, &mut tm);
    }
    // Ignore the SystemTime; we use the libc tm directly.
    let _ = st;

    let year = tm.tm_year + 1900;
    let mon = tm.tm_mon + 1;
    let day = tm.tm_mday;
    let hour = tm.tm_hour;
    let min = tm.tm_min;
    let sec = tm.tm_sec;

    match style {
        "full-iso" => format!(
            "{:04}-{:02}-{:02} {:02}:{:02}:{:02}.000000000 +0000",
            year, mon, day, hour, min, sec
        ),
        "iso" => format!("{:04}-{:02}-{:02}", year, mon, day),
        _ => {
            // long-iso (default)
            format!("{:04}-{:02}-{:02} {:02}:{:02}", year, mon, day, hour, min)
        }
    }
}

/// Print a single DuEntry.
pub fn print_entry<W: Write>(out: &mut W, entry: &DuEntry, config: &DuConfig) -> io::Result<()> {
    // Apply threshold filtering.
    if let Some(thresh) = config.threshold {
        let size_signed = entry.size as i64;
        if thresh >= 0 && size_signed < thresh {
            return Ok(());
        }
        if thresh < 0 && size_signed > thresh.unsigned_abs() as i64 {
            return Ok(());
        }
    }

    let size_str = format_size(entry.size, config);

    if config.show_time {
        if let Some(mtime) = entry.mtime {
            let time_str = format_time(mtime, &config.time_style);
            write!(out, "{}\t{}\t{}", size_str, time_str, entry.path.display())?;
        } else {
            write!(out, "{}\t{}", size_str, entry.path.display())?;
        }
    } else {
        write!(out, "{}\t{}", size_str, entry.path.display())?;
    }

    if config.null_terminator {
        out.write_all(b"\0")?;
    } else {
        out.write_all(b"\n")?;
    }

    Ok(())
}

/// Parse a block size string like "1K", "1M", "1G", etc.
/// Returns the number of bytes per block.
pub fn parse_block_size(s: &str) -> Result<u64, String> {
    let s = s.trim();
    if s.is_empty() {
        return Err("empty block size".to_string());
    }

    let mut num_end = 0;
    for (i, c) in s.char_indices() {
        if c.is_ascii_digit() {
            num_end = i + 1;
        } else {
            break;
        }
    }

    let (num_str, suffix) = s.split_at(num_end);
    let base_val: u64 = if num_str.is_empty() {
        1
    } else {
        num_str
            .parse()
            .map_err(|_| format!("invalid block size: '{}'", s))?
    };

    let multiplier = match suffix.to_uppercase().as_str() {
        "" => 1u64,
        "B" => 1,
        "K" | "KB" => 1024,
        "M" | "MB" => 1024 * 1024,
        "G" | "GB" => 1024 * 1024 * 1024,
        "T" | "TB" => 1024u64 * 1024 * 1024 * 1024,
        "P" | "PB" => 1024u64 * 1024 * 1024 * 1024 * 1024,
        "KB_SI" => 1000,
        _ => return Err(format!("invalid suffix in block size: '{}'", s)),
    };

    Ok(base_val * multiplier)
}

/// Parse a threshold value. Positive means "exclude entries smaller than SIZE".
/// Negative means "exclude entries larger than -SIZE".
/// GNU du rejects `--threshold=-0` and `--threshold=0` is allowed (positive zero is fine,
/// but negative zero is invalid).
pub fn parse_threshold(s: &str) -> Result<i64, String> {
    let s = s.trim();
    let (negative, rest) = if let Some(stripped) = s.strip_prefix('-') {
        (true, stripped)
    } else {
        (false, s)
    };

    let val = parse_block_size(rest)? as i64;
    if negative {
        if val == 0 {
            return Err(format!("invalid --threshold argument '-{}'", rest));
        }
        Ok(-val)
    } else {
        Ok(val)
    }
}

/// Read exclude patterns from a file (one per line).
pub fn read_exclude_file(path: &str) -> io::Result<Vec<String>> {
    let file = std::fs::File::open(path)?;
    let reader = io::BufReader::new(file);
    let mut patterns = Vec::new();
    for line in reader.lines() {
        let line = line?;
        let trimmed = line.trim();
        if !trimmed.is_empty() {
            patterns.push(trimmed.to_string());
        }
    }
    Ok(patterns)
}

/// Format an IO error without the "(os error N)" suffix.
fn format_io_error(e: &io::Error) -> String {
    if let Some(raw) = e.raw_os_error() {
        let os_err = io::Error::from_raw_os_error(raw);
        let msg = format!("{}", os_err);
        msg.replace(&format!(" (os error {})", raw), "")
    } else {
        format!("{}", e)
    }
}
