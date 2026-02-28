#[cfg(not(unix))]
fn main() {
    eprintln!("ln: only available on Unix");
    std::process::exit(1);
}

// fln -- make links between files
//
// Usage: ln [OPTION]... [-T] TARGET LINK_NAME
//        ln [OPTION]... TARGET
//        ln [OPTION]... TARGET... DIRECTORY
//        ln [OPTION]... -t DIRECTORY TARGET...

#[cfg(unix)]
use std::os::unix::fs::MetadataExt;
#[cfg(unix)]
use std::path::{Path, PathBuf};
#[cfg(unix)]
use std::process;

#[cfg(unix)]
const TOOL_NAME: &str = "ln";
#[cfg(unix)]
const VERSION: &str = env!("CARGO_PKG_VERSION");

#[cfg(unix)]
const DEFAULT_BACKUP_SUFFIX: &str = "~";

#[derive(Clone, Copy, PartialEq, Eq)]
#[cfg(unix)]
enum BackupMode {
    None,
    Simple,
}

/// Check if `name` is an unambiguous prefix of `full`.
/// GNU coreutils allows long option abbreviations as long as they are unambiguous.
/// We accept any prefix that is at least as long as the shortest unambiguous prefix.
#[cfg(unix)]
fn matches_long_option(arg: &str, full: &str) -> bool {
    arg == full || (arg.len() >= 3 && full.starts_with(arg))
}

/// Match a long option with `=value` syntax, e.g. `--backup=simple`.
/// Returns Some(value) if the arg matches the option prefix.
#[cfg(unix)]
fn match_long_option_value<'a>(arg: &'a str, option_name: &str) -> Option<&'a str> {
    // option_name is like "--backup", arg might be "--backup=simple" or "--b=simple"
    if let Some(eq_pos) = arg.find('=') {
        let prefix = &arg[..eq_pos];
        if matches_long_option(prefix, option_name) {
            return Some(&arg[eq_pos + 1..]);
        }
    }
    None
}

#[cfg(unix)]
fn main() {
    coreutils_rs::common::reset_sigpipe();

    let mut symbolic = false;
    let mut force = false;
    let mut no_deref = false;
    let mut verbose = false;
    let mut relative = false;
    let mut backup = BackupMode::None;
    let mut suffix = DEFAULT_BACKUP_SUFFIX.to_string();
    let mut target_dir: Option<String> = None;
    let mut no_target_dir = false;
    let mut logical = false;
    let mut physical = false;
    let mut _interactive = false;
    let mut operands: Vec<String> = Vec::new();
    let mut saw_dashdash = false;

    let args: Vec<String> = std::env::args().skip(1).collect();
    let mut i = 0;
    while i < args.len() {
        let arg = &args[i];
        if saw_dashdash {
            operands.push(arg.clone());
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
            "-s" | "--symbolic" => symbolic = true,
            "-f" | "--force" => force = true,
            "-n" | "--no-dereference" => no_deref = true,
            "-v" | "--verbose" => verbose = true,
            "-r" | "--relative" => relative = true,
            "-b" => backup = BackupMode::Simple,
            "-i" | "--interactive" => _interactive = true,
            "-L" | "--logical" => {
                logical = true;
                physical = false;
            }
            "-P" | "--physical" => {
                physical = true;
                logical = false;
            }
            "-T" | "--no-target-directory" => no_target_dir = true,
            "-t" => {
                i += 1;
                if i >= args.len() {
                    eprintln!("{}: option requires an argument -- 't'", TOOL_NAME);
                    eprintln!("Try '{} --help' for more information.", TOOL_NAME);
                    process::exit(1);
                }
                target_dir = Some(args[i].clone());
            }
            "--" => saw_dashdash = true,
            _ if arg.starts_with("-S") && arg.len() > 2 => {
                suffix = arg[2..].to_string();
                backup = BackupMode::Simple;
            }
            _ if arg == "-S" => {
                i += 1;
                if i >= args.len() {
                    eprintln!("{}: option requires an argument -- 'S'", TOOL_NAME);
                    eprintln!("Try '{} --help' for more information.", TOOL_NAME);
                    process::exit(1);
                }
                suffix = args[i].clone();
                backup = BackupMode::Simple;
            }
            _ if arg.starts_with("-t") && arg.len() > 2 && !arg.starts_with("--") => {
                target_dir = Some(arg[2..].to_string());
            }
            _ if arg.starts_with("--") && arg.contains('=') => {
                // Long options with =value
                if let Some(val) = match_long_option_value(arg, "--target-directory") {
                    target_dir = Some(val.to_string());
                } else if let Some(val) = match_long_option_value(arg, "--suffix") {
                    suffix = val.to_string();
                    backup = BackupMode::Simple;
                } else if let Some(val) = match_long_option_value(arg, "--backup") {
                    // --backup=simple, --backup=none, etc.
                    match val {
                        "none" | "off" => backup = BackupMode::None,
                        _ => backup = BackupMode::Simple,
                    }
                } else {
                    eprintln!("{}: unrecognized option '{}'", TOOL_NAME, arg);
                    eprintln!("Try '{} --help' for more information.", TOOL_NAME);
                    process::exit(1);
                }
            }
            _ if arg.starts_with("--") => {
                // Long options without =value: handle abbreviations
                if matches_long_option(arg, "--backup") {
                    backup = BackupMode::Simple;
                } else if matches_long_option(arg, "--symbolic") {
                    symbolic = true;
                } else if matches_long_option(arg, "--force") {
                    force = true;
                } else if matches_long_option(arg, "--no-dereference") {
                    no_deref = true;
                } else if matches_long_option(arg, "--verbose") {
                    verbose = true;
                } else if matches_long_option(arg, "--relative") {
                    relative = true;
                } else if matches_long_option(arg, "--interactive") {
                    _interactive = true;
                } else if matches_long_option(arg, "--logical") {
                    logical = true;
                    physical = false;
                } else if matches_long_option(arg, "--physical") {
                    physical = true;
                    logical = false;
                } else if matches_long_option(arg, "--no-target-directory") {
                    no_target_dir = true;
                } else if matches_long_option(arg, "--target-directory") {
                    // --target-directory without =value: next arg is the value
                    i += 1;
                    if i >= args.len() {
                        eprintln!("{}: option '{}' requires an argument", TOOL_NAME, arg);
                        eprintln!("Try '{} --help' for more information.", TOOL_NAME);
                        process::exit(1);
                    }
                    target_dir = Some(args[i].clone());
                } else if matches_long_option(arg, "--suffix") {
                    i += 1;
                    if i >= args.len() {
                        eprintln!("{}: option '{}' requires an argument", TOOL_NAME, arg);
                        eprintln!("Try '{} --help' for more information.", TOOL_NAME);
                        process::exit(1);
                    }
                    suffix = args[i].clone();
                    backup = BackupMode::Simple;
                } else {
                    eprintln!("{}: unrecognized option '{}'", TOOL_NAME, arg);
                    eprintln!("Try '{} --help' for more information.", TOOL_NAME);
                    process::exit(1);
                }
            }
            _ if arg.starts_with('-') && arg.len() > 1 => {
                // Combined short flags
                let chars: Vec<char> = arg[1..].chars().collect();
                let mut j = 0;
                while j < chars.len() {
                    match chars[j] {
                        's' => symbolic = true,
                        'f' => force = true,
                        'n' => no_deref = true,
                        'v' => verbose = true,
                        'r' => relative = true,
                        'b' => backup = BackupMode::Simple,
                        'i' => _interactive = true,
                        'L' => {
                            logical = true;
                            physical = false;
                        }
                        'P' => {
                            physical = true;
                            logical = false;
                        }
                        'T' => no_target_dir = true,
                        'S' => {
                            let rest: String = chars[j + 1..].iter().collect();
                            if rest.is_empty() {
                                i += 1;
                                if i >= args.len() {
                                    eprintln!("{}: option requires an argument -- 'S'", TOOL_NAME);
                                    eprintln!("Try '{} --help' for more information.", TOOL_NAME);
                                    process::exit(1);
                                }
                                suffix = args[i].clone();
                            } else {
                                suffix = rest;
                            }
                            backup = BackupMode::Simple;
                            break;
                        }
                        't' => {
                            let rest: String = chars[j + 1..].iter().collect();
                            if rest.is_empty() {
                                i += 1;
                                if i >= args.len() {
                                    eprintln!("{}: option requires an argument -- 't'", TOOL_NAME);
                                    eprintln!("Try '{} --help' for more information.", TOOL_NAME);
                                    process::exit(1);
                                }
                                target_dir = Some(args[i].clone());
                            } else {
                                target_dir = Some(rest);
                            }
                            break;
                        }
                        _ => {
                            eprintln!("{}: invalid option -- '{}'", TOOL_NAME, chars[j]);
                            eprintln!("Try '{} --help' for more information.", TOOL_NAME);
                            process::exit(1);
                        }
                    }
                    j += 1;
                }
            }
            _ => operands.push(arg.clone()),
        }
        i += 1;
    }

    if operands.is_empty() {
        eprintln!("{}: missing file operand", TOOL_NAME);
        eprintln!("Try '{} --help' for more information.", TOOL_NAME);
        process::exit(1);
    }

    let mut exit_code = 0;

    if let Some(ref dir) = target_dir {
        // -t DIRECTORY TARGET...
        // All operands are targets; link them into DIRECTORY
        if !Path::new(dir).is_dir() {
            eprintln!("{}: target '{}' is not a directory", TOOL_NAME, dir);
            process::exit(1);
        }
        for target in &operands {
            let link_name = link_name_in_dir(target, dir);
            if let Err(code) = make_link(
                target, &link_name, symbolic, force, no_deref, verbose, relative, backup, &suffix,
                logical, physical,
            ) {
                exit_code = code;
            }
        }
    } else if no_target_dir {
        // -T: treat LINK_NAME as a normal file, not a directory
        if operands.len() != 2 {
            if operands.len() < 2 {
                eprintln!(
                    "{}: missing destination file operand after '{}'",
                    TOOL_NAME, operands[0]
                );
            } else {
                eprintln!("{}: extra operand '{}'", TOOL_NAME, operands[2]);
            }
            eprintln!("Try '{} --help' for more information.", TOOL_NAME);
            process::exit(1);
        }
        if let Err(code) = make_link(
            &operands[0],
            &operands[1],
            symbolic,
            force,
            no_deref,
            verbose,
            relative,
            backup,
            &suffix,
            logical,
            physical,
        ) {
            exit_code = code;
        }
    } else if operands.len() == 1 {
        // Single operand: create link in current directory
        let target = &operands[0];
        let basename = Path::new(target)
            .file_name()
            .map(|n| n.to_string_lossy().to_string())
            .unwrap_or_else(|| target.clone());
        if let Err(code) = make_link(
            target, &basename, symbolic, force, no_deref, verbose, relative, backup, &suffix,
            logical, physical,
        ) {
            exit_code = code;
        }
    } else if operands.len() == 2 {
        let target = &operands[0];
        let dest = &operands[1];
        // If dest is a directory (and we're not using -n on a symlink-to-dir), link into it
        let dest_is_dir = if no_deref {
            // With -n, don't dereference: check the path itself
            Path::new(dest).symlink_metadata().is_ok_and(|m| m.is_dir())
        } else {
            Path::new(dest).is_dir()
        };
        if dest_is_dir {
            let link_name = link_name_in_dir(target, dest);
            if let Err(code) = make_link(
                target, &link_name, symbolic, force, no_deref, verbose, relative, backup, &suffix,
                logical, physical,
            ) {
                exit_code = code;
            }
        } else if let Err(code) = make_link(
            target, dest, symbolic, force, no_deref, verbose, relative, backup, &suffix, logical,
            physical,
        ) {
            exit_code = code;
        }
    } else {
        // Multiple operands: last must be a directory
        let dir = &operands[operands.len() - 1];
        if !Path::new(dir).is_dir() {
            eprintln!("{}: target '{}' is not a directory", TOOL_NAME, dir);
            process::exit(1);
        }
        for target in &operands[..operands.len() - 1] {
            let link_name = link_name_in_dir(target, dir);
            if let Err(code) = make_link(
                target, &link_name, symbolic, force, no_deref, verbose, relative, backup, &suffix,
                logical, physical,
            ) {
                exit_code = code;
            }
        }
    }

    if exit_code != 0 {
        process::exit(exit_code);
    }
}

/// Compute the link name when linking TARGET into DIRECTORY.
#[cfg(unix)]
fn link_name_in_dir(target: &str, dir: &str) -> String {
    let basename = Path::new(target)
        .file_name()
        .map(|n| n.to_string_lossy().to_string())
        .unwrap_or_else(|| target.to_string());
    let p = Path::new(dir).join(&basename);
    p.to_string_lossy().to_string()
}

/// Check if target and link_name refer to the same file (by device+inode).
/// For symbolic links with force, GNU ln detects this and errors.
#[cfg(unix)]
fn same_file(target: &str, link_name: &str) -> bool {
    let target_meta = match std::fs::metadata(target) {
        Ok(m) => m,
        Err(_) => return false,
    };
    // Use symlink_metadata for link_name so we compare the link entry's own inode,
    // not its resolved target (which would false-positive for symlink re-creation)
    let link_meta = match std::fs::symlink_metadata(link_name) {
        Ok(m) => m,
        Err(_) => return false,
    };
    target_meta.dev() == link_meta.dev() && target_meta.ino() == link_meta.ino()
}

/// Create a link from target to link_name.
#[allow(clippy::too_many_arguments)]
#[cfg(unix)]
fn make_link(
    target: &str,
    link_name: &str,
    symbolic: bool,
    force: bool,
    _no_deref: bool,
    verbose: bool,
    relative: bool,
    backup: BackupMode,
    suffix: &str,
    logical: bool,
    physical: bool,
) -> Result<(), i32> {
    let link_path = Path::new(link_name);

    // Check if link_name already exists (as symlink or regular file)
    let link_exists = link_path.symlink_metadata().is_ok();

    // For -sf: detect same source and destination before removing
    if link_exists && (force || backup != BackupMode::None) && same_file(target, link_name) {
        // GNU ln: "X and Y are the same file"
        eprintln!(
            "{}: '{}' and '{}' are the same file",
            TOOL_NAME, target, link_name
        );
        return Err(1);
    }

    if link_exists {
        // Make backup if requested (backup takes priority over force)
        if backup == BackupMode::Simple {
            let backup_name = format!("{}{}", link_name, suffix);
            if let Err(e) = std::fs::rename(link_name, &backup_name) {
                eprintln!(
                    "{}: cannot backup '{}': {}",
                    TOOL_NAME,
                    link_name,
                    coreutils_rs::common::io_error_msg(&e)
                );
                return Err(1);
            }
            // If link_name still exists after rename (e.g. source and backup dest
            // were hard links to the same inode, so rename() was a no-op), and
            // force is also set, remove the destination.
            if force
                && link_path.symlink_metadata().is_ok()
                && let Err(e) = remove_dest(link_name)
            {
                eprintln!(
                    "{}: cannot remove '{}': {}",
                    TOOL_NAME,
                    link_name,
                    coreutils_rs::common::io_error_msg(&e)
                );
                return Err(1);
            }
        } else if force {
            if let Err(e) = remove_dest(link_name) {
                eprintln!(
                    "{}: cannot remove '{}': {}",
                    TOOL_NAME,
                    link_name,
                    coreutils_rs::common::io_error_msg(&e)
                );
                return Err(1);
            }
        } else {
            eprintln!(
                "{}: failed to create {} link '{}': File exists",
                TOOL_NAME,
                if symbolic { "symbolic" } else { "hard" },
                link_name
            );
            return Err(1);
        }
    }

    let actual_target = if symbolic && relative {
        // Compute relative path from link location to target
        compute_relative_target(target, link_name)
    } else {
        target.to_string()
    };

    let result = if symbolic {
        std::os::unix::fs::symlink(&actual_target, link_name)
    } else if logical {
        // -L: dereference target symlinks: resolve the target and hard link to the resolved path
        // If target is a dangling symlink, this will fail (matching GNU behavior)
        let resolved = match std::fs::canonicalize(target) {
            Ok(p) => p,
            Err(e) => {
                eprintln!(
                    "{}: failed to create hard link '{}' => '{}': {}",
                    TOOL_NAME,
                    link_name,
                    target,
                    coreutils_rs::common::io_error_msg(&e)
                );
                return Err(1);
            }
        };
        std::fs::hard_link(&resolved, link_name)
    } else if physical {
        // -P: make hard link directly to symlink (not following it)
        // Use linkat with AT_SYMLINK_FOLLOW=0 (default) to avoid following
        use std::ffi::CString;
        use std::os::unix::ffi::OsStrExt;
        let c_target = CString::new(Path::new(target).as_os_str().as_bytes()).map_err(|_| {
            eprintln!("{}: invalid path '{}'", TOOL_NAME, target);
            1
        })?;
        let c_link = CString::new(Path::new(link_name).as_os_str().as_bytes()).map_err(|_| {
            eprintln!("{}: invalid path '{}'", TOOL_NAME, link_name);
            1
        })?;
        let ret = unsafe {
            libc::linkat(
                libc::AT_FDCWD,
                c_target.as_ptr(),
                libc::AT_FDCWD,
                c_link.as_ptr(),
                0, // no flags = don't follow symlinks
            )
        };
        if ret == 0 {
            Ok(())
        } else {
            Err(std::io::Error::last_os_error())
        }
    } else {
        // Default: hard_link (which follows symlinks on Linux due to default linkat AT_SYMLINK_FOLLOW behavior)
        // Actually std::fs::hard_link uses linkat with AT_SYMLINK_FOLLOW on some platforms.
        // On Linux, hard_link does NOT follow symlinks by default. That's the -P behavior.
        // So default is effectively -P.
        std::fs::hard_link(target, link_name)
    };

    match result {
        Ok(()) => {
            if verbose {
                if symbolic {
                    println!("'{}' -> '{}'", link_name, actual_target);
                } else {
                    println!("'{}' => '{}'", link_name, target);
                }
            }
            Ok(())
        }
        Err(e) => {
            eprintln!(
                "{}: failed to create {} link '{}' -> '{}': {}",
                TOOL_NAME,
                if symbolic { "symbolic" } else { "hard" },
                link_name,
                actual_target,
                coreutils_rs::common::io_error_msg(&e)
            );
            Err(1)
        }
    }
}

/// Remove a destination file or symlink.
#[cfg(unix)]
fn remove_dest(path: &str) -> Result<(), std::io::Error> {
    let meta = std::fs::symlink_metadata(path)?;
    if meta.is_dir() {
        std::fs::remove_dir(path)
    } else {
        std::fs::remove_file(path)
    }
}

/// Compute a relative path from the link location directory to the target.
#[cfg(unix)]
fn compute_relative_target(target: &str, link_name: &str) -> String {
    let target_abs = make_absolute(target);
    let link_abs = make_absolute(link_name);

    let link_dir = match Path::new(&link_abs).parent() {
        Some(p) => p.to_path_buf(),
        None => return target.to_string(),
    };

    make_relative(&target_abs, &link_dir)
}

#[cfg(unix)]
fn make_absolute(path: &str) -> PathBuf {
    let p = Path::new(path);
    if p.is_absolute() {
        p.to_path_buf()
    } else {
        match std::env::current_dir() {
            Ok(cwd) => cwd.join(p),
            Err(_) => p.to_path_buf(),
        }
    }
}

/// Compute a relative path from `from_dir` to `to_path`.
#[cfg(unix)]
fn make_relative(to_path: &Path, from_dir: &Path) -> String {
    // Normalize both paths by collecting components
    let to_components: Vec<_> = to_path.components().collect();
    let from_components: Vec<_> = from_dir.components().collect();

    // Find the common prefix length
    let mut common = 0;
    let max_common = to_components.len().min(from_components.len());
    while common < max_common && to_components[common] == from_components[common] {
        common += 1;
    }

    // Build the relative path: go up from from_dir, then down to to_path
    let mut result = PathBuf::new();
    for _ in common..from_components.len() {
        result.push("..");
    }
    for comp in &to_components[common..] {
        result.push(comp.as_os_str());
    }

    if result.as_os_str().is_empty() {
        ".".to_string()
    } else {
        result.to_string_lossy().to_string()
    }
}

#[cfg(unix)]
fn print_help() {
    println!("Usage: {} [OPTION]... [-T] TARGET LINK_NAME", TOOL_NAME);
    println!("  or:  {} [OPTION]... TARGET", TOOL_NAME);
    println!("  or:  {} [OPTION]... TARGET... DIRECTORY", TOOL_NAME);
    println!("  or:  {} [OPTION]... -t DIRECTORY TARGET...", TOOL_NAME);
    println!("In the 1st form, create a link to TARGET with the name LINK_NAME.");
    println!("In the 2nd form, create a link to TARGET in the current directory.");
    println!("In the 3rd and 4th forms, create links to each TARGET in DIRECTORY.");
    println!("Create hard links by default, symbolic links with --symbolic.");
    println!();
    println!("  -b                         like --backup but does not accept an argument");
    println!("  -f, --force                remove existing destination files");
    println!("  -i, --interactive          prompt whether to remove destinations");
    println!("  -L, --logical              dereference TARGETs that are symbolic links");
    println!("  -n, --no-dereference       treat LINK_NAME as a normal file if");
    println!("                               it is a symbolic link to a directory");
    println!("  -P, --physical             make hard links directly to symbolic links");
    println!("  -r, --relative             create symbolic links relative to link location");
    println!("  -s, --symbolic             make symbolic links instead of hard links");
    println!("  -S, --suffix=SUFFIX        override the usual backup suffix");
    println!("  -t, --target-directory=DIRECTORY  specify the DIRECTORY in which to create");
    println!("                               the links");
    println!("  -T, --no-target-directory   treat LINK_NAME as a normal file always");
    println!("  -v, --verbose              print name of each linked file");
    println!("      --help     display this help and exit");
    println!("      --version  output version information and exit");
    println!();
    println!("The backup suffix is '~', unless set with --suffix or SIMPLE_BACKUP_SUFFIX.");
}

#[cfg(all(test, unix))]
mod tests {
    use std::fs;
    use std::os::unix::fs::MetadataExt;
    use std::process::Command;

    fn cmd() -> Command {
        let mut path = std::env::current_exe().unwrap();
        path.pop();
        path.pop();
        path.push("fln");
        Command::new(path)
    }
    #[test]
    fn test_hard_link() {
        let dir = tempfile::tempdir().unwrap();
        let target = dir.path().join("target.txt");
        let link = dir.path().join("link.txt");
        fs::write(&target, "hello").unwrap();

        let output = cmd()
            .args([target.to_str().unwrap(), link.to_str().unwrap()])
            .output()
            .unwrap();
        assert!(output.status.success());
        assert!(link.exists());

        // Verify same inode
        let target_meta = fs::metadata(&target).unwrap();
        let link_meta = fs::metadata(&link).unwrap();
        assert_eq!(target_meta.ino(), link_meta.ino());
        assert_eq!(target_meta.nlink(), 2);
    }

    #[test]
    fn test_symbolic_link() {
        let dir = tempfile::tempdir().unwrap();
        let target = dir.path().join("target.txt");
        let link = dir.path().join("symlink.txt");
        fs::write(&target, "hello").unwrap();

        let output = cmd()
            .args(["-s", target.to_str().unwrap(), link.to_str().unwrap()])
            .output()
            .unwrap();
        assert!(output.status.success());
        assert!(link.symlink_metadata().unwrap().file_type().is_symlink());

        let link_target = fs::read_link(&link).unwrap();
        assert_eq!(link_target, target);
    }

    #[test]
    fn test_force_overwrite() {
        let dir = tempfile::tempdir().unwrap();
        let target = dir.path().join("target.txt");
        let link = dir.path().join("link.txt");
        fs::write(&target, "hello").unwrap();
        fs::write(&link, "existing").unwrap();

        // Without -f, should fail
        let output = cmd()
            .args(["-s", target.to_str().unwrap(), link.to_str().unwrap()])
            .output()
            .unwrap();
        assert_eq!(output.status.code(), Some(1));

        // With -f, should succeed
        let output = cmd()
            .args(["-sf", target.to_str().unwrap(), link.to_str().unwrap()])
            .output()
            .unwrap();
        assert!(output.status.success());
        assert!(link.symlink_metadata().unwrap().file_type().is_symlink());
    }

    #[test]
    fn test_verbose() {
        let dir = tempfile::tempdir().unwrap();
        let target = dir.path().join("target.txt");
        let link = dir.path().join("verbose_link.txt");
        fs::write(&target, "hello").unwrap();

        let output = cmd()
            .args(["-sv", target.to_str().unwrap(), link.to_str().unwrap()])
            .output()
            .unwrap();
        assert!(output.status.success());
        let stdout = String::from_utf8_lossy(&output.stdout);
        assert!(stdout.contains("->"), "verbose output should contain '->'");
    }

    #[test]
    fn test_relative_symlink() {
        let dir = tempfile::tempdir().unwrap();
        let sub = dir.path().join("sub");
        fs::create_dir(&sub).unwrap();
        let target = dir.path().join("target.txt");
        let link = sub.join("rel_link.txt");
        fs::write(&target, "hello").unwrap();

        let output = cmd()
            .args(["-sr", target.to_str().unwrap(), link.to_str().unwrap()])
            .output()
            .unwrap();
        assert!(output.status.success());

        let link_target = fs::read_link(&link).unwrap();
        // Should be relative, like ../target.txt
        assert!(
            link_target.to_str().unwrap().starts_with(".."),
            "relative link should start with '..': got {:?}",
            link_target
        );
        // The link should still resolve correctly
        assert_eq!(fs::read_to_string(&link).unwrap(), "hello");
    }

    #[test]
    fn test_backup() {
        let dir = tempfile::tempdir().unwrap();
        let target = dir.path().join("target.txt");
        let link = dir.path().join("backup_link.txt");
        fs::write(&target, "new_content").unwrap();
        fs::write(&link, "old_content").unwrap();

        let output = cmd()
            .args(["-sb", target.to_str().unwrap(), link.to_str().unwrap()])
            .output()
            .unwrap();
        assert!(output.status.success());

        // Original should be backed up
        let backup = dir.path().join("backup_link.txt~");
        assert!(backup.exists(), "backup file should exist");
        assert_eq!(fs::read_to_string(&backup).unwrap(), "old_content");

        // Link should point to target
        assert!(link.symlink_metadata().unwrap().file_type().is_symlink());
    }

    #[test]
    fn test_backup_custom_suffix() {
        let dir = tempfile::tempdir().unwrap();
        let target = dir.path().join("target.txt");
        let link = dir.path().join("custom_link.txt");
        fs::write(&target, "new").unwrap();
        fs::write(&link, "old").unwrap();

        let output = cmd()
            .args([
                "-s",
                "--suffix=.bak",
                target.to_str().unwrap(),
                link.to_str().unwrap(),
            ])
            .output()
            .unwrap();
        assert!(output.status.success());

        let backup = dir.path().join("custom_link.txt.bak");
        assert!(
            backup.exists(),
            "backup file with custom suffix should exist"
        );
        assert_eq!(fs::read_to_string(&backup).unwrap(), "old");
    }

    #[test]
    fn test_target_directory() {
        let dir = tempfile::tempdir().unwrap();
        let target = dir.path().join("target.txt");
        let dest_dir = dir.path().join("dest");
        fs::create_dir(&dest_dir).unwrap();
        fs::write(&target, "hello").unwrap();

        let output = cmd()
            .args([
                "-s",
                "-t",
                dest_dir.to_str().unwrap(),
                target.to_str().unwrap(),
            ])
            .output()
            .unwrap();
        assert!(output.status.success());

        let expected_link = dest_dir.join("target.txt");
        assert!(
            expected_link
                .symlink_metadata()
                .unwrap()
                .file_type()
                .is_symlink(),
            "link should be created in target directory"
        );
    }

    #[test]
    fn test_no_target_directory() {
        let dir = tempfile::tempdir().unwrap();
        let target = dir.path().join("target.txt");
        let link = dir.path().join("notdir_link");
        fs::write(&target, "hello").unwrap();

        let output = cmd()
            .args(["-sT", target.to_str().unwrap(), link.to_str().unwrap()])
            .output()
            .unwrap();
        assert!(output.status.success());
        assert!(link.symlink_metadata().unwrap().file_type().is_symlink());
    }

    #[test]
    fn test_no_target_directory_extra_operand() {
        let output = cmd().args(["-T", "a", "b", "c"]).output().unwrap();
        assert_eq!(output.status.code(), Some(1));
        let stderr = String::from_utf8_lossy(&output.stderr);
        assert!(stderr.contains("extra operand"));
    }

    #[test]
    fn test_multiple_targets_to_directory() {
        let dir = tempfile::tempdir().unwrap();
        let t1 = dir.path().join("t1.txt");
        let t2 = dir.path().join("t2.txt");
        let dest = dir.path().join("dest");
        fs::write(&t1, "a").unwrap();
        fs::write(&t2, "b").unwrap();
        fs::create_dir(&dest).unwrap();

        let output = cmd()
            .args([
                "-s",
                t1.to_str().unwrap(),
                t2.to_str().unwrap(),
                dest.to_str().unwrap(),
            ])
            .output()
            .unwrap();
        assert!(output.status.success());
        assert!(
            dest.join("t1.txt")
                .symlink_metadata()
                .unwrap()
                .file_type()
                .is_symlink()
        );
        assert!(
            dest.join("t2.txt")
                .symlink_metadata()
                .unwrap()
                .file_type()
                .is_symlink()
        );
    }

    #[test]
    fn test_missing_operand() {
        let output = cmd().output().unwrap();
        assert_eq!(output.status.code(), Some(1));
        let stderr = String::from_utf8_lossy(&output.stderr);
        assert!(stderr.contains("missing file operand"));
    }

    #[test]
    fn test_hard_link_nonexistent_target() {
        let dir = tempfile::tempdir().unwrap();
        let link = dir.path().join("bad_link.txt");

        let output = cmd()
            .args(["/nonexistent_ln_test_file", link.to_str().unwrap()])
            .output()
            .unwrap();
        assert_eq!(output.status.code(), Some(1));
        let stderr = String::from_utf8_lossy(&output.stderr);
        assert!(stderr.contains("failed to create"));
    }

    #[test]
    fn test_symlink_to_nonexistent_target() {
        // Symlinks can point to nonexistent targets (dangling link)
        let dir = tempfile::tempdir().unwrap();
        let link = dir.path().join("dangling.txt");

        let output = cmd()
            .args(["-s", "/nonexistent_target_12345", link.to_str().unwrap()])
            .output()
            .unwrap();
        assert!(output.status.success());
        assert!(link.symlink_metadata().unwrap().file_type().is_symlink());
    }

    #[test]
    fn test_link_exists_no_force() {
        let dir = tempfile::tempdir().unwrap();
        let target = dir.path().join("target.txt");
        let link = dir.path().join("existing.txt");
        fs::write(&target, "a").unwrap();
        fs::write(&link, "b").unwrap();

        let output = cmd()
            .args([target.to_str().unwrap(), link.to_str().unwrap()])
            .output()
            .unwrap();
        assert_eq!(output.status.code(), Some(1));
        let stderr = String::from_utf8_lossy(&output.stderr);
        assert!(stderr.contains("File exists"));
    }

    #[test]
    fn test_link_into_directory() {
        let dir = tempfile::tempdir().unwrap();
        let target = dir.path().join("target.txt");
        let dest = dir.path().join("dest");
        fs::write(&target, "hello").unwrap();
        fs::create_dir(&dest).unwrap();

        let output = cmd()
            .args(["-s", target.to_str().unwrap(), dest.to_str().unwrap()])
            .output()
            .unwrap();
        assert!(output.status.success());

        let expected = dest.join("target.txt");
        assert!(
            expected
                .symlink_metadata()
                .unwrap()
                .file_type()
                .is_symlink()
        );
    }

    #[test]
    fn test_matches_gnu_hard_link() {
        let dir = tempfile::tempdir().unwrap();
        let target = dir.path().join("gnu_target.txt");
        fs::write(&target, "test").unwrap();

        let gnu_link = dir.path().join("gnu_link.txt");
        let our_link = dir.path().join("our_link.txt");

        let gnu = Command::new("ln")
            .args([target.to_str().unwrap(), gnu_link.to_str().unwrap()])
            .output();
        if let Ok(gnu) = gnu {
            let ours = cmd()
                .args([target.to_str().unwrap(), our_link.to_str().unwrap()])
                .output()
                .unwrap();
            assert_eq!(ours.status.code(), gnu.status.code(), "Exit code mismatch");

            if gnu.status.success() {
                // Both links should exist and point to same inode
                let gnu_ino = fs::metadata(&gnu_link).unwrap().ino();
                let our_ino = fs::metadata(&our_link).unwrap().ino();
                let target_ino = fs::metadata(&target).unwrap().ino();
                assert_eq!(gnu_ino, target_ino);
                assert_eq!(our_ino, target_ino);
            }
        }
    }

    #[test]
    fn test_matches_gnu_symlink() {
        let dir = tempfile::tempdir().unwrap();
        let target = dir.path().join("gnu_sym_target.txt");
        fs::write(&target, "test").unwrap();

        let gnu_link = dir.path().join("gnu_sym.txt");
        let our_link = dir.path().join("our_sym.txt");

        let gnu = Command::new("ln")
            .args(["-s", target.to_str().unwrap(), gnu_link.to_str().unwrap()])
            .output();
        if let Ok(gnu) = gnu {
            let ours = cmd()
                .args(["-s", target.to_str().unwrap(), our_link.to_str().unwrap()])
                .output()
                .unwrap();
            assert_eq!(ours.status.code(), gnu.status.code(), "Exit code mismatch");

            if gnu.status.success() {
                let gnu_target = fs::read_link(&gnu_link).unwrap();
                let our_target = fs::read_link(&our_link).unwrap();
                assert_eq!(gnu_target, our_target, "Symlink targets should match");
            }
        }
    }

    #[test]
    fn test_matches_gnu_force_overwrite() {
        let dir = tempfile::tempdir().unwrap();
        let target = dir.path().join("gnu_force_target.txt");
        let gnu_link = dir.path().join("gnu_force.txt");
        let our_link = dir.path().join("our_force.txt");
        fs::write(&target, "new").unwrap();
        fs::write(&gnu_link, "old").unwrap();
        fs::write(&our_link, "old").unwrap();

        let gnu = Command::new("ln")
            .args(["-sf", target.to_str().unwrap(), gnu_link.to_str().unwrap()])
            .output();
        if let Ok(gnu) = gnu {
            let ours = cmd()
                .args(["-sf", target.to_str().unwrap(), our_link.to_str().unwrap()])
                .output()
                .unwrap();
            assert_eq!(ours.status.code(), gnu.status.code(), "Exit code mismatch");
        }
    }

    // Unit tests for relative path computation
    #[test]
    fn test_make_relative_sibling() {
        use std::path::Path;
        let result = super::make_relative(Path::new("/a/b/target.txt"), Path::new("/a/b"));
        assert_eq!(result, "target.txt");
    }

    #[test]
    fn test_make_relative_parent() {
        use std::path::Path;
        let result = super::make_relative(Path::new("/a/target.txt"), Path::new("/a/b"));
        assert_eq!(result, "../target.txt");
    }

    #[test]
    fn test_make_relative_deep() {
        use std::path::Path;
        let result = super::make_relative(Path::new("/a/b/c/target.txt"), Path::new("/a/x/y"));
        assert_eq!(result, "../../b/c/target.txt");
    }

    #[test]
    fn test_single_operand() {
        // ln -s /some/target creates a link in the current directory with the basename
        let dir = tempfile::tempdir().unwrap();
        let src_dir = dir.path().join("src");
        let work_dir = dir.path().join("work");
        fs::create_dir(&src_dir).unwrap();
        fs::create_dir(&work_dir).unwrap();

        let target = src_dir.join("single_target.txt");
        fs::write(&target, "data").unwrap();

        // Run in work_dir so the link is created there (no conflict)
        let output = cmd()
            .args(["-s", target.to_str().unwrap()])
            .current_dir(&work_dir)
            .output()
            .unwrap();
        assert!(output.status.success());

        let expected_link = work_dir.join("single_target.txt");
        assert!(
            expected_link
                .symlink_metadata()
                .unwrap()
                .file_type()
                .is_symlink(),
            "link should be created in current directory"
        );
        assert_eq!(fs::read_to_string(&expected_link).unwrap(), "data");
    }

    #[test]
    fn test_combined_flags() {
        let dir = tempfile::tempdir().unwrap();
        let target = dir.path().join("combined.txt");
        let link = dir.path().join("combined_link.txt");
        fs::write(&target, "data").unwrap();
        fs::write(&link, "old").unwrap();

        // -sfv = symbolic, force, verbose
        let output = cmd()
            .args(["-sfv", target.to_str().unwrap(), link.to_str().unwrap()])
            .output()
            .unwrap();
        assert!(output.status.success());
        assert!(link.symlink_metadata().unwrap().file_type().is_symlink());
        let stdout = String::from_utf8_lossy(&output.stdout);
        assert!(stdout.contains("->"));
    }

    #[test]
    fn test_no_deref_flag() {
        let dir = tempfile::tempdir().unwrap();
        let target = dir.path().join("nd_target.txt");
        let link = dir.path().join("nd_link.txt");
        fs::write(&target, "data").unwrap();

        // -n should work without error
        let output = cmd()
            .args(["-sn", target.to_str().unwrap(), link.to_str().unwrap()])
            .output()
            .unwrap();
        assert!(output.status.success());
    }

    // ── GNU compat tests ──

    #[test]
    fn test_sf_same_src_and_dest() {
        // ln -sf file file should fail with "are the same file"
        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join("sametest");
        fs::write(&file, "data").unwrap();

        let output = cmd()
            .args(["-sf", file.to_str().unwrap(), file.to_str().unwrap()])
            .output()
            .unwrap();
        assert_eq!(output.status.code(), Some(1));
        let stderr = String::from_utf8_lossy(&output.stderr);
        assert!(
            stderr.contains("are the same file"),
            "Expected 'are the same file' in stderr, got: {}",
            stderr
        );
    }

    #[test]
    fn test_sf_replace_enoent_link() {
        // Create a dangling symlink, then replace with -sf
        let dir = tempfile::tempdir().unwrap();
        let sf_a = dir.path().join("sf_a");
        fs::write(&sf_a, "foo").unwrap();
        let enoent_link = dir.path().join("enoent_link");

        // Create dangling symlink
        let out1 = cmd()
            .args(["-sf", "missing", enoent_link.to_str().unwrap()])
            .output()
            .unwrap();
        assert!(out1.status.success());
        assert!(
            enoent_link
                .symlink_metadata()
                .unwrap()
                .file_type()
                .is_symlink()
        );

        // Replace it
        let out2 = cmd()
            .args(["-sf", sf_a.to_str().unwrap(), enoent_link.to_str().unwrap()])
            .output()
            .unwrap();
        assert!(out2.status.success());
        let target = fs::read_link(&enoent_link).unwrap();
        assert_eq!(target, sf_a);
    }

    #[test]
    fn test_sf_replace_enotdir_link() {
        // Create symlink to a/b, then replace with -sf
        let dir = tempfile::tempdir().unwrap();
        let sf_a = dir.path().join("sf_a");
        fs::write(&sf_a, "foo").unwrap();
        let enotdir_link = dir.path().join("enotdir_link");

        // Create symlink to "a/b" (nonexistent directory path)
        let out1 = cmd()
            .args(["-sf", "a/b", enotdir_link.to_str().unwrap()])
            .output()
            .unwrap();
        assert!(out1.status.success());

        // Replace it
        let out2 = cmd()
            .args([
                "-sf",
                sf_a.to_str().unwrap(),
                enotdir_link.to_str().unwrap(),
            ])
            .output()
            .unwrap();
        assert!(out2.status.success());
        let target = fs::read_link(&enotdir_link).unwrap();
        assert_eq!(target, sf_a);
    }

    #[test]
    fn test_target_dir_long_option() {
        // ln -s --target-dir=DIR ../targetfile
        let dir = tempfile::tempdir().unwrap();
        let tgt_d = dir.path().join("tgt_d");
        fs::create_dir(&tgt_d).unwrap();

        let output = cmd()
            .args([
                "-s",
                &format!("--target-dir={}", tgt_d.to_str().unwrap()),
                "../targetfile",
            ])
            .output()
            .unwrap();
        assert!(output.status.success());
        let link = tgt_d.join("targetfile");
        assert!(link.symlink_metadata().unwrap().file_type().is_symlink());
        let target = fs::read_link(&link).unwrap();
        assert_eq!(target.to_str().unwrap(), "../targetfile");
    }

    #[test]
    fn test_target_dir_abbreviated() {
        // ln -s --target-dir=DIR should also work with abbreviation --target-d
        let dir = tempfile::tempdir().unwrap();
        let tgt_d = dir.path().join("tgt_d2");
        fs::create_dir(&tgt_d).unwrap();

        let output = cmd()
            .args([
                "-s",
                &format!("--target-dir={}", tgt_d.to_str().unwrap()),
                "../targetfile2",
            ])
            .output()
            .unwrap();
        assert!(output.status.success());
    }

    #[test]
    fn test_backup_simple_long() {
        // ln -f --b=simple src dest (abbreviated --backup)
        let dir = tempfile::tempdir().unwrap();
        let bk_a = dir.path().join("bk_a");
        let bk_b = dir.path().join("bk_b");
        fs::write(&bk_a, "a").unwrap();
        fs::write(&bk_b, "b").unwrap();

        // Create hard link as backup dest
        let bk_b_tilde = dir.path().join("bk_b~");
        std::fs::hard_link(&bk_b, &bk_b_tilde).unwrap();

        let output = cmd()
            .args([
                "-f",
                "--b=simple",
                bk_a.to_str().unwrap(),
                bk_b.to_str().unwrap(),
            ])
            .output()
            .unwrap();
        assert!(
            output.status.success(),
            "stderr: {}",
            String::from_utf8_lossy(&output.stderr)
        );
    }

    #[test]
    fn test_backup_simple_suffix_long() {
        // ln --backup=simple --suffix=.orig src dest
        let dir = tempfile::tempdir().unwrap();
        let bk_x = dir.path().join("bk_x");
        let bk_ax = dir.path().join("bk_ax");
        fs::write(&bk_x, "x").unwrap();
        fs::write(&bk_ax, "ax").unwrap();

        let output = cmd()
            .args([
                "--backup=simple",
                "--suffix=.orig",
                bk_x.to_str().unwrap(),
                bk_ax.to_str().unwrap(),
            ])
            .output()
            .unwrap();
        assert!(
            output.status.success(),
            "stderr: {}",
            String::from_utf8_lossy(&output.stderr)
        );
        let backup = dir.path().join("bk_ax.orig");
        assert!(
            backup.exists(),
            "backup file with .orig suffix should exist"
        );
    }

    #[test]
    fn test_logical_follows_symlink() {
        // ln -L symlink hardlink: should follow the symlink and create hard link to target
        let dir = tempfile::tempdir().unwrap();
        let real_file = dir.path().join("real.txt");
        fs::write(&real_file, "data").unwrap();

        let sym = dir.path().join("sym");
        std::os::unix::fs::symlink(&real_file, &sym).unwrap();

        let hard = dir.path().join("hard");
        let output = cmd()
            .args(["-L", sym.to_str().unwrap(), hard.to_str().unwrap()])
            .output()
            .unwrap();
        assert!(output.status.success());

        // hard should NOT be a symlink
        let hard_meta = hard.symlink_metadata().unwrap();
        assert!(!hard_meta.file_type().is_symlink());

        // hard should have same inode as real_file
        let real_meta = fs::metadata(&real_file).unwrap();
        assert_eq!(hard_meta.ino(), real_meta.ino());
    }

    #[test]
    fn test_logical_dangling_symlink_fails() {
        // ln -L dangling_symlink hardlink: should fail
        let dir = tempfile::tempdir().unwrap();
        let dangle = dir.path().join("dangle");
        std::os::unix::fs::symlink("/no-such-file-12345", &dangle).unwrap();

        let hard = dir.path().join("hard_to_dangle");
        let output = cmd()
            .args(["-L", dangle.to_str().unwrap(), hard.to_str().unwrap()])
            .output()
            .unwrap();
        assert_eq!(
            output.status.code(),
            Some(1),
            "Should fail for dangling symlink with -L"
        );
    }

    #[test]
    fn test_physical_hard_link_to_symlink() {
        // ln -P symlink hardlink: should create hard link to the symlink itself
        let dir = tempfile::tempdir().unwrap();
        let dangle = dir.path().join("dangle");
        std::os::unix::fs::symlink("/no-such-file-12345", &dangle).unwrap();

        let hard = dir.path().join("hard_dangle");
        let output = cmd()
            .args(["-P", dangle.to_str().unwrap(), hard.to_str().unwrap()])
            .output()
            .unwrap();
        assert!(
            output.status.success(),
            "stderr: {}",
            String::from_utf8_lossy(&output.stderr)
        );

        // hard should be a symlink (hard link to the symlink)
        let hard_meta = hard.symlink_metadata().unwrap();
        assert!(hard_meta.file_type().is_symlink());
    }

    #[test]
    fn test_backup_same_file_fails() {
        // ln --backup file file should fail with "are the same file"
        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join("hb_f");
        fs::write(&file, "data").unwrap();

        let output = cmd()
            .args(["--backup", file.to_str().unwrap(), file.to_str().unwrap()])
            .output()
            .unwrap();
        assert_eq!(output.status.code(), Some(1));
    }
}
