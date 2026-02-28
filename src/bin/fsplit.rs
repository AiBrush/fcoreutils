use std::process;

use coreutils_rs::common::reset_sigpipe;
use coreutils_rs::split::{self, SplitConfig, SplitMode, SuffixType};

struct Cli {
    config: SplitConfig,
    input: String,
    separator_set: bool,
}

/// Parse a CHUNKS spec for -n option.
/// Supported formats: N, K/N, l/N, l/K/N, r/N, r/K/N
fn parse_chunk_spec(val: &str) -> SplitMode {
    if let Some(rest) = val.strip_prefix("l/") {
        // l/N or l/K/N
        if let Some(slash_pos) = rest.find('/') {
            let k: u64 = rest[..slash_pos].parse().unwrap_or_else(|_| {
                eprintln!("split: invalid number of chunks: '{}'", val);
                process::exit(1);
            });
            let n: u64 = rest[slash_pos + 1..].parse().unwrap_or_else(|_| {
                eprintln!("split: invalid number of chunks: '{}'", val);
                process::exit(1);
            });
            SplitMode::LineChunkExtract(k, n)
        } else {
            let n: u64 = rest.parse().unwrap_or_else(|_| {
                eprintln!("split: invalid number of chunks: '{}'", val);
                process::exit(1);
            });
            SplitMode::LineChunks(n)
        }
    } else if let Some(rest) = val.strip_prefix("r/") {
        // r/N or r/K/N
        if let Some(slash_pos) = rest.find('/') {
            let k: u64 = rest[..slash_pos].parse().unwrap_or_else(|_| {
                eprintln!("split: invalid number of chunks: '{}'", val);
                process::exit(1);
            });
            let n: u64 = rest[slash_pos + 1..].parse().unwrap_or_else(|_| {
                eprintln!("split: invalid number of chunks: '{}'", val);
                process::exit(1);
            });
            SplitMode::RoundRobinExtract(k, n)
        } else {
            let n: u64 = rest.parse().unwrap_or_else(|_| {
                eprintln!("split: invalid number of chunks: '{}'", val);
                process::exit(1);
            });
            SplitMode::RoundRobin(n)
        }
    } else if let Some(slash_pos) = val.find('/') {
        // K/N
        let k: u64 = val[..slash_pos].parse().unwrap_or_else(|_| {
            eprintln!("split: invalid number of chunks: '{}'", val);
            process::exit(1);
        });
        let n: u64 = val[slash_pos + 1..].parse().unwrap_or_else(|_| {
            eprintln!("split: invalid number of chunks: '{}'", val);
            process::exit(1);
        });
        SplitMode::NumberExtract(k, n)
    } else {
        let n: u64 = val.parse().unwrap_or_else(|_| {
            eprintln!("split: invalid number of chunks: '{}'", val);
            process::exit(1);
        });
        SplitMode::Number(n)
    }
}

fn parse_args() -> Cli {
    let mut cli = Cli {
        config: SplitConfig::default(),
        input: "-".to_string(),
        separator_set: false,
    };

    let mut args = std::env::args_os().skip(1);
    let mut positional_count = 0;

    #[allow(clippy::while_let_on_iterator)]
    while let Some(arg) = args.next() {
        let bytes = arg.as_encoded_bytes();
        if bytes == b"--" {
            // Remaining args are positional
            for a in args {
                let s = a.to_string_lossy().into_owned();
                match positional_count {
                    0 => cli.input = s,
                    1 => cli.config.prefix = s,
                    _ => {
                        eprintln!("split: extra operand '{}'", s);
                        eprintln!("Try 'split --help' for more information.");
                        process::exit(1);
                    }
                }
                positional_count += 1;
            }
            break;
        }
        if bytes.starts_with(b"--") {
            let arg_str = arg.to_string_lossy();
            let arg_ref: &str = &arg_str;
            if let Some(val) = arg_ref.strip_prefix("--suffix-length=") {
                cli.config.suffix_length = val.parse().unwrap_or_else(|_| {
                    eprintln!("split: invalid suffix length: '{}'", val);
                    process::exit(1);
                });
            } else if let Some(val) = arg_ref.strip_prefix("--bytes=") {
                let size = split::parse_size(val).unwrap_or_else(|e| {
                    eprintln!("split: invalid number of bytes: '{}'", e);
                    process::exit(1);
                });
                cli.config.mode = SplitMode::Bytes(size);
            } else if let Some(val) = arg_ref.strip_prefix("--line-bytes=") {
                let size = split::parse_size(val).unwrap_or_else(|e| {
                    eprintln!("split: invalid number of bytes: '{}'", e);
                    process::exit(1);
                });
                cli.config.mode = SplitMode::LineBytes(size);
            } else if let Some(val) = arg_ref.strip_prefix("--lines=") {
                let n: u64 = val.parse().unwrap_or_else(|_| {
                    eprintln!("split: invalid number of lines: '{}'", val);
                    process::exit(1);
                });
                cli.config.mode = SplitMode::Lines(n);
            } else if let Some(val) = arg_ref.strip_prefix("--number=") {
                cli.config.mode = parse_chunk_spec(val);
            } else if let Some(val) = arg_ref.strip_prefix("--additional-suffix=") {
                cli.config.additional_suffix = val.to_string();
            } else if let Some(val) = arg_ref.strip_prefix("--numeric-suffixes=") {
                let from: u64 = val.parse().unwrap_or_else(|_| {
                    eprintln!("split: invalid start value: '{}'", val);
                    process::exit(1);
                });
                cli.config.suffix_type = SuffixType::Numeric(from);
            } else if arg_ref == "--numeric-suffixes" {
                cli.config.suffix_type = SuffixType::Numeric(0);
            } else if let Some(val) = arg_ref.strip_prefix("--hex-suffixes=") {
                let from: u64 = val.parse().unwrap_or_else(|_| {
                    eprintln!("split: invalid start value: '{}'", val);
                    process::exit(1);
                });
                cli.config.suffix_type = SuffixType::Hex(from);
            } else if arg_ref == "--hex-suffixes" {
                cli.config.suffix_type = SuffixType::Hex(0);
            } else if let Some(val) = arg_ref.strip_prefix("--filter=") {
                cli.config.filter = Some(val.to_string());
            } else if let Some(val) = arg_ref.strip_prefix("--separator=") {
                let new_sep = if val.len() == 1 {
                    val.as_bytes()[0]
                } else if val.is_empty() {
                    b'\0'
                } else {
                    eprintln!("split: multi-character separator '{}'", val);
                    process::exit(1);
                };
                if cli.separator_set && cli.config.separator != new_sep {
                    eprintln!("split: multiple separator characters specified");
                    process::exit(1);
                }
                cli.config.separator = new_sep;
                cli.separator_set = true;
            } else if arg_ref == "--elide-empty-files" {
                cli.config.elide_empty = true;
            } else if arg_ref == "--verbose" {
                cli.config.verbose = true;
            } else if arg_ref == "--help" {
                print_help();
                process::exit(0);
            } else if arg_ref == "--version" {
                println!("split (fcoreutils) {}", env!("CARGO_PKG_VERSION"));
                process::exit(0);
            } else {
                eprintln!("split: unrecognized option '{}'", arg_str);
                eprintln!("Try 'split --help' for more information.");
                process::exit(1);
            }
        } else if bytes.len() > 1 && bytes[0] == b'-' {
            // Short options: may be clustered
            let arg_str = arg.to_string_lossy();
            let chars: Vec<char> = arg_str[1..].chars().collect();
            let mut i = 0;
            while i < chars.len() {
                match chars[i] {
                    'a' => {
                        // -a N: suffix length
                        let val = if i + 1 < chars.len() {
                            chars[i + 1..].iter().collect::<String>()
                        } else {
                            args.next()
                                .unwrap_or_else(|| {
                                    eprintln!("split: option requires an argument -- 'a'");
                                    process::exit(1);
                                })
                                .to_string_lossy()
                                .into_owned()
                        };
                        cli.config.suffix_length = val.parse().unwrap_or_else(|_| {
                            eprintln!("split: invalid suffix length: '{}'", val);
                            process::exit(1);
                        });
                        break; // consumed rest of cluster
                    }
                    'b' => {
                        let val = if i + 1 < chars.len() {
                            chars[i + 1..].iter().collect::<String>()
                        } else {
                            args.next()
                                .unwrap_or_else(|| {
                                    eprintln!("split: option requires an argument -- 'b'");
                                    process::exit(1);
                                })
                                .to_string_lossy()
                                .into_owned()
                        };
                        let size = split::parse_size(&val).unwrap_or_else(|e| {
                            eprintln!("split: invalid number of bytes: '{}'", e);
                            process::exit(1);
                        });
                        cli.config.mode = SplitMode::Bytes(size);
                        break;
                    }
                    'C' => {
                        let val = if i + 1 < chars.len() {
                            chars[i + 1..].iter().collect::<String>()
                        } else {
                            args.next()
                                .unwrap_or_else(|| {
                                    eprintln!("split: option requires an argument -- 'C'");
                                    process::exit(1);
                                })
                                .to_string_lossy()
                                .into_owned()
                        };
                        let size = split::parse_size(&val).unwrap_or_else(|e| {
                            eprintln!("split: invalid number of bytes: '{}'", e);
                            process::exit(1);
                        });
                        cli.config.mode = SplitMode::LineBytes(size);
                        break;
                    }
                    'l' => {
                        let val = if i + 1 < chars.len() {
                            chars[i + 1..].iter().collect::<String>()
                        } else {
                            args.next()
                                .unwrap_or_else(|| {
                                    eprintln!("split: option requires an argument -- 'l'");
                                    process::exit(1);
                                })
                                .to_string_lossy()
                                .into_owned()
                        };
                        let n: u64 = val.parse().unwrap_or_else(|_| {
                            eprintln!("split: invalid number of lines: '{}'", val);
                            process::exit(1);
                        });
                        cli.config.mode = SplitMode::Lines(n);
                        break;
                    }
                    'n' => {
                        let val = if i + 1 < chars.len() {
                            chars[i + 1..].iter().collect::<String>()
                        } else {
                            args.next()
                                .unwrap_or_else(|| {
                                    eprintln!("split: option requires an argument -- 'n'");
                                    process::exit(1);
                                })
                                .to_string_lossy()
                                .into_owned()
                        };
                        cli.config.mode = parse_chunk_spec(&val);
                        break;
                    }
                    't' => {
                        let val = if i + 1 < chars.len() {
                            chars[i + 1..].iter().collect::<String>()
                        } else {
                            args.next()
                                .unwrap_or_else(|| {
                                    eprintln!("split: option requires an argument -- 't'");
                                    process::exit(1);
                                })
                                .to_string_lossy()
                                .into_owned()
                        };
                        let new_sep = if val.len() == 1 {
                            val.as_bytes()[0]
                        } else if val.is_empty() {
                            b'\0'
                        } else {
                            eprintln!("split: multi-character separator '{}'", val);
                            process::exit(1);
                        };
                        if cli.separator_set && cli.config.separator != new_sep {
                            eprintln!("split: multiple separator characters specified");
                            process::exit(1);
                        }
                        cli.config.separator = new_sep;
                        cli.separator_set = true;
                        break;
                    }
                    'd' => {
                        cli.config.suffix_type = SuffixType::Numeric(0);
                    }
                    'x' => {
                        cli.config.suffix_type = SuffixType::Hex(0);
                    }
                    'e' => {
                        cli.config.elide_empty = true;
                    }
                    _ => {
                        eprintln!("split: invalid option -- '{}'", chars[i]);
                        eprintln!("Try 'split --help' for more information.");
                        process::exit(1);
                    }
                }
                i += 1;
            }
        } else {
            // Positional argument
            let s = arg.to_string_lossy().into_owned();
            match positional_count {
                0 => cli.input = s,
                1 => cli.config.prefix = s,
                _ => {
                    eprintln!("split: extra operand '{}'", s);
                    eprintln!("Try 'split --help' for more information.");
                    process::exit(1);
                }
            }
            positional_count += 1;
        }
    }

    cli
}

fn print_help() {
    print!(
        "Usage: split [OPTION]... [FILE [PREFIX]]\n\
         Output pieces of FILE to PREFIXaa, PREFIXab, ...;\n\
         default size is 1000 lines, and default PREFIX is 'x'.\n\n\
         With no FILE, or when FILE is -, read standard input.\n\n\
         \x20 -a, --suffix-length=N   generate suffixes of length N (default 2)\n\
         \x20 --additional-suffix=SUFF  append an additional SUFFIX to file names\n\
         \x20 -b, --bytes=SIZE        put SIZE bytes per output file\n\
         \x20 -C, --line-bytes=SIZE   put at most SIZE bytes of records per output file\n\
         \x20 -d                      use numeric suffixes starting at 0\n\
         \x20 --numeric-suffixes[=FROM]  same as -d, but allow setting the start value\n\
         \x20 -x                      use hex suffixes starting at 0\n\
         \x20 --hex-suffixes[=FROM]   same as -x, but allow setting the start value\n\
         \x20 -e, --elide-empty-files  do not generate empty output files with '-n'\n\
         \x20 --filter=COMMAND        write to shell COMMAND; file name is $FILE\n\
         \x20 -l, --lines=NUMBER      put NUMBER lines/records per output file\n\
         \x20 -n, --number=CHUNKS     generate CHUNKS output files\n\
         \x20 -t, --separator=SEP     use SEP instead of newline as the record separator\n\
         \x20 --verbose               print a diagnostic just before each output file is opened\n\
         \x20 --help                  display this help and exit\n\
         \x20 --version               output version information and exit\n\n\
         The SIZE argument is an integer and optional unit (example: 10K is 10*1024).\n\
         Units are K, M, G, T, P, E (powers of 1024) or KB, MB, ... (powers of 1000).\n"
    );
}

fn main() {
    reset_sigpipe();

    let cli = parse_args();

    // Validate zero values (GNU split rejects them)
    match &cli.config.mode {
        SplitMode::Lines(0) => {
            eprintln!("split: invalid number of lines: '0'");
            process::exit(1);
        }
        SplitMode::Bytes(0) => {
            eprintln!("split: invalid number of bytes: '0'");
            process::exit(1);
        }
        SplitMode::LineBytes(0) => {
            eprintln!("split: invalid number of bytes: '0'");
            process::exit(1);
        }
        SplitMode::Number(0) | SplitMode::LineChunks(0) | SplitMode::RoundRobin(0) => {
            eprintln!("split: invalid number of chunks: '0'");
            process::exit(1);
        }
        SplitMode::NumberExtract(k, n) => {
            if *n == 0 {
                eprintln!("split: invalid number of chunks: '0'");
                process::exit(1);
            }
            if *k == 0 || *k > *n {
                eprintln!("split: invalid chunk number: '{}/{}'", k, n);
                process::exit(1);
            }
        }
        SplitMode::LineChunkExtract(k, n) => {
            if *n == 0 {
                eprintln!("split: invalid number of chunks: '0'");
                process::exit(1);
            }
            if *k == 0 || *k > *n {
                eprintln!("split: invalid chunk number: '{}/{}'", k, n);
                process::exit(1);
            }
        }
        SplitMode::RoundRobinExtract(k, n) => {
            if *n == 0 {
                eprintln!("split: invalid number of chunks: '0'");
                process::exit(1);
            }
            if *k == 0 || *k > *n {
                eprintln!("split: invalid chunk number: '{}/{}'", k, n);
                process::exit(1);
            }
        }
        _ => {}
    }

    // Guard: detect if an output file would overwrite the input file.
    // GNU split checks if the first output file path resolves to the same inode
    // as the input file and refuses to proceed if so.
    #[cfg(unix)]
    if cli.input != "-" {
        use std::os::unix::fs::MetadataExt;
        let first_output = format!(
            "{}{}{}",
            cli.config.prefix,
            split::generate_suffix(0, &cli.config.suffix_type, cli.config.suffix_length),
            cli.config.additional_suffix
        );
        if let Ok(input_meta) = std::fs::metadata(&cli.input) {
            if let Ok(output_meta) = std::fs::metadata(&first_output) {
                if input_meta.dev() == output_meta.dev() && input_meta.ino() == output_meta.ino() {
                    eprintln!("split: '{}' would overwrite input; aborting", first_output);
                    process::exit(1);
                }
            }
        }
    }

    if let Err(e) = split::split_file(&cli.input, &cli.config) {
        eprintln!("split: {}", e);
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
        path.push("fsplit");
        Command::new(path)
    }
    #[test]
    fn test_split_by_lines() {
        let dir = tempfile::tempdir().unwrap();
        let input = dir.path().join("input.txt");
        std::fs::write(&input, "1\n2\n3\n4\n5\n6\n").unwrap();
        let output = cmd()
            .args(["-l", "2", input.to_str().unwrap()])
            .current_dir(dir.path())
            .output()
            .unwrap();
        assert!(output.status.success());
        // Should create xaa, xab, xac
        assert!(dir.path().join("xaa").exists());
        assert!(dir.path().join("xab").exists());
        assert!(dir.path().join("xac").exists());
        assert_eq!(
            std::fs::read_to_string(dir.path().join("xaa")).unwrap(),
            "1\n2\n"
        );
        assert_eq!(
            std::fs::read_to_string(dir.path().join("xab")).unwrap(),
            "3\n4\n"
        );
        assert_eq!(
            std::fs::read_to_string(dir.path().join("xac")).unwrap(),
            "5\n6\n"
        );
    }

    #[test]
    fn test_split_by_bytes() {
        let dir = tempfile::tempdir().unwrap();
        let input = dir.path().join("input.txt");
        std::fs::write(&input, "abcdef").unwrap();
        let output = cmd()
            .args(["-b", "2", input.to_str().unwrap()])
            .current_dir(dir.path())
            .output()
            .unwrap();
        assert!(output.status.success());
        assert_eq!(
            std::fs::read_to_string(dir.path().join("xaa")).unwrap(),
            "ab"
        );
        assert_eq!(
            std::fs::read_to_string(dir.path().join("xab")).unwrap(),
            "cd"
        );
        assert_eq!(
            std::fs::read_to_string(dir.path().join("xac")).unwrap(),
            "ef"
        );
    }

    #[test]
    fn test_split_custom_prefix() {
        let dir = tempfile::tempdir().unwrap();
        let input = dir.path().join("input.txt");
        std::fs::write(&input, "1\n2\n3\n4\n").unwrap();
        let prefix = dir.path().join("out_");
        let output = cmd()
            .args(["-l", "2", input.to_str().unwrap(), prefix.to_str().unwrap()])
            .output()
            .unwrap();
        assert!(output.status.success());
        assert!(dir.path().join("out_aa").exists());
        assert!(dir.path().join("out_ab").exists());
    }

    #[test]
    fn test_split_numeric_suffixes() {
        let dir = tempfile::tempdir().unwrap();
        let input = dir.path().join("input.txt");
        std::fs::write(&input, "1\n2\n3\n4\n").unwrap();
        let output = cmd()
            .args(["-l", "2", "-d", input.to_str().unwrap()])
            .current_dir(dir.path())
            .output()
            .unwrap();
        assert!(output.status.success());
        assert!(dir.path().join("x00").exists());
        assert!(dir.path().join("x01").exists());
    }

    #[test]
    fn test_split_empty_file() {
        let dir = tempfile::tempdir().unwrap();
        let input = dir.path().join("empty.txt");
        std::fs::write(&input, "").unwrap();
        let output = cmd()
            .arg(input.to_str().unwrap())
            .current_dir(dir.path())
            .output()
            .unwrap();
        assert!(output.status.success());
    }

    #[test]
    fn test_split_single_line_file() {
        let dir = tempfile::tempdir().unwrap();
        let input = dir.path().join("single.txt");
        std::fs::write(&input, "hello\n").unwrap();
        let output = cmd()
            .args(["-l", "1", input.to_str().unwrap()])
            .current_dir(dir.path())
            .output()
            .unwrap();
        assert!(output.status.success());
        assert_eq!(
            std::fs::read_to_string(dir.path().join("xaa")).unwrap(),
            "hello\n"
        );
    }

    #[test]
    fn test_split_stdin() {
        use std::io::Write;
        use std::process::Stdio;
        let dir = tempfile::tempdir().unwrap();
        let mut child = cmd()
            .args(["-l", "1", "-"])
            .current_dir(dir.path())
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .spawn()
            .unwrap();
        child.stdin.take().unwrap().write_all(b"a\nb\nc\n").unwrap();
        let output = child.wait_with_output().unwrap();
        assert!(output.status.success());
        assert!(dir.path().join("xaa").exists());
    }

    #[test]
    fn test_split_nonexistent() {
        let output = cmd().arg("/nonexistent_xyz_split").output().unwrap();
        assert!(!output.status.success());
    }

    #[test]
    fn test_split_verbose() {
        let dir = tempfile::tempdir().unwrap();
        let input = dir.path().join("input.txt");
        std::fs::write(&input, "1\n2\n").unwrap();
        let output = cmd()
            .args(["--verbose", "-l", "1", input.to_str().unwrap()])
            .current_dir(dir.path())
            .output()
            .unwrap();
        assert!(output.status.success());
        let stderr = String::from_utf8_lossy(&output.stderr);
        assert!(stderr.contains("creating"));
    }

    #[test]
    fn test_split_line_chunks_l3() {
        // GNU: split -n l/3 on 5-line file distributes lines by byte boundaries
        let dir = tempfile::tempdir().unwrap();
        let input = dir.path().join("input.txt");
        std::fs::write(&input, "1\n2\n3\n4\n5\n").unwrap();
        let output = cmd()
            .args(["-n", "l/3", input.to_str().unwrap()])
            .current_dir(dir.path())
            .output()
            .unwrap();
        assert!(
            output.status.success(),
            "stderr: {}",
            String::from_utf8_lossy(&output.stderr)
        );
        assert_eq!(
            std::fs::read_to_string(dir.path().join("xaa")).unwrap(),
            "1\n2\n"
        );
        assert_eq!(
            std::fs::read_to_string(dir.path().join("xab")).unwrap(),
            "3\n4\n"
        );
        assert_eq!(
            std::fs::read_to_string(dir.path().join("xac")).unwrap(),
            "5\n"
        );
    }

    #[test]
    fn test_split_line_chunk_extract_no_trailing_newline() {
        // GNU: split -n l/7/7 on file without trailing newline
        let dir = tempfile::tempdir().unwrap();
        let input = dir.path().join("input.txt");
        std::fs::write(&input, "12\n34\n5").unwrap();
        let output = cmd()
            .args(["-n", "l/7/7", input.to_str().unwrap()])
            .current_dir(dir.path())
            .output()
            .unwrap();
        assert!(output.status.success());
        assert_eq!(
            String::from_utf8_lossy(&output.stdout),
            "5",
            "l/7/7 should extract the last chunk containing '5'"
        );
    }

    #[test]
    fn test_split_line_bytes_long_line() {
        // GNU: -C 3 splits long lines at byte boundaries
        let dir = tempfile::tempdir().unwrap();
        let input = dir.path().join("input.txt");
        std::fs::write(&input, "1\n2222\n3\n4").unwrap();
        let output = cmd()
            .args(["-C", "3", input.to_str().unwrap()])
            .current_dir(dir.path())
            .output()
            .unwrap();
        assert!(output.status.success());
        assert_eq!(
            std::fs::read_to_string(dir.path().join("xaa")).unwrap(),
            "1\n"
        );
        assert_eq!(
            std::fs::read_to_string(dir.path().join("xab")).unwrap(),
            "222"
        );
        assert_eq!(
            std::fs::read_to_string(dir.path().join("xac")).unwrap(),
            "2\n"
        );
        assert_eq!(
            std::fs::read_to_string(dir.path().join("xad")).unwrap(),
            "3\n"
        );
        assert_eq!(
            std::fs::read_to_string(dir.path().join("xae")).unwrap(),
            "4"
        );
    }

    #[test]
    fn test_split_line_bytes_c1() {
        // GNU: -C 1 splits every byte into its own file
        use std::io::Write;
        use std::process::Stdio;
        let dir = tempfile::tempdir().unwrap();
        let mut child = cmd()
            .args(["-C", "1"])
            .current_dir(dir.path())
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .spawn()
            .unwrap();
        child.stdin.take().unwrap().write_all(b"x\n").unwrap();
        let output = child.wait_with_output().unwrap();
        assert!(output.status.success());
        assert_eq!(
            std::fs::read_to_string(dir.path().join("xaa")).unwrap(),
            "x"
        );
        assert_eq!(
            std::fs::read_to_string(dir.path().join("xab")).unwrap(),
            "\n"
        );
    }

    #[test]
    fn test_split_reject_different_separators() {
        // GNU: -ta -tb should fail with "multiple separator characters specified"
        let output = cmd().args(["-ta", "-tb"]).output().unwrap();
        assert!(!output.status.success());
        let stderr = String::from_utf8_lossy(&output.stderr);
        assert!(stderr.contains("multiple separator characters specified"));
    }

    #[test]
    fn test_split_same_separator_ok() {
        // GNU: -t: -t: (same separator) should succeed
        use std::process::Stdio;
        let mut child = cmd()
            .args(["-t:", "-t:"])
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .spawn()
            .unwrap();
        drop(child.stdin.take().unwrap());
        let output = child.wait_with_output().unwrap();
        assert!(output.status.success());
    }

    #[test]
    fn test_split_guard_input_overwrite() {
        // GNU: split should refuse to overwrite input file
        let dir = tempfile::tempdir().unwrap();
        let input = dir.path().join("xaa");
        std::fs::write(&input, "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n").unwrap();
        let output = cmd()
            .args(["-C", "6", "xaa"])
            .current_dir(dir.path())
            .output()
            .unwrap();
        assert!(
            !output.status.success(),
            "split should fail when output would overwrite input"
        );
    }
}
