use std::process;

use coreutils_rs::csplit::{self, CsplitConfig, Pattern};

struct Cli {
    config: CsplitConfig,
    file: String,
    patterns: Vec<String>,
}

fn parse_args() -> Cli {
    let mut cli = Cli {
        config: CsplitConfig::default(),
        file: String::new(),
        patterns: Vec::new(),
    };

    let mut args = std::env::args_os().skip(1);
    let mut positional = Vec::new();

    #[allow(clippy::while_let_on_iterator)]
    while let Some(arg) = args.next() {
        let bytes = arg.as_encoded_bytes();
        if bytes == b"--" {
            for a in args {
                positional.push(a.to_string_lossy().into_owned());
            }
            break;
        }
        if bytes.starts_with(b"--") {
            let s = arg.to_string_lossy();
            if let Some(val) = s.strip_prefix("--prefix=") {
                cli.config.prefix = val.to_string();
            } else if let Some(val) = s.strip_prefix("--suffix-format=") {
                cli.config.suffix_format = val.to_string();
            } else if let Some(val) = s.strip_prefix("--digits=") {
                cli.config.digits = val.parse().unwrap_or_else(|_| {
                    eprintln!("csplit: invalid number of digits: '{}'", val);
                    process::exit(1);
                });
            } else {
                match bytes {
                    b"--keep-files" => cli.config.keep_files = true,
                    b"--quiet" | b"--silent" => cli.config.quiet = true,
                    b"--elide-empty-files" => cli.config.elide_empty = true,
                    b"--prefix" => {
                        let val = args.next().unwrap_or_else(|| {
                            eprintln!("csplit: option '--prefix' requires an argument");
                            process::exit(1);
                        });
                        cli.config.prefix = val.to_string_lossy().into_owned();
                    }
                    b"--suffix-format" => {
                        let val = args.next().unwrap_or_else(|| {
                            eprintln!("csplit: option '--suffix-format' requires an argument");
                            process::exit(1);
                        });
                        cli.config.suffix_format = val.to_string_lossy().into_owned();
                    }
                    b"--digits" => {
                        let val = args.next().unwrap_or_else(|| {
                            eprintln!("csplit: option '--digits' requires an argument");
                            process::exit(1);
                        });
                        cli.config.digits = val.to_string_lossy().parse().unwrap_or_else(|_| {
                            eprintln!(
                                "csplit: invalid number of digits: '{}'",
                                val.to_string_lossy()
                            );
                            process::exit(1);
                        });
                    }
                    b"--help" => {
                        print_help();
                        process::exit(0);
                    }
                    b"--version" => {
                        println!("csplit (fcoreutils) {}", env!("CARGO_PKG_VERSION"));
                        process::exit(0);
                    }
                    _ => {
                        eprintln!("csplit: unrecognized option '{}'", s);
                        eprintln!("Try 'csplit --help' for more information.");
                        process::exit(1);
                    }
                }
            }
        } else if bytes.len() > 1
            && bytes[0] == b'-'
            && bytes[1] != b'0'
            && !bytes[1..].iter().all(|b| b.is_ascii_digit())
        {
            // Short options
            let s = arg.to_string_lossy();
            let mut chars = s[1..].chars();
            while let Some(ch) = chars.next() {
                match ch {
                    'f' => {
                        let rest: String = chars.collect();
                        if rest.is_empty() {
                            let val = args.next().unwrap_or_else(|| {
                                eprintln!("csplit: option requires an argument -- 'f'");
                                process::exit(1);
                            });
                            cli.config.prefix = val.to_string_lossy().into_owned();
                        } else {
                            cli.config.prefix = rest;
                        }
                        break;
                    }
                    'b' => {
                        let rest: String = chars.collect();
                        if rest.is_empty() {
                            let val = args.next().unwrap_or_else(|| {
                                eprintln!("csplit: option requires an argument -- 'b'");
                                process::exit(1);
                            });
                            cli.config.suffix_format = val.to_string_lossy().into_owned();
                        } else {
                            cli.config.suffix_format = rest;
                        }
                        break;
                    }
                    'n' => {
                        let rest: String = chars.collect();
                        let val_str = if rest.is_empty() {
                            let val = args.next().unwrap_or_else(|| {
                                eprintln!("csplit: option requires an argument -- 'n'");
                                process::exit(1);
                            });
                            val.to_string_lossy().into_owned()
                        } else {
                            rest
                        };
                        cli.config.digits = val_str.parse().unwrap_or_else(|_| {
                            eprintln!("csplit: invalid number of digits: '{}'", val_str);
                            process::exit(1);
                        });
                        break;
                    }
                    'k' => cli.config.keep_files = true,
                    's' => cli.config.quiet = true,
                    'z' => cli.config.elide_empty = true,
                    _ => {
                        eprintln!("csplit: invalid option -- '{}'", ch);
                        eprintln!("Try 'csplit --help' for more information.");
                        process::exit(1);
                    }
                }
            }
        } else {
            positional.push(arg.to_string_lossy().into_owned());
        }
    }

    if positional.is_empty() {
        eprintln!("csplit: missing operand");
        eprintln!("Try 'csplit --help' for more information.");
        process::exit(1);
    }

    cli.file = positional.remove(0);

    if positional.is_empty() {
        eprintln!("csplit: missing operand after '{}'", cli.file);
        eprintln!("Try 'csplit --help' for more information.");
        process::exit(1);
    }

    cli.patterns = positional;
    cli
}

fn print_help() {
    print!(
        "Usage: csplit [OPTION]... FILE PATTERN...\n\
         Output pieces of FILE separated by PATTERN(s) to files 'xx00', 'xx01', ...,\n\
         and output byte counts of each piece to standard output.\n\n\
         Read standard input if FILE is -\n\n\
         \x20 -b, --suffix-format=FORMAT  use sprintf FORMAT instead of %02d\n\
         \x20 -f, --prefix=PREFIX         use PREFIX instead of 'xx'\n\
         \x20 -k, --keep-files            do not remove output files on errors\n\
         \x20 -n, --digits=DIGITS         use specified number of digits instead of 2\n\
         \x20 -s, --quiet, --silent       do not print counts of output file sizes\n\
         \x20 -z, --elide-empty-files     remove empty output files\n\
         \x20     --help                  display this help and exit\n\
         \x20     --version               output version information and exit\n\n\
         Each PATTERN may be:\n\
         \x20 INTEGER            copy up to but not including specified line number\n\
         \x20 /REGEXP/[OFFSET]   copy up to but not including a matching line\n\
         \x20 %REGEXP%[OFFSET]   skip to, but not including a matching line\n\
         \x20 {{INTEGER}}          repeat the previous pattern a specified number of times\n\
         \x20 {{*}}               repeat the previous pattern as many times as possible\n"
    );
}

fn main() {
    coreutils_rs::common::reset_sigpipe();

    let cli = parse_args();

    // Parse pattern strings
    let mut patterns: Vec<Pattern> = Vec::new();
    for pat_str in &cli.patterns {
        match csplit::parse_pattern(pat_str) {
            Ok(p) => patterns.push(p),
            Err(e) => {
                eprintln!("csplit: {}", e);
                process::exit(1);
            }
        }
    }

    match csplit::csplit_from_path(&cli.file, &patterns, &cli.config) {
        Ok(sizes) => {
            if !cli.config.quiet {
                csplit::print_sizes(&sizes);
            }
        }
        Err(e) => {
            eprintln!("csplit: {}", e);
            process::exit(1);
        }
    }
}

#[cfg(test)]
mod tests {
    use std::process::Command;

    fn cmd() -> Command {
        let mut path = std::env::current_exe().unwrap();
        path.pop();
        path.pop();
        path.push("fcsplit");
        Command::new(path)
    }
    #[test]
    fn test_csplit_basic() {
        let dir = tempfile::tempdir().unwrap();
        let input = dir.path().join("input.txt");
        std::fs::write(&input, "line1\nline2\nline3\nline4\n").unwrap();
        let output = cmd()
            .args([input.to_str().unwrap(), "3"])
            .current_dir(dir.path())
            .output()
            .unwrap();
        assert!(
            output.status.success(),
            "stderr: {}",
            String::from_utf8_lossy(&output.stderr)
        );
    }

    #[test]
    fn test_csplit_by_pattern() {
        let dir = tempfile::tempdir().unwrap();
        let input = dir.path().join("input.txt");
        std::fs::write(&input, "aaa\nbbb\n---\nccc\nddd\n").unwrap();
        let output = cmd()
            .args([input.to_str().unwrap(), "/---/"])
            .current_dir(dir.path())
            .output()
            .unwrap();
        assert!(
            output.status.success(),
            "stderr: {}",
            String::from_utf8_lossy(&output.stderr)
        );
        // Should create xx00 and xx01
        assert!(dir.path().join("xx00").exists());
        assert!(dir.path().join("xx01").exists());
    }

    #[test]
    fn test_csplit_multiple_splits() {
        let dir = tempfile::tempdir().unwrap();
        let input = dir.path().join("input.txt");
        std::fs::write(&input, "a\nb\nc\nd\ne\nf\n").unwrap();
        let output = cmd()
            .args([input.to_str().unwrap(), "3", "5"])
            .current_dir(dir.path())
            .output()
            .unwrap();
        assert!(
            output.status.success(),
            "stderr: {}",
            String::from_utf8_lossy(&output.stderr)
        );
        assert!(dir.path().join("xx00").exists());
        assert!(dir.path().join("xx01").exists());
        assert!(dir.path().join("xx02").exists());
    }

    #[test]
    fn test_csplit_no_args() {
        let output = cmd().output().unwrap();
        assert!(!output.status.success());
    }

    #[test]
    fn test_csplit_nonexistent_file() {
        let dir = tempfile::tempdir().unwrap();
        let output = cmd()
            .args(["/nonexistent/file.txt", "3"])
            .current_dir(dir.path())
            .output()
            .unwrap();
        assert!(!output.status.success());
    }

    #[test]
    fn test_csplit_prefix() {
        let dir = tempfile::tempdir().unwrap();
        let input = dir.path().join("input.txt");
        std::fs::write(&input, "a\nb\nc\nd\n").unwrap();
        let output = cmd()
            .args(["-f", "part", input.to_str().unwrap(), "3"])
            .current_dir(dir.path())
            .output()
            .unwrap();
        assert!(
            output.status.success(),
            "stderr: {}",
            String::from_utf8_lossy(&output.stderr)
        );
        assert!(dir.path().join("part00").exists());
        assert!(dir.path().join("part01").exists());
    }

    #[test]
    fn test_csplit_byte_counts() {
        let dir = tempfile::tempdir().unwrap();
        let input = dir.path().join("input.txt");
        std::fs::write(&input, "line1\nline2\nline3\n").unwrap();
        let output = cmd()
            .args([input.to_str().unwrap(), "2"])
            .current_dir(dir.path())
            .output()
            .unwrap();
        assert!(output.status.success());
        let stdout = String::from_utf8_lossy(&output.stdout);
        // csplit outputs byte counts of each piece
        assert!(!stdout.trim().is_empty());
    }

    #[test]
    fn test_csplit_empty_first_section() {
        let dir = tempfile::tempdir().unwrap();
        let input = dir.path().join("input.txt");
        std::fs::write(&input, "a\nb\nc\n").unwrap();
        let output = cmd()
            .args([input.to_str().unwrap(), "1"])
            .current_dir(dir.path())
            .output()
            .unwrap();
        assert!(output.status.success());
        // First section before line 1 should be empty
        let content = std::fs::read_to_string(dir.path().join("xx00")).unwrap();
        assert!(content.is_empty());
    }
}
