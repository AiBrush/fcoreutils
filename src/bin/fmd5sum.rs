use std::io::{self, BufReader, BufWriter, Write};
use std::process;

use clap::Parser;

use coreutils_rs::hash::{self, HashAlgorithm};

#[derive(Parser)]
#[command(name = "fmd5sum", about = "Compute and check MD5 message digest")]
struct Cli {
    #[arg(short = 'b', long = "binary")]
    binary: bool,
    #[arg(short = 'c', long = "check")]
    check: bool,
    #[arg(long = "tag")]
    tag: bool,
    #[arg(short = 't', long = "text")]
    text: bool,
    #[arg(long = "quiet")]
    quiet: bool,
    #[arg(long = "status")]
    status: bool,
    #[arg(long = "strict")]
    strict: bool,
    #[arg(short = 'w', long = "warn")]
    warn: bool,
    files: Vec<String>,
}

fn main() {
    let cli = Cli::parse();
    let algo = HashAlgorithm::Md5;
    let files = if cli.files.is_empty() {
        vec!["-".to_string()]
    } else {
        cli.files.clone()
    };

    let stdout = io::stdout();
    let mut out = BufWriter::new(stdout.lock());
    let mut had_error = false;

    if cli.check {
        for filename in &files {
            let reader: Box<dyn io::BufRead> = if filename == "-" {
                Box::new(BufReader::new(io::stdin().lock()))
            } else {
                match std::fs::File::open(filename) {
                    Ok(f) => Box::new(BufReader::new(f)),
                    Err(e) => {
                        eprintln!("fmd5sum: {}: {}", filename, e);
                        had_error = true;
                        continue;
                    }
                }
            };
            let mut err_out = io::stderr();
            let opts = hash::CheckOptions {
                quiet: cli.quiet,
                status_only: cli.status,
                strict: cli.strict,
                warn: cli.warn,
            };
            match hash::check_file(algo, reader, &opts, &mut out, &mut err_out) {
                Ok((_ok, fail, _fmt)) => {
                    if fail > 0 {
                        had_error = true;
                    }
                }
                Err(e) => {
                    eprintln!("fmd5sum: {}: {}", filename, e);
                    had_error = true;
                }
            }
        }
    } else {
        for filename in &files {
            let hash_result = if filename == "-" {
                hash::hash_stdin(algo)
            } else {
                hash::hash_file(algo, std::path::Path::new(filename))
            };
            match hash_result {
                Ok(h) => {
                    let display_name = if filename == "-" {
                        "-"
                    } else {
                        filename.as_str()
                    };
                    if cli.tag {
                        let _ = hash::print_hash_tag(&mut out, algo, &h, display_name);
                    } else {
                        let _ = hash::print_hash(&mut out, &h, display_name, cli.binary);
                    }
                }
                Err(e) => {
                    eprintln!("fmd5sum: {}: {}", filename, e);
                    had_error = true;
                }
            }
        }
    }

    let _ = out.flush();
    if had_error {
        process::exit(1);
    }
}
