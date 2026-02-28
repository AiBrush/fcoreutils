#[cfg(not(unix))]
fn main() {
    eprintln!("test: only available on Unix");
    std::process::exit(1);
}

#[cfg(unix)]
use std::process;

#[cfg(unix)]
use coreutils_rs::common::reset_sigpipe;
#[cfg(unix)]
use coreutils_rs::test_cmd;

#[cfg(unix)]
fn main() {
    reset_sigpipe();

    let all_args: Vec<String> = std::env::args().collect();
    let program = &all_args[0];

    // Determine if invoked as "[" (bracket mode).
    // Check if the binary name (last component of path) is "[".
    let invoked_as_bracket = std::path::Path::new(program)
        .file_name()
        .is_some_and(|name| name == "[");

    let args = if invoked_as_bracket {
        let rest = &all_args[1..];
        if rest.is_empty() || rest[rest.len() - 1] != "]" {
            eprintln!("[: missing ']'");
            process::exit(2);
        }
        // Strip the trailing "]"
        &rest[..rest.len() - 1]
    } else {
        &all_args[1..]
    };

    match test_cmd::evaluate(args) {
        Ok(true) => process::exit(0),
        Ok(false) => process::exit(1),
        Err(msg) => {
            eprintln!("{}", msg);
            process::exit(2);
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
        path.push("ftest");
        Command::new(path)
    }

    #[test]
    fn test_test_matches_gnu() {
        // Compare our ftest behavior with GNU test for basic cases
        let gnu = Command::new("test").args(["-d", "/tmp"]).status();
        if let Ok(gnu_status) = gnu {
            let our = cmd().args(["-d", "/tmp"]).status().unwrap();
            assert_eq!(
                our.code(),
                gnu_status.code(),
                "Exit code mismatch for: test -d /tmp"
            );
        }

        let gnu = Command::new("test")
            .args(["-e", "/nonexistent_xyz_123"])
            .status();
        if let Ok(gnu_status) = gnu {
            let our = cmd().args(["-e", "/nonexistent_xyz_123"]).status().unwrap();
            assert_eq!(
                our.code(),
                gnu_status.code(),
                "Exit code mismatch for: test -e /nonexistent_xyz_123"
            );
        }

        let gnu = Command::new("test").args(["hello", "=", "hello"]).status();
        if let Ok(gnu_status) = gnu {
            let our = cmd().args(["hello", "=", "hello"]).status().unwrap();
            assert_eq!(
                our.code(),
                gnu_status.code(),
                "Exit code mismatch for: test hello = hello"
            );
        }

        let gnu = Command::new("test").args(["5", "-lt", "10"]).status();
        if let Ok(gnu_status) = gnu {
            let our = cmd().args(["5", "-lt", "10"]).status().unwrap();
            assert_eq!(
                our.code(),
                gnu_status.code(),
                "Exit code mismatch for: test 5 -lt 10"
            );
        }

        // No arguments: should exit 1
        let gnu = Command::new("test").status();
        if let Ok(gnu_status) = gnu {
            let our = cmd().status().unwrap();
            assert_eq!(
                our.code(),
                gnu_status.code(),
                "Exit code mismatch for: test (no args)"
            );
        }
    }

    // Binary exit code test via command
    #[test]
    fn test_binary_exit_codes() {
        let status = cmd().args(["-d", "/tmp"]).status().unwrap();
        assert_eq!(status.code(), Some(0));

        let status = cmd().args(["-e", "/nonexistent_xyz_123"]).status().unwrap();
        assert_eq!(status.code(), Some(1));

        // No args => exit 1
        let status = cmd().status().unwrap();
        assert_eq!(status.code(), Some(1));
    }

    // Test bracket mode: last arg must be ]
    #[test]
    fn test_bracket_mode() {
        // The ftest binary itself doesn't require "]" unless invoked as "[".
        let status = cmd().args(["-d", "/tmp"]).status().unwrap();
        assert_eq!(status.code(), Some(0));

        // Verify that ftest with a single non-empty string arg exits 0
        let status = cmd().args(["hello"]).status().unwrap();
        assert_eq!(status.code(), Some(0));

        // Verify that ftest with a single empty string arg exits 1
        let status = cmd().args([""]).status().unwrap();
        assert_eq!(status.code(), Some(1));
    }
}
