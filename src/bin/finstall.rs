#[cfg(not(unix))]
fn main() {
    eprintln!("install: only available on Unix");
    std::process::exit(1);
}

// finstall -- copy files and set attributes
//
// Usage: install [OPTION]... [-T] SOURCE DEST
//        install [OPTION]... SOURCE... DIRECTORY
//        install [OPTION]... -t DIRECTORY SOURCE...
//        install [OPTION]... -d DIRECTORY...

#[cfg(unix)]
use std::path::Path;
#[cfg(unix)]
use std::process;

#[cfg(unix)]
use coreutils_rs::install::{
    BackupMode, InstallConfig, install_directories, install_file, parse_backup_mode, parse_mode,
};

#[cfg(unix)]
const TOOL_NAME: &str = "install";
#[cfg(unix)]
const VERSION: &str = env!("CARGO_PKG_VERSION");

#[cfg(unix)]
fn main() {
    coreutils_rs::common::reset_sigpipe();

    let mut config = InstallConfig::default();
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
            "--" => saw_dashdash = true,
            "-b" => config.backup = Some(BackupMode::Simple),
            "-C" | "--compare" => config.compare = true,
            "-d" | "--directory" => config.directory_mode = true,
            "-D" => config.create_leading = true,
            "-p" | "--preserve-timestamps" => config.preserve_timestamps = true,
            "-s" | "--strip" => config.strip = true,
            "-v" | "--verbose" => config.verbose = true,
            "-T" | "--no-target-directory" => config.no_target_directory = true,
            "-m" => {
                i += 1;
                if i >= args.len() {
                    eprintln!("{}: option requires an argument -- 'm'", TOOL_NAME);
                    eprintln!("Try '{} --help' for more information.", TOOL_NAME);
                    process::exit(1);
                }
                match parse_mode(&args[i]) {
                    Ok(m) => config.mode = m,
                    Err(e) => {
                        eprintln!("{}: {}", TOOL_NAME, e);
                        process::exit(1);
                    }
                }
            }
            "-g" => {
                i += 1;
                if i >= args.len() {
                    eprintln!("{}: option requires an argument -- 'g'", TOOL_NAME);
                    eprintln!("Try '{} --help' for more information.", TOOL_NAME);
                    process::exit(1);
                }
                config.group = Some(args[i].clone());
            }
            "-o" => {
                i += 1;
                if i >= args.len() {
                    eprintln!("{}: option requires an argument -- 'o'", TOOL_NAME);
                    eprintln!("Try '{} --help' for more information.", TOOL_NAME);
                    process::exit(1);
                }
                config.owner = Some(args[i].clone());
            }
            "-t" => {
                i += 1;
                if i >= args.len() {
                    eprintln!("{}: option requires an argument -- 't'", TOOL_NAME);
                    eprintln!("Try '{} --help' for more information.", TOOL_NAME);
                    process::exit(1);
                }
                config.target_directory = Some(args[i].clone());
            }
            "-S" => {
                i += 1;
                if i >= args.len() {
                    eprintln!("{}: option requires an argument -- 'S'", TOOL_NAME);
                    eprintln!("Try '{} --help' for more information.", TOOL_NAME);
                    process::exit(1);
                }
                config.suffix = args[i].clone();
            }
            _ if arg.starts_with("--backup=") => {
                let val = &arg["--backup=".len()..];
                match parse_backup_mode(val) {
                    Some(mode) => config.backup = Some(mode),
                    None => {
                        eprintln!("{}: invalid backup type '{}'", TOOL_NAME, val);
                        process::exit(1);
                    }
                }
            }
            "--backup" => config.backup = Some(BackupMode::Existing),
            _ if arg.starts_with("--mode=") => {
                let val = &arg["--mode=".len()..];
                match parse_mode(val) {
                    Ok(m) => config.mode = m,
                    Err(e) => {
                        eprintln!("{}: {}", TOOL_NAME, e);
                        process::exit(1);
                    }
                }
            }
            _ if arg.starts_with("--group=") => {
                config.group = Some(arg["--group=".len()..].to_string());
            }
            _ if arg.starts_with("--owner=") => {
                config.owner = Some(arg["--owner=".len()..].to_string());
            }
            _ if arg.starts_with("--target-directory=") => {
                config.target_directory = Some(arg["--target-directory=".len()..].to_string());
            }
            _ if arg.starts_with("--suffix=") => {
                config.suffix = arg["--suffix=".len()..].to_string();
            }
            _ if arg.starts_with("--strip-program=") => {
                config.strip_program = arg["--strip-program=".len()..].to_string();
            }
            _ if arg.starts_with("-m") && arg.len() > 2 => {
                let val = &arg[2..];
                match parse_mode(val) {
                    Ok(m) => config.mode = m,
                    Err(e) => {
                        eprintln!("{}: {}", TOOL_NAME, e);
                        process::exit(1);
                    }
                }
            }
            _ if arg.starts_with("-g") && arg.len() > 2 => {
                config.group = Some(arg[2..].to_string());
            }
            _ if arg.starts_with("-o") && arg.len() > 2 => {
                config.owner = Some(arg[2..].to_string());
            }
            _ if arg.starts_with("-t") && arg.len() > 2 => {
                config.target_directory = Some(arg[2..].to_string());
            }
            _ if arg.starts_with("-S") && arg.len() > 2 => {
                config.suffix = arg[2..].to_string();
            }
            _ if arg.starts_with('-') && arg.len() > 1 && !arg.starts_with("--") => {
                // Combined short flags
                let chars: Vec<char> = arg[1..].chars().collect();
                let mut j = 0;
                while j < chars.len() {
                    match chars[j] {
                        'b' => config.backup = Some(BackupMode::Simple),
                        'C' => config.compare = true,
                        'd' => config.directory_mode = true,
                        'D' => config.create_leading = true,
                        'p' => config.preserve_timestamps = true,
                        's' => config.strip = true,
                        'v' => config.verbose = true,
                        'T' => config.no_target_directory = true,
                        'm' => {
                            let rest: String = chars[j + 1..].iter().collect();
                            if rest.is_empty() {
                                i += 1;
                                if i >= args.len() {
                                    eprintln!("{}: option requires an argument -- 'm'", TOOL_NAME);
                                    process::exit(1);
                                }
                                match parse_mode(&args[i]) {
                                    Ok(m) => config.mode = m,
                                    Err(e) => {
                                        eprintln!("{}: {}", TOOL_NAME, e);
                                        process::exit(1);
                                    }
                                }
                            } else {
                                match parse_mode(&rest) {
                                    Ok(m) => config.mode = m,
                                    Err(e) => {
                                        eprintln!("{}: {}", TOOL_NAME, e);
                                        process::exit(1);
                                    }
                                }
                            }
                            break;
                        }
                        'g' => {
                            let rest: String = chars[j + 1..].iter().collect();
                            if rest.is_empty() {
                                i += 1;
                                if i >= args.len() {
                                    eprintln!("{}: option requires an argument -- 'g'", TOOL_NAME);
                                    process::exit(1);
                                }
                                config.group = Some(args[i].clone());
                            } else {
                                config.group = Some(rest);
                            }
                            break;
                        }
                        'o' => {
                            let rest: String = chars[j + 1..].iter().collect();
                            if rest.is_empty() {
                                i += 1;
                                if i >= args.len() {
                                    eprintln!("{}: option requires an argument -- 'o'", TOOL_NAME);
                                    process::exit(1);
                                }
                                config.owner = Some(args[i].clone());
                            } else {
                                config.owner = Some(rest);
                            }
                            break;
                        }
                        't' => {
                            let rest: String = chars[j + 1..].iter().collect();
                            if rest.is_empty() {
                                i += 1;
                                if i >= args.len() {
                                    eprintln!("{}: option requires an argument -- 't'", TOOL_NAME);
                                    process::exit(1);
                                }
                                config.target_directory = Some(args[i].clone());
                            } else {
                                config.target_directory = Some(rest);
                            }
                            break;
                        }
                        'S' => {
                            let rest: String = chars[j + 1..].iter().collect();
                            if rest.is_empty() {
                                i += 1;
                                if i >= args.len() {
                                    eprintln!("{}: option requires an argument -- 'S'", TOOL_NAME);
                                    process::exit(1);
                                }
                                config.suffix = args[i].clone();
                            } else {
                                config.suffix = rest;
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

    // -C (compare) is mutually exclusive with --strip and --preserve-timestamps
    if config.compare && config.strip {
        eprintln!(
            "{}: options --compare and --strip are mutually exclusive",
            TOOL_NAME
        );
        eprintln!("Try '{} --help' for more information.", TOOL_NAME);
        process::exit(1);
    }
    if config.compare && config.preserve_timestamps {
        eprintln!(
            "{}: options --compare and --preserve-timestamps are mutually exclusive",
            TOOL_NAME
        );
        eprintln!("Try '{} --help' for more information.", TOOL_NAME);
        process::exit(1);
    }

    // -d mode: create directories
    if config.directory_mode {
        if operands.is_empty() {
            eprintln!("{}: missing file operand", TOOL_NAME);
            eprintln!("Try '{} --help' for more information.", TOOL_NAME);
            process::exit(1);
        }
        let dirs: Vec<&Path> = operands.iter().map(|s| Path::new(s.as_str())).collect();
        if let Err(e) = install_directories(&dirs, &config) {
            eprintln!("{}: {}", TOOL_NAME, coreutils_rs::common::io_error_msg(&e));
            process::exit(1);
        }
        return;
    }

    if operands.is_empty() {
        eprintln!("{}: missing file operand", TOOL_NAME);
        eprintln!("Try '{} --help' for more information.", TOOL_NAME);
        process::exit(1);
    }

    let mut exit_code = 0;

    if let Some(ref dir) = config.target_directory {
        // -t DIRECTORY SOURCE...
        // With -D, create the target directory (and parents) if it doesn't exist
        if config.create_leading
            && let Err(e) = std::fs::create_dir_all(Path::new(dir))
        {
            eprintln!(
                "{}: cannot create directory '{}': {}",
                TOOL_NAME,
                dir,
                coreutils_rs::common::io_error_msg(&e)
            );
            process::exit(1);
        }
        if !Path::new(dir).is_dir() {
            eprintln!("{}: target '{}' is not a directory", TOOL_NAME, dir);
            process::exit(1);
        }
        for source in &operands {
            let src_path = Path::new(source);
            let basename = src_path
                .file_name()
                .map(|n| n.to_string_lossy().to_string())
                .unwrap_or_else(|| source.clone());
            let dst = Path::new(dir).join(&basename);
            if let Err(e) = install_file(src_path, &dst, &config) {
                eprintln!(
                    "{}: cannot install '{}' to '{}': {}",
                    TOOL_NAME,
                    source,
                    dst.display(),
                    coreutils_rs::common::io_error_msg(&e)
                );
                exit_code = 1;
            }
        }
    } else if config.no_target_directory {
        // -T: exactly two operands
        if operands.len() < 2 {
            eprintln!(
                "{}: missing destination file operand after '{}'",
                TOOL_NAME, operands[0]
            );
            eprintln!("Try '{} --help' for more information.", TOOL_NAME);
            process::exit(1);
        }
        if operands.len() > 2 {
            eprintln!("{}: extra operand '{}'", TOOL_NAME, operands[2]);
            eprintln!("Try '{} --help' for more information.", TOOL_NAME);
            process::exit(1);
        }
        let src = Path::new(&operands[0]);
        let dst = Path::new(&operands[1]);
        if let Err(e) = install_file(src, dst, &config) {
            eprintln!(
                "{}: cannot install '{}' to '{}': {}",
                TOOL_NAME,
                operands[0],
                operands[1],
                coreutils_rs::common::io_error_msg(&e)
            );
            process::exit(1);
        }
    } else if operands.len() == 1 {
        eprintln!(
            "{}: missing destination file operand after '{}'",
            TOOL_NAME, operands[0]
        );
        eprintln!("Try '{} --help' for more information.", TOOL_NAME);
        process::exit(1);
    } else if operands.len() == 2 {
        let src = Path::new(&operands[0]);
        let dst = Path::new(&operands[1]);

        if dst.is_dir() {
            // Install into directory
            let basename = src
                .file_name()
                .map(|n| n.to_string_lossy().to_string())
                .unwrap_or_else(|| operands[0].clone());
            let final_dst = dst.join(&basename);
            if let Err(e) = install_file(src, &final_dst, &config) {
                eprintln!(
                    "{}: cannot install '{}' to '{}': {}",
                    TOOL_NAME,
                    operands[0],
                    final_dst.display(),
                    coreutils_rs::common::io_error_msg(&e)
                );
                exit_code = 1;
            }
        } else {
            // -D: create leading dirs
            if config.create_leading
                && let Some(parent) = dst.parent()
                && !parent.as_os_str().is_empty()
                && let Err(e) = std::fs::create_dir_all(parent)
            {
                eprintln!(
                    "{}: cannot create directory '{}': {}",
                    TOOL_NAME,
                    parent.display(),
                    coreutils_rs::common::io_error_msg(&e)
                );
                process::exit(1);
            }
            if let Err(e) = install_file(src, dst, &config) {
                eprintln!(
                    "{}: cannot install '{}' to '{}': {}",
                    TOOL_NAME,
                    operands[0],
                    operands[1],
                    coreutils_rs::common::io_error_msg(&e)
                );
                exit_code = 1;
            }
        }
    } else {
        // Multiple operands: last must be a directory
        let dir = &operands[operands.len() - 1];
        if !Path::new(dir).is_dir() {
            eprintln!("{}: target '{}' is not a directory", TOOL_NAME, dir);
            process::exit(1);
        }
        for source in &operands[..operands.len() - 1] {
            let src_path = Path::new(source);
            let basename = src_path
                .file_name()
                .map(|n| n.to_string_lossy().to_string())
                .unwrap_or_else(|| source.clone());
            let final_dst = Path::new(dir).join(&basename);
            if let Err(e) = install_file(src_path, &final_dst, &config) {
                eprintln!(
                    "{}: cannot install '{}' to '{}': {}",
                    TOOL_NAME,
                    source,
                    final_dst.display(),
                    coreutils_rs::common::io_error_msg(&e)
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
    println!("Usage: {} [OPTION]... [-T] SOURCE DEST", TOOL_NAME);
    println!("  or:  {} [OPTION]... SOURCE... DIRECTORY", TOOL_NAME);
    println!("  or:  {} [OPTION]... -t DIRECTORY SOURCE...", TOOL_NAME);
    println!("  or:  {} [OPTION]... -d DIRECTORY...", TOOL_NAME);
    println!();
    println!("This install program copies files (often just compiled) into destination");
    println!("locations you choose.  If you want to download and install a ready-to-use");
    println!("package on a GNU/Linux system, you should instead be using a package manager");
    println!("like yum(1) or apt-get(1).");
    println!();
    println!("In the first three forms, copy SOURCE to DEST or multiple SOURCE(s) to");
    println!("the existing DIRECTORY, while setting permission modes and owner/group.");
    println!("In the 4th form, create all components of the given DIRECTORY(ies).");
    println!();
    println!("  -b                         like --backup but does not accept an argument");
    println!("      --backup[=CONTROL]     make a backup of each existing destination file");
    println!("  -C, --compare              compare each pair of source and destination files,");
    println!("                               and in some cases, do not modify the destination");
    println!("  -d, --directory            treat all arguments as directory names; create all");
    println!("                               components of the specified directories");
    println!("  -D                         create all leading components of DEST except the");
    println!("                               last, or all components of --target-directory,");
    println!("                               then copy SOURCE to DEST");
    println!("  -g, --group=GROUP          set group ownership, instead of process' current group");
    println!(
        "  -m, --mode=MODE            set permission mode (as in chmod), instead of rwxr-xr-x"
    );
    println!("  -o, --owner=OWNER          set ownership (super-user only)");
    println!("  -p, --preserve-timestamps  apply access/modification times of SOURCE files");
    println!("                               to corresponding destination files");
    println!("  -s, --strip                strip symbol tables");
    println!("      --strip-program=PROGRAM  program used to strip binaries");
    println!("  -S, --suffix=SUFFIX        override the usual backup suffix");
    println!("  -t, --target-directory=DIRECTORY  copy all SOURCE arguments into DIRECTORY");
    println!("  -T, --no-target-directory   treat DEST as a normal file");
    println!("  -v, --verbose              print the name of each directory as it is created");
    println!("      --help     display this help and exit");
    println!("      --version  output version information and exit");
}

#[cfg(test)]
mod tests {
    use std::fs;
    use std::process::Command;

    fn cmd() -> Command {
        let mut path = std::env::current_exe().unwrap();
        path.pop();
        path.pop();
        path.push("finstall");
        Command::new(path)
    }

    #[cfg(unix)]
    #[test]
    fn test_install_file() {
        let dir = tempfile::tempdir().unwrap();
        let src = dir.path().join("source.txt");
        let dst = dir.path().join("dest.txt");
        fs::write(&src, "hello install").unwrap();

        let output = cmd()
            .args([src.to_str().unwrap(), dst.to_str().unwrap()])
            .output()
            .unwrap();
        assert!(
            output.status.success(),
            "install should succeed: {}",
            String::from_utf8_lossy(&output.stderr)
        );
        assert!(dst.exists(), "destination should exist");
        assert_eq!(fs::read_to_string(&dst).unwrap(), "hello install");

        // Default mode should be 0755
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mode = fs::metadata(&dst).unwrap().permissions().mode() & 0o777;
            assert_eq!(
                mode, 0o755,
                "default install mode should be 0755, got {:o}",
                mode
            );
        }
    }

    #[cfg(unix)]
    #[test]
    fn test_install_mode() {
        let dir = tempfile::tempdir().unwrap();
        let src = dir.path().join("mode_src.txt");
        let dst = dir.path().join("mode_dst.txt");
        fs::write(&src, "content").unwrap();

        let output = cmd()
            .args(["-m", "0644", src.to_str().unwrap(), dst.to_str().unwrap()])
            .output()
            .unwrap();
        assert!(
            output.status.success(),
            "install -m 0644 should succeed: {}",
            String::from_utf8_lossy(&output.stderr)
        );

        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mode = fs::metadata(&dst).unwrap().permissions().mode() & 0o777;
            assert_eq!(mode, 0o644, "mode should be 0644, got {:o}", mode);
        }
    }

    #[cfg(unix)]
    #[test]
    fn test_install_directory() {
        let dir = tempfile::tempdir().unwrap();
        let new_dir = dir.path().join("new_dir");

        let output = cmd()
            .args(["-d", new_dir.to_str().unwrap()])
            .output()
            .unwrap();
        assert!(
            output.status.success(),
            "install -d should succeed: {}",
            String::from_utf8_lossy(&output.stderr)
        );
        assert!(new_dir.is_dir(), "directory should be created");
    }

    #[cfg(unix)]
    #[test]
    fn test_install_d_creates_parents() {
        let dir = tempfile::tempdir().unwrap();
        let src = dir.path().join("src.txt");
        let dst = dir.path().join("a").join("b").join("c").join("dest.txt");
        fs::write(&src, "deep").unwrap();

        let output = cmd()
            .args(["-D", src.to_str().unwrap(), dst.to_str().unwrap()])
            .output()
            .unwrap();
        assert!(
            output.status.success(),
            "install -D should succeed: {}",
            String::from_utf8_lossy(&output.stderr)
        );
        assert!(dst.exists(), "destination should exist");
        assert_eq!(fs::read_to_string(&dst).unwrap(), "deep");
    }

    #[cfg(unix)]
    #[test]
    fn test_install_compare() {
        let dir = tempfile::tempdir().unwrap();
        let src = dir.path().join("cmp_src.txt");
        let dst = dir.path().join("cmp_dst.txt");
        fs::write(&src, "same content").unwrap();
        fs::write(&dst, "same content").unwrap();

        // Set a specific mtime on dst
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            fs::set_permissions(&dst, fs::Permissions::from_mode(0o755)).unwrap();
        }

        let old_meta = fs::metadata(&dst).unwrap();
        let old_mtime = old_meta.modified().unwrap();

        // Small delay
        std::thread::sleep(std::time::Duration::from_millis(50));

        let output = cmd()
            .args(["-C", src.to_str().unwrap(), dst.to_str().unwrap()])
            .output()
            .unwrap();
        assert!(
            output.status.success(),
            "install -C should succeed: {}",
            String::from_utf8_lossy(&output.stderr)
        );

        // With -C and identical content, mtime should NOT change
        let new_meta = fs::metadata(&dst).unwrap();
        let new_mtime = new_meta.modified().unwrap();
        assert_eq!(
            old_mtime, new_mtime,
            "mtime should not change when files are identical with -C"
        );
    }

    #[cfg(unix)]
    #[test]
    fn test_install_compare_different() {
        let dir = tempfile::tempdir().unwrap();
        let src = dir.path().join("cmp_src2.txt");
        let dst = dir.path().join("cmp_dst2.txt");
        fs::write(&src, "new content").unwrap();
        fs::write(&dst, "old content").unwrap();

        let output = cmd()
            .args(["-C", src.to_str().unwrap(), dst.to_str().unwrap()])
            .output()
            .unwrap();
        assert!(
            output.status.success(),
            "install -C with different content should succeed: {}",
            String::from_utf8_lossy(&output.stderr)
        );

        // File should be updated since contents differ
        assert_eq!(fs::read_to_string(&dst).unwrap(), "new content");
    }

    #[cfg(unix)]
    #[test]
    fn test_install_verbose() {
        let dir = tempfile::tempdir().unwrap();
        let src = dir.path().join("verbose_src.txt");
        let dst = dir.path().join("verbose_dst.txt");
        fs::write(&src, "data").unwrap();

        let output = cmd()
            .args(["-v", src.to_str().unwrap(), dst.to_str().unwrap()])
            .output()
            .unwrap();
        assert!(output.status.success());
        let stderr = String::from_utf8_lossy(&output.stderr);
        assert!(
            stderr.contains("->"),
            "verbose output should contain '->': {}",
            stderr
        );
    }

    #[cfg(unix)]
    #[test]
    fn test_install_matches_gnu() {
        // Compare with GNU install on basic file copy
        let dir = tempfile::tempdir().unwrap();

        let gnu_src = dir.path().join("gnu_src.txt");
        let gnu_dst = dir.path().join("gnu_dst.txt");
        let our_src = dir.path().join("our_src.txt");
        let our_dst = dir.path().join("our_dst.txt");

        fs::write(&gnu_src, "test data").unwrap();
        fs::write(&our_src, "test data").unwrap();

        let gnu = Command::new("install")
            .args([gnu_src.to_str().unwrap(), gnu_dst.to_str().unwrap()])
            .output();

        if let Ok(gnu_output) = gnu {
            let our_output = cmd()
                .args([our_src.to_str().unwrap(), our_dst.to_str().unwrap()])
                .output()
                .unwrap();
            assert_eq!(
                our_output.status.code(),
                gnu_output.status.code(),
                "Exit codes should match"
            );
            if gnu_output.status.success() {
                assert_eq!(
                    fs::read_to_string(&gnu_dst).unwrap(),
                    fs::read_to_string(&our_dst).unwrap(),
                    "File contents should match"
                );

                // Check that both set 0755
                #[cfg(unix)]
                {
                    use std::os::unix::fs::PermissionsExt;
                    let gnu_mode = fs::metadata(&gnu_dst).unwrap().permissions().mode() & 0o777;
                    let our_mode = fs::metadata(&our_dst).unwrap().permissions().mode() & 0o777;
                    assert_eq!(
                        gnu_mode, our_mode,
                        "Modes should match: gnu={:o} ours={:o}",
                        gnu_mode, our_mode
                    );
                }
            }
        }
    }
    #[cfg(unix)]
    #[test]
    fn test_install_missing_operand() {
        let output = cmd().output().unwrap();
        assert_eq!(output.status.code(), Some(1));
        let stderr = String::from_utf8_lossy(&output.stderr);
        assert!(stderr.contains("missing file operand"));
    }

    #[cfg(unix)]
    #[test]
    fn test_install_target_directory() {
        let dir = tempfile::tempdir().unwrap();
        let src = dir.path().join("td_src.txt");
        let dest_dir = dir.path().join("td_dest");
        fs::write(&src, "content").unwrap();
        fs::create_dir(&dest_dir).unwrap();

        let output = cmd()
            .args(["-t", dest_dir.to_str().unwrap(), src.to_str().unwrap()])
            .output()
            .unwrap();
        assert!(output.status.success());
        assert!(dest_dir.join("td_src.txt").exists());
    }

    #[cfg(unix)]
    #[test]
    fn test_install_preserve_timestamps() {
        let dir = tempfile::tempdir().unwrap();
        let src = dir.path().join("ts_src.txt");
        let dst = dir.path().join("ts_dst.txt");
        fs::write(&src, "timestamps").unwrap();

        // Wait a bit so the install time would differ
        std::thread::sleep(std::time::Duration::from_millis(50));

        let output = cmd()
            .args(["-p", src.to_str().unwrap(), dst.to_str().unwrap()])
            .output()
            .unwrap();
        assert!(
            output.status.success(),
            "install -p should succeed: {}",
            String::from_utf8_lossy(&output.stderr)
        );

        let src_mtime = fs::metadata(&src).unwrap().modified().unwrap();
        let dst_mtime = fs::metadata(&dst).unwrap().modified().unwrap();
        assert_eq!(
            src_mtime, dst_mtime,
            "modification times should match with -p"
        );
    }

    #[cfg(unix)]
    #[test]
    fn test_install_multiple_to_directory() {
        let dir = tempfile::tempdir().unwrap();
        let f1 = dir.path().join("a.txt");
        let f2 = dir.path().join("b.txt");
        let dest = dir.path().join("dest");
        fs::write(&f1, "aaa").unwrap();
        fs::write(&f2, "bbb").unwrap();
        fs::create_dir(&dest).unwrap();

        let output = cmd()
            .args([
                f1.to_str().unwrap(),
                f2.to_str().unwrap(),
                dest.to_str().unwrap(),
            ])
            .output()
            .unwrap();
        assert!(output.status.success());
        assert!(dest.join("a.txt").exists());
        assert!(dest.join("b.txt").exists());
    }

    #[cfg(unix)]
    #[test]
    fn test_install_backup() {
        let dir = tempfile::tempdir().unwrap();
        let src = dir.path().join("bak_src.txt");
        let dst = dir.path().join("bak_dst.txt");
        fs::write(&src, "new").unwrap();
        fs::write(&dst, "old").unwrap();

        let output = cmd()
            .args(["-b", src.to_str().unwrap(), dst.to_str().unwrap()])
            .output()
            .unwrap();
        assert!(output.status.success());

        let backup = dir.path().join("bak_dst.txt~");
        assert!(backup.exists(), "backup file should exist");
        assert_eq!(fs::read_to_string(&backup).unwrap(), "old");
        assert_eq!(fs::read_to_string(&dst).unwrap(), "new");
    }

    #[cfg(unix)]
    #[test]
    fn test_install_directory_nested() {
        let dir = tempfile::tempdir().unwrap();
        let nested = dir.path().join("x").join("y").join("z");

        let output = cmd()
            .args(["-d", nested.to_str().unwrap()])
            .output()
            .unwrap();
        assert!(
            output.status.success(),
            "install -d with nested dirs should succeed: {}",
            String::from_utf8_lossy(&output.stderr)
        );
        assert!(nested.is_dir());
    }
}
