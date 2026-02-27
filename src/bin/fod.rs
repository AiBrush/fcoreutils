// fod -- octal/hex dump
//
// Usage: od [OPTION]... [FILE]...
//        od [-abcdfilosx] [FILE] [[+]OFFSET[.][b]]

use std::io::{self, Read};
use std::process;

use coreutils_rs::common::reset_sigpipe;
use coreutils_rs::od::{
    AddressRadix, Endian, OdConfig, OutputFormat, od_process, parse_format_type,
};

const TOOL_NAME: &str = "od";
const VERSION: &str = env!("CARGO_PKG_VERSION");

fn main() {
    reset_sigpipe();

    let args: Vec<String> = std::env::args().skip(1).collect();

    let mut address_radix = None;
    let mut formats: Vec<OutputFormat> = Vec::new();
    let mut z_flags: Vec<bool> = Vec::new();
    let mut skip_bytes: u64 = 0;
    let mut read_bytes: Option<u64> = None;
    let mut width: Option<usize> = None;
    let mut show_duplicates = false;
    let mut endian = Endian::Native;
    let mut operands: Vec<String> = Vec::new();
    let mut saw_dashdash = false;

    let mut i = 0;
    while i < args.len() {
        let arg = &args[i];
        if saw_dashdash {
            operands.push(arg.clone());
            i += 1;
            continue;
        }
        match arg.as_str() {
            "--help" => {
                print_help();
                return;
            }
            "--version" => {
                println!("{} (fcoreutils) {}", TOOL_NAME, VERSION);
                return;
            }
            "--" => saw_dashdash = true,
            "-v" | "--output-duplicates" => show_duplicates = true,

            "--traditional" => { /* accepted, ignored */ }

            _ if arg.starts_with("--endian=") => {
                let val = &arg["--endian=".len()..];
                match val {
                    "little" => endian = Endian::Little,
                    "big" => endian = Endian::Big,
                    _ => {
                        eprintln!(
                            "{}: invalid argument '{}' for '--endian'\nValid arguments are:\n  - 'big'\n  - 'little'",
                            TOOL_NAME, val
                        );
                        process::exit(1);
                    }
                }
            }

            // Traditional format shortcuts
            "-a" => {
                formats.push(OutputFormat::NamedChar);
                z_flags.push(false);
            }
            "-b" => {
                formats.push(OutputFormat::Octal(1));
                z_flags.push(false);
            }
            "-c" => {
                formats.push(OutputFormat::PrintableChar);
                z_flags.push(false);
            }
            "-d" => {
                formats.push(OutputFormat::UnsignedDec(2));
                z_flags.push(false);
            }
            "-e" => {
                formats.push(OutputFormat::Float(8));
                z_flags.push(false);
            }
            "-f" => {
                formats.push(OutputFormat::Float(4));
                z_flags.push(false);
            }
            "-h" => {
                formats.push(OutputFormat::Hex(2));
                z_flags.push(false);
            }
            "-i" => {
                formats.push(OutputFormat::SignedDec(4));
                z_flags.push(false);
            }
            "-l" => {
                formats.push(OutputFormat::SignedDec(8));
                z_flags.push(false);
            }
            "-o" => {
                formats.push(OutputFormat::Octal(2));
                z_flags.push(false);
            }
            "-s" => {
                formats.push(OutputFormat::SignedDec(2));
                z_flags.push(false);
            }
            "-x" => {
                formats.push(OutputFormat::Hex(2));
                z_flags.push(false);
            }

            _ if arg.starts_with("--address-radix=") => {
                address_radix = Some(parse_radix(&arg["--address-radix=".len()..]));
            }
            _ if arg.starts_with("--format=") => {
                let fmt_str = &arg["--format=".len()..];
                match parse_format_type(fmt_str) {
                    Ok((f, z)) => {
                        formats.push(f);
                        z_flags.push(z);
                    }
                    Err(e) => {
                        eprintln!("{}: {}", TOOL_NAME, e);
                        process::exit(1);
                    }
                }
            }
            _ if arg.starts_with("--skip-bytes=") => {
                skip_bytes = parse_offset(&arg["--skip-bytes=".len()..]);
            }
            _ if arg.starts_with("--read-bytes=") => {
                read_bytes = Some(parse_offset(&arg["--read-bytes=".len()..]));
            }
            _ if arg == "--width" => {
                // --width without =
                i += 1;
                if i < args.len() {
                    width = Some(args[i].parse().unwrap_or(16));
                }
            }
            _ if arg.starts_with("--width=") => {
                width = Some(arg["--width=".len()..].parse().unwrap_or(16));
            }
            _ if arg.starts_with("--width") => {
                // --width with no argument means default 32
                width = Some(32);
            }
            _ if arg.starts_with('-') && arg.len() > 1 && !arg.starts_with("--") => {
                // Short options
                let bytes = arg.as_bytes();
                let mut j = 1;
                while j < bytes.len() {
                    match bytes[j] {
                        b'A' => {
                            j += 1;
                            if j < bytes.len() {
                                address_radix =
                                    Some(parse_radix(&String::from_utf8_lossy(&bytes[j..j + 1])));
                                j += 1;
                            } else {
                                i += 1;
                                if i < args.len() {
                                    address_radix = Some(parse_radix(&args[i]));
                                }
                            }
                            continue;
                        }
                        b'j' => {
                            let rest: String =
                                String::from_utf8_lossy(&bytes[j + 1..]).into_owned();
                            if rest.is_empty() {
                                i += 1;
                                if i < args.len() {
                                    skip_bytes = parse_offset(&args[i]);
                                }
                            } else {
                                skip_bytes = parse_offset(&rest);
                            }
                            j = bytes.len(); // consumed rest
                            continue;
                        }
                        b'N' => {
                            let rest: String =
                                String::from_utf8_lossy(&bytes[j + 1..]).into_owned();
                            if rest.is_empty() {
                                i += 1;
                                if i < args.len() {
                                    read_bytes = Some(parse_offset(&args[i]));
                                }
                            } else {
                                read_bytes = Some(parse_offset(&rest));
                            }
                            j = bytes.len();
                            continue;
                        }
                        b't' => {
                            let rest: String =
                                String::from_utf8_lossy(&bytes[j + 1..]).into_owned();
                            let fmt_str = if rest.is_empty() {
                                i += 1;
                                if i < args.len() {
                                    args[i].clone()
                                } else {
                                    eprintln!("{}: option requires an argument -- 't'", TOOL_NAME);
                                    process::exit(1);
                                }
                            } else {
                                rest
                            };
                            match parse_format_type(&fmt_str) {
                                Ok((f, z)) => {
                                    formats.push(f);
                                    z_flags.push(z);
                                }
                                Err(e) => {
                                    eprintln!("{}: {}", TOOL_NAME, e);
                                    process::exit(1);
                                }
                            }
                            j = bytes.len();
                            continue;
                        }
                        b'w' => {
                            let rest: String =
                                String::from_utf8_lossy(&bytes[j + 1..]).into_owned();
                            if rest.is_empty() {
                                // -w alone means default 32
                                width = Some(32);
                            } else {
                                width = Some(rest.parse().unwrap_or(16));
                            }
                            j = bytes.len();
                            continue;
                        }
                        b'v' => show_duplicates = true,
                        b'a' => {
                            formats.push(OutputFormat::NamedChar);
                            z_flags.push(false);
                        }
                        b'b' => {
                            formats.push(OutputFormat::Octal(1));
                            z_flags.push(false);
                        }
                        b'c' => {
                            formats.push(OutputFormat::PrintableChar);
                            z_flags.push(false);
                        }
                        b'd' => {
                            formats.push(OutputFormat::UnsignedDec(2));
                            z_flags.push(false);
                        }
                        b'e' => {
                            formats.push(OutputFormat::Float(8));
                            z_flags.push(false);
                        }
                        b'f' => {
                            formats.push(OutputFormat::Float(4));
                            z_flags.push(false);
                        }
                        b'h' => {
                            formats.push(OutputFormat::Hex(2));
                            z_flags.push(false);
                        }
                        b'i' => {
                            formats.push(OutputFormat::SignedDec(4));
                            z_flags.push(false);
                        }
                        b'l' => {
                            formats.push(OutputFormat::SignedDec(8));
                            z_flags.push(false);
                        }
                        b'o' => {
                            formats.push(OutputFormat::Octal(2));
                            z_flags.push(false);
                        }
                        b's' => {
                            formats.push(OutputFormat::SignedDec(2));
                            z_flags.push(false);
                        }
                        b'x' => {
                            formats.push(OutputFormat::Hex(2));
                            z_flags.push(false);
                        }
                        _ => {
                            eprintln!("{}: invalid option -- '{}'", TOOL_NAME, bytes[j] as char);
                            eprintln!("Try '{} --help' for more information.", TOOL_NAME);
                            process::exit(1);
                        }
                    }
                    j += 1;
                }
            }
            _ if arg.starts_with("--") => {
                eprintln!("{}: unrecognized option '{}'", TOOL_NAME, arg);
                eprintln!("Try '{} --help' for more information.", TOOL_NAME);
                process::exit(1);
            }
            _ if arg.starts_with('+') => {
                // Traditional offset: +OFFSET[.][b]
                skip_bytes = parse_offset(&arg[1..]);
            }
            _ => operands.push(arg.clone()),
        }
        i += 1;
    }

    let config = OdConfig {
        address_radix: address_radix.unwrap_or(AddressRadix::Octal),
        formats: if formats.is_empty() {
            vec![OutputFormat::Octal(2)]
        } else {
            formats
        },
        z_flags: if z_flags.is_empty() {
            vec![false]
        } else {
            z_flags
        },
        skip_bytes,
        read_bytes,
        width: width.unwrap_or(16),
        show_duplicates,
        endian,
    };

    let stdout = io::stdout();
    let mut out = io::BufWriter::with_capacity(256 * 1024, stdout.lock());

    if operands.is_empty() || (operands.len() == 1 && operands[0] == "-") {
        // On Unix, use unbuffered stdin reads when -N is specified so that
        // sequential invocations like `(od -N3 -c; od -N3 -c) < file` work
        // correctly — buffered StdinLock would over-read from the fd.
        let result = {
            #[cfg(unix)]
            {
                use std::os::unix::io::FromRawFd;
                if config.read_bytes.is_some() {
                    // SAFETY: fd 0 (stdin) is always valid in normal process execution.
                    // ManuallyDrop prevents closing fd 0 on drop. Using &File gives
                    // direct unbuffered read(2) so exactly read_bytes bytes are consumed.
                    let stdin_file =
                        std::mem::ManuallyDrop::new(unsafe { std::fs::File::from_raw_fd(0) });
                    od_process(&*stdin_file, &mut out, &config)
                } else {
                    let stdin = io::stdin();
                    od_process(stdin.lock(), &mut out, &config)
                }
            }
            #[cfg(not(unix))]
            {
                let stdin = io::stdin();
                od_process(stdin.lock(), &mut out, &config)
            }
        };
        if let Err(e) = result {
            eprintln!("{}: {}", TOOL_NAME, e);
            process::exit(1);
        }
    } else if operands.len() == 1 && operands[0] != "-" {
        // Single file: read_file uses O_NOATIME + exact-size preallocation
        match coreutils_rs::common::io::read_file(std::path::Path::new(&operands[0])) {
            Ok(data) => {
                if let Err(e) = od_process(data.as_ref(), &mut out, &config) {
                    eprintln!("{}: {}", TOOL_NAME, e);
                    process::exit(1);
                }
            }
            Err(e) => {
                eprintln!("{}: {}: {}", TOOL_NAME, operands[0], e);
                process::exit(1);
            }
        }
    } else {
        // Multiple files: concatenate via std::fs::read (avoids mmap overhead since data
        // is immediately copied into combined buffer anyway).
        let mut combined = Vec::new();
        for path in &operands {
            if path == "-" {
                let mut buf = Vec::new();
                io::stdin()
                    .lock()
                    .read_to_end(&mut buf)
                    .unwrap_or_else(|e| {
                        eprintln!("{}: standard input: {}", TOOL_NAME, e);
                        process::exit(1);
                    });
                combined.extend_from_slice(&buf);
            } else {
                match std::fs::read(path) {
                    Ok(data) => {
                        combined.extend_from_slice(&data);
                    }
                    Err(e) => {
                        eprintln!("{}: {}: {}", TOOL_NAME, path, e);
                        process::exit(1);
                    }
                }
            }
        }
        if let Err(e) = od_process(combined.as_slice(), &mut out, &config) {
            eprintln!("{}: {}", TOOL_NAME, e);
            process::exit(1);
        }
    }
}

fn parse_radix(s: &str) -> AddressRadix {
    match s {
        "o" => AddressRadix::Octal,
        "d" => AddressRadix::Decimal,
        "x" => AddressRadix::Hex,
        "n" => AddressRadix::None,
        _ => {
            eprintln!(
                "{}: invalid address radix '{}'; it must be one character from [doxn]",
                TOOL_NAME, s
            );
            process::exit(1);
        }
    }
}

fn parse_offset(s: &str) -> u64 {
    let s = s.trim();
    let (num_str, multiplier) = if let Some(n) = s.strip_suffix("GiB") {
        (n, 1_073_741_824u64)
    } else if let Some(n) = s.strip_suffix("GB") {
        (n, 1_000_000_000u64)
    } else if let Some(n) = s.strip_suffix('G') {
        (n, 1_073_741_824u64)
    } else if let Some(n) = s.strip_suffix("MiB") {
        (n, 1_048_576u64)
    } else if let Some(n) = s.strip_suffix("MB") {
        (n, 1_000_000u64)
    } else if let Some(n) = s.strip_suffix('M') {
        (n, 1_048_576u64)
    } else if let Some(n) = s.strip_suffix("KiB") {
        (n, 1_024u64)
    } else if let Some(n) = s.strip_suffix("KB") {
        (n, 1_000u64)
    } else if let Some(n) = s.strip_suffix("kB") {
        (n, 1_000u64)
    } else if let Some(n) = s.strip_suffix('K') {
        (n, 1_024u64)
    } else if let Some(n) = s.strip_suffix('k') {
        (n, 1_024u64)
    } else if let Some(n) = s.strip_suffix('b') {
        (n, 512u64)
    } else {
        (s, 1u64)
    };

    let base_val = if num_str.starts_with("0x") || num_str.starts_with("0X") {
        u64::from_str_radix(&num_str[2..], 16).unwrap_or(0)
    } else if num_str.starts_with('0') && num_str.len() > 1 {
        u64::from_str_radix(&num_str[1..], 8).unwrap_or(0)
    } else {
        num_str.parse::<u64>().unwrap_or(0)
    };

    base_val * multiplier
}

fn print_help() {
    println!("Usage: {} [OPTION]... [FILE]...", TOOL_NAME);
    println!("  or:  {} -C [OPTION]... [FILE]...", TOOL_NAME);
    println!("Write an unambiguous representation, octal bytes by default,");
    println!("of FILE to standard output.");
    println!();
    println!("  -A, --address-radix=RADIX   output format for file offsets; RADIX is one");
    println!("                                of [doxn], for Decimal, Octal, Hex or None");
    println!("  -j, --skip-bytes=BYTES      skip BYTES input bytes first");
    println!("  -N, --read-bytes=BYTES      limit dump to BYTES input bytes");
    println!("  -t, --format=TYPE           select output format or formats");
    println!("  -v, --output-duplicates     do not use * to mark line suppression");
    println!("  -w[BYTES], --width[=BYTES]  output BYTES bytes per output line;");
    println!("                                32 is implied when BYTES is not specified");
    println!("      --help     display this help and exit");
    println!("      --version  output version information and exit");
    println!();
    println!("Traditional format specifications may be intermixed:");
    println!("  -b   same as -t o1");
    println!("  -c   same as -t c");
    println!("  -d   same as -t u2");
    println!("  -o   same as -t o2");
    println!("  -s   same as -t d2");
    println!("  -x   same as -t x2");
}
