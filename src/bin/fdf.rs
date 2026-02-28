#[cfg(not(unix))]
fn main() {
    eprintln!("df: only available on Unix");
    std::process::exit(1);
}

#[cfg(unix)]
use std::process;

#[cfg(unix)]
use coreutils_rs::common::reset_sigpipe;
#[cfg(unix)]
use coreutils_rs::df::{DfConfig, parse_block_size, parse_output_fields, run_df};

#[cfg(unix)]
const TOOL_NAME: &str = "df";
#[cfg(unix)]
const VERSION: &str = env!("CARGO_PKG_VERSION");

/// Take the next value for an option from the rest of the current arg or the next arg.
#[cfg(unix)]
fn take_value(
    bytes: &[u8],
    pos: usize,
    args: &mut impl Iterator<Item = std::ffi::OsString>,
    flag: &str,
) -> String {
    if pos < bytes.len() {
        let full = String::from_utf8_lossy(bytes).into_owned();
        full[pos..].to_string()
    } else {
        args.next()
            .unwrap_or_else(|| {
                eprintln!("{}: option requires an argument -- '{}'", TOOL_NAME, flag);
                process::exit(1);
            })
            .to_string_lossy()
            .into_owned()
    }
}

#[cfg(unix)]
fn parse_args() -> DfConfig {
    let mut config = DfConfig::default();
    let mut args = std::env::args_os().skip(1);

    #[allow(clippy::while_let_on_iterator)]
    while let Some(arg) = args.next() {
        let bytes = arg.as_encoded_bytes();

        if bytes == b"--" {
            // Everything after -- is a file argument.
            for a in args {
                config.files.push(a.to_string_lossy().into_owned());
            }
            break;
        }

        if bytes.starts_with(b"--") {
            let arg_str = arg.to_string_lossy();
            let long = &arg_str[2..];

            // Handle --option=value form.
            let (opt, val) = if let Some(eq_pos) = long.find('=') {
                (&long[..eq_pos], Some(&long[eq_pos + 1..]))
            } else {
                (long, None)
            };

            match opt {
                "all" => config.all = true,
                "block-size" => {
                    let v = val.map(|s| s.to_string()).unwrap_or_else(|| {
                        args.next()
                            .unwrap_or_else(|| {
                                eprintln!(
                                    "{}: option '--block-size' requires an argument",
                                    TOOL_NAME
                                );
                                process::exit(1);
                            })
                            .to_string_lossy()
                            .into_owned()
                    });
                    match parse_block_size(&v) {
                        Ok(bs) => config.block_size = bs,
                        Err(e) => {
                            eprintln!("{}: {}", TOOL_NAME, e);
                            process::exit(1);
                        }
                    }
                }
                "human-readable" => config.human_readable = true,
                "si" => config.si = true,
                "inodes" => config.inodes = true,
                "local" => config.local_only = true,
                "no-sync" => config.sync_before = false,
                "sync" => config.sync_before = true,
                "output" => {
                    if let Some(v) = val {
                        match parse_output_fields(v) {
                            Ok(fields) => config.output_fields = Some(fields),
                            Err(e) => {
                                eprintln!("{}: {}", TOOL_NAME, e);
                                process::exit(1);
                            }
                        }
                    } else {
                        // --output without =LIST means all fields.
                        config.output_fields = Some(
                            coreutils_rs::df::VALID_OUTPUT_FIELDS
                                .iter()
                                .map(|s| s.to_string())
                                .collect(),
                        );
                    }
                }
                "portability" => config.portability = true,
                "print-type" => config.print_type = true,
                "total" => config.total = true,
                "type" => {
                    let v = val.map(|s| s.to_string()).unwrap_or_else(|| {
                        args.next()
                            .unwrap_or_else(|| {
                                eprintln!("{}: option '--type' requires an argument", TOOL_NAME);
                                process::exit(1);
                            })
                            .to_string_lossy()
                            .into_owned()
                    });
                    config.type_filter.insert(v);
                }
                "exclude-type" => {
                    let v = val.map(|s| s.to_string()).unwrap_or_else(|| {
                        args.next()
                            .unwrap_or_else(|| {
                                eprintln!(
                                    "{}: option '--exclude-type' requires an argument",
                                    TOOL_NAME
                                );
                                process::exit(1);
                            })
                            .to_string_lossy()
                            .into_owned()
                    });
                    config.exclude_type.insert(v);
                }
                "help" => {
                    print_help();
                    process::exit(0);
                }
                "version" => {
                    println!("{} (fcoreutils) {}", TOOL_NAME, VERSION);
                    process::exit(0);
                }
                _ => {
                    eprintln!("{}: unrecognized option '--{}'", TOOL_NAME, opt);
                    eprintln!("Try '{} --help' for more information.", TOOL_NAME);
                    process::exit(1);
                }
            }
        } else if bytes.len() > 1 && bytes[0] == b'-' {
            // Short options.
            let mut i = 1;
            while i < bytes.len() {
                match bytes[i] {
                    b'a' => config.all = true,
                    b'B' => {
                        let v = take_value(bytes, i + 1, &mut args, "B");
                        match parse_block_size(&v) {
                            Ok(bs) => config.block_size = bs,
                            Err(e) => {
                                eprintln!("{}: {}", TOOL_NAME, e);
                                process::exit(1);
                            }
                        }
                        break;
                    }
                    b'h' => config.human_readable = true,
                    b'H' => config.si = true,
                    b'i' => config.inodes = true,
                    b'k' => config.block_size = 1024,
                    b'l' => config.local_only = true,
                    b'P' => config.portability = true,
                    b'T' => config.print_type = true,
                    b't' => {
                        let v = take_value(bytes, i + 1, &mut args, "t");
                        config.type_filter.insert(v);
                        break;
                    }
                    b'x' => {
                        let v = take_value(bytes, i + 1, &mut args, "x");
                        config.exclude_type.insert(v);
                        break;
                    }
                    _ => {
                        eprintln!("{}: invalid option -- '{}'", TOOL_NAME, bytes[i] as char);
                        eprintln!("Try '{} --help' for more information.", TOOL_NAME);
                        process::exit(1);
                    }
                }
                i += 1;
            }
        } else {
            config.files.push(arg.to_string_lossy().into_owned());
        }
    }

    config
}

#[cfg(unix)]
fn print_help() {
    print!(
        "Usage: {0} [OPTION]... [FILE]...\n\
         Show information about the file system on which each FILE resides,\n\
         or all file systems by default.\n\n\
         Mandatory arguments to long options are mandatory for short options too.\n\
         \x20 -a, --all             include pseudo, duplicate, inaccessible file systems\n\
         \x20 -B, --block-size=SIZE  scale sizes by SIZE before printing them; e.g.,\n\
         \x20                         '-BM' prints sizes in units of 1,048,576 bytes\n\
         \x20 -h, --human-readable  print sizes in powers of 1024 (e.g., 1023M)\n\
         \x20 -H, --si              print sizes in powers of 1000 (e.g., 1.1G)\n\
         \x20 -i, --inodes          list inode information instead of block usage\n\
         \x20 -k                    like --block-size=1K\n\
         \x20 -l, --local           limit listing to local file systems\n\
         \x20     --no-sync         do not invoke sync before getting usage info (default)\n\
         \x20     --output[=FIELD_LIST]  use the output format defined by FIELD_LIST,\n\
         \x20                         or print all fields if FIELD_LIST is omitted.\n\
         \x20 -P, --portability     use the POSIX output format\n\
         \x20     --sync            invoke sync before getting usage info\n\
         \x20     --total           elicit a grand total\n\
         \x20 -t, --type=TYPE       limit listing to file systems of type TYPE\n\
         \x20 -T, --print-type      print file system type\n\
         \x20 -x, --exclude-type=TYPE   limit listing to file systems not of type TYPE\n\
         \x20     --help            display this help and exit\n\
         \x20     --version         output version information and exit\n\n\
         FIELD_LIST is a comma-separated list of columns to be included.  Valid\n\
         field names are: 'source', 'fstype', 'itotal', 'iused', 'iavail',\n\
         'ipcent', 'size', 'used', 'avail', 'pcent', 'file' and 'target'\n",
        TOOL_NAME
    );
}

#[cfg(unix)]
fn main() {
    reset_sigpipe();

    let config = parse_args();

    // GNU df: --output conflicts with -i, -P, -T
    if config.output_fields.is_some() {
        if config.inodes {
            eprintln!(
                "{}: options --output and --inodes (-i) are mutually exclusive",
                TOOL_NAME
            );
            process::exit(1);
        }
        if config.portability {
            eprintln!(
                "{}: options --output and --portability (-P) are mutually exclusive",
                TOOL_NAME
            );
            process::exit(1);
        }
        if config.print_type {
            eprintln!(
                "{}: options --output and --print-type (-T) are mutually exclusive",
                TOOL_NAME
            );
            process::exit(1);
        }
    }

    let exit_code = run_df(&config);
    process::exit(exit_code);
}

#[cfg(test)]
mod tests {
    use std::process::Command;

    fn cmd() -> Command {
        let mut path = std::env::current_exe().unwrap();
        path.pop();
        path.pop();
        path.push("fdf");
        Command::new(path)
    }

    #[cfg(target_os = "linux")]
    #[test]
    fn test_df_runs() {
        let output = cmd().output().unwrap();
        assert_eq!(output.status.code(), Some(0), "df should exit 0");
        let stdout = String::from_utf8_lossy(&output.stdout);
        assert!(
            stdout.contains("Filesystem"),
            "Should have Filesystem header"
        );
        assert!(
            stdout.contains("Mounted on"),
            "Should have 'Mounted on' header"
        );
        // Should have at least one filesystem line beyond the header.
        assert!(
            stdout.lines().count() >= 2,
            "Should have at least header + 1 line"
        );
    }

    #[cfg(target_os = "linux")]
    #[test]
    fn test_df_human() {
        let output = cmd().arg("-h").output().unwrap();
        assert_eq!(output.status.code(), Some(0));
        let stdout = String::from_utf8_lossy(&output.stdout);
        assert!(
            stdout.contains("Size"),
            "Human-readable should use 'Size' header"
        );
        // Human-readable output should contain unit suffixes.
        let has_suffix = stdout.contains('K')
            || stdout.contains('M')
            || stdout.contains('G')
            || stdout.contains('T');
        assert!(
            has_suffix,
            "Human-readable output should contain size suffixes"
        );
    }

    #[cfg(target_os = "linux")]
    #[test]
    fn test_df_inodes() {
        let output = cmd().arg("-i").output().unwrap();
        assert_eq!(output.status.code(), Some(0));
        let stdout = String::from_utf8_lossy(&output.stdout);
        assert!(stdout.contains("Inodes"), "Should have Inodes header");
        assert!(stdout.contains("IUsed"), "Should have IUsed header");
        assert!(stdout.contains("IFree"), "Should have IFree header");
        assert!(stdout.contains("IUse%"), "Should have IUse% header");
    }

    #[cfg(target_os = "linux")]
    #[test]
    fn test_df_type_filter() {
        // Filter for tmpfs which should exist on most Linux systems.
        let output = cmd().args(["-t", "tmpfs"]).output().unwrap();
        assert_eq!(output.status.code(), Some(0));
        let stdout = String::from_utf8_lossy(&output.stdout);
        // All non-header lines should be tmpfs mounts. If tmpfs not present, just header.
        for line in stdout.lines().skip(1) {
            // When filtering by type, result set is restricted to that type.
            // We don't verify the type column here since -T isn't passed,
            // but the filter should not crash.
            assert!(!line.is_empty());
        }
    }

    #[cfg(target_os = "linux")]
    #[test]
    fn test_df_exclude() {
        let output = cmd().args(["-x", "tmpfs"]).output().unwrap();
        assert_eq!(output.status.code(), Some(0));
        let stdout = String::from_utf8_lossy(&output.stdout);
        // With -T we could verify no tmpfs line appears, but without -T we just
        // check it runs successfully.
        assert!(stdout.contains("Filesystem"));
        // Additionally verify with -T to ensure tmpfs is excluded.
        let output2 = cmd().args(["-x", "tmpfs", "-T"]).output().unwrap();
        assert_eq!(output2.status.code(), Some(0));
        let stdout2 = String::from_utf8_lossy(&output2.stdout);
        for line in stdout2.lines().skip(1) {
            let parts: Vec<&str> = line.split_whitespace().collect();
            if parts.len() >= 2 {
                assert_ne!(parts[1], "tmpfs", "tmpfs should be excluded");
            }
        }
    }

    #[cfg(target_os = "linux")]
    #[test]
    fn test_df_total() {
        let output = cmd().arg("--total").output().unwrap();
        assert_eq!(output.status.code(), Some(0));
        let stdout = String::from_utf8_lossy(&output.stdout);
        let last_line = stdout.lines().last().unwrap_or("");
        assert!(
            last_line.starts_with("total"),
            "Last line should start with 'total', got: '{}'",
            last_line
        );
    }

    #[cfg(target_os = "linux")]
    #[test]
    fn test_df_print_type() {
        let output = cmd().arg("-T").output().unwrap();
        assert_eq!(output.status.code(), Some(0));
        let stdout = String::from_utf8_lossy(&output.stdout);
        assert!(stdout.contains("Type"), "Should have 'Type' column header");
    }

    #[cfg(target_os = "linux")]
    #[test]
    fn test_df_specific_file() {
        let output = cmd().arg("/").output().unwrap();
        assert_eq!(output.status.code(), Some(0));
        let stdout = String::from_utf8_lossy(&output.stdout);
        // Should show exactly header + 1 filesystem line.
        let line_count = stdout.lines().count();
        assert_eq!(
            line_count, 2,
            "df / should show header + 1 line, got {} lines",
            line_count
        );
        // The filesystem should have / as the mount point.
        let fs_line = stdout.lines().nth(1).unwrap();
        assert!(
            fs_line.contains('/'),
            "Filesystem line should contain '/' mount point"
        );
    }

    #[cfg(target_os = "linux")]
    #[test]
    fn test_df_portability() {
        let output = cmd().arg("-P").output().unwrap();
        assert_eq!(output.status.code(), Some(0));
        let stdout = String::from_utf8_lossy(&output.stdout);
        // POSIX format uses "Capacity" instead of "Use%".
        assert!(
            stdout.contains("Capacity"),
            "Portability mode should use 'Capacity' header"
        );
        assert!(
            stdout.contains("Available"),
            "Portability mode should use 'Available' header"
        );
        // Each filesystem entry should be on a single line (POSIX requirement).
        for line in stdout.lines().skip(1) {
            let parts: Vec<&str> = line.split_whitespace().collect();
            assert!(
                parts.len() >= 6,
                "POSIX format line should have at least 6 fields, got {}: '{}'",
                parts.len(),
                line
            );
        }
    }

    #[cfg(target_os = "linux")]
    #[test]
    fn test_df_matches_gnu_format() {
        // Compare column count with GNU df.
        let gnu = std::process::Command::new("df").arg("/").output();
        if let Ok(gnu) = gnu {
            let ours = cmd().arg("/").output().unwrap();
            let gnu_stdout = String::from_utf8_lossy(&gnu.stdout);
            let our_stdout = String::from_utf8_lossy(&ours.stdout);

            // Both should have the same number of output lines.
            assert_eq!(
                gnu_stdout.lines().count(),
                our_stdout.lines().count(),
                "Line count should match GNU df"
            );

            // Headers should have the same column names.
            let gnu_header = gnu_stdout.lines().next().unwrap_or("");
            let our_header = our_stdout.lines().next().unwrap_or("");
            assert!(
                our_header.contains("Filesystem"),
                "Our header should contain 'Filesystem'"
            );
            assert!(
                gnu_header.contains("Filesystem"),
                "GNU header should contain 'Filesystem'"
            );

            // Both should show the same number of columns.
            let gnu_cols = gnu_header.split_whitespace().count();
            let our_cols = our_header.split_whitespace().count();
            // GNU uses "Mounted on" (2 words) and "1K-blocks" (1 word): 6 tokens total.
            // We should match this.
            assert_eq!(
                our_cols, gnu_cols,
                "Column count should match: ours={}, gnu={}",
                our_cols, gnu_cols
            );
        }
    }
}
