// ftsort -- topological sort
//
// Usage: tsort [OPTION] [FILE]
// Read pairs of strings from FILE (or stdin), representing edges in a
// directed graph, and output a topological ordering.

use std::collections::{HashMap, VecDeque};
use std::hash::{BuildHasherDefault, Hasher};
use std::io::{self, Read, Write};
use std::process;

const TOOL_NAME: &str = "tsort";
const VERSION: &str = env!("CARGO_PKG_VERSION");

// Maximum numeric value for direct-indexing fast path (4MB lookup table).
const NUMERIC_FAST_PATH_MAX: u32 = 1_100_000;

// FxHash: fast non-cryptographic hash for string interning and edge dedup.
struct FxHasher(u64);

impl Default for FxHasher {
    #[inline]
    fn default() -> Self {
        FxHasher(0)
    }
}

impl Hasher for FxHasher {
    #[inline]
    fn finish(&self) -> u64 {
        self.0
    }
    #[inline]
    fn write(&mut self, bytes: &[u8]) {
        for &b in bytes {
            self.0 = (self.0.rotate_left(5) ^ b as u64).wrapping_mul(0x517cc1b727220a95);
        }
    }
    #[inline]
    fn write_u32(&mut self, i: u32) {
        self.0 = (self.0.rotate_left(5) ^ i as u64).wrapping_mul(0x517cc1b727220a95);
    }
    #[inline]
    fn write_u64(&mut self, i: u64) {
        self.0 = (self.0.rotate_left(5) ^ i).wrapping_mul(0x517cc1b727220a95);
    }
}

type FxBuildHasher = BuildHasherDefault<FxHasher>;
type FxHashMap<K, V> = HashMap<K, V, FxBuildHasher>;

fn print_help() {
    println!("Usage: {} [OPTION] [FILE]", TOOL_NAME);
    println!("Write totally ordered list consistent with the partial ordering in FILE.");
    println!("With no FILE, or when FILE is -, read standard input.");
    println!();
    println!("      --help     display this help and exit");
    println!("      --version  output version information and exit");
}

fn print_version() {
    println!("{} (fcoreutils) {}", TOOL_NAME, VERSION);
}

/// Try to parse a byte slice as a u32. Returns None for non-numeric or overflow.
#[inline]
fn try_parse_u32(token: &[u8]) -> Option<u32> {
    if token.is_empty() || token.len() > 7 {
        return None;
    }
    let mut n: u32 = 0;
    for &b in token {
        let d = b.wrapping_sub(b'0');
        if d > 9 {
            return None;
        }
        n = n * 10 + d as u32;
    }
    Some(n)
}

/// Scan the next token from input starting at `pos`. Returns (token, new_pos).
#[inline]
fn next_token(input: &[u8], mut pos: usize) -> Option<(&[u8], usize)> {
    let len = input.len();
    // Skip whitespace
    while pos < len {
        let b = input[pos];
        if b != b' ' && b != b'\n' && b != b'\r' && b != b'\t' {
            break;
        }
        pos += 1;
    }
    if pos >= len {
        return None;
    }
    let start = pos;
    while pos < len {
        let b = input[pos];
        if b == b' ' || b == b'\n' || b == b'\r' || b == b'\t' {
            break;
        }
        pos += 1;
    }
    Some((&input[start..pos], pos))
}

/// Numeric fast path: all tokens are small integers, use Vec-indexed lookup
/// instead of HashMap. Eliminates hashing entirely for O(1) lookup.
/// Single-pass: parses tokens, interns values, builds adjacency simultaneously.
fn run_numeric(input: &[u8], source_name: &str) -> Option<i32> {
    // Pre-allocate lookup table for value→node_id mapping.
    let mut val_to_id = vec![u32::MAX; NUMERIC_FAST_PATH_MAX as usize + 1];
    let mut node_values: Vec<u32> = Vec::new(); // node_id → numeric value
    let mut adj: Vec<Vec<u32>> = Vec::new();
    let mut in_deg: Vec<u32> = Vec::new();

    let mut pos = 0;
    let mut pair_first_id: u32 = 0;
    let mut is_first = true;
    let mut token_count = 0u64;

    // Single pass: parse token → intern value → build edges
    while let Some((token, new_pos)) = next_token(input, pos) {
        pos = new_pos;
        let val = try_parse_u32(token)?;
        if val > NUMERIC_FAST_PATH_MAX {
            return None;
        }

        // Direct-indexed interning (O(1) lookup, no hashing)
        let mut id = val_to_id[val as usize];
        if id == u32::MAX {
            id = node_values.len() as u32;
            val_to_id[val as usize] = id;
            node_values.push(val);
            adj.push(Vec::new());
            in_deg.push(0);
        }

        token_count += 1;
        if is_first {
            pair_first_id = id;
            is_first = false;
        } else {
            // Build edge directly — dedup via linear scan on adjacency list.
            // For typical tsort inputs (low fan-out), this is O(1) per edge.
            if pair_first_id != id && !adj[pair_first_id as usize].contains(&id) {
                adj[pair_first_id as usize].push(id);
                in_deg[id as usize] += 1;
            }
            is_first = true;
        }
    }

    if !token_count.is_multiple_of(2) {
        eprintln!(
            "{}: {}: input contains an odd number of tokens",
            TOOL_NAME, source_name
        );
        return Some(1);
    }

    drop(val_to_id);
    let total = node_values.len();

    // Kahn's algorithm with inline itoa output (avoids pre-formatting all names)
    Some(kahn_sort_numeric(
        &node_values,
        &adj,
        &mut in_deg,
        total,
        source_name,
    ))
}

/// Kahn's sort optimized for numeric node names (uses itoa on-the-fly).
fn kahn_sort_numeric(
    node_values: &[u32],
    adj: &[Vec<u32>],
    in_deg: &mut [u32],
    total: usize,
    source_name: &str,
) -> i32 {
    let stdout = io::stdout();
    let mut out = io::BufWriter::with_capacity(256 * 1024, stdout.lock());
    let mut out_buf: Vec<u8> = Vec::with_capacity(256 * 1024);
    let mut itoa_buf = itoa::Buffer::new();

    let mut queue: VecDeque<u32> = VecDeque::new();
    let mut processed = 0usize;
    let mut has_cycle = false;
    let mut removed = vec![false; total];
    let mut new_zeros: Vec<u32> = Vec::new();

    for (id, &deg) in in_deg.iter().enumerate().take(total) {
        if deg == 0 {
            queue.push_back(id as u32);
        }
    }

    loop {
        while let Some(node) = queue.pop_front() {
            let node_usize = node as usize;
            processed += 1;
            removed[node_usize] = true;

            // Format number directly into output buffer
            out_buf.extend_from_slice(itoa_buf.format(node_values[node_usize]).as_bytes());
            out_buf.push(b'\n');
            if out_buf.len() >= 128 * 1024 {
                if out.write_all(&out_buf).is_err() {
                    process::exit(0);
                }
                out_buf.clear();
            }

            new_zeros.clear();
            for &nb in &adj[node_usize] {
                let nb_usize = nb as usize;
                if !removed[nb_usize] && in_deg[nb_usize] > 0 {
                    in_deg[nb_usize] -= 1;
                    if in_deg[nb_usize] == 0 {
                        new_zeros.push(nb);
                    }
                }
            }
            for &n in new_zeros.iter().rev() {
                queue.push_back(n);
            }
        }

        if processed >= total {
            break;
        }

        has_cycle = true;
        if !out_buf.is_empty() {
            let _ = out.write_all(&out_buf);
            out_buf.clear();
        }
        let _ = out.flush();

        let start_node = (0..total).find(|&n| !removed[n]).unwrap();
        let cycle = find_cycle(start_node, adj, &removed);

        eprintln!("{}: {}: input contains a loop:", TOOL_NAME, source_name);
        for &member in &cycle {
            eprintln!("{}: {}", TOOL_NAME, itoa_buf.format(node_values[member]));
        }

        in_deg[cycle[0]] = 0;
        queue.push_back(cycle[0] as u32);
    }

    if !out_buf.is_empty() {
        let _ = out.write_all(&out_buf);
    }
    let _ = out.flush();
    if has_cycle { 1 } else { 0 }
}

/// General-purpose path: uses FxHashMap for arbitrary string tokens.
fn run_general(input: &[u8], source_name: &str) -> i32 {
    let mut node_names: Vec<&[u8]> = Vec::new();
    let mut name_to_id: FxHashMap<&[u8], u32> = FxHashMap::default();
    let mut edge_pairs: Vec<(u32, u32)> = Vec::new();

    let mut pos = 0;
    let mut pair_first: u32 = 0;
    let mut is_first = true;
    let mut token_count = 0u64;

    while let Some((token, new_pos)) = next_token(input, pos) {
        pos = new_pos;
        let next_id = node_names.len() as u32;
        let id = *name_to_id.entry(token).or_insert_with(|| {
            node_names.push(token);
            next_id
        });

        token_count += 1;
        if is_first {
            pair_first = id;
            is_first = false;
        } else {
            edge_pairs.push((pair_first, id));
            is_first = true;
        }
    }

    if !token_count.is_multiple_of(2) {
        eprintln!(
            "{}: {}: input contains an odd number of tokens",
            TOOL_NAME, source_name
        );
        return 1;
    }

    let total = node_names.len();

    // Build adjacency with edge dedup via linear scan (fast for low fan-out)
    let mut adj: Vec<Vec<u32>> = vec![Vec::new(); total];
    let mut in_deg: Vec<u32> = vec![0; total];

    for &(from, to) in &edge_pairs {
        if from != to && !adj[from as usize].contains(&to) {
            adj[from as usize].push(to);
            in_deg[to as usize] += 1;
        }
    }
    drop(edge_pairs);

    kahn_sort(&node_names, &adj, &mut in_deg, total, source_name)
}

/// Kahn's topological sort with cycle breaking (matches GNU behavior).
/// Works with any node name type that derefs to [u8].
fn kahn_sort<T: AsRef<[u8]>>(
    node_names: &[T],
    adj: &[Vec<u32>],
    in_deg: &mut [u32],
    total: usize,
    source_name: &str,
) -> i32 {
    let stdout = io::stdout();
    let mut out = io::BufWriter::with_capacity(256 * 1024, stdout.lock());
    let mut out_buf: Vec<u8> = Vec::with_capacity(256 * 1024);

    let mut queue: VecDeque<u32> = VecDeque::new();
    let mut processed = 0usize;
    let mut has_cycle = false;
    let mut removed = vec![false; total];
    let mut new_zeros: Vec<u32> = Vec::new();

    // Seed queue with initial zero-degree nodes
    for (id, &deg) in in_deg.iter().enumerate().take(total) {
        if deg == 0 {
            queue.push_back(id as u32);
        }
    }

    loop {
        while let Some(node) = queue.pop_front() {
            let node_usize = node as usize;
            processed += 1;
            removed[node_usize] = true;

            out_buf.extend_from_slice(node_names[node_usize].as_ref());
            out_buf.push(b'\n');
            if out_buf.len() >= 128 * 1024 {
                if out.write_all(&out_buf).is_err() {
                    process::exit(0);
                }
                out_buf.clear();
            }

            new_zeros.clear();
            for &nb in &adj[node_usize] {
                let nb_usize = nb as usize;
                if !removed[nb_usize] && in_deg[nb_usize] > 0 {
                    in_deg[nb_usize] -= 1;
                    if in_deg[nb_usize] == 0 {
                        new_zeros.push(nb);
                    }
                }
            }
            for &n in new_zeros.iter().rev() {
                queue.push_back(n);
            }
        }

        if processed >= total {
            break;
        }

        has_cycle = true;
        if !out_buf.is_empty() {
            let _ = out.write_all(&out_buf);
            out_buf.clear();
        }
        let _ = out.flush();

        let start_node = (0..total).find(|&n| !removed[n]).unwrap();
        let cycle = find_cycle(start_node, adj, &removed);

        eprintln!("{}: {}: input contains a loop:", TOOL_NAME, source_name);
        for &member in &cycle {
            eprintln!(
                "{}: {}",
                TOOL_NAME,
                String::from_utf8_lossy(node_names[member].as_ref())
            );
        }

        in_deg[cycle[0]] = 0;
        queue.push_back(cycle[0] as u32);
    }

    if !out_buf.is_empty() {
        let _ = out.write_all(&out_buf);
    }
    let _ = out.flush();
    if has_cycle { 1 } else { 0 }
}

fn run_bytes(input: &[u8], source_name: &str) -> i32 {
    // Try numeric fast path first (eliminates hashing for integer-only inputs)
    if let Some(exit_code) = run_numeric(input, source_name) {
        return exit_code;
    }
    // Fall back to general-purpose path
    run_general(input, source_name)
}

/// Find a cycle starting from `start` by following edges via DFS.
fn find_cycle(start: usize, adj: &[Vec<u32>], removed: &[bool]) -> Vec<usize> {
    let mut visited = vec![u32::MAX; removed.len()];
    let mut path: Vec<usize> = Vec::new();

    let mut current = start;
    loop {
        if visited[current] != u32::MAX {
            return path[visited[current] as usize..].to_vec();
        }
        visited[current] = path.len() as u32;
        path.push(current);

        let next = adj[current].iter().find(|&&n| !removed[n as usize]);
        match next {
            Some(&n) => current = n as usize,
            None => return vec![start],
        }
    }
}

/// Try to mmap stdin if it's a regular file.
#[cfg(unix)]
fn try_mmap_stdin() -> Option<memmap2::Mmap> {
    use std::os::unix::io::FromRawFd;
    let mut stat: libc::stat = unsafe { std::mem::zeroed() };
    if unsafe { libc::fstat(0, &mut stat) } != 0
        || (stat.st_mode & libc::S_IFMT) != libc::S_IFREG
        || stat.st_size <= 0
    {
        return None;
    }
    let file = unsafe { std::fs::File::from_raw_fd(0) };
    let mmap = unsafe { memmap2::MmapOptions::new().map(&file) }.ok();
    std::mem::forget(file);
    mmap
}

fn main() {
    coreutils_rs::common::reset_sigpipe();

    let args: Vec<String> = std::env::args().skip(1).collect();
    let mut filename: Option<String> = None;

    for arg in &args {
        match arg.as_str() {
            "--help" => {
                print_help();
                return;
            }
            "--version" => {
                print_version();
                return;
            }
            "-" => {
                filename = None;
            }
            _ => {
                if arg.starts_with('-') {
                    eprintln!("{}: unrecognized option '{}'", TOOL_NAME, arg);
                    process::exit(1);
                }
                filename = Some(arg.clone());
            }
        }
    }

    if let Some(ref file) = filename {
        #[cfg(unix)]
        {
            if let Ok(f) = std::fs::File::open(file) {
                let size = f.metadata().map(|m| m.len()).unwrap_or(0);
                if size > 0
                    && let Ok(mmap) = unsafe { memmap2::MmapOptions::new().map(&f) }
                {
                    let exit_code = run_bytes(&mmap, file);
                    process::exit(exit_code);
                }
            }
        }
        match std::fs::read(file) {
            Ok(contents) => {
                let exit_code = run_bytes(&contents, file);
                process::exit(exit_code);
            }
            Err(e) => {
                eprintln!(
                    "{}: {}: {}",
                    TOOL_NAME,
                    file,
                    coreutils_rs::common::io_error_msg(&e)
                );
                process::exit(1);
            }
        }
    } else {
        #[cfg(unix)]
        {
            if let Some(mmap) = try_mmap_stdin() {
                let exit_code = run_bytes(&mmap, "-");
                process::exit(exit_code);
            }
        }
        let mut input = Vec::new();
        if let Err(e) = io::stdin().lock().read_to_end(&mut input) {
            eprintln!("{}: read error: {}", TOOL_NAME, e);
            process::exit(1);
        }
        let exit_code = run_bytes(&input, "-");
        process::exit(exit_code);
    }
}

#[cfg(test)]
mod tests {
    use std::process::Command;

    fn cmd() -> Command {
        let mut path = std::env::current_exe().unwrap();
        path.pop();
        path.pop();
        path.push("ftsort");
        Command::new(path)
    }

    #[test]
    fn test_basic_sort() {
        let output = cmd()
            .args(["-"])
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::piped())
            .spawn()
            .and_then(|mut child| {
                use std::io::Write;
                let stdin = child.stdin.as_mut().unwrap();
                stdin.write_all(b"a b\nb c\n").unwrap();
                drop(child.stdin.take());
                child.wait_with_output()
            })
            .unwrap();
        assert!(output.status.success());
        let stdout = String::from_utf8_lossy(&output.stdout);
        let lines: Vec<&str> = stdout.trim().lines().collect();
        assert_eq!(lines.len(), 3);
        let pos_a = lines.iter().position(|&x| x == "a").unwrap();
        let pos_b = lines.iter().position(|&x| x == "b").unwrap();
        let pos_c = lines.iter().position(|&x| x == "c").unwrap();
        assert!(pos_a < pos_b);
        assert!(pos_b < pos_c);
    }

    #[test]
    fn test_stdin_input() {
        use std::io::Write;
        let mut child = cmd()
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::piped())
            .spawn()
            .unwrap();
        {
            let stdin = child.stdin.as_mut().unwrap();
            stdin.write_all(b"x y\ny z\n").unwrap();
        }
        let output = child.wait_with_output().unwrap();
        assert!(output.status.success());
        let stdout = String::from_utf8_lossy(&output.stdout);
        let lines: Vec<&str> = stdout.trim().lines().collect();
        let pos_x = lines.iter().position(|&x| x == "x").unwrap();
        let pos_y = lines.iter().position(|&x| x == "y").unwrap();
        let pos_z = lines.iter().position(|&x| x == "z").unwrap();
        assert!(pos_x < pos_y);
        assert!(pos_y < pos_z);
    }

    #[test]
    fn test_cycle_detection() {
        use std::io::Write;
        let mut child = cmd()
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::piped())
            .spawn()
            .unwrap();
        {
            let stdin = child.stdin.as_mut().unwrap();
            stdin.write_all(b"a b\nb c\nc a\n").unwrap();
        }
        let output = child.wait_with_output().unwrap();
        assert!(!output.status.success());
        let stderr = String::from_utf8_lossy(&output.stderr);
        assert!(stderr.contains("loop"));
    }

    #[test]
    fn test_single_element() {
        use std::io::Write;
        let mut child = cmd()
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::piped())
            .spawn()
            .unwrap();
        {
            let stdin = child.stdin.as_mut().unwrap();
            stdin.write_all(b"a a\n").unwrap();
        }
        let output = child.wait_with_output().unwrap();
        assert!(output.status.success());
        let stdout = String::from_utf8_lossy(&output.stdout);
        assert_eq!(stdout.trim(), "a");
    }

    #[test]
    fn test_file_input() {
        use std::io::Write;
        let dir = std::env::temp_dir();
        let file_path = dir.join("tsort_test_input.txt");
        {
            let mut f = std::fs::File::create(&file_path).unwrap();
            f.write_all(b"1 2\n2 3\n3 4\n").unwrap();
        }
        let output = cmd().arg(file_path.to_str().unwrap()).output().unwrap();
        assert!(output.status.success());
        let stdout = String::from_utf8_lossy(&output.stdout);
        let lines: Vec<&str> = stdout.trim().lines().collect();
        assert_eq!(lines, vec!["1", "2", "3", "4"]);
        let _ = std::fs::remove_file(&file_path);
    }

    #[test]
    fn test_help() {
        let output = cmd().arg("--help").output().unwrap();
        assert!(output.status.success());
        let stdout = String::from_utf8_lossy(&output.stdout);
        assert!(stdout.contains("Usage:"));
        assert!(stdout.contains("tsort"));
    }

    #[test]
    fn test_version() {
        let output = cmd().arg("--version").output().unwrap();
        assert!(output.status.success());
        let stdout = String::from_utf8_lossy(&output.stdout);
        assert!(stdout.contains("tsort"));
        assert!(stdout.contains("fcoreutils"));
    }

    #[test]
    fn test_match_gnu_basic() {
        use std::io::Write;

        let gnu = Command::new("tsort")
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::piped())
            .spawn()
            .and_then(|mut child| {
                let stdin = child.stdin.as_mut().unwrap();
                stdin.write_all(b"a b\nb c\nc d\n").unwrap();
                drop(child.stdin.take());
                child.wait_with_output()
            });

        if let Ok(gnu) = gnu {
            let mut child = cmd()
                .stdin(std::process::Stdio::piped())
                .stdout(std::process::Stdio::piped())
                .spawn()
                .unwrap();
            {
                let stdin = child.stdin.as_mut().unwrap();
                stdin.write_all(b"a b\nb c\nc d\n").unwrap();
            }
            let ours = child.wait_with_output().unwrap();
            assert_eq!(
                String::from_utf8_lossy(&ours.stdout),
                String::from_utf8_lossy(&gnu.stdout),
                "Output mismatch with GNU tsort"
            );
        }
    }

    #[test]
    fn test_diamond_dependency() {
        use std::io::Write;
        let mut child = cmd()
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::piped())
            .spawn()
            .unwrap();
        {
            let stdin = child.stdin.as_mut().unwrap();
            stdin.write_all(b"a b\na c\nb d\nc d\n").unwrap();
        }
        let output = child.wait_with_output().unwrap();
        assert!(output.status.success());
        let stdout = String::from_utf8_lossy(&output.stdout);
        let lines: Vec<&str> = stdout.trim().lines().collect();
        let pos_a = lines.iter().position(|&x| x == "a").unwrap();
        let pos_b = lines.iter().position(|&x| x == "b").unwrap();
        let pos_c = lines.iter().position(|&x| x == "c").unwrap();
        let pos_d = lines.iter().position(|&x| x == "d").unwrap();
        assert!(pos_a < pos_b);
        assert!(pos_a < pos_c);
        assert!(pos_b < pos_d);
        assert!(pos_c < pos_d);
    }
}
