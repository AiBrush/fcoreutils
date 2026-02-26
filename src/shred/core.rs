use std::fs;
use std::io::{self, Seek, Write};
use std::path::Path;

/// How to remove files after shredding.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RemoveMode {
    /// Just unlink the file.
    Unlink,
    /// Wipe the filename by renaming before unlinking.
    Wipe,
    /// Wipe and sync before unlinking.
    WipeSync,
}

/// Configuration for the shred operation.
#[derive(Debug, Clone)]
pub struct ShredConfig {
    pub iterations: usize,
    pub zero_pass: bool,
    pub remove: Option<RemoveMode>,
    pub force: bool,
    pub verbose: bool,
    pub exact: bool,
    pub size: Option<u64>,
}

impl Default for ShredConfig {
    fn default() -> Self {
        Self {
            iterations: 3,
            zero_pass: false,
            remove: None,
            force: false,
            verbose: false,
            exact: false,
            size: None,
        }
    }
}

/// Fast userspace PRNG (xorshift128+) for shred data generation.
/// Seeded from /dev/urandom once, then generates all random data in userspace.
/// This is sufficient for shred's purpose (overwriting data to prevent recovery).
struct FastRng {
    s0: u64,
    s1: u64,
}

impl FastRng {
    /// Create a new PRNG seeded from /dev/urandom.
    fn new() -> Self {
        use std::io::Read;
        let mut seed = [0u8; 16];
        if let Ok(mut f) = std::fs::File::open("/dev/urandom") {
            let _ = f.read_exact(&mut seed);
        } else {
            // Fallback: seed from clock
            let t = std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|d| d.as_nanos() as u64)
                .unwrap_or(0x12345678);
            seed[..8].copy_from_slice(&t.to_le_bytes());
            seed[8..].copy_from_slice(&(t.wrapping_mul(0x9E3779B97F4A7C15)).to_le_bytes());
        }
        let s0 = u64::from_le_bytes(seed[..8].try_into().unwrap());
        let s1 = u64::from_le_bytes(seed[8..].try_into().unwrap());
        // Ensure not all-zero state
        Self {
            s0: if s0 == 0 { 0x12345678 } else { s0 },
            s1: if s1 == 0 { 0x87654321 } else { s1 },
        }
    }

    #[inline]
    fn next_u64(&mut self) -> u64 {
        let mut s1 = self.s0;
        let s0 = self.s1;
        let result = s0.wrapping_add(s1);
        self.s0 = s0;
        s1 ^= s1 << 23;
        self.s1 = s1 ^ s0 ^ (s1 >> 18) ^ (s0 >> 5);
        result
    }

    /// Fill a buffer with random bytes entirely in userspace.
    fn fill(&mut self, buf: &mut [u8]) {
        // Fill 8 bytes at a time
        let chunks = buf.len() / 8;
        let ptr = buf.as_mut_ptr() as *mut u64;
        for i in 0..chunks {
            unsafe { ptr.add(i).write_unaligned(self.next_u64()) };
        }
        // Fill remaining bytes
        let remaining = buf.len() % 8;
        if remaining > 0 {
            let val = self.next_u64();
            let start = chunks * 8;
            for j in 0..remaining {
                buf[start + j] = (val >> (j * 8)) as u8;
            }
        }
    }
}

/// Fill a buffer with random bytes using a fast userspace PRNG.
pub fn fill_random(buf: &mut [u8]) {
    let mut rng = FastRng::new();
    rng.fill(buf);
}

/// Shred a single file according to the given configuration.
pub fn shred_file(path: &Path, config: &ShredConfig) -> io::Result<()> {
    // If force, make writable if needed
    if config.force {
        if let Ok(meta) = fs::metadata(path) {
            let mut perms = meta.permissions();
            #[cfg(unix)]
            {
                use std::os::unix::fs::PermissionsExt;
                let mode = perms.mode();
                if mode & 0o200 == 0 {
                    perms.set_mode(mode | 0o200);
                    let _ = fs::set_permissions(path, perms);
                }
            }
            #[cfg(not(unix))]
            {
                #[allow(clippy::permissions_set_readonly_false)]
                if perms.readonly() {
                    perms.set_readonly(false);
                    let _ = fs::set_permissions(path, perms);
                }
            }
        }
    }

    let file_size = if let Some(s) = config.size {
        s
    } else {
        fs::metadata(path)?.len()
    };

    let write_size = if config.exact {
        file_size
    } else {
        // Round up to 512-byte block boundary
        let block = 512u64;
        (file_size + block - 1) / block * block
    };

    let mut file = fs::OpenOptions::new().write(true).open(path)?;
    // Use 1MB buffer for fewer read/write syscalls
    let buf_size = 1024 * 1024usize;
    let mut rng_buf = vec![0u8; buf_size];

    // Create PRNG once and reuse across all passes (seeded from /dev/urandom)
    let mut rng = FastRng::new();

    let total_passes = config.iterations + if config.zero_pass { 1 } else { 0 };

    // Random passes
    for pass in 0..config.iterations {
        if config.verbose {
            eprintln!(
                "shred: {}: pass {}/{} (random)...",
                path.display(),
                pass + 1,
                total_passes
            );
        }
        file.seek(io::SeekFrom::Start(0))?;
        let mut remaining = write_size;
        while remaining > 0 {
            let chunk = remaining.min(rng_buf.len() as u64) as usize;
            rng.fill(&mut rng_buf[..chunk]);
            file.write_all(&rng_buf[..chunk])?;
            remaining -= chunk as u64;
        }
        file.sync_data()?;
    }

    // Zero pass
    if config.zero_pass {
        if config.verbose {
            eprintln!(
                "shred: {}: pass {}/{} (000000)...",
                path.display(),
                total_passes,
                total_passes
            );
        }
        file.seek(io::SeekFrom::Start(0))?;
        let zeros = vec![0u8; buf_size];
        let mut remaining = write_size;
        while remaining > 0 {
            let chunk = remaining.min(zeros.len() as u64) as usize;
            file.write_all(&zeros[..chunk])?;
            remaining -= chunk as u64;
        }
        file.sync_data()?;
    }

    drop(file);

    // Remove file if requested
    if let Some(ref mode) = config.remove {
        match mode {
            RemoveMode::Wipe | RemoveMode::WipeSync => {
                // Try to rename the file to obscure the name before removing
                if let Some(parent) = path.parent() {
                    let name_len = path.file_name().map(|n| n.len()).unwrap_or(1);
                    // Rename to progressively shorter names
                    let mut current = path.to_path_buf();
                    let mut len = name_len;
                    while len > 0 {
                        let new_name: String = std::iter::repeat_n('0', len).collect();
                        let new_path = parent.join(&new_name);
                        if fs::rename(&current, &new_path).is_ok() {
                            if *mode == RemoveMode::WipeSync {
                                // Sync the directory
                                if let Ok(dir) = fs::File::open(parent) {
                                    let _ = dir.sync_all();
                                }
                            }
                            current = new_path;
                        }
                        len /= 2;
                    }
                    if config.verbose {
                        eprintln!("shred: {}: removed", path.display());
                    }
                    fs::remove_file(&current)?;
                } else {
                    if config.verbose {
                        eprintln!("shred: {}: removed", path.display());
                    }
                    fs::remove_file(path)?;
                }
            }
            RemoveMode::Unlink => {
                if config.verbose {
                    eprintln!("shred: {}: removed", path.display());
                }
                fs::remove_file(path)?;
            }
        }
    }

    Ok(())
}

/// Parse a size string with optional suffix (K, M, G, etc.).
pub fn parse_size(s: &str) -> Result<u64, String> {
    if s.is_empty() {
        return Err("invalid size: ''".to_string());
    }

    let s = s.trim();

    // Check for suffix
    let (num_str, multiplier) = if s.ends_with("GB") || s.ends_with("gB") {
        (&s[..s.len() - 2], 1_000_000_000u64)
    } else if s.ends_with("MB") {
        (&s[..s.len() - 2], 1_000_000u64)
    } else if s.ends_with("KB") {
        (&s[..s.len() - 2], 1_000u64)
    } else if s.ends_with('G') || s.ends_with('g') {
        (&s[..s.len() - 1], 1_073_741_824u64)
    } else if s.ends_with('M') || s.ends_with('m') {
        (&s[..s.len() - 1], 1_048_576u64)
    } else if s.ends_with('K') || s.ends_with('k') {
        (&s[..s.len() - 1], 1_024u64)
    } else {
        (s, 1u64)
    };

    // Parse with hex (0x/0X) and octal (0) prefix support
    let value: u64 = if num_str.starts_with("0x") || num_str.starts_with("0X") {
        u64::from_str_radix(&num_str[2..], 16)
            .map_err(|_| format!("invalid size: '{}'", s))?
    } else if num_str.starts_with('0') && num_str.len() > 1 {
        u64::from_str_radix(num_str, 8)
            .map_err(|_| format!("invalid size: '{}'", s))?
    } else {
        num_str
            .parse()
            .map_err(|_| format!("invalid size: '{}'", s))?
    };

    value
        .checked_mul(multiplier)
        .ok_or_else(|| format!("size too large: '{}'", s))
}

/// Parse a --remove[=HOW] argument.
pub fn parse_remove_mode(arg: &str) -> Result<RemoveMode, String> {
    if arg == "--remove" || arg == "-u" {
        Ok(RemoveMode::WipeSync)
    } else if let Some(how) = arg.strip_prefix("--remove=") {
        match how {
            "unlink" => Ok(RemoveMode::Unlink),
            "wipe" => Ok(RemoveMode::Wipe),
            "wipesync" => Ok(RemoveMode::WipeSync),
            _ => Err(format!(
                "invalid argument '{}' for '--remove'\nValid arguments are:\n  - 'unlink'\n  - 'wipe'\n  - 'wipesync'",
                how
            )),
        }
    } else {
        Err(format!("unrecognized option '{}'", arg))
    }
}
