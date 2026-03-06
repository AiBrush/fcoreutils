use std::io::{self, Write};
#[cfg(unix)]
use std::mem::ManuallyDrop;
#[cfg(unix)]
use std::os::unix::io::FromRawFd;
use std::path::Path;
use std::process;

use coreutils_rs::base64::core as b64;
use coreutils_rs::common::io::read_file;
#[cfg(unix)]
use coreutils_rs::common::io::try_mmap_stdin;
use coreutils_rs::common::{enlarge_stdout_pipe, io_error_msg};

/// Raw stdin reader for zero-overhead pipe reads on Linux.
/// Bypasses Rust's StdinLock (mutex + 8KB BufReader) for direct libc::read(0).
#[cfg(target_os = "linux")]
struct RawStdin;

#[cfg(target_os = "linux")]
impl io::Read for RawStdin {
    #[inline]
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        loop {
            let ret = unsafe { libc::read(0, buf.as_mut_ptr() as *mut libc::c_void, buf.len()) };
            if ret >= 0 {
                return Ok(ret as usize);
            }
            let err = io::Error::last_os_error();
            if err.kind() != io::ErrorKind::Interrupted {
                return Err(err);
            }
        }
    }
}

struct Cli {
    decode: bool,
    ignore_garbage: bool,
    wrap: usize,
    file: Option<String>,
}

/// Hand-rolled argument parser — eliminates clap's ~100-200µs initialization.
/// base64's args are simple: -d, -i, -w COLS, and an optional FILE positional.
fn parse_args() -> Cli {
    let mut cli = Cli {
        decode: false,
        ignore_garbage: false,
        wrap: 76,
        file: None,
    };

    let mut args = std::env::args_os().skip(1);
    #[allow(clippy::while_let_on_iterator)]
    while let Some(arg) = args.next() {
        let bytes = arg.as_encoded_bytes();
        if bytes == b"--" {
            if let Some(f) = args.next() {
                cli.file = Some(f.to_string_lossy().into_owned());
            }
            break;
        }
        if bytes.starts_with(b"--") {
            if bytes.starts_with(b"--wrap=") {
                let val = std::str::from_utf8(&bytes[7..]).unwrap_or("76");
                cli.wrap = val.parse().unwrap_or_else(|_| {
                    eprintln!("base64: invalid wrap size: '{}'", val);
                    process::exit(1);
                });
            } else {
                match bytes {
                    b"--decode" => cli.decode = true,
                    b"--ignore-garbage" => cli.ignore_garbage = true,
                    b"--wrap" => {
                        if let Some(v) = args.next() {
                            let s = v.to_string_lossy();
                            cli.wrap = s.parse().unwrap_or_else(|_| {
                                eprintln!("base64: invalid wrap size: '{}'", s);
                                process::exit(1);
                            });
                        } else {
                            eprintln!("base64: option '--wrap' requires an argument");
                            process::exit(1);
                        }
                    }
                    b"--help" => {
                        print!(
                            "Usage: base64 [OPTION]... [FILE]\n\
                            Base64 encode or decode FILE, or standard input, to standard output.\n\n\
                            With no FILE, or when FILE is -, read standard input.\n\n\
                            Mandatory arguments to long options are mandatory for short options too.\n\
                            \x20 -d, --decode          decode data\n\
                            \x20 -i, --ignore-garbage  when decoding, ignore non-alphabet characters\n\
                            \x20 -w, --wrap=COLS       wrap encoded lines after COLS character (default 76).\n\
                            \x20                         Use 0 to disable line wrapping\n\
                            \x20     --help             display this help and exit\n\
                            \x20     --version          output version information and exit\n\n\
                            The data are encoded as described for the base64 alphabet in RFC 4648.\n\
                            When decoding, the input may contain newlines in addition to the bytes of\n\
                            the formal base64 alphabet.  Use --ignore-garbage to attempt to recover\n\
                            from any other non-alphabet bytes in the encoded stream.\n"
                        );
                        process::exit(0);
                    }
                    b"--version" => {
                        println!("base64 (fcoreutils) {}", env!("CARGO_PKG_VERSION"));
                        process::exit(0);
                    }
                    _ => {
                        eprintln!("base64: unrecognized option '{}'", arg.to_string_lossy());
                        eprintln!("Try 'base64 --help' for more information.");
                        process::exit(1);
                    }
                }
            }
        } else if bytes.len() > 1 && bytes[0] == b'-' {
            let mut i = 1;
            while i < bytes.len() {
                match bytes[i] {
                    b'd' => cli.decode = true,
                    b'i' => cli.ignore_garbage = true,
                    b'w' => {
                        // -w can be followed by value in same arg (-w76) or next arg (-w 76)
                        if i + 1 < bytes.len() {
                            let val = std::str::from_utf8(&bytes[i + 1..]).unwrap_or("76");
                            cli.wrap = val.parse().unwrap_or_else(|_| {
                                eprintln!("base64: invalid wrap size: '{}'", val);
                                process::exit(1);
                            });
                            i = bytes.len();
                            continue;
                        } else if let Some(v) = args.next() {
                            let s = v.to_string_lossy();
                            cli.wrap = s.parse().unwrap_or_else(|_| {
                                eprintln!("base64: invalid wrap size: '{}'", s);
                                process::exit(1);
                            });
                        } else {
                            eprintln!("base64: option requires an argument -- 'w'");
                            process::exit(1);
                        }
                    }
                    _ => {
                        eprintln!("base64: invalid option -- '{}'", bytes[i] as char);
                        eprintln!("Try 'base64 --help' for more information.");
                        process::exit(1);
                    }
                }
                i += 1;
            }
        } else {
            cli.file = Some(arg.to_string_lossy().into_owned());
        }
    }

    cli
}

/// Raw fd stdout for zero-overhead writes on Unix.
/// Uses regular write(2) instead of vmsplice — all base64 encode/decode paths
/// write temporary buffers that are freed after write_all returns. vmsplice
/// without SPLICE_F_GIFT maps user pages into the pipe buffer without copying,
/// so freed/reused pages corrupt the data the reader sees. Regular write(2)
/// copies data into the kernel pipe buffer, making it safe for temporary buffers.
#[cfg(unix)]
#[inline]
fn raw_stdout() -> ManuallyDrop<std::fs::File> {
    unsafe { ManuallyDrop::new(std::fs::File::from_raw_fd(1)) }
}

fn main() {
    coreutils_rs::common::reset_sigpipe();

    enlarge_stdout_pipe();

    let cli = parse_args();

    let filename = cli.file.as_deref().unwrap_or("-");

    #[cfg(unix)]
    let result = {
        let mut raw = raw_stdout();
        if filename == "-" {
            process_stdin(&cli, &mut *raw)
        } else {
            process_file(filename, &cli, &mut *raw)
        }
    };
    #[cfg(not(unix))]
    let result = {
        let stdout = io::stdout();
        let mut out = io::BufWriter::with_capacity(8 * 1024 * 1024, stdout.lock());
        let r = if filename == "-" {
            process_stdin(&cli, &mut out)
        } else {
            process_file(filename, &cli, &mut out)
        };
        if let Err(e) = out.flush()
            && e.kind() != io::ErrorKind::BrokenPipe
        {
            eprintln!("base64: {}", io_error_msg(&e));
            process::exit(1);
        }
        r
    };

    if let Err(e) = result {
        if e.kind() == io::ErrorKind::BrokenPipe {
            process::exit(0);
        }
        // GNU base64 prints "base64: invalid input" without the filename
        // for decode errors (InvalidData), but includes the filename for
        // I/O errors (file not found, permission denied, etc.).
        if e.kind() == io::ErrorKind::InvalidData {
            eprintln!("base64: {}", io_error_msg(&e));
        } else if filename != "-" {
            eprintln!("base64: {}: {}", filename, io_error_msg(&e));
        } else {
            eprintln!("base64: {}", io_error_msg(&e));
        }
        process::exit(1);
    }
}

fn process_stdin(cli: &Cli, out: &mut impl Write) -> io::Result<()> {
    if cli.decode {
        #[cfg(unix)]
        if let Some(mmap) = try_mmap_stdin(0) {
            return b64::decode_to_writer(&mmap, cli.ignore_garbage, out);
        }

        #[cfg(target_os = "linux")]
        return b64::decode_stream(&mut RawStdin, cli.ignore_garbage, out);
        #[cfg(not(target_os = "linux"))]
        {
            let stdin = io::stdin();
            let mut reader = stdin.lock();
            return b64::decode_stream(&mut reader, cli.ignore_garbage, out);
        }
    }

    #[cfg(unix)]
    if let Some(mmap) = try_mmap_stdin(0) {
        return b64::encode_to_writer(&mmap, cli.wrap, out);
    }

    #[cfg(target_os = "linux")]
    return b64::encode_stream(&mut RawStdin, cli.wrap, out);
    #[cfg(not(target_os = "linux"))]
    {
        let stdin = io::stdin();
        let mut reader = stdin.lock();
        b64::encode_stream(&mut reader, cli.wrap, out)
    }
}

fn process_file(filename: &str, cli: &Cli, out: &mut impl Write) -> io::Result<()> {
    // Use read_file (read() for <1MB, mmap for larger) for both encode and decode.
    // For encode: avoids streaming path's 28MB buffer allocation (6146 page faults).
    // For decode: read() for small files avoids mmap setup/teardown overhead.
    let data = read_file(Path::new(filename))?;
    if cli.decode {
        b64::decode_to_writer(&data, cli.ignore_garbage, out)
    } else {
        b64::encode_to_writer(&data, cli.wrap, out)
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
        path.push("fbase64");
        Command::new(path)
    }
    #[test]
    fn test_base64_encode() {
        let mut child = cmd()
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .spawn()
            .unwrap();
        child.stdin.take().unwrap().write_all(b"Hello").unwrap();
        let output = child.wait_with_output().unwrap();
        assert!(output.status.success());
        let stdout = String::from_utf8_lossy(&output.stdout);
        assert!(stdout.contains("SGVsbG8="));
    }

    #[test]
    fn test_base64_decode() {
        let mut child = cmd()
            .arg("-d")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .spawn()
            .unwrap();
        child
            .stdin
            .take()
            .unwrap()
            .write_all(b"SGVsbG8=\n")
            .unwrap();
        let output = child.wait_with_output().unwrap();
        assert!(output.status.success());
        assert_eq!(output.stdout, b"Hello");
    }

    #[test]
    fn test_base64_empty_input() {
        let mut child = cmd()
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .spawn()
            .unwrap();
        child.stdin.take().unwrap().write_all(b"").unwrap();
        let output = child.wait_with_output().unwrap();
        assert!(output.status.success());
        assert!(output.stdout.is_empty());
    }

    #[test]
    fn test_base64_roundtrip() {
        let input = b"The quick brown fox jumps over the lazy dog\n";
        let mut enc = cmd()
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .spawn()
            .unwrap();
        enc.stdin.take().unwrap().write_all(input).unwrap();
        let encoded = enc.wait_with_output().unwrap();
        assert!(encoded.status.success());

        let mut dec = cmd()
            .arg("-d")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .spawn()
            .unwrap();
        dec.stdin
            .take()
            .unwrap()
            .write_all(&encoded.stdout)
            .unwrap();
        let decoded = dec.wait_with_output().unwrap();
        assert!(decoded.status.success());
        assert_eq!(decoded.stdout, input);
    }

    #[test]
    fn test_base64_wrap_zero() {
        let mut child = cmd()
            .args(["-w", "0"])
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .spawn()
            .unwrap();
        child
            .stdin
            .take()
            .unwrap()
            .write_all(b"Hello, World! This is a longer test input.")
            .unwrap();
        let output = child.wait_with_output().unwrap();
        assert!(output.status.success());
        let stdout = String::from_utf8_lossy(&output.stdout);
        assert_eq!(stdout.lines().count(), 1, "no wrapping with -w 0");
    }

    #[test]
    fn test_base64_wrap_custom() {
        let mut child = cmd()
            .args(["-w", "20"])
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .spawn()
            .unwrap();
        child
            .stdin
            .take()
            .unwrap()
            .write_all(b"Hello, World! This is a longer test input.")
            .unwrap();
        let output = child.wait_with_output().unwrap();
        assert!(output.status.success());
        let stdout = String::from_utf8_lossy(&output.stdout);
        for line in stdout.lines() {
            assert!(line.len() <= 20, "line too long: {}", line);
        }
    }

    #[test]
    fn test_base64_decode_invalid() {
        let mut child = cmd()
            .arg("-d")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .unwrap();
        child
            .stdin
            .take()
            .unwrap()
            .write_all(b"!!!invalid!!!\n")
            .unwrap();
        let output = child.wait_with_output().unwrap();
        assert!(!output.status.success());
    }

    #[test]
    fn test_base64_ignore_garbage() {
        let mut child = cmd()
            .args(["-d", "-i"])
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .spawn()
            .unwrap();
        child
            .stdin
            .take()
            .unwrap()
            .write_all(b"SGVs!!bG8=\n")
            .unwrap();
        let output = child.wait_with_output().unwrap();
        assert!(output.status.success());
        assert_eq!(output.stdout, b"Hello");
    }

    #[test]
    fn test_base64_binary_data() {
        let data: Vec<u8> = (0..=255).collect();
        let mut enc = cmd()
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .spawn()
            .unwrap();
        enc.stdin.take().unwrap().write_all(&data).unwrap();
        let encoded = enc.wait_with_output().unwrap();
        assert!(encoded.status.success());

        let mut dec = cmd()
            .arg("-d")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .spawn()
            .unwrap();
        dec.stdin
            .take()
            .unwrap()
            .write_all(&encoded.stdout)
            .unwrap();
        let decoded = dec.wait_with_output().unwrap();
        assert!(decoded.status.success());
        assert_eq!(decoded.stdout, data);
    }

    #[test]
    fn test_base64_file_input() {
        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join("test.txt");
        std::fs::write(&file, "Hello").unwrap();
        let output = cmd().arg(file.to_str().unwrap()).output().unwrap();
        assert!(output.status.success());
        let stdout = String::from_utf8_lossy(&output.stdout);
        assert!(stdout.trim().contains("SGVsbG8="));
    }

    #[test]
    fn test_base64_invalid_option() {
        let output = cmd().arg("--invalid").output().unwrap();
        assert!(!output.status.success());
    }

    #[test]
    fn test_base64_known_vectors() {
        // RFC 4648 test vectors
        let test_cases: &[(&[u8], &str)] = &[
            (b"", ""),
            (b"f", "Zg=="),
            (b"fo", "Zm8="),
            (b"foo", "Zm9v"),
            (b"foob", "Zm9vYg=="),
            (b"fooba", "Zm9vYmE="),
            (b"foobar", "Zm9vYmFy"),
        ];
        for (input, expected) in test_cases {
            let mut child = cmd()
                .stdin(Stdio::piped())
                .stdout(Stdio::piped())
                .spawn()
                .unwrap();
            child.stdin.take().unwrap().write_all(input).unwrap();
            let output = child.wait_with_output().unwrap();
            assert!(output.status.success());
            assert_eq!(
                String::from_utf8_lossy(&output.stdout).trim(),
                *expected,
                "mismatch for input {:?}",
                String::from_utf8_lossy(input)
            );
        }
    }
}
