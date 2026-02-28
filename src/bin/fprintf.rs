// fprintf -- format and print data
//
// Usage: printf FORMAT [ARGUMENT...]

use std::io::Write;
use std::process;

const TOOL_NAME: &str = "printf";
const VERSION: &str = env!("CARGO_PKG_VERSION");

fn print_help() {
    println!("Usage: {} FORMAT [ARGUMENT...]", TOOL_NAME);
    println!("  or:  {} OPTION", TOOL_NAME);
    println!();
    println!("Print ARGUMENT(s) according to FORMAT, or execute according to OPTION:");
    println!();
    println!("      --help     display this help and exit");
    println!("      --version  output version information and exit");
    println!();
    println!("FORMAT controls the output as in C printf.  Interpreted sequences are:");
    println!();
    println!("  \\\"      double quote");
    println!("  \\\\      backslash");
    println!("  \\a      alert (BEL)");
    println!("  \\b      backspace");
    println!("  \\c      produce no further output");
    println!("  \\e      escape");
    println!("  \\f      form feed");
    println!("  \\n      new line");
    println!("  \\r      carriage return");
    println!("  \\t      horizontal tab");
    println!("  \\v      vertical tab");
    println!("  \\NNN    byte with octal value NNN (1 to 3 digits)");
    println!("  \\xHH    byte with hexadecimal value HH (1 to 2 digits)");
    println!("  \\uHHHH  Unicode character with hex value HHHH (1 to 4 digits)");
    println!("  \\UHHHHHHHH  Unicode character with hex value HHHHHHHH (1 to 8 digits)");
    println!("  %%      a single %");
    println!();
    println!("  %b      ARGUMENT as a string with '\\' escapes interpreted");
    println!();
    println!("and all C format specifications ending with one of diouxXeEfgGcs.");
    println!();
    println!("NOTE: your shell may have its own version of printf, which usually supersedes");
    println!("the version described here.  Please refer to your shell's documentation");
    println!("for details about the options it supports.");
}

fn print_version() {
    println!("{} (fcoreutils) {}", TOOL_NAME, VERSION);
}

fn main() {
    coreutils_rs::common::reset_sigpipe();

    let args: Vec<String> = std::env::args().skip(1).collect();

    if args.is_empty() {
        eprintln!("{}: missing operand", TOOL_NAME);
        eprintln!("Try '{} --help' for more information.", TOOL_NAME);
        process::exit(1);
    }

    match args[0].as_str() {
        "--help" => {
            print_help();
            return;
        }
        "--version" => {
            print_version();
            return;
        }
        _ => {}
    }

    // Handle -- as option terminator before the format string (GNU compat).
    // After the format string, -- is treated as a regular data argument.
    let arg_start = if args[0] == "--" { 1 } else { 0 };
    if arg_start >= args.len() {
        eprintln!("{}: missing operand", TOOL_NAME);
        eprintln!("Try '{} --help' for more information.", TOOL_NAME);
        process::exit(1);
    }

    let format = &args[arg_start];
    let remaining = &args[arg_start + 1..];
    let arg_strs: Vec<&str> = remaining.iter().map(|s| s.as_str()).collect();

    coreutils_rs::printf::reset_conv_error();
    let output = coreutils_rs::printf::process_format_string(format, &arg_strs);
    let had_error = coreutils_rs::printf::had_conv_error();

    let stdout = std::io::stdout();
    let mut handle = stdout.lock();
    if let Err(e) = handle.write_all(&output) {
        if e.kind() == std::io::ErrorKind::BrokenPipe {
            process::exit(0);
        }
        eprintln!("{}: write error: {}", TOOL_NAME, e);
        process::exit(1);
    }

    if had_error {
        process::exit(1);
    }
}

#[cfg(test)]
mod tests {
    use std::process::Command;

    fn cmd() -> Command {
        let mut path = std::env::current_exe().unwrap();
        path.pop();
        path.pop();
        path.push("fprintf");
        Command::new(path)
    }
    #[test]
    fn test_printf_string() {
        let output = cmd().args(["%s\n", "hello"]).output().unwrap();
        assert!(output.status.success());
        assert_eq!(String::from_utf8_lossy(&output.stdout), "hello\n");
    }

    #[test]
    fn test_printf_integer() {
        let output = cmd().args(["%d", "42"]).output().unwrap();
        assert!(output.status.success());
        assert_eq!(String::from_utf8_lossy(&output.stdout), "42");
    }

    #[test]
    fn test_printf_no_args() {
        let output = cmd().output().unwrap();
        assert!(!output.status.success());
    }

    #[test]
    fn test_printf_hex() {
        let output = cmd().args(["%x", "255"]).output().unwrap();
        assert!(output.status.success());
        assert_eq!(String::from_utf8_lossy(&output.stdout), "ff");
    }

    #[test]
    fn test_printf_octal() {
        let output = cmd().args(["%o", "8"]).output().unwrap();
        assert!(output.status.success());
        assert_eq!(String::from_utf8_lossy(&output.stdout), "10");
    }

    #[test]
    fn test_printf_escape_sequences() {
        let output = cmd().args(["hello\\tworld\\n"]).output().unwrap();
        assert!(output.status.success());
        assert_eq!(String::from_utf8_lossy(&output.stdout), "hello\tworld\n");
    }

    #[test]
    fn test_printf_width_padding() {
        let output = cmd().args(["%10s", "hello"]).output().unwrap();
        assert!(output.status.success());
        assert_eq!(String::from_utf8_lossy(&output.stdout), "     hello");
    }

    #[test]
    fn test_printf_zero_padding() {
        let output = cmd().args(["%05d", "42"]).output().unwrap();
        assert!(output.status.success());
        assert_eq!(String::from_utf8_lossy(&output.stdout), "00042");
    }

    #[test]
    fn test_printf_multiple_args() {
        let output = cmd().args(["%s %s\n", "hello", "world"]).output().unwrap();
        assert!(output.status.success());
        assert_eq!(String::from_utf8_lossy(&output.stdout), "hello world\n");
    }

    #[test]
    fn test_printf_float() {
        let output = cmd().args(["%.2f", "3.14159"]).output().unwrap();
        assert!(output.status.success());
        assert_eq!(String::from_utf8_lossy(&output.stdout), "3.14");
    }

    #[test]
    fn test_printf_char() {
        let output = cmd().args(["%c", "A"]).output().unwrap();
        assert!(output.status.success());
        assert_eq!(String::from_utf8_lossy(&output.stdout), "A");
    }

    #[test]
    fn test_printf_literal_percent() {
        let output = cmd().args(["100%%"]).output().unwrap();
        assert!(output.status.success());
        assert_eq!(String::from_utf8_lossy(&output.stdout), "100%");
    }

    #[test]
    fn test_printf_backslash_n() {
        let output = cmd().args(["a\\nb"]).output().unwrap();
        assert!(output.status.success());
        assert_eq!(String::from_utf8_lossy(&output.stdout), "a\nb");
    }

    #[test]
    fn test_printf_reuse_format() {
        // GNU printf re-uses format when extra args
        let output = cmd().args(["%s\n", "a", "b", "c"]).output().unwrap();
        assert!(output.status.success());
        assert_eq!(String::from_utf8_lossy(&output.stdout), "a\nb\nc\n");
    }

    #[test]
    fn test_printf_negative_int() {
        let output = cmd().args(["%d", "-42"]).output().unwrap();
        assert!(output.status.success());
        assert_eq!(String::from_utf8_lossy(&output.stdout), "-42");
    }
}
