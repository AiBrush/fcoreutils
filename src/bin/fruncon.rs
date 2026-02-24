// fruncon -- run command with specified SELinux security context
//
// Usage: runcon CONTEXT COMMAND [ARG]...
//        runcon [-c] [-u USER] [-r ROLE] [-t TYPE] [-l RANGE] COMMAND [ARG]...
//
// With neither CONTEXT nor COMMAND, print the current security context.

#[cfg(not(unix))]
fn main() {
    eprintln!("runcon: only available on Unix");
    std::process::exit(125);
}

#[cfg(unix)]
use std::os::unix::process::CommandExt;

#[cfg(unix)]
fn main() {
    coreutils_rs::common::reset_sigpipe();

    let args: Vec<String> = std::env::args().skip(1).collect();

    // --help / --version first pass
    for arg in &args {
        match arg.as_str() {
            "--help" => {
                print_help();
                return;
            }
            "--version" => {
                println!("runcon (fcoreutils) {}", env!("CARGO_PKG_VERSION"));
                return;
            }
            _ => {}
        }
    }

    // No arguments: print current security context
    if args.is_empty() {
        match get_current_context() {
            Ok(ctx) => {
                println!("{}", ctx);
            }
            Err(e) => {
                eprintln!("runcon: {}", e);
                std::process::exit(1);
            }
        }
        return;
    }

    // Parse options
    let mut compute = false;
    let mut user: Option<String> = None;
    let mut role: Option<String> = None;
    let mut typ: Option<String> = None;
    let mut range: Option<String> = None;
    let mut positional_start: Option<usize> = None;

    let mut i = 0;
    while i < args.len() {
        let arg = &args[i];
        match arg.as_str() {
            "-c" | "--compute" => {
                compute = true;
                i += 1;
            }
            "-u" | "--user" => {
                i += 1;
                if i >= args.len() {
                    eprintln!("runcon: option '{}' requires an argument", arg);
                    std::process::exit(125);
                }
                user = Some(args[i].clone());
                i += 1;
            }
            "-r" | "--role" => {
                i += 1;
                if i >= args.len() {
                    eprintln!("runcon: option '{}' requires an argument", arg);
                    std::process::exit(125);
                }
                role = Some(args[i].clone());
                i += 1;
            }
            "-t" | "--type" => {
                i += 1;
                if i >= args.len() {
                    eprintln!("runcon: option '{}' requires an argument", arg);
                    std::process::exit(125);
                }
                typ = Some(args[i].clone());
                i += 1;
            }
            "-l" | "--range" => {
                i += 1;
                if i >= args.len() {
                    eprintln!("runcon: option '{}' requires an argument", arg);
                    std::process::exit(125);
                }
                range = Some(args[i].clone());
                i += 1;
            }
            s if s.starts_with("--user=") => {
                user = Some(s["--user=".len()..].to_string());
                i += 1;
            }
            s if s.starts_with("--role=") => {
                role = Some(s["--role=".len()..].to_string());
                i += 1;
            }
            s if s.starts_with("--type=") => {
                typ = Some(s["--type=".len()..].to_string());
                i += 1;
            }
            s if s.starts_with("--range=") => {
                range = Some(s["--range=".len()..].to_string());
                i += 1;
            }
            "--" => {
                i += 1;
                if i < args.len() {
                    positional_start = Some(i);
                }
                break;
            }
            _ => {
                positional_start = Some(i);
                break;
            }
        }
    }

    if compute {
        eprintln!("runcon: warning: -c/--compute requires libselinux and is not yet supported");
        std::process::exit(125);
    }

    let has_partial = user.is_some() || role.is_some() || typ.is_some() || range.is_some();

    // Determine context and command
    let (context, command_start): (Option<String>, usize) = if let Some(start) = positional_start {
        if has_partial {
            // Partial mode: all remaining args are COMMAND [ARG]...
            (None, start)
        } else {
            // First positional is CONTEXT, rest is COMMAND [ARG]...
            if start + 1 >= args.len() {
                // Only context, no command
                eprintln!("runcon: no command specified");
                eprintln!("Try 'runcon --help' for more information.");
                std::process::exit(125);
            }
            (Some(args[start].clone()), start + 1)
        }
    } else {
        // No positional args (with or without partial options)
        eprintln!("runcon: missing operand");
        eprintln!("Try 'runcon --help' for more information.");
        std::process::exit(125);
    };

    if command_start >= args.len() {
        eprintln!("runcon: missing operand");
        eprintln!("Try 'runcon --help' for more information.");
        std::process::exit(125);
    }

    // Check if SELinux is available
    if !is_selinux_enabled() {
        eprintln!("runcon: runcon may be used only on a SELinux kernel");
        std::process::exit(125);
    }

    // Build the new context
    let new_context = if let Some(ctx) = context {
        ctx
    } else {
        // Partial mode: read current context and modify fields
        let current = match get_current_context() {
            Ok(ctx) => ctx,
            Err(e) => {
                eprintln!("runcon: failed to get current context: {}", e);
                std::process::exit(125);
            }
        };

        let parts: Vec<&str> = current.splitn(4, ':').collect();
        if parts.len() < 3 {
            eprintln!("runcon: failed to parse current context");
            std::process::exit(125);
        }

        let new_user = user.as_deref().unwrap_or(parts[0]);
        let new_role = role.as_deref().unwrap_or(parts[1]);
        let new_type = typ.as_deref().unwrap_or(parts[2]);
        let new_range = range
            .as_deref()
            .unwrap_or(if parts.len() > 3 { parts[3] } else { "s0" });

        format!("{}:{}:{}:{}", new_user, new_role, new_type, new_range)
    };

    // Set the exec context via /proc/self/attr/exec
    if let Err(e) = set_exec_context(&new_context) {
        eprintln!(
            "runcon: failed to set exec context to '{}': {}",
            new_context, e
        );
        std::process::exit(125);
    }

    // Execute the command (replaces this process)
    let command = &args[command_start];
    let command_args = &args[command_start + 1..];

    let err = std::process::Command::new(command)
        .args(command_args)
        .exec();

    let code = if err.kind() == std::io::ErrorKind::NotFound {
        127
    } else {
        126
    };
    eprintln!(
        "runcon: failed to run command '{}': {}",
        command,
        coreutils_rs::common::io_error_msg(&err)
    );
    std::process::exit(code);
}

#[cfg(unix)]
fn is_selinux_enabled() -> bool {
    std::path::Path::new("/sys/fs/selinux").exists() || std::path::Path::new("/selinux").exists()
}

#[cfg(unix)]
fn get_current_context() -> Result<String, String> {
    match std::fs::read_to_string("/proc/self/attr/current") {
        Ok(ctx) => {
            let trimmed = ctx.trim_end_matches('\0').trim().to_string();
            if trimmed.is_empty() {
                Err("could not get current context".to_string())
            } else {
                Ok(trimmed)
            }
        }
        Err(e) => Err(coreutils_rs::common::io_error_msg(&e)),
    }
}

#[cfg(unix)]
fn set_exec_context(context: &str) -> Result<(), String> {
    std::fs::write("/proc/self/attr/exec", context)
        .map_err(|e| coreutils_rs::common::io_error_msg(&e))
}

fn print_help() {
    println!("Usage: runcon CONTEXT COMMAND [args]");
    println!("  or:  runcon [ -c ] [-u USER] [-r ROLE] [-t TYPE] [-l RANGE] COMMAND [args]");
    println!("Run a program in a different SELinux security context.");
    println!("With neither CONTEXT nor COMMAND, print the current security context.");
    println!();
    println!("Mandatory arguments to long options are mandatory for short options too.");
    println!("  CONTEXT            Complete security context");
    println!("  -c, --compute      compute process transition context before modifying");
    println!("  -t, --type=TYPE    type (for same role as parent)");
    println!("  -u, --user=USER    user identity");
    println!("  -r, --role=ROLE    role");
    println!("  -l, --range=RANGE  levelrange");
    println!("      --help        display this help and exit");
    println!("      --version     output version information and exit");
    println!();
    println!("Exit status:");
    println!("  125  if the runcon command itself fails");
    println!("  126  if COMMAND is found but cannot be invoked");
    println!("  127  if COMMAND cannot be found");
    println!("  -    the exit status of COMMAND otherwise");
}

#[cfg(all(test, unix))]
mod tests {
    use std::process::Command;

    fn cmd() -> Command {
        let mut path = std::env::current_exe().unwrap();
        path.pop();
        path.pop();
        path.push("fruncon");
        Command::new(path)
    }

    #[test]
    fn test_help() {
        let output = cmd().arg("--help").output().unwrap();
        assert_eq!(output.status.code(), Some(0));
        let stdout = String::from_utf8_lossy(&output.stdout);
        assert!(stdout.contains("Usage: runcon"));
        assert!(stdout.contains("CONTEXT"));
        assert!(stdout.contains("--compute"));
    }

    #[test]
    fn test_version() {
        let output = cmd().arg("--version").output().unwrap();
        assert_eq!(output.status.code(), Some(0));
        let stdout = String::from_utf8_lossy(&output.stdout);
        assert!(stdout.contains("runcon (fcoreutils)"));
    }

    #[test]
    fn test_no_args_prints_context() {
        let output = cmd().output().unwrap();
        let stdout = String::from_utf8_lossy(&output.stdout);
        if output.status.success() {
            assert!(!stdout.trim().is_empty());
        }
    }

    #[test]
    fn test_matches_gnu_no_args() {
        let gnu = Command::new("runcon").output();
        if let Ok(gnu) = gnu {
            let ours = cmd().output().unwrap();
            assert_eq!(ours.status.code(), gnu.status.code());
            if gnu.status.success() {
                let gnu_out = String::from_utf8_lossy(&gnu.stdout);
                let our_out = String::from_utf8_lossy(&ours.stdout);
                assert_eq!(our_out.trim(), gnu_out.trim());
            }
        }
    }

    #[test]
    fn test_matches_gnu_with_context_and_command() {
        let gnu = Command::new("runcon")
            .args(["foo_context", "/bin/true"])
            .output();
        if let Ok(gnu) = gnu {
            let ours = cmd().args(["foo_context", "/bin/true"]).output().unwrap();
            assert_eq!(ours.status.code(), gnu.status.code());
        }
    }
}
