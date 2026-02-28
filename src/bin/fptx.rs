use std::io::{self, BufRead, BufReader, BufWriter, Write};
use std::process;

use coreutils_rs::ptx::{self, OutputFormat, PtxConfig};

struct Cli {
    config: PtxConfig,
    files: Vec<String>,
}

/// Helper: consume the rest of a short-option cluster or the next arg as the option value.
fn take_short_opt_value(
    chars: &mut std::str::Chars<'_>,
    args: &mut impl Iterator<Item = std::ffi::OsString>,
    opt_char: char,
) -> String {
    let rest: String = chars.collect();
    if rest.is_empty() {
        let val = args.next().unwrap_or_else(|| {
            eprintln!("ptx: option requires an argument -- '{}'", opt_char);
            process::exit(1);
        });
        val.to_string_lossy().into_owned()
    } else {
        rest
    }
}

fn parse_args() -> Cli {
    let mut cli = Cli {
        config: PtxConfig::default(),
        files: Vec::new(),
    };

    let mut args = std::env::args_os().skip(1);

    #[allow(clippy::while_let_on_iterator)]
    while let Some(arg) = args.next() {
        let bytes = arg.as_encoded_bytes();
        if bytes == b"--" {
            for a in args {
                cli.files.push(a.to_string_lossy().into_owned());
            }
            break;
        }
        if bytes.starts_with(b"--") {
            let s = arg.to_string_lossy();
            if let Some(val) = s.strip_prefix("--width=") {
                cli.config.width = val.parse().unwrap_or_else(|_| {
                    eprintln!("ptx: invalid width: '{}'", val);
                    process::exit(1);
                });
            } else if let Some(val) = s.strip_prefix("--gap-size=") {
                cli.config.gap_size = val.parse().unwrap_or_else(|_| {
                    eprintln!("ptx: invalid gap size: '{}'", val);
                    process::exit(1);
                });
            } else if let Some(val) = s.strip_prefix("--ignore-file=") {
                match ptx::read_word_file(val) {
                    Ok(words) => cli.config.ignore_words = words,
                    Err(e) => {
                        eprintln!("ptx: {}: {}", val, e);
                        process::exit(1);
                    }
                }
            } else if let Some(val) = s.strip_prefix("--only-file=") {
                match ptx::read_word_file(val) {
                    Ok(words) => cli.config.only_words = Some(words),
                    Err(e) => {
                        eprintln!("ptx: {}: {}", val, e);
                        process::exit(1);
                    }
                }
            } else if let Some(val) = s.strip_prefix("--break-file=") {
                cli.config.word_regexp = Some(val.to_string());
            } else if let Some(val) = s.strip_prefix("--flag-truncation=") {
                cli.config.flag_truncation = Some(val.to_string());
            } else if let Some(val) = s.strip_prefix("--macro-name=") {
                cli.config.macro_name = Some(val.to_string());
            } else if let Some(val) = s.strip_prefix("--sentence-regexp=") {
                cli.config.sentence_regexp = Some(val.to_string());
            } else if let Some(val) = s.strip_prefix("--word-regexp=") {
                cli.config.word_regexp = Some(val.to_string());
            } else {
                match bytes {
                    b"--ignore-case" => cli.config.ignore_case = true,
                    b"--auto-reference" => cli.config.auto_reference = true,
                    b"--traditional" => cli.config.traditional = true,
                    b"--references" => cli.config.references = true,
                    b"--right-side-refs" => cli.config.right_reference = true,
                    b"--format=roff" => cli.config.format = OutputFormat::Roff,
                    b"--format=tex" => cli.config.format = OutputFormat::Tex,
                    b"--width" => {
                        let val = args.next().unwrap_or_else(|| {
                            eprintln!("ptx: option '--width' requires an argument");
                            process::exit(1);
                        });
                        cli.config.width = val.to_string_lossy().parse().unwrap_or_else(|_| {
                            eprintln!("ptx: invalid width: '{}'", val.to_string_lossy());
                            process::exit(1);
                        });
                    }
                    b"--gap-size" => {
                        let val = args.next().unwrap_or_else(|| {
                            eprintln!("ptx: option '--gap-size' requires an argument");
                            process::exit(1);
                        });
                        cli.config.gap_size = val.to_string_lossy().parse().unwrap_or_else(|_| {
                            eprintln!("ptx: invalid gap size: '{}'", val.to_string_lossy());
                            process::exit(1);
                        });
                    }
                    b"--ignore-file" => {
                        let val = args.next().unwrap_or_else(|| {
                            eprintln!("ptx: option '--ignore-file' requires an argument");
                            process::exit(1);
                        });
                        let path = val.to_string_lossy();
                        match ptx::read_word_file(&path) {
                            Ok(words) => cli.config.ignore_words = words,
                            Err(e) => {
                                eprintln!("ptx: {}: {}", path, e);
                                process::exit(1);
                            }
                        }
                    }
                    b"--only-file" => {
                        let val = args.next().unwrap_or_else(|| {
                            eprintln!("ptx: option '--only-file' requires an argument");
                            process::exit(1);
                        });
                        let path = val.to_string_lossy();
                        match ptx::read_word_file(&path) {
                            Ok(words) => cli.config.only_words = Some(words),
                            Err(e) => {
                                eprintln!("ptx: {}: {}", path, e);
                                process::exit(1);
                            }
                        }
                    }
                    b"--flag-truncation" => {
                        let val = args.next().unwrap_or_else(|| {
                            eprintln!("ptx: option '--flag-truncation' requires an argument");
                            process::exit(1);
                        });
                        cli.config.flag_truncation = Some(val.to_string_lossy().into_owned());
                    }
                    b"--macro-name" => {
                        let val = args.next().unwrap_or_else(|| {
                            eprintln!("ptx: option '--macro-name' requires an argument");
                            process::exit(1);
                        });
                        cli.config.macro_name = Some(val.to_string_lossy().into_owned());
                    }
                    b"--sentence-regexp" => {
                        let val = args.next().unwrap_or_else(|| {
                            eprintln!("ptx: option '--sentence-regexp' requires an argument");
                            process::exit(1);
                        });
                        cli.config.sentence_regexp = Some(val.to_string_lossy().into_owned());
                    }
                    b"--word-regexp" => {
                        let val = args.next().unwrap_or_else(|| {
                            eprintln!("ptx: option '--word-regexp' requires an argument");
                            process::exit(1);
                        });
                        cli.config.word_regexp = Some(val.to_string_lossy().into_owned());
                    }
                    b"--help" => {
                        print_help();
                        process::exit(0);
                    }
                    b"--version" => {
                        println!("ptx (fcoreutils) {}", env!("CARGO_PKG_VERSION"));
                        process::exit(0);
                    }
                    _ => {
                        eprintln!("ptx: unrecognized option '{}'", s);
                        eprintln!("Try 'ptx --help' for more information.");
                        process::exit(1);
                    }
                }
            }
        } else if bytes.len() > 1 && bytes[0] == b'-' {
            // Short options
            let s = arg.to_string_lossy();
            let mut chars = s[1..].chars();
            while let Some(ch) = chars.next() {
                match ch {
                    'f' => cli.config.ignore_case = true,
                    'A' => cli.config.auto_reference = true,
                    'G' => cli.config.traditional = true,
                    'r' => cli.config.references = true,
                    'R' => cli.config.right_reference = true,
                    'T' => cli.config.format = OutputFormat::Tex,
                    'O' => cli.config.format = OutputFormat::Roff,
                    'w' => {
                        let val_str = take_short_opt_value(&mut chars, &mut args, 'w');
                        cli.config.width = val_str.parse().unwrap_or_else(|_| {
                            eprintln!("ptx: invalid width: '{}'", val_str);
                            process::exit(1);
                        });
                        break;
                    }
                    'g' => {
                        let val_str = take_short_opt_value(&mut chars, &mut args, 'g');
                        cli.config.gap_size = val_str.parse().unwrap_or_else(|_| {
                            eprintln!("ptx: invalid gap size: '{}'", val_str);
                            process::exit(1);
                        });
                        break;
                    }
                    'b' => {
                        let val_str = take_short_opt_value(&mut chars, &mut args, 'b');
                        cli.config.word_regexp = Some(val_str);
                        break;
                    }
                    'F' => {
                        let val_str = take_short_opt_value(&mut chars, &mut args, 'F');
                        cli.config.flag_truncation = Some(val_str);
                        break;
                    }
                    'M' => {
                        let val_str = take_short_opt_value(&mut chars, &mut args, 'M');
                        cli.config.macro_name = Some(val_str);
                        break;
                    }
                    'S' => {
                        let val_str = take_short_opt_value(&mut chars, &mut args, 'S');
                        cli.config.sentence_regexp = Some(val_str);
                        break;
                    }
                    'W' => {
                        let val_str = take_short_opt_value(&mut chars, &mut args, 'W');
                        cli.config.word_regexp = Some(val_str);
                        break;
                    }
                    'i' => {
                        let val_str = take_short_opt_value(&mut chars, &mut args, 'i');
                        match ptx::read_word_file(&val_str) {
                            Ok(words) => cli.config.ignore_words = words,
                            Err(e) => {
                                eprintln!("ptx: {}: {}", val_str, e);
                                process::exit(1);
                            }
                        }
                        break;
                    }
                    'o' => {
                        let val_str = take_short_opt_value(&mut chars, &mut args, 'o');
                        match ptx::read_word_file(&val_str) {
                            Ok(words) => cli.config.only_words = Some(words),
                            Err(e) => {
                                eprintln!("ptx: {}: {}", val_str, e);
                                process::exit(1);
                            }
                        }
                        break;
                    }
                    't' => {} // silently ignore (unimplemented typeset mode, like GNU)
                    _ => {
                        eprintln!("ptx: invalid option -- '{}'", ch);
                        eprintln!("Try 'ptx --help' for more information.");
                        process::exit(1);
                    }
                }
            }
        } else {
            cli.files.push(arg.to_string_lossy().into_owned());
        }
    }

    cli
}

fn print_help() {
    print!(
        "Usage: ptx [OPTION]... [INPUT]...\n\
         Output a permuted index, including context, of the words in the input files.\n\n\
         With no FILE, or when FILE is -, read standard input.\n\n\
         \x20 -A, --auto-reference           output automatically generated references\n\
         \x20 -G, --traditional              behave more like System V 'ptx'\n\
         \x20 -F, --flag-truncation=STRING   use STRING for flagging line truncations.\n\
         \x20                                The default is '/'\n\
         \x20 -M, --macro-name=STRING        macro name to use instead of 'xx'\n\
         \x20 -O, --format=roff              generate output as roff directives\n\
         \x20 -R, --right-side-refs          put references at right, not counted in -w\n\
         \x20 -S, --sentence-regexp=REGEXP   for end of lines or end of sentences\n\
         \x20 -T, --format=tex               generate output as TeX directives\n\
         \x20 -W, --word-regexp=REGEXP       use REGEXP to match each keyword\n\
         \x20 -b, --break-file=FILE          word break characters in this FILE\n\
         \x20 -f, --ignore-case              fold lower case to upper case for sorting\n\
         \x20 -g, --gap-size=NUMBER          gap size in columns between output fields\n\
         \x20 -i, --ignore-file=FILE         read ignore word list from FILE\n\
         \x20 -o, --only-file=FILE           read only word list from this FILE\n\
         \x20 -r, --references               first field of each line is a reference\n\
         \x20 -t, --typeset-mode               - not implemented -\n\
         \x20 -w, --width=NUMBER             output width in columns, reference excluded\n\
         \x20     --help                     display this help and exit\n\
         \x20     --version                  output version information and exit\n"
    );
}

fn main() {
    coreutils_rs::common::reset_sigpipe();

    let cli = parse_args();

    let stdout = io::stdout();
    let mut out = BufWriter::with_capacity(64 * 1024, stdout.lock());

    if cli.files.is_empty() || (cli.files.len() == 1 && cli.files[0] == "-") {
        // Read from stdin
        let stdin = io::stdin();
        let reader = BufReader::new(stdin.lock());
        if let Err(e) = ptx::generate_ptx(reader, &mut out, &cli.config) {
            if e.kind() == io::ErrorKind::BrokenPipe {
                process::exit(0);
            }
            eprintln!("ptx: {}", e);
            process::exit(1);
        }
    } else {
        // Read each file separately, preserving file boundaries.
        // GNU ptx processes each file's lines independently for sentence grouping.
        let mut file_contents: Vec<(Option<String>, String)> = Vec::new();
        let mut had_error = false;

        for file in &cli.files {
            if file == "-" {
                let stdin = io::stdin();
                let mut content = String::new();
                for line in stdin.lock().lines() {
                    match line {
                        Ok(l) => {
                            content.push_str(&l);
                            content.push('\n');
                        }
                        Err(e) => {
                            eprintln!("ptx: standard input: {}", e);
                            had_error = true;
                            break;
                        }
                    }
                }
                file_contents.push((None, content));
            } else {
                match std::fs::read_to_string(file) {
                    Ok(content) => {
                        file_contents.push((Some(file.clone()), content));
                    }
                    Err(e) => {
                        eprintln!("ptx: {}: {}", file, e);
                        had_error = true;
                    }
                }
            }
        }

        if had_error && file_contents.is_empty() {
            process::exit(1);
        }

        if let Err(e) = ptx::generate_ptx_multi(&file_contents, &mut out, &cli.config) {
            if e.kind() == io::ErrorKind::BrokenPipe {
                process::exit(0);
            }
            eprintln!("ptx: {}", e);
            process::exit(1);
        }

        if had_error {
            process::exit(1);
        }
    }

    if let Err(e) = out.flush() {
        #[allow(clippy::collapsible_if)]
        if e.kind() != io::ErrorKind::BrokenPipe {
            eprintln!("ptx: write error: {}", e);
            process::exit(1);
        }
    }
}

#[cfg(test)]
mod tests {
    use std::io::Write;
    use std::process::Command;
    use std::process::Stdio;

    fn cmd() -> Command {
        let mut path = std::env::current_exe().unwrap();
        path.pop();
        path.pop();
        path.push("fptx");
        Command::new(path)
    }
    #[test]
    fn test_ptx_basic() {
        let mut child = cmd()
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .spawn()
            .unwrap();
        child
            .stdin
            .take()
            .unwrap()
            .write_all(b"apple banana cherry\n")
            .unwrap();
        let output = child.wait_with_output().unwrap();
        assert!(output.status.success());
        let stdout = String::from_utf8_lossy(&output.stdout);
        assert!(stdout.contains("apple"));
        assert!(stdout.contains("banana"));
    }

    #[test]
    fn test_ptx_file() {
        let dir = tempfile::tempdir().unwrap();
        let f = dir.path().join("test.txt");
        std::fs::write(&f, "hello world foo\n").unwrap();
        let output = cmd().arg(f.to_str().unwrap()).output().unwrap();
        assert!(output.status.success());
        let stdout = String::from_utf8_lossy(&output.stdout);
        assert!(stdout.contains("hello"));
    }

    #[test]
    fn test_ptx_empty_input() {
        let mut child = cmd()
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .spawn()
            .unwrap();
        drop(child.stdin.take().unwrap());
        let output = child.wait_with_output().unwrap();
        assert!(output.status.success());
    }

    #[test]
    fn test_ptx_width() {
        let mut child = cmd()
            .args(["-w", "40"])
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .spawn()
            .unwrap();
        child
            .stdin
            .take()
            .unwrap()
            .write_all(b"the quick brown fox\n")
            .unwrap();
        let output = child.wait_with_output().unwrap();
        assert!(output.status.success());
    }

    #[test]
    fn test_ptx_multiple_lines() {
        let mut child = cmd()
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .spawn()
            .unwrap();
        child
            .stdin
            .take()
            .unwrap()
            .write_all(b"line one\nline two\nline three\n")
            .unwrap();
        let output = child.wait_with_output().unwrap();
        assert!(output.status.success());
        let stdout = String::from_utf8_lossy(&output.stdout);
        assert!(stdout.contains("one") && stdout.contains("two") && stdout.contains("three"));
    }

    #[test]
    fn test_ptx_nonexistent() {
        let output = cmd().arg("/nonexistent_xyz_ptx").output().unwrap();
        assert!(!output.status.success());
    }

    #[test]
    fn test_ptx_multiple_files() {
        let dir = tempfile::tempdir().unwrap();
        let f1 = dir.path().join("a.txt");
        let f2 = dir.path().join("b.txt");
        std::fs::write(&f1, "hello world\n").unwrap();
        std::fs::write(&f2, "foo bar\n").unwrap();
        let output = cmd()
            .args([f1.to_str().unwrap(), f2.to_str().unwrap()])
            .output()
            .unwrap();
        assert!(output.status.success());
    }
}
