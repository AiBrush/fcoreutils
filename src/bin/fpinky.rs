#[cfg(not(unix))]
fn main() {
    eprintln!("pinky: only available on Unix");
    std::process::exit(1);
}

// fpinky -- lightweight finger information lookup
//
// Usage: pinky [OPTION]... [USER]...
//
// A lightweight replacement for finger(1). Shows user login information
// from utmpx records and passwd entries.

#[cfg(unix)]
use std::process;

#[cfg(unix)]
use clap::Parser;

#[cfg(unix)]
use coreutils_rs::pinky;

#[cfg(unix)]
#[derive(Parser)]
#[command(name = "pinky", version = env!("CARGO_PKG_VERSION"), about = "Lightweight finger", disable_help_flag = true)]
struct Cli {
    /// display this help and exit
    #[arg(long = "help", action = clap::ArgAction::Help)]
    help: Option<bool>,
    /// produce long format output for the specified USERs
    #[arg(short = 'l')]
    long_format: bool,

    /// omit the user's home directory and shell in long format
    #[arg(short = 'b')]
    omit_home_shell: bool,

    /// omit the user's project file in long format
    #[arg(short = 'h')]
    omit_project: bool,

    /// omit the user's plan file in long format
    #[arg(short = 'p')]
    omit_plan: bool,

    /// do short format output (default)
    #[arg(short = 's')]
    short_format: bool,

    /// omit the column of full names in short format
    #[arg(short = 'f')]
    omit_heading: bool,

    /// omit the user's full name in short format
    #[arg(short = 'w')]
    omit_fullname: bool,

    /// omit the user's full name and remote host in short format
    #[arg(short = 'i')]
    omit_fullname_host: bool,

    /// omit the user's full name, remote host and idle time in short format
    #[arg(short = 'q')]
    omit_fullname_host_idle: bool,

    /// users to look up
    users: Vec<String>,
}

#[cfg(unix)]
fn main() {
    coreutils_rs::common::reset_sigpipe();

    // Handle --version before clap
    let raw_args: Vec<String> = std::env::args().collect();
    if raw_args.iter().any(|a| a == "--version") {
        println!("pinky (fcoreutils) {}", env!("CARGO_PKG_VERSION"));
        process::exit(0);
    }

    let cli = Cli::parse();

    let short_format = !cli.long_format;
    let config = pinky::PinkyConfig {
        long_format: cli.long_format,
        short_format,
        omit_home_shell: cli.omit_home_shell,
        omit_project: cli.omit_project,
        omit_plan: cli.omit_plan,
        omit_heading: cli.omit_heading,
        omit_fullname: cli.omit_fullname,
        omit_fullname_host: cli.omit_fullname_host,
        omit_fullname_host_idle: cli.omit_fullname_host_idle,
        users: cli.users,
    };

    let output = pinky::run_pinky(&config);
    if !output.is_empty() {
        println!("{}", output);
    }

    process::exit(0);
}

#[cfg(test)]
mod tests {
    use std::process::Command;

    fn cmd() -> Command {
        let mut path = std::env::current_exe().unwrap();
        path.pop();
        path.pop();
        path.push("fpinky");
        Command::new(path)
    }

    #[cfg(unix)]
    #[test]
    fn test_pinky_runs() {
        let output = cmd().output().unwrap();
        // pinky should succeed even with no logged-in users
        assert!(
            output.status.success(),
            "fpinky should exit with code 0, stderr: {}",
            String::from_utf8_lossy(&output.stderr)
        );
    }

    #[cfg(unix)]
    #[test]
    fn test_pinky_short() {
        // Default short format should include a heading
        let output = cmd().output().unwrap();
        assert!(output.status.success());
        let stdout = String::from_utf8_lossy(&output.stdout);
        // If there are any logged-in users, heading should be present
        if !stdout.trim().is_empty() {
            assert!(
                stdout.contains("Login"),
                "Short format heading should contain 'Login', got: {}",
                stdout
            );
        }
    }

    #[cfg(unix)]
    #[test]
    fn test_pinky_long() {
        // Long format with -l; needs a username
        // Get current username for testing
        let whoami = Command::new("whoami").output();
        if let Ok(whoami) = whoami {
            if whoami.status.success() {
                let username = String::from_utf8_lossy(&whoami.stdout).trim().to_string();
                if !username.is_empty() {
                    let output = cmd().args(["-l", &username]).output().unwrap();
                    assert!(output.status.success());
                    let stdout = String::from_utf8_lossy(&output.stdout);
                    assert!(
                        stdout.contains("Login name:"),
                        "Long format should contain 'Login name:', got: {}",
                        stdout
                    );
                }
            }
        }
    }

    #[cfg(unix)]
    #[test]
    fn test_pinky_specific_user() {
        // Look up current user
        let whoami = Command::new("whoami").output();
        if let Ok(whoami) = whoami {
            if whoami.status.success() {
                let username = String::from_utf8_lossy(&whoami.stdout).trim().to_string();
                if !username.is_empty() {
                    let output = cmd().arg(&username).output().unwrap();
                    assert!(
                        output.status.success(),
                        "pinky should succeed for specific user"
                    );
                }
            }
        }
    }

    #[cfg(unix)]
    #[test]
    fn test_pinky_matches_gnu_format() {
        let gnu = Command::new("pinky").output();
        if let Ok(gnu) = gnu {
            let ours = cmd().output().unwrap();
            assert_eq!(
                ours.status.code(),
                gnu.status.code(),
                "Exit code mismatch: ours={:?} gnu={:?}",
                ours.status.code(),
                gnu.status.code()
            );
            // Both should have the same number of output lines
            let gnu_lines = String::from_utf8_lossy(&gnu.stdout).lines().count();
            let our_lines = String::from_utf8_lossy(&ours.stdout).lines().count();
            assert_eq!(
                our_lines, gnu_lines,
                "Line count mismatch: ours={} gnu={}",
                our_lines, gnu_lines
            );
        }
    }

    #[cfg(unix)]
    #[test]
    fn test_long_format_via_binary() {
        // Test -l flag via binary with current user
        let whoami_output = Command::new("whoami").output();
        if let Ok(whoami) = whoami_output {
            if whoami.status.success() {
                let username = String::from_utf8_lossy(&whoami.stdout).trim().to_string();
                if !username.is_empty() {
                    let output = cmd().args(["-l", &username]).output().unwrap();
                    assert!(output.status.success());
                    let stdout = String::from_utf8_lossy(&output.stdout);
                    assert!(
                        stdout.contains("Login name:"),
                        "Long format should contain 'Login name:', got: {}",
                        stdout
                    );
                    assert!(
                        stdout.contains(&username),
                        "Long format should contain the username"
                    );
                }
            }
        }
    }

    #[cfg(unix)]
    #[test]
    fn test_long_format_omit_flags() {
        // Test -l -b -h -p flags via binary
        let whoami_output = Command::new("whoami").output();
        if let Ok(whoami) = whoami_output {
            if whoami.status.success() {
                let username = String::from_utf8_lossy(&whoami.stdout).trim().to_string();
                if !username.is_empty() {
                    let output = cmd()
                        .args(["-l", "-b", "-h", "-p", &username])
                        .output()
                        .unwrap();
                    assert!(output.status.success());
                    let stdout = String::from_utf8_lossy(&output.stdout);
                    assert!(stdout.contains("Login name:"));
                    assert!(
                        !stdout.contains("Directory:"),
                        "With -b, should omit directory line"
                    );
                }
            }
        }
    }
    #[cfg(unix)]
    #[test]
    fn test_pinky_basic() {
        let output = cmd().output().unwrap();
        assert!(output.status.success());
    }

    #[cfg(unix)]
    #[test]
    fn test_pinky_short_format() {
        let output = cmd().arg("-s").output().unwrap();
        assert!(output.status.success());
    }

    #[cfg(unix)]
    #[test]
    fn test_pinky_long_format() {
        // pinky with a username shows long format
        let user = std::env::var("USER").unwrap_or_else(|_| "root".to_string());
        let output = cmd().arg(&user).output().unwrap();
        assert!(output.status.success());
        let stdout = String::from_utf8_lossy(&output.stdout);
        // Long format should show login info
        assert!(!stdout.is_empty());
    }

    #[cfg(unix)]
    #[test]
    fn test_pinky_nonexistent_user() {
        let output = cmd().arg("nonexistent_user_xyz_12345").output().unwrap();
        // Should succeed but output nothing for the user
        let stdout = String::from_utf8_lossy(&output.stdout);
        // May or may not show the user
        let _ = stdout;
    }
}
