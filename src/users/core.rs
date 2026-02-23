/// users -- print the user names of users currently logged in
///
/// Reads utmpx records and prints a sorted, space-separated list of login names
/// for all USER_PROCESS entries.
use std::ffi::{CStr, CString};

// utmpxname is a glibc extension to set the utmpx database file path.
#[cfg(target_os = "linux")]
unsafe extern "C" {
    fn utmpxname(file: *const libc::c_char) -> libc::c_int;
}

/// Retrieve a sorted list of currently logged-in user names from utmpx.
/// If `file` is Some, reads from that file; otherwise uses the default database.
///
/// # Safety
/// Uses libc's setutxent/getutxent/endutxent which are not thread-safe.
/// This function must not be called concurrently.
pub fn get_users() -> Vec<String> {
    get_users_from(None)
}

pub fn get_users_from(file: Option<&str>) -> Vec<String> {
    let mut users = Vec::new();

    unsafe {
        // Set custom file if provided
        #[cfg(target_os = "linux")]
        if let Some(path) = file {
            if let Ok(cpath) = CString::new(path) {
                utmpxname(cpath.as_ptr());
            }
        }

        libc::setutxent();
        loop {
            let entry = libc::getutxent();
            if entry.is_null() {
                break;
            }
            let entry = &*entry;
            if entry.ut_type == libc::USER_PROCESS {
                let name = CStr::from_ptr(entry.ut_user.as_ptr())
                    .to_string_lossy()
                    .to_string();
                if !name.is_empty() {
                    users.push(name);
                }
            }
        }
        libc::endutxent();

        // Reset to default database after reading custom file
        #[cfg(target_os = "linux")]
        if file.is_some() {
            // Reset to default by calling with the standard path
            if let Ok(cpath) = CString::new("/var/run/utmp") {
                utmpxname(cpath.as_ptr());
            }
        }
    }

    users.sort();
    users
}

/// Format the user list as a single space-separated line (matching GNU users output).
pub fn format_users(users: &[String]) -> String {
    users.join(" ")
}
