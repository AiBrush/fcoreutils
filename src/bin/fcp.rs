#[cfg(not(unix))]
fn main() {
    eprintln!("cp: only available on Unix");
    std::process::exit(1);
}

#[cfg(unix)]
use std::process;

#[cfg(unix)]
use coreutils_rs::common::reset_sigpipe;
#[cfg(unix)]
use coreutils_rs::cp::{
    CpConfig, DerefMode, apply_preserve, parse_backup_mode, parse_reflink_mode,
};

#[cfg(unix)]
const TOOL_NAME: &str = "cp";
#[cfg(unix)]
const VERSION: &str = env!("CARGO_PKG_VERSION");

#[cfg(unix)]
fn print_help() {
    print!(
        "\
Usage: cp [OPTION]... [-T] SOURCE DEST
  or:  cp [OPTION]... SOURCE... DIRECTORY
  or:  cp [OPTION]... -t DIRECTORY SOURCE...
Copy SOURCE to DEST, or multiple SOURCE(s) to DIRECTORY.

  -a, --archive              same as -dR --preserve=all
  -b                         like --backup but does not accept an argument
      --backup[=CONTROL]     make a backup of each existing destination file
  -d                         same as --no-dereference --preserve=links
  -f, --force                if an existing destination file cannot be
                               opened, remove it and try again
  -i, --interactive          prompt before overwrite
  -H                         follow command-line symbolic links in SOURCE
  -l, --link                 hard link files instead of copying
  -L, --dereference          always follow symbolic links in SOURCE
  -n, --no-clobber           do not overwrite an existing file
  -P, --no-dereference       never follow symbolic links in SOURCE
  -p                         same as --preserve=mode,ownership,timestamps
      --preserve[=ATTR_LIST] preserve the specified attributes (default:
                               mode,ownership,timestamps)
  -R, -r, --recursive        copy directories recursively
      --reflink[=WHEN]       control clone/CoW copies (auto, always, never)
  -s, --symbolic-link        make symbolic links instead of copying
  -S, --suffix=SUFFIX        override the usual backup suffix
  -t, --target-directory=DIR copy all SOURCE arguments into DIRECTORY
  -T, --no-target-directory  treat DEST as a normal file
  -u, --update               copy only when the SOURCE file is newer
  -v, --verbose              explain what is being done
  -x, --one-file-system      stay on this file system
      --help                 display this help and exit
      --version              output version information and exit
"
    );
}

#[cfg(unix)]
fn main() {
    reset_sigpipe();

    let mut config = CpConfig::default();
    let mut positional: Vec<String> = Vec::new();
    let mut saw_dashdash = false;

    let args: Vec<String> = std::env::args().skip(1).collect();
    let mut i = 0;

    while i < args.len() {
        let arg = &args[i];

        if saw_dashdash {
            positional.push(arg.clone());
            i += 1;
            continue;
        }

        if arg == "--" {
            saw_dashdash = true;
            i += 1;
            continue;
        }

        // Long options
        if arg.starts_with("--") {
            if let Some(eq_pos) = arg.find('=') {
                let (key, val) = arg.split_at(eq_pos);
                let val = &val[1..]; // skip '='
                match key {
                    "--backup" => match parse_backup_mode(val) {
                        Ok(m) => config.backup = Some(m),
                        Err(e) => {
                            eprintln!("cp: {}", e);
                            process::exit(1);
                        }
                    },
                    "--preserve" => apply_preserve(val, &mut config),
                    "--reflink" => match parse_reflink_mode(val) {
                        Ok(m) => config.reflink = m,
                        Err(e) => {
                            eprintln!("cp: {}", e);
                            process::exit(1);
                        }
                    },
                    "--suffix" => config.suffix = val.to_string(),
                    "--target-directory" => config.target_directory = Some(val.to_string()),
                    _ => {
                        eprintln!("cp: unrecognized option '{}'", arg);
                        eprintln!("Try 'cp --help' for more information.");
                        process::exit(1);
                    }
                }
                i += 1;
                continue;
            }

            match arg.as_str() {
                "--help" => {
                    print_help();
                    process::exit(0);
                }
                "--version" => {
                    println!("{} (fcoreutils) {}", TOOL_NAME, VERSION);
                    process::exit(0);
                }
                "--archive" => {
                    config.dereference = DerefMode::Never;
                    config.recursive = true;
                    config.preserve_mode = true;
                    config.preserve_ownership = true;
                    config.preserve_timestamps = true;
                }
                "--backup" => {
                    config.backup = Some(coreutils_rs::cp::BackupMode::Existing);
                }
                "--force" => config.force = true,
                "--interactive" => config.interactive = true,
                "--link" => config.link = true,
                "--dereference" => config.dereference = DerefMode::Always,
                "--no-clobber" => config.no_clobber = true,
                "--no-dereference" => config.dereference = DerefMode::Never,
                "--preserve" => {
                    apply_preserve("mode,ownership,timestamps", &mut config);
                }
                "--recursive" => config.recursive = true,
                "--reflink" => config.reflink = coreutils_rs::cp::ReflinkMode::Auto,
                "--symbolic-link" => config.symbolic_link = true,
                "--no-target-directory" => config.no_target_directory = true,
                "--update" => config.update = true,
                "--verbose" => config.verbose = true,
                "--one-file-system" => config.one_file_system = true,
                _ => {
                    eprintln!("cp: unrecognized option '{}'", arg);
                    eprintln!("Try 'cp --help' for more information.");
                    process::exit(1);
                }
            }
            i += 1;
            continue;
        }

        // Short options
        if arg.starts_with('-') && arg.len() > 1 {
            let bytes = arg.as_bytes();
            let mut j = 1;
            while j < bytes.len() {
                match bytes[j] {
                    b'a' => {
                        config.dereference = DerefMode::Never;
                        config.recursive = true;
                        config.preserve_mode = true;
                        config.preserve_ownership = true;
                        config.preserve_timestamps = true;
                    }
                    b'b' => {
                        config.backup = Some(coreutils_rs::cp::BackupMode::Existing);
                    }
                    b'd' => {
                        config.dereference = DerefMode::Never;
                        // --preserve=links is acknowledged but links preservation
                        // is not yet fully implemented.
                    }
                    b'f' => config.force = true,
                    b'i' => config.interactive = true,
                    b'H' => config.dereference = DerefMode::CommandLine,
                    b'l' => config.link = true,
                    b'L' => config.dereference = DerefMode::Always,
                    b'n' => config.no_clobber = true,
                    b'P' => config.dereference = DerefMode::Never,
                    b'p' => {
                        config.preserve_mode = true;
                        config.preserve_ownership = true;
                        config.preserve_timestamps = true;
                    }
                    b'R' | b'r' => config.recursive = true,
                    b's' => config.symbolic_link = true,
                    b'S' => {
                        // -S SUFFIX: value is either rest of this arg or next arg.
                        let rest = &arg[(j + 1)..];
                        if !rest.is_empty() {
                            config.suffix = rest.to_string();
                        } else {
                            i += 1;
                            if i >= args.len() {
                                eprintln!("cp: option requires an argument -- 'S'");
                                process::exit(1);
                            }
                            config.suffix = args[i].clone();
                        }
                        j = bytes.len(); // consumed rest
                        continue;
                    }
                    b't' => {
                        // -t DIR
                        let rest = &arg[(j + 1)..];
                        if !rest.is_empty() {
                            config.target_directory = Some(rest.to_string());
                        } else {
                            i += 1;
                            if i >= args.len() {
                                eprintln!("cp: option requires an argument -- 't'");
                                process::exit(1);
                            }
                            config.target_directory = Some(args[i].clone());
                        }
                        j = bytes.len();
                        continue;
                    }
                    b'T' => config.no_target_directory = true,
                    b'u' => config.update = true,
                    b'v' => config.verbose = true,
                    b'x' => config.one_file_system = true,
                    _ => {
                        eprintln!("cp: invalid option -- '{}'", bytes[j] as char);
                        eprintln!("Try 'cp --help' for more information.");
                        process::exit(1);
                    }
                }
                j += 1;
            }
            i += 1;
            continue;
        }

        // Positional argument
        positional.push(arg.clone());
        i += 1;
    }

    if positional.is_empty() {
        eprintln!("cp: missing file operand");
        eprintln!("Try 'cp --help' for more information.");
        process::exit(1);
    }

    // If --target-directory is set, all positional args are sources.
    let (sources, dest) = if config.target_directory.is_some() {
        (positional.as_slice(), None)
    } else if positional.len() == 1 {
        eprintln!(
            "cp: missing destination file operand after '{}'",
            positional[0]
        );
        eprintln!("Try 'cp --help' for more information.");
        process::exit(1);
    } else {
        let (srcs, dst) = positional.split_at(positional.len() - 1);
        (srcs, Some(dst[0].as_str()))
    };

    let (errors, had_error) = coreutils_rs::cp::run_cp(sources, dest, &config);
    for e in &errors {
        eprintln!("{}", e);
    }

    if had_error {
        process::exit(1);
    }
}

#[cfg(test)]
mod tests {
    use std::process::Command;

    fn cmd() -> Command {
        let mut path = std::env::current_exe().unwrap();
        path.pop();
        path.pop();
        path.push("fcp");
        Command::new(path)
    }
    #[test]
    fn test_cp_basic_file() {
        let dir = tempfile::tempdir().unwrap();
        let src = dir.path().join("src.txt");
        let dst = dir.path().join("dst.txt");
        std::fs::write(&src, "hello world\n").unwrap();
        let output = cmd()
            .args([src.to_str().unwrap(), dst.to_str().unwrap()])
            .output()
            .unwrap();
        assert!(
            output.status.success(),
            "stderr: {}",
            String::from_utf8_lossy(&output.stderr)
        );
        assert_eq!(std::fs::read_to_string(&dst).unwrap(), "hello world\n");
    }

    #[test]
    fn test_cp_to_directory() {
        let dir = tempfile::tempdir().unwrap();
        let src = dir.path().join("file.txt");
        let target_dir = dir.path().join("target");
        std::fs::write(&src, "content\n").unwrap();
        std::fs::create_dir(&target_dir).unwrap();
        let output = cmd()
            .args([src.to_str().unwrap(), target_dir.to_str().unwrap()])
            .output()
            .unwrap();
        assert!(output.status.success());
        assert_eq!(
            std::fs::read_to_string(target_dir.join("file.txt")).unwrap(),
            "content\n"
        );
    }

    #[test]
    fn test_cp_recursive() {
        let dir = tempfile::tempdir().unwrap();
        let src_dir = dir.path().join("src");
        std::fs::create_dir(&src_dir).unwrap();
        std::fs::write(src_dir.join("a.txt"), "aaa\n").unwrap();
        std::fs::create_dir(src_dir.join("sub")).unwrap();
        std::fs::write(src_dir.join("sub").join("b.txt"), "bbb\n").unwrap();
        let dst_dir = dir.path().join("dst");
        let output = cmd()
            .args(["-r", src_dir.to_str().unwrap(), dst_dir.to_str().unwrap()])
            .output()
            .unwrap();
        assert!(
            output.status.success(),
            "stderr: {}",
            String::from_utf8_lossy(&output.stderr)
        );
        assert_eq!(
            std::fs::read_to_string(dst_dir.join("a.txt")).unwrap(),
            "aaa\n"
        );
        assert_eq!(
            std::fs::read_to_string(dst_dir.join("sub").join("b.txt")).unwrap(),
            "bbb\n"
        );
    }

    #[test]
    fn test_cp_nonexistent_source() {
        let dir = tempfile::tempdir().unwrap();
        let output = cmd()
            .args([
                "/nonexistent/file.txt",
                dir.path().join("dst").to_str().unwrap(),
            ])
            .output()
            .unwrap();
        assert!(!output.status.success());
    }

    #[test]
    fn test_cp_no_args() {
        let output = cmd().output().unwrap();
        assert!(!output.status.success());
    }

    #[test]
    fn test_cp_preserve_content() {
        let dir = tempfile::tempdir().unwrap();
        let src = dir.path().join("binary.dat");
        let dst = dir.path().join("copy.dat");
        let data: Vec<u8> = (0..=255).cycle().take(4096).collect();
        std::fs::write(&src, &data).unwrap();
        let output = cmd()
            .args([src.to_str().unwrap(), dst.to_str().unwrap()])
            .output()
            .unwrap();
        assert!(output.status.success());
        assert_eq!(std::fs::read(&dst).unwrap(), data);
    }

    #[test]
    fn test_cp_empty_file() {
        let dir = tempfile::tempdir().unwrap();
        let src = dir.path().join("empty.txt");
        let dst = dir.path().join("copy.txt");
        std::fs::write(&src, "").unwrap();
        let output = cmd()
            .args([src.to_str().unwrap(), dst.to_str().unwrap()])
            .output()
            .unwrap();
        assert!(output.status.success());
        assert_eq!(std::fs::read_to_string(&dst).unwrap(), "");
    }

    #[test]
    fn test_cp_overwrite() {
        let dir = tempfile::tempdir().unwrap();
        let src = dir.path().join("src.txt");
        let dst = dir.path().join("dst.txt");
        std::fs::write(&src, "new content\n").unwrap();
        std::fs::write(&dst, "old content\n").unwrap();
        let output = cmd()
            .args([src.to_str().unwrap(), dst.to_str().unwrap()])
            .output()
            .unwrap();
        assert!(output.status.success());
        assert_eq!(std::fs::read_to_string(&dst).unwrap(), "new content\n");
    }

    #[test]
    fn test_cp_multiple_files_to_dir() {
        let dir = tempfile::tempdir().unwrap();
        let f1 = dir.path().join("a.txt");
        let f2 = dir.path().join("b.txt");
        let target = dir.path().join("target");
        std::fs::write(&f1, "aaa\n").unwrap();
        std::fs::write(&f2, "bbb\n").unwrap();
        std::fs::create_dir(&target).unwrap();
        let output = cmd()
            .args([
                f1.to_str().unwrap(),
                f2.to_str().unwrap(),
                target.to_str().unwrap(),
            ])
            .output()
            .unwrap();
        assert!(output.status.success());
        assert!(target.join("a.txt").exists());
        assert!(target.join("b.txt").exists());
    }

    #[cfg(unix)]
    #[test]
    fn test_cp_symlink() {
        let dir = tempfile::tempdir().unwrap();
        let src = dir.path().join("src.txt");
        let link = dir.path().join("link.txt");
        let dst = dir.path().join("dst.txt");
        std::fs::write(&src, "content\n").unwrap();
        std::os::unix::fs::symlink(&src, &link).unwrap();
        let output = cmd()
            .args([link.to_str().unwrap(), dst.to_str().unwrap()])
            .output()
            .unwrap();
        assert!(output.status.success());
        // By default, cp follows symlinks
        assert_eq!(std::fs::read_to_string(&dst).unwrap(), "content\n");
    }

    #[test]
    fn test_cp_no_clobber() {
        let dir = tempfile::tempdir().unwrap();
        let src = dir.path().join("src.txt");
        let dst = dir.path().join("dst.txt");
        std::fs::write(&src, "new\n").unwrap();
        std::fs::write(&dst, "old\n").unwrap();
        let output = cmd()
            .args(["-n", src.to_str().unwrap(), dst.to_str().unwrap()])
            .output()
            .unwrap();
        assert!(output.status.success());
        // File should NOT be overwritten
        assert_eq!(std::fs::read_to_string(&dst).unwrap(), "old\n");
    }

    #[test]
    fn test_cp_large_file() {
        let dir = tempfile::tempdir().unwrap();
        let src = dir.path().join("large.dat");
        let dst = dir.path().join("copy.dat");
        let data = vec![0x42u8; 2 * 1024 * 1024]; // 2MB
        std::fs::write(&src, &data).unwrap();
        let output = cmd()
            .args([src.to_str().unwrap(), dst.to_str().unwrap()])
            .output()
            .unwrap();
        assert!(output.status.success());
        assert_eq!(std::fs::metadata(&dst).unwrap().len(), 2 * 1024 * 1024);
    }
}
