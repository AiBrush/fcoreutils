use std::process;
#[cfg(unix)]
use std::sync::atomic::{AtomicBool, Ordering};

use coreutils_rs::common::io_error_msg;
use coreutils_rs::sort::{
    CheckMode, KeyDef, KeyOpts, SortConfig, parse_buffer_size, sort_and_output,
};

// ── SIGPIPE disposition detection ────────────────────────────────────────────
//
// GNU sort behavior depends on the ORIGINAL SIGPIPE disposition inherited from
// the parent process:
//   - SIG_DFL (normal bash): sort is killed silently by SIGPIPE (exit 141)
//   - SIG_IGN (Docker/nohup/CI): sort catches EPIPE, prints diagnostics, exits 2
//
// The Rust runtime sets SIGPIPE to SIG_IGN before main() runs, so we must
// capture the original disposition in a pre-main constructor.

/// Whether the parent process had SIGPIPE set to SIG_IGN.
#[cfg(unix)]
static SIGPIPE_WAS_IGNORED: AtomicBool = AtomicBool::new(false);

/// Probe SIGPIPE disposition via sigaction (race-free, read-only).
#[cfg(unix)]
#[inline(always)]
unsafe fn probe_sigpipe() {
    unsafe {
        let mut old: libc::sigaction = std::mem::zeroed();
        libc::sigaction(libc::SIGPIPE, std::ptr::null(), &mut old);
        if old.sa_sigaction == libc::SIG_IGN {
            SIGPIPE_WAS_IGNORED.store(true, Ordering::Relaxed);
        }
    }
}

/// Pre-main constructor (non-macOS Unix): `.init_array` entries receive (argc, argv, envp).
#[cfg(all(unix, not(target_os = "macos")))]
unsafe extern "C" fn _save_sigpipe(
    _argc: libc::c_int,
    _argv: *const *const libc::c_char,
    _envp: *const *const libc::c_char,
) {
    unsafe { probe_sigpipe() }
}

/// Pre-main constructor (macOS): `__mod_init_func` entries receive no arguments.
#[cfg(target_os = "macos")]
unsafe extern "C" fn _save_sigpipe() {
    unsafe { probe_sigpipe() }
}

#[cfg(all(unix, not(target_os = "macos")))]
#[used]
#[unsafe(link_section = ".init_array")]
static _SAVE_SIGPIPE_INIT: unsafe extern "C" fn(
    libc::c_int,
    *const *const libc::c_char,
    *const *const libc::c_char,
) = _save_sigpipe;

#[cfg(target_os = "macos")]
#[used]
#[unsafe(link_section = "__DATA,__mod_init_func")]
static _SAVE_SIGPIPE_INIT: unsafe extern "C" fn() = _save_sigpipe;

struct Cli {
    ignore_leading_blanks: bool,
    dictionary_order: bool,
    ignore_case: bool,
    general_numeric: bool,
    human_numeric: bool,
    ignore_nonprinting: bool,
    month_sort: bool,
    numeric_sort: bool,
    random_sort: bool,
    reverse: bool,
    version_sort: bool,
    keys: Vec<String>,
    field_separator: Option<String>,
    unique: bool,
    stable: bool,
    check: Option<String>,
    check_quiet: bool,
    merge: bool,
    output: Option<String>,
    temp_dir: Option<String>,
    parallel: Option<usize>,
    buffer_size: Option<String>,
    zero_terminated: bool,
    debug: bool,
    files: Vec<String>,
}

/// Take the next value for an option: rest of current arg (after pos) or next arg.
fn take_value(
    bytes: &[u8],
    pos: usize,
    args: &mut impl Iterator<Item = std::ffi::OsString>,
    flag: &str,
) -> String {
    if pos < bytes.len() {
        // Rest of this arg is the value (e.g., -k1,3 or -ofile)
        let full = String::from_utf8_lossy(bytes).into_owned();
        full[pos..].to_string()
    } else {
        // Next arg is the value
        args.next()
            .unwrap_or_else(|| {
                eprintln!("sort: option requires an argument -- '{}'", flag);
                process::exit(2);
            })
            .to_string_lossy()
            .into_owned()
    }
}

/// Hand-rolled argument parser — eliminates clap's ~200-300µs initialization.
fn parse_args() -> Cli {
    let mut cli = Cli {
        ignore_leading_blanks: false,
        dictionary_order: false,
        ignore_case: false,
        general_numeric: false,
        human_numeric: false,
        ignore_nonprinting: false,
        month_sort: false,
        numeric_sort: false,
        random_sort: false,
        reverse: false,
        version_sort: false,
        keys: Vec::new(),
        field_separator: None,
        unique: false,
        stable: false,
        check: None,
        check_quiet: false,
        merge: false,
        output: None,
        temp_dir: None,
        parallel: None,
        buffer_size: None,
        zero_terminated: false,
        debug: false,
        files: Vec::new(),
    };

    let mut args = std::env::args_os().skip(1);
    #[allow(clippy::while_let_on_iterator)]
    while let Some(arg) = args.next() {
        let bytes = arg.as_encoded_bytes();

        if bytes == b"--" {
            // Everything after -- is a file
            for a in args {
                cli.files.push(a.to_string_lossy().into_owned());
            }
            break;
        }

        if bytes.starts_with(b"--") {
            // Long option
            let s = arg.to_string_lossy();
            let opt = &s[2..];

            // Check for --option=value form
            let (name, eq_val) = if let Some(eq) = opt.find('=') {
                (&opt[..eq], Some(&opt[eq + 1..]))
            } else {
                (opt, None)
            };

            match name {
                "ignore-leading-blanks" => cli.ignore_leading_blanks = true,
                "dictionary-order" => cli.dictionary_order = true,
                "ignore-case" => cli.ignore_case = true,
                "general-numeric-sort" => cli.general_numeric = true,
                "human-numeric-sort" => cli.human_numeric = true,
                "ignore-nonprinting" => cli.ignore_nonprinting = true,
                "month-sort" => cli.month_sort = true,
                "numeric-sort" => cli.numeric_sort = true,
                "random-sort" => cli.random_sort = true,
                "reverse" => cli.reverse = true,
                "version-sort" => cli.version_sort = true,
                "unique" => cli.unique = true,
                "stable" => cli.stable = true,
                "merge" => cli.merge = true,
                "zero-terminated" => cli.zero_terminated = true,
                "debug" => cli.debug = true,
                "check" => {
                    cli.check = Some(eq_val.unwrap_or("diagnose").to_string());
                }
                "key" => {
                    let val = eq_val.map(|v| v.to_string()).unwrap_or_else(|| {
                        args.next()
                            .unwrap_or_else(|| {
                                eprintln!("sort: option '--key' requires an argument");
                                process::exit(2);
                            })
                            .to_string_lossy()
                            .into_owned()
                    });
                    cli.keys.push(val);
                }
                "field-separator" => {
                    cli.field_separator =
                        Some(eq_val.map(|v| v.to_string()).unwrap_or_else(|| {
                            args.next()
                                .unwrap_or_else(|| {
                                    eprintln!(
                                        "sort: option '--field-separator' requires an argument"
                                    );
                                    process::exit(2);
                                })
                                .to_string_lossy()
                                .into_owned()
                        }));
                }
                "output" => {
                    cli.output = Some(eq_val.map(|v| v.to_string()).unwrap_or_else(|| {
                        args.next()
                            .unwrap_or_else(|| {
                                eprintln!("sort: option '--output' requires an argument");
                                process::exit(2);
                            })
                            .to_string_lossy()
                            .into_owned()
                    }));
                }
                "temporary-directory" => {
                    cli.temp_dir = Some(eq_val.map(|v| v.to_string()).unwrap_or_else(|| {
                        args.next()
                            .unwrap_or_else(|| {
                                eprintln!(
                                    "sort: option '--temporary-directory' requires an argument"
                                );
                                process::exit(2);
                            })
                            .to_string_lossy()
                            .into_owned()
                    }));
                }
                "parallel" => {
                    let val = eq_val.map(|v| v.to_string()).unwrap_or_else(|| {
                        args.next()
                            .unwrap_or_else(|| {
                                eprintln!("sort: option '--parallel' requires an argument");
                                process::exit(2);
                            })
                            .to_string_lossy()
                            .into_owned()
                    });
                    cli.parallel = Some(val.parse().unwrap_or_else(|_| {
                        eprintln!("sort: invalid number of parallel jobs: '{}'", val);
                        process::exit(2);
                    }));
                }
                "buffer-size" => {
                    cli.buffer_size = Some(eq_val.map(|v| v.to_string()).unwrap_or_else(|| {
                        args.next()
                            .unwrap_or_else(|| {
                                eprintln!("sort: option '--buffer-size' requires an argument");
                                process::exit(2);
                            })
                            .to_string_lossy()
                            .into_owned()
                    }));
                }
                "sort" => {
                    let val = eq_val.map(|v| v.to_string()).unwrap_or_else(|| {
                        args.next()
                            .unwrap_or_else(|| {
                                eprintln!("sort: option '--sort' requires an argument");
                                process::exit(2);
                            })
                            .to_string_lossy()
                            .into_owned()
                    });
                    match val.as_str() {
                        "general-numeric" => cli.general_numeric = true,
                        "human-numeric" => cli.human_numeric = true,
                        "month" => cli.month_sort = true,
                        "numeric" => cli.numeric_sort = true,
                        "random" => cli.random_sort = true,
                        "version" => cli.version_sort = true,
                        _ => {
                            eprintln!("sort: unknown sort type: '{}'", val);
                            process::exit(2);
                        }
                    }
                }
                "help" => {
                    print!(
                        "Usage: sort [OPTION]... [FILE]...\n\
                         Write sorted concatenation of all FILE(s) to standard output.\n\n\
                         With no FILE, or when FILE is -, read standard input.\n\n\
                         Ordering options:\n\
                         \x20 -b, --ignore-leading-blanks  ignore leading blanks\n\
                         \x20 -d, --dictionary-order       consider only blanks and alphanumeric characters\n\
                         \x20 -f, --ignore-case            fold lower case to upper case characters\n\
                         \x20 -g, --general-numeric-sort   compare according to general numerical value\n\
                         \x20 -i, --ignore-nonprinting     consider only printable characters\n\
                         \x20 -M, --month-sort             compare (unknown) < 'JAN' < ... < 'DEC'\n\
                         \x20 -h, --human-numeric-sort     compare human readable numbers (e.g., 2K 1G)\n\
                         \x20 -n, --numeric-sort           compare according to string numerical value\n\
                         \x20 -R, --random-sort            shuffle, but group identical keys\n\
                         \x20 -r, --reverse                reverse the result of comparisons\n\
                         \x20 -V, --version-sort           natural sort of (version) numbers within text\n\n\
                         Other options:\n\
                         \x20 -c, --check                  check for sorted input; do not sort\n\
                         \x20 -C                           like -c, but do not report first bad line\n\
                         \x20 -k, --key=KEYDEF             sort via a key; KEYDEF gives location and type\n\
                         \x20 -m, --merge                  merge already sorted files; do not sort\n\
                         \x20 -o, --output=FILE            write result to FILE instead of standard output\n\
                         \x20 -s, --stable                 stabilize sort by disabling last-resort comparison\n\
                         \x20 -S, --buffer-size=SIZE       use SIZE for main memory buffer\n\
                         \x20 -t, --field-separator=SEP    use SEP instead of non-blank to blank transition\n\
                         \x20 -T, --temporary-directory=DIR  use DIR for temporaries, not $TMPDIR or /tmp\n\
                         \x20 -u, --unique                 output only the first of an equal run\n\
                         \x20 -z, --zero-terminated        line delimiter is NUL, not newline\n\
                         \x20     --parallel=N             change the number of sorts run concurrently to N\n\
                         \x20     --help                   display this help and exit\n\
                         \x20     --version                output version information and exit\n"
                    );
                    process::exit(0);
                }
                "version" => {
                    println!("sort (fcoreutils) {}", env!("CARGO_PKG_VERSION"));
                    process::exit(0);
                }
                _ => {
                    eprintln!("sort: unrecognized option '--{}'", name);
                    eprintln!("Try 'sort --help' for more information.");
                    process::exit(2);
                }
            }
        } else if bytes.len() > 1 && bytes[0] == b'-' {
            // Short option(s): -b, -bnr, -k1,3, -ofile, etc.
            let mut i = 1;
            while i < bytes.len() {
                match bytes[i] {
                    b'b' => cli.ignore_leading_blanks = true,
                    b'd' => cli.dictionary_order = true,
                    b'f' => cli.ignore_case = true,
                    b'g' => cli.general_numeric = true,
                    b'h' => cli.human_numeric = true,
                    b'i' => cli.ignore_nonprinting = true,
                    b'M' => cli.month_sort = true,
                    b'n' => cli.numeric_sort = true,
                    b'R' => cli.random_sort = true,
                    b'r' => cli.reverse = true,
                    b'V' => cli.version_sort = true,
                    b'u' => cli.unique = true,
                    b's' => cli.stable = true,
                    b'm' => cli.merge = true,
                    b'z' => cli.zero_terminated = true,
                    b'c' => {
                        cli.check = Some("diagnose".to_string());
                    }
                    b'C' => cli.check_quiet = true,
                    b'k' => {
                        let val = take_value(bytes, i + 1, &mut args, "k");
                        cli.keys.push(val);
                        break;
                    }
                    b't' => {
                        let val = take_value(bytes, i + 1, &mut args, "t");
                        cli.field_separator = Some(val);
                        break;
                    }
                    b'o' => {
                        let val = take_value(bytes, i + 1, &mut args, "o");
                        cli.output = Some(val);
                        break;
                    }
                    b'T' => {
                        let val = take_value(bytes, i + 1, &mut args, "T");
                        cli.temp_dir = Some(val);
                        break;
                    }
                    b'S' => {
                        let val = take_value(bytes, i + 1, &mut args, "S");
                        cli.buffer_size = Some(val);
                        break;
                    }
                    _ => {
                        eprintln!("sort: invalid option -- '{}'", bytes[i] as char);
                        eprintln!("Try 'sort --help' for more information.");
                        process::exit(2);
                    }
                }
                i += 1;
            }
        } else {
            cli.files.push(arg.to_string_lossy().into_owned());
        }
    }

    cli
}

fn main() {
    // Initialize locale from environment (LC_COLLATE, LANG, etc.) so that
    // strcoll-based comparisons respect the user's locale, matching GNU sort.
    unsafe {
        libc::setlocale(libc::LC_ALL, c"".as_ptr());
    }

    // Restore SIGPIPE based on the original disposition saved by the pre-main
    // constructor. Normal bash has SIG_DFL; restore it so sort is killed
    // silently by SIGPIPE (exit 141). If SIG_IGN was inherited (Docker/nohup/CI),
    // keep it and handle EPIPE explicitly with diagnostic messages + exit 2.
    #[cfg(unix)]
    let sigpipe_ignored = SIGPIPE_WAS_IGNORED.load(Ordering::Relaxed);
    #[cfg(not(unix))]
    let sigpipe_ignored = true;

    #[cfg(unix)]
    if !sigpipe_ignored {
        // Normal shell: restore SIG_DFL so we are killed silently like GNU sort
        unsafe {
            let mut act: libc::sigaction = std::mem::zeroed();
            act.sa_sigaction = libc::SIG_DFL;
            libc::sigaction(libc::SIGPIPE, &act, std::ptr::null_mut());
        }
    }

    // Enlarge pipe buffers on Linux for higher throughput.
    #[cfg(target_os = "linux")]
    for &fd in &[0i32, 1] {
        for &size in &[8 * 1024 * 1024i32, 1024 * 1024, 256 * 1024] {
            if unsafe { libc::fcntl(fd, libc::F_SETPIPE_SZ, size) } > 0 {
                break;
            }
        }
    }

    let cli = parse_args();

    // Validate -c and -C are not combined
    if cli.check.is_some() && cli.check_quiet {
        eprintln!("sort: options '-cC' are incompatible");
        process::exit(2);
    }

    // Parse key definitions
    let mut keys: Vec<KeyDef> = Vec::new();
    for key_spec in &cli.keys {
        match KeyDef::parse(key_spec) {
            Ok(k) => keys.push(k),
            Err(e) => {
                eprintln!("sort: {}", e);
                process::exit(2);
            }
        }
    }

    // Parse field separator
    let separator = cli.field_separator.as_ref().map(|s| {
        if s.len() == 1 {
            s.as_bytes()[0]
        } else if s == "\\0" {
            b'\0'
        } else if s == "\\t" {
            b'\t'
        } else {
            eprintln!("sort: multi-character tab '{}'", s);
            process::exit(2);
        }
    });

    // Build global options
    let global_opts = KeyOpts {
        ignore_leading_blanks: cli.ignore_leading_blanks,
        dictionary_order: cli.dictionary_order,
        ignore_case: cli.ignore_case,
        general_numeric: cli.general_numeric,
        human_numeric: cli.human_numeric,
        ignore_nonprinting: cli.ignore_nonprinting,
        month: cli.month_sort,
        numeric: cli.numeric_sort,
        random: cli.random_sort,
        version: cli.version_sort,
        reverse: cli.reverse,
    };

    // Validate global option compatibility (GNU sort rules)
    if let Err(e) = global_opts.validate() {
        eprintln!("sort: {}", e);
        process::exit(2);
    }

    // Determine check mode
    let check = if cli.check_quiet {
        CheckMode::Quiet
    } else if let Some(ref val) = cli.check {
        match val.as_str() {
            "quiet" | "silent" => CheckMode::Quiet,
            _ => CheckMode::Diagnose,
        }
    } else {
        CheckMode::None
    };

    // Parse buffer size
    let buffer_size = cli.buffer_size.as_ref().map(|s| {
        parse_buffer_size(s).unwrap_or_else(|e| {
            eprintln!("sort: invalid buffer size: {}", e);
            process::exit(2);
        })
    });

    let random_seed = if cli.random_sort {
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_nanos() as u64)
            .unwrap_or(42)
    } else {
        0
    };

    let config = SortConfig {
        keys,
        separator,
        global_opts,
        unique: cli.unique,
        stable: cli.stable,
        reverse: cli.reverse,
        check,
        merge: cli.merge,
        output_file: cli.output,
        zero_terminated: cli.zero_terminated,
        parallel: cli.parallel,
        buffer_size,
        temp_dir: cli.temp_dir,
        random_seed,
        debug: cli.debug,
    };

    // Debug mode: print locale info to stderr (matching GNU sort --debug)
    if cli.debug {
        let locale_name = std::env::var("LC_ALL")
            .or_else(|_| std::env::var("LC_COLLATE"))
            .or_else(|_| std::env::var("LANG"))
            .unwrap_or_else(|_| "C".to_string());
        // GNU sort says: text ordering performed using 'XX' sorting rules
        // It uses the full locale name including encoding (e.g. 'en_US.UTF-8').
        eprintln!(
            "sort: text ordering performed using '{}' sorting rules",
            if locale_name == "C" || locale_name == "POSIX" {
                "simple byte comparison".to_string()
            } else {
                locale_name
            }
        );
    }

    let inputs = if cli.files.is_empty() {
        vec!["-".to_string()]
    } else {
        cli.files
    };

    if let Err(e) = sort_and_output(&inputs, &config) {
        if e.kind() == std::io::ErrorKind::BrokenPipe {
            if sigpipe_ignored {
                // SIG_IGN inherited: print GNU-style diagnostics before exit 2
                let output_name = config.output_file.as_deref().unwrap_or("standard output");
                eprintln!("sort: write failed: '{}': Broken pipe", output_name);
                eprintln!("sort: write error");
            }
            // With SIG_DFL we should not reach here (killed by signal),
            // but re-raise SIGPIPE so the shell sees exit 141, not 2.
            #[cfg(unix)]
            if !sigpipe_ignored {
                unsafe {
                    libc::raise(libc::SIGPIPE);
                }
            }
            process::exit(2);
        }
        eprintln!("sort: {}", io_error_msg(&e));
        process::exit(2);
    }
}

#[cfg(test)]
mod tests {
    use std::io::Write;
    use std::process::Command;
    use std::process::Stdio;

    fn cmd() -> Command {
        let mut path = std::env::current_exe().unwrap();
        path.pop();
        path.pop();
        path.push("fsort");
        Command::new(path)
    }
    #[cfg(unix)]
    #[test]
    fn test_sort_basic() {
        let mut child = cmd()
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .spawn()
            .unwrap();
        child
            .stdin
            .take()
            .unwrap()
            .write_all(b"banana\napple\ncherry\n")
            .unwrap();
        let output = child.wait_with_output().unwrap();
        assert!(output.status.success());
        assert_eq!(
            String::from_utf8_lossy(&output.stdout),
            "apple\nbanana\ncherry\n"
        );
    }

    #[cfg(unix)]
    #[test]
    fn test_sort_reverse() {
        let mut child = cmd()
            .arg("-r")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .spawn()
            .unwrap();
        child.stdin.take().unwrap().write_all(b"a\nb\nc\n").unwrap();
        let output = child.wait_with_output().unwrap();
        assert!(output.status.success());
        assert_eq!(String::from_utf8_lossy(&output.stdout), "c\nb\na\n");
    }

    #[cfg(unix)]
    #[test]
    fn test_sort_numeric() {
        let mut child = cmd()
            .arg("-n")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .spawn()
            .unwrap();
        child
            .stdin
            .take()
            .unwrap()
            .write_all(b"10\n2\n1\n20\n")
            .unwrap();
        let output = child.wait_with_output().unwrap();
        assert!(output.status.success());
        assert_eq!(String::from_utf8_lossy(&output.stdout), "1\n2\n10\n20\n");
    }

    #[cfg(unix)]
    #[test]
    fn test_sort_empty_input() {
        let mut child = cmd()
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .spawn()
            .unwrap();
        drop(child.stdin.take().unwrap());
        let output = child.wait_with_output().unwrap();
        assert!(output.status.success());
        assert_eq!(output.stdout, b"");
    }

    #[cfg(unix)]
    #[test]
    fn test_sort_unique() {
        let mut child = cmd()
            .arg("-u")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .spawn()
            .unwrap();
        child
            .stdin
            .take()
            .unwrap()
            .write_all(b"apple\nbanana\napple\ncherry\nbanana\n")
            .unwrap();
        let output = child.wait_with_output().unwrap();
        assert!(output.status.success());
        assert_eq!(
            String::from_utf8_lossy(&output.stdout),
            "apple\nbanana\ncherry\n"
        );
    }

    #[cfg(unix)]
    #[test]
    fn test_sort_stable() {
        let mut child = cmd()
            .args(["-s", "-k1,1"])
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .spawn()
            .unwrap();
        child
            .stdin
            .take()
            .unwrap()
            .write_all(b"a 2\na 1\nb 1\n")
            .unwrap();
        let output = child.wait_with_output().unwrap();
        assert!(output.status.success());
        let stdout = String::from_utf8_lossy(&output.stdout);
        // Stable sort preserves original order for equal keys
        assert_eq!(stdout, "a 2\na 1\nb 1\n");
    }

    #[cfg(unix)]
    #[test]
    fn test_sort_numeric_reverse() {
        let mut child = cmd()
            .args(["-n", "-r"])
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .spawn()
            .unwrap();
        child
            .stdin
            .take()
            .unwrap()
            .write_all(b"1\n10\n2\n20\n")
            .unwrap();
        let output = child.wait_with_output().unwrap();
        assert!(output.status.success());
        assert_eq!(String::from_utf8_lossy(&output.stdout), "20\n10\n2\n1\n");
    }

    #[cfg(unix)]
    #[test]
    fn test_sort_check_sorted() {
        let mut child = cmd()
            .arg("-c")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .unwrap();
        child.stdin.take().unwrap().write_all(b"a\nb\nc\n").unwrap();
        let output = child.wait_with_output().unwrap();
        assert!(output.status.success());
    }

    #[cfg(unix)]
    #[test]
    fn test_sort_check_unsorted() {
        let mut child = cmd()
            .arg("-c")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .unwrap();
        child.stdin.take().unwrap().write_all(b"b\na\nc\n").unwrap();
        let output = child.wait_with_output().unwrap();
        assert!(!output.status.success());
    }

    #[cfg(unix)]
    #[test]
    fn test_sort_key_field() {
        let mut child = cmd()
            .args(["-k", "2"])
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .spawn()
            .unwrap();
        child
            .stdin
            .take()
            .unwrap()
            .write_all(b"x b\ny a\nz c\n")
            .unwrap();
        let output = child.wait_with_output().unwrap();
        assert!(output.status.success());
        assert_eq!(String::from_utf8_lossy(&output.stdout), "y a\nx b\nz c\n");
    }

    #[cfg(unix)]
    #[test]
    fn test_sort_case_insensitive() {
        let mut child = cmd()
            .arg("-f")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .spawn()
            .unwrap();
        child
            .stdin
            .take()
            .unwrap()
            .write_all(b"Banana\napple\nCherry\n")
            .unwrap();
        let output = child.wait_with_output().unwrap();
        assert!(output.status.success());
        let stdout = String::from_utf8_lossy(&output.stdout);
        let lines: Vec<&str> = stdout.lines().collect();
        assert_eq!(lines[0], "apple");
    }

    #[cfg(unix)]
    #[test]
    fn test_sort_file() {
        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join("test.txt");
        std::fs::write(&file, "cherry\napple\nbanana\n").unwrap();
        let output = cmd().arg(file.to_str().unwrap()).output().unwrap();
        assert!(output.status.success());
        assert_eq!(
            String::from_utf8_lossy(&output.stdout),
            "apple\nbanana\ncherry\n"
        );
    }

    #[cfg(unix)]
    #[test]
    fn test_sort_output_file() {
        let dir = tempfile::tempdir().unwrap();
        let input = dir.path().join("input.txt");
        let output_file = dir.path().join("output.txt");
        std::fs::write(&input, "c\na\nb\n").unwrap();
        let output = cmd()
            .args(["-o", output_file.to_str().unwrap(), input.to_str().unwrap()])
            .output()
            .unwrap();
        assert!(output.status.success());
        let result = std::fs::read_to_string(&output_file).unwrap();
        assert_eq!(result, "a\nb\nc\n");
    }

    #[cfg(unix)]
    #[test]
    fn test_sort_single_line() {
        let mut child = cmd()
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .spawn()
            .unwrap();
        child.stdin.take().unwrap().write_all(b"hello\n").unwrap();
        let output = child.wait_with_output().unwrap();
        assert!(output.status.success());
        assert_eq!(String::from_utf8_lossy(&output.stdout), "hello\n");
    }

    #[cfg(unix)]
    #[test]
    fn test_sort_tab_separator() {
        let mut child = cmd()
            .args(["-t", "\t", "-k", "2,2n"])
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .spawn()
            .unwrap();
        child
            .stdin
            .take()
            .unwrap()
            .write_all(b"x\t10\ny\t2\nz\t1\n")
            .unwrap();
        let output = child.wait_with_output().unwrap();
        assert!(output.status.success());
        assert_eq!(
            String::from_utf8_lossy(&output.stdout),
            "z\t1\ny\t2\nx\t10\n"
        );
    }

    #[cfg(unix)]
    #[test]
    fn test_sort_nonexistent_file() {
        let output = cmd().arg("/nonexistent_xyz_sort").output().unwrap();
        assert!(!output.status.success());
    }
}
