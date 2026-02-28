#[cfg(not(unix))]
fn main() {
    eprintln!("date: only available on Unix");
    std::process::exit(1);
}

#[cfg(unix)]
use std::io::{self, BufRead, BufReader, Write};
#[cfg(unix)]
use std::process;
#[cfg(unix)]
use std::time::SystemTime;

#[cfg(unix)]
use coreutils_rs::common::{io_error_msg, reset_sigpipe};
#[cfg(unix)]
use coreutils_rs::date::{self, DateConfig, IsoFormat};

#[cfg(unix)]
struct Cli {
    config: DateConfig,
}

#[cfg(unix)]
fn parse_args() -> Cli {
    let mut cli = Cli {
        config: DateConfig::default(),
    };

    let mut args = std::env::args_os().skip(1);

    #[allow(clippy::while_let_on_iterator)]
    while let Some(arg) = args.next() {
        let bytes = arg.as_encoded_bytes();
        let s = arg.to_string_lossy();

        // Format string starts with +
        if bytes.starts_with(b"+") {
            cli.config.format = Some(s[1..].to_string());
            continue;
        }

        if bytes == b"--" {
            // After --, next arg could be a format string
            if let Some(next) = args.next() {
                let ns = next.to_string_lossy();
                if let Some(fmt) = ns.strip_prefix('+') {
                    cli.config.format = Some(fmt.to_string());
                }
            }
            break;
        }

        if bytes.starts_with(b"--") {
            if let Some(val) = s.strip_prefix("--date=") {
                cli.config.date_string = Some(val.to_string());
            } else if let Some(val) = s.strip_prefix("--file=") {
                cli.config.date_file = Some(val.to_string());
            } else if let Some(val) = s.strip_prefix("--iso-8601=") {
                match date::parse_iso_format(val) {
                    Ok(fmt) => cli.config.iso_format = Some(fmt),
                    Err(e) => {
                        eprintln!("date: {}", e);
                        process::exit(1);
                    }
                }
            } else if s.as_ref() == "--iso-8601" {
                cli.config.iso_format = Some(IsoFormat::Date);
            } else if let Some(val) = s.strip_prefix("--rfc-3339=") {
                match date::parse_rfc3339_format(val) {
                    Ok(fmt) => cli.config.rfc_3339 = Some(fmt),
                    Err(e) => {
                        eprintln!("date: {}", e);
                        process::exit(1);
                    }
                }
            } else if let Some(val) = s.strip_prefix("--reference=") {
                cli.config.reference_file = Some(val.to_string());
            } else if let Some(val) = s.strip_prefix("--set=") {
                cli.config.set_string = Some(val.to_string());
            } else {
                match s.as_ref() {
                    "--rfc-email" => cli.config.rfc_email = true,
                    "--utc" | "--universal" => cli.config.utc = true,
                    "--help" => {
                        print_help();
                        process::exit(0);
                    }
                    "--version" => {
                        println!("date (fcoreutils) {}", env!("CARGO_PKG_VERSION"));
                        process::exit(0);
                    }
                    _ => {
                        // Handle --date STRING (space-separated)
                        if s.as_ref() == "--date" {
                            let val = require_arg(&mut args, "--date");
                            cli.config.date_string = Some(val);
                        } else if s.as_ref() == "--file" {
                            let val = require_arg(&mut args, "--file");
                            cli.config.date_file = Some(val);
                        } else if s.as_ref() == "--reference" {
                            let val = require_arg(&mut args, "--reference");
                            cli.config.reference_file = Some(val);
                        } else if s.as_ref() == "--set" {
                            let val = require_arg(&mut args, "--set");
                            cli.config.set_string = Some(val);
                        } else if s.as_ref() == "--rfc-3339" {
                            let val = require_arg(&mut args, "--rfc-3339");
                            match date::parse_rfc3339_format(&val) {
                                Ok(fmt) => cli.config.rfc_3339 = Some(fmt),
                                Err(e) => {
                                    eprintln!("date: {}", e);
                                    process::exit(1);
                                }
                            }
                        } else {
                            eprintln!("date: unrecognized option '{}'", s);
                            eprintln!("Try 'date --help' for more information.");
                            process::exit(1);
                        }
                    }
                }
            }
        } else if bytes.len() > 1 && bytes[0] == b'-' {
            // Short options
            let chars: Vec<char> = s[1..].chars().collect();
            let mut ci = 0;
            while ci < chars.len() {
                match chars[ci] {
                    'd' => {
                        let val = short_opt_value(&s, &chars, ci, &mut args, 'd');
                        cli.config.date_string = Some(val);
                        break;
                    }
                    'f' => {
                        let val = short_opt_value(&s, &chars, ci, &mut args, 'f');
                        cli.config.date_file = Some(val);
                        break;
                    }
                    'I' => {
                        // -I with optional FMT
                        if ci + 1 < chars.len() {
                            let rest: String = chars[ci + 1..].iter().collect();
                            match date::parse_iso_format(&rest) {
                                Ok(fmt) => cli.config.iso_format = Some(fmt),
                                Err(e) => {
                                    eprintln!("date: {}", e);
                                    process::exit(1);
                                }
                            }
                        } else {
                            cli.config.iso_format = Some(IsoFormat::Date);
                        }
                        break;
                    }
                    'R' => cli.config.rfc_email = true,
                    'r' => {
                        let val = short_opt_value(&s, &chars, ci, &mut args, 'r');
                        cli.config.reference_file = Some(val);
                        break;
                    }
                    's' => {
                        let val = short_opt_value(&s, &chars, ci, &mut args, 's');
                        cli.config.set_string = Some(val);
                        break;
                    }
                    'u' => cli.config.utc = true,
                    _ => {
                        eprintln!("date: invalid option -- '{}'", chars[ci]);
                        eprintln!("Try 'date --help' for more information.");
                        process::exit(1);
                    }
                }
                ci += 1;
            }
        } else {
            // Positional argument - treat as format if starts with +
            if let Some(fmt) = s.strip_prefix('+') {
                cli.config.format = Some(fmt.to_string());
            } else {
                eprintln!("date: extra operand '{}'", s);
                process::exit(1);
            }
        }
    }

    cli
}

#[cfg(unix)]
fn short_opt_value(
    s: &str,
    chars: &[char],
    i: usize,
    args: &mut impl Iterator<Item = std::ffi::OsString>,
    opt: char,
) -> String {
    if i + 1 < chars.len() {
        s[1 + i + 1..].to_string()
    } else {
        args.next()
            .unwrap_or_else(|| {
                eprintln!("date: option requires an argument -- '{}'", opt);
                process::exit(1);
            })
            .to_string_lossy()
            .into_owned()
    }
}

#[cfg(unix)]
fn require_arg(args: &mut impl Iterator<Item = std::ffi::OsString>, opt: &str) -> String {
    args.next()
        .unwrap_or_else(|| {
            eprintln!("date: option '{}' requires an argument", opt);
            process::exit(1);
        })
        .to_string_lossy()
        .into_owned()
}

#[cfg(unix)]
fn print_help() {
    print!(
        "Usage: date [OPTION]... [+FORMAT]\n\
         \x20 or:  date [-u|--utc|--universal] [MMDDhhmm[[CC]YY][.ss]]\n\
         Display the current time in the given FORMAT, or set the system date.\n\n\
         \x20 -d, --date=STRING          display time described by STRING\n\
         \x20 -f, --file=DATEFILE        like --date; once for each line of DATEFILE\n\
         \x20 -I[FMT], --iso-8601[=FMT] output date/time in ISO 8601 format.\n\
         \x20                            FMT='date' for date only (the default),\n\
         \x20                            'hours', 'minutes', 'seconds', or 'ns'\n\
         \x20 -R, --rfc-email            output date and time in RFC 5322 format\n\
         \x20     --rfc-3339=FMT         output date/time in RFC 3339 format.\n\
         \x20                            FMT='date', 'seconds', or 'ns'\n\
         \x20 -r, --reference=FILE       display the last modification time of FILE\n\
         \x20 -s, --set=STRING           set time described by STRING\n\
         \x20 -u, --utc, --universal     print or set Coordinated Universal Time (UTC)\n\
         \x20     --help                 display this help and exit\n\
         \x20     --version              output version information and exit\n\n\
         FORMAT controls the output. Interpreted sequences are:\n\n\
         \x20 %%   a literal %\n\
         \x20 %a   locale's abbreviated weekday name (e.g., Sun)\n\
         \x20 %A   locale's full weekday name (e.g., Sunday)\n\
         \x20 %b   locale's abbreviated month name (e.g., Jan)\n\
         \x20 %B   locale's full month name (e.g., January)\n\
         \x20 %c   locale's date and time (e.g., Thu Mar  3 23:05:25 2005)\n\
         \x20 %C   century; like %Y, except omit last two digits (e.g., 20)\n\
         \x20 %d   day of month (e.g., 01)\n\
         \x20 %D   date; same as %m/%d/%y\n\
         \x20 %e   day of month, space padded; same as %_d\n\
         \x20 %F   full date; like %+4Y-%m-%d\n\
         \x20 %H   hour (00..23)\n\
         \x20 %I   hour (01..12)\n\
         \x20 %j   day of year (001..366)\n\
         \x20 %k   hour, space padded ( 0..23); same as %_H\n\
         \x20 %l   hour, space padded ( 1..12); same as %_I\n\
         \x20 %m   month (01..12)\n\
         \x20 %M   minute (00..59)\n\
         \x20 %N   nanoseconds (000000000..999999999)\n\
         \x20 %p   locale's equivalent of either AM or PM\n\
         \x20 %P   like %p, but lower case\n\
         \x20 %r   locale's 12-hour clock time (e.g., 11:11:04 PM)\n\
         \x20 %R   24-hour hour and minute; same as %H:%M\n\
         \x20 %s   seconds since the Epoch (1970-01-01 00:00 UTC)\n\
         \x20 %S   second (00..60)\n\
         \x20 %T   time; same as %H:%M:%S\n\
         \x20 %u   day of week (1..7); 1 is Monday\n\
         \x20 %V   ISO week number, with Monday as first day of week (01..53)\n\
         \x20 %w   day of week (0..6); 0 is Sunday\n\
         \x20 %x   locale's date representation\n\
         \x20 %X   locale's time representation\n\
         \x20 %y   last two digits of year (00..99)\n\
         \x20 %Y   year\n\
         \x20 %z   +hhmm numeric time zone (e.g., -0400)\n\
         \x20 %Z   alphabetic time zone abbreviation (e.g., EDT)\n"
    );
}

#[cfg(unix)]
fn display_date(time: &SystemTime, config: &DateConfig) -> Result<String, String> {
    let utc = config.utc;

    if let Some(ref iso_fmt) = config.iso_format {
        return Ok(date::format_iso(time, iso_fmt, utc));
    }
    if config.rfc_email {
        return Ok(date::format_rfc_email(time, utc));
    }
    if let Some(ref rfc_fmt) = config.rfc_3339 {
        return Ok(date::format_rfc3339(time, rfc_fmt, utc));
    }
    if let Some(ref fmt) = config.format {
        return Ok(date::format_date(time, fmt, utc));
    }

    // Default format
    Ok(date::format_date(time, date::default_format(), utc))
}

#[cfg(unix)]
fn main() {
    reset_sigpipe();

    let cli = parse_args();
    let config = &cli.config;

    let stdout = io::stdout();
    let mut out = stdout.lock();
    let mut had_error = false;

    // Handle --set (we parse but don't actually set the clock; that requires root)
    if let Some(ref set_str) = config.set_string {
        match date::parse_date_string(set_str, config.utc) {
            Ok(_time) => {
                eprintln!("date: cannot set date: Operation not permitted");
                process::exit(1);
            }
            Err(e) => {
                eprintln!("date: {}", e);
                process::exit(1);
            }
        }
    }

    // Handle --file: read dates from file
    if let Some(ref date_file) = config.date_file {
        let reader: Box<dyn BufRead> = if date_file == "-" {
            Box::new(BufReader::new(io::stdin().lock()))
        } else {
            match std::fs::File::open(date_file) {
                Ok(f) => Box::new(BufReader::new(f)),
                Err(e) => {
                    eprintln!("date: {}: {}", date_file, io_error_msg(&e));
                    process::exit(1);
                }
            }
        };

        for line in reader.lines() {
            match line {
                Ok(date_str) => match date::parse_date_string(&date_str, config.utc) {
                    Ok(time) => match display_date(&time, config) {
                        Ok(s) => {
                            if let Err(e) = writeln!(out, "{}", s) {
                                if e.kind() == io::ErrorKind::BrokenPipe {
                                    process::exit(0);
                                }
                                eprintln!("date: write error: {}", io_error_msg(&e));
                                process::exit(1);
                            }
                        }
                        Err(e) => {
                            eprintln!("date: {}", e);
                            had_error = true;
                        }
                    },
                    Err(e) => {
                        eprintln!("date: {}", e);
                        had_error = true;
                    }
                },
                Err(e) => {
                    eprintln!("date: {}: {}", date_file, io_error_msg(&e));
                    had_error = true;
                }
            }
        }

        if had_error {
            process::exit(1);
        }
        return;
    }

    // Determine the time to display
    let time = if let Some(ref date_str) = config.date_string {
        match date::parse_date_string(date_str, config.utc) {
            Ok(t) => t,
            Err(e) => {
                eprintln!("date: {}", e);
                process::exit(1);
            }
        }
    } else if let Some(ref ref_file) = config.reference_file {
        match date::file_mod_time(ref_file) {
            Ok(t) => t,
            Err(e) => {
                eprintln!("date: {}", e);
                process::exit(1);
            }
        }
    } else {
        SystemTime::now()
    };

    match display_date(&time, config) {
        Ok(s) => {
            if let Err(e) = writeln!(out, "{}", s) {
                if e.kind() == io::ErrorKind::BrokenPipe {
                    process::exit(0);
                }
                eprintln!("date: write error: {}", io_error_msg(&e));
                process::exit(1);
            }
        }
        Err(e) => {
            eprintln!("date: {}", e);
            process::exit(1);
        }
    }
}

#[cfg(test)]
mod tests {
    use std::process::Command;

    fn cmd() -> Command {
        let mut path = std::env::current_exe().unwrap();
        path.pop();
        path.pop();
        path.push("fdate");
        Command::new(path)
    }

    #[test]
    fn test_date_help() {
        let output = cmd().arg("--help").output().unwrap();
        assert!(output.status.success());
        assert!(String::from_utf8_lossy(&output.stdout).contains("Usage"));
    }

    #[test]
    fn test_date_version() {
        let output = cmd().arg("--version").output().unwrap();
        assert!(output.status.success());
        assert!(String::from_utf8_lossy(&output.stdout).contains("fcoreutils"));
    }
    #[test]
    fn test_date_basic() {
        let output = cmd().output().unwrap();
        assert!(output.status.success());
        let stdout = String::from_utf8_lossy(&output.stdout);
        assert!(!stdout.is_empty());
    }

    #[test]
    fn test_date_format() {
        let output = cmd().arg("+%Y").output().unwrap();
        assert!(output.status.success());
        let stdout = String::from_utf8_lossy(&output.stdout);
        assert!(stdout.trim().parse::<u32>().is_ok());
    }

    #[test]
    fn test_date_utc() {
        let output = cmd().args(["-u", "+%Z"]).output().unwrap();
        assert!(output.status.success());
        let stdout = String::from_utf8_lossy(&output.stdout);
        assert!(stdout.contains("UTC") || stdout.contains("GMT"));
    }

    #[test]
    fn test_date_epoch() {
        let output = cmd().arg("+%s").output().unwrap();
        assert!(output.status.success());
        let stdout = String::from_utf8_lossy(&output.stdout);
        let epoch: u64 = stdout.trim().parse().expect("should be a unix timestamp");
        // Should be a reasonable modern timestamp (after 2020)
        assert!(epoch > 1_577_836_800);
    }

    #[test]
    fn test_date_day_of_week() {
        let output = cmd().arg("+%A").output().unwrap();
        assert!(output.status.success());
        let stdout = String::from_utf8_lossy(&output.stdout);
        let days = [
            "Monday",
            "Tuesday",
            "Wednesday",
            "Thursday",
            "Friday",
            "Saturday",
            "Sunday",
        ];
        assert!(
            days.iter().any(|d| stdout.trim() == *d),
            "unexpected day: {}",
            stdout.trim()
        );
    }

    #[test]
    fn test_date_iso() {
        let output = cmd().arg("+%Y-%m-%d").output().unwrap();
        assert!(output.status.success());
        let stdout = String::from_utf8_lossy(&output.stdout);
        let parts: Vec<&str> = stdout.trim().split('-').collect();
        assert_eq!(parts.len(), 3);
        assert!(parts[0].len() == 4); // YYYY
        assert!(parts[1].len() == 2); // MM
        assert!(parts[2].len() == 2); // DD
    }

    #[test]
    fn test_date_multiple_format_specifiers() {
        let output = cmd().arg("+%H:%M:%S").output().unwrap();
        assert!(output.status.success());
        let stdout = String::from_utf8_lossy(&output.stdout);
        let parts: Vec<&str> = stdout.trim().split(':').collect();
        assert_eq!(parts.len(), 3);
    }

    #[test]
    fn test_date_literal_percent() {
        let output = cmd().arg("+100%%").output().unwrap();
        assert!(output.status.success());
        let stdout = String::from_utf8_lossy(&output.stdout);
        assert_eq!(stdout.trim(), "100%");
    }

    #[test]
    fn test_date_date_flag() {
        let output = cmd()
            .args(["-d", "2024-01-15", "+%Y-%m-%d"])
            .output()
            .unwrap();
        assert!(output.status.success());
        let stdout = String::from_utf8_lossy(&output.stdout);
        assert_eq!(stdout.trim(), "2024-01-15");
    }

    #[test]
    fn test_date_epoch_zero() {
        let output = cmd()
            .args(["-u", "-d", "@0", "+%Y-%m-%d %H:%M:%S"])
            .output()
            .unwrap();
        assert!(output.status.success());
        let stdout = String::from_utf8_lossy(&output.stdout);
        assert_eq!(stdout.trim(), "1970-01-01 00:00:00");
    }

    #[test]
    fn test_date_invalid_format() {
        // Invalid date string should fail
        let output = cmd().args(["-d", "not a date"]).output().unwrap();
        assert!(!output.status.success());
    }

    #[test]
    fn test_date_rfc3339() {
        let output = cmd().arg("--rfc-3339=seconds").output().unwrap();
        assert!(output.status.success());
        let stdout = String::from_utf8_lossy(&output.stdout);
        // Should contain date-time with timezone offset
        assert!(stdout.contains("-") && stdout.contains(":"));
    }
}
