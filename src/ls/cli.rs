//! Shared CLI argument parsing for ls / dir / vdir.

use std::io;

use super::{
    ClassifyMode, ColorMode, HyperlinkMode, IndicatorStyle, LsConfig, OutputFormat, QuotingStyle,
    SortBy, TimeField, TimeStyle, atty_stdout, ls_main,
};

/// Which variant of ls we are running.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LsFlavor {
    Ls,
    Dir,
    Vdir,
}

impl LsFlavor {
    pub fn name(self) -> &'static str {
        match self {
            LsFlavor::Ls => "ls",
            LsFlavor::Dir => "dir",
            LsFlavor::Vdir => "vdir",
        }
    }
}

fn get_terminal_width() -> Option<usize> {
    let mut ws: libc::winsize = unsafe { std::mem::zeroed() };
    let ret = unsafe { libc::ioctl(1, libc::TIOCGWINSZ, &mut ws) };
    if ret == 0 && ws.ws_col > 0 {
        return Some(ws.ws_col as usize);
    }
    if let Ok(val) = std::env::var("COLUMNS") {
        if let Ok(w) = val.parse::<usize>() {
            return Some(w);
        }
    }
    None
}

fn take_short_value(
    bytes: &[u8],
    pos: usize,
    args: &mut impl Iterator<Item = std::ffi::OsString>,
    flag: &str,
    prog: &str,
) -> String {
    if pos < bytes.len() {
        let full = String::from_utf8_lossy(bytes).into_owned();
        full[pos..].to_string()
    } else {
        args.next()
            .unwrap_or_else(|| {
                eprintln!("{}: option requires an argument -- '{}'", prog, flag);
                std::process::exit(2);
            })
            .to_string_lossy()
            .into_owned()
    }
}

fn print_ls_help(flavor: LsFlavor) {
    let name = flavor.name();
    let desc = match flavor {
        LsFlavor::Ls => {
            "List information about the FILEs (the current directory by default).\n\
                         Sort entries alphabetically if none of -cftuvSUX nor --sort is specified."
        }
        LsFlavor::Dir => {
            "List directory contents.\n\
                         Equivalent to ls -C -b (multi-column format with C-style escapes).\n\
                         All ls options are accepted."
        }
        LsFlavor::Vdir => {
            "List directory contents.\n\
                          Equivalent to ls -l -b (long format with C-style escapes).\n\
                          All ls options are accepted."
        }
    };
    print!(
        "Usage: {} [OPTION]... [FILE]...\n{}\n\n\
         \x20 -a, --all                  do not ignore entries starting with .\n\
         \x20 -A, --almost-all           do not list implied . and ..\n\
         \x20 -b, --escape               print C-style escapes for nongraphic characters\n\
         \x20 -B, --ignore-backups       do not list implied entries ending with ~\n\
         \x20 -c                         sort by/show ctime\n\
         \x20 -C                         list entries by columns\n\
         \x20     --color[=WHEN]         colorize output; WHEN: always, auto, never\n\
         \x20 -d, --directory            list directories themselves, not their contents\n\
         \x20 -F, --classify[=WHEN]      append indicator (one of */=>@|) to entries\n\
         \x20 -g                         like -l, but do not list owner\n\
         \x20 -G, --no-group             in -l listing, don't print group names\n\
         \x20     --group-directories-first  group directories before files\n\
         \x20     --full-time            like -l --time-style=full-iso\n\
         \x20 -h, --human-readable       with -l, print sizes like 1K 234M 2G etc.\n\
         \x20 -i, --inode                print the index number of each file\n\
         \x20 -I, --ignore=PATTERN       do not list entries matching PATTERN\n\
         \x20 -k, --kibibytes            default to 1024-byte blocks\n\
         \x20 -l                         use a long listing format\n\
         \x20 -L, --dereference          show info for link references\n\
         \x20 -m                         fill width with a comma separated list of entries\n\
         \x20 -n, --numeric-uid-gid      like -l, but list numeric user and group IDs\n\
         \x20 -N, --literal              print entry names without quoting\n\
         \x20 -o                         like -l, but do not list group information\n\
         \x20 -p                         append / indicator to directories\n\
         \x20 -q, --hide-control-chars   print ? instead of nongraphic characters\n\
         \x20 -Q, --quote-name           enclose entry names in double quotes\n\
         \x20 -r, --reverse              reverse order while sorting\n\
         \x20 -R, --recursive            list subdirectories recursively\n\
         \x20 -s, --size                 print the allocated size of each file, in blocks\n\
         \x20 -S                         sort by file size, largest first\n\
         \x20     --si                   use powers of 1000 not 1024\n\
         \x20     --sort=WORD            sort by WORD: none, size, time, version, extension\n\
         \x20 -t                         sort by time, newest first\n\
         \x20 -T, --tabsize=COLS         assume tab stops at each COLS instead of 8\n\
         \x20     --time=WORD            select which time to show/sort by\n\
         \x20     --time-style=STYLE     time display style\n\
         \x20 -u                         sort by/show access time\n\
         \x20 -U                         do not sort; list entries in directory order\n\
         \x20 -v                         natural sort of (version) numbers within text\n\
         \x20 -w, --width=COLS           set output width to COLS\n\
         \x20 -x                         list entries by lines instead of by columns\n\
         \x20 -X                         sort alphabetically by entry extension\n\
         \x20 -Z, --context              print any security context of each file\n\
         \x20 -1                         list one file per line\n\
         \x20     --hyperlink[=WHEN]     hyperlink file names; WHEN: always, auto, never\n\
         \x20     --indicator-style=WORD append indicator WORD: none, slash, file-type, classify\n\
         \x20     --quoting-style=WORD   use quoting style WORD for entry names\n\
         \x20     --help                 display this help and exit\n\
         \x20     --version              output version information and exit\n",
        name, desc
    );
}

fn next_opt_val(
    eq_val: Option<&str>,
    args: &mut impl Iterator<Item = std::ffi::OsString>,
    prog: &str,
    opt: &str,
) -> String {
    eq_val.map(|v| v.to_string()).unwrap_or_else(|| {
        args.next()
            .unwrap_or_else(|| {
                eprintln!("{}: option '--{}' requires an argument", prog, opt);
                std::process::exit(2);
            })
            .to_string_lossy()
            .into_owned()
    })
}

/// Parse command-line arguments for ls / dir / vdir.
pub fn parse_ls_args(flavor: LsFlavor) -> (LsConfig, Vec<String>) {
    let is_tty = atty_stdout();
    let mut config = LsConfig::default();
    let mut paths = Vec::new();
    let prog = flavor.name();

    match flavor {
        LsFlavor::Ls => {
            if is_tty {
                config.format = OutputFormat::Columns;
                config.hide_control_chars = true;
            } else {
                config.format = OutputFormat::SingleColumn;
                config.color = ColorMode::Never;
            }
        }
        LsFlavor::Dir => {
            config.format = OutputFormat::Columns;
            config.quoting_style = QuotingStyle::Escape;
            if !is_tty {
                config.color = ColorMode::Never;
            }
        }
        LsFlavor::Vdir => {
            config.format = OutputFormat::Long;
            config.long_format = true;
            config.quoting_style = QuotingStyle::Escape;
            if !is_tty {
                config.color = ColorMode::Never;
            }
        }
    }

    if is_tty {
        if let Some(w) = get_terminal_width() {
            if w > 0 {
                config.width = w;
            }
        }
    }

    let mut explicit_format = false;
    let mut args = std::env::args_os().skip(1);
    #[allow(clippy::while_let_on_iterator)]
    while let Some(arg) = args.next() {
        let bytes = arg.as_encoded_bytes();
        if bytes == b"--" {
            for a in args {
                paths.push(a.to_string_lossy().into_owned());
            }
            break;
        }
        if bytes.starts_with(b"--") {
            let s = arg.to_string_lossy();
            let opt = &s[2..];
            let (name, eq_val) = if let Some(eq) = opt.find('=') {
                (&opt[..eq], Some(&opt[eq + 1..]))
            } else {
                (opt, None)
            };
            match name {
                "help" => {
                    print_ls_help(flavor);
                    std::process::exit(0);
                }
                "version" => {
                    println!("{} (fcoreutils) {}", prog, env!("CARGO_PKG_VERSION"));
                    std::process::exit(0);
                }
                "all" => config.all = true,
                "almost-all" => config.almost_all = true,
                "escape" => config.quoting_style = QuotingStyle::Escape,
                "ignore-backups" => config.ignore_backups = true,
                "directory" => config.directory = true,
                "classify" => {
                    let mode = eq_val.unwrap_or("always");
                    match mode {
                        "always" | "yes" | "force" => {
                            config.classify = ClassifyMode::Always;
                            config.indicator_style = IndicatorStyle::Classify;
                        }
                        "auto" | "tty" | "if-tty" => {
                            config.classify = ClassifyMode::Auto;
                            if is_tty {
                                config.indicator_style = IndicatorStyle::Classify;
                            }
                        }
                        "never" | "no" | "none" => config.classify = ClassifyMode::Never,
                        _ => {
                            eprintln!("{}: invalid argument '{}' for '--classify'", prog, mode);
                            std::process::exit(2);
                        }
                    }
                }
                "no-group" => config.show_group = false,
                "group-directories-first" => config.group_directories_first = true,
                "human-readable" => config.human_readable = true,
                "si" => config.si = true,
                "inode" => config.show_inode = true,
                "ignore" => {
                    let val = next_opt_val(eq_val, &mut args, prog, "ignore");
                    config.ignore_patterns.push(val);
                }
                "kibibytes" => config.kibibytes = true,
                "dereference" => config.dereference = true,
                "numeric-uid-gid" => {
                    config.numeric_ids = true;
                    config.long_format = true;
                    if !explicit_format {
                        config.format = OutputFormat::Long;
                    }
                }
                "literal" => {
                    config.literal = true;
                    config.quoting_style = QuotingStyle::Literal;
                }
                "hide-control-chars" => config.hide_control_chars = true,
                "quote-name" => config.quoting_style = QuotingStyle::C,
                "reverse" => config.reverse = true,
                "recursive" => config.recursive = true,
                "size" => config.show_size = true,
                "context" => config.context = true,
                "color" => {
                    let val = eq_val.unwrap_or("always");
                    config.color = match val {
                        "always" | "yes" | "force" => ColorMode::Always,
                        "auto" | "tty" | "if-tty" => ColorMode::Auto,
                        "never" | "no" | "none" => ColorMode::Never,
                        _ => {
                            eprintln!("{}: invalid argument '{}' for '--color'", prog, val);
                            std::process::exit(2);
                        }
                    };
                }
                "sort" => {
                    let val = next_opt_val(eq_val, &mut args, prog, "sort");
                    config.sort_by = match val.as_str() {
                        "none" => SortBy::None,
                        "size" => SortBy::Size,
                        "time" => SortBy::Time,
                        "version" => SortBy::Version,
                        "extension" => SortBy::Extension,
                        "width" => SortBy::Width,
                        _ => {
                            eprintln!("{}: invalid argument '{}' for '--sort'", prog, val);
                            std::process::exit(2);
                        }
                    };
                }
                "time" => {
                    let val = next_opt_val(eq_val, &mut args, prog, "time");
                    config.time_field = match val.as_str() {
                        "atime" | "access" | "use" => TimeField::Atime,
                        "ctime" | "status" => TimeField::Ctime,
                        "birth" | "creation" => TimeField::Birth,
                        "mtime" | "modification" => TimeField::Mtime,
                        _ => {
                            eprintln!("{}: invalid argument '{}' for '--time'", prog, val);
                            std::process::exit(2);
                        }
                    };
                }
                "time-style" => {
                    let val = next_opt_val(eq_val, &mut args, prog, "time-style");
                    config.time_style = match val.as_str() {
                        "full-iso" => TimeStyle::FullIso,
                        "long-iso" => TimeStyle::LongIso,
                        "iso" => TimeStyle::Iso,
                        "locale" => TimeStyle::Locale,
                        s if s.starts_with('+') => TimeStyle::Custom(s[1..].to_string()),
                        _ => {
                            eprintln!("{}: invalid argument '{}' for '--time-style'", prog, val);
                            std::process::exit(2);
                        }
                    };
                }
                "full-time" => {
                    config.long_format = true;
                    config.format = OutputFormat::Long;
                    explicit_format = true;
                    config.time_style = TimeStyle::FullIso;
                }
                "tabsize" => {
                    let val = next_opt_val(eq_val, &mut args, prog, "tabsize");
                    config.tab_size = val.parse().unwrap_or(8);
                }
                "width" => {
                    let val = next_opt_val(eq_val, &mut args, prog, "width");
                    config.width = val.parse().unwrap_or(80);
                }
                "hyperlink" => {
                    let val = eq_val.unwrap_or("always");
                    config.hyperlink = match val {
                        "always" | "yes" | "force" => HyperlinkMode::Always,
                        "auto" | "tty" | "if-tty" => HyperlinkMode::Auto,
                        "never" | "no" | "none" => HyperlinkMode::Never,
                        _ => {
                            eprintln!("{}: invalid argument '{}' for '--hyperlink'", prog, val);
                            std::process::exit(2);
                        }
                    };
                }
                "indicator-style" => {
                    let val = next_opt_val(eq_val, &mut args, prog, "indicator-style");
                    config.indicator_style = match val.as_str() {
                        "none" => IndicatorStyle::None,
                        "slash" => IndicatorStyle::Slash,
                        "file-type" => IndicatorStyle::FileType,
                        "classify" => IndicatorStyle::Classify,
                        _ => {
                            eprintln!(
                                "{}: invalid argument '{}' for '--indicator-style'",
                                prog, val
                            );
                            std::process::exit(2);
                        }
                    };
                }
                "quoting-style" => {
                    let val = next_opt_val(eq_val, &mut args, prog, "quoting-style");
                    config.quoting_style = match val.as_str() {
                        "literal" => QuotingStyle::Literal,
                        "locale" => QuotingStyle::Locale,
                        "shell" => QuotingStyle::Shell,
                        "shell-always" => QuotingStyle::ShellAlways,
                        "shell-escape" => QuotingStyle::ShellEscape,
                        "shell-escape-always" => QuotingStyle::ShellEscapeAlways,
                        "c" => QuotingStyle::C,
                        "escape" => QuotingStyle::Escape,
                        _ => {
                            eprintln!("{}: invalid argument '{}' for '--quoting-style'", prog, val);
                            std::process::exit(2);
                        }
                    };
                }
                _ => {
                    eprintln!("{}: unrecognized option '--{}'", prog, name);
                    eprintln!("Try '{} --help' for more information.", prog);
                    std::process::exit(2);
                }
            }
        } else if bytes.len() > 1 && bytes[0] == b'-' {
            let mut i = 1;
            while i < bytes.len() {
                match bytes[i] {
                    b'a' => config.all = true,
                    b'A' => config.almost_all = true,
                    b'b' => config.quoting_style = QuotingStyle::Escape,
                    b'B' => config.ignore_backups = true,
                    b'c' => config.time_field = TimeField::Ctime,
                    b'C' => {
                        config.format = OutputFormat::Columns;
                        explicit_format = true;
                    }
                    b'd' => config.directory = true,
                    b'f' => {
                        config.all = true;
                        config.sort_by = SortBy::None;
                    }
                    b'F' => {
                        config.classify = ClassifyMode::Always;
                        config.indicator_style = IndicatorStyle::Classify;
                    }
                    b'g' => {
                        config.long_format = true;
                        config.show_owner = false;
                        if !explicit_format {
                            config.format = OutputFormat::Long;
                        }
                    }
                    b'G' => config.show_group = false,
                    b'h' => config.human_readable = true,
                    b'i' => config.show_inode = true,
                    b'k' => config.kibibytes = true,
                    b'l' => {
                        config.long_format = true;
                        config.format = OutputFormat::Long;
                        explicit_format = true;
                    }
                    b'L' => config.dereference = true,
                    b'm' => {
                        config.format = OutputFormat::Comma;
                        explicit_format = true;
                    }
                    b'n' => {
                        config.long_format = true;
                        config.numeric_ids = true;
                        if !explicit_format {
                            config.format = OutputFormat::Long;
                        }
                    }
                    b'N' => {
                        config.literal = true;
                        config.quoting_style = QuotingStyle::Literal;
                    }
                    b'o' => {
                        config.long_format = true;
                        config.show_group = false;
                        if !explicit_format {
                            config.format = OutputFormat::Long;
                        }
                    }
                    b'p' => config.indicator_style = IndicatorStyle::Slash,
                    b'q' => config.hide_control_chars = true,
                    b'Q' => config.quoting_style = QuotingStyle::C,
                    b'r' => config.reverse = true,
                    b'R' => config.recursive = true,
                    b's' => config.show_size = true,
                    b'S' => config.sort_by = SortBy::Size,
                    b't' => config.sort_by = SortBy::Time,
                    b'u' => config.time_field = TimeField::Atime,
                    b'U' => config.sort_by = SortBy::None,
                    b'v' => config.sort_by = SortBy::Version,
                    b'x' => {
                        config.format = OutputFormat::Across;
                        explicit_format = true;
                    }
                    b'X' => config.sort_by = SortBy::Extension,
                    b'Z' => config.context = true,
                    b'1' => {
                        config.format = OutputFormat::SingleColumn;
                        explicit_format = true;
                    }
                    b'I' => {
                        let val = take_short_value(bytes, i + 1, &mut args, "I", prog);
                        config.ignore_patterns.push(val);
                        break;
                    }
                    b'w' => {
                        let val = take_short_value(bytes, i + 1, &mut args, "w", prog);
                        config.width = val.parse().unwrap_or_else(|_| {
                            eprintln!("{}: invalid line width: '{}'", prog, val);
                            std::process::exit(2);
                        });
                        break;
                    }
                    b'T' => {
                        let val = take_short_value(bytes, i + 1, &mut args, "T", prog);
                        config.tab_size = val.parse().unwrap_or_else(|_| {
                            eprintln!("{}: invalid tab size: '{}'", prog, val);
                            std::process::exit(2);
                        });
                        break;
                    }
                    _ => {
                        eprintln!("{}: invalid option -- '{}'", prog, bytes[i] as char);
                        eprintln!("Try '{} --help' for more information.", prog);
                        std::process::exit(2);
                    }
                }
                i += 1;
            }
        } else {
            paths.push(arg.to_string_lossy().into_owned());
        }
    }

    (config, paths)
}

/// Run ls / dir / vdir with the given flavor.
pub fn run_ls(flavor: LsFlavor) {
    let (config, paths) = parse_ls_args(flavor);
    let prog = flavor.name();

    let file_args: Vec<String> = if paths.is_empty() {
        vec![".".to_string()]
    } else {
        paths
    };

    match ls_main(&file_args, &config) {
        Ok(true) => {}
        Ok(false) => std::process::exit(2),
        Err(e) => {
            if e.kind() == io::ErrorKind::BrokenPipe {
                std::process::exit(141);
            }
            eprintln!("{}: {}", prog, e);
            std::process::exit(2);
        }
    }
}
