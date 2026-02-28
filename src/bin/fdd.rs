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
}
