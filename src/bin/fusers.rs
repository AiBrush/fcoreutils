#[cfg(not(unix))]
fn main() {
    eprintln!("users: only available on Unix");
    std::process::exit(1);
}

// fusers -- print the user names of users currently logged in
//
// Usage: users [FILE]
//
// Prints a space-separated sorted list of login names from utmpx.

#[cfg(unix)]
fn main() {
    coreutils_rs::common::reset_sigpipe();

    let args: Vec<String> = std::env::args().skip(1).collect();

    for arg in &args {
        match arg.as_str() {
            "--help" => {
                println!("Usage: users [OPTION]... [FILE]");
                println!("Output who is currently logged in according to FILE.");
                println!("If FILE is not specified, use /var/run/utmp.");
                println!();
                println!("      --help     display this help and exit");
                println!("      --version  output version information and exit");
                return;
            }
            "--version" => {
                println!("users (fcoreutils) {}", env!("CARGO_PKG_VERSION"));
                return;
            }
            _ => {}
        }
    }

    // Find the optional file argument (non-option arg)
    let file_arg = args
        .iter()
        .find(|a| !a.starts_with("--"))
        .map(|s| s.as_str());
    let users = coreutils_rs::users::get_users_from(file_arg);
    let output = coreutils_rs::users::format_users(&users);
    if !output.is_empty() {
        println!("{}", output);
    }
}

#[cfg(test)]
mod tests {
    use std::process::Command;

    fn cmd() -> Command {
        let mut path = std::env::current_exe().unwrap();
        path.pop();
        path.pop();
        path.push("fusers");
        Command::new(path)
    }

    #[test]
    fn test_users_runs() {
        let output = cmd().output().unwrap();
        assert!(
            output.status.success(),
            "fusers should exit with code 0, stderr: {}",
            String::from_utf8_lossy(&output.stderr)
        );
    }

    #[test]
    fn test_users_format() {
        let output = cmd().output().unwrap();
        assert!(output.status.success());
        let stdout = String::from_utf8_lossy(&output.stdout);
        // Output should be at most one line (may be empty if no users logged in)
        let lines: Vec<&str> = stdout.lines().collect();
        assert!(
            lines.len() <= 1,
            "users output should be a single line, got {} lines",
            lines.len()
        );
        // If there is output, names should be space-separated (no tabs, no commas)
        if let Some(line) = lines.first() {
            assert!(!line.contains('\t'), "users output should not contain tabs");
            assert!(
                !line.contains(','),
                "users output should not contain commas"
            );
        }
    }

    #[test]
    fn test_users_matches_gnu() {
        let gnu = Command::new("users").output();
        if let Ok(gnu) = gnu {
            let ours = cmd().output().unwrap();
            assert_eq!(
                ours.status.code(),
                gnu.status.code(),
                "Exit code mismatch: ours={:?} gnu={:?}",
                ours.status.code(),
                gnu.status.code()
            );
            // Both should produce the same user list
            let gnu_stdout = String::from_utf8_lossy(&gnu.stdout);
            let our_stdout = String::from_utf8_lossy(&ours.stdout);
            assert_eq!(
                our_stdout.trim(),
                gnu_stdout.trim(),
                "Output mismatch: ours='{}' gnu='{}'",
                our_stdout.trim(),
                gnu_stdout.trim()
            );
        }
    }

    #[test]
    fn test_users_basic() {
        let output = cmd().output().unwrap();
        assert!(output.status.success());
        // Output may be empty if no utmp entries, but should not error
    }

    #[test]
    fn test_users_single_line() {
        let output = cmd().output().unwrap();
        assert!(output.status.success());
        let stdout = String::from_utf8_lossy(&output.stdout);
        // Should be at most one line
        assert!(stdout.lines().count() <= 1);
    }
}
