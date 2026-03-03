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
// 4KB buffer covers even very large tab stops in a single memcpy
const SPACES: [u8; 4096] = [b' '; 4096];

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
/// Dispatches to the optimal path based on tab configuration and data content.
pub fn expand_bytes(
    data: &[u8],
    tabs: &TabStops,
    initial_only: bool,
    out: &mut impl Write,
) -> std::io::Result<()> {
    if data.is_empty() {
        return Ok(());
    }

    // For regular tab stops, use fast SIMD paths.
    // We combine the no-tabs and no-backspace checks to minimize full-data scans.
    if let TabStops::Regular(tab_size) = tabs {
        if initial_only {
            // --initial mode: check for tabs first (cheap) to skip processing
            if memchr::memchr(b'\t', data).is_none() {
                return out.write_all(data);
            }
            return expand_initial_fast(data, *tab_size, out);
        }

        // Fast path: no tabs → write-through (avoids backspace scan too)
        if memchr::memchr(b'\t', data).is_none() {
            return out.write_all(data);
        }

        // Check for backspaces. If none, use the fast SIMD path.
        if memchr::memchr(b'\x08', data).is_none() {
            return expand_regular_fast(data, *tab_size, out);
        }

        // Has backspaces → fall through to generic
        return expand_generic(data, tabs, initial_only, true, out);
    }

    // Tab list path: check for tabs first
    if memchr::memchr(b'\t', data).is_none() {
        return out.write_all(data);
    }
    let has_backspace = memchr::memchr(b'\x08', data).is_some();
    expand_generic(data, tabs, initial_only, has_backspace, out)
}

/// Parallel threshold: files above this size use multi-threaded expand.
/// Below this, single-threaded is faster (avoids thread pool overhead).
const PARALLEL_THRESHOLD: usize = 4 * 1024 * 1024; // 4MB

/// Fast expand for regular tab stops without -i flag.
/// For large files (>4MB), uses rayon to process chunks in parallel.
/// For smaller files, uses single-threaded SIMD processing.
fn expand_regular_fast(data: &[u8], tab_size: usize, out: &mut impl Write) -> std::io::Result<()> {
    debug_assert!(tab_size > 0, "tab_size must be > 0");

    if data.len() >= PARALLEL_THRESHOLD {
        expand_regular_parallel(data, tab_size, out)
    } else {
        expand_regular_single(data, tab_size, out)
    }
}

/// Single-threaded expand: SIMD memchr2_iter scan of entire data.
fn expand_regular_single(
    data: &[u8],
    tab_size: usize,
    out: &mut impl Write,
) -> std::io::Result<()> {
    let is_pow2 = tab_size.is_power_of_two();
    let mask = tab_size.wrapping_sub(1);

    const INPUT_CHUNK: usize = 256 * 1024;
    let worst_output = INPUT_CHUNK * tab_size + tab_size;
    let mut output: Vec<u8> = Vec::with_capacity(worst_output);

    let mut column: usize = 0;
    let mut data_pos: usize = 0;

    while data_pos < data.len() {
        let chunk_end = if data_pos + INPUT_CHUNK >= data.len() {
            data.len()
        } else {
            let search_end = data_pos + INPUT_CHUNK;
            match memchr::memrchr(b'\n', &data[data_pos..search_end]) {
                Some(off) => data_pos + off + 1,
                None => search_end,
            }
        };

        let chunk = &data[data_pos..chunk_end];
        output.clear();

        let out_ptr = output.as_mut_ptr();
        let src = chunk.as_ptr();
        let mut wp: usize = 0;
        let mut pos: usize = 0;

        for hit in memchr::memchr2_iter(b'\t', b'\n', chunk) {
            let seg_len = hit - pos;
            if seg_len > 0 {
                unsafe {
                    std::ptr::copy_nonoverlapping(src.add(pos), out_ptr.add(wp), seg_len);
                }
                wp += seg_len;
                column += seg_len;
            }

            if unsafe { *src.add(hit) } == b'\n' {
                unsafe {
                    *out_ptr.add(wp) = b'\n';
                }
                wp += 1;
                column = 0;
            } else {
                let rem = if is_pow2 {
                    column & mask
                } else {
                    column % tab_size
                };
                let spaces = tab_size - rem;
                unsafe {
                    std::ptr::write_bytes(out_ptr.add(wp), b' ', spaces);
                }
                wp += spaces;
                column += spaces;
            }

            pos = hit + 1;
        }

        if pos < chunk.len() {
            let tail = chunk.len() - pos;
            unsafe {
                std::ptr::copy_nonoverlapping(src.add(pos), out_ptr.add(wp), tail);
            }
            wp += tail;
            column += tail;
        }

        unsafe {
            output.set_len(wp);
        }
        if wp > 0 {
            out.write_all(&output)?;
        }

        data_pos = chunk_end;
    }

    Ok(())
}

/// Expand a chunk of data (must start/end on newline boundaries, except possibly
/// the last chunk). Column starts at 0 for each chunk since chunks are line-aligned.
/// Returns the expanded output as a Vec<u8>.
/// Pre-allocates worst-case output to eliminate all capacity checks in the hot loop.
fn expand_chunk(chunk: &[u8], tab_size: usize, is_pow2: bool, mask: usize) -> Vec<u8> {
    // Worst case: every byte is a tab → tab_size× expansion.
    // For most real data the expansion ratio is ~1.5x, so this over-allocates,
    // but it eliminates all capacity checks from the hot loop.
    let worst_case = chunk.len() * tab_size;
    let mut output: Vec<u8> = Vec::with_capacity(worst_case);

    let out_ptr = output.as_mut_ptr();
    let src = chunk.as_ptr();
    let mut wp: usize = 0;
    let mut column: usize = 0;
    let mut pos: usize = 0;

    // Inner loop: zero capacity checks, zero Vec::len() reads, zero set_len() calls.
    // Just raw pointer arithmetic.
    for hit in memchr::memchr2_iter(b'\t', b'\n', chunk) {
        let seg_len = hit - pos;
        if seg_len > 0 {
            unsafe {
                std::ptr::copy_nonoverlapping(src.add(pos), out_ptr.add(wp), seg_len);
            }
            wp += seg_len;
            column += seg_len;
        }

        if unsafe { *src.add(hit) } == b'\n' {
            unsafe {
                *out_ptr.add(wp) = b'\n';
            }
            wp += 1;
            column = 0;
        } else {
            let rem = if is_pow2 {
                column & mask
            } else {
                column % tab_size
            };
            let spaces = tab_size - rem;
            unsafe {
                std::ptr::write_bytes(out_ptr.add(wp), b' ', spaces);
            }
            wp += spaces;
            column += spaces;
        }

        pos = hit + 1;
    }

    // Copy tail
    if pos < chunk.len() {
        let tail = chunk.len() - pos;
        unsafe {
            std::ptr::copy_nonoverlapping(src.add(pos), out_ptr.add(wp), tail);
        }
        wp += tail;
    }

    unsafe {
        output.set_len(wp);
    }
    output
}

/// Parallel expand for large files (>4MB). Splits data into line-aligned chunks
/// and processes them concurrently using rayon. Each chunk is expanded independently
/// (column tracking resets at newline boundaries), then results are written in order.
fn expand_regular_parallel(
    data: &[u8],
    tab_size: usize,
    out: &mut impl Write,
) -> std::io::Result<()> {
    use rayon::prelude::*;

    let is_pow2 = tab_size.is_power_of_two();
    let mask = tab_size.wrapping_sub(1);

    // Split data into line-aligned chunks for parallel processing.
    // Use ~N chunks where N = number of CPUs for optimal load balance.
    let num_chunks = rayon::current_num_threads().max(2);
    let target_chunk_size = data.len() / num_chunks;
    let mut chunks: Vec<&[u8]> = Vec::with_capacity(num_chunks + 1);
    let mut pos: usize = 0;

    for _ in 0..num_chunks - 1 {
        if pos >= data.len() {
            break;
        }
        let target_end = (pos + target_chunk_size).min(data.len());
        // Find the next newline at or after target_end
        let chunk_end = if target_end >= data.len() {
            data.len()
        } else {
            match memchr::memchr(b'\n', &data[target_end..]) {
                Some(off) => target_end + off + 1,
                None => data.len(),
            }
        };
        chunks.push(&data[pos..chunk_end]);
        pos = chunk_end;
    }
    // Last chunk gets everything remaining
    if pos < data.len() {
        chunks.push(&data[pos..]);
    }

    // Process all chunks in parallel
    let results: Vec<Vec<u8>> = chunks
        .par_iter()
        .map(|chunk| expand_chunk(chunk, tab_size, is_pow2, mask))
        .collect();

    // Write results in order
    for result in &results {
        if !result.is_empty() {
            out.write_all(result)?;
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
            expand_generic(line, &tabs, true, true, out)?;
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
/// Uses memchr2 SIMD scanning when no backspaces are present.
/// `has_backspace` hint avoids a redundant O(n) scan when the caller already knows.
fn expand_generic(
    data: &[u8],
    tabs: &TabStops,
    initial_only: bool,
    has_backspace: bool,
    out: &mut impl Write,
) -> std::io::Result<()> {
    const FLUSH_THRESHOLD: usize = 256 * 1024;
    let cap = data.len().min(FLUSH_THRESHOLD) + data.len().min(FLUSH_THRESHOLD) / 8;
    let mut output = Vec::with_capacity(cap);

    // If no backspaces present and not initial-only, use SIMD bulk scanning
    if !initial_only && !has_backspace {
        let mut column: usize = 0;
        let mut pos: usize = 0;

        while pos < data.len() {
            match memchr::memchr2(b'\t', b'\n', &data[pos..]) {
                Some(offset) => {
                    if offset > 0 {
                        output.extend_from_slice(&data[pos..pos + offset]);
                        column += offset;
                    }
                    let byte = data[pos + offset];
                    pos += offset + 1;

                    if byte == b'\n' {
                        output.push(b'\n');
                        column = 0;
                    } else {
                        let spaces = tabs.spaces_to_next(column);
                        push_spaces(&mut output, spaces);
                        column += spaces;
                    }
                    if output.len() >= FLUSH_THRESHOLD {
                        out.write_all(&output)?;
                        output.clear();
                    }
                }
                None => {
                    output.extend_from_slice(&data[pos..]);
                    break;
                }
            }
        }
    } else {
        // Byte-by-byte fallback for backspace handling or initial-only mode
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
                    if output.len() >= FLUSH_THRESHOLD {
                        out.write_all(&output)?;
                        output.clear();
                    }
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
    }

    if !output.is_empty() {
        out.write_all(&output)?;
    }
    Ok(())
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
    if all {
        return unexpand_regular_fast_all(data, tab_size, out);
    }

    let mut column: usize = 0;
    let mut pos: usize = 0;
    let mut in_initial = true;

    while pos < data.len() {
        if in_initial {
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
            // Non-blank: fall through to body mode below.
        }

        // Body of line: bulk copy until newline (default mode)
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
    }

    Ok(())
}

/// Fast unexpand -a for regular tab stops without backspaces.
/// Buffers output into a Vec to avoid per-call write_all overhead.
/// Handles single spaces efficiently (most common case: no tab conversion needed).
fn unexpand_regular_fast_all(
    data: &[u8],
    tab_size: usize,
    out: &mut impl Write,
) -> std::io::Result<()> {
    // Line-level fast path: process the file line by line.
    // Lines with only single spaces (no tabs, no double spaces) don't need
    // any conversion and can be copied as-is — this covers most natural text.
    let mut output: Vec<u8> = Vec::with_capacity(data.len());
    let mut pos: usize = 0;

    for nl_pos in memchr::memchr_iter(b'\n', data) {
        let line = &data[pos..nl_pos];

        // Fast check: skip lines with no tabs and no consecutive spaces.
        // Two separate SIMD scans are needed: memchr2 can't work because
        // a space appearing before a tab would cause us to miss the tab.
        let needs_processing =
            memchr::memchr(b'\t', line).is_some() || memchr::memmem::find(line, b"  ").is_some();

        if !needs_processing {
            // No conversion needed: copy line as-is
            output.extend_from_slice(line);
        } else {
            // Process this line through the blank-conversion logic
            unexpand_line_all(line, tab_size, &mut output);
        }
        output.push(b'\n');

        // Flush periodically
        if output.len() >= 256 * 1024 {
            out.write_all(&output)?;
            output.clear();
        }
        pos = nl_pos + 1;
    }

    // Handle final line without trailing newline
    if pos < data.len() {
        let line = &data[pos..];
        let needs_processing =
            memchr::memchr(b'\t', line).is_some() || memchr::memmem::find(line, b"  ").is_some();
        if !needs_processing {
            output.extend_from_slice(line);
        } else {
            unexpand_line_all(line, tab_size, &mut output);
        }
    }

    if !output.is_empty() {
        out.write_all(&output)?;
    }
    Ok(())
}

/// Process a single line for unexpand -a, converting blank runs to tabs+spaces.
#[inline]
fn unexpand_line_all(line: &[u8], tab_size: usize, output: &mut Vec<u8>) {
    let mut column: usize = 0;
    let mut pos: usize = 0;

    while pos < line.len() {
        // Check for blanks to convert
        if line[pos] == b' ' || line[pos] == b'\t' {
            // Count consecutive blanks, tracking column advancement
            let blank_start_col = column;
            while pos < line.len() && (line[pos] == b' ' || line[pos] == b'\t') {
                if line[pos] == b'\t' {
                    column += tab_size - column % tab_size;
                } else {
                    column += 1;
                }
                pos += 1;
            }
            // Vec<u8> implements Write, so we can use emit_blanks directly.
            emit_blanks(output, blank_start_col, column - blank_start_col, tab_size).unwrap();
            continue;
        }

        // Non-blank: copy until next space or tab
        match memchr::memchr2(b' ', b'\t', &line[pos..]) {
            Some(offset) => {
                output.extend_from_slice(&line[pos..pos + offset]);
                column += offset;
                pos += offset;
            }
            None => {
                output.extend_from_slice(&line[pos..]);
                break;
            }
        }
    }
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
