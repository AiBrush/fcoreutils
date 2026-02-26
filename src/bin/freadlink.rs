// freadlink — print resolved symbolic links or canonical file names
//
// Usage: readlink [OPTION]... FILE...

use std::path::{Path, PathBuf};
use std::process;

const TOOL_NAME: &str = "readlink";
const VERSION: &str = env!("CARGO_PKG_VERSION");

#[derive(Clone, Copy, PartialEq, Eq)]
enum CanonMode {
    None,
    /// -f: all components must exist
    Canonicalize,
    /// -e: all components must exist (stricter)
    CanonicalizeExisting,
    /// -m: no existence requirements
    CanonicalizeMissing,
}

fn main() {
    coreutils_rs::common::reset_sigpipe();

    let mut mode = CanonMode::None;
    let mut no_newline = false;
    let mut quiet = false;
    let mut verbose = false;
    let mut zero = false;
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
            "--help" => {
                print_help();
                return;
            }
            "--version" => {
                println!("{} (fcoreutils) {}", TOOL_NAME, VERSION);
                return;
            }
            "-f" | "--canonicalize" => mode = CanonMode::Canonicalize,
            "-e" | "--canonicalize-existing" => mode = CanonMode::CanonicalizeExisting,
            "-m" | "--canonicalize-missing" => mode = CanonMode::CanonicalizeMissing,
            "-n" | "--no-newline" => no_newline = true,
            "-q" | "--quiet" | "--silent" => quiet = true,
            "-v" | "--verbose" => verbose = true,
            "-z" | "--zero" => zero = true,
            "--" => saw_dashdash = true,
            s if s.starts_with('-') && !s.starts_with("--") && s.len() > 1 => {
                for ch in s[1..].chars() {
                    match ch {
                        'f' => mode = CanonMode::Canonicalize,
                        'e' => mode = CanonMode::CanonicalizeExisting,
                        'm' => mode = CanonMode::CanonicalizeMissing,
                        'n' => no_newline = true,
                        'q' => quiet = true,
                        'v' => verbose = true,
                        'z' => zero = true,
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

    if files.is_empty() {
        eprintln!("{}: missing operand", TOOL_NAME);
        eprintln!("Try '{} --help' for more information.", TOOL_NAME);
        process::exit(1);
    }

    let terminator = if zero { "\0" } else { "\n" };
    let mut exit_code = 0;
    let multiple = files.len() > 1;

    for (idx, file) in files.iter().enumerate() {
        match resolve(file, mode) {
            Ok(resolved) => {
                let s = resolved.to_string_lossy();
                if no_newline && !multiple && idx == files.len() - 1 {
                    print!("{}", s);
                } else {
                    print!("{}{}", s, terminator);
                }
            }
            Err(e) => {
                exit_code = 1;
                if verbose || !quiet {
                    eprintln!(
                        "{}: {}: {}",
                        TOOL_NAME,
                        file,
                        coreutils_rs::common::io_error_msg(&e)
                    );
                }
            }
        }
    }

    process::exit(exit_code);
}

fn resolve(path: &str, mode: CanonMode) -> Result<PathBuf, std::io::Error> {
    match mode {
        CanonMode::None => {
            // Just read the symlink target
            std::fs::read_link(path)
        }
        CanonMode::CanonicalizeExisting => {
            // All components must exist
            std::fs::canonicalize(path)
        }
        CanonMode::Canonicalize => canonicalize_f(Path::new(path)),
        CanonMode::CanonicalizeMissing => canonicalize_missing(Path::new(path)),
    }
}

/// Canonicalize a path where all but the last component must exist (-f).
/// Walks each component, following symlinks. All intermediate components must
/// resolve to existing directories. The very last component may be missing,
/// but if it is a symlink, it is followed (and its target's parent must exist).
fn canonicalize_f(path: &Path) -> Result<PathBuf, std::io::Error> {
    // If the whole path resolves, great
    if let Ok(canon) = std::fs::canonicalize(path) {
        return Ok(canon);
    }

    // Make the path absolute
    let abs = if path.is_absolute() {
        path.to_path_buf()
    } else {
        std::env::current_dir()?.join(path)
    };

    let components: Vec<std::path::Component<'_>> = abs.components().collect();
    if components.is_empty() {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidInput,
            "empty path",
        ));
    }

    let mut resolved = PathBuf::new();
    let last_idx = components.len() - 1;
    // Track how many symlinks we follow to prevent infinite loops
    let mut symlink_count = 0;
    const MAX_SYMLINKS: usize = 40;

    // Process all components except the last using a queue approach
    // to handle symlink expansion
    let mut queue: Vec<(std::ffi::OsString, bool)> = components
        .iter()
        .enumerate()
        .map(|(idx, c)| (c.as_os_str().to_os_string(), idx == last_idx))
        .collect();

    let mut qi = 0;
    while qi < queue.len() {
        let (ref comp_os, is_last) = queue[qi];
        let comp_str = comp_os.to_string_lossy();

        if comp_str == "/" {
            resolved = PathBuf::from("/");
        } else if comp_str == "." {
            // skip
        } else if comp_str == ".." {
            resolved.pop();
        } else {
            resolved.push(comp_os);

            match std::fs::symlink_metadata(&resolved) {
                Ok(meta) if meta.file_type().is_symlink() => {
                    symlink_count += 1;
                    if symlink_count > MAX_SYMLINKS {
                        return Err(std::io::Error::new(
                            std::io::ErrorKind::Other,
                            "Too many levels of symbolic links",
                        ));
                    }
                    let target = std::fs::read_link(&resolved)?;
                    resolved.pop();
                    // Expand the symlink: replace current component with target's components
                    let target_path = if target.is_absolute() {
                        resolved = PathBuf::new();
                        target
                    } else {
                        resolved.join(&target)
                    };
                    // Insert the expanded components into the queue
                    let expanded: Vec<(std::ffi::OsString, bool)> = target_path
                        .components()
                        .collect::<Vec<_>>()
                        .into_iter()
                        .map(|c| (c.as_os_str().to_os_string(), false))
                        .collect();
                    // The last expanded component inherits the is_last property
                    let mut exp = expanded;
                    if let Some(last) = exp.last_mut() {
                        last.1 = is_last;
                    }
                    // Replace the rest of the queue
                    let remaining: Vec<(std::ffi::OsString, bool)> =
                        queue[qi + 1..].to_vec();
                    queue.truncate(qi);
                    queue.extend(exp);
                    queue.extend(remaining);
                    continue; // re-process from same index
                }
                Ok(_) => {
                    // Exists and is not a symlink — good
                }
                Err(e) => {
                    if is_last {
                        // Last component doesn't exist — that's OK for -f
                        // (resolved already has it appended)
                    } else {
                        return Err(e);
                    }
                }
            }
        }
        qi += 1;
    }

    Ok(resolved)
}

/// Canonicalize a path where not all components need to exist (-m).
/// Walk each component: follow symlinks where possible, normalize the rest.
fn canonicalize_missing(path: &Path) -> Result<PathBuf, std::io::Error> {
    // Make the path absolute first
    let abs = if path.is_absolute() {
        path.to_path_buf()
    } else {
        std::env::current_dir()?.join(path)
    };

    // Try to canonicalize the whole thing first
    if let Ok(canon) = std::fs::canonicalize(&abs) {
        return Ok(canon);
    }

    // Walk component by component
    let components: Vec<std::path::Component<'_>> = abs.components().collect();
    let mut resolved = PathBuf::new();
    let mut i = 0;

    while i < components.len() {
        let c = components[i];
        match c {
            std::path::Component::RootDir => {
                resolved.push("/");
            }
            std::path::Component::Prefix(p) => {
                resolved.push(p.as_os_str());
            }
            std::path::Component::CurDir => {}
            std::path::Component::ParentDir => {
                resolved.pop();
            }
            std::path::Component::Normal(s) => {
                resolved.push(s);
                // Try to canonicalize what we have so far
                if let Ok(canon) = std::fs::canonicalize(&resolved) {
                    resolved = canon;
                } else if let Ok(target) = std::fs::read_link(&resolved) {
                    // It's a symlink but target doesn't exist — follow it anyway for -m
                    resolved.pop();
                    if target.is_absolute() {
                        resolved = target;
                    } else {
                        resolved.push(target);
                    }
                    // Normalize the result by re-walking through its components
                    resolved = normalize_path(&resolved);
                }
                // else: not a symlink, doesn't exist — just keep it appended
            }
        }
        i += 1;
    }

    Ok(resolved)
}

/// Normalize a path by resolving . and .. without touching the filesystem.
fn normalize_path(path: &Path) -> PathBuf {
    let mut result = PathBuf::new();
    for c in path.components() {
        match c {
            std::path::Component::CurDir => {}
            std::path::Component::ParentDir => {
                result.pop();
            }
            _ => {
                result.push(c.as_os_str());
            }
        }
    }
    result
}

fn print_help() {
    println!("Usage: {} [OPTION]... FILE...", TOOL_NAME);
    println!("Print value of a symbolic link or canonical file name");
    println!();
    println!("  -f, --canonicalize            canonicalize by following every symlink in");
    println!("                                every component of the given name recursively;");
    println!("                                all but the last component must exist");
    println!("  -e, --canonicalize-existing   canonicalize by following every symlink in");
    println!("                                every component of the given name recursively,");
    println!("                                all components must exist");
    println!("  -m, --canonicalize-missing    canonicalize by following every symlink in");
    println!("                                every component of the given name recursively,");
    println!("                                without requirements on components existence");
    println!("  -n, --no-newline              do not output the trailing delimiter");
    println!("  -q, --quiet, --silent         suppress most error messages");
    println!("  -v, --verbose                 report error messages");
    println!("  -z, --zero                    end each output line with NUL, not newline");
    println!("      --help     display this help and exit");
    println!("      --version  output version information and exit");
}

#[cfg(all(test, unix))]
mod tests {
    use std::fs;
    use std::process::Command;

    fn cmd() -> Command {
        let mut path = std::env::current_exe().unwrap();
        path.pop();
        path.pop();
        path.push("freadlink");
        Command::new(path)
    }

    #[test]
    fn test_readlink_symlink() {
        let dir = tempfile::tempdir().unwrap();
        let target = dir.path().join("target.txt");
        let link = dir.path().join("link.txt");
        fs::write(&target, "content").unwrap();
        std::os::unix::fs::symlink(&target, &link).unwrap();

        let output = cmd().arg(link.to_str().unwrap()).output().unwrap();
        assert!(output.status.success());
        let stdout = String::from_utf8_lossy(&output.stdout);
        assert_eq!(stdout.trim(), target.to_str().unwrap());
    }

    #[test]
    fn test_readlink_canonicalize() {
        let dir = tempfile::tempdir().unwrap();
        let target = dir.path().join("real.txt");
        let link = dir.path().join("sym.txt");
        fs::write(&target, "data").unwrap();
        std::os::unix::fs::symlink(&target, &link).unwrap();

        let output = cmd().args(["-f", link.to_str().unwrap()]).output().unwrap();
        assert!(output.status.success());
        let stdout = String::from_utf8_lossy(&output.stdout);
        // Canonicalized path should resolve to the real target
        let canon = fs::canonicalize(&target).unwrap();
        assert_eq!(stdout.trim(), canon.to_str().unwrap());
    }

    #[test]
    fn test_readlink_not_symlink() {
        let dir = tempfile::tempdir().unwrap();
        let regular = dir.path().join("regular.txt");
        fs::write(&regular, "hello").unwrap();

        let output = cmd().arg(regular.to_str().unwrap()).output().unwrap();
        assert_eq!(output.status.code(), Some(1));
    }

    #[test]
    fn test_readlink_no_newline() {
        let dir = tempfile::tempdir().unwrap();
        let target = dir.path().join("target2.txt");
        let link = dir.path().join("link2.txt");
        fs::write(&target, "content").unwrap();
        std::os::unix::fs::symlink(&target, &link).unwrap();

        let output = cmd().args(["-n", link.to_str().unwrap()]).output().unwrap();
        assert!(output.status.success());
        let stdout = String::from_utf8_lossy(&output.stdout);
        // Should NOT end with newline
        assert!(
            !stdout.ends_with('\n'),
            "output should not end with newline"
        );
        assert_eq!(stdout.as_ref(), target.to_str().unwrap());
    }

    #[test]
    fn test_readlink_matches_gnu() {
        let dir = tempfile::tempdir().unwrap();
        let target = dir.path().join("gnu_target.txt");
        let link = dir.path().join("gnu_link.txt");
        fs::write(&target, "test").unwrap();
        std::os::unix::fs::symlink(&target, &link).unwrap();

        let gnu = Command::new("readlink")
            .arg(link.to_str().unwrap())
            .output();
        if let Ok(gnu) = gnu {
            let ours = cmd().arg(link.to_str().unwrap()).output().unwrap();
            assert_eq!(ours.status.code(), gnu.status.code(), "Exit code mismatch");
            let gnu_out = String::from_utf8_lossy(&gnu.stdout);
            let our_out = String::from_utf8_lossy(&ours.stdout);
            assert_eq!(our_out.trim(), gnu_out.trim(), "Output mismatch");
        }

        // Also compare -f behavior
        let gnu_f = Command::new("readlink")
            .args(["-f", link.to_str().unwrap()])
            .output();
        if let Ok(gnu_f) = gnu_f {
            let ours_f = cmd().args(["-f", link.to_str().unwrap()]).output().unwrap();
            assert_eq!(
                ours_f.status.code(),
                gnu_f.status.code(),
                "Exit code mismatch for -f"
            );
            let gnu_out = String::from_utf8_lossy(&gnu_f.stdout);
            let our_out = String::from_utf8_lossy(&ours_f.stdout);
            assert_eq!(our_out.trim(), gnu_out.trim(), "Output mismatch for -f");
        }

        // Compare non-symlink behavior
        let regular = dir.path().join("regular_gnu.txt");
        fs::write(&regular, "test").unwrap();
        let gnu_reg = Command::new("readlink")
            .arg(regular.to_str().unwrap())
            .output();
        if let Ok(gnu_reg) = gnu_reg {
            let ours_reg = cmd().arg(regular.to_str().unwrap()).output().unwrap();
            assert_eq!(
                ours_reg.status.code(),
                gnu_reg.status.code(),
                "Exit code mismatch for regular file"
            );
        }
    }

    // Tests for the 6 GNU compatibility fixes

    #[test]
    fn test_f_on_missing_path() {
        // readlink -f on a non-existent path should resolve parent + final component
        let dir = tempfile::tempdir().unwrap();
        let canon_dir = fs::canonicalize(dir.path()).unwrap();
        let missing = dir.path().join("nonexist");

        let output = cmd()
            .args(["-f", missing.to_str().unwrap()])
            .output()
            .unwrap();
        assert!(output.status.success(), "should succeed for -f with missing last component");
        let stdout = String::from_utf8_lossy(&output.stdout);
        assert_eq!(stdout.trim(), canon_dir.join("nonexist").to_str().unwrap());
    }

    #[test]
    fn test_f_symlink_to_missing() {
        // readlink -f on a symlink pointing to a non-existent file
        let dir = tempfile::tempdir().unwrap();
        let canon_dir = fs::canonicalize(dir.path()).unwrap();
        let target = canon_dir.join("doesnotexist");
        let link = dir.path().join("link-to-missing");
        std::os::unix::fs::symlink(&target, &link).unwrap();

        let output = cmd()
            .args(["-f", link.to_str().unwrap()])
            .output()
            .unwrap();
        assert!(output.status.success(), "should succeed for -f on symlink to missing");
        let stdout = String::from_utf8_lossy(&output.stdout);
        // Should resolve through the symlink to the (missing) target
        assert_eq!(stdout.trim(), target.to_str().unwrap());
    }

    #[test]
    fn test_f_subdir_nonexist() {
        // readlink -f subdir/nonexist — subdir exists, nonexist does not
        let dir = tempfile::tempdir().unwrap();
        let canon_dir = fs::canonicalize(dir.path()).unwrap();
        let subdir = dir.path().join("subdir");
        fs::create_dir(&subdir).unwrap();

        let path = subdir.join("nonexist");
        let output = cmd()
            .args(["-f", path.to_str().unwrap()])
            .output()
            .unwrap();
        assert!(output.status.success());
        let stdout = String::from_utf8_lossy(&output.stdout);
        assert_eq!(
            stdout.trim(),
            canon_dir.join("subdir").join("nonexist").to_str().unwrap()
        );
    }

    #[test]
    fn test_f_link_to_dir_nonexist() {
        // readlink -f link-to-dir/nonexist — link-to-dir is symlink to existing dir
        let dir = tempfile::tempdir().unwrap();
        let canon_dir = fs::canonicalize(dir.path()).unwrap();
        let subdir = dir.path().join("subdir");
        fs::create_dir(&subdir).unwrap();
        let link = dir.path().join("link-to-dir");
        std::os::unix::fs::symlink(&subdir, &link).unwrap();

        let path = link.join("nonexist");
        let output = cmd()
            .args(["-f", path.to_str().unwrap()])
            .output()
            .unwrap();
        assert!(output.status.success());
        let stdout = String::from_utf8_lossy(&output.stdout);
        // Should resolve link-to-dir -> subdir, then append nonexist
        assert_eq!(
            stdout.trim(),
            canon_dir.join("subdir").join("nonexist").to_str().unwrap()
        );
    }

    #[test]
    fn test_f_link_to_subdir_missing() {
        // readlink -f link-to-dir/missing — similar to above with different name
        let dir = tempfile::tempdir().unwrap();
        let canon_dir = fs::canonicalize(dir.path()).unwrap();
        let subdir = dir.path().join("subdir");
        fs::create_dir(&subdir).unwrap();
        let link = dir.path().join("link-to-dir");
        std::os::unix::fs::symlink(&subdir, &link).unwrap();

        let path = link.join("missing");
        let output = cmd()
            .args(["-f", path.to_str().unwrap()])
            .output()
            .unwrap();
        assert!(output.status.success());
        let stdout = String::from_utf8_lossy(&output.stdout);
        assert_eq!(
            stdout.trim(),
            canon_dir.join("subdir").join("missing").to_str().unwrap()
        );
    }

    #[test]
    fn test_m_link_to_missing_more() {
        // readlink -m link-to-missing/more — symlink target doesn't exist,
        // and we add more components after it
        let dir = tempfile::tempdir().unwrap();
        let canon_dir = fs::canonicalize(dir.path()).unwrap();
        let target = canon_dir.join("doesnotexist");
        let link = dir.path().join("link-to-missing");
        std::os::unix::fs::symlink(&target, &link).unwrap();

        let path = link.join("more");
        let output = cmd()
            .args(["-m", path.to_str().unwrap()])
            .output()
            .unwrap();
        assert!(output.status.success(), "should succeed for -m with missing intermediates");
        let stdout = String::from_utf8_lossy(&output.stdout);
        // Should follow symlink to doesnotexist, then append "more"
        assert_eq!(
            stdout.trim(),
            target.join("more").to_str().unwrap()
        );
    }
}
