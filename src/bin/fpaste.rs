use std::path::Path;
use std::process;

use coreutils_rs::common::io::{read_file, read_stdin};
use coreutils_rs::common::io_error_msg;
use coreutils_rs::paste::{self, PasteConfig};

struct Cli {
    config: PasteConfig,
    files: Vec<String>,
}

fn parse_args() -> Cli {
    let mut cli = Cli {
        config: PasteConfig::default(),
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
            if let Some(val) = s.strip_prefix("--delimiters=") {
                cli.config.delimiters = paste::parse_delimiters(val);
            } else {
                match bytes {
                    b"--delimiters" => {
                        let val = args.next().unwrap_or_else(|| {
                            eprintln!("paste: option '--delimiters' requires an argument");
                            process::exit(1);
                        });
                        cli.config.delimiters = paste::parse_delimiters(&val.to_string_lossy());
                    }
                    b"--serial" => cli.config.serial = true,
                    b"--zero-terminated" => cli.config.zero_terminated = true,
                    b"--help" => {
                        print_help();
                        process::exit(0);
                    }
                    b"--version" => {
                        println!("paste (fcoreutils) {}", env!("CARGO_PKG_VERSION"));
                        process::exit(0);
                    }
                    _ => {
                        eprintln!("paste: unrecognized option '{}'", s);
                        eprintln!("Try 'paste --help' for more information.");
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
                    'd' => {
                        let val = if i + 1 < chars.len() {
                            // Rest of the arg is the delimiter value
                            s[1 + i + 1..].to_string()
                        } else {
                            args.next()
                                .unwrap_or_else(|| {
                                    eprintln!("paste: option requires an argument -- 'd'");
                                    process::exit(1);
                                })
                                .to_string_lossy()
                                .into_owned()
                        };
                        cli.config.delimiters = paste::parse_delimiters(&val);
                        break; // consumed rest of arg
                    }
                    's' => cli.config.serial = true,
                    'z' => cli.config.zero_terminated = true,
                    _ => {
                        eprintln!("paste: invalid option -- '{}'", chars[i]);
                        eprintln!("Try 'paste --help' for more information.");
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

fn print_help() {
    print!(
        "Usage: paste [OPTION]... [FILE]...\n\
         Write lines consisting of the sequentially corresponding lines from\n\
         each FILE, separated by TABs, to standard output.\n\n\
         With no FILE, or when FILE is -, read standard input.\n\n\
         Mandatory arguments to long options are mandatory for short options too.\n\
         \x20 -d, --delimiters=LIST   reuse characters from LIST instead of TABs\n\
         \x20 -s, --serial            paste one file at a time instead of in parallel\n\
         \x20 -z, --zero-terminated   line delimiter is NUL, not newline\n\
         \x20     --help              display this help and exit\n\
         \x20     --version           output version information and exit\n"
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

    // Read all files. Stdin is read once and shared if `-` appears multiple times.
    let mut file_data_owned: Vec<coreutils_rs::common::io::FileData> = Vec::new();
    let mut stdin_data: Option<coreutils_rs::common::io::FileData> = None;
    let mut data_indices: Vec<usize> = Vec::new(); // index into file_data_owned or stdin
    let mut had_error = false;

    for filename in &files {
        if filename == "-" {
            if stdin_data.is_none() {
                match read_stdin() {
                    Ok(d) => {
                        stdin_data = Some(coreutils_rs::common::io::FileData::Owned(d));
                    }
                    Err(e) => {
                        eprintln!("paste: standard input: {}", io_error_msg(&e));
                        had_error = true;
                        // Push empty data so indices stay correct
                        file_data_owned.push(coreutils_rs::common::io::FileData::Owned(Vec::new()));
                        data_indices.push(file_data_owned.len() - 1);
                        continue;
                    }
                }
            }
            // Sentinel for stdin reference
            data_indices.push(usize::MAX);
        } else {
            match read_file(Path::new(filename)) {
                Ok(d) => {
                    file_data_owned.push(d);
                    data_indices.push(file_data_owned.len() - 1);
                }
                Err(e) => {
                    eprintln!("paste: {}: {}", filename, io_error_msg(&e));
                    had_error = true;
                    // Push empty data so indices stay correct
                    file_data_owned.push(coreutils_rs::common::io::FileData::Owned(Vec::new()));
                    data_indices.push(file_data_owned.len() - 1);
                }
            }
        }
    }

    // Build reference slices
    let stdin_ref: &[u8] = match &stdin_data {
        Some(d) => d,
        None => b"",
    };
    let data_refs: Vec<&[u8]> = data_indices
        .iter()
        .map(|&idx| {
            if idx == usize::MAX {
                stdin_ref
            } else {
                &*file_data_owned[idx]
            }
        })
        .collect();

    // Build output buffer
    let output = paste::paste_to_vec(&data_refs, &cli.config);

    // Write output using raw write for minimal syscall overhead
    if let Err(e) = write_all_raw(&output) {
        if e.kind() == std::io::ErrorKind::BrokenPipe {
            process::exit(0);
        }
        eprintln!("paste: write error: {}", io_error_msg(&e));
        had_error = true;
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
