// frmdir — remove empty directories
//
// Usage: rmdir [OPTION]... DIRECTORY...

use std::path::PathBuf;
use std::process;

const TOOL_NAME: &str = "rmdir";
const VERSION: &str = env!("CARGO_PKG_VERSION");

fn main() {
    coreutils_rs::common::reset_sigpipe();

    let mut parents = false;
    let mut ignore_nonempty = false;
    let mut verbose = false;
    let mut dirs: Vec<String> = Vec::new();
    let mut saw_dashdash = false;

    for arg in std::env::args().skip(1) {
        if saw_dashdash {
            dirs.push(arg);
            continue;
        }
        match arg.as_str() {
            "--help" => {
                println!("Usage: {} [OPTION]... DIRECTORY...", TOOL_NAME);
                println!("Remove the DIRECTORY(ies), if they are empty.");
                println!();
                println!("      --ignore-fail-on-non-empty");
                println!("                 ignore each failure that is solely because a directory");
                println!("                 is non-empty");
                println!("  -p, --parents  remove DIRECTORY and its ancestors");
                println!("  -v, --verbose  output a diagnostic for every directory processed");
                println!("      --help     display this help and exit");
                println!("      --version  output version information and exit");
                return;
            }
            "--version" => {
                println!("{} (fcoreutils) {}", TOOL_NAME, VERSION);
                return;
            }
            "-p" | "--parents" => parents = true,
            "-v" | "--verbose" => verbose = true,
            "--ignore-fail-on-non-empty" => ignore_nonempty = true,
            "--" => saw_dashdash = true,
            s if s.starts_with('-') && s.len() > 1 && !s.starts_with("--") => {
                for ch in s[1..].chars() {
                    match ch {
                        'p' => parents = true,
                        'v' => verbose = true,
                        _ => {
                            eprintln!("{}: invalid option -- '{}'", TOOL_NAME, ch);
                            eprintln!("Try '{} --help' for more information.", TOOL_NAME);
                            process::exit(1);
                        }
                    }
                }
            }
            _ => dirs.push(arg),
        }
    }

    if dirs.is_empty() {
        eprintln!("{}: missing operand", TOOL_NAME);
        eprintln!("Try '{} --help' for more information.", TOOL_NAME);
        process::exit(1);
    }

    let mut exit_code = 0;
    for dir in &dirs {
        if parents {
            if let Err(code) = remove_parents(dir, ignore_nonempty, verbose) {
                exit_code = code;
            }
        } else {
            match remove_one(dir, ignore_nonempty, verbose) {
                Ok(_) => {}
                Err(code) => exit_code = code,
            }
        }
    }

    if exit_code != 0 {
        process::exit(exit_code);
    }
}

/// Returns Ok(true) if directory was removed, Ok(false) if it was skipped
/// due to --ignore-fail-on-non-empty, or Err(1) on real failure.
fn remove_one(dir: &str, ignore_nonempty: bool, verbose: bool) -> Result<bool, i32> {
    match std::fs::remove_dir(dir) {
        Ok(()) => {
            if verbose {
                println!("{}: removing directory, '{}'", TOOL_NAME, dir);
            }
            Ok(true)
        }
        Err(e) => {
            if ignore_nonempty && is_nonempty_error(&e) {
                return Ok(false);
            }
            eprintln!(
                "{}: failed to remove directory '{}': {}",
                TOOL_NAME,
                dir,
                coreutils_rs::common::io_error_msg(&e)
            );
            Err(1)
        }
    }
}

fn remove_parents(dir: &str, ignore_nonempty: bool, verbose: bool) -> Result<(), i32> {
    // Strip trailing slashes for the initial path (GNU compat)
    let mut path = PathBuf::from(dir.trim_end_matches('/'));
    loop {
        let path_str = path.to_string_lossy().to_string();
        // Don't try to remove empty path or root
        if path_str.is_empty() || path_str == "/" || path_str == "." {
            break;
        }
        let removed = remove_one(&path_str, ignore_nonempty, verbose)?;
        if !removed {
            // Directory was skipped (non-empty + --ignore-fail-on-non-empty)
            // Stop walking up the tree — GNU behavior
            break;
        }
        if !path.pop() {
            break;
        }
    }
    Ok(())
}

fn is_nonempty_error(e: &std::io::Error) -> bool {
    // Check by ErrorKind for cross-platform support
    if e.kind() == std::io::ErrorKind::DirectoryNotEmpty {
        return true;
    }
    // Also check raw OS error codes as fallback
    #[cfg(unix)]
    {
        if matches!(e.raw_os_error(), Some(libc::ENOTEMPTY) | Some(libc::EEXIST)) {
            return true;
        }
    }
    #[cfg(windows)]
    {
        // ERROR_DIR_NOT_EMPTY = 145
        if e.raw_os_error() == Some(145) {
            return true;
        }
    }
    false
}

#[cfg(test)]
mod tests {
    use std::fs;
    use std::process::Command;

    fn cmd() -> Command {
        let mut path = std::env::current_exe().unwrap();
        path.pop();
        path.pop();
        path.push("frmdir");
        Command::new(path)
    }

    #[test]
    fn test_rmdir_empty_dir() {
        let dir = tempfile::tempdir().unwrap();
        let target = dir.path().join("empty");
        fs::create_dir(&target).unwrap();

        let output = cmd().arg(target.to_str().unwrap()).output().unwrap();
        assert_eq!(output.status.code(), Some(0));
        assert!(!target.exists());
    }

    #[test]
    fn test_rmdir_nonempty_fails() {
        let dir = tempfile::tempdir().unwrap();
        let target = dir.path().join("notempty");
        fs::create_dir(&target).unwrap();
        fs::write(target.join("file.txt"), "data").unwrap();

        let output = cmd().arg(target.to_str().unwrap()).output().unwrap();
        assert_eq!(output.status.code(), Some(1));
        assert!(target.exists()); // Should still exist
    }

    #[test]
    fn test_rmdir_ignore_nonempty() {
        let dir = tempfile::tempdir().unwrap();
        let target = dir.path().join("notempty2");
        fs::create_dir(&target).unwrap();
        fs::write(target.join("file.txt"), "data").unwrap();

        let output = cmd()
            .args(["--ignore-fail-on-non-empty", target.to_str().unwrap()])
            .output()
            .unwrap();
        assert_eq!(output.status.code(), Some(0));
        assert!(target.exists()); // Still exists, but no error
    }

    #[test]
    fn test_rmdir_parents() {
        let dir = tempfile::tempdir().unwrap();
        let base = dir.path().join("a").join("b").join("c");
        fs::create_dir_all(&base).unwrap();

        let _output = cmd().args(["-p", base.to_str().unwrap()]).output().unwrap();
        // c, b, and a should all be removed
        // (exit code may be non-zero because it tries to remove the tempdir parent too)
        assert!(!dir.path().join("a").exists(), "a/ should be removed");
    }

    #[test]
    fn test_rmdir_verbose() {
        let dir = tempfile::tempdir().unwrap();
        let target = dir.path().join("verbosedir");
        fs::create_dir(&target).unwrap();

        let output = cmd()
            .args(["-v", target.to_str().unwrap()])
            .output()
            .unwrap();
        assert_eq!(output.status.code(), Some(0));
        let stdout_str = String::from_utf8_lossy(&output.stdout);
        assert!(
            stdout_str.contains("removing directory"),
            "verbose should report removal"
        );
    }

    #[test]
    fn test_rmdir_nonexistent() {
        let output = cmd().arg("/nonexistent_rmdir_test_12345").output().unwrap();
        assert_eq!(output.status.code(), Some(1));
    }

    #[test]
    fn test_rmdir_matches_gnu() {
        let gnu = Command::new("rmdir")
            .arg("/nonexistent_rmdir_test_67890")
            .output();
        if let Ok(gnu) = gnu {
            let ours = cmd().arg("/nonexistent_rmdir_test_67890").output().unwrap();
            assert_eq!(ours.status.code(), gnu.status.code(), "Exit code mismatch");
        }
    }

    #[test]
    fn test_rmdir_empty() {
        let dir = tempfile::tempdir().unwrap();
        let sub = dir.path().join("empty_dir");
        std::fs::create_dir(&sub).unwrap();
        let output = cmd().arg(sub.to_str().unwrap()).output().unwrap();
        assert!(output.status.success());
        assert!(!sub.exists());
    }

    #[test]
    fn test_rmdir_non_empty() {
        let dir = tempfile::tempdir().unwrap();
        let sub = dir.path().join("notempty");
        std::fs::create_dir(&sub).unwrap();
        std::fs::write(sub.join("file.txt"), "data").unwrap();
        let output = cmd().arg(sub.to_str().unwrap()).output().unwrap();
        assert!(!output.status.success());
    }

    #[test]
    fn test_rmdir_parents_nested() {
        let dir = tempfile::tempdir().unwrap();
        let nested = dir.path().join("a/b/c");
        std::fs::create_dir_all(&nested).unwrap();
        // Use current_dir so -p removes a/b/c relative to tempdir
        let output = cmd()
            .args(["-p", "a/b/c"])
            .current_dir(dir.path())
            .output()
            .unwrap();
        assert!(output.status.success());
        assert!(!dir.path().join("a").exists());
    }

    #[test]
    fn test_rmdir_multiple() {
        let dir = tempfile::tempdir().unwrap();
        let d1 = dir.path().join("d1");
        let d2 = dir.path().join("d2");
        std::fs::create_dir(&d1).unwrap();
        std::fs::create_dir(&d2).unwrap();
        let output = cmd()
            .args([d1.to_str().unwrap(), d2.to_str().unwrap()])
            .output()
            .unwrap();
        assert!(output.status.success());
        assert!(!d1.exists() && !d2.exists());
    }

    #[test]
    fn test_rmdir_no_args() {
        let output = cmd().output().unwrap();
        assert!(!output.status.success());
    }

    #[test]
    fn test_rmdir_ignore_non_empty() {
        let dir = tempfile::tempdir().unwrap();
        let sub = dir.path().join("notempty2");
        std::fs::create_dir(&sub).unwrap();
        std::fs::write(sub.join("file.txt"), "data").unwrap();
        let output = cmd()
            .args(["--ignore-fail-on-non-empty", sub.to_str().unwrap()])
            .output()
            .unwrap();
        assert!(output.status.success());
        // Directory should still exist (not removed because non-empty)
        assert!(sub.exists());
    }

    #[test]
    fn test_rmdir_p_trailing_slash() {
        // rmdir -p dir/ with trailing slash should work
        let dir = tempfile::tempdir().unwrap();
        let nested = dir.path().join("outer").join("inner");
        std::fs::create_dir_all(&nested).unwrap();
        let path_with_slash = format!("{}/", nested.to_str().unwrap());
        let output = cmd().args(["-p", &path_with_slash]).output().unwrap();
        // Will fail trying to remove tempdir parent, but outer/inner should be gone
        assert!(
            !dir.path().join("outer").exists(),
            "outer should be removed by -p"
        );
    }

    #[test]
    fn test_rmdir_p_ignore_nonempty_stops() {
        // rmdir -p --ignore-fail-on-non-empty should stop at non-empty dir, exit 0
        let dir = tempfile::tempdir().unwrap();
        let chain = dir.path().join("parent").join("child");
        let sibling = dir.path().join("parent").join("sibling_file");
        std::fs::create_dir_all(&chain).unwrap();
        std::fs::write(&sibling, "x").unwrap();

        let output = cmd()
            .args(["-p", "--ignore-fail-on-non-empty", chain.to_str().unwrap()])
            .output()
            .unwrap();
        assert!(
            output.status.success(),
            "Should exit 0 when stopping at non-empty parent"
        );
        assert!(!chain.exists(), "child should be removed");
        assert!(
            dir.path().join("parent").exists(),
            "parent should still exist (non-empty)"
        );
        assert!(sibling.exists(), "sibling_file should still exist");
    }

    #[test]
    fn test_rmdir_error_message_says_directory() {
        // GNU rmdir says "failed to remove directory 'X'"
        let output = cmd().arg("/nonexistent_rmdir_99").output().unwrap();
        let stderr = String::from_utf8_lossy(&output.stderr);
        assert!(
            stderr.contains("failed to remove directory"),
            "error should say 'directory': {}",
            stderr
        );
    }
}
