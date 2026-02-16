use std::path::Path;
use std::process;

use coreutils_rs::common::io::{read_file, read_stdin};
use coreutils_rs::common::io_error_msg;
use coreutils_rs::nl::{self, NlConfig};

struct Cli {
    config: NlConfig,
    files: Vec<String>,
}

fn parse_args() -> Cli {
    let mut cli = Cli {
        config: NlConfig::default(),
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
            if let Some(val) = s.strip_prefix("--body-numbering=") {
                match nl::parse_numbering_style(val) {
                    Ok(style) => cli.config.body_style = style,
                    Err(e) => {
                        eprintln!("nl: {}", e);
                        process::exit(1);
                    }
                }
            } else if let Some(val) = s.strip_prefix("--header-numbering=") {
                match nl::parse_numbering_style(val) {
                    Ok(style) => cli.config.header_style = style,
                    Err(e) => {
                        eprintln!("nl: {}", e);
                        process::exit(1);
                    }
                }
            } else if let Some(val) = s.strip_prefix("--footer-numbering=") {
                match nl::parse_numbering_style(val) {
                    Ok(style) => cli.config.footer_style = style,
                    Err(e) => {
                        eprintln!("nl: {}", e);
                        process::exit(1);
                    }
                }
            } else if let Some(val) = s.strip_prefix("--section-delimiter=") {
                cli.config.section_delimiter = val.as_bytes().to_vec();
            } else if let Some(val) = s.strip_prefix("--line-increment=") {
                match val.parse::<i64>() {
                    Ok(n) => cli.config.line_increment = n,
                    Err(_) => {
                        eprintln!("nl: invalid line increment: '{}'", val);
                        process::exit(1);
                    }
                }
            } else if let Some(val) = s.strip_prefix("--join-blank-lines=") {
                match val.parse::<usize>() {
                    Ok(n) if n > 0 => cli.config.join_blank_lines = n,
                    _ => {
                        eprintln!("nl: invalid line number of blank lines: '{}'", val);
                        process::exit(1);
                    }
                }
            } else if let Some(val) = s.strip_prefix("--number-format=") {
                match nl::parse_number_format(val) {
                    Ok(fmt) => cli.config.number_format = fmt,
                    Err(e) => {
                        eprintln!("nl: {}", e);
                        process::exit(1);
                    }
                }
            } else if let Some(val) = s.strip_prefix("--number-separator=") {
                cli.config.number_separator = val.as_bytes().to_vec();
            } else if let Some(val) = s.strip_prefix("--starting-line-number=") {
                match val.parse::<i64>() {
                    Ok(n) => cli.config.starting_line_number = n,
                    Err(_) => {
                        eprintln!("nl: invalid starting line number: '{}'", val);
                        process::exit(1);
                    }
                }
            } else if let Some(val) = s.strip_prefix("--number-width=") {
                match val.parse::<usize>() {
                    Ok(n) if n > 0 => cli.config.number_width = n,
                    _ => {
                        eprintln!("nl: invalid line number field width: '{}'", val);
                        process::exit(1);
                    }
                }
            } else {
                match bytes {
                    b"--body-numbering" => {
                        let val = require_arg(&mut args, "--body-numbering");
                        match nl::parse_numbering_style(&val) {
                            Ok(style) => cli.config.body_style = style,
                            Err(e) => {
                                eprintln!("nl: {}", e);
                                process::exit(1);
                            }
                        }
                    }
                    b"--header-numbering" => {
                        let val = require_arg(&mut args, "--header-numbering");
                        match nl::parse_numbering_style(&val) {
                            Ok(style) => cli.config.header_style = style,
                            Err(e) => {
                                eprintln!("nl: {}", e);
                                process::exit(1);
                            }
                        }
                    }
                    b"--footer-numbering" => {
                        let val = require_arg(&mut args, "--footer-numbering");
                        match nl::parse_numbering_style(&val) {
                            Ok(style) => cli.config.footer_style = style,
                            Err(e) => {
                                eprintln!("nl: {}", e);
                                process::exit(1);
                            }
                        }
                    }
                    b"--section-delimiter" => {
                        let val = require_arg(&mut args, "--section-delimiter");
                        cli.config.section_delimiter = val.into_bytes();
                    }
                    b"--line-increment" => {
                        let val = require_arg(&mut args, "--line-increment");
                        match val.parse::<i64>() {
                            Ok(n) => cli.config.line_increment = n,
                            Err(_) => {
                                eprintln!("nl: invalid line increment: '{}'", val);
                                process::exit(1);
                            }
                        }
                    }
                    b"--join-blank-lines" => {
                        let val = require_arg(&mut args, "--join-blank-lines");
                        match val.parse::<usize>() {
                            Ok(n) if n > 0 => cli.config.join_blank_lines = n,
                            _ => {
                                eprintln!("nl: invalid line number of blank lines: '{}'", val);
                                process::exit(1);
                            }
                        }
                    }
                    b"--number-format" => {
                        let val = require_arg(&mut args, "--number-format");
                        match nl::parse_number_format(&val) {
                            Ok(fmt) => cli.config.number_format = fmt,
                            Err(e) => {
                                eprintln!("nl: {}", e);
                                process::exit(1);
                            }
                        }
                    }
                    b"--no-renumber" => cli.config.no_renumber = true,
                    b"--number-separator" => {
                        let val = require_arg(&mut args, "--number-separator");
                        cli.config.number_separator = val.into_bytes();
                    }
                    b"--starting-line-number" => {
                        let val = require_arg(&mut args, "--starting-line-number");
                        match val.parse::<i64>() {
                            Ok(n) => cli.config.starting_line_number = n,
                            Err(_) => {
                                eprintln!("nl: invalid starting line number: '{}'", val);
                                process::exit(1);
                            }
                        }
                    }
                    b"--number-width" => {
                        let val = require_arg(&mut args, "--number-width");
                        match val.parse::<usize>() {
                            Ok(n) if n > 0 => cli.config.number_width = n,
                            _ => {
                                eprintln!("nl: invalid line number field width: '{}'", val);
                                process::exit(1);
                            }
                        }
                    }
                    b"--help" => {
                        print_help();
                        process::exit(0);
                    }
                    b"--version" => {
                        println!("nl (fcoreutils) {}", env!("CARGO_PKG_VERSION"));
                        process::exit(0);
                    }
                    _ => {
                        eprintln!("nl: unrecognized option '{}'", s);
                        eprintln!("Try 'nl --help' for more information.");
                        process::exit(1);
                    }
                }
            }
        } else if bytes.len() > 1 && bytes[0] == b'-' && bytes != b"-" {
            // Short options
            let s = arg.to_string_lossy();
            let chars: Vec<char> = s[1..].chars().collect();
            let mut i = 0;
            while i < chars.len() {
                match chars[i] {
                    'b' => {
                        let val = short_opt_value(&s, &chars, i, &mut args, 'b');
                        match nl::parse_numbering_style(&val) {
                            Ok(style) => cli.config.body_style = style,
                            Err(e) => {
                                eprintln!("nl: {}", e);
                                process::exit(1);
                            }
                        }
                        break;
                    }
                    'h' => {
                        let val = short_opt_value(&s, &chars, i, &mut args, 'h');
                        match nl::parse_numbering_style(&val) {
                            Ok(style) => cli.config.header_style = style,
                            Err(e) => {
                                eprintln!("nl: {}", e);
                                process::exit(1);
                            }
                        }
                        break;
                    }
                    'f' => {
                        let val = short_opt_value(&s, &chars, i, &mut args, 'f');
                        match nl::parse_numbering_style(&val) {
                            Ok(style) => cli.config.footer_style = style,
                            Err(e) => {
                                eprintln!("nl: {}", e);
                                process::exit(1);
                            }
                        }
                        break;
                    }
                    'd' => {
                        let val = short_opt_value(&s, &chars, i, &mut args, 'd');
                        cli.config.section_delimiter = val.into_bytes();
                        break;
                    }
                    'i' => {
                        let val = short_opt_value(&s, &chars, i, &mut args, 'i');
                        match val.parse::<i64>() {
                            Ok(n) => cli.config.line_increment = n,
                            Err(_) => {
                                eprintln!("nl: invalid line increment: '{}'", val);
                                process::exit(1);
                            }
                        }
                        break;
                    }
                    'l' => {
                        let val = short_opt_value(&s, &chars, i, &mut args, 'l');
                        match val.parse::<usize>() {
                            Ok(n) if n > 0 => cli.config.join_blank_lines = n,
                            _ => {
                                eprintln!("nl: invalid line number of blank lines: '{}'", val);
                                process::exit(1);
                            }
                        }
                        break;
                    }
                    'n' => {
                        let val = short_opt_value(&s, &chars, i, &mut args, 'n');
                        match nl::parse_number_format(&val) {
                            Ok(fmt) => cli.config.number_format = fmt,
                            Err(e) => {
                                eprintln!("nl: {}", e);
                                process::exit(1);
                            }
                        }
                        break;
                    }
                    'p' => cli.config.no_renumber = true,
                    's' => {
                        let val = short_opt_value(&s, &chars, i, &mut args, 's');
                        cli.config.number_separator = val.into_bytes();
                        break;
                    }
                    'v' => {
                        let val = short_opt_value(&s, &chars, i, &mut args, 'v');
                        match val.parse::<i64>() {
                            Ok(n) => cli.config.starting_line_number = n,
                            Err(_) => {
                                eprintln!("nl: invalid starting line number: '{}'", val);
                                process::exit(1);
                            }
                        }
                        break;
                    }
                    'w' => {
                        let val = short_opt_value(&s, &chars, i, &mut args, 'w');
                        match val.parse::<usize>() {
                            Ok(n) if n > 0 => cli.config.number_width = n,
                            _ => {
                                eprintln!("nl: invalid line number field width: '{}'", val);
                                process::exit(1);
                            }
                        }
                        break;
                    }
                    _ => {
                        eprintln!("nl: invalid option -- '{}'", chars[i]);
                        eprintln!("Try 'nl --help' for more information.");
                        process::exit(1);
                    }
                }
                i += 1;
            }
        } else {
            cli.files.push(arg.to_string_lossy().into_owned());
        }
    }

    cli
}

/// Get value for a short option that takes an argument.
fn short_opt_value(
    s: &str,
    chars: &[char],
    i: usize,
    args: &mut impl Iterator<Item = std::ffi::OsString>,
    opt: char,
) -> String {
    if i + 1 < chars.len() {
        s[1 + i + 1..].to_string()
    } else {
        args.next()
            .unwrap_or_else(|| {
                eprintln!("nl: option requires an argument -- '{}'", opt);
                process::exit(1);
            })
            .to_string_lossy()
            .into_owned()
    }
}

/// Require an argument for a long option.
fn require_arg(args: &mut impl Iterator<Item = std::ffi::OsString>, opt: &str) -> String {
    args.next()
        .unwrap_or_else(|| {
            eprintln!("nl: option '{}' requires an argument", opt);
            process::exit(1);
        })
        .to_string_lossy()
        .into_owned()
}

fn print_help() {
    print!(
        "Usage: nl [OPTION]... [FILE]...\n\
         Write each FILE to standard output, with line numbers added.\n\n\
         With no FILE, or when FILE is -, read standard input.\n\n\
         Mandatory arguments to long options are mandatory for short options too.\n\
         \x20 -b, --body-numbering=STYLE      use STYLE for numbering body lines\n\
         \x20 -d, --section-delimiter=CC       use CC for logical page delimiters\n\
         \x20 -f, --footer-numbering=STYLE     use STYLE for numbering footer lines\n\
         \x20 -h, --header-numbering=STYLE     use STYLE for numbering header lines\n\
         \x20 -i, --line-increment=NUMBER      line number increment at each line\n\
         \x20 -l, --join-blank-lines=NUMBER    group of NUMBER empty lines counted as one\n\
         \x20 -n, --number-format=FORMAT       insert line numbers according to FORMAT\n\
         \x20 -p, --no-renumber                do not reset line numbers for each section\n\
         \x20 -s, --number-separator=STRING    add STRING after (possible) line number\n\
         \x20 -v, --starting-line-number=NUMBER  first line number for each section\n\
         \x20 -w, --number-width=NUMBER        use NUMBER columns for line numbers\n\
         \x20     --help                       display this help and exit\n\
         \x20     --version                    output version information and exit\n\n\
         By default, selects -v1 -i1 -l1 -sTAB -w6 -nrn -hn -bt -fn.\n\
         CC are two delimiter characters used to construct logical page delimiters;\n\
         a missing second character implies :.\n\n\
         STYLE is one of:\n\
         \x20 a   number all lines\n\
         \x20 t   number only nonempty lines\n\
         \x20 n   number no lines\n\
         \x20 pBRE  number only lines that contain a match for the basic regular\n\
         \x20       expression, BRE\n\n\
         FORMAT is one of:\n\
         \x20 ln   left justified, no leading zeros\n\
         \x20 rn   right justified, no leading zeros\n\
         \x20 rz   right justified, leading zeros\n"
    );
}

/// Enlarge pipe buffers on Linux for higher throughput.
#[cfg(target_os = "linux")]
fn enlarge_pipes() {
    for &fd in &[0i32, 1] {
        for &size in &[8 * 1024 * 1024i32, 1024 * 1024, 256 * 1024] {
            if unsafe { libc::fcntl(fd, libc::F_SETPIPE_SZ, size) } > 0 {
                break;
            }
        }
    }
}

fn main() {
    coreutils_rs::common::reset_sigpipe();

    #[cfg(target_os = "linux")]
    enlarge_pipes();

    let cli = parse_args();

    let files: Vec<String> = if cli.files.is_empty() {
        vec!["-".to_string()]
    } else {
        cli.files
    };

    let mut had_error = false;

    for filename in &files {
        let data = if filename == "-" {
            match read_stdin() {
                Ok(d) => coreutils_rs::common::io::FileData::Owned(d),
                Err(e) => {
                    eprintln!("nl: standard input: {}", io_error_msg(&e));
                    had_error = true;
                    continue;
                }
            }
        } else {
            match read_file(Path::new(filename)) {
                Ok(d) => d,
                Err(e) => {
                    eprintln!("nl: {}: {}", filename, io_error_msg(&e));
                    had_error = true;
                    continue;
                }
            }
        };

        let output = nl::nl_to_vec(&data, &cli.config);
        if let Err(e) = write_all_raw(&output) {
            if e.kind() == std::io::ErrorKind::BrokenPipe {
                process::exit(0);
            }
            eprintln!("nl: write error: {}", io_error_msg(&e));
            had_error = true;
        }
    }

    if had_error {
        process::exit(1);
    }
}

/// Write the full buffer to stdout, retrying on partial/interrupted writes.
#[cfg(unix)]
fn write_all_raw(data: &[u8]) -> std::io::Result<()> {
    let mut written = 0;
    while written < data.len() {
        let ret = unsafe {
            libc::write(
                1,
                data[written..].as_ptr() as *const libc::c_void,
                data.len() - written,
            )
        };
        if ret > 0 {
            written += ret as usize;
        } else if ret == 0 {
            return Err(std::io::Error::new(
                std::io::ErrorKind::WriteZero,
                "write returned 0",
            ));
        } else {
            let err = std::io::Error::last_os_error();
            if err.kind() == std::io::ErrorKind::Interrupted {
                continue;
            }
            return Err(err);
        }
    }
    Ok(())
}

#[cfg(not(unix))]
fn write_all_raw(data: &[u8]) -> std::io::Result<()> {
    use std::io::Write;
    let stdout = std::io::stdout();
    let mut out = std::io::BufWriter::with_capacity(256 * 1024, stdout.lock());
    out.write_all(data)?;
    out.flush()
}
