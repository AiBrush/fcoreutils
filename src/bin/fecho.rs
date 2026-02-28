use std::io::{self, Write};
use std::process;

use coreutils_rs::common::reset_sigpipe;
use coreutils_rs::echo::{echo_output, parse_echo_args};

fn main() {
    reset_sigpipe();

    let args: Vec<String> = std::env::args().skip(1).collect();
    let (config, text_args) = parse_echo_args(&args);

    let stdout = io::stdout();
    let mut out = stdout.lock();

    // Fast path: no escape interpretation — write args directly to stdout
    // avoiding intermediate Vec allocation entirely.
    if !config.interpret_escapes {
        let result = (|| -> io::Result<()> {
            for (i, arg) in text_args.iter().enumerate() {
                if i > 0 {
                    out.write_all(b" ")?;
                }
                out.write_all(arg.as_bytes())?;
            }
            if config.trailing_newline {
                out.write_all(b"\n")?;
            }
            Ok(())
        })();
        if let Err(e) = result {
            if e.kind() == io::ErrorKind::BrokenPipe {
                process::exit(0);
            }
            eprintln!("echo: write error: {}", e);
            process::exit(1);
        }
        return;
    }

    // Slow path: escape interpretation needed
    let output = echo_output(text_args, &config);
    if let Err(e) = out.write_all(&output) {
        if e.kind() == io::ErrorKind::BrokenPipe {
            process::exit(0);
        }
        eprintln!("echo: write error: {}", e);
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
        path.push("fecho");
        Command::new(path)
    }

    #[test]
    fn test_cmd_echo_simple() {
        let output = cmd().args(["hello", "world"]).output().unwrap();
        assert!(output.status.success());
        assert_eq!(output.stdout, b"hello world\n");
    }

    #[test]
    fn test_cmd_echo_no_newline() {
        let output = cmd().args(["-n", "hello"]).output().unwrap();
        assert!(output.status.success());
        assert_eq!(output.stdout, b"hello");
    }

    #[test]
    fn test_cmd_echo_escape_tab_newline() {
        let output = cmd().args(["-e", "a\\tb\\n"]).output().unwrap();
        assert!(output.status.success());
        assert_eq!(output.stdout, b"a\tb\n\n");
    }

    #[test]
    fn test_cmd_echo_escape_c() {
        let output = cmd().args(["-e", "hello\\cworld"]).output().unwrap();
        assert!(output.status.success());
        assert_eq!(output.stdout, b"hello");
    }

    #[test]
    fn test_cmd_echo_octal() {
        let output = cmd().args(["-ne", "\\0101"]).output().unwrap();
        assert!(output.status.success());
        assert_eq!(output.stdout, b"A");
    }

    #[test]
    fn test_cmd_echo_hex() {
        let output = cmd().args(["-ne", "\\x41"]).output().unwrap();
        assert!(output.status.success());
        assert_eq!(output.stdout, b"A");
    }

    #[test]
    fn test_cmd_echo_no_args() {
        let output = cmd().output().unwrap();
        assert!(output.status.success());
        assert_eq!(output.stdout, b"\n");
    }

    #[test]
    fn test_cmd_invalid_flag_is_text() {
        let output = cmd().args(["-z", "hello"]).output().unwrap();
        assert!(output.status.success());
        assert_eq!(output.stdout, b"-z hello\n");
    }

    #[test]
    fn test_echo_matches_gnu() {
        // Compare basic output with GNU echo
        let gnu = Command::new("echo").args(["hello", "world"]).output();
        if let Ok(gnu) = gnu {
            let ours = cmd().args(["hello", "world"]).output().unwrap();
            assert_eq!(ours.stdout, gnu.stdout, "Output mismatch with GNU echo");
            assert_eq!(ours.status.code(), gnu.status.code(), "Exit code mismatch");
        }
    }

    #[test]
    fn test_echo_backslash_n() {
        let output = cmd().args(["-e", "a\\nb"]).output().unwrap();
        assert!(output.status.success());
        assert_eq!(output.stdout, b"a\nb\n");
    }

    #[test]
    fn test_echo_backslash_t() {
        let output = cmd().args(["-e", "a\\tb"]).output().unwrap();
        assert!(output.status.success());
        assert_eq!(output.stdout, b"a\tb\n");
    }

    #[test]
    fn test_echo_backslash_backslash() {
        let output = cmd().args(["-e", "a\\\\b"]).output().unwrap();
        assert!(output.status.success());
        assert_eq!(output.stdout, b"a\\b\n");
    }

    #[test]
    fn test_echo_disable_escape() {
        let output = cmd().args(["-E", "a\\nb"]).output().unwrap();
        assert!(output.status.success());
        assert_eq!(output.stdout, b"a\\nb\n");
    }

    #[test]
    fn test_echo_n_and_e() {
        let output = cmd().args(["-ne", "hello\\n"]).output().unwrap();
        assert!(output.status.success());
        assert_eq!(output.stdout, b"hello\n");
    }

    #[test]
    fn test_echo_empty_string_arg() {
        let output = cmd().arg("").output().unwrap();
        assert!(output.status.success());
        assert_eq!(output.stdout, b"\n");
    }

    #[test]
    fn test_echo_multiple_empty_args() {
        let output = cmd().args(["", "", ""]).output().unwrap();
        assert!(output.status.success());
        assert_eq!(output.stdout, b"  \n");
    }

    #[test]
    fn test_echo_special_chars() {
        let output = cmd().args(["hello!", "@#$%"]).output().unwrap();
        assert!(output.status.success());
        assert_eq!(output.stdout, b"hello! @#$%\n");
    }

    #[test]
    fn test_echo_exit_code() {
        let output = cmd().arg("test").output().unwrap();
        assert_eq!(output.status.code(), Some(0));
    }

    #[test]
    fn test_echo_dash_only() {
        // A bare "-" should be printed as text
        let output = cmd().arg("-").output().unwrap();
        assert!(output.status.success());
        assert_eq!(output.stdout, b"-\n");
    }
}
