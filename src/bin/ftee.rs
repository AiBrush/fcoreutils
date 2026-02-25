#[cfg(not(unix))]
fn main() {
    eprintln!("tee: only available on Unix");
    std::process::exit(1);
}

// ftee -- read from stdin, write to stdout and files
//
// Usage: tee [OPTION]... [FILE]...

#[cfg(unix)]
use std::fs::{File, OpenOptions};
#[cfg(unix)]
use std::io;
#[cfg(unix)]
use std::os::unix::io::AsRawFd;
#[cfg(unix)]
use std::process;

#[cfg(unix)]
const TOOL_NAME: &str = "tee";
#[cfg(unix)]
const VERSION: &str = env!("CARGO_PKG_VERSION");

#[derive(Clone, Copy, PartialEq)]
#[cfg(unix)]
enum OutputErrorMode {
    /// Default: exit on error
    WarnDefault,
    /// warn: warn on error, continue
    Warn,
    /// warn-nopipe: warn on error except EPIPE, continue
    WarnNoPipe,
    /// exit: exit on error
    Exit,
    /// exit-nopipe: exit on error except EPIPE
    ExitNoPipe,
}

#[cfg(unix)]
fn main() {
    coreutils_rs::common::reset_sigpipe();

    let mut append = false;
    let mut ignore_interrupts = false;
    let mut output_error = OutputErrorMode::WarnDefault;
    let mut diagnose_pipe = false;
    let mut files: Vec<String> = Vec::new();
    let mut saw_dashdash = false;

    let args: Vec<String> = std::env::args().skip(1).collect();
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
                println!("Usage: {} [OPTION]... [FILE]...", TOOL_NAME);
                println!("Copy standard input to each FILE, and also to standard output.");
                println!();
                println!("  -a, --append             append to the given FILEs, do not overwrite");
                println!("  -i, --ignore-interrupts  ignore interrupt signals");
                println!("  -p                       diagnose errors writing to non pipes");
                println!(
                    "      --output-error[=MODE]  set behavior on write error.  See MODE below"
                );
                println!("      --help               display this help and exit");
                println!("      --version            output version information and exit");
                println!();
                println!("MODE determines behavior with write errors on the outputs:");
                println!("  'warn'         diagnose errors writing to any output");
                println!("  'warn-nopipe'  diagnose errors writing to any output not a pipe");
                println!("  'exit'         exit on error writing to any output");
                println!("  'exit-nopipe'  exit on error writing to any output not a pipe");
                return;
            }
            "--version" => {
                println!("{} (fcoreutils) {}", TOOL_NAME, VERSION);
                return;
            }
            "--append" => append = true,
            "--ignore-interrupts" => ignore_interrupts = true,
            "--output-error" => output_error = OutputErrorMode::Warn,
            s if s.starts_with("--output-error=") => {
                let mode_val = &s["--output-error=".len()..];
                output_error = match mode_val {
                    "warn" => OutputErrorMode::Warn,
                    "warn-nopipe" => OutputErrorMode::WarnNoPipe,
                    "exit" => OutputErrorMode::Exit,
                    "exit-nopipe" => OutputErrorMode::ExitNoPipe,
                    _ => {
                        eprintln!(
                            "{}: invalid argument \u{2018}{}\u{2019} for \u{2018}--output-error\u{2019}",
                            TOOL_NAME, mode_val
                        );
                        eprintln!("Valid arguments are:");
                        eprintln!("  - \u{2018}warn\u{2019}");
                        eprintln!("  - \u{2018}warn-nopipe\u{2019}");
                        eprintln!("  - \u{2018}exit\u{2019}");
                        eprintln!("  - \u{2018}exit-nopipe\u{2019}");
                        eprintln!(
                            "Try \u{2018}{} --help\u{2019} for more information.",
                            TOOL_NAME
                        );
                        process::exit(1);
                    }
                };
            }
            "--" => saw_dashdash = true,
            s if s.starts_with('-') && s.len() > 1 && !s.starts_with("--") => {
                for ch in s[1..].chars() {
                    match ch {
                        'a' => append = true,
                        'i' => ignore_interrupts = true,
                        'p' => diagnose_pipe = true,
                        _ => {
                            eprintln!("{}: invalid option -- '{}'", TOOL_NAME, ch);
                            eprintln!("Try '{} --help' for more information.", TOOL_NAME);
                            process::exit(1);
                        }
                    }
                }
            }
            _ => files.push(arg.clone()),
        }
        i += 1;
    }

    if ignore_interrupts {
        #[cfg(unix)]
        unsafe {
            libc::signal(libc::SIGINT, libc::SIG_IGN);
        }
    }

    // -p implies --output-error=warn-nopipe
    if diagnose_pipe && output_error == OutputErrorMode::WarnDefault {
        output_error = OutputErrorMode::WarnNoPipe;
    }

    // Open all output files — store raw fds for direct syscall writes
    let mut outputs: Vec<(String, File)> = Vec::new();
    let mut exit_code = 0;

    for path in &files {
        let result = if append {
            OpenOptions::new().create(true).append(true).open(path)
        } else {
            File::create(path)
        };
        match result {
            Ok(f) => outputs.push((path.clone(), f)),
            Err(e) => {
                eprintln!(
                    "{}: {}: {}",
                    TOOL_NAME,
                    path,
                    coreutils_rs::common::io_error_msg(&e)
                );
                exit_code = 1;
            }
        }
    }

    // Raw fd I/O: bypass BufReader/BufWriter overhead entirely.
    // Uses a 1MB buffer with direct libc::read/write syscalls.
    let stdin_fd = io::stdin().as_raw_fd();
    let stdout_fd = io::stdout().as_raw_fd();
    let mut buf = vec![0u8; 1024 * 1024];
    let mut stdout_ok = true;
    let mut to_remove = Vec::new();

    loop {
        let n = unsafe { libc::read(stdin_fd, buf.as_mut_ptr().cast(), buf.len() as _) };
        if n == 0 {
            break;
        }
        if n < 0 {
            let err = io::Error::last_os_error();
            if err.kind() == io::ErrorKind::Interrupted {
                continue;
            }
            eprintln!("{}: read error: {}", TOOL_NAME, err);
            process::exit(1);
        }
        let data = &buf[..n as usize];

        // Write to stdout
        // Under --output-error=warn, GNU tee keeps writing and warns on each chunk,
        // so only permanently suppress stdout writes for BrokenPipe (unrecoverable).
        if stdout_ok {
            if let Err(e) = write_all_raw(stdout_fd, data) {
                if handle_write_error(TOOL_NAME, "standard output", &e, output_error) {
                    process::exit(1);
                }
                exit_code = 1;
                if e.kind() == io::ErrorKind::BrokenPipe {
                    stdout_ok = false;
                }
            }
        }

        // Write to each file
        to_remove.clear();
        for (idx, (path, file)) in outputs.iter().enumerate() {
            if let Err(e) = write_all_raw(file.as_raw_fd(), data) {
                if handle_write_error(TOOL_NAME, path, &e, output_error) {
                    process::exit(1);
                }
                exit_code = 1;
                to_remove.push(idx);
            }
        }
        for idx in to_remove.iter().rev() {
            outputs.remove(*idx);
        }
    }

    process::exit(exit_code);
}

/// Write all bytes to a raw fd, retrying on short writes and EINTR.
#[cfg(unix)]
fn write_all_raw(fd: i32, mut data: &[u8]) -> io::Result<()> {
    while !data.is_empty() {
        let ret = unsafe { libc::write(fd, data.as_ptr().cast(), data.len() as _) };
        if ret > 0 {
            data = &data[ret as usize..];
        } else if ret == 0 {
            return Err(io::Error::new(io::ErrorKind::WriteZero, "write returned 0"));
        } else {
            let err = io::Error::last_os_error();
            if err.kind() == io::ErrorKind::Interrupted {
                continue;
            }
            return Err(err);
        }
    }
    Ok(())
}

#[cfg(unix)]
fn handle_write_error(
    tool_name: &str,
    target: &str,
    error: &io::Error,
    mode: OutputErrorMode,
) -> bool {
    let is_pipe_error = error.kind() == io::ErrorKind::BrokenPipe;

    match mode {
        OutputErrorMode::WarnDefault => {
            if !is_pipe_error {
                eprintln!(
                    "{}: {}: {}",
                    tool_name,
                    target,
                    coreutils_rs::common::io_error_msg(error)
                );
            }
            false
        }
        OutputErrorMode::Warn => {
            eprintln!(
                "{}: {}: {}",
                tool_name,
                target,
                coreutils_rs::common::io_error_msg(error)
            );
            false
        }
        OutputErrorMode::WarnNoPipe => {
            if !is_pipe_error {
                eprintln!(
                    "{}: {}: {}",
                    tool_name,
                    target,
                    coreutils_rs::common::io_error_msg(error)
                );
            }
            false
        }
        OutputErrorMode::Exit => {
            eprintln!(
                "{}: {}: {}",
                tool_name,
                target,
                coreutils_rs::common::io_error_msg(error)
            );
            true
        }
        OutputErrorMode::ExitNoPipe => {
            if is_pipe_error {
                false
            } else {
                eprintln!(
                    "{}: {}: {}",
                    tool_name,
                    target,
                    coreutils_rs::common::io_error_msg(error)
                );
                true
            }
        }
    }
}

#[cfg(all(test, unix))]
mod tests {
    use std::io::Write;
    use std::process::{Command, Stdio};

    fn cmd() -> Command {
        let mut path = std::env::current_exe().unwrap();
        path.pop();
        path.pop();
        path.push("ftee");
        Command::new(path)
    }

    #[test]
    fn test_basic_pipe_through() {
        let mut child = cmd()
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .spawn()
            .unwrap();
        child
            .stdin
            .as_mut()
            .unwrap()
            .write_all(b"hello world\n")
            .unwrap();
        let output = child.wait_with_output().unwrap();
        assert_eq!(output.status.code(), Some(0));
        assert_eq!(String::from_utf8_lossy(&output.stdout), "hello world\n");
    }

    #[test]
    fn test_write_to_file() {
        let dir = tempfile::tempdir().unwrap();
        let file_path = dir.path().join("out.txt");

        let mut child = cmd()
            .arg(file_path.to_str().unwrap())
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .spawn()
            .unwrap();
        child
            .stdin
            .as_mut()
            .unwrap()
            .write_all(b"test data\n")
            .unwrap();
        let output = child.wait_with_output().unwrap();
        assert_eq!(output.status.code(), Some(0));

        let contents = std::fs::read_to_string(&file_path).unwrap();
        assert_eq!(contents, "test data\n");
        // stdout should also have the data
        assert_eq!(String::from_utf8_lossy(&output.stdout), "test data\n");
    }

    #[test]
    fn test_append_mode() {
        let dir = tempfile::tempdir().unwrap();
        let file_path = dir.path().join("append.txt");
        std::fs::write(&file_path, "existing\n").unwrap();

        let mut child = cmd()
            .args(["-a", file_path.to_str().unwrap()])
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .spawn()
            .unwrap();
        child
            .stdin
            .as_mut()
            .unwrap()
            .write_all(b"new data\n")
            .unwrap();
        let output = child.wait_with_output().unwrap();
        assert_eq!(output.status.code(), Some(0));

        let contents = std::fs::read_to_string(&file_path).unwrap();
        assert_eq!(contents, "existing\nnew data\n");
    }

    #[test]
    fn test_multiple_files() {
        let dir = tempfile::tempdir().unwrap();
        let file1 = dir.path().join("f1.txt");
        let file2 = dir.path().join("f2.txt");

        let mut child = cmd()
            .args([file1.to_str().unwrap(), file2.to_str().unwrap()])
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .spawn()
            .unwrap();
        child.stdin.as_mut().unwrap().write_all(b"multi\n").unwrap();
        let output = child.wait_with_output().unwrap();
        assert_eq!(output.status.code(), Some(0));

        assert_eq!(std::fs::read_to_string(&file1).unwrap(), "multi\n");
        assert_eq!(std::fs::read_to_string(&file2).unwrap(), "multi\n");
    }

    #[test]
    fn test_ignore_interrupts_flag() {
        // Just test that -i is accepted
        let mut child = cmd()
            .arg("-i")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .spawn()
            .unwrap();
        child.stdin.as_mut().unwrap().write_all(b"data\n").unwrap();
        let output = child.wait_with_output().unwrap();
        assert_eq!(output.status.code(), Some(0));
    }

    #[test]
    fn test_help() {
        let output = cmd().arg("--help").output().unwrap();
        assert_eq!(output.status.code(), Some(0));
        let stdout = String::from_utf8_lossy(&output.stdout);
        assert!(stdout.contains("Usage:"));
    }

    #[test]
    fn test_version() {
        let output = cmd().arg("--version").output().unwrap();
        assert_eq!(output.status.code(), Some(0));
        let stdout = String::from_utf8_lossy(&output.stdout);
        assert!(stdout.contains("(fcoreutils)"));
    }

    #[test]
    fn test_matches_gnu() {
        let gnu_child = Command::new("tee")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn();
        if let Ok(mut gnu_child) = gnu_child {
            gnu_child
                .stdin
                .as_mut()
                .unwrap()
                .write_all(b"gnu test\n")
                .unwrap();
            let gnu = gnu_child.wait_with_output().unwrap();

            let mut our_child = cmd()
                .stdin(Stdio::piped())
                .stdout(Stdio::piped())
                .stderr(Stdio::piped())
                .spawn()
                .unwrap();
            our_child
                .stdin
                .as_mut()
                .unwrap()
                .write_all(b"gnu test\n")
                .unwrap();
            let ours = our_child.wait_with_output().unwrap();

            assert_eq!(ours.stdout, gnu.stdout, "STDOUT mismatch");
            assert_eq!(ours.status.code(), gnu.status.code(), "Exit code mismatch");
        }
    }

    #[test]
    fn test_overwrite_mode() {
        let dir = tempfile::tempdir().unwrap();
        let file_path = dir.path().join("overwrite.txt");
        std::fs::write(&file_path, "old content\n").unwrap();

        let mut child = cmd()
            .arg(file_path.to_str().unwrap())
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .spawn()
            .unwrap();
        child.stdin.as_mut().unwrap().write_all(b"new\n").unwrap();
        let output = child.wait_with_output().unwrap();
        assert_eq!(output.status.code(), Some(0));

        let contents = std::fs::read_to_string(&file_path).unwrap();
        assert_eq!(contents, "new\n");
    }
}
