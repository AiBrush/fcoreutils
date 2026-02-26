#[cfg(not(unix))]
fn main() {
    eprintln!("rm: only available on Unix");
    std::process::exit(1);
}

// frm — remove files or directories
//
// Usage: rm [OPTION]... [FILE]...

#[cfg(unix)]
use std::io::{self, Write};
#[cfg(unix)]
use std::os::unix::fs::MetadataExt;
#[cfg(unix)]
use std::path::Path;
#[cfg(unix)]
use std::process;

#[cfg(unix)]
use coreutils_rs::rm::{InteractiveMode, PreserveRoot, RmConfig};

#[cfg(unix)]
const TOOL_NAME: &str = "rm";
#[cfg(unix)]
const VERSION: &str = env!("CARGO_PKG_VERSION");

#[cfg(unix)]
fn print_help() {
    println!("Usage: {} [OPTION]... [FILE]...", TOOL_NAME);
    println!("Remove (unlink) the FILE(s).");
    println!();
    println!("  -f, --force           ignore nonexistent files and arguments, never prompt");
    println!("  -i                    prompt before every removal");
    println!("  -I                    prompt once before removing more than three files, or");
    println!("                          when removing recursively");
    println!("      --interactive[=WHEN]  prompt according to WHEN: never, once (-I), or");
    println!("                          always (-i); without WHEN, prompt always");
    println!("      --one-file-system  when removing a hierarchy recursively, skip any");
    println!("                          directory that is on a file system different from");
    println!("                          that of the corresponding command line argument");
    println!("      --no-preserve-root  do not treat '/' specially");
    println!("      --preserve-root[=all]  do not remove '/' (default); with 'all',");
    println!("                          reject any command line argument on a separate device");
    println!("  -r, -R, --recursive   remove directories and their contents recursively");
    println!("  -d, --dir             remove empty directories");
    println!("  -v, --verbose         explain what is being done");
    println!("      --help            display this help and exit");
    println!("      --version         output version information and exit");
}

/// Normalize a path string for display: collapse consecutive slashes to one.
/// GNU rm displays "a///" as "a/", and "a///x" as "a/x".
#[cfg(unix)]
fn normalize_display_path(p: &Path) -> String {
    let s = p.to_string_lossy();
    let bytes = s.as_bytes();
    // Fast path: no double-slash at all
    if !bytes.windows(2).any(|w| w[0] == b'/' && w[1] == b'/') {
        return s.into_owned();
    }
    let mut result = Vec::with_capacity(bytes.len());
    let mut prev_slash = false;
    for &b in bytes {
        if b == b'/' {
            if !prev_slash {
                result.push(b);
            }
            prev_slash = true;
        } else {
            prev_slash = false;
            result.push(b);
        }
    }
    String::from_utf8(result).unwrap_or_else(|_| s.into_owned())
}

/// Prompt the user on stderr and return true if they answer 'y' or 'Y'.
#[cfg(unix)]
fn prompt_yes(msg: &str) -> bool {
    eprint!("{}", msg);
    let _ = io::stderr().flush();
    let mut answer = String::new();
    if io::stdin().read_line(&mut answer).is_err() {
        return false;
    }
    let trimmed = answer.trim();
    trimmed.eq_ignore_ascii_case("y") || trimmed.eq_ignore_ascii_case("yes")
}

/// Check if an I/O error should be silently ignored under -f.
/// GNU rm with -f ignores ENOENT and ENOTDIR (e.g., `rm -f existing-file/child`).
#[cfg(unix)]
fn is_ignorable_force_error(e: &io::Error) -> bool {
    matches!(
        e.raw_os_error(),
        Some(libc::ENOENT) | Some(libc::ENOTDIR)
    )
}

/// Format an I/O error message the way GNU coreutils does (no "(os error N)").
#[cfg(unix)]
fn format_io_error(e: &io::Error) -> String {
    if let Some(code) = e.raw_os_error() {
        io::Error::from_raw_os_error(code)
            .to_string()
            .trim_end()
            .to_string()
    } else {
        e.to_string()
    }
}

/// Remove a single path according to the given configuration.
/// Returns `Ok(true)` on success, `Ok(false)` on non-fatal failure.
#[cfg(unix)]
fn rm_path(
    path: &Path,
    display_path: &str,
    config: &RmConfig,
    stdout: &mut io::BufWriter<io::Stdout>,
) -> Result<bool, io::Error> {
    // Check preserve-root
    let canonical = std::fs::canonicalize(path).unwrap_or_else(|_| path.to_path_buf());
    if canonical == Path::new("/")
        && matches!(config.preserve_root, PreserveRoot::Yes | PreserveRoot::All)
    {
        eprintln!("rm: it is dangerous to operate recursively on '/'");
        eprintln!("rm: use --no-preserve-root to override this failsafe");
        return Ok(false);
    }

    let meta = match std::fs::symlink_metadata(path) {
        Ok(m) => m,
        Err(e) => {
            if config.force && is_ignorable_force_error(&e) {
                return Ok(true);
            }
            eprintln!(
                "rm: cannot remove '{}': {}",
                display_path,
                format_io_error(&e)
            );
            return Ok(false);
        }
    };

    if meta.is_dir() {
        if config.recursive {
            if config.interactive == InteractiveMode::Always
                && !prompt_yes(&format!("rm: descend into directory '{}'? ", display_path))
            {
                return Ok(false);
            }
            let root_dev = meta.dev();
            rm_recursive(path, display_path, config, root_dev, stdout)
        } else if config.dir {
            if config.interactive == InteractiveMode::Always
                && !prompt_yes(&format!("rm: remove directory '{}'? ", display_path))
            {
                return Ok(false);
            }
            match std::fs::remove_dir(path) {
                Ok(()) => {
                    if config.verbose {
                        let _ = writeln!(stdout, "removed directory '{}'", display_path);
                    }
                    Ok(true)
                }
                Err(e) => {
                    eprintln!(
                        "rm: cannot remove '{}': {}",
                        display_path,
                        format_io_error(&e)
                    );
                    Ok(false)
                }
            }
        } else {
            eprintln!("rm: cannot remove '{}': Is a directory", display_path);
            Ok(false)
        }
    } else {
        if config.interactive == InteractiveMode::Always
            && !prompt_yes(&format!("rm: remove file '{}'? ", display_path))
        {
            return Ok(false);
        }
        match std::fs::remove_file(path) {
            Ok(()) => {
                if config.verbose {
                    let _ = writeln!(stdout, "removed '{}'", display_path);
                }
                Ok(true)
            }
            Err(e) => {
                eprintln!(
                    "rm: cannot remove '{}': {}",
                    display_path,
                    format_io_error(&e)
                );
                Ok(false)
            }
        }
    }
}

/// Recursively remove a directory tree.
#[cfg(unix)]
fn rm_recursive(
    path: &Path,
    display_path: &str,
    config: &RmConfig,
    root_dev: u64,
    stdout: &mut io::BufWriter<io::Stdout>,
) -> Result<bool, io::Error> {
    // For non-interactive, non-verbose mode, use parallel removal
    if config.interactive == InteractiveMode::Never && !config.verbose {
        let success = std::sync::atomic::AtomicBool::new(true);
        rm_recursive_parallel(path, config, root_dev, &success);
        if let Err(e) = std::fs::remove_dir(path) {
            eprintln!(
                "rm: cannot remove '{}': {}",
                display_path,
                format_io_error(&e)
            );
            return Ok(false);
        }
        return Ok(success.load(std::sync::atomic::Ordering::Relaxed));
    }

    let mut success = true;

    let entries = match std::fs::read_dir(path) {
        Ok(rd) => rd,
        Err(e) => {
            eprintln!(
                "rm: cannot remove '{}': {}",
                display_path,
                format_io_error(&e)
            );
            return Ok(false);
        }
    };

    for entry in entries {
        let entry = match entry {
            Ok(e) => e,
            Err(e) => {
                eprintln!(
                    "rm: cannot read directory entry in '{}': {}",
                    display_path,
                    format_io_error(&e)
                );
                success = false;
                continue;
            }
        };
        let child_path = entry.path();
        let child_name = child_path
            .file_name()
            .map(|n| n.to_string_lossy().into_owned())
            .unwrap_or_default();
        let child_display = format!("{}/{}", display_path.trim_end_matches('/'), child_name);

        let child_meta = match std::fs::symlink_metadata(&child_path) {
            Ok(m) => m,
            Err(e) => {
                eprintln!(
                    "rm: cannot remove '{}': {}",
                    child_display,
                    format_io_error(&e)
                );
                success = false;
                continue;
            }
        };

        let skip_fs = config.one_file_system && child_meta.dev() != root_dev;
        if skip_fs {
            continue;
        }

        if child_meta.is_dir() {
            if config.interactive == InteractiveMode::Always
                && !prompt_yes(&format!("rm: descend into directory '{}'? ", child_display))
            {
                success = false;
                continue;
            }
            if !rm_recursive(&child_path, &child_display, config, root_dev, stdout)? {
                success = false;
            }
        } else {
            if config.interactive == InteractiveMode::Always
                && !prompt_yes(&format!("rm: remove file '{}'? ", child_display))
            {
                success = false;
                continue;
            }
            match std::fs::remove_file(&child_path) {
                Ok(()) => {
                    if config.verbose {
                        let _ = writeln!(stdout, "removed '{}'", child_display);
                    }
                }
                Err(e) => {
                    eprintln!(
                        "rm: cannot remove '{}': {}",
                        child_display,
                        format_io_error(&e)
                    );
                    success = false;
                }
            }
        }
    }

    // Remove the (hopefully empty) directory itself.
    if config.interactive == InteractiveMode::Always
        && !prompt_yes(&format!("rm: remove directory '{}'? ", display_path))
    {
        return Ok(false);
    }

    match std::fs::remove_dir(path) {
        Ok(()) => {
            if config.verbose {
                let _ = writeln!(stdout, "removed directory '{}'", display_path);
            }
        }
        Err(e) => {
            eprintln!(
                "rm: cannot remove '{}': {}",
                display_path,
                format_io_error(&e)
            );
            success = false;
        }
    }

    Ok(success)
}

/// Parallel recursive removal for non-interactive, non-verbose mode.
#[cfg(unix)]
fn rm_recursive_parallel(
    path: &Path,
    config: &RmConfig,
    root_dev: u64,
    success: &std::sync::atomic::AtomicBool,
) {
    let entries = match std::fs::read_dir(path) {
        Ok(rd) => rd,
        Err(e) => {
            if !config.force {
                eprintln!(
                    "rm: cannot remove '{}': {}",
                    path.display(),
                    format_io_error(&e)
                );
            }
            success.store(false, std::sync::atomic::Ordering::Relaxed);
            return;
        }
    };

    let entries: Vec<_> = entries.filter_map(|e| e.ok()).collect();

    use rayon::prelude::*;
    entries.par_iter().for_each(|entry| {
        let child_path = entry.path();
        let child_meta = match std::fs::symlink_metadata(&child_path) {
            Ok(m) => m,
            Err(e) => {
                if config.force && is_ignorable_force_error(&e) {
                    return;
                }
                if !config.force {
                    eprintln!(
                        "rm: cannot remove '{}': {}",
                        child_path.display(),
                        format_io_error(&e)
                    );
                }
                success.store(false, std::sync::atomic::Ordering::Relaxed);
                return;
            }
        };

        let skip_fs = config.one_file_system && child_meta.dev() != root_dev;
        if skip_fs {
            return;
        }

        if child_meta.is_dir() {
            rm_recursive_parallel(&child_path, config, root_dev, success);
            if let Err(e) = std::fs::remove_dir(&child_path) {
                if config.force && is_ignorable_force_error(&e) {
                    return;
                }
                if !config.force {
                    eprintln!(
                        "rm: cannot remove '{}': {}",
                        child_path.display(),
                        format_io_error(&e)
                    );
                }
                success.store(false, std::sync::atomic::Ordering::Relaxed);
            }
        } else if let Err(e) = std::fs::remove_file(&child_path) {
            if config.force && is_ignorable_force_error(&e) {
                return;
            }
            if !config.force {
                eprintln!(
                    "rm: cannot remove '{}': {}",
                    child_path.display(),
                    format_io_error(&e)
                );
            }
            success.store(false, std::sync::atomic::Ordering::Relaxed);
        }
    });
}

#[cfg(unix)]
fn main() {
    coreutils_rs::common::reset_sigpipe();

    let mut config = RmConfig::default();
    let mut files: Vec<String> = Vec::new();
    let mut saw_dashdash = false;

    let args: Vec<String> = std::env::args().skip(1).collect();
    let mut i = 0;
    while i < args.len() {
        let arg = &args[i];

        if saw_dashdash {
            files.push(arg.clone());
            i += 1;
            continue;
        }

        match arg.as_str() {
            "--" => {
                saw_dashdash = true;
            }
            "--help" => {
                print_help();
                return;
            }
            "--version" => {
                println!("{} (fcoreutils) {}", TOOL_NAME, VERSION);
                return;
            }
            "--force" => config.force = true,
            "--recursive" => config.recursive = true,
            "--dir" => config.dir = true,
            "--verbose" => config.verbose = true,
            "--one-file-system" => config.one_file_system = true,
            "--no-preserve-root" => config.preserve_root = PreserveRoot::No,
            "--preserve-root" => config.preserve_root = PreserveRoot::Yes,
            "--preserve-root=all" => config.preserve_root = PreserveRoot::All,
            "--interactive" => config.interactive = InteractiveMode::Always,
            s if s.starts_with("--interactive=") => {
                let val = &s["--interactive=".len()..];
                match val {
                    "never" => config.interactive = InteractiveMode::Never,
                    "once" => config.interactive = InteractiveMode::Once,
                    "always" => config.interactive = InteractiveMode::Always,
                    _ => {
                        eprintln!(
                            "{}: invalid argument '{}' for '--interactive'",
                            TOOL_NAME, val
                        );
                        process::exit(1);
                    }
                }
            }
            // Short options: may be combined (e.g. -rf, -riv)
            s if s.starts_with('-') && !s.starts_with("--") && s.len() > 1 => {
                for ch in s[1..].chars() {
                    match ch {
                        'f' => {
                            config.force = true;
                            // -f cancels prior -i/-I
                            config.interactive = InteractiveMode::Never;
                        }
                        'i' => {
                            config.interactive = InteractiveMode::Always;
                            // -i cancels -f
                            config.force = false;
                        }
                        'I' => {
                            config.interactive = InteractiveMode::Once;
                            // -I cancels -f
                            config.force = false;
                        }
                        'r' | 'R' => config.recursive = true,
                        'd' => config.dir = true,
                        'v' => config.verbose = true,
                        _ => {
                            eprintln!("{}: invalid option -- '{}'", TOOL_NAME, ch);
                            eprintln!("Try '{} --help' for more information.", TOOL_NAME);
                            process::exit(1);
                        }
                    }
                }
            }
            _ => files.push(arg.clone()),
        }

        i += 1;
    }

    // GNU rm: with no operands (and no -f), print usage error.
    if files.is_empty() {
        if config.force {
            // rm -f with no operands is a successful no-op.
            return;
        }
        eprintln!("{}: missing operand", TOOL_NAME);
        eprintln!("Try '{} --help' for more information.", TOOL_NAME);
        process::exit(1);
    }

    // -I prompts once before removing more than 3 files or when recursive.
    if config.interactive == InteractiveMode::Once {
        let should_prompt = files.len() > 3 || config.recursive;
        if should_prompt {
            eprint!(
                "{}: remove {} argument{}? ",
                TOOL_NAME,
                files.len(),
                if files.len() == 1 { "" } else { "s" }
            );
            let mut answer = String::new();
            if std::io::stdin().read_line(&mut answer).is_err() {
                process::exit(1);
            }
            let trimmed = answer.trim();
            if !trimmed.eq_ignore_ascii_case("y") && !trimmed.eq_ignore_ascii_case("yes") {
                process::exit(0);
            }
        }
    }

    let stdout_handle = io::stdout();
    let mut stdout = io::BufWriter::new(stdout_handle);

    let mut exit_code = 0;
    for file in &files {
        let path = Path::new(file);
        let display = normalize_display_path(path);
        match rm_path(path, &display, &config, &mut stdout) {
            Ok(true) => {}
            Ok(false) => exit_code = 1,
            Err(e) => {
                eprintln!(
                    "{}: cannot remove '{}': {}",
                    TOOL_NAME,
                    display,
                    format_io_error(&e)
                );
                exit_code = 1;
            }
        }
    }

    let _ = stdout.flush();

    if exit_code != 0 {
        process::exit(exit_code);
    }
}
