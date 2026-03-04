use std::io::{self, BufWriter, Read, Write};
#[cfg(unix)]
use std::mem::ManuallyDrop;
#[cfg(unix)]
use std::os::unix::io::FromRawFd;
use std::path::Path;
use std::process;

use coreutils_rs::common::io::read_file;
use coreutils_rs::common::{enlarge_stdout_pipe, io_error_msg};
use coreutils_rs::expand::{TabStops, parse_tab_stops, unexpand_bytes, unexpand_is_passthrough};

struct Cli {
    all: bool,
    first_only: bool,
    tabs: TabStops,
    files: Vec<String>,
}

fn parse_args() -> Cli {
    let mut cli = Cli {
        all: false,
        first_only: false,
        tabs: TabStops::Regular(8),
        files: Vec::new(),
    };

    let mut args = std::env::args_os().skip(1);
    let mut tab_spec: Option<String> = None;

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
            if bytes.starts_with(b"--tabs=") {
                let val = arg.to_string_lossy();
                tab_spec = Some(val[7..].to_string());
                // -t implies -a for unexpand
                cli.all = true;
                continue;
            }
            match bytes {
                b"--all" => cli.all = true,
                b"--first-only" => cli.first_only = true,
                b"--tabs" => {
                    tab_spec = Some(
                        args.next()
                            .unwrap_or_else(|| {
                                eprintln!("unexpand: option '--tabs' requires an argument");
                                process::exit(1);
                            })
                            .to_string_lossy()
                            .into_owned(),
                    );
                    // -t implies -a for unexpand
                    cli.all = true;
                }
                b"--help" => {
                    print!(
                        "Usage: unexpand [OPTION]... [FILE]...\n\
                         Convert blanks in each FILE to tabs, writing to standard output.\n\n\
                         With no FILE, or when FILE is -, read standard input.\n\n\
                         Mandatory arguments to long options are mandatory for short options too.\n\
                         \x20 -a, --all                  convert all blanks, instead of just initial blanks\n\
                         \x20     --first-only            convert only leading sequences of blanks (overrides -a)\n\
                         \x20 -t, --tabs=N               have tabs N characters apart, not 8\n\
                         \x20 -t, --tabs=LIST            use comma separated list of tab positions\n\
                         \x20     --help                 display this help and exit\n\
                         \x20     --version              output version information and exit\n"
                    );
                    process::exit(0);
                }
                b"--version" => {
                    println!("unexpand (fcoreutils) {}", env!("CARGO_PKG_VERSION"));
                    process::exit(0);
                }
                _ => {
                    eprintln!("unexpand: unrecognized option '{}'", arg.to_string_lossy());
                    eprintln!("Try 'unexpand --help' for more information.");
                    process::exit(1);
                }
            }
        } else if bytes.len() > 1 && bytes[0] == b'-' {
            let mut i = 1;
            while i < bytes.len() {
                match bytes[i] {
                    b'a' => cli.all = true,
                    b't' => {
                        if i + 1 < bytes.len() {
                            let val = arg.to_string_lossy();
                            tab_spec = Some(val[i + 1..].to_string());
                        } else {
                            tab_spec = Some(
                                args.next()
                                    .unwrap_or_else(|| {
                                        eprintln!("unexpand: option requires an argument -- 't'");
                                        process::exit(1);
                                    })
                                    .to_string_lossy()
                                    .into_owned(),
                            );
                        }
                        // -t implies -a for unexpand
                        cli.all = true;
                        break;
                    }
                    _ => {
                        if bytes[i].is_ascii_digit() {
                            let val = arg.to_string_lossy();
                            tab_spec = Some(val[i..].to_string());
                            break;
                        }
                        eprintln!("unexpand: invalid option -- '{}'", bytes[i] as char);
                        eprintln!("Try 'unexpand --help' for more information.");
                        process::exit(1);
                    }
                }
                i += 1;
            }
        } else {
            cli.files.push(arg.to_string_lossy().into_owned());
        }
    }

    if let Some(spec) = tab_spec {
        match parse_tab_stops(&spec) {
            Ok(tabs) => cli.tabs = tabs,
            Err(e) => {
                eprintln!("unexpand: {}", e);
                process::exit(1);
            }
        }
    }

    // --first-only overrides -a
    if cli.first_only {
        cli.all = false;
    }

    cli
}

/// Write all bytes directly to a file descriptor, bypassing BufWriter.
#[cfg(unix)]
fn write_all_fd(fd: i32, data: &[u8]) -> io::Result<()> {
    let mut pos = 0;
    while pos < data.len() {
        let n = unsafe {
            libc::write(
                fd,
                data[pos..].as_ptr() as *const libc::c_void,
                data.len() - pos,
            )
        };
        if n < 0 {
            return Err(io::Error::last_os_error());
        }
        pos += n as usize;
    }
    Ok(())
}

fn main() {
    coreutils_rs::common::reset_sigpipe();

    enlarge_stdout_pipe();

    let cli = parse_args();

    let files: Vec<String> = if cli.files.is_empty() {
        vec!["-".to_string()]
    } else {
        cli.files
    };

    #[cfg(unix)]
    let stdout_raw = unsafe { ManuallyDrop::new(std::fs::File::from_raw_fd(1)) };
    #[cfg(unix)]
    let mut out = BufWriter::with_capacity(1024 * 1024, &*stdout_raw);
    #[cfg(not(unix))]
    let stdout = io::stdout();
    #[cfg(not(unix))]
    let mut out = BufWriter::with_capacity(1024 * 1024, stdout.lock());

    let mut had_error = false;

    for filename in &files {
        let result = if filename == "-" {
            // Streaming stdin: read in chunks and process incrementally.
            // We split at newline boundaries so column tracking stays correct
            // across chunks. Leftover bytes (partial last line) carry over.
            let stdin = io::stdin();
            let mut reader = stdin.lock();
            let mut buf = vec![0u8; 256 * 1024];
            let mut leftover = 0usize; // bytes from previous read still in buf
            let mut err: Option<io::Error> = None;
            loop {
                let n = match reader.read(&mut buf[leftover..]) {
                    Ok(0) => {
                        // EOF: process any remaining leftover
                        if leftover > 0 {
                            let r = unexpand_bytes(&buf[..leftover], &cli.tabs, cli.all, &mut out);
                            if let Err(e) = r {
                                err = Some(e);
                            }
                        }
                        break;
                    }
                    Ok(n) => n,
                    Err(e) if e.kind() == io::ErrorKind::Interrupted => continue,
                    Err(e) => {
                        err = Some(e);
                        break;
                    }
                };
                let total = leftover + n;
                // Find last newline to split at line boundary
                let process_end = match memchr::memrchr(b'\n', &buf[..total]) {
                    Some(pos) => pos + 1,
                    None => {
                        // No newline in buffer — keep accumulating
                        leftover = total;
                        if total >= buf.len() {
                            // Buffer full with no newline — process it all
                            if let Err(e) =
                                unexpand_bytes(&buf[..total], &cli.tabs, cli.all, &mut out)
                            {
                                err = Some(e);
                                break;
                            }
                            leftover = 0;
                        }
                        continue;
                    }
                };
                if let Err(e) = unexpand_bytes(&buf[..process_end], &cli.tabs, cli.all, &mut out) {
                    err = Some(e);
                    break;
                }
                // Move leftover bytes to front
                let remaining = total - process_end;
                if remaining > 0 {
                    buf.copy_within(process_end..total, 0);
                }
                leftover = remaining;
            }
            match err {
                Some(e) => Err(e),
                None => Ok(()),
            }
        } else {
            let data = match read_file(Path::new(filename)) {
                Ok(d) => d,
                Err(e) => {
                    eprintln!("unexpand: {}: {}", filename, io_error_msg(&e));
                    had_error = true;
                    continue;
                }
            };
            // Fast path: if output = input, bypass BufWriter and write directly
            #[cfg(unix)]
            if unexpand_is_passthrough(&data, &cli.tabs, cli.all) {
                // Flush any buffered data first, then write directly to fd
                if let Err(e) = out.flush() {
                    Err(e)
                } else {
                    write_all_fd(1, &data)
                }
            } else {
                unexpand_bytes(&data, &cli.tabs, cli.all, &mut out)
            }
            #[cfg(not(unix))]
            unexpand_bytes(&data, &cli.tabs, cli.all, &mut out)
        };

        if let Err(e) = result {
            if e.kind() == io::ErrorKind::BrokenPipe {
                process::exit(0);
            }
            eprintln!("unexpand: write error: {}", io_error_msg(&e));
            had_error = true;
        }
    }

    if let Err(e) = out.flush()
        && e.kind() != io::ErrorKind::BrokenPipe
    {
        eprintln!("unexpand: write error: {}", io_error_msg(&e));
        had_error = true;
    }

    if had_error {
        process::exit(1);
    }
}

#[cfg(test)]
mod tests {
    use std::io::Write;
    use std::process::{Command, Stdio};

    fn cmd() -> Command {
        let mut path = std::env::current_exe().unwrap();
        path.pop();
        path.pop();
        path.push("funexpand");
        Command::new(path)
    }
    #[test]
    fn test_unexpand_basic() {
        let mut child = cmd()
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .spawn()
            .unwrap();
        child
            .stdin
            .take()
            .unwrap()
            .write_all(b"        hello\n")
            .unwrap();
        let output = child.wait_with_output().unwrap();
        assert!(output.status.success());
        assert_eq!(String::from_utf8_lossy(&output.stdout), "\thello\n");
    }

    #[test]
    fn test_unexpand_all() {
        let mut child = cmd()
            .arg("-a")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .spawn()
            .unwrap();
        child
            .stdin
            .take()
            .unwrap()
            .write_all(b"hello           world\n")
            .unwrap();
        let output = child.wait_with_output().unwrap();
        assert!(output.status.success());
        let stdout = String::from_utf8_lossy(&output.stdout);
        assert!(stdout.contains('\t'), "Should contain tabs with -a");
    }

    #[test]
    fn test_unexpand_file() {
        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join("test.txt");
        std::fs::write(&file, "        hello\n").unwrap();
        let output = cmd().arg(file.to_str().unwrap()).output().unwrap();
        assert!(output.status.success());
        assert_eq!(String::from_utf8_lossy(&output.stdout), "\thello\n");
    }

    #[test]
    fn test_unexpand_empty_input() {
        let mut child = cmd()
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .spawn()
            .unwrap();
        drop(child.stdin.take().unwrap());
        let output = child.wait_with_output().unwrap();
        assert!(output.status.success());
        assert_eq!(output.stdout, b"");
    }

    #[test]
    fn test_unexpand_no_spaces() {
        let mut child = cmd()
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .spawn()
            .unwrap();
        child.stdin.take().unwrap().write_all(b"hello\n").unwrap();
        let output = child.wait_with_output().unwrap();
        assert!(output.status.success());
        assert_eq!(String::from_utf8_lossy(&output.stdout), "hello\n");
    }

    #[test]
    fn test_unexpand_custom_tabstop() {
        let mut child = cmd()
            .args(["-t", "4"])
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .spawn()
            .unwrap();
        child
            .stdin
            .take()
            .unwrap()
            .write_all(b"    hello\n")
            .unwrap();
        let output = child.wait_with_output().unwrap();
        assert!(output.status.success());
        assert_eq!(String::from_utf8_lossy(&output.stdout), "\thello\n");
    }

    #[test]
    fn test_unexpand_mixed_spaces() {
        let mut child = cmd()
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .spawn()
            .unwrap();
        // 8 spaces (tab stop) + 4 spaces (not a full tab)
        child
            .stdin
            .take()
            .unwrap()
            .write_all(b"            hello\n")
            .unwrap();
        let output = child.wait_with_output().unwrap();
        assert!(output.status.success());
        let stdout = String::from_utf8_lossy(&output.stdout);
        assert!(stdout.contains('\t'));
    }

    #[test]
    fn test_unexpand_first_only() {
        // Default: only convert leading spaces
        let mut child = cmd()
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .spawn()
            .unwrap();
        child
            .stdin
            .take()
            .unwrap()
            .write_all(b"        hello        world\n")
            .unwrap();
        let output = child.wait_with_output().unwrap();
        assert!(output.status.success());
        let stdout = String::from_utf8_lossy(&output.stdout);
        // Leading spaces converted, internal spaces preserved
        assert!(stdout.starts_with('\t'));
    }

    #[test]
    fn test_unexpand_nonexistent_file() {
        let output = cmd().arg("/nonexistent_xyz_unexpand").output().unwrap();
        assert!(!output.status.success());
    }
}
