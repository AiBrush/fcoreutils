use std::path::Path;
use std::process;

const TOOL_NAME: &str = "shred";
const VERSION: &str = env!("CARGO_PKG_VERSION");

fn print_help() {
    println!("Usage: {} [OPTION]... FILE...", TOOL_NAME);
    println!("Overwrite the specified FILE(s) repeatedly, in order to make it harder");
    println!("for even very expensive hardware probing to recover the data.");
    println!();
    println!("If FILE is -, shred standard output.");
    println!();
    println!("  -f, --force        change permissions to allow writing if necessary");
    println!("  -n, --iterations=N overwrite N times instead of the default (3)");
    println!("  -s, --size=N       shred this many bytes (suffixes like K, M, G accepted)");
    println!("  -u                 deallocate and remove file after overwriting");
    println!("      --remove[=HOW] like -u but give control on HOW to delete;  See below");
    println!("  -v, --verbose      show progress");
    println!("  -x, --exact        do not round file sizes up to the next full block;");
    println!("                       this is the default for non-regular files");
    println!("  -z, --zero         add a final overwrite with zeros to hide shredding");
    println!("      --help         display this help and exit");
    println!("      --version      output version information and exit");
    println!();
    println!("Delete FILE(s) if --remove (-u) is specified.  The default is not to remove");
    println!("the files because it is common to operate on device files like /dev/hda,");
    println!("and those files usually should not be removed.");
    println!();
    println!("CAUTION: shred assumes the file system and hardware overwrite data in place.");
    println!("This is not true on journaled, log-structured, or copy-on-write file systems.");
    println!();
    println!("HOW values for --remove:");
    println!("  'unlink'   => use a standard unlink call");
    println!("  'wipe'     => also first obfuscate bytes in the name");
    println!("  'wipesync' => also sync each obfuscated name to the device");
    println!("The default mode is 'wipesync', but note it can be expensive.");
}

fn main() {
    coreutils_rs::common::reset_sigpipe();

    let args: Vec<String> = std::env::args().skip(1).collect();

    let mut config = coreutils_rs::shred::ShredConfig::default();
    let mut files: Vec<String> = Vec::new();
    let mut saw_dashdash = false;
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
            "--" => {
                saw_dashdash = true;
            }
            "-f" | "--force" => {
                config.force = true;
            }
            "-v" | "--verbose" => {
                config.verbose = true;
            }
            "-x" | "--exact" => {
                config.exact = true;
            }
            "-z" | "--zero" => {
                config.zero_pass = true;
            }
            "-u" => {
                config.remove = Some(coreutils_rs::shred::RemoveMode::WipeSync);
            }
            "-n" => {
                i += 1;
                if i >= args.len() {
                    eprintln!("{}: option requires an argument -- 'n'", TOOL_NAME);
                    eprintln!("Try '{} --help' for more information.", TOOL_NAME);
                    process::exit(1);
                }
                config.iterations = match args[i].parse() {
                    Ok(n) => n,
                    Err(_) => {
                        eprintln!("{}: invalid number of passes: '{}'", TOOL_NAME, args[i]);
                        process::exit(1);
                    }
                };
            }
            "-s" => {
                i += 1;
                if i >= args.len() {
                    eprintln!("{}: option requires an argument -- 's'", TOOL_NAME);
                    eprintln!("Try '{} --help' for more information.", TOOL_NAME);
                    process::exit(1);
                }
                config.size = match coreutils_rs::shred::parse_size(&args[i]) {
                    Ok(n) => Some(n),
                    Err(e) => {
                        eprintln!("{}: {}", TOOL_NAME, e);
                        process::exit(1);
                    }
                };
            }
            _ if arg.starts_with("--iterations=") => {
                let val = &arg["--iterations=".len()..];
                config.iterations = match val.parse() {
                    Ok(n) => n,
                    Err(_) => {
                        eprintln!("{}: invalid number of passes: '{}'", TOOL_NAME, val);
                        process::exit(1);
                    }
                };
            }
            _ if arg.starts_with("--size=") => {
                let val = &arg["--size=".len()..];
                config.size = match coreutils_rs::shred::parse_size(val) {
                    Ok(n) => Some(n),
                    Err(e) => {
                        eprintln!("{}: {}", TOOL_NAME, e);
                        process::exit(1);
                    }
                };
            }
            _ if arg.starts_with("--remove") => match coreutils_rs::shred::parse_remove_mode(arg) {
                Ok(mode) => config.remove = Some(mode),
                Err(e) => {
                    eprintln!("{}: {}", TOOL_NAME, e);
                    process::exit(1);
                }
            },
            _ if arg.starts_with('-') && arg.len() > 1 && !arg.starts_with("--") => {
                // Parse combined short flags like -vfz
                let chars: Vec<char> = arg[1..].chars().collect();
                let mut j = 0;
                while j < chars.len() {
                    match chars[j] {
                        'f' => config.force = true,
                        'v' => config.verbose = true,
                        'x' => config.exact = true,
                        'z' => config.zero_pass = true,
                        'u' => {
                            config.remove = Some(coreutils_rs::shred::RemoveMode::WipeSync);
                        }
                        'n' => {
                            // Rest of this arg or next arg is the count
                            let rest: String = chars[j + 1..].iter().collect();
                            if rest.is_empty() {
                                i += 1;
                                if i >= args.len() {
                                    eprintln!("{}: option requires an argument -- 'n'", TOOL_NAME);
                                    process::exit(1);
                                }
                                config.iterations = match args[i].parse() {
                                    Ok(n) => n,
                                    Err(_) => {
                                        eprintln!(
                                            "{}: invalid number of passes: '{}'",
                                            TOOL_NAME, args[i]
                                        );
                                        process::exit(1);
                                    }
                                };
                            } else {
                                config.iterations = match rest.parse() {
                                    Ok(n) => n,
                                    Err(_) => {
                                        eprintln!(
                                            "{}: invalid number of passes: '{}'",
                                            TOOL_NAME, rest
                                        );
                                        process::exit(1);
                                    }
                                };
                            }
                            break;
                        }
                        's' => {
                            let rest: String = chars[j + 1..].iter().collect();
                            if rest.is_empty() {
                                i += 1;
                                if i >= args.len() {
                                    eprintln!("{}: option requires an argument -- 's'", TOOL_NAME);
                                    process::exit(1);
                                }
                                config.size = match coreutils_rs::shred::parse_size(&args[i]) {
                                    Ok(n) => Some(n),
                                    Err(e) => {
                                        eprintln!("{}: {}", TOOL_NAME, e);
                                        process::exit(1);
                                    }
                                };
                            } else {
                                config.size = match coreutils_rs::shred::parse_size(&rest) {
                                    Ok(n) => Some(n),
                                    Err(e) => {
                                        eprintln!("{}: {}", TOOL_NAME, e);
                                        process::exit(1);
                                    }
                                };
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
            _ => {
                files.push(arg.clone());
            }
        }
        i += 1;
    }

    if files.is_empty() {
        eprintln!("{}: missing file operand", TOOL_NAME);
        eprintln!("Try '{} --help' for more information.", TOOL_NAME);
        process::exit(1);
    }

    let mut exit_code = 0;
    for file in &files {
        let path = Path::new(file);
        if let Err(e) = coreutils_rs::shred::shred_file(path, &config) {
            eprintln!(
                "{}: {}: {}",
                TOOL_NAME,
                file,
                coreutils_rs::common::io_error_msg(&e)
            );
            exit_code = 1;
        }
    }

    if exit_code != 0 {
        process::exit(exit_code);
    }
}

#[cfg(test)]
mod tests {
    use std::process::Command;

    fn cmd() -> Command {
        let mut path = std::env::current_exe().unwrap();
        path.pop();
        path.pop();
        path.push("fshred");
        Command::new(path)
    }

    #[test]
    fn test_shred_overwrites() {
        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join("overwrite.txt");
        let original = b"This is secret data that should be overwritten";
        std::fs::write(&file, original).unwrap();

        let output = cmd().arg(file.to_str().unwrap()).output().unwrap();
        assert!(output.status.success(), "shred failed: {:?}", output);

        // File should still exist (no -u flag)
        assert!(file.exists());

        // Content should be different from original
        let content = std::fs::read(&file).unwrap();
        assert_ne!(&content[..original.len()], original);
    }

    #[test]
    fn test_shred_removes() {
        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join("remove.txt");
        std::fs::write(&file, "secret data").unwrap();

        let output = cmd().args(["-u", file.to_str().unwrap()]).output().unwrap();
        assert!(output.status.success(), "shred -u failed: {:?}", output);

        // File should be removed
        assert!(!file.exists());
    }

    #[test]
    fn test_shred_zero_pass() {
        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join("zero.txt");
        std::fs::write(&file, "secret data!").unwrap();

        let output = cmd().args(["-z", file.to_str().unwrap()]).output().unwrap();
        assert!(output.status.success(), "shred -z failed: {:?}", output);

        // File should still exist
        assert!(file.exists());

        // After zero pass, the file data within the original size should be all zeros
        // (if exact mode; otherwise it is rounded up)
        let content = std::fs::read(&file).unwrap();
        // The last pass was zeros, so the content should be all zeros
        assert!(
            content.iter().all(|&b| b == 0),
            "Expected all zeros after -z pass, got non-zero bytes"
        );
    }

    #[test]
    fn test_shred_iterations() {
        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join("iters.txt");
        std::fs::write(&file, "some data here").unwrap();

        let output = cmd()
            .args(["-n", "5", file.to_str().unwrap()])
            .output()
            .unwrap();
        assert!(output.status.success(), "shred -n 5 failed: {:?}", output);
        assert!(file.exists());
    }

    #[test]
    fn test_shred_verbose() {
        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join("verbose.txt");
        std::fs::write(&file, "some data").unwrap();

        let output = cmd()
            .args(["-v", "-n", "2", file.to_str().unwrap()])
            .output()
            .unwrap();
        assert!(output.status.success(), "shred -v failed: {:?}", output);

        let stderr = String::from_utf8_lossy(&output.stderr);
        assert!(
            stderr.contains("pass 1/2"),
            "Expected pass 1/2 in verbose output, got: {}",
            stderr
        );
        assert!(
            stderr.contains("pass 2/2"),
            "Expected pass 2/2 in verbose output, got: {}",
            stderr
        );
    }

    #[test]
    fn test_shred_size() {
        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join("sized.txt");
        std::fs::write(&file, "hello").unwrap();

        let output = cmd()
            .args(["-s", "1024", "-z", "-x", file.to_str().unwrap()])
            .output()
            .unwrap();
        assert!(
            output.status.success(),
            "shred -s 1024 failed: {:?}",
            output
        );

        // File should have been written with the specified size
        let content = std::fs::read(&file).unwrap();
        assert_eq!(content.len(), 1024);
        // With -z, content should be all zeros
        assert!(content.iter().all(|&b| b == 0));
    }

    #[test]
    fn test_shred_file_removed() {
        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join("gone.txt");
        std::fs::write(&file, "will be removed").unwrap();
        assert!(file.exists());

        let output = cmd().args(["-u", file.to_str().unwrap()]).output().unwrap();
        assert!(output.status.success());
        assert!(!file.exists(), "File should have been removed with -u");
    }

    #[test]
    fn test_shred_force() {
        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join("readonly.txt");
        std::fs::write(&file, "readonly data").unwrap();

        // Make the file read-only
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let perms = std::fs::Permissions::from_mode(0o444);
            std::fs::set_permissions(&file, perms).unwrap();
        }

        let output = cmd().args(["-f", file.to_str().unwrap()]).output().unwrap();
        assert!(
            output.status.success(),
            "shred -f failed on read-only file: {:?}",
            output
        );
    }
    #[test]
    fn test_shred_matches_gnu_behavior() {
        // Both should fail on nonexistent files
        let gnu = Command::new("shred").arg("/nonexistent_file_xyz").output();
        if let Ok(gnu) = gnu {
            let ours = cmd().arg("/nonexistent_file_xyz").output().unwrap();
            assert_eq!(
                ours.status.success(),
                gnu.status.success(),
                "Exit status mismatch with GNU shred on nonexistent file"
            );
        }
    }

    #[test]
    fn test_shred_missing_file() {
        let output = cmd().output().unwrap();
        assert!(!output.status.success());
        let stderr = String::from_utf8_lossy(&output.stderr);
        assert!(
            stderr.contains("missing file operand") || stderr.contains("Usage"),
            "Expected usage error, got: {}",
            stderr
        );
    }

    #[test]
    fn test_shred_exact() {
        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join("exact.txt");
        let data = b"hello world"; // 11 bytes, not block-aligned
        std::fs::write(&file, data).unwrap();

        let output = cmd()
            .args(["-x", "-z", file.to_str().unwrap()])
            .output()
            .unwrap();
        assert!(output.status.success());

        // With -x, the file should be exactly the original size
        let content = std::fs::read(&file).unwrap();
        assert_eq!(content.len(), data.len());
    }
}
