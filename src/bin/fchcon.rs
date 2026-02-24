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

#[cfg(unix)]
fn main() {
    coreutils_rs::common::reset_sigpipe();

    let args: Vec<String> = std::env::args().skip(1).collect();

    let mut user: Option<String> = None;
    let mut role: Option<String> = None;
    let mut typ: Option<String> = None;
    let mut range: Option<String> = None;
    let mut reference: Option<String> = None;
    let mut recursive = false;
    let mut verbose = false;
    let mut no_dereference = false;
    let mut preserve_root = false;
    let mut traverse_mode: u8 = b'P'; // -H, -L, -P (default P)
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
            "--dereference" => {
                no_dereference = false;
                i += 1;
            }
            "-h" | "--no-dereference" => {
                no_dereference = true;
                i += 1;
            }
            "-R" | "--recursive" => {
                recursive = true;
                i += 1;
            }
            "-v" | "--verbose" => {
                verbose = true;
                i += 1;
            }
            "--no-preserve-root" => {
                preserve_root = false;
                i += 1;
            }
            "--preserve-root" => {
                preserve_root = true;
                i += 1;
            }
            "-H" => {
                traverse_mode = b'H';
                i += 1;
            }
            "-L" => {
                traverse_mode = b'L';
                i += 1;
            }
            "-P" => {
                traverse_mode = b'P';
                i += 1;
            }
            "-u" | "--user" => {
                i += 1;
                if i >= args.len() {
                    eprintln!("chcon: option '{}' requires an argument", arg);
                    std::process::exit(1);
                }
                user = Some(args[i].clone());
                i += 1;
            }
            "-r" | "--role" => {
                i += 1;
                if i >= args.len() {
                    eprintln!("chcon: option '{}' requires an argument", arg);
                    std::process::exit(1);
                }
                role = Some(args[i].clone());
                i += 1;
            }
            "-t" | "--type" => {
                i += 1;
                if i >= args.len() {
                    eprintln!("chcon: option '{}' requires an argument", arg);
                    std::process::exit(1);
                }
                typ = Some(args[i].clone());
                i += 1;
            }
            "-l" | "--range" => {
                i += 1;
                if i >= args.len() {
                    eprintln!("chcon: option '{}' requires an argument", arg);
                    std::process::exit(1);
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
            s if s.starts_with("--reference=") => {
                reference = Some(s["--reference=".len()..].to_string());
                i += 1;
            }
            "--reference" => {
                i += 1;
                if i >= args.len() {
                    eprintln!("chcon: option '--reference' requires an argument");
                    std::process::exit(1);
                }
                reference = Some(args[i].clone());
                i += 1;
            }
            s if s.starts_with("--") => {
                eprintln!("chcon: unrecognized option '{}'", s);
                eprintln!("Try 'chcon --help' for more information.");
                std::process::exit(1);
            }
            s if s.starts_with('-') && s.len() > 1 => {
                // Short option clusters
                let bytes = s.as_bytes();
                let mut j = 1;
                while j < bytes.len() {
                    match bytes[j] {
                        b'h' => no_dereference = true,
                        b'R' => recursive = true,
                        b'v' => verbose = true,
                        b'H' => traverse_mode = b'H',
                        b'L' => traverse_mode = b'L',
                        b'P' => traverse_mode = b'P',
                        b'u' => {
                            // -uVALUE or -u VALUE
                            if j + 1 < bytes.len() {
                                user = Some(String::from_utf8_lossy(&bytes[j + 1..]).to_string());
                                j = bytes.len();
                                continue;
                            } else {
                                i += 1;
                                if i >= args.len() {
                                    eprintln!("chcon: option requires an argument -- 'u'");
                                    std::process::exit(1);
                                }
                                user = Some(args[i].clone());
                            }
                        }
                        b'r' => {
                            if j + 1 < bytes.len() {
                                role = Some(String::from_utf8_lossy(&bytes[j + 1..]).to_string());
                                j = bytes.len();
                                continue;
                            } else {
                                i += 1;
                                if i >= args.len() {
                                    eprintln!("chcon: option requires an argument -- 'r'");
                                    std::process::exit(1);
                                }
                                role = Some(args[i].clone());
                            }
                        }
                        b't' => {
                            if j + 1 < bytes.len() {
                                typ = Some(String::from_utf8_lossy(&bytes[j + 1..]).to_string());
                                j = bytes.len();
                                continue;
                            } else {
                                i += 1;
                                if i >= args.len() {
                                    eprintln!("chcon: option requires an argument -- 't'");
                                    std::process::exit(1);
                                }
                                typ = Some(args[i].clone());
                            }
                        }
                        b'l' => {
                            if j + 1 < bytes.len() {
                                range = Some(String::from_utf8_lossy(&bytes[j + 1..]).to_string());
                                j = bytes.len();
                                continue;
                            } else {
                                i += 1;
                                if i >= args.len() {
                                    eprintln!("chcon: option requires an argument -- 'l'");
                                    std::process::exit(1);
                                }
                                range = Some(args[i].clone());
                            }
                        }
                        ch => {
                            eprintln!("chcon: invalid option -- '{}'", ch as char);
                            eprintln!("Try 'chcon --help' for more information.");
                            std::process::exit(1);
                        }
                    }
                    j += 1;
                }
                i += 1;
            }
            _ => {
                positional.push(arg.clone());
                i += 1;
            }
        }
    }

    let has_partial = user.is_some() || role.is_some() || typ.is_some() || range.is_some();
    let has_reference = reference.is_some();

    // Determine context and files
    let (context, files): (Option<String>, Vec<String>) = if has_reference {
        // --reference mode: all positional args are files
        if positional.is_empty() {
            eprintln!("chcon: missing operand");
            eprintln!("Try 'chcon --help' for more information.");
            std::process::exit(1);
        }
        (None, positional)
    } else if has_partial {
        // Partial context mode: all positional args are files
        if positional.is_empty() {
            eprintln!("chcon: missing operand");
            eprintln!("Try 'chcon --help' for more information.");
            std::process::exit(1);
        }
        (None, positional)
    } else {
        // Full context mode: first positional is CONTEXT, rest are files
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

    // Check preserve-root
    if recursive && preserve_root {
        for f in &files {
            if f == "/" {
                eprintln!("chcon: it is dangerous to operate recursively on '/'");
                eprintln!("chcon: use --no-preserve-root to override this failsafe");
                std::process::exit(1);
            }
        }
    }

    // Process files
    let mut had_error = false;

    // If we have a reference file, read its context first
    let ref_context: Option<String> = if let Some(ref rfile) = reference {
        match get_file_context(rfile, no_dereference) {
            Ok(ctx) => Some(ctx),
            Err(e) => {
                eprintln!("chcon: failed to get security context of '{}': {}", rfile, e);
                std::process::exit(1);
            }
        }
    } else {
        None
    };

    for file in &files {
        if process_file(
            file,
            &context,
            &ref_context,
            &user,
            &role,
            &typ,
            &range,
            has_partial,
            recursive,
            verbose,
            no_dereference,
            traverse_mode,
        )
        .is_err()
        {
            had_error = true;
        }
    }

    if had_error {
        std::process::exit(1);
    }
}

#[cfg(unix)]
fn process_file(
    path: &str,
    context: &Option<String>,
    ref_context: &Option<String>,
    user: &Option<String>,
    role: &Option<String>,
    typ: &Option<String>,
    range: &Option<String>,
    has_partial: bool,
    recursive: bool,
    verbose: bool,
    no_dereference: bool,
    traverse_mode: u8,
) -> Result<(), ()> {
    // Check file accessibility
    let metadata = if no_dereference {
        std::fs::symlink_metadata(path)
    } else {
        std::fs::metadata(path)
    };
    if let Err(e) = metadata {
        eprintln!(
            "chcon: cannot access '{}': {}",
            path,
            coreutils_rs::common::io_error_msg(&e)
        );
        return Err(());
    }

    let mut had_error = false;

    // Apply context change to this file
    if let Err(()) = change_context(path, context, ref_context, user, role, typ, range, has_partial, no_dereference, verbose) {
        had_error = true;
    }

    // Handle recursion
    if recursive {
        if let Ok(md) = if no_dereference {
            std::fs::symlink_metadata(path)
        } else {
            std::fs::metadata(path)
        } {
            if md.is_dir() {
                if let Err(()) = recurse_dir(path, context, ref_context, user, role, typ, range, has_partial, verbose, no_dereference, traverse_mode) {
                    had_error = true;
                }
            }
        }
    }

    if had_error { Err(()) } else { Ok(()) }
}

#[cfg(unix)]
fn recurse_dir(
    dir: &str,
    context: &Option<String>,
    ref_context: &Option<String>,
    user: &Option<String>,
    role: &Option<String>,
    typ: &Option<String>,
    range: &Option<String>,
    has_partial: bool,
    verbose: bool,
    no_dereference: bool,
    traverse_mode: u8,
) -> Result<(), ()> {
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

        // Determine whether to follow symlinks for traversal
        let follow = match traverse_mode {
            b'L' => true,
            b'H' => false, // Only top-level args, not recursed entries
            _ => false,     // P
        };

        let use_no_deref = if follow { false } else { no_dereference };

        if let Err(()) = change_context(
            &child, context, ref_context, user, role, typ, range, has_partial, use_no_deref, verbose,
        ) {
            had_error = true;
        }

        // Recurse into subdirectories
        let md = if follow {
            std::fs::metadata(&child)
        } else {
            std::fs::symlink_metadata(&child)
        };
        if let Ok(md) = md {
            if md.is_dir() {
                if let Err(()) = recurse_dir(
                    &child, context, ref_context, user, role, typ, range, has_partial, verbose,
                    use_no_deref, traverse_mode,
                ) {
                    had_error = true;
                }
            }
        }
    }

    if had_error { Err(()) } else { Ok(()) }
}

#[cfg(unix)]
fn change_context(
    path: &str,
    context: &Option<String>,
    ref_context: &Option<String>,
    user: &Option<String>,
    role: &Option<String>,
    typ: &Option<String>,
    range: &Option<String>,
    has_partial: bool,
    no_dereference: bool,
    verbose: bool,
) -> Result<(), ()> {
    if let Some(ctx) = ref_context {
        // Reference mode: set full context from reference file
        return set_file_context(path, ctx, no_dereference, verbose);
    }

    if let Some(ctx) = context {
        // Full context mode
        return set_file_context(path, ctx, no_dereference, verbose);
    }

    if has_partial {
        // Partial context mode: read current, modify, write back
        let current = match get_file_context(path, no_dereference) {
            Ok(ctx) => ctx,
            Err(_) => {
                eprintln!("chcon: can't apply partial context to unlabeled file '{}'", path);
                return Err(());
            }
        };

        // SELinux context format: user:role:type:range
        let parts: Vec<&str> = current.splitn(4, ':').collect();
        if parts.len() < 3 {
            eprintln!("chcon: can't apply partial context to unlabeled file '{}'", path);
            return Err(());
        }

        let new_user = user.as_deref().unwrap_or(parts[0]);
        let new_role = role.as_deref().unwrap_or(parts[1]);
        let new_type = typ.as_deref().unwrap_or(parts[2]);
        let new_range = range.as_deref().unwrap_or(if parts.len() > 3 { parts[3] } else { "s0" });

        let new_ctx = format!("{}:{}:{}:{}", new_user, new_role, new_type, new_range);
        return set_file_context(path, &new_ctx, no_dereference, verbose);
    }

    Ok(())
}

#[cfg(unix)]
fn get_file_context(path: &str, no_dereference: bool) -> Result<String, String> {
    use std::ffi::CString;

    let c_path = CString::new(path).map_err(|_| "invalid path".to_string())?;
    let c_name = CString::new("security.selinux").unwrap();
    let mut buf = vec![0u8; 256];

    let len = if no_dereference {
        unsafe {
            libc::lgetxattr(
                c_path.as_ptr(),
                c_name.as_ptr(),
                buf.as_mut_ptr() as *mut libc::c_void,
                buf.len(),
            )
        }
    } else {
        unsafe {
            libc::getxattr(
                c_path.as_ptr(),
                c_name.as_ptr(),
                buf.as_mut_ptr() as *mut libc::c_void,
                buf.len(),
            )
        }
    };

    if len < 0 {
        let err = std::io::Error::last_os_error();
        Err(coreutils_rs::common::io_error_msg(&err))
    } else {
        // Remove trailing NUL if present
        let actual_len = if len > 0 && buf[len as usize - 1] == 0 {
            len as usize - 1
        } else {
            len as usize
        };
        String::from_utf8(buf[..actual_len].to_vec())
            .map_err(|_| "invalid context encoding".to_string())
    }
}

#[cfg(unix)]
fn set_file_context(path: &str, context: &str, no_dereference: bool, verbose: bool) -> Result<(), ()> {
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
        eprintln!("changing security context of '{}'", path);
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
    fn test_help() {
        let output = cmd().arg("--help").output().unwrap();
        assert_eq!(output.status.code(), Some(0));
        let stdout = String::from_utf8_lossy(&output.stdout);
        assert!(stdout.contains("Usage: chcon"));
        assert!(stdout.contains("--reference"));
        assert!(stdout.contains("--recursive"));
    }

    #[test]
    fn test_version() {
        let output = cmd().arg("--version").output().unwrap();
        assert_eq!(output.status.code(), Some(0));
        let stdout = String::from_utf8_lossy(&output.stdout);
        assert!(stdout.contains("chcon (fcoreutils)"));
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
