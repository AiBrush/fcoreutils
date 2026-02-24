use std::io::Write;

/// Tab stop specification
#[derive(Clone, Debug)]
pub enum TabStops {
    /// Regular interval (default 8)
    Regular(usize),
    /// Explicit list of tab stop positions (0-indexed columns)
    List(Vec<usize>),
}

impl TabStops {
    /// Calculate the number of spaces to the next tab stop from the given column.
    #[inline]
    fn spaces_to_next(&self, column: usize) -> usize {
        match self {
            TabStops::Regular(n) => {
                if *n == 0 {
                    return 0;
                }
                *n - (column % *n)
            }
            TabStops::List(stops) => {
                // Find the first tab stop > current column
                match stops.binary_search(&(column + 1)) {
                    Ok(idx) => stops[idx] - column,
                    Err(idx) => {
                        if idx < stops.len() {
                            stops[idx] - column
                        } else {
                            // Past all tab stops: GNU uses 1 space
                            1
                        }
                    }
                }
            }
        }
    }

    /// Get the next tab stop position after the given column.
    #[inline]
    fn next_tab_stop(&self, column: usize) -> usize {
        column + self.spaces_to_next(column)
    }
}

/// Parse a tab specification string (e.g., "4", "4,8,12", "4 8 12").
pub fn parse_tab_stops(spec: &str) -> Result<TabStops, String> {
    let spec = spec.trim();
    if spec.is_empty() {
        return Ok(TabStops::Regular(8));
    }

    // Check if it's a single number (regular interval)
    if let Ok(n) = spec.parse::<usize>() {
        if n == 0 {
            return Err("tab size cannot be 0".to_string());
        }
        return Ok(TabStops::Regular(n));
    }

    // Parse as comma or space-separated list
    let mut stops: Vec<usize> = Vec::new();
    for part in spec.split([',', ' ']) {
        let part = part.trim();
        if part.is_empty() {
            continue;
        }
        // Handle / prefix for repeating tab stops
        if let Some(rest) = part.strip_prefix('/') {
            let n: usize = rest
                .parse()
                .map_err(|_| format!("'{}' is not a valid number", part))?;
            if n == 0 {
                return Err("tab size cannot be 0".to_string());
            }
            let last = stops.last().copied().unwrap_or(0);
            let mut pos = last + n;
            while pos < 10000 {
                stops.push(pos);
                pos += n;
            }
            continue;
        }
        match part.parse::<usize>() {
            Ok(n) => {
                if !stops.is_empty() && n <= *stops.last().unwrap() {
                    return Err("tab sizes must be ascending".to_string());
                }
                stops.push(n);
            }
            Err(_) => return Err(format!("'{}' is not a valid number", part)),
        }
    }

    if stops.is_empty() {
        return Err("tab specification is empty".to_string());
    }

    if stops.len() == 1 {
        return Ok(TabStops::Regular(stops[0]));
    }

    Ok(TabStops::List(stops))
}

// Pre-computed spaces buffer for fast tab expansion (avoids per-tab allocation)
// Larger buffer (256 bytes) means most tabs can be served in a single memcpy
const SPACES: [u8; 256] = [b' '; 256];

/// Write N spaces to a Vec efficiently using pre-computed buffer.
#[inline]
fn push_spaces(output: &mut Vec<u8>, n: usize) {
    let mut remaining = n;
    while remaining > 0 {
        let chunk = remaining.min(SPACES.len());
        output.extend_from_slice(&SPACES[..chunk]);
        remaining -= chunk;
    }
}

/// Write N spaces to a Write stream using pre-computed buffer.
#[inline]
fn write_spaces(out: &mut impl Write, n: usize) -> std::io::Result<()> {
    let mut remaining = n;
    while remaining > 0 {
        let chunk = remaining.min(SPACES.len());
        out.write_all(&SPACES[..chunk])?;
        remaining -= chunk;
    }
    Ok(())
}

/// Expand tabs to spaces using SIMD scanning.
/// Uses memchr2 to find tabs and newlines, bulk-copying everything between them.
pub fn expand_bytes(
    data: &[u8],
    tabs: &TabStops,
    initial_only: bool,
    out: &mut impl Write,
) -> std::io::Result<()> {
    if data.is_empty() {
        return Ok(());
    }

    // Fast path: no tabs in data → just copy through
    if memchr::memchr(b'\t', data).is_none() {
        return out.write_all(data);
    }

    // For regular tab stops, use fast SIMD paths
    if let TabStops::Regular(tab_size) = tabs {
        if initial_only {
            // --initial mode processes line-by-line anyway, so handle backspace
            // per-line instead of scanning the whole buffer.
            return expand_initial_fast(data, *tab_size, out);
        } else if memchr::memchr(b'\x08', data).is_none() {
            return expand_regular_fast(data, *tab_size, out);
        }
    }

    // Generic path for backspace handling or tab lists
    expand_generic(data, tabs, initial_only, out)
}

/// Fast expand for regular tab stops without -i flag.
/// Writes directly from source data for non-tab runs, avoiding intermediate buffer copies.
fn expand_regular_fast(data: &[u8], tab_size: usize, out: &mut impl Write) -> std::io::Result<()> {
    debug_assert!(tab_size > 0, "tab_size must be > 0");
    let mut column: usize = 0;
    let mut pos: usize = 0;

    while pos < data.len() {
        match memchr::memchr2(b'\t', b'\n', &data[pos..]) {
            Some(offset) => {
                // Write non-special bytes directly from source (zero-copy)
                if offset > 0 {
                    out.write_all(&data[pos..pos + offset])?;
                    column += offset;
                }
                let byte = data[pos + offset];
                pos += offset + 1;

                if byte == b'\n' {
                    out.write_all(b"\n")?;
                    column = 0;
                } else {
                    // Tab: write spaces
                    let spaces = tab_size - (column % tab_size);
                    write_spaces(out, spaces)?;
                    column += spaces;
                }
            }
            None => {
                out.write_all(&data[pos..])?;
                break;
            }
        }
    }

    Ok(())
}

/// Fast expand for --initial mode with regular tab stops.
/// Only expands tabs in the leading whitespace of each line, bulk-copying the rest.
/// Uses memchr (SIMD) to find line boundaries. Leading-whitespace expansion is scalar.
/// Handles backspace per-line: lines containing \x08 fall back to generic expand.
fn expand_initial_fast(data: &[u8], tab_size: usize, out: &mut impl Write) -> std::io::Result<()> {
    debug_assert!(tab_size > 0, "tab_size must be > 0");
    let tabs = TabStops::Regular(tab_size);
    let mut pos: usize = 0;

    while pos < data.len() {
        // Find end of this line
        let line_end = memchr::memchr(b'\n', &data[pos..])
            .map(|off| pos + off + 1)
            .unwrap_or(data.len());

        let line = &data[pos..line_end];
        debug_assert!(!line.is_empty());

        // Fast skip: if line doesn't start with tab or space, write it whole
        let first = line[0];
        if first != b'\t' && first != b' ' {
            out.write_all(line)?;
            pos = line_end;
            continue;
        }

        // If this line contains a backspace, fall back to generic for this line only
        if memchr::memchr(b'\x08', line).is_some() {
            expand_generic(line, &tabs, true, out)?;
            pos = line_end;
            continue;
        }

        // Expand only leading tabs/spaces in this line
        let mut column: usize = 0;
        let mut i = 0; // offset within line
        while i < line.len() {
            let byte = line[i];
            if byte == b'\t' {
                let spaces = tab_size - (column % tab_size);
                write_spaces(out, spaces)?;
                column += spaces;
                i += 1;
            } else if byte == b' ' {
                // Batch consecutive spaces from source data
                let space_start = i;
                while i < line.len() && line[i] == b' ' {
                    i += 1;
                }
                out.write_all(&line[space_start..i])?;
                column += i - space_start;
            } else {
                // First non-blank: write the rest of the line unchanged
                break;
            }
        }

        // Write remainder of line as-is (zero-copy)
        if i < line.len() {
            out.write_all(&line[i..])?;
        }

        pos = line_end;
    }

    Ok(())
}

/// Generic expand with support for -i flag and tab lists.
fn expand_generic(
    data: &[u8],
    tabs: &TabStops,
    initial_only: bool,
    out: &mut impl Write,
) -> std::io::Result<()> {
    let mut output = Vec::with_capacity(data.len() + data.len() / 8);
    let mut column: usize = 0;
    let mut in_initial = true;

    for &byte in data {
        match byte {
            b'\t' => {
                if initial_only && !in_initial {
                    output.push(b'\t');
                    column = tabs.next_tab_stop(column);
                } else {
                    let spaces = tabs.spaces_to_next(column);
                    push_spaces(&mut output, spaces);
                    column += spaces;
                }
            }
            b'\n' => {
                output.push(b'\n');
                column = 0;
                in_initial = true;
            }
            b'\x08' => {
                output.push(b'\x08');
                if column > 0 {
                    column -= 1;
                }
            }
            _ => {
                if initial_only && in_initial && byte != b' ' {
                    in_initial = false;
                }
                output.push(byte);
                column += 1;
            }
        }
    }

    out.write_all(&output)
}

/// Unexpand spaces to tabs.
/// If `all` is true, convert all sequences of spaces; otherwise only leading spaces.
pub fn unexpand_bytes(
    data: &[u8],
    tabs: &TabStops,
    all: bool,
    out: &mut impl Write,
) -> std::io::Result<()> {
    if data.is_empty() {
        return Ok(());
    }

    // Fast path: no spaces or tabs → just copy through
    if memchr::memchr2(b' ', b'\t', data).is_none() {
        return out.write_all(data);
    }

    // For regular tab stops, use the optimized SIMD-scanning path
    if let TabStops::Regular(tab_size) = tabs {
        if memchr::memchr(b'\x08', data).is_none() {
            return unexpand_regular_fast(data, *tab_size, all, out);
        }
    }

    // Generic path for tab lists or data with backspaces
    unexpand_generic(data, tabs, all, out)
}

/// Emit a run of blanks as the optimal combination of tabs and spaces.
/// Matches GNU unexpand behavior: a single blank at a tab stop is only converted
/// to a tab if more blanks follow, otherwise it stays as a space.
#[inline]
fn emit_blanks(
    out: &mut impl Write,
    start_col: usize,
    count: usize,
    tab_size: usize,
) -> std::io::Result<()> {
    if count == 0 {
        return Ok(());
    }
    let end_col = start_col + count;
    let mut col = start_col;

    // Emit tabs for each tab stop we can reach
    loop {
        let next_tab = col + (tab_size - col % tab_size);
        if next_tab > end_col {
            break;
        }
        let blanks_consumed = next_tab - col;
        if blanks_consumed >= 2 || next_tab < end_col {
            // 2+ blanks to tab stop, OR 1 blank but more follow → emit tab
            out.write_all(b"\t")?;
            col = next_tab;
        } else {
            // 1 blank at tab stop with nothing after → keep as space
            break;
        }
    }

    // Emit remaining spaces
    let remaining = end_col - col;
    if remaining > 0 {
        let mut r = remaining;
        while r > 0 {
            let chunk = r.min(SPACES.len());
            out.write_all(&SPACES[..chunk])?;
            r -= chunk;
        }
    }
    Ok(())
}

/// Fast unexpand for regular tab stops without backspaces.
/// Uses memchr SIMD scanning to skip non-special bytes in bulk.
fn unexpand_regular_fast(
    data: &[u8],
    tab_size: usize,
    all: bool,
    out: &mut impl Write,
) -> std::io::Result<()> {
    let mut column: usize = 0;
    let mut pos: usize = 0;
    let mut in_initial = true;

    while pos < data.len() {
        if in_initial || all {
            // Check for blanks to convert
            if data[pos] == b' ' || data[pos] == b'\t' {
                // Count consecutive blanks, tracking column advancement
                let blank_start_col = column;
                while pos < data.len() && (data[pos] == b' ' || data[pos] == b'\t') {
                    if data[pos] == b'\t' {
                        column += tab_size - column % tab_size;
                    } else {
                        column += 1;
                    }
                    pos += 1;
                }
                // Emit blanks as optimal tabs+spaces
                emit_blanks(out, blank_start_col, column - blank_start_col, tab_size)?;
                continue;
            }
            if data[pos] == b'\n' {
                out.write_all(b"\n")?;
                column = 0;
                in_initial = true;
                pos += 1;
                continue;
            }
            // Non-blank: switch to body mode
            in_initial = false;
        }

        // Body of line: bulk copy until next interesting byte
        if !all {
            // Default mode: copy everything until newline
            match memchr::memchr(b'\n', &data[pos..]) {
                Some(offset) => {
                    out.write_all(&data[pos..pos + offset + 1])?;
                    column = 0;
                    in_initial = true;
                    pos += offset + 1;
                }
                None => {
                    out.write_all(&data[pos..])?;
                    return Ok(());
                }
            }
        } else {
            // all=true: copy until next space, tab, or newline
            match memchr::memchr3(b' ', b'\t', b'\n', &data[pos..]) {
                Some(offset) => {
                    if offset > 0 {
                        out.write_all(&data[pos..pos + offset])?;
                        column += offset;
                    }
                    pos += offset;
                }
                None => {
                    out.write_all(&data[pos..])?;
                    return Ok(());
                }
            }
        }
    }

    Ok(())
}

/// Generic unexpand with support for tab lists and backspaces.
fn unexpand_generic(
    data: &[u8],
    tabs: &TabStops,
    all: bool,
    out: &mut impl Write,
) -> std::io::Result<()> {
    let tab_size = match tabs {
        TabStops::Regular(n) => *n,
        TabStops::List(_) => 0, // handled by is_tab_stop/next_tab_stop
    };
    let mut column: usize = 0;
    let mut space_start_col: Option<usize> = None;
    let mut in_initial = true;

    for &byte in data {
        match byte {
            b' ' => {
                if !all && !in_initial {
                    out.write_all(b" ")?;
                    column += 1;
                } else {
                    if space_start_col.is_none() {
                        space_start_col = Some(column);
                    }
                    column += 1;
                    // Don't convert to tab here — wait for end of blank run
                }
            }
            b'\t' => {
                if !all && !in_initial {
                    // In non-converting mode, just emit the tab
                    if let Some(start_col) = space_start_col.take() {
                        let n = column - start_col;
                        out.write_all(&SPACES[..n.min(SPACES.len())])?;
                    }
                    out.write_all(b"\t")?;
                    column = tabs.next_tab_stop(column);
                } else {
                    if space_start_col.is_none() {
                        space_start_col = Some(column);
                    }
                    column = tabs.next_tab_stop(column);
                }
            }
            _ => {
                // Flush pending blanks
                if let Some(start_col) = space_start_col.take() {
                    let count = column - start_col;
                    if tab_size > 0 {
                        emit_blanks(out, start_col, count, tab_size)?;
                    } else {
                        // Tab list: use is_tab_stop for conversion
                        emit_blanks_tablist(out, start_col, count, tabs)?;
                    }
                }

                if byte == b'\n' {
                    out.write_all(b"\n")?;
                    column = 0;
                    in_initial = true;
                } else if byte == b'\x08' {
                    out.write_all(b"\x08")?;
                    if column > 0 {
                        column -= 1;
                    }
                } else {
                    if in_initial {
                        in_initial = false;
                    }
                    out.write_all(&[byte])?;
                    column += 1;
                }
            }
        }
    }

    if let Some(start_col) = space_start_col {
        let count = column - start_col;
        if tab_size > 0 {
            emit_blanks(out, start_col, count, tab_size)?;
        } else {
            emit_blanks_tablist(out, start_col, count, tabs)?;
        }
    }

    Ok(())
}

/// Emit blanks using a tab list (non-regular tab stops).
/// After the last defined tab stop, only spaces are emitted (no more tabs).
fn emit_blanks_tablist(
    out: &mut impl Write,
    start_col: usize,
    count: usize,
    tabs: &TabStops,
) -> std::io::Result<()> {
    if count == 0 {
        return Ok(());
    }
    let end_col = start_col + count;
    let mut col = start_col;

    // Get the last defined tab stop to know when to stop converting to tabs
    let last_stop = match tabs {
        TabStops::List(stops) => stops.last().copied().unwrap_or(0),
        TabStops::Regular(_) => usize::MAX,
    };

    while col < last_stop {
        let next_tab = tabs.next_tab_stop(col);
        if next_tab > end_col || next_tab > last_stop {
            break;
        }
        let blanks_consumed = next_tab - col;
        if blanks_consumed >= 2 || next_tab < end_col {
            out.write_all(b"\t")?;
            col = next_tab;
        } else {
            break;
        }
    }

    let remaining = end_col - col;
    if remaining > 0 {
        let mut r = remaining;
        while r > 0 {
            let chunk = r.min(SPACES.len());
            out.write_all(&SPACES[..chunk])?;
            r -= chunk;
        }
    }
    Ok(())
}
