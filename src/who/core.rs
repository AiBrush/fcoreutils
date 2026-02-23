/// who — show who is logged on
///
/// Reads utmpx records and displays information about currently logged-in users,
/// boot time, dead processes, run level, etc.
use std::ffi::CStr;
use std::fmt::Write as FmtWrite;

// utmpx entry type constants (from utmpx.h)
const RUN_LVL: i16 = 1;
const BOOT_TIME: i16 = 2;
const NEW_TIME: i16 = 3;
const OLD_TIME: i16 = 4;
const INIT_PROCESS: i16 = 5;
const LOGIN_PROCESS: i16 = 6;
const USER_PROCESS: i16 = 7;
const DEAD_PROCESS: i16 = 8;

/// A decoded utmpx entry.
#[derive(Clone, Debug)]
pub struct UtmpxEntry {
    pub ut_type: i16,
    pub ut_pid: i32,
    pub ut_line: String,
    pub ut_id: String,
    pub ut_user: String,
    pub ut_host: String,
    pub ut_tv_sec: i64,
}

/// Guess the pty name that was opened for a given UID right after the given
/// start time (in microseconds since epoch). Matches the GNU coreutils
/// `guess_pty_name()` algorithm: scan `/dev/pts/`, find the entry owned by
/// `uid` whose ctime is >= start_time and closest to it (within 5 seconds).
/// Returns e.g. "pts/0".
fn guess_pty_name(uid: u32, start_us: u64) -> Option<String> {
    let start_sec = (start_us / 1_000_000) as i64;
    let start_nsec = ((start_us % 1_000_000) * 1000) as i64;

    let dir = std::fs::read_dir("/dev/pts").ok()?;

    let mut best_name: Option<String> = None;
    let mut best_sec: i64 = 0;
    let mut best_nsec: i64 = 0;

    for entry in dir.flatten() {
        let name = entry.file_name();
        let name_str = name.to_string_lossy();
        // Skip . entries and ptmx
        if name_str.starts_with('.') || name_str == "ptmx" {
            continue;
        }

        let path = format!("/dev/pts/{}", name_str);
        let c_path = match std::ffi::CString::new(path.as_str()) {
            Ok(p) => p,
            Err(_) => continue,
        };

        let mut stat_buf: libc::stat = unsafe { std::mem::zeroed() };
        let rc = unsafe { libc::stat(c_path.as_ptr(), &mut stat_buf) };
        if rc != 0 {
            continue;
        }

        // Must be owned by the session's UID
        if stat_buf.st_uid != uid {
            continue;
        }

        let ct_sec = stat_buf.st_ctime;
        let ct_nsec = stat_buf.st_ctime_nsec;

        // ctime must be >= start_time
        if ct_sec < start_sec || (ct_sec == start_sec && ct_nsec < start_nsec) {
            continue;
        }

        // Is this the best (earliest) candidate so far?
        if best_name.is_none()
            || ct_sec < best_sec
            || (ct_sec == best_sec && ct_nsec < best_nsec)
        {
            best_name = Some(format!("pts/{}", name_str));
            best_sec = ct_sec;
            best_nsec = ct_nsec;
        }
    }

    // Must be within 5 seconds of the start time
    if let Some(ref _name) = best_name {
        if best_sec > start_sec + 5
            || (best_sec == start_sec + 5 && best_nsec > start_nsec)
        {
            return None;
        }
    }

    best_name
}

/// Read session entries from systemd-logind session files.
/// Used as a fallback when the traditional utmpx database has no USER_PROCESS
/// entries. Implements the same algorithm as GNU coreutils' read_utmp_from_systemd().
///
/// If `check_pids` is true (used by who/users), filter out entries whose
/// leader PID is no longer alive. If false (used by pinky), include all
/// active sessions regardless of PID state.
fn read_systemd_sessions(check_pids: bool) -> Vec<UtmpxEntry> {
    let sessions_dir = std::path::Path::new("/run/systemd/sessions");
    if !sessions_dir.exists() {
        return Vec::new();
    }

    let mut entries = Vec::new();

    let dir = match std::fs::read_dir(sessions_dir) {
        Ok(d) => d,
        Err(_) => return Vec::new(),
    };

    for entry in dir.flatten() {
        let path = entry.path();
        // Skip .ref files and other non-session files
        if path.extension().is_some() {
            continue;
        }
        let content = match std::fs::read_to_string(&path) {
            Ok(c) => c,
            Err(_) => continue,
        };

        let mut user = String::new();
        let mut remote_host = String::new();
        let mut service = String::new();
        let mut realtime_us: u64 = 0;
        let mut uid: u32 = 0;
        let mut leader_pid: i32 = 0;
        let mut active = false;
        let mut session_type = String::new();
        let mut session_class = String::new();
        let mut session_id = String::new();

        // Use filename as session ID
        if let Some(fname) = path.file_name() {
            session_id = fname.to_string_lossy().into_owned();
        }

        for line in content.lines() {
            if let Some(val) = line.strip_prefix("USER=") {
                user = val.to_string();
            } else if let Some(val) = line.strip_prefix("REMOTE_HOST=") {
                remote_host = val.to_string();
            } else if let Some(val) = line.strip_prefix("SERVICE=") {
                service = val.to_string();
            } else if let Some(val) = line.strip_prefix("REALTIME=") {
                realtime_us = val.parse().unwrap_or(0);
            } else if let Some(val) = line.strip_prefix("UID=") {
                uid = val.parse().unwrap_or(0);
            } else if let Some(val) = line.strip_prefix("LEADER=") {
                leader_pid = val.parse().unwrap_or(0);
            } else if line == "ACTIVE=1" {
                active = true;
            } else if let Some(val) = line.strip_prefix("TYPE=") {
                session_type = val.to_string();
            } else if let Some(val) = line.strip_prefix("CLASS=") {
                session_class = val.to_string();
            }
        }

        // Skip inactive sessions
        if !active || user.is_empty() {
            continue;
        }

        // When check_pids is set (who/users), verify the leader PID is alive
        // This matches GNU's READ_UTMP_CHECK_PIDS behavior
        if check_pids && leader_pid > 0 {
            let pid_alive = unsafe { libc::kill(leader_pid, 0) };
            if pid_alive < 0 {
                let err = std::io::Error::last_os_error();
                if err.raw_os_error() == Some(libc::ESRCH) {
                    continue; // Process does not exist
                }
            }
        }

        // Determine entry type: "manager" class → LOGIN_PROCESS, else USER_PROCESS
        let entry_type = if session_class.starts_with("manager") {
            LOGIN_PROCESS
        } else {
            USER_PROCESS
        };

        // Skip non-user, non-manager classes
        if session_class != "user" && !session_class.starts_with("manager") {
            continue;
        }

        // Determine TTY line (matching GNU coreutils algorithm)
        let tty = if session_type == "tty" {
            // Try to guess the pty device from /dev/pts/
            let pty = guess_pty_name(uid, realtime_us);
            match (service.is_empty(), pty) {
                (false, Some(pty_name)) => format!("{} {}", service, pty_name),
                (false, None) => service.clone(),
                (true, Some(pty_name)) => pty_name,
                (true, None) => continue, // No seat and no tty, skip
            }
        } else if session_type == "web" {
            if service.is_empty() {
                continue;
            }
            service.clone()
        } else {
            continue; // Unrecognized session type
        };

        let tv_sec = (realtime_us / 1_000_000) as i64;

        entries.push(UtmpxEntry {
            ut_type: entry_type,
            ut_pid: leader_pid,
            ut_line: tty,
            ut_id: session_id,
            ut_user: user,
            ut_host: remote_host,
            ut_tv_sec: tv_sec,
        });
    }

    // Sort by realtime for consistent ordering
    entries.sort_by_key(|e| e.ut_tv_sec);
    entries
}

/// Read all utmpx entries from the system database.
///
/// # Safety
/// Uses libc's setutxent/getutxent/endutxent which are not thread-safe.
/// This function must not be called concurrently.
pub fn read_utmpx() -> Vec<UtmpxEntry> {
    let mut entries = Vec::new();

    unsafe {
        libc::setutxent();
        loop {
            let entry = libc::getutxent();
            if entry.is_null() {
                break;
            }
            let e = &*entry;

            let user = cstr_from_buf(&e.ut_user);
            let line = cstr_from_buf(&e.ut_line);
            let host = cstr_from_buf(&e.ut_host);
            let id = cstr_from_buf(&e.ut_id);

            let tv_sec = e.ut_tv.tv_sec as i64;

            entries.push(UtmpxEntry {
                ut_type: e.ut_type as i16,
                ut_pid: e.ut_pid,
                ut_line: line,
                ut_id: id,
                ut_user: user,
                ut_host: host,
                ut_tv_sec: tv_sec,
            });
        }
        libc::endutxent();
    }

    entries
}

/// Read utmpx entries, falling back to systemd sessions if the utmpx database
/// has no USER_PROCESS entries. This matches GNU coreutils behavior: when
/// /var/run/utmp is absent or empty, use systemd-logind session files.
///
/// If `check_pids` is true (who/users), filter out entries whose leader PID
/// is dead (matches GNU's READ_UTMP_CHECK_PIDS). If false (pinky), include
/// all active sessions.
pub fn read_utmpx_with_systemd_fallback_ex(check_pids: bool) -> Vec<UtmpxEntry> {
    let mut entries = read_utmpx();

    // If check_pids is set, filter traditional utmpx entries by PID too
    if check_pids {
        entries.retain(|e| {
            if e.ut_type == USER_PROCESS && e.ut_pid > 0 {
                let rc = unsafe { libc::kill(e.ut_pid, 0) };
                if rc < 0 {
                    let err = std::io::Error::last_os_error();
                    if err.raw_os_error() == Some(libc::ESRCH) {
                        return false;
                    }
                }
            }
            true
        });
    }

    let has_user_entries = entries.iter().any(|e| e.ut_type == USER_PROCESS);
    if !has_user_entries {
        let systemd_entries = read_systemd_sessions(check_pids);
        entries.extend(systemd_entries);
    }
    entries
}

/// Read utmpx with systemd fallback, checking PIDs (for who/users).
pub fn read_utmpx_with_systemd_fallback() -> Vec<UtmpxEntry> {
    read_utmpx_with_systemd_fallback_ex(true)
}

/// Read utmpx with systemd fallback, without PID checking (for pinky).
pub fn read_utmpx_with_systemd_fallback_no_pid_check() -> Vec<UtmpxEntry> {
    read_utmpx_with_systemd_fallback_ex(false)
}

/// Extract a Rust String from a fixed-size C char buffer.
unsafe fn cstr_from_buf(buf: &[libc::c_char]) -> String {
    // Find the first NUL byte or use the entire buffer length
    let len = buf.iter().position(|&c| c == 0).unwrap_or(buf.len());
    let bytes: Vec<u8> = buf[..len].iter().map(|&c| c as u8).collect();
    String::from_utf8_lossy(&bytes).into_owned()
}

/// Configuration for the who command, derived from CLI flags.
#[derive(Clone, Debug, Default)]
pub struct WhoConfig {
    pub show_boot: bool,
    pub show_dead: bool,
    pub show_heading: bool,
    pub show_login: bool,
    pub only_current: bool,      // -m
    pub show_init_spawn: bool,   // -p
    pub show_count: bool,        // -q
    pub show_runlevel: bool,     // -r
    pub short_format: bool,      // -s (default)
    pub show_clock_change: bool, // -t
    pub show_mesg: bool,         // -T, -w
    pub show_users: bool,        // -u
    pub show_all: bool,          // -a
    pub show_ips: bool,          // --ips
    pub show_lookup: bool,       // --lookup
    pub am_i: bool,              // "who am i"
}

impl WhoConfig {
    /// Apply the --all flag: equivalent to -b -d --login -p -r -t -T -u.
    pub fn apply_all(&mut self) {
        self.show_boot = true;
        self.show_dead = true;
        self.show_login = true;
        self.show_init_spawn = true;
        self.show_runlevel = true;
        self.show_clock_change = true;
        self.show_mesg = true;
        self.show_users = true;
    }

    /// Returns true if no specific filter flags are set,
    /// meaning only USER_PROCESS entries should be shown (default behavior).
    pub fn is_default_filter(&self) -> bool {
        !self.show_boot
            && !self.show_dead
            && !self.show_login
            && !self.show_init_spawn
            && !self.show_runlevel
            && !self.show_clock_change
            && !self.show_users
    }
}

/// Format a Unix timestamp as "YYYY-MM-DD HH:MM".
pub fn format_time(tv_sec: i64) -> String {
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
        tm.tm_min,
    )
}

/// Extract the actual device path from a ut_line field.
/// For systemd-logind entries, ut_line may be "sshd pts/0" (service + space + tty).
/// For traditional utmpx entries, it's just "pts/0" or "tty1".
fn extract_device_path(line: &str) -> Option<String> {
    if line.is_empty() {
        return None;
    }
    // For lines like "sshd pts/0", extract "pts/0"
    let tty_part = if let Some(idx) = line.find("pts/") {
        &line[idx..]
    } else if let Some(idx) = line.find("tty") {
        &line[idx..]
    } else if line.starts_with('/') {
        return Some(line.to_string());
    } else {
        line
    };
    if tty_part.starts_with('/') {
        Some(tty_part.to_string())
    } else {
        Some(format!("/dev/{}", tty_part))
    }
}

/// Determine the message status character for a terminal line.
/// '+' means writable (mesg y), '-' means not writable (mesg n), '?' means unknown.
fn mesg_status(line: &str) -> char {
    let dev_path = match extract_device_path(line) {
        Some(p) => p,
        None => return '?',
    };

    let mut stat_buf: libc::stat = unsafe { std::mem::zeroed() };
    let c_path = std::ffi::CString::new(dev_path).unwrap_or_default();
    let rc = unsafe { libc::stat(c_path.as_ptr(), &mut stat_buf) };
    if rc != 0 {
        return '?';
    }
    if stat_buf.st_mode & libc::S_IWGRP != 0 {
        '+'
    } else {
        '-'
    }
}

/// Compute idle time string for a terminal.
/// Returns "." if active within the last minute, "old" if more than 24h,
/// or "HH:MM" otherwise.
fn idle_str(line: &str) -> String {
    let dev_path = match extract_device_path(line) {
        Some(p) => p,
        None => return "?".to_string(),
    };

    let mut stat_buf: libc::stat = unsafe { std::mem::zeroed() };
    let c_path = std::ffi::CString::new(dev_path).unwrap_or_default();
    let rc = unsafe { libc::stat(c_path.as_ptr(), &mut stat_buf) };
    if rc != 0 {
        return "?".to_string();
    }

    let now = unsafe { libc::time(std::ptr::null_mut()) };
    let atime = stat_buf.st_atime;
    let idle_secs = now - atime;

    if idle_secs < 60 {
        ".".to_string()
    } else if idle_secs >= 86400 {
        "old".to_string()
    } else {
        let hours = idle_secs / 3600;
        let mins = (idle_secs % 3600) / 60;
        format!("{:02}:{:02}", hours, mins)
    }
}

/// Get the terminal device for the current process (for "who am i" / -m).
pub fn current_tty() -> Option<String> {
    unsafe {
        let name = libc::ttyname(0); // stdin
        if name.is_null() {
            None
        } else {
            let s = CStr::from_ptr(name).to_string_lossy().into_owned();
            // Strip /dev/ prefix to match utmpx ut_line
            Some(s.strip_prefix("/dev/").unwrap_or(&s).to_string())
        }
    }
}

/// Check if an entry should be displayed given the config.
pub fn should_show(entry: &UtmpxEntry, config: &WhoConfig) -> bool {
    if config.am_i || config.only_current {
        // Only show entries matching the current terminal
        if let Some(tty) = current_tty() {
            // For systemd entries, ut_line may be "sshd pts/0" — match if it contains the tty
            return entry.ut_type == USER_PROCESS
                && (entry.ut_line == tty || entry.ut_line.ends_with(&format!(" {}", tty)));
        }
        return false;
    }

    if config.show_count {
        return entry.ut_type == USER_PROCESS;
    }

    if config.is_default_filter() {
        return entry.ut_type == USER_PROCESS;
    }

    match entry.ut_type {
        BOOT_TIME => config.show_boot,
        DEAD_PROCESS => config.show_dead,
        LOGIN_PROCESS => config.show_login,
        INIT_PROCESS => config.show_init_spawn,
        RUN_LVL => config.show_runlevel,
        NEW_TIME | OLD_TIME => config.show_clock_change,
        USER_PROCESS => config.show_users || config.is_default_filter(),
        _ => false,
    }
}

/// Format a single utmpx entry as an output line.
pub fn format_entry(entry: &UtmpxEntry, config: &WhoConfig) -> String {
    let mut out = String::new();

    // Determine name and line based on entry type
    let (name, line) = match entry.ut_type {
        BOOT_TIME => (String::new(), "system boot".to_string()),
        RUN_LVL => {
            let current = (entry.ut_pid & 0xFF) as u8 as char;
            (String::new(), format!("run-level {}", current))
        }
        LOGIN_PROCESS => ("LOGIN".to_string(), entry.ut_line.clone()),
        NEW_TIME => (String::new(), entry.ut_line.clone()),
        OLD_TIME => (String::new(), entry.ut_line.clone()),
        _ => (entry.ut_user.clone(), entry.ut_line.clone()),
    };

    // NAME column (left-aligned, 8 chars min)
    let _ = write!(out, "{:<8}", name);

    // Mesg status column
    if config.show_mesg {
        let status = if entry.ut_type == USER_PROCESS {
            mesg_status(&entry.ut_line)
        } else if entry.ut_type == LOGIN_PROCESS || entry.ut_type == DEAD_PROCESS {
            '?'
        } else {
            // BOOT_TIME, RUN_LVL, NEW_TIME, OLD_TIME: no terminal, show space
            ' '
        };
        let _ = write!(out, " {}", status);
    }

    // LINE column
    let _ = write!(out, " {:<12}", line);

    // TIME column
    let time_str = format_time(entry.ut_tv_sec);
    let _ = write!(out, " {}", time_str);

    // IDLE + PID for -u
    if config.show_users || config.show_all {
        match entry.ut_type {
            USER_PROCESS => {
                let idle = idle_str(&entry.ut_line);
                let _ = write!(out, " {:>5}", idle);
                let _ = write!(out, " {:>11}", entry.ut_pid);
            }
            LOGIN_PROCESS => {
                let _ = write!(out, "   ?  {:>10}", entry.ut_pid);
            }
            DEAD_PROCESS => {
                let _ = write!(out, "      {:>10}", entry.ut_pid);
            }
            _ => {}
        }
    }

    // For LOGIN_PROCESS, always show id
    if entry.ut_type == LOGIN_PROCESS {
        if !(config.show_users || config.show_all) {
            // Without -u, show PID with extra spacing
            let _ = write!(out, "          {:>5}", entry.ut_pid);
        }
        let _ = write!(out, " id={}", entry.ut_id);
    }

    // COMMENT (host) column
    if !entry.ut_host.is_empty() {
        if config.show_ips {
            let _ = write!(out, " ({})", entry.ut_host);
        } else if config.show_lookup {
            let resolved = lookup_host(&entry.ut_host);
            let _ = write!(out, " ({})", resolved);
        } else {
            let _ = write!(out, " ({})", entry.ut_host);
        }
    }

    out
}

/// Attempt to resolve a hostname via DNS. Falls back to original on failure.
fn lookup_host(host: &str) -> String {
    let c_host = match std::ffi::CString::new(host) {
        Ok(s) => s,
        Err(_) => return host.to_string(),
    };

    unsafe {
        let mut hints: libc::addrinfo = std::mem::zeroed();
        hints.ai_flags = libc::AI_CANONNAME;
        hints.ai_family = libc::AF_UNSPEC;

        let mut result: *mut libc::addrinfo = std::ptr::null_mut();
        let rc = libc::getaddrinfo(c_host.as_ptr(), std::ptr::null(), &hints, &mut result);
        if rc != 0 || result.is_null() {
            return host.to_string();
        }

        let canonical = if !(*result).ai_canonname.is_null() {
            CStr::from_ptr((*result).ai_canonname)
                .to_string_lossy()
                .into_owned()
        } else {
            host.to_string()
        };

        libc::freeaddrinfo(result);
        canonical
    }
}

/// Format output for the -q / --count mode.
pub fn format_count(entries: &[UtmpxEntry]) -> String {
    let users: Vec<&str> = entries
        .iter()
        .filter(|e| e.ut_type == USER_PROCESS)
        .map(|e| e.ut_user.as_str())
        .collect();

    let mut out = String::new();
    let _ = writeln!(out, "{}", users.join(" "));
    let _ = write!(out, "# users={}", users.len());
    out
}

/// Format heading line.
pub fn format_heading(config: &WhoConfig) -> String {
    let mut out = String::new();
    let _ = write!(out, "{:<8}", "NAME");
    if config.show_mesg {
        let _ = write!(out, " S");
    }
    let _ = write!(out, " {:<12}", "LINE");
    let _ = write!(out, " {:<16}", "TIME");
    if config.show_users || config.show_all {
        let _ = write!(out, " {:<6}", "IDLE");
        let _ = write!(out, " {:>10}", "PID");
    }
    let _ = write!(out, " {}", "COMMENT");
    out
}

/// Read boot time from /proc/stat (Linux-specific fallback).
/// Returns the boot timestamp in seconds since epoch, or None if unavailable.
#[cfg(target_os = "linux")]
fn read_boot_time_from_proc() -> Option<i64> {
    let data = std::fs::read_to_string("/proc/stat").ok()?;
    for line in data.lines() {
        if let Some(val) = line.strip_prefix("btime ") {
            return val.trim().parse::<i64>().ok();
        }
    }
    None
}

#[cfg(not(target_os = "linux"))]
fn read_boot_time_from_proc() -> Option<i64> {
    None
}

/// Run the who command and return the formatted output.
pub fn run_who(config: &WhoConfig) -> String {
    let mut entries = read_utmpx_with_systemd_fallback();

    // If no BOOT_TIME entry was found in utmpx (common in containers and some
    // Linux configurations), synthesize one from /proc/stat btime.
    if !entries.iter().any(|e| e.ut_type == BOOT_TIME) {
        if let Some(btime) = read_boot_time_from_proc() {
            entries.push(UtmpxEntry {
                ut_type: BOOT_TIME,
                ut_pid: 0,
                ut_line: String::new(),
                ut_id: String::new(),
                ut_user: String::new(),
                ut_host: String::new(),
                ut_tv_sec: btime,
            });
        }
    }

    // Sort entries by time (oldest first) to match utmpx file order (boot before sessions).
    entries.sort_by_key(|e| e.ut_tv_sec);

    let mut output = String::new();

    if config.show_count {
        return format_count(&entries);
    }

    if config.show_heading {
        let _ = writeln!(output, "{}", format_heading(config));
    }

    for entry in &entries {
        if should_show(entry, config) {
            let _ = writeln!(output, "{}", format_entry(entry, config));
        }
    }

    // Remove trailing newline for consistency
    if output.ends_with('\n') {
        output.pop();
    }

    output
}
