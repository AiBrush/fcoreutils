#[cfg(not(unix))]
fn main() {
    eprintln!("who: only available on Unix");
    std::process::exit(1);
}

// fwho -- show who is logged on
//
// Usage: who [OPTION]... [ FILE | ARG1 ARG2 ]
//
// Reads utmpx records to display login information.

#[cfg(unix)]
use std::process;

#[cfg(unix)]
use coreutils_rs::who;

#[cfg(unix)]
const TOOL_NAME: &str = "who";
#[cfg(unix)]
const VERSION: &str = env!("CARGO_PKG_VERSION");

#[cfg(unix)]
fn print_help() {
    println!("Usage: {} [OPTION]... [ FILE | ARG1 ARG2 ]", TOOL_NAME);
    println!("Show who is logged on.");
    println!();
    println!("  -a, --all            same as -b -d --login -p -r -t -T -u");
    println!("  -b, --boot           time of last system boot");
    println!("  -d, --dead           print dead processes");
    println!("  -H, --heading        print line of column headings");
    println!("  -l, --login          print system login processes");
    println!("  -m                   only hostname and user associated with stdin");
    println!("  -p, --process        print active processes spawned by init");
    println!("  -q, --count          all login names and number of users logged on");
    println!("  -r, --runlevel       print current runlevel");
    println!("  -s, --short          print only name, line, and time (default)");
    println!("  -t, --time           print last system clock change");
    println!("  -T, -w, --mesg       add user's message status as +, - or ?");
    println!("  -u, --users          list users logged in");
    println!("      --ips            print ips instead of hostnames");
    println!("      --lookup         attempt to canonicalize hostnames via DNS");
    println!("      --help           display this help and exit");
    println!("      --version        output version information and exit");
    println!();
    println!(
        "If ARG1 ARG2 given (e.g. 'who am i'), print only the entry for the current terminal."
    );
}

#[cfg(unix)]
fn main() {
    coreutils_rs::common::reset_sigpipe();

    let mut config = who::WhoConfig::default();
    let mut positional: Vec<String> = Vec::new();

    for arg in std::env::args_os().skip(1) {
        let arg = arg.to_string_lossy();
        match arg.as_ref() {
            "--help" => {
                print_help();
                return;
            }
            "--version" => {
                println!("{} (fcoreutils) {}", TOOL_NAME, VERSION);
                return;
            }
            "-a" | "--all" => {
                config.show_all = true;
                config.apply_all();
            }
            "-b" | "--boot" => config.show_boot = true,
            "-d" | "--dead" => config.show_dead = true,
            "-H" | "--heading" => config.show_heading = true,
            "-l" | "--login" => config.show_login = true,
            "-m" => config.only_current = true,
            "-p" | "--process" => config.show_init_spawn = true,
            "-q" | "--count" => config.show_count = true,
            "-r" | "--runlevel" => config.show_runlevel = true,
            "-s" | "--short" => config.short_format = true,
            "-t" | "--time" => config.show_clock_change = true,
            "-T" | "-w" | "--mesg" => config.show_mesg = true,
            "-u" | "--users" => config.show_users = true,
            "--ips" => config.show_ips = true,
            "--lookup" => config.show_lookup = true,
            s if s.starts_with('-') && s.len() > 1 && !s.starts_with("--") => {
                for ch in s[1..].chars() {
                    match ch {
                        'a' => {
                            config.show_all = true;
                            config.apply_all();
                        }
                        'b' => config.show_boot = true,
                        'd' => config.show_dead = true,
                        'H' => config.show_heading = true,
                        'l' => config.show_login = true,
                        'm' => config.only_current = true,
                        'p' => config.show_init_spawn = true,
                        'q' => config.show_count = true,
                        'r' => config.show_runlevel = true,
                        's' => config.short_format = true,
                        't' => config.show_clock_change = true,
                        'T' | 'w' => config.show_mesg = true,
                        'u' => config.show_users = true,
                        _ => {
                            eprintln!("{}: invalid option -- '{}'", TOOL_NAME, ch);
                            eprintln!("Try '{} --help' for more information.", TOOL_NAME);
                            process::exit(1);
                        }
                    }
                }
            }
            _ => positional.push(arg.into_owned()),
        }
    }

    // GNU who allows 0, 1, or 2 operands but rejects 3+
    if positional.len() > 2 {
        eprintln!("{}: extra operand '{}'", TOOL_NAME, positional[2]);
        eprintln!("Try '{} --help' for more information.", TOOL_NAME);
        process::exit(1);
    }

    // Check for "who am i" / "who am I" pattern (exactly 2 extra args)
    if positional.len() == 2 {
        let a = positional[0].to_lowercase();
        let b = positional[1].to_lowercase();
        if a == "am" && b == "i" {
            config.am_i = true;
        }
    }

    let output = who::run_who(&config);
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
        path.push("fwho");
        Command::new(path)
    }

    #[cfg(unix)]
    #[test]
    fn test_who_runs() {
        let output = cmd().output().unwrap();
        // who should succeed even with no logged-in users
        assert!(
            output.status.success(),
            "fwho should exit with code 0, stderr: {}",
            String::from_utf8_lossy(&output.stderr)
        );
    }

    #[cfg(unix)]
    #[test]
    fn test_who_heading() {
        let output = cmd().arg("-H").output().unwrap();
        assert!(output.status.success());
        let stdout = String::from_utf8_lossy(&output.stdout);
        // Heading line should contain NAME and LINE
        assert!(stdout.contains("NAME"), "Heading should contain NAME");
        assert!(stdout.contains("LINE"), "Heading should contain LINE");
        assert!(stdout.contains("TIME"), "Heading should contain TIME");
    }

    #[cfg(unix)]
    #[test]
    fn test_who_count() {
        let output = cmd().arg("-q").output().unwrap();
        assert!(output.status.success());
        let stdout = String::from_utf8_lossy(&output.stdout);
        // Count mode should show "# users=N"
        assert!(
            stdout.contains("# users="),
            "Count mode should show '# users=N', got: {}",
            stdout
        );
    }

    #[cfg(unix)]
    #[test]
    fn test_who_boot() {
        let output = cmd().arg("-b").output().unwrap();
        assert!(output.status.success());
        let stdout = String::from_utf8_lossy(&output.stdout);
        // Boot output may or may not have "system boot" depending on utmpx data
        // On systems with boot record, verify it contains "system boot"
        if !stdout.trim().is_empty() {
            assert!(
                stdout.contains("system boot"),
                "Boot output should contain 'system boot', got: {}",
                stdout
            );
        }
    }

    #[cfg(unix)]
    #[test]
    fn test_who_format_check() {
        // Verify that regular who output lines have reasonable formatting
        let output = cmd().output().unwrap();
        assert!(output.status.success());
        let stdout = String::from_utf8_lossy(&output.stdout);
        for line in stdout.lines() {
            if line.trim().is_empty() {
                continue;
            }
            // Each line should have at least a name and a timestamp portion
            // Timestamps match YYYY-MM-DD HH:MM
            let parts: Vec<&str> = line.split_whitespace().collect();
            assert!(
                parts.len() >= 3,
                "Output line should have at least 3 fields: '{}'",
                line
            );
        }
    }

    #[cfg(unix)]
    #[test]
    fn test_who_matches_gnu_format() {
        let gnu = Command::new("who").output();
        if let Ok(gnu) = gnu {
            let ours = cmd().output().unwrap();
            assert_eq!(
                ours.status.code(),
                gnu.status.code(),
                "Exit code mismatch: ours={:?} gnu={:?}",
                ours.status.code(),
                gnu.status.code()
            );
            // Both should have the same number of output lines (same logged-in users)
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
    fn test_who_basic() {
        let output = cmd().output().unwrap();
        assert!(output.status.success());
    }

    #[cfg(unix)]
    #[test]
    fn test_who_count_exit_success() {
        let output = cmd().arg("-q").output().unwrap();
        assert!(output.status.success());
        let stdout = String::from_utf8_lossy(&output.stdout);
        // -q output should contain a count
        assert!(stdout.contains('#') || stdout.contains("="));
    }

    #[cfg(unix)]
    #[test]
    fn test_who_heading_long_flag() {
        let output = cmd().arg("--heading").output().unwrap();
        assert!(output.status.success());
        let stdout = String::from_utf8_lossy(&output.stdout);
        // Heading should contain column names like NAME
        assert!(stdout.contains("NAME") || stdout.is_empty());
    }

    #[cfg(unix)]
    #[test]
    fn test_who_boot_exit_success() {
        let output = cmd().arg("-b").output().unwrap();
        assert!(output.status.success());
    }

    #[cfg(unix)]
    #[test]
    fn test_who_am_i() {
        let output = cmd().args(["am", "i"]).output().unwrap();
        assert!(output.status.success());
    }
}
