use std::process;

use coreutils_rs::common::reset_sigpipe;
use coreutils_rs::dd::{self, DdConfig};

fn main() {
    reset_sigpipe();

    let args: Vec<String> = std::env::args().skip(1).collect();

    // Handle --help, --version, and strip leading '--' separator
    let mut operand_args = Vec::new();
    let mut saw_separator = false;
    for arg in &args {
        if saw_separator {
            operand_args.push(arg.clone());
            continue;
        }
        match arg.as_str() {
            "--help" => {
                dd::print_help();
                process::exit(0);
            }
            "--version" => {
                dd::print_version();
                process::exit(0);
            }
            "--" => {
                saw_separator = true;
            }
            _ => operand_args.push(arg.clone()),
        }
    }

    let config: DdConfig = match dd::parse_dd_args(&operand_args) {
        Ok(c) => c,
        Err(e) => {
            eprintln!("dd: {}", e);
            process::exit(1);
        }
    };

    match dd::dd_copy(&config) {
        Ok(_) => {}
        Err(e) => {
            eprintln!("dd: {}", e);
            process::exit(1);
        }
    }
}
