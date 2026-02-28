use std::process;

use coreutils_rs::common::reset_sigpipe;
use coreutils_rs::dd::{self, DdConfig};

fn main() {
    reset_sigpipe();

    let args: Vec<String> = std::env::args().skip(1).collect();

    // Handle --help, --version, and strip leading '--' separator
    let mut operand_args = Vec::new();
    let mut saw_separator = false;
    for arg in &args {
        if saw_separator {
            operand_args.push(arg.clone());
            continue;
        }
        match arg.as_str() {
            "--help" => {
                dd::print_help();
                process::exit(0);
            }
            "--version" => {
                dd::print_version();
                process::exit(0);
            }
            "--" => {
                saw_separator = true;
            }
            _ => operand_args.push(arg.clone()),
        }
    }

    let config: DdConfig = match dd::parse_dd_args(&operand_args) {
        Ok(c) => c,
        Err(e) => {
            eprintln!("dd: {}", e);
            process::exit(1);
        }
    };

    match dd::dd_copy(&config) {
        Ok(_) => {}
        Err(e) => {
            eprintln!("dd: {}", e);
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
        path.push("fdd");
        Command::new(path)
    }

    #[test]
    fn test_dd_help() {
        let output = cmd().arg("--help").output().unwrap();
        assert!(output.status.success());
        // dd outputs help to stderr (GNU compatible)
        assert!(String::from_utf8_lossy(&output.stderr).contains("Usage"));
    }

    #[test]
    fn test_dd_version() {
        let output = cmd().arg("--version").output().unwrap();
        assert!(output.status.success());
        // dd outputs version to stderr (GNU compatible)
        assert!(String::from_utf8_lossy(&output.stderr).contains("fcoreutils"));
    }

    #[test]
    fn test_dd_stdin_stdout() {
        use std::io::Write;
        use std::process::Stdio;
        let mut child = cmd()
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .unwrap();
        child
            .stdin
            .take()
            .unwrap()
            .write_all(b"hello world\n")
            .unwrap();
        let output = child.wait_with_output().unwrap();
        assert!(output.status.success());
        assert_eq!(output.stdout, b"hello world\n");
    }

    #[test]
    fn test_dd_if_of() {
        let dir = tempfile::tempdir().unwrap();
        let src = dir.path().join("input.dat");
        let dst = dir.path().join("output.dat");
        std::fs::write(&src, "test data\n").unwrap();
        let output = cmd()
            .arg(format!("if={}", src.display()))
            .arg(format!("of={}", dst.display()))
            .output()
            .unwrap();
        assert!(output.status.success());
        assert_eq!(std::fs::read_to_string(&dst).unwrap(), "test data\n");
    }

    #[test]
    fn test_dd_count() {
        let dir = tempfile::tempdir().unwrap();
        let src = dir.path().join("input.dat");
        let dst = dir.path().join("output.dat");
        std::fs::write(&src, "abcdefghij").unwrap();
        let output = cmd()
            .arg(format!("if={}", src.display()))
            .arg(format!("of={}", dst.display()))
            .arg("bs=1")
            .arg("count=5")
            .output()
            .unwrap();
        assert!(output.status.success());
        assert_eq!(std::fs::read_to_string(&dst).unwrap(), "abcde");
    }

    #[test]
    fn test_dd_skip() {
        let dir = tempfile::tempdir().unwrap();
        let src = dir.path().join("input.dat");
        let dst = dir.path().join("output.dat");
        std::fs::write(&src, "abcdefghij").unwrap();
        let output = cmd()
            .arg(format!("if={}", src.display()))
            .arg(format!("of={}", dst.display()))
            .arg("bs=1")
            .arg("skip=5")
            .output()
            .unwrap();
        assert!(output.status.success());
        assert_eq!(std::fs::read_to_string(&dst).unwrap(), "fghij");
    }

    #[test]
    fn test_dd_conv_ucase() {
        use std::io::Write;
        use std::process::Stdio;
        let mut child = cmd()
            .arg("conv=ucase")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .unwrap();
        child
            .stdin
            .take()
            .unwrap()
            .write_all(b"hello world\n")
            .unwrap();
        let output = child.wait_with_output().unwrap();
        assert!(output.status.success());
        assert_eq!(output.stdout, b"HELLO WORLD\n");
    }

    #[test]
    fn test_dd_conv_lcase() {
        use std::io::Write;
        use std::process::Stdio;
        let mut child = cmd()
            .arg("conv=lcase")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .unwrap();
        child
            .stdin
            .take()
            .unwrap()
            .write_all(b"HELLO WORLD\n")
            .unwrap();
        let output = child.wait_with_output().unwrap();
        assert!(output.status.success());
        assert_eq!(output.stdout, b"hello world\n");
    }

    #[test]
    fn test_dd_status_none() {
        use std::io::Write;
        use std::process::Stdio;
        let mut child = cmd()
            .arg("status=none")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .unwrap();
        child.stdin.take().unwrap().write_all(b"data\n").unwrap();
        let output = child.wait_with_output().unwrap();
        assert!(output.status.success());
        // status=none suppresses the record summary on stderr
        assert!(output.stderr.is_empty());
    }

    #[test]
    fn test_dd_empty_input() {
        use std::io::Write;
        use std::process::Stdio;
        let mut child = cmd()
            .arg("status=none")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .unwrap();
        child.stdin.take().unwrap().write_all(b"").unwrap();
        let output = child.wait_with_output().unwrap();
        assert!(output.status.success());
        assert!(output.stdout.is_empty());
    }

    #[test]
    fn test_dd_bs_multiplier() {
        let dir = tempfile::tempdir().unwrap();
        let src = dir.path().join("input.dat");
        let dst = dir.path().join("output.dat");
        let data = vec![0xABu8; 1024];
        std::fs::write(&src, &data).unwrap();
        let output = cmd()
            .arg(format!("if={}", src.display()))
            .arg(format!("of={}", dst.display()))
            .arg("bs=512")
            .arg("count=1")
            .output()
            .unwrap();
        assert!(output.status.success());
        assert_eq!(std::fs::read(&dst).unwrap().len(), 512);
    }

    #[test]
    fn test_dd_invalid_arg() {
        let output = cmd().arg("invalid=option").output().unwrap();
        assert!(!output.status.success());
    }
}
