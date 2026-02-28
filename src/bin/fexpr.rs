use std::process;

use coreutils_rs::expr::{EXIT_FAILURE, EXIT_SUCCESS, evaluate_expr};

fn main() {
    coreutils_rs::common::reset_sigpipe();

    let args: Vec<String> = std::env::args().skip(1).collect();

    // Handle --help and --version before parsing expression
    if args.len() == 1 {
        match args[0].as_str() {
            "--help" => {
                print_help();
                process::exit(EXIT_SUCCESS);
            }
            "--version" => {
                print_version();
                process::exit(EXIT_SUCCESS);
            }
            _ => {}
        }
    }

    match evaluate_expr(&args) {
        Ok(value) => {
            println!("{}", value);
            if value.is_null() {
                process::exit(EXIT_FAILURE);
            } else {
                process::exit(EXIT_SUCCESS);
            }
        }
        Err(e) => {
            eprintln!("expr: {}", e);
            process::exit(e.exit_code());
        }
    }
}

fn print_help() {
    println!("Usage: expr EXPRESSION");
    println!("  or:  expr OPTION");
    println!();
    println!("Print the value of EXPRESSION to standard output.");
    println!();
    println!("      --help     display this help and exit");
    println!("      --version  output version information and exit");
    println!();
    println!("EXPRESSION is composed of the following operators, in order of");
    println!("increasing precedence:");
    println!();
    println!("  ARG1 | ARG2       ARG1 if it is neither null nor 0, otherwise ARG2");
    println!("  ARG1 & ARG2       ARG1 if neither argument is null or 0, otherwise 0");
    println!();
    println!("  ARG1 < ARG2       ARG1 is less than ARG2");
    println!("  ARG1 <= ARG2      ARG1 is less than or equal to ARG2");
    println!("  ARG1 = ARG2       ARG1 is equal to ARG2");
    println!("  ARG1 != ARG2      ARG1 is not equal to ARG2");
    println!("  ARG1 >= ARG2      ARG1 is greater than or equal to ARG2");
    println!("  ARG1 > ARG2       ARG1 is greater than ARG2");
    println!();
    println!("  ARG1 + ARG2       arithmetic sum of ARG1 and ARG2");
    println!("  ARG1 - ARG2       arithmetic difference of ARG1 and ARG2");
    println!();
    println!("  ARG1 * ARG2       arithmetic product of ARG1 and ARG2");
    println!("  ARG1 / ARG2       arithmetic quotient of ARG1 divided by ARG2");
    println!("  ARG1 % ARG2       arithmetic remainder of ARG1 divided by ARG2");
    println!();
    println!("  STRING : REGEX    anchored pattern match of REGEX in STRING");
    println!("  match STRING REGEX  same as STRING : REGEX");
    println!("  substr STRING POS LENGTH  substring of STRING, POS counted from 1");
    println!("  index STRING CHARS  index in STRING where any CHARS is found, or 0");
    println!("  length STRING     length of STRING");
    println!();
    println!("  ( EXPRESSION )    value of EXPRESSION");
    println!();
    println!("Exit status is 0 if EXPRESSION is neither null nor 0, 1 if EXPRESSION");
    println!("is null or 0, 2 if EXPRESSION is syntactically invalid, and 3 if an");
    println!("error occurred.");
}

fn print_version() {
    println!("expr (fcoreutils) {}", env!("CARGO_PKG_VERSION"));
}

#[cfg(test)]
mod tests {
    use std::process::Command;

    fn cmd() -> Command {
        let mut path = std::env::current_exe().unwrap();
        path.pop();
        path.pop();
        path.push("fexpr");
        Command::new(path)
    }

    #[test]
    fn test_expr_help() {
        let output = cmd().arg("--help").output().unwrap();
        assert!(output.status.success());
        assert!(String::from_utf8_lossy(&output.stdout).contains("Usage"));
    }

    #[test]
    fn test_expr_version() {
        let output = cmd().arg("--version").output().unwrap();
        assert!(output.status.success());
        assert!(String::from_utf8_lossy(&output.stdout).contains("fcoreutils"));
    }
    #[test]
    fn test_expr_add() {
        let output = cmd().args(["2", "+", "3"]).output().unwrap();
        assert!(output.status.success());
        assert_eq!(String::from_utf8_lossy(&output.stdout).trim(), "5");
    }

    #[test]
    fn test_expr_multiply() {
        let output = cmd().args(["3", "*", "4"]).output().unwrap();
        assert!(output.status.success());
        assert_eq!(String::from_utf8_lossy(&output.stdout).trim(), "12");
    }

    #[test]
    fn test_expr_length() {
        let output = cmd().args(["length", "hello"]).output().unwrap();
        assert!(output.status.success());
        assert_eq!(String::from_utf8_lossy(&output.stdout).trim(), "5");
    }

    #[test]
    fn test_expr_comparison() {
        let output = cmd().args(["5", ">", "3"]).output().unwrap();
        assert!(output.status.success());
        assert_eq!(String::from_utf8_lossy(&output.stdout).trim(), "1");
    }
}
