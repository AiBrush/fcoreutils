use std::fs;
use std::io;
use std::path::Path;

#[cfg(unix)]
use std::os::unix::fs::MetadataExt;

/// Backup mode for destination files.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum BackupMode {
    /// Simple backup: append suffix (default `~`).
    Simple,
    /// Numbered backup: append `.~N~`.
    Numbered,
    /// Existing: numbered if numbered backups exist, otherwise simple.
    Existing,
    /// Never make backups (same as not specifying --backup).
    None,
}

/// Configuration for mv operations.
#[derive(Debug, Clone)]
pub struct MvConfig {
    pub force: bool,
    pub interactive: bool,
    pub no_clobber: bool,
    pub verbose: bool,
    pub update: bool,
    pub backup: Option<BackupMode>,
    pub suffix: String,
    pub target_directory: Option<String>,
    pub no_target_directory: bool,
    pub strip_trailing_slashes: bool,
}

impl Default for MvConfig {
    fn default() -> Self {
        Self {
            force: false,
            interactive: false,
            no_clobber: false,
            verbose: false,
            update: false,
            backup: None,
            suffix: "~".to_string(),
            target_directory: None,
            no_target_directory: false,
            strip_trailing_slashes: false,
        }
    }
}

/// Parse a backup control string (from --backup=CONTROL or VERSION_CONTROL env).
pub fn parse_backup_mode(s: &str) -> Option<BackupMode> {
    match s {
        "none" | "off" => Some(BackupMode::None),
        "simple" | "never" => Some(BackupMode::Simple),
        "numbered" | "t" => Some(BackupMode::Numbered),
        "existing" | "nil" => Some(BackupMode::Existing),
        _ => Option::None,
    }
}

/// Generate a backup file name for a given destination path.
pub fn make_backup_name(dst: &Path, mode: &BackupMode, suffix: &str) -> std::path::PathBuf {
    match mode {
        BackupMode::Simple | BackupMode::None => {
            let mut name = dst.as_os_str().to_os_string();
            name.push(suffix);
            std::path::PathBuf::from(name)
        }
        BackupMode::Numbered => make_numbered_backup(dst),
        BackupMode::Existing => {
            // If any numbered backup exists, use numbered; otherwise simple.
            if has_numbered_backup(dst) {
                make_numbered_backup(dst)
            } else {
                let mut name = dst.as_os_str().to_os_string();
                name.push(suffix);
                std::path::PathBuf::from(name)
            }
        }
    }
}

/// Check if any numbered backup (e.g., `file.~1~`) exists for the given path.
fn has_numbered_backup(path: &Path) -> bool {
    let file_name = match path.file_name() {
        Some(n) => n.to_string_lossy().to_string(),
        None => return false,
    };
    let parent = path.parent().unwrap_or_else(|| Path::new("."));
    if let Ok(entries) = fs::read_dir(parent) {
        for entry in entries.flatten() {
            let name = entry.file_name().to_string_lossy().to_string();
            if name.starts_with(&format!("{}.~", file_name)) && name.ends_with('~') {
                // Check that the middle part is a number
                let middle = &name[file_name.len() + 2..name.len() - 1];
                if middle.parse::<u64>().is_ok() {
                    return true;
                }
            }
        }
    }
    false
}

/// Create the next numbered backup name (e.g., `file.~1~`, `file.~2~`, ...).
fn make_numbered_backup(path: &Path) -> std::path::PathBuf {
    let mut n = 1u64;
    loop {
        let candidate = format!("{}.~{}~", path.display(), n);
        let p = std::path::PathBuf::from(&candidate);
        if !p.exists() {
            return p;
        }
        n += 1;
    }
}

/// Move a single file or directory from `src` to `dst`.
///
/// Tries `rename()` first (atomic, same filesystem). If that fails with
/// `EXDEV` (cross-device), falls back to recursive copy + remove.
pub fn mv_file(src: &Path, dst: &Path, config: &MvConfig) -> io::Result<()> {
    // Check no_clobber / update
    if dst.exists() {
        if config.no_clobber {
            return Ok(());
        }
        if config.update {
            let src_time = fs::metadata(src)?.modified()?;
            let dst_time = fs::metadata(dst)?.modified()?;
            if src_time <= dst_time {
                return Ok(());
            }
        }
    }

    // Handle backup
    if dst.exists() {
        if let Some(ref mode) = config.backup {
            let backup_name = make_backup_name(dst, mode, &config.suffix);
            fs::rename(dst, &backup_name)?;
        }
    }

    // Try rename first (same filesystem, atomic)
    match fs::rename(src, dst) {
        Ok(()) => {
            if config.verbose {
                eprintln!("renamed '{}' -> '{}'", src.display(), dst.display());
            }
            Ok(())
        }
        Err(e) if e.raw_os_error() == Some(libc::EXDEV) => {
            // Cross-filesystem: copy then remove
            copy_recursive(src, dst)?;
            remove_recursive(src)?;
            if config.verbose {
                eprintln!("renamed '{}' -> '{}'", src.display(), dst.display());
            }
            Ok(())
        }
        Err(e) => Err(e),
    }
}

/// Strip trailing slashes from a path string, returning the cleaned string.
pub fn strip_trailing_slashes(path: &str) -> &str {
    let trimmed = path.trim_end_matches('/');
    if trimmed.is_empty() { "/" } else { trimmed }
}

/// Preserve file metadata (permissions, timestamps, ownership) from `src` onto `dst`.
/// Used during cross-device moves to maintain the original file attributes.
fn preserve_metadata(src_meta: &fs::Metadata, dst: &Path) -> io::Result<()> {
    // Preserve permissions
    fs::set_permissions(dst, src_meta.permissions())?;

    // Preserve timestamps
    #[cfg(unix)]
    {
        let atime_spec = libc::timespec {
            tv_sec: src_meta.atime(),
            tv_nsec: src_meta.atime_nsec(),
        };
        let mtime_spec = libc::timespec {
            tv_sec: src_meta.mtime(),
            tv_nsec: src_meta.mtime_nsec(),
        };
        let times = [atime_spec, mtime_spec];
        let c_path = std::ffi::CString::new(dst.as_os_str().as_encoded_bytes())
            .map_err(|e| io::Error::new(io::ErrorKind::InvalidInput, e))?;
        // SAFETY: c_path is a valid NUL-terminated C string, times is a valid [timespec; 2].
        let ret = unsafe { libc::utimensat(libc::AT_FDCWD, c_path.as_ptr(), times.as_ptr(), 0) };
        if ret != 0 {
            return Err(io::Error::last_os_error());
        }
    }

    // Preserve ownership (requires root for chown)
    #[cfg(unix)]
    {
        let c_path = std::ffi::CString::new(dst.as_os_str().as_encoded_bytes())
            .map_err(|e| io::Error::new(io::ErrorKind::InvalidInput, e))?;
        // SAFETY: c_path is a valid NUL-terminated C string, uid/gid are valid u32 values.
        let ret = unsafe { libc::lchown(c_path.as_ptr(), src_meta.uid(), src_meta.gid()) };
        if ret != 0 {
            let err = io::Error::last_os_error();
            // Ownership preservation may fail for non-root; ignore EPERM.
            if err.raw_os_error() != Some(libc::EPERM) {
                return Err(err);
            }
        }
    }

    Ok(())
}

/// Recursively copy a file or directory from `src` to `dst`.
fn copy_recursive(src: &Path, dst: &Path) -> io::Result<()> {
    let metadata = fs::symlink_metadata(src)?;

    if metadata.is_dir() {
        fs::create_dir_all(dst)?;
        for entry in fs::read_dir(src)? {
            let entry = entry?;
            let src_child = entry.path();
            let dst_child = dst.join(entry.file_name());
            copy_recursive(&src_child, &dst_child)?;
        }
        // Preserve directory metadata after contents are copied
        preserve_metadata(&metadata, dst)?;
    } else if metadata.file_type().is_symlink() {
        let link_target = fs::read_link(src)?;
        #[cfg(unix)]
        {
            std::os::unix::fs::symlink(&link_target, dst)?;
        }
        #[cfg(not(unix))]
        {
            // On non-Unix, try a regular copy as fallback
            fs::copy(src, dst)?;
        }
        // Preserve symlink ownership (timestamps are not preserved for symlinks by design)
        #[cfg(unix)]
        {
            let c_path = std::ffi::CString::new(dst.as_os_str().as_encoded_bytes())
                .map_err(|e| io::Error::new(io::ErrorKind::InvalidInput, e))?;
            // SAFETY: c_path is a valid NUL-terminated C string, uid/gid are valid u32 values.
            let ret = unsafe { libc::lchown(c_path.as_ptr(), metadata.uid(), metadata.gid()) };
            if ret != 0 {
                let err = io::Error::last_os_error();
                if err.raw_os_error() != Some(libc::EPERM) {
                    return Err(err);
                }
            }
        }
    } else {
        fs::copy(src, dst)?;
        preserve_metadata(&metadata, dst)?;
    }

    Ok(())
}

/// Recursively remove a file or directory.
fn remove_recursive(path: &Path) -> io::Result<()> {
    let metadata = fs::symlink_metadata(path)?;
    if metadata.is_dir() {
        fs::remove_dir_all(path)
    } else {
        fs::remove_file(path)
    }
}
