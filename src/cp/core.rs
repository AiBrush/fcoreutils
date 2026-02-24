use std::io;
use std::path::Path;

#[cfg(unix)]
use std::os::unix::fs::MetadataExt;
#[cfg(unix)]
use std::os::unix::fs::PermissionsExt;

/// How to dereference (follow) symbolic links.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DerefMode {
    /// Never follow symlinks (copy the link itself).
    Never,
    /// Follow symlinks given on the command line, but not encountered during recursion.
    CommandLine,
    /// Always follow symlinks.
    Always,
}

/// Backup strategy, following GNU `--backup` semantics.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BackupMode {
    /// Numbered backups (~1~, ~2~, ...).
    Numbered,
    /// Numbered if numbered backups already exist, otherwise simple.
    Existing,
    /// Simple backup with suffix.
    Simple,
    /// Never make backups.
    None,
}

/// Reflink (copy-on-write clone) strategy.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ReflinkMode {
    /// Try reflink, fall back to normal copy.
    Auto,
    /// Require reflink; fail if not supported.
    Always,
    /// Never attempt reflink.
    Never,
}

/// Configuration for a cp invocation.
pub struct CpConfig {
    pub recursive: bool,
    pub force: bool,
    pub interactive: bool,
    pub no_clobber: bool,
    pub verbose: bool,
    pub preserve_mode: bool,
    pub preserve_ownership: bool,
    pub preserve_timestamps: bool,
    pub dereference: DerefMode,
    pub link: bool,
    pub symbolic_link: bool,
    pub update: bool,
    pub one_file_system: bool,
    pub backup: Option<BackupMode>,
    pub suffix: String,
    pub reflink: ReflinkMode,
    pub target_directory: Option<String>,
    pub no_target_directory: bool,
}

impl Default for CpConfig {
    fn default() -> Self {
        Self {
            recursive: false,
            force: false,
            interactive: false,
            no_clobber: false,
            verbose: false,
            preserve_mode: false,
            preserve_ownership: false,
            preserve_timestamps: false,
            dereference: DerefMode::CommandLine,
            link: false,
            symbolic_link: false,
            update: false,
            one_file_system: false,
            backup: None,
            suffix: "~".to_string(),
            reflink: ReflinkMode::Auto,
            target_directory: None,
            no_target_directory: false,
        }
    }
}

/// Parse a `--backup=CONTROL` value.
pub fn parse_backup_mode(s: &str) -> Result<BackupMode, String> {
    match s {
        "none" | "off" => Ok(BackupMode::None),
        "numbered" | "t" => Ok(BackupMode::Numbered),
        "existing" | "nil" => Ok(BackupMode::Existing),
        "simple" | "never" => Ok(BackupMode::Simple),
        _ => Err(format!("invalid backup type '{}'", s)),
    }
}

/// Parse a `--reflink[=WHEN]` value.
pub fn parse_reflink_mode(s: &str) -> Result<ReflinkMode, String> {
    match s {
        "auto" => Ok(ReflinkMode::Auto),
        "always" => Ok(ReflinkMode::Always),
        "never" => Ok(ReflinkMode::Never),
        _ => Err(format!("invalid reflink value '{}'", s)),
    }
}

/// Parse a `--preserve[=LIST]` attribute list.
///
/// Supports: mode, ownership, timestamps, links, context, xattr, all.
pub fn apply_preserve(list: &str, config: &mut CpConfig) {
    for attr in list.split(',') {
        match attr.trim() {
            "mode" => config.preserve_mode = true,
            "ownership" => config.preserve_ownership = true,
            "timestamps" => config.preserve_timestamps = true,
            "links" | "context" | "xattr" => { /* acknowledged but not yet implemented */ }
            "all" => {
                config.preserve_mode = true;
                config.preserve_ownership = true;
                config.preserve_timestamps = true;
            }
            _ => {}
        }
    }
}

// ---- backup helpers ----

/// Create a backup of `dst` if it exists, according to the configured backup mode.
/// Returns `Ok(())` when no backup is needed or the backup was made successfully.
fn make_backup(dst: &Path, config: &CpConfig) -> io::Result<()> {
    let mode = match config.backup {
        Some(m) => m,
        None => return Ok(()),
    };
    if mode == BackupMode::None {
        return Ok(());
    }
    if !dst.exists() {
        return Ok(());
    }

    let backup_path = match mode {
        BackupMode::Simple | BackupMode::None => {
            let mut p = dst.as_os_str().to_os_string();
            p.push(&config.suffix);
            std::path::PathBuf::from(p)
        }
        BackupMode::Numbered => numbered_backup_path(dst),
        BackupMode::Existing => {
            // Use numbered if any numbered backup already exists.
            let numbered = numbered_backup_candidate(dst, 1);
            if numbered.exists() {
                numbered_backup_path(dst)
            } else {
                let mut p = dst.as_os_str().to_os_string();
                p.push(&config.suffix);
                std::path::PathBuf::from(p)
            }
        }
    };

    std::fs::rename(dst, &backup_path)?;
    Ok(())
}

fn numbered_backup_path(dst: &Path) -> std::path::PathBuf {
    let mut n: u64 = 1;
    loop {
        let candidate = numbered_backup_candidate(dst, n);
        if !candidate.exists() {
            return candidate;
        }
        n += 1;
    }
}

fn numbered_backup_candidate(dst: &Path, n: u64) -> std::path::PathBuf {
    let mut p = dst.as_os_str().to_os_string();
    p.push(format!(".~{}~", n));
    std::path::PathBuf::from(p)
}

// ---- attribute preservation ----

/// Preserve file attributes (mode, timestamps, ownership) on `dst` using
/// pre-fetched source metadata (avoids redundant stat calls).
fn preserve_attributes_from_meta(
    meta: &std::fs::Metadata,
    dst: &Path,
    config: &CpConfig,
) -> io::Result<()> {
    // Only chmod when -p/--preserve=mode is set. Without it, the destination
    // keeps its O_CREAT permissions (source_mode & ~umask), matching GNU cp.
    #[cfg(unix)]
    if config.preserve_mode {
        let mode = meta.mode();
        std::fs::set_permissions(dst, std::fs::Permissions::from_mode(mode))?;
    }

    #[cfg(unix)]
    if config.preserve_timestamps {
        let atime_spec = libc::timespec {
            tv_sec: meta.atime(),
            tv_nsec: meta.atime_nsec(),
        };
        let mtime_spec = libc::timespec {
            tv_sec: meta.mtime(),
            tv_nsec: meta.mtime_nsec(),
        };
        let times = [atime_spec, mtime_spec];
        // SAFETY: CString::new checks for interior NULs; the path is valid UTF-8/bytes.
        let c_path = std::ffi::CString::new(dst.as_os_str().as_encoded_bytes())
            .map_err(|e| io::Error::new(io::ErrorKind::InvalidInput, e))?;
        // SAFETY: c_path is a valid NUL-terminated C string, times is a valid [timespec; 2].
        let ret = unsafe { libc::utimensat(libc::AT_FDCWD, c_path.as_ptr(), times.as_ptr(), 0) };
        if ret != 0 {
            return Err(io::Error::last_os_error());
        }
    }

    #[cfg(unix)]
    if config.preserve_ownership {
        // SAFETY: CString::new checks for interior NULs; the path is valid bytes.
        let c_path = std::ffi::CString::new(dst.as_os_str().as_encoded_bytes())
            .map_err(|e| io::Error::new(io::ErrorKind::InvalidInput, e))?;
        // SAFETY: c_path is a valid NUL-terminated C string, uid/gid are valid u32 values.
        let ret = unsafe { libc::lchown(c_path.as_ptr(), meta.uid(), meta.gid()) };
        if ret != 0 {
            // Ownership preservation may fail for non-root; ignore EPERM.
            let err = io::Error::last_os_error();
            if err.raw_os_error() != Some(libc::EPERM) {
                return Err(err);
            }
        }
    }

    // Suppress unused-variable warnings on non-unix platforms.
    #[cfg(not(unix))]
    {
        let _ = (meta, config);
    }

    Ok(())
}

// ---- large-buffer fallback copy ----

/// Copy file data using a thread-local buffer (up to 4MB, capped to file size).
/// Avoids stdlib's 64KB default buffer and amortizes allocation across files.
/// Creates the destination with `src_mode` so the kernel applies the process umask.
fn copy_data_large_buf(src: &Path, dst: &Path, src_len: u64, src_mode: u32) -> io::Result<()> {
    use std::cell::RefCell;
    use std::io::{Read, Write};
    const MAX_BUF: usize = 4 * 1024 * 1024; // 4 MB
    /// Shrink the thread-local buffer when it exceeds this size and the current
    /// file needs much less, to avoid holding 4 MB per Rayon thread permanently.
    const SHRINK_THRESHOLD: usize = 512 * 1024; // 512 KB

    thread_local! {
        static BUF: RefCell<Vec<u8>> = const { RefCell::new(Vec::new()) };
    }

    // Safe on 32-bit: clamp via u64 before casting to usize.
    let buf_size = src_len.min(MAX_BUF as u64).max(8192) as usize;

    let mut reader = std::fs::File::open(src)?;
    let mut opts = std::fs::OpenOptions::new();
    opts.write(true).create(true).truncate(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        opts.mode(src_mode);
    }
    #[cfg(not(unix))]
    let _ = src_mode;
    let mut writer = opts.open(dst)?;

    BUF.with(|cell| {
        let mut buf = cell.borrow_mut();
        // Shrink if buffer is much larger than needed to limit per-thread memory.
        if buf.len() > SHRINK_THRESHOLD && buf_size < buf.len() / 4 {
            buf.resize(buf_size, 0);
            buf.shrink_to_fit();
        } else if buf.len() < buf_size {
            buf.resize(buf_size, 0);
        }
        loop {
            let n = reader.read(&mut buf[..buf_size])?;
            if n == 0 {
                break;
            }
            writer.write_all(&buf[..n])?;
        }
        Ok(())
    })
}

// ---- Linux copy_file_range optimisation ----

#[cfg(target_os = "linux")]
fn copy_file_range_linux(src: &Path, dst: &Path, src_mode: u32, src_len: u64) -> io::Result<()> {
    use std::os::unix::fs::OpenOptionsExt;
    use std::os::unix::io::AsRawFd;

    let src_file = std::fs::File::open(src)?;
    let len = src_len;

    let dst_file = std::fs::OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(true)
        .mode(src_mode)
        .open(dst)?;

    let mut remaining = len as i64;
    while remaining > 0 {
        // Cap to isize::MAX to avoid overflow on 32-bit when casting to usize.
        let to_copy = (remaining as u64).min(isize::MAX as u64) as usize;
        // SAFETY: src_file and dst_file are valid open file descriptors;
        // null offsets mean the kernel uses and updates the file offsets.
        // Uses raw syscall instead of libc::copy_file_range to support
        // older glibc versions (e.g. cross-compilation with cross-rs).
        let ret = unsafe {
            libc::syscall(
                libc::SYS_copy_file_range,
                src_file.as_raw_fd(),
                std::ptr::null_mut::<libc::off64_t>(),
                dst_file.as_raw_fd(),
                std::ptr::null_mut::<libc::off64_t>(),
                to_copy,
                0u32,
            )
        };
        if ret < 0 {
            return Err(io::Error::last_os_error());
        }
        if ret == 0 {
            // EOF before all bytes copied — break to avoid infinite loop
            break;
        }
        remaining -= ret as i64;
    }
    Ok(())
}

// ---- single-file copy ----

/// Copy a single file (or symlink) from `src` to `dst`.
pub fn copy_file(src: &Path, dst: &Path, config: &CpConfig) -> io::Result<()> {
    let src_meta = if config.dereference == DerefMode::Always {
        std::fs::metadata(src)?
    } else {
        std::fs::symlink_metadata(src)?
    };

    copy_file_with_meta(src, dst, &src_meta, config)
}

/// Copy a single file using pre-fetched metadata (avoids redundant stat).
fn copy_file_with_meta(
    src: &Path,
    dst: &Path,
    src_meta: &std::fs::Metadata,
    config: &CpConfig,
) -> io::Result<()> {
    // Handle symlink when not dereferencing.
    if src_meta.file_type().is_symlink() && config.dereference == DerefMode::Never {
        let target = std::fs::read_link(src)?;
        #[cfg(unix)]
        {
            std::os::unix::fs::symlink(&target, dst)?;
        }
        #[cfg(not(unix))]
        {
            // Fallback: try a regular copy (symlinks are not portable).
            let _ = target;
            std::fs::copy(src, dst)?;
        }
        return Ok(());
    }

    // Hard link mode.
    if config.link {
        std::fs::hard_link(src, dst)?;
        return Ok(());
    }

    // Symbolic link mode.
    if config.symbolic_link {
        #[cfg(unix)]
        {
            std::os::unix::fs::symlink(src, dst)?;
        }
        #[cfg(not(unix))]
        {
            return Err(io::Error::new(
                io::ErrorKind::Unsupported,
                "symbolic links are not supported on this platform",
            ));
        }
        return Ok(());
    }

    // Try reflink (FICLONE ioctl) for instant CoW copy on btrfs/XFS.
    #[cfg(target_os = "linux")]
    {
        if matches!(config.reflink, ReflinkMode::Auto | ReflinkMode::Always) {
            use std::os::unix::io::AsRawFd;
            // FICLONE = _IOW(0x94, 9, int) from linux/fs.h
            const FICLONE: libc::c_ulong = 0x40049409;

            if let Ok(src_file) = std::fs::File::open(src) {
                let dst_file = std::fs::OpenOptions::new()
                    .write(true)
                    .create(true)
                    .truncate(true)
                    .open(dst);
                if let Ok(dst_file) = dst_file {
                    // SAFETY: Both file descriptors are valid (files are open),
                    // FICLONE takes an fd as argument, and we check the return value.
                    let ret =
                        unsafe { libc::ioctl(dst_file.as_raw_fd(), FICLONE, src_file.as_raw_fd()) };
                    if ret == 0 {
                        preserve_attributes_from_meta(src_meta, dst, config)?;
                        return Ok(());
                    }
                    if config.reflink == ReflinkMode::Always {
                        return Err(io::Error::new(
                            io::ErrorKind::Unsupported,
                            format!(
                                "failed to clone '{}' to '{}': {}",
                                src.display(),
                                dst.display(),
                                io::Error::last_os_error()
                            ),
                        ));
                    }
                    // Auto mode: fall through to other copy methods
                }
            }
        }
    }

    // Try Linux copy_file_range for zero-copy.
    #[cfg(target_os = "linux")]
    let src_mode_bits = src_meta.mode();
    #[cfg(target_os = "linux")]
    {
        match copy_file_range_linux(src, dst, src_mode_bits, src_meta.len()) {
            Ok(()) => {
                preserve_attributes_from_meta(src_meta, dst, config)?;
                return Ok(());
            }
            Err(e)
                if matches!(
                    e.raw_os_error(),
                    Some(libc::EINVAL | libc::ENOSYS | libc::EXDEV)
                ) =>
            {
                // Unsupported/cross-device — fall through to large-buffer copy
            }
            Err(e) => return Err(e),
        }
    }

    // Fallback: large-buffer copy (up to 4MB vs stdlib's 64KB).
    #[cfg(unix)]
    let mode = src_meta.mode();
    #[cfg(not(unix))]
    let mode = 0o666u32;
    copy_data_large_buf(src, dst, src_meta.len(), mode)?;
    preserve_attributes_from_meta(src_meta, dst, config)?;
    Ok(())
}

// ---- recursive copy ----

/// Recursively copy `src` to `dst`, using parallel file copies within each directory.
fn copy_recursive(
    src: &Path,
    dst: &Path,
    config: &CpConfig,
    root_dev: Option<u64>,
) -> io::Result<()> {
    let src_meta = std::fs::symlink_metadata(src)?;

    #[cfg(unix)]
    if config.one_file_system {
        if let Some(dev) = root_dev {
            if src_meta.dev() != dev {
                return Ok(());
            }
        }
    }

    if src_meta.is_dir() {
        if !dst.exists() {
            std::fs::create_dir_all(dst)?;
        }

        #[cfg(unix)]
        let next_dev = Some(root_dev.unwrap_or(src_meta.dev()));
        #[cfg(not(unix))]
        let next_dev: Option<u64> = None;

        // Collect entries and partition into files and directories.
        let mut files: Vec<(std::path::PathBuf, std::path::PathBuf, std::fs::Metadata)> =
            Vec::new();
        let mut dirs: Vec<(std::path::PathBuf, std::path::PathBuf)> = Vec::new();

        for entry in std::fs::read_dir(src)? {
            let entry = entry?;
            let child_src = entry.path();
            let child_dst = dst.join(entry.file_name());
            // Respect dereference mode: follow symlinks when Always.
            let meta = if config.dereference == DerefMode::Always {
                std::fs::metadata(&child_src)?
            } else {
                std::fs::symlink_metadata(&child_src)?
            };
            // Check --one-file-system for all entries (not just directories).
            #[cfg(unix)]
            if config.one_file_system {
                if let Some(dev) = root_dev {
                    if meta.dev() != dev {
                        continue;
                    }
                }
            }
            if meta.is_dir() {
                dirs.push((child_src, child_dst));
            } else {
                files.push((child_src, child_dst, meta));
            }
        }

        /// Minimum number of files before we parallelize copies within a directory.
        /// Rayon dispatch overhead dominates below this threshold (empirical).
        const PARALLEL_FILE_THRESHOLD: usize = 8;

        // Copy files in parallel using Rayon when there are enough to benefit.
        if files.len() >= PARALLEL_FILE_THRESHOLD {
            use rayon::prelude::*;
            let result: Result<(), io::Error> =
                files
                    .par_iter()
                    .try_for_each(|(child_src, child_dst, meta)| {
                        copy_file_with_meta(child_src, child_dst, meta, config)
                    });
            result?;
        } else {
            for (child_src, child_dst, meta) in &files {
                copy_file_with_meta(child_src, child_dst, meta, config)?;
            }
        }

        // Recurse into subdirectories sequentially (they may create dirs that
        // need to exist before their children can be copied).
        for (child_src, child_dst) in &dirs {
            copy_recursive(child_src, child_dst, config, next_dev)?;
        }

        // Preserve directory attributes after copying contents.
        preserve_attributes_from_meta(&src_meta, dst, config)?;
    } else {
        // If parent directory does not exist, create it.
        if let Some(parent) = dst.parent() {
            if !parent.exists() {
                std::fs::create_dir_all(parent)?;
            }
        }
        copy_file_with_meta(src, dst, &src_meta, config)?;
    }
    Ok(())
}

// ---- main entry point ----

/// Determine the effective destination and perform the copy.
///
/// `sources` is the list of source paths; `raw_dest` is the positional destination
/// (may be `None` when `--target-directory` is used).
///
/// Returns a list of per-file error messages (empty on full success) and a bool
/// indicating whether any error occurred.
pub fn run_cp(
    sources: &[String],
    raw_dest: Option<&str>,
    config: &CpConfig,
) -> (Vec<String>, bool) {
    let mut errors: Vec<String> = Vec::new();
    let mut had_error = false;

    // Resolve destination directory.
    let dest_dir: Option<std::path::PathBuf> = config
        .target_directory
        .as_deref()
        .or(raw_dest)
        .map(std::path::PathBuf::from);

    let dest_dir = match dest_dir {
        Some(d) => d,
        None => {
            errors.push("cp: missing destination operand".to_string());
            return (errors, true);
        }
    };

    // Multiple sources or target is an existing directory => copy into directory.
    let copy_into_dir = sources.len() > 1 || dest_dir.is_dir() || config.target_directory.is_some();

    // When -T is set, never treat destination as a directory.
    let copy_into_dir = copy_into_dir && !config.no_target_directory;

    for source in sources {
        let src = Path::new(source);
        let dst = if copy_into_dir {
            let name = src.file_name().unwrap_or(src.as_ref());
            dest_dir.join(name)
        } else {
            dest_dir.clone()
        };

        if let Err(e) = do_copy(src, &dst, config) {
            let msg = format!(
                "cp: cannot copy '{}' to '{}': {}",
                src.display(),
                dst.display(),
                strip_os_error(&e)
            );
            errors.push(msg);
            had_error = true;
        } else if config.verbose {
            // Verbose output goes to stderr to match GNU behavior when piped.
            eprintln!("'{}' -> '{}'", src.display(), dst.display());
        }
    }

    (errors, had_error)
}

/// Core copy dispatcher for a single source -> destination pair.
fn do_copy(src: &Path, dst: &Path, config: &CpConfig) -> io::Result<()> {
    let src_meta = if config.dereference == DerefMode::Always {
        std::fs::metadata(src)?
    } else {
        std::fs::symlink_metadata(src)?
    };

    // Reject directory source without -R.
    if src_meta.is_dir() && !config.recursive {
        return Err(io::Error::new(
            io::ErrorKind::Other,
            format!("omitting directory '{}'", src.display()),
        ));
    }

    // No-clobber: skip if destination exists.
    if config.no_clobber && dst.exists() {
        return Ok(());
    }

    // Update: skip if destination is same age or newer.
    if config.update && dst.exists() {
        if let (Ok(src_m), Ok(dst_m)) = (src.metadata(), dst.metadata()) {
            if let (Ok(src_t), Ok(dst_t)) = (src_m.modified(), dst_m.modified()) {
                if dst_t >= src_t {
                    return Ok(());
                }
            }
        }
    }

    // Interactive: prompt on stderr.
    if config.interactive && dst.exists() {
        eprint!("cp: overwrite '{}'? ", dst.display());
        let mut response = String::new();
        io::stdin().read_line(&mut response)?;
        let r = response.trim().to_lowercase();
        if !(r == "y" || r == "yes") {
            return Ok(());
        }
    }

    // Force: remove existing destination if it cannot be opened for writing.
    if config.force && dst.exists() {
        if let Ok(m) = dst.metadata() {
            if m.permissions().readonly() {
                std::fs::remove_file(dst)?;
            }
        }
    }

    // Make backup if requested.
    make_backup(dst, config)?;

    if src_meta.is_dir() {
        #[cfg(unix)]
        let root_dev = Some(src_meta.dev());
        #[cfg(not(unix))]
        let root_dev: Option<u64> = None;
        copy_recursive(src, dst, config, root_dev)
    } else {
        copy_file(src, dst, config)
    }
}

/// Strip the " (os error N)" suffix from an io::Error for GNU-compatible messages.
fn strip_os_error(e: &io::Error) -> String {
    if let Some(raw) = e.raw_os_error() {
        let msg = format!("{}", e);
        msg.replace(&format!(" (os error {})", raw), "")
    } else {
        format!("{}", e)
    }
}
