// fkill -- send signals to processes
//
// Usage: kill [-s SIGNAL | -SIGNAL] PID...
//        kill -l [SIGNAL]...
//        kill -L

use std::process;

const TOOL_NAME: &str = "kill";
const VERSION: &str = env!("CARGO_PKG_VERSION");

/// All standard signal names indexed by signal number (1-based).
/// Index 0 is unused; signals[1] = "HUP", signals[15] = "TERM", etc.
const SIGNALS: [&str; 32] = [
    "",       // 0 (unused)
    "HUP",    // 1
    "INT",    // 2
    "QUIT",   // 3
    "ILL",    // 4
    "TRAP",   // 5
    "ABRT",   // 6
    "BUS",    // 7
    "FPE",    // 8
    "KILL",   // 9
    "USR1",   // 10
    "SEGV",   // 11
    "USR2",   // 12
    "PIPE",   // 13
    "ALRM",   // 14
    "TERM",   // 15
    "STKFLT", // 16
    "CHLD",   // 17
    "CONT",   // 18
    "STOP",   // 19
    "TSTP",   // 20
    "TTIN",   // 21
    "TTOU",   // 22
    "URG",    // 23
    "XCPU",   // 24
    "XFSZ",   // 25
    "VTALRM", // 26
    "PROF",   // 27
    "WINCH",  // 28
    "POLL",   // 29
    "PWR",    // 30
    "SYS",    // 31
];

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();

    if args.is_empty() {
        eprintln!("{}: not enough arguments", TOOL_NAME);
        eprintln!("Try '{} --help' for more information.", TOOL_NAME);
        process::exit(1);
    }

    let mut signal: i32 = 15; // SIGTERM default
    let mut pids: Vec<String> = Vec::new();
    let mut list_mode = false;
    let mut table_mode = false;
    let mut list_args: Vec<String> = Vec::new();
    let mut i = 0;

    while i < args.len() {
        let arg = &args[i];
        match arg.as_str() {
            "--help" => {
                print_help();
                return;
            }
            "--version" => {
                println!("{} (fcoreutils) {}", TOOL_NAME, VERSION);
                return;
            }
            "-l" | "--list" => {
                list_mode = true;
                // Remaining args are signal specs to convert
                i += 1;
                while i < args.len() {
                    list_args.push(args[i].clone());
                    i += 1;
                }
                break;
            }
            "-L" | "--table" => {
                table_mode = true;
                i += 1;
            }
            "-s" | "--signal" => {
                i += 1;
                if i >= args.len() {
                    eprintln!("{}: option requires an argument -- 's'", TOOL_NAME);
                    process::exit(1);
                }
                signal = parse_signal_or_die(&args[i]);
                i += 1;
            }
            "-n" => {
                i += 1;
                if i >= args.len() {
                    eprintln!("{}: option requires an argument -- 'n'", TOOL_NAME);
                    process::exit(1);
                }
                match args[i].parse::<i32>() {
                    Ok(n) => signal = n,
                    Err(_) => {
                        eprintln!("{}: invalid signal number: '{}'", TOOL_NAME, args[i]);
                        process::exit(1);
                    }
                }
                i += 1;
            }
            s if s.starts_with("--signal=") => {
                let val = &s["--signal=".len()..];
                signal = parse_signal_or_die(val);
                i += 1;
            }
            s if s.starts_with('-') && s.len() > 1 && !s.starts_with("--") => {
                let sig_str = &s[1..];
                // Could be a signal number or name
                if let Ok(n) = sig_str.parse::<i32>() {
                    signal = n;
                } else {
                    signal = name_to_signal(sig_str).unwrap_or_else(|| {
                        eprintln!("{}: unknown signal: {}", TOOL_NAME, sig_str);
                        process::exit(1);
                    });
                }
                i += 1;
            }
            _ => {
                pids.push(arg.clone());
                i += 1;
            }
        }
    }

    if table_mode {
        print_table();
        return;
    }

    if list_mode {
        if list_args.is_empty() {
            print_signals();
        } else {
            let mut had_error = false;
            for spec in &list_args {
                if let Ok(num) = spec.parse::<i32>() {
                    // Number → name (handle exit status: num > 128 → num - 128)
                    let signum = if num > 128 { num - 128 } else { num };
                    if signum >= 1 && signum <= 31 {
                        println!("{}", SIGNALS[signum as usize]);
                    } else {
                        eprintln!("{}: unknown signal: {}", TOOL_NAME, spec);
                        had_error = true;
                    }
                } else {
                    // Name → number
                    let upper = spec.to_uppercase();
                    let name = upper.strip_prefix("SIG").unwrap_or(&upper);
                    match name_to_signal(name) {
                        Some(n) => println!("{}", n),
                        None => {
                            eprintln!("{}: unknown signal: {}", TOOL_NAME, spec);
                            had_error = true;
                        }
                    }
                }
            }
            if had_error {
                process::exit(1);
            }
        }
        return;
    }

    if pids.is_empty() {
        eprintln!("{}: not enough arguments", TOOL_NAME);
        process::exit(1);
    }

    let mut had_error = false;
    for pid_str in &pids {
        match pid_str.parse::<i32>() {
            Ok(pid) => {
                if let Err(e) = send_signal(pid, signal) {
                    eprintln!(
                        "{}: sending signal to {} failed: {}",
                        TOOL_NAME, pid, e
                    );
                    had_error = true;
                }
            }
            Err(_) => {
                eprintln!("{}: failed to parse argument: '{}'", TOOL_NAME, pid_str);
                had_error = true;
            }
        }
    }

    if had_error {
        process::exit(1);
    }
}

fn parse_signal_or_die(s: &str) -> i32 {
    if let Ok(n) = s.parse::<i32>() {
        return n;
    }
    name_to_signal(s).unwrap_or_else(|| {
        eprintln!("{}: unknown signal: {}", TOOL_NAME, s);
        process::exit(1);
    })
}

fn name_to_signal(s: &str) -> Option<i32> {
    let upper = s.to_uppercase();
    let name = upper.strip_prefix("SIG").unwrap_or(&upper);
    for i in 1..SIGNALS.len() {
        if SIGNALS[i] == name {
            return Some(i as i32);
        }
    }
    // Aliases
    match name {
        "IOT" => Some(6),   // SIGIOT = SIGABRT
        "CLD" => Some(17),  // SIGCLD = SIGCHLD
        "IO" => Some(29),   // SIGIO = SIGPOLL
        _ => None,
    }
}

fn print_help() {
    println!("Usage: {} [-s SIGNAL | -SIGNAL] PID...", TOOL_NAME);
    println!("  or:  {} -l [SIGNAL]...", TOOL_NAME);
    println!("  or:  {} -L", TOOL_NAME);
    println!("Send signals to processes, or list signals.");
    println!();
    println!("Options:");
    println!("  -s, --signal SIGNAL   specify the signal to send");
    println!("  -l, --list [SIGNAL]   list signal names, or convert to/from names");
    println!("  -L, --table           list signal names in a nice table");
    println!("  -n SIGNUM             send signal specified by number");
    println!("      --help            display this help and exit");
    println!("      --version         output version information and exit");
    println!();
    println!("SIGNAL may be a signal name like 'HUP', or a signal number like '1'.");
    println!("PID is an integer; if negative it identifies a process group.");
}

/// Print all signal names space-separated (GNU `kill -l` format).
fn print_signals() {
    let names: Vec<&str> = SIGNALS[1..].to_vec();
    let mut line = String::new();
    for name in &names {
        if !line.is_empty() {
            // Check if adding this name would exceed ~79 columns
            if line.len() + 1 + name.len() > 79 {
                println!("{}", line);
                line.clear();
            } else {
                line.push(' ');
            }
        }
        line.push_str(name);
    }
    if !line.is_empty() {
        println!("{}", line);
    }
}

/// Print signal table (GNU `kill -L` format).
fn print_table() {
    for i in 1..=31_i32 {
        let name = SIGNALS[i as usize];
        print!("{:2} {:<8}", i, name);
        if i % 7 == 0 {
            println!();
        }
    }
    // Final newline if last row wasn't complete
    if 31 % 7 != 0 {
        println!();
    }
}

#[cfg(unix)]
fn send_signal(pid: i32, signal: i32) -> Result<(), std::io::Error> {
    let ret = unsafe { libc::kill(pid, signal) };
    if ret != 0 {
        Err(std::io::Error::last_os_error())
    } else {
        Ok(())
    }
}

#[cfg(windows)]
fn send_signal(pid: i32, _signal: i32) -> Result<(), std::io::Error> {
    let output = std::process::Command::new("taskkill")
        .args(["/F", "/PID", &pid.to_string()])
        .output()?;
    if output.status.success() {
        Ok(())
    } else {
        Err(std::io::Error::other(
            String::from_utf8_lossy(&output.stderr).trim().to_string(),
        ))
    }
}

#[cfg(test)]
mod tests {
    use std::process::Command;

    fn cmd() -> Command {
        let mut path = std::env::current_exe().unwrap();
        path.pop();
        path.pop();
        path.push("fkill");
        Command::new(path)
    }

    #[test]
    fn test_help() {
        let output = cmd().arg("--help").output().unwrap();
        assert_eq!(output.status.code(), Some(0));
        let stdout = String::from_utf8_lossy(&output.stdout);
        assert!(stdout.contains("Usage:"));
        assert!(stdout.contains("SIGNAL"));
    }

    #[test]
    fn test_version() {
        let output = cmd().arg("--version").output().unwrap();
        assert_eq!(output.status.code(), Some(0));
        let stdout = String::from_utf8_lossy(&output.stdout);
        assert!(stdout.contains("(fcoreutils)"));
    }

    #[test]
    fn test_list_signals() {
        let output = cmd().arg("-l").output().unwrap();
        assert_eq!(output.status.code(), Some(0));
        let stdout = String::from_utf8_lossy(&output.stdout);
        assert!(stdout.contains("HUP"));
        assert!(stdout.contains("TERM"));
        assert!(stdout.contains("KILL"));
    }

    #[test]
    fn test_list_number_to_name() {
        let output = cmd().args(["-l", "15"]).output().unwrap();
        assert_eq!(output.status.code(), Some(0));
        let stdout = String::from_utf8_lossy(&output.stdout);
        assert_eq!(stdout.trim(), "TERM");
    }

    #[test]
    fn test_list_name_to_number() {
        let output = cmd().args(["-l", "TERM"]).output().unwrap();
        assert_eq!(output.status.code(), Some(0));
        let stdout = String::from_utf8_lossy(&output.stdout);
        assert_eq!(stdout.trim(), "15");
    }

    #[test]
    fn test_list_exit_status_conversion() {
        // 137 = 128 + 9 (KILL)
        let output = cmd().args(["-l", "137"]).output().unwrap();
        assert_eq!(output.status.code(), Some(0));
        let stdout = String::from_utf8_lossy(&output.stdout);
        assert_eq!(stdout.trim(), "KILL");
    }

    #[test]
    fn test_table() {
        let output = cmd().arg("-L").output().unwrap();
        assert_eq!(output.status.code(), Some(0));
        let stdout = String::from_utf8_lossy(&output.stdout);
        assert!(stdout.contains(" 1 HUP"));
        assert!(stdout.contains("15 TERM"));
    }

    #[test]
    fn test_no_args_error() {
        let output = cmd().output().unwrap();
        assert_ne!(output.status.code(), Some(0));
        let stderr = String::from_utf8_lossy(&output.stderr);
        assert!(stderr.contains("not enough arguments"));
    }

    #[test]
    #[cfg(unix)]
    fn test_send_signal_to_self() {
        // Send signal 0 (no-op, just check process exists) to our own PID
        let pid = std::process::id().to_string();
        let output = cmd().args(["-0", &pid]).output().unwrap();
        assert_eq!(output.status.code(), Some(0));
    }

    #[test]
    #[cfg(unix)]
    fn test_send_signal_nonexistent_pid() {
        // PID 99999999 is very unlikely to exist
        let output = cmd().args(["99999999"]).output().unwrap();
        assert_ne!(output.status.code(), Some(0));
        let stderr = String::from_utf8_lossy(&output.stderr);
        assert!(stderr.contains("sending signal"));
    }
}
