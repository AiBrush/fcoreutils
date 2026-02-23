use std::process;

const TOOL_NAME: &str = "kill";
const VERSION: &str = env!("CARGO_PKG_VERSION");

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();

    if args.is_empty() || args.iter().any(|a| a == "--help") {
        eprintln!("Usage: kill [-s SIGNAL | -SIGNAL] PID...");
        eprintln!("       kill -l [SIGNAL]");
        process::exit(0);
    }

    if args.iter().any(|a| a == "--version") {
        println!("{} (fcoreutils) {}", TOOL_NAME, VERSION);
        process::exit(0);
    }

    // Parse signal and PIDs
    let mut signal: i32 = 15; // SIGTERM
    let mut pids: Vec<i32> = Vec::new();
    let mut list_signals = false;
    let mut i = 0;

    while i < args.len() {
        let arg = &args[i];
        if arg == "-l" || arg == "--list" {
            list_signals = true;
            i += 1;
            continue;
        }
        if arg == "-s" && i + 1 < args.len() {
            i += 1;
            signal = parse_signal(&args[i]).unwrap_or_else(|| {
                eprintln!("kill: invalid signal '{}'", args[i]);
                process::exit(1);
            });
            i += 1;
            continue;
        }
        if arg.starts_with('-') && arg.len() > 1 {
            let sig_str = &arg[1..];
            if let Ok(n) = sig_str.parse::<i32>() {
                signal = n;
            } else {
                signal = parse_signal(sig_str).unwrap_or_else(|| {
                    eprintln!("kill: invalid signal '{}'", sig_str);
                    process::exit(1);
                });
            }
            i += 1;
            continue;
        }
        match arg.parse::<i32>() {
            Ok(pid) => pids.push(pid),
            Err(_) => {
                eprintln!("kill: invalid PID '{}'", arg);
                process::exit(1);
            }
        }
        i += 1;
    }

    if list_signals {
        print_signals();
        process::exit(0);
    }

    let mut had_error = false;
    for pid in pids {
        if let Err(e) = send_signal(pid, signal) {
            eprintln!("kill: ({}) - {}", pid, e);
            had_error = true;
        }
    }

    process::exit(if had_error { 1 } else { 0 });
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
    // On Windows, use taskkill to terminate processes
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

fn parse_signal(s: &str) -> Option<i32> {
    // Try numeric
    if let Ok(n) = s.parse::<i32>() {
        return Some(n);
    }
    // Try signal name
    let upper = s.to_uppercase();
    let name = upper.strip_prefix("SIG").unwrap_or(&upper);
    match name {
        "HUP" => Some(1),
        "INT" => Some(2),
        "QUIT" => Some(3),
        "ILL" => Some(4),
        "TRAP" => Some(5),
        "ABRT" | "IOT" => Some(6),
        "BUS" => Some(7),
        "FPE" => Some(8),
        "KILL" => Some(9),
        "USR1" => Some(10),
        "SEGV" => Some(11),
        "USR2" => Some(12),
        "PIPE" => Some(13),
        "ALRM" => Some(14),
        "TERM" => Some(15),
        "STKFLT" => Some(16),
        "CHLD" | "CLD" => Some(17),
        "CONT" => Some(18),
        "STOP" => Some(19),
        "TSTP" => Some(20),
        "TTIN" => Some(21),
        "TTOU" => Some(22),
        "URG" => Some(23),
        "XCPU" => Some(24),
        "XFSZ" => Some(25),
        "VTALRM" => Some(26),
        "PROF" => Some(27),
        "WINCH" => Some(28),
        "IO" | "POLL" => Some(29),
        "PWR" => Some(30),
        "SYS" => Some(31),
        _ => None,
    }
}

fn print_signals() {
    let signals = [
        "HUP", "INT", "QUIT", "ILL", "TRAP", "ABRT", "BUS", "FPE", "KILL", "USR1", "SEGV", "USR2",
        "PIPE", "ALRM", "TERM", "STKFLT", "CHLD", "CONT", "STOP", "TSTP", "TTIN", "TTOU", "URG",
        "XCPU", "XFSZ", "VTALRM", "PROF", "WINCH", "POLL", "PWR", "SYS",
    ];
    for (i, sig) in signals.iter().enumerate() {
        print!("{}", sig);
        if i < signals.len() - 1 {
            print!(" ");
        }
    }
    println!();
}
