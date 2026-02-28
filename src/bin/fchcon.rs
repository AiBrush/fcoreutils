// fchcon -- change file SELinux security context
//
// Usage: chcon [OPTION]... CONTEXT FILE...
//        chcon [OPTION]... [-u USER] [-r ROLE] [-l RANGE] [-t TYPE] FILE...
//        chcon [OPTION]... --reference=RFILE FILE...

#[cfg(not(unix))]
fn main() {
    eprintln!("chcon: only available on Unix");
    std::process::exit(1);
}

/// All chcon configuration packed into a single struct to avoid too-many-arguments.
#[cfg(unix)]
struct ChconConfig {
    context: Option<String>,
    ref_context: Option<String>,
    user: Option<String>,
    role: Option<String>,
    typ: Option<String>,
    range: Option<String>,
    has_partial: bool,
    recursive: bool,
    verbose: bool,
    no_dereference: bool,
    traverse_mode: u8,
}

/// Mutable parsing state (used during arg parsing, then converted to ChconConfig).
#[cfg(unix)]
#[derive(Default)]
struct ParseOpts {
    user: Option<String>,
    role: Option<String>,
    typ: Option<String>,
    range: Option<String>,
    no_dereference: bool,
    recursive: bool,
    verbose: bool,
    traverse_mode: u8,
}

#[cfg(unix)]
fn main() {
    coreutils_rs::common::reset_sigpipe();

    let args: Vec<String> = std::env::args().skip(1).collect();

    let mut opts = ParseOpts {
        traverse_mode: b'P',
        ..Default::default()
    };
    let mut reference: Option<String> = None;
    let mut preserve_root = false;
    let mut positional: Vec<String> = Vec::new();
    let mut saw_dashdash = false;

    let mut i = 0;
    while i < args.len() {
        let arg = &args[i];

        if saw_dashdash {
            positional.push(arg.clone());
            i += 1;
            continue;
        }

        match arg.as_str() {
            "--help" => {
                print_help();
                return;
            }
            "--version" => {
                println!("chcon (fcoreutils) {}", env!("CARGO_PKG_VERSION"));
                return;
            }
            "--" => {
                saw_dashdash = true;
                i += 1;
                continue;
            }
            "--dereference" => opts.no_dereference = false,
            "-h" | "--no-dereference" => opts.no_dereference = true,
            "-R" | "--recursive" => opts.recursive = true,
            "-v" | "--verbose" => opts.verbose = true,
            "--no-preserve-root" => preserve_root = false,
            "--preserve-root" => preserve_root = true,
            "-H" => opts.traverse_mode = b'H',
            "-L" => opts.traverse_mode = b'L',
            "-P" => opts.traverse_mode = b'P',
            "-u" | "--user" => {
                i += 1;
                require_arg(&args, i, arg);
                opts.user = Some(args[i].clone());
            }
            "-r" | "--role" => {
                i += 1;
                require_arg(&args, i, arg);
                opts.role = Some(args[i].clone());
            }
            "-t" | "--type" => {
                i += 1;
                require_arg(&args, i, arg);
                opts.typ = Some(args[i].clone());
            }
            "-l" | "--range" => {
                i += 1;
                require_arg(&args, i, arg);
                opts.range = Some(args[i].clone());
            }
            s if s.starts_with("--user=") => opts.user = Some(s["--user=".len()..].to_string()),
            s if s.starts_with("--role=") => opts.role = Some(s["--role=".len()..].to_string()),
            s if s.starts_with("--type=") => opts.typ = Some(s["--type=".len()..].to_string()),
            s if s.starts_with("--range=") => opts.range = Some(s["--range=".len()..].to_string()),
            s if s.starts_with("--reference=") => {
                reference = Some(s["--reference=".len()..].to_string());
            }
            "--reference" => {
                i += 1;
                require_arg(&args, i, "--reference");
                reference = Some(args[i].clone());
            }
            s if s.starts_with("--") => {
                eprintln!("chcon: unrecognized option '{}'", s);
                eprintln!("Try 'chcon --help' for more information.");
                std::process::exit(1);
            }
            s if s.starts_with('-') && s.len() > 1 => {
                parse_short_opts(s, &args, &mut i, &mut opts);
            }
            _ => positional.push(arg.clone()),
        }
        i += 1;
    }

    let has_partial =
        opts.user.is_some() || opts.role.is_some() || opts.typ.is_some() || opts.range.is_some();

    // Determine context and files
    let (context, files): (Option<String>, Vec<String>) = if reference.is_some() || has_partial {
        if positional.is_empty() {
            eprintln!("chcon: missing operand");
            eprintln!("Try 'chcon --help' for more information.");
            std::process::exit(1);
        }
        (None, positional)
    } else {
        if positional.is_empty() {
            eprintln!("chcon: missing operand");
            eprintln!("Try 'chcon --help' for more information.");
            std::process::exit(1);
        }
        if positional.len() == 1 {
            eprintln!("chcon: missing operand after '{}'", positional[0]);
            eprintln!("Try 'chcon --help' for more information.");
            std::process::exit(1);
        }
        let ctx = positional[0].clone();
        let fls = positional[1..].to_vec();
        (Some(ctx), fls)
    };

    // Check preserve-root (canonicalize to catch "//" , "foo/../.." etc.)
    if opts.recursive && preserve_root {
        for f in &files {
            let is_root = std::path::Path::new(f)
                .canonicalize()
                .map(|p| p.as_os_str() == "/")
                .unwrap_or(f == "/");
            if is_root {
                eprintln!("chcon: it is dangerous to operate recursively on '/'");
                eprintln!("chcon: use --no-preserve-root to override this failsafe");
                std::process::exit(1);
            }
        }
    }

    // Read reference context if needed
    let ref_context: Option<String> = reference.as_ref().map(|rfile| {
        get_file_context(rfile, opts.no_dereference).unwrap_or_else(|e| {
            eprintln!(
                "chcon: failed to get security context of '{}': {}",
                rfile, e
            );
            std::process::exit(1);
        })
    });

    let cfg = ChconConfig {
        context,
        ref_context,
        user: opts.user,
        role: opts.role,
        typ: opts.typ,
        range: opts.range,
        has_partial,
        recursive: opts.recursive,
        verbose: opts.verbose,
        no_dereference: opts.no_dereference,
        traverse_mode: opts.traverse_mode,
    };

    let mut had_error = false;
    for file in &files {
        if process_file(file, &cfg, true).is_err() {
            had_error = true;
        }
    }

    if had_error {
        std::process::exit(1);
    }
}

#[cfg(unix)]
fn require_arg(args: &[String], i: usize, opt: &str) {
    if i >= args.len() {
        eprintln!("chcon: option '{}' requires an argument", opt);
        std::process::exit(1);
    }
}

#[cfg(unix)]
fn parse_short_opts(s: &str, args: &[String], i: &mut usize, opts: &mut ParseOpts) {
    let bytes = s.as_bytes();
    let mut j = 1;
    while j < bytes.len() {
        match bytes[j] {
            b'h' => opts.no_dereference = true,
            b'R' => opts.recursive = true,
            b'v' => opts.verbose = true,
            b'H' => opts.traverse_mode = b'H',
            b'L' => opts.traverse_mode = b'L',
            b'P' => opts.traverse_mode = b'P',
            ch @ (b'u' | b'r' | b't' | b'l') => {
                let val = if j + 1 < bytes.len() {
                    String::from_utf8_lossy(&bytes[j + 1..]).to_string()
                } else {
                    *i += 1;
                    if *i >= args.len() {
                        eprintln!("chcon: option requires an argument -- '{}'", ch as char);
                        std::process::exit(1);
                    }
                    args[*i].clone()
                };
                match ch {
                    b'u' => opts.user = Some(val),
                    b'r' => opts.role = Some(val),
                    b't' => opts.typ = Some(val),
                    _ => opts.range = Some(val),
                }
                return;
            }
            ch => {
                eprintln!("chcon: invalid option -- '{}'", ch as char);
                eprintln!("Try 'chcon --help' for more information.");
                std::process::exit(1);
            }
        }
        j += 1;
    }
}

#[cfg(unix)]
fn process_file(path: &str, cfg: &ChconConfig, cmdline: bool) -> Result<(), ()> {
    // For -H: follow symlinks only for command-line arguments
    // For -L: always follow symlinks
    // For -P: never follow symlinks (default)
    let follow = match cfg.traverse_mode {
        b'L' => !cfg.no_dereference,
        b'H' if cmdline => true,
        _ => !cfg.no_dereference,
    };
    let md = if follow {
        std::fs::metadata(path)
    } else {
        std::fs::symlink_metadata(path)
    };
    let md = match md {
        Ok(m) => m,
        Err(e) => {
            eprintln!(
                "chcon: cannot access '{}': {}",
                path,
                coreutils_rs::common::io_error_msg(&e)
            );
            return Err(());
        }
    };

    let mut had_error = false;

    if change_context(path, cfg).is_err() {
        had_error = true;
    }

    if cfg.recursive && md.is_dir() && recurse_dir(path, cfg).is_err() {
        had_error = true;
    }

    if had_error { Err(()) } else { Ok(()) }
}

#[cfg(unix)]
fn recurse_dir(dir: &str, cfg: &ChconConfig) -> Result<(), ()> {
    let entries = match std::fs::read_dir(dir) {
        Ok(e) => e,
        Err(e) => {
            eprintln!(
                "chcon: cannot read directory '{}': {}",
                dir,
                coreutils_rs::common::io_error_msg(&e)
            );
            return Err(());
        }
    };

    let mut had_error = false;
    for entry in entries {
        let entry = match entry {
            Ok(e) => e,
            Err(e) => {
                eprintln!(
                    "chcon: cannot read directory entry in '{}': {}",
                    dir,
                    coreutils_rs::common::io_error_msg(&e)
                );
                had_error = true;
                continue;
            }
        };
        let child_path = entry.path();
        let child = child_path.to_string_lossy().to_string();

        if change_context(&child, cfg).is_err() {
            had_error = true;
        }

        let follow = cfg.traverse_mode == b'L';
        let md = if follow {
            std::fs::metadata(&child)
        } else {
            std::fs::symlink_metadata(&child)
        };
        if let Ok(md) = md
            && md.is_dir()
            && recurse_dir(&child, cfg).is_err()
        {
            had_error = true;
        }
    }

    if had_error { Err(()) } else { Ok(()) }
}

#[cfg(unix)]
fn change_context(path: &str, cfg: &ChconConfig) -> Result<(), ()> {
    if let Some(ctx) = &cfg.ref_context {
        return set_file_context(path, ctx, cfg.no_dereference, cfg.verbose);
    }

    if let Some(ctx) = &cfg.context {
        return set_file_context(path, ctx, cfg.no_dereference, cfg.verbose);
    }

    if cfg.has_partial {
        let current = match get_file_context(path, cfg.no_dereference) {
            Ok(ctx) => ctx,
            Err(_) => {
                eprintln!(
                    "chcon: can't apply partial context to unlabeled file '{}'",
                    path
                );
                return Err(());
            }
        };

        let parts: Vec<&str> = current.splitn(4, ':').collect();
        if parts.len() < 3 {
            eprintln!(
                "chcon: can't apply partial context to unlabeled file '{}'",
                path
            );
            return Err(());
        }

        let new_user = cfg.user.as_deref().unwrap_or(parts[0]);
        let new_role = cfg.role.as_deref().unwrap_or(parts[1]);
        let new_type = cfg.typ.as_deref().unwrap_or(parts[2]);
        let new_range =
            cfg.range
                .as_deref()
                .unwrap_or(if parts.len() > 3 { parts[3] } else { "s0" });

        let new_ctx = format!("{}:{}:{}:{}", new_user, new_role, new_type, new_range);
        return set_file_context(path, &new_ctx, cfg.no_dereference, cfg.verbose);
    }

    Ok(())
}

// --- Cross-platform xattr helpers ---

#[cfg(target_os = "linux")]
fn get_file_context(path: &str, no_dereference: bool) -> Result<String, String> {
    use std::ffi::CString;

    let c_path = CString::new(path).map_err(|_| "invalid path".to_string())?;
    let c_name = CString::new("security.selinux").unwrap();

    // Two-pass approach: query required size first, then read
    let get_xattr = |buf: *mut libc::c_void, size: usize| -> isize {
        if no_dereference {
            unsafe { libc::lgetxattr(c_path.as_ptr(), c_name.as_ptr(), buf, size) }
        } else {
            unsafe { libc::getxattr(c_path.as_ptr(), c_name.as_ptr(), buf, size) }
        }
    };

    let needed = get_xattr(std::ptr::null_mut(), 0);
    if needed < 0 {
        let err = std::io::Error::last_os_error();
        return Err(coreutils_rs::common::io_error_msg(&err));
    }

    let mut buf = vec![0u8; needed as usize];
    let len = get_xattr(buf.as_mut_ptr() as *mut libc::c_void, buf.len());

    parse_xattr_result(&buf, len)
}

#[cfg(target_os = "macos")]
fn get_file_context(path: &str, no_dereference: bool) -> Result<String, String> {
    use std::ffi::CString;

    let c_path = CString::new(path).map_err(|_| "invalid path".to_string())?;
    let c_name = CString::new("security.selinux").unwrap();

    let options: libc::c_int = if no_dereference {
        0x0001 /* XATTR_NOFOLLOW */
    } else {
        0
    };

    // Two-pass approach: query required size first, then read
    let get_xattr = |buf: *mut libc::c_void, size: usize| -> isize {
        unsafe { libc::getxattr(c_path.as_ptr(), c_name.as_ptr(), buf, size, 0, options) }
    };

    let needed = get_xattr(std::ptr::null_mut(), 0);
    if needed < 0 {
        let err = std::io::Error::last_os_error();
        return Err(coreutils_rs::common::io_error_msg(&err));
    }

    let mut buf = vec![0u8; needed as usize];
    let len = get_xattr(buf.as_mut_ptr() as *mut libc::c_void, buf.len());

    parse_xattr_result(&buf, len)
}

// Fallback for other Unix platforms (FreeBSD, etc.)
#[cfg(all(unix, not(target_os = "linux"), not(target_os = "macos")))]
fn get_file_context(_path: &str, _no_dereference: bool) -> Result<String, String> {
    Err("extended attributes not supported on this platform".to_string())
}

#[cfg(unix)]
fn parse_xattr_result(buf: &[u8], len: isize) -> Result<String, String> {
    if len < 0 {
        let err = std::io::Error::last_os_error();
        Err(coreutils_rs::common::io_error_msg(&err))
    } else {
        let actual_len = if len > 0 && buf[len as usize - 1] == 0 {
            len as usize - 1
        } else {
            len as usize
        };
        String::from_utf8(buf[..actual_len].to_vec())
            .map_err(|_| "invalid context encoding".to_string())
    }
}

#[cfg(target_os = "linux")]
fn set_file_context(
    path: &str,
    context: &str,
    no_dereference: bool,
    verbose: bool,
) -> Result<(), ()> {
    use std::ffi::CString;

    let c_path = CString::new(path).map_err(|_| ())?;
    let c_name = CString::new("security.selinux").unwrap();
    let c_value = context.as_bytes();

    let ret = if no_dereference {
        unsafe {
            libc::lsetxattr(
                c_path.as_ptr(),
                c_name.as_ptr(),
                c_value.as_ptr() as *const libc::c_void,
                c_value.len(),
                0,
            )
        }
    } else {
        unsafe {
            libc::setxattr(
                c_path.as_ptr(),
                c_name.as_ptr(),
                c_value.as_ptr() as *const libc::c_void,
                c_value.len(),
                0,
            )
        }
    };

    report_set_result(ret, path, context, verbose)
}

#[cfg(target_os = "macos")]
fn set_file_context(
    path: &str,
    context: &str,
    no_dereference: bool,
    verbose: bool,
) -> Result<(), ()> {
    use std::ffi::CString;

    let c_path = CString::new(path).map_err(|_| ())?;
    let c_name = CString::new("security.selinux").unwrap();
    let c_value = context.as_bytes();

    let options: libc::c_int = if no_dereference {
        0x0001 /* XATTR_NOFOLLOW */
    } else {
        0
    };
    let ret = unsafe {
        libc::setxattr(
            c_path.as_ptr(),
            c_name.as_ptr(),
            c_value.as_ptr() as *const libc::c_void,
            c_value.len(),
            0, // position
            options,
        )
    };

    report_set_result(ret, path, context, verbose)
}

#[cfg(all(unix, not(target_os = "linux"), not(target_os = "macos")))]
fn set_file_context(
    path: &str,
    context: &str,
    _no_dereference: bool,
    _verbose: bool,
) -> Result<(), ()> {
    eprintln!(
        "chcon: failed to change context of '{}' to '{}': Operation not supported",
        path, context
    );
    Err(())
}

#[cfg(unix)]
fn report_set_result(ret: libc::c_int, path: &str, context: &str, verbose: bool) -> Result<(), ()> {
    if ret != 0 {
        let err = std::io::Error::last_os_error();
        eprintln!(
            "chcon: failed to change context of '{}' to '{}': {}",
            path,
            context,
            coreutils_rs::common::io_error_msg(&err)
        );
        return Err(());
    }
    if verbose {
        println!("changing security context of '{}'", path);
    }
    Ok(())
}

fn print_help() {
    println!("Usage: chcon [OPTION]... CONTEXT FILE...");
    println!("  or:  chcon [OPTION]... [-u USER] [-r ROLE] [-l RANGE] [-t TYPE] FILE...");
    println!("  or:  chcon [OPTION]... --reference=RFILE FILE...");
    println!("Change the SELinux security context of each FILE to CONTEXT.");
    println!("With --reference, change the security context of each FILE to that of RFILE.");
    println!();
    println!("Mandatory arguments to long options are mandatory for short options too.");
    println!("      --dereference      affect the referent of each symbolic link (this is");
    println!("                         the default), rather than the symbolic link itself");
    println!("  -h, --no-dereference   affect symbolic links instead of any referenced file");
    println!("  -u, --user=USER        set user USER in the target security context");
    println!("  -r, --role=ROLE        set role ROLE in the target security context");
    println!("  -t, --type=TYPE        set type TYPE in the target security context");
    println!("  -l, --range=RANGE      set range RANGE in the target security context");
    println!("      --no-preserve-root  do not treat '/' specially (the default)");
    println!("      --preserve-root    fail to operate recursively on '/'");
    println!("      --reference=RFILE  use RFILE's security context rather than specifying");
    println!("                         a CONTEXT value");
    println!("  -R, --recursive        operate on files and directories recursively");
    println!("  -v, --verbose          output a diagnostic for every file processed");
    println!();
    println!("The following options modify how a hierarchy is traversed when the -R");
    println!("option is also specified.  If more than one is specified, only the final");
    println!("one takes effect.");
    println!();
    println!("  -H                     if a command line argument is a symbolic link");
    println!("                         to a directory, traverse it");
    println!("  -L                     traverse every symbolic link to a directory");
    println!("                         encountered");
    println!("  -P                     do not traverse any symbolic links (default)");
    println!();
    println!("      --help        display this help and exit");
    println!("      --version     output version information and exit");
}

#[cfg(all(test, unix))]
mod tests {
    use std::process::Command;

    fn cmd() -> Command {
        let mut path = std::env::current_exe().unwrap();
        path.pop();
        path.pop();
        path.push("fchcon");
        Command::new(path)
    }
    #[test]
    fn test_missing_operand() {
        let output = cmd().output().unwrap();
        assert_eq!(output.status.code(), Some(1));
        let stderr = String::from_utf8_lossy(&output.stderr);
        assert!(stderr.contains("missing operand"));
    }

    #[test]
    fn test_missing_operand_after_context() {
        let output = cmd().arg("foo").output().unwrap();
        assert_eq!(output.status.code(), Some(1));
        let stderr = String::from_utf8_lossy(&output.stderr);
        assert!(stderr.contains("missing operand after 'foo'"));
    }

    #[test]
    fn test_nonexistent_file() {
        let output = cmd()
            .args(["foo_ctx", "/tmp/definitely_nonexistent_chcon_test_12345"])
            .output()
            .unwrap();
        assert_eq!(output.status.code(), Some(1));
        let stderr = String::from_utf8_lossy(&output.stderr);
        assert!(stderr.contains("cannot access"));
    }

    #[test]
    fn test_matches_gnu_no_args() {
        let gnu = Command::new("chcon").output();
        if let Ok(gnu) = gnu {
            let ours = cmd().output().unwrap();
            assert_eq!(ours.status.code(), gnu.status.code());
        }
    }

    #[test]
    fn test_matches_gnu_single_arg() {
        let gnu = Command::new("chcon").arg("foo").output();
        if let Ok(gnu) = gnu {
            let ours = cmd().arg("foo").output().unwrap();
            assert_eq!(ours.status.code(), gnu.status.code());
        }
    }

    #[test]
    fn test_matches_gnu_nonexistent() {
        let gnu = Command::new("chcon")
            .args(["foo_ctx", "/nonexistent_xyz_999"])
            .output();
        if let Ok(gnu) = gnu {
            let ours = cmd()
                .args(["foo_ctx", "/nonexistent_xyz_999"])
                .output()
                .unwrap();
            assert_eq!(ours.status.code(), gnu.status.code());
        }
    }
}
