use std::io::{self, Write};
#[cfg(unix)]
use std::mem::ManuallyDrop;
#[cfg(unix)]
use std::os::unix::io::FromRawFd;
use std::path::Path;
use std::process;

use clap::Parser;

use coreutils_rs::base64::core as b64;
use coreutils_rs::common::io::read_file;

#[derive(Parser)]
#[command(
    name = "base64",
    about = "Base64 encode or decode FILE, or standard input, to standard output.",
    after_help = "With no FILE, or when FILE is -, read standard input.\n\n\
        The data are encoded as described for the base64 alphabet in RFC 4648.\n\
        When decoding, the input may contain newlines in addition to the bytes of\n\
        the formal base64 alphabet.  Use --ignore-garbage to attempt to recover\n\
        from any other non-alphabet bytes in the encoded stream.",
    version
)]
struct Cli {
    /// Decode data
    #[arg(short = 'd', long = "decode")]
    decode: bool,

    /// When decoding, ignore non-alphabet characters
    #[arg(short = 'i', long = "ignore-garbage")]
    ignore_garbage: bool,

    /// Wrap encoded lines after COLS character (default 76).
    /// Use 0 to disable line wrapping
    #[arg(short = 'w', long = "wrap", value_name = "COLS", default_value = "76")]
    wrap: usize,

    /// File to process (reads stdin if omitted or -)
    file: Option<String>,
}

/// Raw fd stdout for zero-overhead writes on Unix.
/// Bypasses BufWriter/StdoutLock overhead — our callers already batch
/// output into large (4MB+) chunks, so no intermediate buffering needed.
#[cfg(unix)]
#[inline]
fn raw_stdout() -> ManuallyDrop<std::fs::File> {
    unsafe { ManuallyDrop::new(std::fs::File::from_raw_fd(1)) }
}

fn main() {
    let cli = Cli::parse();

    let filename = cli.file.as_deref().unwrap_or("-");

    // Raw fd stdout with BufWriter for batching small writes (wrapped encoding)
    #[cfg(unix)]
    let mut raw = raw_stdout();
    #[cfg(unix)]
    let mut out = io::BufWriter::with_capacity(2 * 1024 * 1024, &mut *raw);
    #[cfg(not(unix))]
    let mut out = io::BufWriter::with_capacity(2 * 1024 * 1024, io::stdout().lock());

    let result = if filename == "-" {
        process_stdin(&cli, &mut out)
    } else {
        process_file(filename, &cli, &mut out)
    };

    if let Err(e) = out.flush()
        && e.kind() != io::ErrorKind::BrokenPipe
    {
        eprintln!("base64: {}", e);
        process::exit(1);
    }

    if let Err(e) = result {
        // Ignore broken pipe
        if e.kind() == io::ErrorKind::BrokenPipe {
            process::exit(0);
        }
        eprintln!("base64: {}", e);
        process::exit(1);
    }
}

fn process_stdin(cli: &Cli, out: &mut impl Write) -> io::Result<()> {
    if cli.decode {
        let mut stdin = io::stdin().lock();
        b64::decode_stream(&mut stdin, cli.ignore_garbage, out)
    } else {
        let mut stdin = io::stdin().lock();
        b64::encode_stream(&mut stdin, cli.wrap, out)
    }
}

fn process_file(filename: &str, cli: &Cli, out: &mut impl Write) -> io::Result<()> {
    if cli.decode {
        // For decode: read to owned Vec for in-place whitespace strip + decode.
        // Avoids double-buffering (mmap + clean buffer) by stripping in-place.
        let mut data = std::fs::read(filename)?;
        b64::decode_owned(&mut data, cli.ignore_garbage, out)
    } else {
        // For encode: mmap for zero-copy read access.
        let data = read_file(Path::new(filename))?;
        b64::encode_to_writer(&data, cli.wrap, out)
    }
}
