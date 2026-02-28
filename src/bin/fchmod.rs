#[cfg(not(unix))]
fn main() {
    eprintln!("chmod: only available on Unix");
    std::process::exit(1);
}

// fchmod -- change file mode bits
//
// Usage: chmod [OPTION]... MODE[,MODE]... FILE...
//   or:  chmod [OPTION]... OCTAL-MODE FILE...
//   or:  chmod [OPTION]... --reference=RFILE FILE...

#[cfg(unix)]
use std::os::unix::fs::MetadataExt;
#[cfg(unix)]
use std::process;

#[cfg(unix)]
const TOOL_NAME: &str = "chmod";
#[cfg(unix)]
const VERSION: &str = env!("CARGO_PKG_VERSION");

#[cfg(unix)]
fn main() {
    coreutils_rs::common::reset_sigpipe();

    let mut config = coreutils_rs::chmod::ChmodConfig::default();
    let mut reference: Option<String> = None;
    let mut mode_str: Option<String> = None;
    let mut files: Vec<String> = Vec::new();
    let mut saw_dashdash = false;
    // Track if the mode was supplied as a dash-prefixed arg before '--'.
    // GNU chmod only emits the umask-blocked warning in this case.
    let mut mode_looks_like_option = false;

    let args: Vec<String> = std::env::args().skip(1).collect();
    let mut i = 0;
    while i < args.len() {
        let arg = &args[i];
        if saw_dashdash {
            // After --, first non-option arg is still the mode if we haven't
            // seen one yet (GNU behaviour: -- only stops option parsing, the
            // mode is always the first non-option operand).
            if mode_str.is_none() && reference.is_none() {
                mode_str = Some(arg.clone());
            } else {
                files.push(arg.clone());
            }
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
            "--" => saw_dashdash = true,
            "-c" | "--changes" => config.changes = true,
            "-f" | "--silent" | "--quiet" => config.quiet = true,
            "-v" | "--verbose" => config.verbose = true,
            "--no-preserve-root" => config.preserve_root = false,
            "--preserve-root" => config.preserve_root = true,
            "-R" | "--recursive" => config.recursive = true,
            s if s.starts_with("--reference=") => {
                reference = Some(s["--reference=".len()..].to_string());
            }
            "--reference" => {
                i += 1;
                if i >= args.len() {
                    eprintln!("{}: option '--reference' requires an argument", TOOL_NAME);
                    eprintln!("Try '{} --help' for more information.", TOOL_NAME);
                    process::exit(1);
                }
                reference = Some(args[i].clone());
            }
            s if s.starts_with('-') && s.len() > 1 && !s.starts_with("--") => {
                // Could be combined short flags like -Rvc, OR a symbolic mode like -rwx
                // Try to parse as flags first
                let chars: Vec<char> = s[1..].chars().collect();
                let all_flags = chars.iter().all(|c| matches!(c, 'c' | 'f' | 'v' | 'R'));
                if all_flags {
                    for ch in &chars {
                        match ch {
                            'c' => config.changes = true,
                            'f' => config.quiet = true,
                            'v' => config.verbose = true,
                            'R' => config.recursive = true,
                            _ => unreachable!(),
                        }
                    }
                } else {
                    // Treat as mode string (e.g. "-rwx" means remove rwx)
                    if mode_str.is_none() {
                        mode_str = Some(arg.clone());
                        // This mode was passed as a dash-prefixed arg, not after --
                        mode_looks_like_option = true;
                    } else {
                        files.push(arg.clone());
                    }
                }
            }
            _ => {
                // First non-option argument is the mode (unless --reference is used)
                if mode_str.is_none() && reference.is_none() {
                    mode_str = Some(arg.clone());
                } else {
                    files.push(arg.clone());
                }
            }
        }
        i += 1;
    }

    // If --reference is used, we don't need a mode string
    if reference.is_none() && mode_str.is_none() {
        eprintln!("{}: missing operand", TOOL_NAME);
        eprintln!("Try '{} --help' for more information.", TOOL_NAME);
        process::exit(1);
    }

    if files.is_empty() {
        if reference.is_some() {
            eprintln!("{}: missing operand", TOOL_NAME);
        } else {
            eprintln!(
                "{}: missing operand after '{}'",
                TOOL_NAME,
                mode_str.as_deref().unwrap_or("")
            );
        }
        eprintln!("Try '{} --help' for more information.", TOOL_NAME);
        process::exit(1);
    }

    // Get mode from reference file if specified
    let effective_mode_str: String = if let Some(ref rfile) = reference {
        match std::fs::metadata(rfile) {
            Ok(meta) => {
                let m = meta.mode() & 0o7777;
                format!("{:o}", m)
            }
            Err(e) => {
                eprintln!(
                    "{}: failed to get attributes of '{}': {}",
                    TOOL_NAME,
                    rfile,
                    coreutils_rs::common::io_error_msg(&e)
                );
                process::exit(1);
            }
        }
    } else {
        mode_str.unwrap()
    };

    let mut exit_code = 0;

    for file in &files {
        let path = std::path::Path::new(file);

        if config.recursive {
            if config.preserve_root && path == std::path::Path::new("/") {
                eprintln!(
                    "{}: it is dangerous to operate recursively on '/'",
                    TOOL_NAME
                );
                eprintln!(
                    "{}: use --no-preserve-root to override this failsafe",
                    TOOL_NAME
                );
                exit_code = 1;
                continue;
            }

            if let Err(e) = coreutils_rs::chmod::chmod_recursive(path, &effective_mode_str, &config)
            {
                if !config.quiet {
                    eprintln!("{}: {}", TOOL_NAME, e);
                }
                exit_code = 1;
            }
        } else {
            // Get current mode
            let metadata = match std::fs::symlink_metadata(path) {
                Ok(m) => m,
                Err(e) => {
                    if !config.quiet {
                        eprintln!(
                            "{}: cannot access '{}': {}",
                            TOOL_NAME,
                            file,
                            coreutils_rs::common::io_error_msg(&e)
                        );
                    }
                    exit_code = 1;
                    continue;
                }
            };

            // Skip symlinks
            if metadata.file_type().is_symlink() {
                continue;
            }

            let current_mode = metadata.mode();
            let (new_mode, umask_blocked) = match coreutils_rs::chmod::parse_mode_check_umask(
                &effective_mode_str,
                current_mode,
            ) {
                Ok(r) => r,
                Err(e) => {
                    eprintln!("{}: {}", TOOL_NAME, e);
                    process::exit(1);
                }
            };

            if let Err(e) = coreutils_rs::chmod::chmod_file(path, new_mode, &config) {
                if !config.quiet {
                    eprintln!(
                        "{}: changing permissions of '{}': {}",
                        TOOL_NAME,
                        file,
                        coreutils_rs::common::io_error_msg(&e)
                    );
                }
                exit_code = 1;
            } else if umask_blocked && mode_looks_like_option {
                // GNU chmod warns when umask prevents the requested mode from
                // being fully applied, but ONLY when the mode string was supplied
                // as a dash-prefixed argument (not after '--').
                let actual_sym = coreutils_rs::chmod::format_symbolic_for_warning(new_mode);
                // Compute the mode that would have been set without umask
                let unmasked_mode = match coreutils_rs::chmod::parse_mode_no_umask(
                    &effective_mode_str,
                    current_mode,
                ) {
                    Ok(m) => m,
                    Err(_) => new_mode,
                };
                let requested_sym = coreutils_rs::chmod::format_symbolic_for_warning(unmasked_mode);
                eprintln!(
                    "{}: {}: new permissions are {}, not {}",
                    TOOL_NAME, file, actual_sym, requested_sym
                );
                exit_code = 1;
            }
        }
    }

    if exit_code != 0 {
        process::exit(exit_code);
    }
}

#[cfg(unix)]
fn print_help() {
    println!("Usage: {} [OPTION]... MODE[,MODE]... FILE...", TOOL_NAME);
    println!("  or:  {} [OPTION]... OCTAL-MODE FILE...", TOOL_NAME);
    println!("  or:  {} [OPTION]... --reference=RFILE FILE...", TOOL_NAME);
    println!();
    println!("Change the mode of each FILE to MODE.");
    println!("With --reference, change the mode of each FILE to that of RFILE.");
    println!();
    println!("  -c, --changes          like verbose but report only when a change is made");
    println!("  -f, --silent, --quiet   suppress most error messages");
    println!("  -v, --verbose          output a diagnostic for every file processed");
    println!("      --no-preserve-root  do not treat '/' specially (the default)");
    println!("      --preserve-root    fail to operate recursively on '/'");
    println!("      --reference=RFILE  use RFILE's mode instead of MODE values");
    println!("  -R, --recursive        change files and directories recursively");
    println!("      --help     display this help and exit");
    println!("      --version  output version information and exit");
    println!();
    println!("Each MODE is of the form '[ugoa]*([-+=]([rwxXst]*|[ugo]))+|[-+=][0-7]+'.");
}

#[cfg(all(test, unix))]
mod tests {
    use std::process::Command;

    fn cmd() -> Command {
        let mut path = std::env::current_exe().unwrap();
        path.pop();
        path.pop();
        path.push("fchmod");
        Command::new(path)
    }
    #[test]
    fn test_missing_operand() {
        let output = cmd().output().unwrap();
        assert_eq!(output.status.code(), Some(1));
        let stderr = String::from_utf8_lossy(&output.stderr);
        assert!(stderr.contains("missing operand"));
    }

    #[test]
    fn test_missing_file() {
        let output = cmd().arg("755").output().unwrap();
        assert_eq!(output.status.code(), Some(1));
        let stderr = String::from_utf8_lossy(&output.stderr);
        assert!(stderr.contains("missing operand"));
    }

    #[test]
    fn test_octal_mode() {
        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join("test.txt");
        std::fs::write(&file, "test").unwrap();

        let output = cmd()
            .args(["755", file.to_str().unwrap()])
            .output()
            .unwrap();
        assert!(output.status.success(), "chmod 755 should succeed");

        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let meta = std::fs::metadata(&file).unwrap();
            let mode = meta.permissions().mode() & 0o777;
            assert_eq!(mode, 0o755, "mode should be 0755, got {:o}", mode);
        }
    }

    #[test]
    fn test_symbolic_mode() {
        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join("sym.txt");
        std::fs::write(&file, "test").unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&file, std::fs::Permissions::from_mode(0o644)).unwrap();
        }

        let output = cmd()
            .args(["u+x", file.to_str().unwrap()])
            .output()
            .unwrap();
        assert!(output.status.success());

        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let meta = std::fs::metadata(&file).unwrap();
            let mode = meta.permissions().mode() & 0o777;
            assert_eq!(mode, 0o744, "mode should be 0744, got {:o}", mode);
        }
    }

    #[test]
    fn test_recursive() {
        let dir = tempfile::tempdir().unwrap();
        let sub = dir.path().join("sub");
        std::fs::create_dir(&sub).unwrap();
        let file = sub.join("file.txt");
        std::fs::write(&file, "test").unwrap();

        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&file, std::fs::Permissions::from_mode(0o644)).unwrap();
        }

        let output = cmd()
            .args(["-R", "755", dir.path().to_str().unwrap()])
            .output()
            .unwrap();
        assert!(output.status.success());

        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let meta = std::fs::metadata(&file).unwrap();
            let mode = meta.permissions().mode() & 0o777;
            assert_eq!(mode, 0o755, "mode should be 0755, got {:o}", mode);
        }
    }

    #[test]
    fn test_verbose_flag() {
        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join("verbose.txt");
        std::fs::write(&file, "test").unwrap();

        let output = cmd()
            .args(["-v", "755", file.to_str().unwrap()])
            .output()
            .unwrap();
        assert!(output.status.success());
        // GNU chmod sends verbose output to stdout
        let stdout = String::from_utf8_lossy(&output.stdout);
        assert!(
            stdout.contains("mode of"),
            "verbose should report mode change on stdout: {}",
            stdout
        );
    }

    #[test]
    fn test_reference_file() {
        let dir = tempfile::tempdir().unwrap();
        let ref_file = dir.path().join("ref.txt");
        let target = dir.path().join("target.txt");
        std::fs::write(&ref_file, "ref").unwrap();
        std::fs::write(&target, "target").unwrap();

        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&ref_file, std::fs::Permissions::from_mode(0o751)).unwrap();
            std::fs::set_permissions(&target, std::fs::Permissions::from_mode(0o644)).unwrap();
        }

        let output = cmd()
            .args([
                &format!("--reference={}", ref_file.to_str().unwrap()),
                target.to_str().unwrap(),
            ])
            .output()
            .unwrap();
        assert!(output.status.success());

        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let meta = std::fs::metadata(&target).unwrap();
            let mode = meta.permissions().mode() & 0o777;
            assert_eq!(mode, 0o751, "mode should match reference, got {:o}", mode);
        }
    }

    #[test]
    fn test_nonexistent_file() {
        let output = cmd()
            .args(["755", "/nonexistent_file_12345"])
            .output()
            .unwrap();
        assert_ne!(output.status.code(), Some(0));
    }

    #[test]
    fn test_quiet_suppresses_errors() {
        let output = cmd()
            .args(["-f", "755", "/nonexistent_file_12345"])
            .output()
            .unwrap();
        let stderr = String::from_utf8_lossy(&output.stderr);
        assert!(
            stderr.is_empty(),
            "quiet mode should suppress errors: {}",
            stderr
        );
    }

    #[test]
    fn test_preserve_root() {
        let output = cmd()
            .args(["-R", "--preserve-root", "755", "/"])
            .output()
            .unwrap();
        assert_ne!(output.status.code(), Some(0));
        let stderr = String::from_utf8_lossy(&output.stderr);
        assert!(
            stderr.contains("dangerous"),
            "should warn about root: {}",
            stderr
        );
    }

    #[test]
    fn test_double_dash_mode() {
        // After --, the first arg should be treated as mode, not file
        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join("dd.txt");
        std::fs::write(&file, "test").unwrap();

        let output = cmd()
            .args(["--", "755", file.to_str().unwrap()])
            .output()
            .unwrap();
        assert!(
            output.status.success(),
            "chmod -- 755 file should succeed: {}",
            String::from_utf8_lossy(&output.stderr)
        );

        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let meta = std::fs::metadata(&file).unwrap();
            let mode = meta.permissions().mode() & 0o777;
            assert_eq!(mode, 0o755, "mode should be 0755, got {:o}", mode);
        }
    }

    #[test]
    fn test_double_dash_minus_mode() {
        // After --, -rwx should be treated as a mode string
        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join("ddm.txt");
        std::fs::write(&file, "test").unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&file, std::fs::Permissions::from_mode(0o777)).unwrap();
        }

        let output = cmd()
            .args(["--", "-rwx", file.to_str().unwrap()])
            .output()
            .unwrap();
        // After --, no umask warning should be emitted
        assert!(
            output.status.success(),
            "chmod -- -rwx file should succeed: {}",
            String::from_utf8_lossy(&output.stderr)
        );
    }

    #[test]
    fn test_verbose_includes_symbolic() {
        // GNU chmod includes symbolic mode in parentheses
        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join("vs.txt");
        std::fs::write(&file, "test").unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&file, std::fs::Permissions::from_mode(0o644)).unwrap();
        }

        let output = cmd()
            .args(["-v", "755", file.to_str().unwrap()])
            .output()
            .unwrap();
        let stdout = String::from_utf8_lossy(&output.stdout);
        assert!(
            stdout.contains("(rw-r--r--)"),
            "verbose should include symbolic old mode: {}",
            stdout
        );
        assert!(
            stdout.contains("(rwxr-xr-x)"),
            "verbose should include symbolic new mode: {}",
            stdout
        );
    }

    #[test]
    fn test_chmod_go_minus_rwx() {
        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join("test.txt");
        std::fs::write(&file, "test").unwrap();
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&file, std::fs::Permissions::from_mode(0o777)).unwrap();

        let output = cmd()
            .args(["go-rwx", file.to_str().unwrap()])
            .output()
            .unwrap();
        assert!(output.status.success());

        let meta = std::fs::metadata(&file).unwrap();
        let mode = meta.permissions().mode() & 0o777;
        assert_eq!(mode, 0o700, "mode should be 0700, got {:o}", mode);
    }

    #[test]
    fn test_chmod_multiple_modes() {
        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join("test.txt");
        std::fs::write(&file, "test").unwrap();
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&file, std::fs::Permissions::from_mode(0o000)).unwrap();

        let output = cmd()
            .args(["u+rw,g+r", file.to_str().unwrap()])
            .output()
            .unwrap();
        assert!(output.status.success());

        let meta = std::fs::metadata(&file).unwrap();
        let mode = meta.permissions().mode() & 0o777;
        assert_eq!(mode, 0o640, "mode should be 0640, got {:o}", mode);
    }

    #[test]
    fn test_chmod_a_plus_x() {
        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join("test.txt");
        std::fs::write(&file, "test").unwrap();
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&file, std::fs::Permissions::from_mode(0o644)).unwrap();

        let output = cmd()
            .args(["a+x", file.to_str().unwrap()])
            .output()
            .unwrap();
        assert!(output.status.success());

        let meta = std::fs::metadata(&file).unwrap();
        let mode = meta.permissions().mode() & 0o777;
        assert_eq!(mode, 0o755, "mode should be 0755, got {:o}", mode);
    }

    #[test]
    fn test_chmod_set_exact() {
        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join("test.txt");
        std::fs::write(&file, "test").unwrap();
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&file, std::fs::Permissions::from_mode(0o777)).unwrap();

        let output = cmd()
            .args(["u=rw,go=", file.to_str().unwrap()])
            .output()
            .unwrap();
        assert!(output.status.success());

        let meta = std::fs::metadata(&file).unwrap();
        let mode = meta.permissions().mode() & 0o777;
        assert_eq!(mode, 0o600, "mode should be 0600, got {:o}", mode);
    }

    #[test]
    fn test_chmod_changes_flag() {
        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join("test.txt");
        std::fs::write(&file, "test").unwrap();
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&file, std::fs::Permissions::from_mode(0o644)).unwrap();

        // --changes should only report if mode actually changed
        let output = cmd()
            .args(["--changes", "644", file.to_str().unwrap()])
            .output()
            .unwrap();
        assert!(output.status.success());
        // No change, so stdout should be empty
        assert!(
            output.stdout.is_empty(),
            "no-change should produce no output with --changes"
        );
    }

    #[test]
    fn test_chmod_invalid_mode() {
        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join("test.txt");
        std::fs::write(&file, "test").unwrap();

        let output = cmd()
            .args(["zzz", file.to_str().unwrap()])
            .output()
            .unwrap();
        assert!(!output.status.success());
    }

    #[test]
    fn test_chmod_multiple_files() {
        let dir = tempfile::tempdir().unwrap();
        let f1 = dir.path().join("a.txt");
        let f2 = dir.path().join("b.txt");
        std::fs::write(&f1, "a").unwrap();
        std::fs::write(&f2, "b").unwrap();

        let output = cmd()
            .args(["600", f1.to_str().unwrap(), f2.to_str().unwrap()])
            .output()
            .unwrap();
        assert!(output.status.success());

        use std::os::unix::fs::PermissionsExt;
        assert_eq!(
            std::fs::metadata(&f1).unwrap().permissions().mode() & 0o777,
            0o600
        );
        assert_eq!(
            std::fs::metadata(&f2).unwrap().permissions().mode() & 0o777,
            0o600
        );
    }
}
