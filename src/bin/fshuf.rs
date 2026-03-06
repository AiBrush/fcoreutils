// fshuf -- generate random permutations
//
// Usage: shuf [OPTION]... [FILE]
//        shuf -e [OPTION]... [ARG]...
//        shuf -i LO-HI [OPTION]...

use std::fs;
use std::io::{self, Read, Write};
use std::process;

/// Write entire buffer to a raw fd, retrying on short writes.
/// Returns false on BrokenPipe (caller should stop output), propagates other errors.
#[cfg(unix)]
fn raw_write_all(fd: i32, mut data: &[u8]) -> io::Result<bool> {
    while !data.is_empty() {
        let n = unsafe { libc::write(fd, data.as_ptr() as *const _, data.len()) };
        if n < 0 {
            let err = io::Error::last_os_error();
            if err.kind() == io::ErrorKind::Interrupted {
                continue;
            }
            if err.kind() == io::ErrorKind::BrokenPipe {
                return Ok(false);
            }
            return Err(err);
        }
        data = &data[n as usize..];
    }
    Ok(true)
}

/// Write to a `dyn Write` with BrokenPipe handling.
/// Returns false on BrokenPipe (caller should stop output), propagates other errors.
fn checked_write_all(out: &mut dyn Write, data: &[u8]) -> io::Result<bool> {
    match out.write_all(data) {
        Ok(()) => Ok(true),
        Err(e) if e.kind() == io::ErrorKind::BrokenPipe => Ok(false),
        Err(e) => Err(e),
    }
}

const TOOL_NAME: &str = "shuf";
const VERSION: &str = env!("CARGO_PKG_VERSION");

fn print_help() {
    println!("Usage: {} [OPTION]... [FILE]", TOOL_NAME);
    println!("  or:  {} -e [OPTION]... [ARG]...", TOOL_NAME);
    println!("  or:  {} -i LO-HI [OPTION]...", TOOL_NAME);
    println!("Write a random permutation of the input lines to standard output.");
    println!();
    println!("With no FILE, or when FILE is -, read standard input.");
    println!();
    println!("Mandatory arguments to long options are mandatory for short options too.");
    println!("  -e, --echo                treat each ARG as an input line");
    println!("  -i, --input-range=LO-HI   treat each number LO through HI as an input line");
    println!("  -n, --head-count=COUNT     output at most COUNT lines");
    println!("  -o, --output=FILE          write result to FILE instead of standard output");
    println!("  -r, --repeat              output lines can be repeated");
    println!("  -z, --zero-terminated      line delimiter is NUL, not newline");
    println!("      --random-source=FILE   get random bytes from FILE");
    println!("      --help     display this help and exit");
    println!("      --version  output version information and exit");
}

fn print_version() {
    println!("{} (fcoreutils) {}", TOOL_NAME, VERSION);
}

/// Random number generator matching GNU's randint algorithm.
/// When using --random-source, reads bytes from the file on each generation.
/// When no source, uses xorshift64 PRNG seeded from /dev/urandom.
enum RandGen {
    /// GNU-compatible: read bytes from file, maintain running state
    FileSource {
        reader: io::BufReader<fs::File>,
        source_path: String,
        randnum: u64,
        randmax: u64,
    },
    /// Fast PRNG for when no --random-source given
    Xorshift { state: u64 },
}

impl RandGen {
    fn from_file(path: &str) -> Self {
        let f = match fs::File::open(path) {
            Ok(f) => f,
            Err(e) => {
                eprintln!(
                    "{}: {}: {}",
                    TOOL_NAME,
                    path,
                    coreutils_rs::common::io_error_msg(&e)
                );
                process::exit(1);
            }
        };
        RandGen::FileSource {
            reader: io::BufReader::new(f),
            source_path: path.to_string(),
            randnum: 0,
            randmax: 0,
        }
    }

    fn from_urandom() -> Self {
        let mut f = match fs::File::open("/dev/urandom") {
            Ok(f) => f,
            Err(_) => {
                let t = std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .unwrap_or_default()
                    .as_nanos();
                let mut state = t as u64;
                if state == 0 {
                    state = 0x12345678_9abcdef0;
                }
                return RandGen::Xorshift { state };
            }
        };
        let mut buf = [0u8; 8];
        let _ = f.read_exact(&mut buf);
        let mut state = u64::from_le_bytes(buf);
        if state == 0 {
            state = 0x12345678_9abcdef0;
        }
        RandGen::Xorshift { state }
    }

    /// Generate a random number in [0, genmax] matching GNU's randint_genmax.
    fn gen_max(&mut self, genmax: u64) -> u64 {
        if genmax == 0 {
            return 0;
        }
        match self {
            RandGen::FileSource {
                reader,
                source_path,
                randnum,
                randmax,
            } => loop {
                if *randmax < genmax {
                    let mut buf = [0u8; 1];
                    if reader.read_exact(&mut buf).is_err() {
                        eprintln!("{}: {}: end of file", TOOL_NAME, source_path);
                        process::exit(1);
                    }
                    *randnum = randnum.wrapping_mul(256).wrapping_add(buf[0] as u64);
                    *randmax = randmax.wrapping_mul(256).wrapping_add(255);
                } else {
                    let excess_max = *randmax - genmax;
                    let excess = excess_max % (genmax + 1);
                    if excess <= *randmax - *randnum {
                        let result = *randnum % (genmax + 1);
                        *randnum /= genmax + 1;
                        *randmax = excess_max / (genmax + 1);
                        return result;
                    }
                    // Rejection: need more bytes
                    let mut buf = [0u8; 1];
                    if reader.read_exact(&mut buf).is_err() {
                        eprintln!("{}: {}: end of file", TOOL_NAME, source_path);
                        process::exit(1);
                    }
                    *randnum = randnum.wrapping_mul(256).wrapping_add(buf[0] as u64);
                    *randmax = randmax.wrapping_mul(256).wrapping_add(255);
                }
            },
            RandGen::Xorshift { state } => {
                // Lemire's nearly-divisionless bounded random:
                // Uses widening multiply (u64 * u64 → u128) to map random value
                // to [0, n) range. Avoids expensive u64 division in ~all cases.
                let s = genmax + 1;
                loop {
                    *state ^= *state << 13;
                    *state ^= *state >> 7;
                    *state ^= *state << 17;
                    let x = *state;
                    let m = (x as u128) * (s as u128);
                    let l = m as u64; // low 64 bits
                    if l < s {
                        // Rare rejection path (< 1/2^32 probability for typical s)
                        let t = s.wrapping_neg() % s;
                        if l < t {
                            continue;
                        }
                    }
                    return (m >> 64) as u64;
                }
            }
        }
    }

    /// Return a random index in [0, n)
    fn gen_range(&mut self, n: usize) -> usize {
        if n <= 1 {
            return 0;
        }
        self.gen_max((n - 1) as u64) as usize
    }
}

/// Top-down Fisher-Yates shuffle (matches GNU's algorithm)
fn shuffle<T>(items: &mut [T], rng: &mut RandGen) {
    let n = items.len();
    if n <= 1 {
        return;
    }
    for i in 0..n {
        let j = i + rng.gen_range(n - i);
        items.swap(i, j);
    }
}

fn main() {
    coreutils_rs::common::reset_sigpipe();

    let args: Vec<String> = std::env::args().skip(1).collect();

    let mut echo_mode = false;
    let mut input_range: Option<(u64, u64)> = None;
    let mut input_range_count = 0u32;
    let mut head_counts: Vec<usize> = Vec::new();
    let mut output_file: Option<String> = None;
    let mut output_file_count = 0u32;
    let mut repeat = false;
    let mut zero_terminated = false;
    let mut random_source: Option<String> = None;
    let mut positional: Vec<String> = Vec::new();
    let mut echo_args: Vec<String> = Vec::new();

    let mut i = 0;
    // First pass: check for -e/--echo to determine positional arg handling
    let has_echo = args.iter().any(|a| {
        a == "-e"
            || a == "--echo"
            || (a.starts_with('-') && !a.starts_with("--") && a.len() > 1 && a[1..].contains('e'))
    });

    // Helper: check if a long option matches (supports abbreviation, min 3 chars)
    fn match_long(arg: &str, full: &str) -> bool {
        arg == full || (arg.len() >= 3 && full.starts_with(arg))
    }

    while i < args.len() {
        let arg = &args[i];

        // Handle long options
        if arg.starts_with("--") {
            if arg == "--help" {
                print_help();
                return;
            } else if arg == "--version" {
                print_version();
                return;
            } else if match_long(arg, "--echo") {
                echo_mode = true;
            } else if match_long(arg, "--repeat") {
                repeat = true;
            } else if match_long(arg, "--zero-terminated") {
                zero_terminated = true;
            } else if arg == "--input-range" || match_long(arg, "--input-range") {
                i += 1;
                if i >= args.len() {
                    eprintln!("{}: option '--input-range' requires an argument", TOOL_NAME);
                    process::exit(1);
                }
                input_range = Some(parse_range(&args[i]));
                input_range_count += 1;
            } else if let Some(rest) = arg.strip_prefix("--input-range=") {
                input_range = Some(parse_range(rest));
                input_range_count += 1;
            } else if arg == "--head-count" || match_long(arg, "--head-count") {
                i += 1;
                if i >= args.len() {
                    eprintln!("{}: option '--head-count' requires an argument", TOOL_NAME);
                    process::exit(1);
                }
                let val = parse_count(&args[i]);
                head_counts.push(val);
            } else if let Some(rest) = arg.strip_prefix("--head-count=") {
                let val = parse_count(rest);
                head_counts.push(val);
            } else if arg == "--output" || match_long(arg, "--output") {
                i += 1;
                if i >= args.len() {
                    eprintln!("{}: option '--output' requires an argument", TOOL_NAME);
                    process::exit(1);
                }
                output_file = Some(args[i].clone());
                output_file_count += 1;
            } else if let Some(rest) = arg.strip_prefix("--output=") {
                output_file = Some(rest.to_string());
                output_file_count += 1;
            } else if arg == "--random-source" || match_long(arg, "--random-source") {
                i += 1;
                if i >= args.len() {
                    eprintln!(
                        "{}: option '--random-source' requires an argument",
                        TOOL_NAME
                    );
                    process::exit(1);
                }
                random_source = Some(args[i].clone());
            } else if let Some(rest) = arg.strip_prefix("--random-source=") {
                random_source = Some(rest.to_string());
            } else {
                eprintln!("{}: unrecognized option '{}'", TOOL_NAME, arg);
                eprintln!("Try '{} --help' for more information.", TOOL_NAME);
                process::exit(1);
            }
        } else if arg.starts_with('-') && arg.len() > 1 {
            // Handle short options (possibly combined like -er, -rn3, etc.)
            let bytes = arg.as_bytes();
            let mut j = 1;
            while j < bytes.len() {
                match bytes[j] {
                    b'e' => echo_mode = true,
                    b'r' => repeat = true,
                    b'z' => zero_terminated = true,
                    b'i' => {
                        // Rest of this arg or next arg is the range value
                        if j + 1 < bytes.len() {
                            let rest = &arg[j + 1..];
                            input_range = Some(parse_range(rest));
                            input_range_count += 1;
                        } else {
                            i += 1;
                            if i >= args.len() {
                                eprintln!("{}: option requires an argument -- 'i'", TOOL_NAME);
                                process::exit(1);
                            }
                            input_range = Some(parse_range(&args[i]));
                            input_range_count += 1;
                        }
                        j = bytes.len(); // consumed rest
                        continue;
                    }
                    b'n' => {
                        if j + 1 < bytes.len() {
                            let rest = &arg[j + 1..];
                            let val = parse_count(rest);
                            head_counts.push(val);
                        } else {
                            i += 1;
                            if i >= args.len() {
                                eprintln!("{}: option requires an argument -- 'n'", TOOL_NAME);
                                process::exit(1);
                            }
                            let val = parse_count(&args[i]);
                            head_counts.push(val);
                        }
                        j = bytes.len();
                        continue;
                    }
                    b'o' => {
                        if j + 1 < bytes.len() {
                            let rest = &arg[j + 1..];
                            output_file = Some(rest.to_string());
                        } else {
                            i += 1;
                            if i >= args.len() {
                                eprintln!("{}: option requires an argument -- 'o'", TOOL_NAME);
                                process::exit(1);
                            }
                            output_file = Some(args[i].clone());
                        }
                        output_file_count += 1;
                        j = bytes.len();
                        continue;
                    }
                    _ => {
                        eprintln!("{}: invalid option -- '{}'", TOOL_NAME, bytes[j] as char);
                        eprintln!("Try '{} --help' for more information.", TOOL_NAME);
                        process::exit(1);
                    }
                }
                j += 1;
            }
        } else if has_echo {
            echo_args.push(arg.clone());
        } else {
            positional.push(arg.clone());
        }
        i += 1;
    }

    // Validate option conflicts (GNU compat)
    if input_range_count > 1 {
        eprintln!("{}: multiple -i options specified", TOOL_NAME);
        process::exit(1);
    }
    if output_file_count > 1 {
        eprintln!("{}: multiple output files specified", TOOL_NAME);
        process::exit(1);
    }
    // GNU shuf: multiple -n uses the smallest value
    let head_count: Option<usize> = if head_counts.is_empty() {
        None
    } else {
        Some(*head_counts.iter().min().unwrap())
    };
    if echo_mode && input_range.is_some() {
        eprintln!("{}: cannot combine -e and -i options", TOOL_NAME);
        process::exit(1);
    }
    if input_range.is_some() && !positional.is_empty() {
        eprintln!(
            "{}: extra operand \u{2018}{}\u{2019}",
            TOOL_NAME, positional[0]
        );
        eprintln!("Try '{} --help' for more information.", TOOL_NAME);
        process::exit(1);
    }

    let mut rng = if let Some(ref source) = random_source {
        RandGen::from_file(source)
    } else {
        RandGen::from_urandom()
    };

    let delimiter = if zero_terminated { b'\0' } else { b'\n' };

    // Dispatch to concrete output type to avoid Box<dyn Write> vtable overhead.
    // This gives ~10-20% speedup on tight RNG+output loops.
    if let Some(ref outfile) = output_file {
        let f = match fs::File::create(outfile) {
            Ok(f) => f,
            Err(e) => {
                eprintln!(
                    "{}: {}: {}",
                    TOOL_NAME,
                    outfile,
                    coreutils_rs::common::io_error_msg(&e)
                );
                process::exit(1);
            }
        };
        let mut out = io::BufWriter::with_capacity(1024 * 1024, f);
        dispatch_mode(
            echo_mode,
            input_range,
            &mut echo_args,
            &positional,
            zero_terminated,
            &mut rng,
            &mut out,
            delimiter,
            head_count,
            repeat,
            output_file.is_none(),
        );
        if let Err(e) = out.flush()
            && e.kind() != std::io::ErrorKind::BrokenPipe
        {
            eprintln!("shuf: write error: {e}");
            std::process::exit(1);
        }
    } else {
        let stdout = io::stdout();
        let mut out = io::BufWriter::with_capacity(1024 * 1024, stdout.lock());
        dispatch_mode(
            echo_mode,
            input_range,
            &mut echo_args,
            &positional,
            zero_terminated,
            &mut rng,
            &mut out,
            delimiter,
            head_count,
            repeat,
            true,
        );
        if let Err(e) = out.flush()
            && e.kind() != std::io::ErrorKind::BrokenPipe
        {
            eprintln!("shuf: write error: {e}");
            std::process::exit(1);
        }
    }
}

#[allow(clippy::too_many_arguments)]
fn dispatch_mode(
    echo_mode: bool,
    input_range: Option<(u64, u64)>,
    echo_args: &mut [String],
    positional: &[String],
    zero_terminated: bool,
    rng: &mut RandGen,
    out: &mut impl Write,
    delimiter: u8,
    head_count: Option<usize>,
    repeat: bool,
    is_stdout: bool,
) {
    if echo_mode {
        if echo_args.is_empty() && !repeat {
            return;
        }
        run_string_shuffle(echo_args, rng, out, delimiter, head_count, repeat);
    } else if let Some((lo, hi)) = input_range {
        run_range_shuffle(lo, hi, rng, out, delimiter, head_count, repeat);
    } else {
        let filename = positional.first().map(|s| s.as_str());
        run_file_shuffle(
            filename,
            zero_terminated,
            rng,
            out,
            delimiter,
            head_count,
            repeat,
            is_stdout,
        );
    }
}

fn run_string_shuffle(
    lines: &mut [String],
    rng: &mut RandGen,
    out: &mut impl Write,
    delimiter: u8,
    head_count: Option<usize>,
    repeat: bool,
) {
    if repeat {
        let count = head_count.unwrap_or(usize::MAX);
        if count == 0 {
            return;
        }
        if lines.is_empty() {
            eprintln!("{}: no lines to repeat", TOOL_NAME);
            process::exit(1);
        }
        for _ in 0..count {
            let idx = rng.gen_range(lines.len());
            match checked_write_all(out, lines[idx].as_bytes()) {
                Ok(false) => return,
                Err(err) => {
                    eprintln!("{}: write error: {}", TOOL_NAME, err);
                    process::exit(1);
                }
                _ => {}
            }
            match checked_write_all(out, &[delimiter]) {
                Ok(false) => return,
                Err(err) => {
                    eprintln!("{}: write error: {}", TOOL_NAME, err);
                    process::exit(1);
                }
                _ => {}
            }
        }
    } else {
        shuffle(lines, rng);
        let count = head_count.unwrap_or(lines.len()).min(lines.len());
        for line in lines.iter().take(count) {
            match checked_write_all(out, line.as_bytes()) {
                Ok(false) => return,
                Err(err) => {
                    eprintln!("{}: write error: {}", TOOL_NAME, err);
                    process::exit(1);
                }
                _ => {}
            }
            match checked_write_all(out, &[delimiter]) {
                Ok(false) => return,
                Err(err) => {
                    eprintln!("{}: write error: {}", TOOL_NAME, err);
                    process::exit(1);
                }
                _ => {}
            }
        }
    }
}

fn run_range_shuffle(
    lo: u64,
    hi: u64,
    rng: &mut RandGen,
    out: &mut impl Write,
    delimiter: u8,
    head_count: Option<usize>,
    repeat: bool,
) {
    let range_size = hi - lo + 1;
    let mut ibuf = itoa::Buffer::new();

    if repeat {
        let count = head_count.unwrap_or(usize::MAX);
        if count == 0 || range_size == 0 {
            return;
        }
        let batch_size = count.min(8192);
        let mut buf = Vec::with_capacity(batch_size * 12);
        for i in 0..count {
            let val = lo + rng.gen_max(range_size - 1);
            buf.extend_from_slice(ibuf.format(val).as_bytes());
            buf.push(delimiter);
            if (i + 1) % batch_size == 0 {
                match checked_write_all(out, &buf) {
                    Ok(false) => return,
                    Err(err) => {
                        eprintln!("{}: write error: {}", TOOL_NAME, err);
                        process::exit(1);
                    }
                    _ => {}
                }
                buf.clear();
            }
        }
        if !buf.is_empty() {
            match checked_write_all(out, &buf) {
                Ok(false) => process::exit(0),
                Err(err) => {
                    eprintln!("{}: write error: {}", TOOL_NAME, err);
                    process::exit(1);
                }
                _ => {}
            }
        }
        return;
    }

    if range_size == 0 {
        return;
    }

    let count = head_count
        .unwrap_or(range_size as usize)
        .min(range_size as usize);
    if count == 0 {
        return;
    }

    // Sparse path: when count is small relative to range, pick random values directly
    // using a HashSet for deduplication. O(count) expected time and space.
    if (count as u64) < range_size / 10 || (count < 10000 && range_size > 1_000_000) {
        let mut picked = std::collections::HashSet::with_capacity(count);
        let mut result = Vec::with_capacity(count);
        while picked.len() < count {
            let val = lo + rng.gen_max(range_size - 1);
            if picked.insert(val) {
                result.push(val);
            }
        }
        let mut buf = Vec::with_capacity(count * 8);
        for val in result {
            buf.extend_from_slice(ibuf.format(val).as_bytes());
            buf.push(delimiter);
        }
        match checked_write_all(out, &buf) {
            Ok(false) => process::exit(0),
            Err(err) => {
                eprintln!("{}: write error: {}", TOOL_NAME, err);
                process::exit(1);
            }
            _ => {}
        }
    } else if hi <= u32::MAX as u64 {
        // Use u32 array when range fits — halves cache footprint for Fisher-Yates
        let lo32 = lo as u32;
        let mut values: Vec<u32> = (lo32..=(hi as u32)).collect();
        let n = values.len();
        for i in 0..count {
            let j = i + rng.gen_range(n - i);
            values.swap(i, j);
        }
        const OUT_CHUNK: usize = 1024 * 1024;
        let mut buf = Vec::with_capacity(OUT_CHUNK + 32);
        for &val in values.iter().take(count) {
            buf.extend_from_slice(ibuf.format(val).as_bytes());
            buf.push(delimiter);
            if buf.len() >= OUT_CHUNK {
                match checked_write_all(out, &buf) {
                    Ok(false) => return,
                    Err(err) => {
                        eprintln!("{}: write error: {}", TOOL_NAME, err);
                        process::exit(1);
                    }
                    _ => {}
                }
                buf.clear();
            }
        }
        if !buf.is_empty() {
            match checked_write_all(out, &buf) {
                Ok(false) => process::exit(0),
                Err(err) => {
                    eprintln!("{}: write error: {}", TOOL_NAME, err);
                    process::exit(1);
                }
                _ => {}
            }
        }
    } else {
        // Dense path: generate all values and partial Fisher-Yates shuffle.
        let mut values: Vec<u64> = (lo..=hi).collect();
        let n = values.len();
        for i in 0..count {
            let j = i + rng.gen_range(n - i);
            values.swap(i, j);
        }
        // Pre-allocate output buffer sized to hold all formatted output.
        // Average number width ~7 chars for 1M range, so estimate generously.
        let est_size = count * 9;
        let mut buf = Vec::with_capacity(est_size.min(4 * 1024 * 1024));
        const OUT_CHUNK: usize = 512 * 1024;
        for &val in values.iter().take(count) {
            buf.extend_from_slice(ibuf.format(val).as_bytes());
            buf.push(delimiter);
            if buf.len() >= OUT_CHUNK {
                match checked_write_all(out, &buf) {
                    Ok(false) => return,
                    Err(err) => {
                        eprintln!("{}: write error: {}", TOOL_NAME, err);
                        process::exit(1);
                    }
                    _ => {}
                }
                buf.clear();
            }
        }
        if !buf.is_empty() {
            match checked_write_all(out, &buf) {
                Ok(false) => process::exit(0),
                Err(err) => {
                    eprintln!("{}: write error: {}", TOOL_NAME, err);
                    process::exit(1);
                }
                _ => {}
            }
        }
    }
}

#[allow(clippy::too_many_arguments)]
fn run_file_shuffle(
    filename: Option<&str>,
    zero_terminated: bool,
    rng: &mut RandGen,
    out: &mut impl Write,
    delimiter: u8,
    head_count: Option<usize>,
    repeat: bool,
    is_stdout: bool,
) {
    let data = read_file_data(filename);
    let sep = if zero_terminated { 0u8 } else { b'\n' };

    // Build line index as (start, end) pairs using u32 for compactness.
    // At 8 bytes per entry (vs 16 for (usize, usize)), this halves cache footprint
    // for the Fisher-Yates shuffle where random access is the bottleneck.
    // end is delimiter-inclusive: data[start..end] includes the trailing delimiter,
    // enabling single-iovec output per line.
    let estimated_lines = data.len() / 40 + 64;
    let mut offsets: Vec<[u32; 2]> = Vec::with_capacity(estimated_lines);
    let mut start = 0usize;
    for pos in memchr::memchr_iter(sep, &data) {
        offsets.push([start as u32, (pos + 1) as u32]);
        start = pos + 1;
    }
    // Last line without trailing delimiter
    let last_needs_delim = start < data.len();
    if last_needs_delim {
        offsets.push([start as u32, data.len() as u32]);
    }

    if offsets.is_empty() && !repeat {
        return;
    }

    if repeat {
        let count = head_count.unwrap_or(usize::MAX);
        if count == 0 {
            return;
        }
        if offsets.is_empty() {
            eprintln!("{}: no lines to repeat", TOOL_NAME);
            process::exit(1);
        }
        let last_idx = offsets.len() - 1;
        const CHUNK: usize = 2 * 1024 * 1024;
        let mut buf: Vec<u8> = Vec::with_capacity(CHUNK + 256);
        let src = data.as_ptr();
        for _ in 0..count {
            let idx = rng.gen_range(offsets.len());
            let [s, e] = offsets[idx];
            let span = (e - s) as usize;
            // For delimiter-inclusive entries, span includes the delimiter.
            // For last line without delimiter, append it manually.
            // In the repeat path, offsets are never shuffled, so offsets[last_idx]
            // is always the unterminated last line entry. Equivalent to
            // `e as usize == data.len()` (see invariant in the non-repeat path),
            // but cheaper to check.
            let needs_extra = last_needs_delim && idx == last_idx;
            let needed = buf.len() + span + needs_extra as usize;
            if needed > CHUNK && !buf.is_empty() {
                match checked_write_all(out, &buf) {
                    Ok(false) => return,
                    Err(err) => {
                        eprintln!("{}: write error: {}", TOOL_NAME, err);
                        process::exit(1);
                    }
                    _ => {}
                }
                buf.clear();
            }
            let pos = buf.len();
            buf.reserve(span + needs_extra as usize);
            unsafe {
                let dst = buf.as_mut_ptr().add(pos);
                std::ptr::copy_nonoverlapping(src.add(s as usize), dst, span);
                if needs_extra {
                    *dst.add(span) = delimiter;
                    buf.set_len(pos + span + 1);
                } else {
                    buf.set_len(pos + span);
                }
            }
        }
        if !buf.is_empty() {
            match checked_write_all(out, &buf) {
                Ok(false) => process::exit(0),
                Err(err) => {
                    eprintln!("{}: write error: {}", TOOL_NAME, err);
                    process::exit(1);
                }
                _ => {}
            }
        }
    } else {
        let n = offsets.len();
        let count = head_count.unwrap_or(n).min(n);

        // Partial Fisher-Yates: only do `count` rounds instead of shuffling all N.
        // O(count) random swaps instead of O(N). Huge win for -n 100 from 200K lines.
        for i in 0..count {
            let j = i + rng.gen_range(n - i);
            offsets.swap(i, j);
        }

        #[cfg(unix)]
        {
            // Contiguous output buffer with raw write_all_fd.
            // Reduces syscalls from ~3900 writev to ~50 write for 100MB output.
            let out_fd: i32 = if is_stdout {
                let _ = out.flush();
                1
            } else {
                -1
            };

            if out_fd >= 0 {
                const BUF_SIZE: usize = 2 * 1024 * 1024;
                let mut buf: Vec<u8> = Vec::with_capacity(BUF_SIZE + 256);
                let src = data.as_ptr();
                let offsets_slice = &offsets[..count];
                const PREFETCH_DIST: usize = 16;

                for (idx, &[s, e]) in offsets_slice.iter().enumerate() {
                    if idx + PREFETCH_DIST < count {
                        let future_s = offsets_slice[idx + PREFETCH_DIST][0] as usize;
                        #[cfg(target_arch = "x86_64")]
                        unsafe {
                            std::arch::x86_64::_mm_prefetch(
                                src.add(future_s) as *const i8,
                                std::arch::x86_64::_MM_HINT_T1,
                            );
                        }
                    }

                    let span = (e - s) as usize;
                    // e == data.len() uniquely identifies the original unterminated last line.
                    // No delimiter-inclusive entry can satisfy this: they have e = start + len + 1
                    // where the +1 accounts for the delimiter byte, so e <= data.len() only if the
                    // last byte IS the delimiter — but then last_needs_delim is false, short-circuiting.
                    let needs_extra = last_needs_delim && e as usize == data.len();
                    let total = span + needs_extra as usize;

                    if buf.len() + total > BUF_SIZE && !buf.is_empty() {
                        match raw_write_all(out_fd, &buf) {
                            Ok(false) => return,
                            Err(err) => {
                                eprintln!("{}: write error: {}", TOOL_NAME, err);
                                process::exit(1);
                            }
                            _ => {}
                        }
                        buf.clear();
                    }
                    buf.reserve(total);
                    let pos = buf.len();
                    unsafe {
                        let dst = buf.as_mut_ptr().add(pos);
                        std::ptr::copy_nonoverlapping(src.add(s as usize), dst, span);
                        if needs_extra {
                            *dst.add(span) = delimiter;
                            buf.set_len(pos + span + 1);
                        } else {
                            buf.set_len(pos + span);
                        }
                    }
                }
                if !buf.is_empty() {
                    match raw_write_all(out_fd, &buf) {
                        Ok(false) => process::exit(0),
                        Err(err) => {
                            eprintln!("{}: write error: {}", TOOL_NAME, err);
                            process::exit(1);
                        }
                        _ => {}
                    }
                }
            } else {
                // Fallback: copy-based path for non-stdout output
                const CHUNK: usize = 2 * 1024 * 1024;
                let mut buf: Vec<u8> = Vec::with_capacity(CHUNK + 256);
                let src = data.as_ptr();
                let offsets_slice = &offsets[..count];
                const PREFETCH_DIST: usize = 16;

                for (idx, &[s, e]) in offsets_slice.iter().enumerate() {
                    if idx + PREFETCH_DIST < count {
                        let future_s = offsets_slice[idx + PREFETCH_DIST][0] as usize;
                        #[cfg(target_arch = "x86_64")]
                        unsafe {
                            std::arch::x86_64::_mm_prefetch(
                                src.add(future_s) as *const i8,
                                std::arch::x86_64::_MM_HINT_T1,
                            );
                        }
                    }
                    let span = (e - s) as usize;
                    // See invariant comment in unix-stdout path above: e == data.len()
                    // uniquely identifies the unterminated last line.
                    let needs_extra = last_needs_delim && e as usize == data.len();
                    let total = span + needs_extra as usize;
                    if buf.len() + total > CHUNK && !buf.is_empty() {
                        match checked_write_all(out, &buf) {
                            Ok(false) => return,
                            Err(err) => {
                                eprintln!("{}: write error: {}", TOOL_NAME, err);
                                process::exit(1);
                            }
                            _ => {}
                        }
                        buf.clear();
                    }
                    buf.reserve(total);
                    let pos = buf.len();
                    unsafe {
                        let dst = buf.as_mut_ptr().add(pos);
                        std::ptr::copy_nonoverlapping(src.add(s as usize), dst, span);
                        if needs_extra {
                            *dst.add(span) = delimiter;
                            buf.set_len(pos + span + 1);
                        } else {
                            buf.set_len(pos + span);
                        }
                    }
                }
                if !buf.is_empty() {
                    match checked_write_all(out, &buf) {
                        Ok(false) => process::exit(0),
                        Err(err) => {
                            eprintln!("{}: write error: {}", TOOL_NAME, err);
                            process::exit(1);
                        }
                        _ => {}
                    }
                }
            }
        }

        #[cfg(not(unix))]
        {
            const OUT_CHUNK: usize = 2 * 1024 * 1024;
            let mut buf = Vec::with_capacity(OUT_CHUNK + 256);
            for &[s, e] in offsets[..count].iter() {
                let span = (e - s) as usize;
                // See invariant comment in unix-stdout path above: e == data.len()
                // uniquely identifies the unterminated last line.
                let needs_extra = last_needs_delim && e as usize == data.len();
                let total = span + needs_extra as usize;
                if buf.len() + total > OUT_CHUNK && !buf.is_empty() {
                    match checked_write_all(out, &buf) {
                        Ok(false) => return,
                        Err(err) => {
                            eprintln!("{}: write error: {}", TOOL_NAME, err);
                            process::exit(1);
                        }
                        _ => {}
                    }
                    buf.clear();
                }
                buf.reserve(total);
                buf.extend_from_slice(&data[s as usize..e as usize]);
                if needs_extra {
                    buf.push(delimiter);
                }
            }
            if !buf.is_empty() {
                match checked_write_all(out, &buf) {
                    Ok(false) => process::exit(0),
                    Err(err) => {
                        eprintln!("{}: write error: {}", TOOL_NAME, err);
                        process::exit(1);
                    }
                    _ => {}
                }
            }
        }
    }
}

fn read_file_data(filename: Option<&str>) -> coreutils_rs::common::io::FileData {
    match filename {
        Some("-") | None => {
            let mut buf = Vec::new();
            io::stdin().lock().read_to_end(&mut buf).unwrap_or(0);
            coreutils_rs::common::io::FileData::Owned(buf)
        }
        Some(file) => match coreutils_rs::common::io::read_file(std::path::Path::new(file)) {
            Ok(data) => data,
            Err(e) => {
                eprintln!(
                    "{}: {}: {}",
                    TOOL_NAME,
                    file,
                    coreutils_rs::common::io_error_msg(&e)
                );
                process::exit(1);
            }
        },
    }
}

fn parse_range(s: &str) -> (u64, u64) {
    // Find the separator '-' that's not part of a negative number sign
    // Format: LO-HI where LO and HI are non-negative integers
    let sep_pos = if let Some(rest) = s.strip_prefix('-') {
        // First char is '-' (could be negative, which is invalid for u64 range)
        // Look for next '-' as separator
        match rest.find('-') {
            Some(p) => p + 1,
            None => {
                eprintln!("{}: invalid input range: \u{2018}{}\u{2019}", TOOL_NAME, s);
                process::exit(1);
            }
        }
    } else {
        match s.find('-') {
            Some(p) => p,
            None => {
                eprintln!("{}: invalid input range: \u{2018}{}\u{2019}", TOOL_NAME, s);
                process::exit(1);
            }
        }
    };

    let lo_str = &s[..sep_pos];
    let hi_str = &s[sep_pos + 1..];

    let lo: u64 = match lo_str.parse() {
        Ok(v) => v,
        Err(_) => {
            eprintln!("{}: invalid input range: \u{2018}{}\u{2019}", TOOL_NAME, s);
            process::exit(1);
        }
    };
    let hi: u64 = match hi_str.parse() {
        Ok(v) => v,
        Err(_) => {
            eprintln!("{}: invalid input range: \u{2018}{}\u{2019}", TOOL_NAME, s);
            process::exit(1);
        }
    };
    if lo > hi {
        eprintln!("{}: invalid input range: \u{2018}{}\u{2019}", TOOL_NAME, s);
        process::exit(1);
    }
    (lo, hi)
}

fn parse_count(s: &str) -> usize {
    match s.parse() {
        Ok(v) => v,
        Err(_) => {
            eprintln!("{}: invalid line count: '{}'", TOOL_NAME, s);
            process::exit(1);
        }
    }
}

#[cfg(test)]
mod tests {
    use std::collections::HashSet;
    use std::io::Write;
    use std::process::Command;

    fn cmd() -> Command {
        let mut path = std::env::current_exe().unwrap();
        path.pop();
        path.pop();
        path.push("fshuf");
        Command::new(path)
    }

    #[test]
    fn test_basic_shuffle() {
        let mut child = cmd()
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::piped())
            .spawn()
            .unwrap();
        {
            let stdin = child.stdin.as_mut().unwrap();
            stdin.write_all(b"a\nb\nc\nd\ne\n").unwrap();
        }
        let output = child.wait_with_output().unwrap();
        assert!(output.status.success());
        let stdout = String::from_utf8_lossy(&output.stdout);
        let lines: HashSet<&str> = stdout.trim().lines().collect();
        let expected: HashSet<&str> = ["a", "b", "c", "d", "e"].iter().copied().collect();
        assert_eq!(
            lines, expected,
            "All elements should be present after shuffle"
        );
    }

    #[test]
    fn test_echo_mode() {
        let output = cmd().args(["-e", "x", "y", "z"]).output().unwrap();
        assert!(output.status.success());
        let stdout = String::from_utf8_lossy(&output.stdout);
        let lines: HashSet<&str> = stdout.trim().lines().collect();
        let expected: HashSet<&str> = ["x", "y", "z"].iter().copied().collect();
        assert_eq!(lines, expected);
    }

    #[test]
    fn test_input_range() {
        let output = cmd().args(["-i", "1-5"]).output().unwrap();
        assert!(output.status.success());
        let stdout = String::from_utf8_lossy(&output.stdout);
        let mut lines: Vec<i32> = stdout.trim().lines().map(|l| l.parse().unwrap()).collect();
        lines.sort();
        assert_eq!(lines, vec![1, 2, 3, 4, 5]);
    }

    #[test]
    fn test_head_count() {
        let output = cmd().args(["-i", "1-100", "-n", "5"]).output().unwrap();
        assert!(output.status.success());
        let stdout = String::from_utf8_lossy(&output.stdout);
        let lines: Vec<&str> = stdout.trim().lines().collect();
        assert_eq!(lines.len(), 5);
    }

    #[test]
    fn test_repeat() {
        let output = cmd()
            .args(["-e", "-r", "-n", "10", "a", "b"])
            .output()
            .unwrap();
        assert!(output.status.success());
        let stdout = String::from_utf8_lossy(&output.stdout);
        let lines: Vec<&str> = stdout.trim().lines().collect();
        assert_eq!(lines.len(), 10);
        for line in &lines {
            assert!(
                *line == "a" || *line == "b",
                "Expected 'a' or 'b', got '{}'",
                line
            );
        }
    }

    #[test]
    fn test_zero_terminated() {
        let mut child = cmd()
            .args(["-z"])
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::piped())
            .spawn()
            .unwrap();
        {
            let stdin = child.stdin.as_mut().unwrap();
            stdin.write_all(b"a\0b\0c\0").unwrap();
        }
        let output = child.wait_with_output().unwrap();
        assert!(output.status.success());
        let stdout = &output.stdout;
        // Output should be NUL-terminated
        let items: HashSet<&[u8]> = stdout
            .split(|&b| b == 0)
            .filter(|s| !s.is_empty())
            .collect();
        assert_eq!(items.len(), 3);
        assert!(items.contains(&b"a"[..]));
        assert!(items.contains(&b"b"[..]));
        assert!(items.contains(&b"c"[..]));
    }

    #[test]
    fn test_output_file() {
        let dir = tempfile::tempdir().unwrap();
        let outpath = dir.path().join("output.txt");
        let output = cmd()
            .args(["-e", "hello", "world", "-o", outpath.to_str().unwrap()])
            .output()
            .unwrap();
        assert!(output.status.success());
        let contents = std::fs::read_to_string(&outpath).unwrap();
        let lines: HashSet<&str> = contents.trim().lines().collect();
        assert!(lines.contains("hello"));
        assert!(lines.contains("world"));
    }
    #[test]
    fn test_match_gnu_format() {
        // GNU shuf -i 1-5 output should have exactly 5 lines, each a number 1-5
        let gnu = Command::new("shuf").args(["-i", "1-5"]).output();
        if let Ok(gnu) = gnu {
            // Both should produce 5 lines with numbers 1-5
            let gnu_lines: Vec<i32> = String::from_utf8_lossy(&gnu.stdout)
                .trim()
                .lines()
                .map(|l| l.parse().unwrap())
                .collect();
            assert_eq!(gnu_lines.len(), 5);

            let ours = cmd().args(["-i", "1-5"]).output().unwrap();
            let our_lines: Vec<i32> = String::from_utf8_lossy(&ours.stdout)
                .trim()
                .lines()
                .map(|l| l.parse().unwrap())
                .collect();
            assert_eq!(our_lines.len(), 5);

            let mut gnu_sorted = gnu_lines;
            gnu_sorted.sort();
            let mut our_sorted = our_lines;
            our_sorted.sort();
            assert_eq!(gnu_sorted, our_sorted, "Same set of numbers");
        }
    }

    // --- GNU compatibility: option conflict validation ---

    #[test]
    fn test_i_and_e_conflict() {
        let output = cmd().args(["-e", "-i", "0-9", "a"]).output().unwrap();
        assert!(!output.status.success(), "-i and -e together should error");
        let stderr = String::from_utf8_lossy(&output.stderr);
        assert!(
            stderr.contains("cannot combine -e and -i"),
            "stderr: {}",
            stderr
        );
    }

    #[test]
    fn test_multiple_i_is_error() {
        let output = cmd().args(["-i", "0-1", "-i", "0-2"]).output().unwrap();
        assert!(!output.status.success(), "multiple -i should error");
        let stderr = String::from_utf8_lossy(&output.stderr);
        assert!(stderr.contains("multiple -i"), "stderr: {}", stderr);
    }

    #[test]
    fn test_i_with_extra_operand() {
        let output = cmd().args(["-i", "0-0", "foo"]).output().unwrap();
        assert!(
            !output.status.success(),
            "-i with extra operand should error"
        );
        let stderr = String::from_utf8_lossy(&output.stderr);
        assert!(stderr.contains("extra operand"), "stderr: {}", stderr);
    }

    #[test]
    fn test_multiple_o_is_error() {
        // GNU shuf rejects multiple -o (exit 1)
        let dir = tempfile::tempdir().unwrap();
        let p1 = dir.path().join("fshuf_multi_o_1.txt");
        let p2 = dir.path().join("fshuf_multi_o_2.txt");
        let output = cmd()
            .args([
                "-i",
                "0-0",
                "-o",
                p1.to_str().unwrap(),
                "-o",
                p2.to_str().unwrap(),
            ])
            .output()
            .unwrap();
        assert!(!output.status.success(), "multiple -o should error");
        let stderr = String::from_utf8_lossy(&output.stderr);
        assert!(
            stderr.contains("multiple output files"),
            "stderr: {}",
            stderr
        );
    }

    #[test]
    fn test_multiple_n_uses_smallest() {
        // GNU shuf uses the smallest -n value when multiple are specified
        let output = cmd()
            .args(["-n", "10", "-i", "0-9", "-n", "3", "-n", "20"])
            .output()
            .unwrap();
        assert!(output.status.success());
        let stdout = String::from_utf8_lossy(&output.stdout);
        let lines: Vec<&str> = stdout.trim().lines().collect();
        assert_eq!(lines.len(), 3, "multiple -n should use smallest value");
    }

    // --- GNU compatibility: --repeat feature ---

    #[test]
    fn test_repeat_input_range_count() {
        let output = cmd()
            .args(["--repeat", "-i", "0-9", "-n", "1000"])
            .output()
            .unwrap();
        assert!(output.status.success());
        let stdout = String::from_utf8_lossy(&output.stdout);
        let lines: Vec<&str> = stdout.trim().lines().collect();
        assert_eq!(lines.len(), 1000, "should output exactly 1000 lines");
        for line in &lines {
            let num: u64 = line.parse().expect("each line should be a number");
            assert!(num <= 9, "number {} out of range 0-9", num);
        }
    }

    #[test]
    fn test_repeat_stdin_n0_empty() {
        let mut child = cmd()
            .args(["--repeat", "-n", "0"])
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::piped())
            .spawn()
            .unwrap();
        {
            let stdin = child.stdin.as_mut().unwrap();
            stdin.write_all(b"a\nb\n").unwrap();
        }
        let output = child.wait_with_output().unwrap();
        assert!(output.status.success());
        assert!(
            output.stdout.is_empty(),
            "--repeat -n0 should produce no output"
        );
    }

    #[test]
    fn test_repeat_input_range_222_233() {
        let output = cmd()
            .args(["--repeat", "-i", "222-233", "-n", "2000"])
            .output()
            .unwrap();
        assert!(output.status.success());
        let stdout = String::from_utf8_lossy(&output.stdout);
        let lines: Vec<&str> = stdout.trim().lines().collect();
        assert_eq!(lines.len(), 2000);
        for line in &lines {
            let num: u64 = line.parse().expect("each line should be a number");
            assert!(
                (222..=233).contains(&num),
                "number {} out of range 222-233",
                num
            );
        }
    }

    #[test]
    fn test_repeat_stdin_count() {
        let mut child = cmd()
            .args(["--repeat", "-n", "2000"])
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::piped())
            .spawn()
            .unwrap();
        {
            let stdin = child.stdin.as_mut().unwrap();
            stdin.write_all(b"a\nb\nc\n").unwrap();
        }
        let output = child.wait_with_output().unwrap();
        assert!(output.status.success());
        let stdout = String::from_utf8_lossy(&output.stdout);
        let lines: Vec<&str> = stdout.trim().lines().collect();
        assert_eq!(lines.len(), 2000);
        for line in &lines {
            assert!(
                *line == "a" || *line == "b" || *line == "c",
                "unexpected line: {}",
                line
            );
        }
    }

    #[test]
    fn test_input_range_single() {
        let output = cmd().args(["-i", "5-5"]).output().unwrap();
        assert!(output.status.success());
        let stdout = String::from_utf8_lossy(&output.stdout);
        assert_eq!(stdout.trim(), "5");
    }

    #[test]
    fn test_head_count_zero() {
        let output = cmd().args(["-i", "1-10", "-n", "0"]).output().unwrap();
        assert!(output.status.success());
        let stdout = String::from_utf8_lossy(&output.stdout);
        assert_eq!(stdout, "");
    }
}
