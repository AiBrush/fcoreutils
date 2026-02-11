use std::io::{self, BufRead, BufReader, BufWriter, Read, Write};

/// How to delimit groups when using --all-repeated
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AllRepeatedMethod {
    None,
    Prepend,
    Separate,
}

/// How to delimit groups when using --group
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum GroupMethod {
    Separate,
    Prepend,
    Append,
    Both,
}

/// Output mode for uniq
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum OutputMode {
    /// Default: print unique lines and first of each duplicate group
    Default,
    /// -d: print only first line of duplicate groups
    RepeatedOnly,
    /// -D / --all-repeated: print ALL duplicate lines
    AllRepeated(AllRepeatedMethod),
    /// -u: print only lines that are NOT duplicated
    UniqueOnly,
    /// --group: show all items with group separators
    Group(GroupMethod),
}

/// Configuration for uniq processing
#[derive(Debug, Clone)]
pub struct UniqConfig {
    pub mode: OutputMode,
    pub count: bool,
    pub ignore_case: bool,
    pub skip_fields: usize,
    pub skip_chars: usize,
    pub check_chars: Option<usize>,
    pub zero_terminated: bool,
}

impl Default for UniqConfig {
    fn default() -> Self {
        Self {
            mode: OutputMode::Default,
            count: false,
            ignore_case: false,
            skip_fields: 0,
            skip_chars: 0,
            check_chars: None,
            zero_terminated: false,
        }
    }
}

/// Extract the comparison key from a line according to skip_fields, skip_chars, check_chars.
/// Matches GNU uniq field-skip semantics exactly: for each field, skip blanks then non-blanks.
#[inline]
fn get_compare_slice<'a>(line: &'a [u8], config: &UniqConfig) -> &'a [u8] {
    let mut start = 0;
    let len = line.len();

    // Skip N fields (GNU: each field = run of blanks + run of non-blanks)
    for _ in 0..config.skip_fields {
        // Skip blanks (space and tab)
        while start < len && (line[start] == b' ' || line[start] == b'\t') {
            start += 1;
        }
        // Skip non-blanks (field content)
        while start < len && line[start] != b' ' && line[start] != b'\t' {
            start += 1;
        }
    }

    // Skip N characters
    if config.skip_chars > 0 {
        let skip = config.skip_chars.min(len - start);
        start += skip;
    }

    let slice = &line[start..];

    // Limit comparison to N characters
    if let Some(w) = config.check_chars {
        if w < slice.len() {
            return &slice[..w];
        }
    }

    slice
}

/// Strip the line terminator from the end of a line buffer.
#[inline]
fn strip_terminator(line: &[u8], zero_terminated: bool) -> &[u8] {
    let term = if zero_terminated { b'\0' } else { b'\n' };
    if line.last() == Some(&term) {
        &line[..line.len() - 1]
    } else {
        line
    }
}

/// Compare two lines after stripping terminators.
#[inline]
fn compare_lines(a: &[u8], b: &[u8], config: &UniqConfig) -> bool {
    let a_stripped = strip_terminator(a, config.zero_terminated);
    let b_stripped = strip_terminator(b, config.zero_terminated);

    let sa = get_compare_slice(a_stripped, config);
    let sb = get_compare_slice(b_stripped, config);

    if config.ignore_case {
        sa.eq_ignore_ascii_case(sb)
    } else {
        sa == sb
    }
}

/// Write a count-prefixed line in GNU uniq format.
/// GNU format: 7 spaces for count, right-aligned, followed by space and line.
#[inline]
fn write_count_line(out: &mut impl Write, count: u64, line: &[u8]) -> io::Result<()> {
    // GNU uniq uses "%7lu " format for count prefix
    write!(out, "{:>7} ", count)?;
    out.write_all(line)?;
    Ok(())
}

/// Write line with terminator if needed.
#[inline]
fn write_line(out: &mut impl Write, line: &[u8]) -> io::Result<()> {
    out.write_all(line)?;
    Ok(())
}

/// Write a line separator (empty line).
#[inline]
fn write_separator(out: &mut impl Write, zero_terminated: bool) -> io::Result<()> {
    if zero_terminated {
        out.write_all(b"\0")?;
    } else {
        out.write_all(b"\n")?;
    }
    Ok(())
}

/// Ensure line ends with proper terminator.
#[inline]
fn ensure_terminator(line: &[u8], zero_terminated: bool) -> bool {
    let term = if zero_terminated { b'\0' } else { b'\n' };
    line.last() == Some(&term)
}

/// Main streaming uniq processor.
/// Reads from `input`, writes to `output`.
pub fn process_uniq<R: Read, W: Write>(
    input: R,
    output: W,
    config: &UniqConfig,
) -> io::Result<()> {
    let reader = BufReader::with_capacity(256 * 1024, input);
    let mut writer = BufWriter::with_capacity(256 * 1024, output);
    let term = if config.zero_terminated { b'\0' } else { b'\n' };

    match config.mode {
        OutputMode::Group(method) => {
            process_group(reader, &mut writer, config, method, term)?;
        }
        OutputMode::AllRepeated(method) => {
            process_all_repeated(reader, &mut writer, config, method, term)?;
        }
        _ => {
            process_standard(reader, &mut writer, config, term)?;
        }
    }

    writer.flush()?;
    Ok(())
}

/// Standard processing for Default, RepeatedOnly, UniqueOnly modes.
fn process_standard<R: BufRead, W: Write>(
    mut reader: R,
    writer: &mut W,
    config: &UniqConfig,
    term: u8,
) -> io::Result<()> {
    let mut prev_line: Vec<u8> = Vec::with_capacity(4096);
    let mut current_line: Vec<u8> = Vec::with_capacity(4096);
    // Read first line
    prev_line.clear();
    if read_line_term(&mut reader, &mut prev_line, term)? == 0 {
        return Ok(()); // empty input
    }
    let mut count: u64 = 1;

    loop {
        current_line.clear();
        let bytes_read = read_line_term(&mut reader, &mut current_line, term)?;

        if bytes_read == 0 {
            // End of input - output the last group
            output_group(writer, &prev_line, count, config)?;
            break;
        }

        if compare_lines(&prev_line, &current_line, config) {
            count += 1;
        } else {
            // Lines differ - output previous group
            output_group(writer, &prev_line, count, config)?;
            std::mem::swap(&mut prev_line, &mut current_line);
            count = 1;
        }
    }

    Ok(())
}

/// Output a group based on mode (Default/RepeatedOnly/UniqueOnly).
#[inline]
fn output_group(
    writer: &mut impl Write,
    line: &[u8],
    count: u64,
    config: &UniqConfig,
) -> io::Result<()> {
    let should_print = match config.mode {
        OutputMode::Default => true,
        OutputMode::RepeatedOnly => count > 1,
        OutputMode::UniqueOnly => count == 1,
        _ => true,
    };

    if should_print {
        if config.count {
            write_count_line(writer, count, line)?;
            if !ensure_terminator(line, config.zero_terminated) {
                write_separator(writer, config.zero_terminated)?;
            }
        } else {
            write_line(writer, line)?;
            if !ensure_terminator(line, config.zero_terminated) {
                write_separator(writer, config.zero_terminated)?;
            }
        }
    }

    Ok(())
}

/// Process --all-repeated / -D mode.
fn process_all_repeated<R: BufRead, W: Write>(
    mut reader: R,
    writer: &mut W,
    config: &UniqConfig,
    method: AllRepeatedMethod,
    term: u8,
) -> io::Result<()> {
    // We need to buffer the current group to know if it's a duplicate group
    let mut group: Vec<Vec<u8>> = Vec::new();
    let mut current_line: Vec<u8> = Vec::with_capacity(4096);
    let mut first_group = true;

    // Read first line
    current_line.clear();
    if read_line_term(&mut reader, &mut current_line, term)? == 0 {
        return Ok(());
    }
    group.push(current_line.clone());

    loop {
        current_line.clear();
        let bytes_read = read_line_term(&mut reader, &mut current_line, term)?;

        if bytes_read == 0 {
            // End of input - flush last group
            flush_all_repeated_group(writer, &group, method, &mut first_group, config)?;
            break;
        }

        if compare_lines(group.last().unwrap(), &current_line, config) {
            group.push(current_line.clone());
        } else {
            flush_all_repeated_group(writer, &group, method, &mut first_group, config)?;
            group.clear();
            group.push(current_line.clone());
        }
    }

    Ok(())
}

/// Flush a group for --all-repeated mode.
fn flush_all_repeated_group(
    writer: &mut impl Write,
    group: &[Vec<u8>],
    method: AllRepeatedMethod,
    first_group: &mut bool,
    config: &UniqConfig,
) -> io::Result<()> {
    if group.len() <= 1 {
        return Ok(()); // Not a duplicate group
    }

    match method {
        AllRepeatedMethod::Prepend => {
            write_separator(writer, config.zero_terminated)?;
        }
        AllRepeatedMethod::Separate => {
            if !*first_group {
                write_separator(writer, config.zero_terminated)?;
            }
        }
        AllRepeatedMethod::None => {}
    }

    for line in group {
        write_line(writer, line)?;
        if !ensure_terminator(line, config.zero_terminated) {
            write_separator(writer, config.zero_terminated)?;
        }
    }

    *first_group = false;
    Ok(())
}

/// Process --group mode.
fn process_group<R: BufRead, W: Write>(
    mut reader: R,
    writer: &mut W,
    config: &UniqConfig,
    method: GroupMethod,
    term: u8,
) -> io::Result<()> {
    let mut prev_line: Vec<u8> = Vec::with_capacity(4096);
    let mut current_line: Vec<u8> = Vec::with_capacity(4096);
    // Read first line
    prev_line.clear();
    if read_line_term(&mut reader, &mut prev_line, term)? == 0 {
        return Ok(());
    }

    // Prepend/Both: separator before first group
    if matches!(method, GroupMethod::Prepend | GroupMethod::Both) {
        write_separator(writer, config.zero_terminated)?;
    }

    write_line(writer, &prev_line)?;
    if !ensure_terminator(&prev_line, config.zero_terminated) {
        write_separator(writer, config.zero_terminated)?;
    }
    let mut first_group = false;

    loop {
        current_line.clear();
        let bytes_read = read_line_term(&mut reader, &mut current_line, term)?;

        if bytes_read == 0 {
            // End of input
            if matches!(method, GroupMethod::Append | GroupMethod::Both) {
                write_separator(writer, config.zero_terminated)?;
            }
            break;
        }

        if !compare_lines(&prev_line, &current_line, config) {
            // New group - separator between groups
            if !first_group {
                write_separator(writer, config.zero_terminated)?;
            }
        }

        write_line(writer, &current_line)?;
        if !ensure_terminator(&current_line, config.zero_terminated) {
            write_separator(writer, config.zero_terminated)?;
        }

        std::mem::swap(&mut prev_line, &mut current_line);
    }

    Ok(())
}

/// Read a line terminated by the given byte (newline or NUL).
/// Returns number of bytes read (0 = EOF).
#[inline]
fn read_line_term<R: BufRead>(reader: &mut R, buf: &mut Vec<u8>, term: u8) -> io::Result<usize> {
    if term == b'\n' {
        reader.read_until(b'\n', buf)
    } else {
        reader.read_until(b'\0', buf)
    }
}
