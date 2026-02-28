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

    let terminator = if cli.config.zero_terminated {
        0u8
    } else {
        b'\n'
    };
    let mut had_error = false;

    // Count stdin occurrences
    let stdin_count = files.iter().filter(|f| *f == "-").count();

    // Read stdin once if needed
    let stdin_raw: Vec<u8> = if stdin_count > 0 {
        match read_stdin() {
            Ok(d) => d,
            Err(e) => {
                eprintln!("paste: standard input: {}", io_error_msg(&e));
                had_error = true;
                Vec::new()
            }
        }
    } else {
        Vec::new()
    };

    // Distribute stdin lines among multiple `-` arguments.
    // GNU paste shares a single stdin stream: `paste - -` reads alternating lines.
    let mut stdin_parts: Vec<Vec<u8>> = if stdin_count > 1 && cli.config.serial {
        // Serial mode: first `-` consumes all stdin, rest get empty
        let mut parts = vec![Vec::new(); stdin_count];
        parts[0] = stdin_raw;
        parts
    } else if stdin_count > 1 {
        // Parallel mode: round-robin distribute stdin lines
        distribute_stdin_lines(&stdin_raw, stdin_count, terminator)
    } else {
        vec![stdin_raw]
    };

    // Build file data for each argument
    let mut file_data: Vec<coreutils_rs::common::io::FileData> = Vec::with_capacity(files.len());
    let mut stdin_idx = 0;

    for filename in &files {
        if filename == "-" {
            let data = std::mem::take(&mut stdin_parts[stdin_idx]);
            file_data.push(coreutils_rs::common::io::FileData::Owned(data));
            stdin_idx += 1;
        } else {
            match read_file(Path::new(filename)) {
                Ok(d) => file_data.push(d),
                Err(e) => {
                    eprintln!("paste: {}: {}", filename, io_error_msg(&e));
                    had_error = true;
                    file_data.push(coreutils_rs::common::io::FileData::Owned(Vec::new()));
                }
            }
        }
    }

    // Build reference slices
    let data_refs: Vec<&[u8]> = file_data.iter().map(|d| &**d).collect();

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

/// Distribute stdin lines round-robin among multiple stdin arguments.
/// This matches GNU paste behavior where `paste - -` reads alternating lines from stdin.
fn distribute_stdin_lines(data: &[u8], count: usize, terminator: u8) -> Vec<Vec<u8>> {
    let mut parts = vec![Vec::new(); count];
    let mut start = 0;
    let mut line_idx = 0;
    for (i, &b) in data.iter().enumerate() {
        if b == terminator {
            let target = line_idx % count;
            parts[target].extend_from_slice(&data[start..=i]);
            start = i + 1;
            line_idx += 1;
        }
    }
    // Handle last line without terminator
    if start < data.len() {
        let target = line_idx % count;
        parts[target].extend_from_slice(&data[start..]);
    }
    parts
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
                (data.len() - written) as _,
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

#[cfg(test)]
mod tests {
    use std::process::Command;

    fn cmd() -> Command {
        let mut path = std::env::current_exe().unwrap();
        path.pop();
        path.pop();
        path.push("fpaste");
        Command::new(path)
    }

    #[test]
    fn test_paste_help() {
        let output = cmd().arg("--help").output().unwrap();
        assert!(output.status.success());
        assert!(String::from_utf8_lossy(&output.stdout).contains("Usage"));
    }

    #[test]
    fn test_paste_version() {
        let output = cmd().arg("--version").output().unwrap();
        assert!(output.status.success());
        assert!(String::from_utf8_lossy(&output.stdout).contains("fcoreutils"));
    }

    #[test]
    fn test_paste_two_files() {
        let dir = tempfile::tempdir().unwrap();
        let f1 = dir.path().join("a.txt");
        let f2 = dir.path().join("b.txt");
        std::fs::write(&f1, "1\n2\n3\n").unwrap();
        std::fs::write(&f2, "a\nb\nc\n").unwrap();
        let output = cmd()
            .args([f1.to_str().unwrap(), f2.to_str().unwrap()])
            .output()
            .unwrap();
        assert!(output.status.success());
        assert_eq!(
            String::from_utf8_lossy(&output.stdout),
            "1\ta\n2\tb\n3\tc\n"
        );
    }

    #[test]
    fn test_paste_serial() {
        let dir = tempfile::tempdir().unwrap();
        let f1 = dir.path().join("a.txt");
        std::fs::write(&f1, "1\n2\n3\n").unwrap();
        let output = cmd().args(["-s", f1.to_str().unwrap()]).output().unwrap();
        assert!(output.status.success());
        assert_eq!(String::from_utf8_lossy(&output.stdout), "1\t2\t3\n");
    }

    #[test]
    fn test_paste_custom_delimiter() {
        let dir = tempfile::tempdir().unwrap();
        let f1 = dir.path().join("a.txt");
        let f2 = dir.path().join("b.txt");
        std::fs::write(&f1, "1\n2\n").unwrap();
        std::fs::write(&f2, "a\nb\n").unwrap();
        let output = cmd()
            .args(["-d", ":", f1.to_str().unwrap(), f2.to_str().unwrap()])
            .output()
            .unwrap();
        assert!(output.status.success());
        assert_eq!(String::from_utf8_lossy(&output.stdout), "1:a\n2:b\n");
    }

    #[test]
    fn test_paste_stdin() {
        use std::io::Write;
        use std::process::Stdio;
        let dir = tempfile::tempdir().unwrap();
        let f1 = dir.path().join("a.txt");
        std::fs::write(&f1, "1\n2\n").unwrap();
        let mut child = cmd()
            .args([f1.to_str().unwrap(), "-"])
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .spawn()
            .unwrap();
        child.stdin.take().unwrap().write_all(b"a\nb\n").unwrap();
        let output = child.wait_with_output().unwrap();
        assert!(output.status.success());
        assert_eq!(String::from_utf8_lossy(&output.stdout), "1\ta\n2\tb\n");
    }

    #[test]
    fn test_paste_unequal_files() {
        let dir = tempfile::tempdir().unwrap();
        let f1 = dir.path().join("a.txt");
        let f2 = dir.path().join("b.txt");
        std::fs::write(&f1, "1\n2\n3\n").unwrap();
        std::fs::write(&f2, "a\n").unwrap();
        let output = cmd()
            .args([f1.to_str().unwrap(), f2.to_str().unwrap()])
            .output()
            .unwrap();
        assert!(output.status.success());
        let stdout = String::from_utf8_lossy(&output.stdout);
        assert_eq!(stdout, "1\ta\n2\t\n3\t\n");
    }

    #[test]
    fn test_paste_empty_file() {
        let dir = tempfile::tempdir().unwrap();
        let f1 = dir.path().join("empty.txt");
        std::fs::write(&f1, "").unwrap();
        let output = cmd().arg(f1.to_str().unwrap()).output().unwrap();
        assert!(output.status.success());
        assert_eq!(output.stdout, b"");
    }

    #[test]
    fn test_paste_serial_empty() {
        let dir = tempfile::tempdir().unwrap();
        let f1 = dir.path().join("empty.txt");
        std::fs::write(&f1, "").unwrap();
        let output = cmd().args(["-s", f1.to_str().unwrap()]).output().unwrap();
        assert!(output.status.success());
    }

    #[test]
    fn test_paste_multi_char_delimiter() {
        let dir = tempfile::tempdir().unwrap();
        let f1 = dir.path().join("a.txt");
        let f2 = dir.path().join("b.txt");
        let f3 = dir.path().join("c.txt");
        std::fs::write(&f1, "1\n").unwrap();
        std::fs::write(&f2, "2\n").unwrap();
        std::fs::write(&f3, "3\n").unwrap();
        let output = cmd()
            .args([
                "-d",
                ":,",
                f1.to_str().unwrap(),
                f2.to_str().unwrap(),
                f3.to_str().unwrap(),
            ])
            .output()
            .unwrap();
        assert!(output.status.success());
        assert_eq!(String::from_utf8_lossy(&output.stdout), "1:2,3\n");
    }

    #[test]
    fn test_paste_nonexistent_file() {
        let output = cmd().arg("/nonexistent_xyz_paste").output().unwrap();
        assert!(!output.status.success());
    }

    #[test]
    fn test_paste_single_file() {
        let dir = tempfile::tempdir().unwrap();
        let f1 = dir.path().join("a.txt");
        std::fs::write(&f1, "hello\nworld\n").unwrap();
        let output = cmd().arg(f1.to_str().unwrap()).output().unwrap();
        assert!(output.status.success());
        assert_eq!(String::from_utf8_lossy(&output.stdout), "hello\nworld\n");
    }

    #[test]
    fn test_paste_serial_multiple_files() {
        let dir = tempfile::tempdir().unwrap();
        let f1 = dir.path().join("a.txt");
        let f2 = dir.path().join("b.txt");
        std::fs::write(&f1, "1\n2\n").unwrap();
        std::fs::write(&f2, "a\nb\n").unwrap();
        let output = cmd()
            .args(["-s", f1.to_str().unwrap(), f2.to_str().unwrap()])
            .output()
            .unwrap();
        assert!(output.status.success());
        assert_eq!(String::from_utf8_lossy(&output.stdout), "1\t2\na\tb\n");
    }
}
