/// pinky — lightweight finger information lookup
///
/// A simplified version of the finger command that displays information
/// about currently logged-in users using utmpx records and passwd entries.
use std::ffi::CStr;
use std::fmt::Write as FmtWrite;
use std::path::PathBuf;

use crate::who;

/// Configuration for the pinky command, derived from CLI flags.
#[derive(Clone, Debug)]
pub struct PinkyConfig {
    /// Use long format output (-l).
    pub long_format: bool,
    /// Omit home directory and shell in long format (-b).
    pub omit_home_shell: bool,
    /// Omit project file in long format (-h).
    pub omit_project: bool,
    /// Omit plan file in long format (-p).
    pub omit_plan: bool,
    /// Short format (default) (-s).
    pub short_format: bool,
    /// Omit column heading in short format (-f).
    pub omit_heading: bool,
    /// Omit full name in short format (-w).
    pub omit_fullname: bool,
    /// Omit full name and remote host in short format (-i).
    pub omit_fullname_host: bool,
    /// Omit full name, remote host, and idle time in short format (-q).
    pub omit_fullname_host_idle: bool,
    /// Specific users to look up (positional args).
    pub users: Vec<String>,
}

impl Default for PinkyConfig {
    fn default() -> Self {
        Self {
            long_format: false,
            omit_home_shell: false,
            omit_project: false,
            omit_plan: false,
            short_format: true,
            omit_heading: false,
            omit_fullname: false,
            omit_fullname_host: false,
            omit_fullname_host_idle: false,
            users: Vec::new(),
        }
    }
}

/// Passwd entry information for a user.
#[derive(Clone, Debug)]
pub struct UserInfo {
    pub login: String,
    pub fullname: String,
    pub home_dir: String,
    pub shell: String,
}

/// Look up a user's passwd entry by login name.
pub fn get_user_info(username: &str) -> Option<UserInfo> {
    let c_name = std::ffi::CString::new(username).ok()?;
    unsafe {
        let pw = libc::getpwnam(c_name.as_ptr());
        if pw.is_null() {
            return None;
        }
        let pw = &*pw;

        let login = CStr::from_ptr(pw.pw_name).to_string_lossy().into_owned();
        let gecos = if pw.pw_gecos.is_null() {
            String::new()
        } else {
            CStr::from_ptr(pw.pw_gecos).to_string_lossy().into_owned()
        };
        // GECOS field may have multiple comma-separated values; first is the full name
        let fullname = gecos.split(',').next().unwrap_or("").to_string();
        let home_dir = CStr::from_ptr(pw.pw_dir).to_string_lossy().into_owned();
        let shell = CStr::from_ptr(pw.pw_shell).to_string_lossy().into_owned();

        Some(UserInfo {
            login,
            fullname,
            home_dir,
            shell,
        })
    }
}

/// Compute idle time string for a terminal.
/// Returns "." if active within the last minute, or "HH:MM" otherwise.
fn idle_str(line: &str) -> String {
    if line.is_empty() {
        return "?????".to_string();
    }
    // Extract the actual device path from lines like "sshd pts/0"
    let dev_path = if line.starts_with('/') {
        line.to_string()
    } else if let Some(idx) = line.find("pts/") {
        format!("/dev/{}", &line[idx..])
    } else if let Some(idx) = line.find("tty") {
        format!("/dev/{}", &line[idx..])
    } else {
        format!("/dev/{}", line)
    };

    let mut stat_buf: libc::stat = unsafe { std::mem::zeroed() };
    let c_path = std::ffi::CString::new(dev_path).unwrap_or_default();
    let rc = unsafe { libc::stat(c_path.as_ptr(), &mut stat_buf) };
    if rc != 0 {
        return "?????".to_string();
    }

    let now = unsafe { libc::time(std::ptr::null_mut()) };
    let atime = stat_buf.st_atime;
    let idle_secs = now - atime;

    if idle_secs < 60 {
        ".".to_string()
    } else {
        let hours = idle_secs / 3600;
        let mins = (idle_secs % 3600) / 60;
        format!("{:02}:{:02}", hours, mins)
    }
}

/// Format a Unix timestamp as "YYYY-MM-DD HH:MM" (ISO short format, matches GNU coreutils 9.7+).
fn format_time_short(tv_sec: i64) -> String {
    if tv_sec == 0 {
        return String::new();
    }
    let t = tv_sec as libc::time_t;
    let tm = unsafe {
        let mut tm: libc::tm = std::mem::zeroed();
        libc::localtime_r(&t, &mut tm);
        tm
    };
    format!(
        "{:04}-{:02}-{:02} {:02}:{:02}",
        tm.tm_year + 1900,
        tm.tm_mon + 1,
        tm.tm_mday,
        tm.tm_hour,
        tm.tm_min
    )
}

/// Read a file's first line, returning it or an empty string.
fn read_first_line(path: &PathBuf) -> String {
    match std::fs::read_to_string(path) {
        Ok(contents) => contents.lines().next().unwrap_or("").to_string(),
        Err(_) => String::new(),
    }
}

/// Read a file's full content, returning it or an empty string.
fn read_file_contents(path: &PathBuf) -> String {
    std::fs::read_to_string(path).unwrap_or_default()
}

/// Format the short-format heading line (matches GNU pinky column widths).
/// GNU format: %-8s "Login" | " %-19s" "Name" | " %-9s" " TTY" | " %-6s" "Idle" | " %-16s" "When" | " %s" "Where"
pub fn format_short_heading(config: &PinkyConfig) -> String {
    let mut out = String::new();
    let _ = write!(out, "{:<8}", "Login");
    if !config.omit_fullname && !config.omit_fullname_host && !config.omit_fullname_host_idle {
        let _ = write!(out, " {:<19}", "Name");
    }
    // GNU uses " %-9s" with " TTY" (note leading space in argument = 4 chars padded to 9)
    let _ = write!(out, " {:<9}", " TTY");
    if !config.omit_fullname_host_idle {
        let _ = write!(out, " {:<6}", "Idle");
    }
    let _ = write!(out, " {:<16}", "When");
    if !config.omit_fullname_host && !config.omit_fullname_host_idle {
        let _ = write!(out, " {}", "Where");
    }
    out
}

/// Determine the message status character for a terminal line (pinky format).
/// ' ' means writable (mesg y), '*' means not writable (mesg n), '?' means unknown.
fn pinky_mesg_status(line: &str) -> char {
    // Extract the device part: for "sshd pts/0", extract "pts/0"
    let dev_part = if let Some(space_idx) = line.find(' ') {
        &line[space_idx + 1..]
    } else {
        line
    };

    if dev_part.is_empty() {
        return '?';
    }

    let dev_path = if dev_part.starts_with('/') {
        dev_part.to_string()
    } else {
        format!("/dev/{}", dev_part)
    };

    let mut stat_buf: libc::stat = unsafe { std::mem::zeroed() };
    let c_path = std::ffi::CString::new(dev_path).unwrap_or_default();
    let rc = unsafe { libc::stat(c_path.as_ptr(), &mut stat_buf) };
    if rc != 0 {
        return '?';
    }
    if stat_buf.st_mode & libc::S_IWGRP != 0 {
        ' '
    } else {
        '*'
    }
}

/// Format a single entry in short format (matches GNU pinky format exactly).
pub fn format_short_entry(entry: &who::UtmpxEntry, config: &PinkyConfig) -> String {
    let mut out = String::new();

    // Login name: %-8s
    let user = &entry.ut_user;
    if user.len() < 8 {
        let _ = write!(out, "{:<8}", user);
    } else {
        let _ = write!(out, "{}", user);
    }

    // Full name: " %-19.19s"
    if !config.omit_fullname && !config.omit_fullname_host && !config.omit_fullname_host_idle {
        let fullname = get_user_info(&entry.ut_user)
            .map(|u| u.fullname)
            .unwrap_or_default();
        // Truncate full name to 19 chars for alignment (GNU uses %-19.19s)
        let display_name: String = fullname.chars().take(19).collect();
        let _ = write!(out, " {:<19}", display_name);
    }

    // Mesg status: space + mesg_char (GNU: fputc(' '), fputc(mesg))
    let mesg = pinky_mesg_status(&entry.ut_line);
    let _ = write!(out, " {}", mesg);

    // TTY line: %-8s (may overflow for long lines like "sshd pts/0")
    let line = &entry.ut_line;
    if line.len() < 8 {
        let _ = write!(out, "{:<8}", line);
    } else {
        let _ = write!(out, "{}", line);
    }

    // Idle time: " %-6s"
    if !config.omit_fullname_host_idle {
        let idle = idle_str(&entry.ut_line);
        let _ = write!(out, " {:<6}", idle);
    }

    // When (login time): " %s"
    let time_str = format_time_short(entry.ut_tv_sec);
    let _ = write!(out, " {}", time_str);

    // Where (remote host)
    if !config.omit_fullname_host && !config.omit_fullname_host_idle {
        if !entry.ut_host.is_empty() {
            let _ = write!(out, " {}", entry.ut_host);
        }
    }

    out
}

/// Format output in long format for a specific user.
pub fn format_long_entry(username: &str, config: &PinkyConfig) -> String {
    let mut out = String::new();

    let info = get_user_info(username);

    let _ = write!(out, "Login name: {:<28}", username);
    if let Some(ref info) = info {
        let _ = write!(out, "In real life:  {}", info.fullname);
    }
    let _ = writeln!(out);

    if !config.omit_home_shell {
        if let Some(ref info) = info {
            let _ = write!(out, "Directory: {:<29}", info.home_dir);
            let _ = writeln!(out, "Shell:  {}", info.shell);
        } else {
            let _ = writeln!(out, "Directory: ???");
        }
    }

    // Project file
    if !config.omit_project {
        if let Some(ref info) = info {
            let project_path = PathBuf::from(&info.home_dir).join(".project");
            if project_path.exists() {
                let project = read_first_line(&project_path);
                if !project.is_empty() {
                    let _ = writeln!(out, "Project: {}", project);
                }
            }
        }
    }

    // Plan file
    if !config.omit_plan {
        if let Some(ref info) = info {
            let plan_path = PathBuf::from(&info.home_dir).join(".plan");
            if plan_path.exists() {
                let plan = read_file_contents(&plan_path);
                if !plan.is_empty() {
                    let _ = writeln!(out, "Plan:");
                    let _ = write!(out, "{}", plan);
                    // Ensure plan ends with newline
                    if !plan.ends_with('\n') {
                        let _ = writeln!(out);
                    }
                }
            }
        }
    }

    // Remove trailing newline for consistency - caller adds blank line separator
    if out.ends_with('\n') {
        out.pop();
    }

    out
}

/// Run the pinky command and return the formatted output.
pub fn run_pinky(config: &PinkyConfig) -> String {
    let mut output = String::new();

    if config.long_format {
        // Long format: show detailed info for each specified user
        let users = if config.users.is_empty() {
            // If no users specified in long mode, show logged-in users
            let entries = who::read_utmpx_with_systemd_fallback_no_pid_check();
            let mut names: Vec<String> = entries
                .iter()
                .filter(|e| e.ut_type == 7) // USER_PROCESS
                .map(|e| e.ut_user.clone())
                .collect();
            names.sort();
            names.dedup();
            names
        } else {
            config.users.clone()
        };

        for user in users.iter() {
            // Write entry then blank line (GNU pinky separates entries with blank lines)
            let _ = writeln!(output, "{}", format_long_entry(user, config));
        }
    } else {
        // Short format (default)
        let entries = who::read_utmpx_with_systemd_fallback_no_pid_check();

        if !config.omit_heading {
            let _ = writeln!(output, "{}", format_short_heading(config));
        }

        let user_entries: Vec<&who::UtmpxEntry> = entries
            .iter()
            .filter(|e| e.ut_type == 7) // USER_PROCESS
            .filter(|e| {
                if config.users.is_empty() {
                    true
                } else {
                    config.users.iter().any(|u| u == &e.ut_user)
                }
            })
            .collect();

        for entry in &user_entries {
            let _ = writeln!(output, "{}", format_short_entry(entry, config));
        }
    }

    // Short format: remove trailing newline (fpinky uses println! which adds one)
    // Long format: keep trailing newline so fpinky's println! creates the blank separator
    if !config.long_format && output.ends_with('\n') {
        output.pop();
    }

    output
}
