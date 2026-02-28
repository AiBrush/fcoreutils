// fdircolors -- color setup for ls
//
// Usage: dircolors [OPTION]... [FILE]
// Output commands to set LS_COLORS environment variable.

use std::io::{self, BufRead, Write};
use std::process;

const TOOL_NAME: &str = "dircolors";
const VERSION: &str = env!("CARGO_PKG_VERSION");

/// Simple glob pattern matcher supporting *, ?, and [...] character classes.
fn glob_match(pattern: &str, text: &str) -> bool {
    glob_match_bytes(pattern.as_bytes(), text.as_bytes())
}

fn glob_match_bytes(pat: &[u8], txt: &[u8]) -> bool {
    if pat.is_empty() {
        return txt.is_empty();
    }
    if pat[0] == b'*' {
        for i in 0..=txt.len() {
            if glob_match_bytes(&pat[1..], &txt[i..]) {
                return true;
            }
        }
        return false;
    }
    if txt.is_empty() {
        return false;
    }
    if pat[0] == b'?' {
        return glob_match_bytes(&pat[1..], &txt[1..]);
    }
    if pat[0] == b'[' {
        if let Some(close) = pat[1..].iter().position(|&b| b == b']') {
            let class = &pat[1..1 + close];
            if char_class_matches(class, txt[0]) {
                return glob_match_bytes(&pat[2 + close..], &txt[1..]);
            }
        }
        return false;
    }
    if pat[0] == txt[0] {
        return glob_match_bytes(&pat[1..], &txt[1..]);
    }
    false
}

fn char_class_matches(class: &[u8], ch: u8) -> bool {
    let mut i = 0;
    let negate = !class.is_empty() && (class[0] == b'!' || class[0] == b'^');
    if negate {
        i = 1;
    }
    let mut matched = false;
    while i < class.len() {
        if i + 2 < class.len() && class[i + 1] == b'-' {
            if ch >= class[i] && ch <= class[i + 2] {
                matched = true;
            }
            i += 3;
        } else {
            if ch == class[i] {
                matched = true;
            }
            i += 1;
        }
    }
    if negate { !matched } else { matched }
}

fn print_help() {
    println!("Usage: {} [OPTION]... [FILE]", TOOL_NAME);
    println!("Output commands to set LS_COLORS.");
    println!("Determine format of output:");
    println!("  -b, --sh, --bourne-shell    output Bourne shell code to set LS_COLORS");
    println!("  -c, --csh, --c-shell        output C shell code to set LS_COLORS");
    println!("  -p, --print-database        output defaults");
    println!("      --help     display this help and exit");
    println!("      --version  output version information and exit");
    println!();
    println!("If FILE is specified, read it to determine which colors to use for which");
    println!("file types and extensions.  Otherwise, a precompiled database is used.");
    println!("For details on the format of these files, run 'dircolors --print-database'.");
}

fn print_version() {
    println!("{} (fcoreutils) {}", TOOL_NAME, VERSION);
}

#[derive(Clone, Copy, PartialEq)]
enum OutputFormat {
    BourneShell,
    CShell,
}

/// Built-in default database, matching GNU dircolors 9.4 (Ubuntu 24.04).
const DEFAULT_DATABASE: &str = include_str!("dircolors_database.txt");

/// Result of parsing a dircolors database.
struct ParsedDatabase {
    /// TERM patterns from the database
    term_patterns: Vec<String>,
    /// COLORTERM patterns from the database
    colorterm_patterns: Vec<String>,
    /// The LS_COLORS string
    ls_colors: String,
}

/// Parse a dircolors database (either built-in or from a file) and return
/// the LS_COLORS string along with TERM/COLORTERM patterns.
fn parse_database(input: &str) -> ParsedDatabase {
    let mut entries: Vec<String> = Vec::new();
    let mut term_patterns: Vec<String> = Vec::new();
    let mut colorterm_patterns: Vec<String> = Vec::new();

    for line in input.lines() {
        let line = line.trim();

        // Skip empty lines and comments
        if line.is_empty() || line.starts_with('#') {
            continue;
        }

        // Strip inline comments
        let line = if let Some(pos) = line.find(" #") {
            line[..pos].trim()
        } else {
            line
        };

        // Collect TERM/COLORTERM patterns, skip other non-color entries
        if let Some(rest) = line.strip_prefix("TERM ") {
            term_patterns.push(rest.trim().to_string());
            continue;
        }
        if let Some(rest) = line.strip_prefix("COLORTERM ") {
            colorterm_patterns.push(rest.trim().to_string());
            continue;
        }
        if line.starts_with("COLOR ")
            || line.starts_with("OPTIONS ")
            || line.starts_with("EIGHTBIT ")
        {
            continue;
        }

        // Parse: KEY VALUE
        let parts: Vec<&str> = line.splitn(2, char::is_whitespace).collect();
        if parts.len() != 2 {
            continue;
        }

        let key = parts[0].trim();
        let value = parts[1].trim();

        if value.is_empty() {
            continue;
        }

        // Map dircolors keywords to LS_COLORS codes
        let ls_key = match key {
            "NORMAL" => "no",
            "FILE" => "fi",
            "DIR" => "di",
            "LINK" => "ln",
            "MULTIHARDLINK" => "mh",
            "FIFO" => "pi",
            "SOCK" => "so",
            "DOOR" => "do",
            "BLK" => "bd",
            "CHR" => "cd",
            "ORPHAN" => "or",
            "MISSING" => "mi",
            "SETUID" => "su",
            "SETGID" => "sg",
            "CAPABILITY" => "ca",
            "STICKY_OTHER_WRITABLE" => "tw",
            "OTHER_WRITABLE" => "ow",
            "STICKY" => "st",
            "EXEC" => "ex",
            "RESET" => "rs",
            _ => {
                // Extension: .ext or *pattern
                if key.starts_with('.') || key.starts_with('*') {
                    let ext_key = if key.starts_with('.') {
                        format!("*{key}")
                    } else {
                        key.to_string()
                    };
                    entries.push(format!("{ext_key}={value}"));
                    continue;
                }
                // Unknown keyword, skip
                continue;
            }
        };

        entries.push(format!("{ls_key}={value}"));
    }

    let ls_colors = if entries.is_empty() {
        String::new()
    } else {
        let mut s = entries.join(":");
        s.push(':');
        s
    };

    ParsedDatabase {
        term_patterns,
        colorterm_patterns,
        ls_colors,
    }
}

/// Check if the current terminal matches any TERM/COLORTERM patterns.
/// Returns true if colors should be output (terminal matches or no patterns exist).
fn terminal_matches(db: &ParsedDatabase) -> bool {
    // If no TERM/COLORTERM patterns at all, always output colors
    if db.term_patterns.is_empty() && db.colorterm_patterns.is_empty() {
        return true;
    }

    // Check TERM env var against TERM patterns
    if let Ok(term) = std::env::var("TERM") {
        for pattern in &db.term_patterns {
            if glob_match(pattern, &term) {
                return true;
            }
        }
    }

    // Check COLORTERM env var against COLORTERM patterns
    if let Ok(colorterm) = std::env::var("COLORTERM") {
        for pattern in &db.colorterm_patterns {
            if glob_match(pattern, &colorterm) {
                return true;
            }
        }
    }

    false
}

fn output_bourne_shell(ls_colors: &str) {
    println!("LS_COLORS='{ls_colors}';");
    println!("export LS_COLORS");
}

fn output_c_shell(ls_colors: &str) {
    println!("setenv LS_COLORS '{ls_colors}'");
}

fn main() {
    coreutils_rs::common::reset_sigpipe();

    let args: Vec<String> = std::env::args().skip(1).collect();

    let mut format = OutputFormat::BourneShell;
    let mut print_database = false;
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
            "-b" | "--sh" | "--bourne-shell" => {
                format = OutputFormat::BourneShell;
            }
            "-c" | "--csh" | "--c-shell" => {
                format = OutputFormat::CShell;
            }
            "-p" | "--print-database" => {
                print_database = true;
            }
            "-" => {
                filename = Some("-".to_string());
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

    if print_database {
        if filename.is_some() {
            eprintln!(
                "{}: the options to output dircolors' internal database and\nto select a shell syntax are mutually exclusive",
                TOOL_NAME
            );
            process::exit(1);
        }
        let stdout = io::stdout();
        let mut out = stdout.lock();
        let _ = out.write_all(DEFAULT_DATABASE.as_bytes());
        let _ = out.flush();
        return;
    }

    let database = if let Some(ref file) = filename {
        if file == "-" {
            let stdin = io::stdin();
            let mut input = String::new();
            for line in stdin.lock().lines() {
                match line {
                    Ok(l) => {
                        input.push_str(&l);
                        input.push('\n');
                    }
                    Err(e) => {
                        eprintln!("{}: read error: {}", TOOL_NAME, e);
                        process::exit(1);
                    }
                }
            }
            input
        } else {
            match std::fs::read_to_string(file) {
                Ok(contents) => contents,
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
        }
    } else {
        DEFAULT_DATABASE.to_string()
    };

    let db = parse_database(&database);

    let ls_colors = if terminal_matches(&db) {
        &db.ls_colors
    } else {
        ""
    };

    match format {
        OutputFormat::BourneShell => output_bourne_shell(ls_colors),
        OutputFormat::CShell => output_c_shell(ls_colors),
    }
}

#[cfg(test)]
mod tests {
    use std::io::Write;
    use std::process::Command;

    fn cmd() -> Command {
        let mut path = std::env::current_exe().unwrap();
        path.pop();
        path.pop();
        path.push("fdircolors");
        Command::new(path)
    }

    #[test]
    fn test_print_database() {
        let output = cmd().arg("-p").output().unwrap();
        assert!(output.status.success());
        let stdout = String::from_utf8_lossy(&output.stdout);
        assert!(stdout.contains("TERM"));
        assert!(stdout.contains("DIR"));
        assert!(stdout.contains(".tar"));
        assert!(stdout.contains(".gz"));
    }

    #[test]
    fn test_bourne_shell_format() {
        let output = cmd().arg("-b").output().unwrap();
        assert!(output.status.success());
        let stdout = String::from_utf8_lossy(&output.stdout);
        assert!(stdout.contains("LS_COLORS='"));
        assert!(stdout.contains("export LS_COLORS"));
    }

    #[test]
    fn test_c_shell_format() {
        let output = cmd().arg("-c").output().unwrap();
        assert!(output.status.success());
        let stdout = String::from_utf8_lossy(&output.stdout);
        assert!(stdout.contains("setenv LS_COLORS '"));
    }

    #[test]
    fn test_default_is_bourne() {
        let output = cmd().output().unwrap();
        assert!(output.status.success());
        let stdout = String::from_utf8_lossy(&output.stdout);
        assert!(stdout.contains("LS_COLORS='"));
        assert!(stdout.contains("export LS_COLORS"));
    }

    #[test]
    fn test_ls_colors_content() {
        // Set TERM to a matching terminal so colors are output
        let output = cmd()
            .arg("-b")
            .env("TERM", "xterm-256color")
            .output()
            .unwrap();
        assert!(output.status.success());
        let stdout = String::from_utf8_lossy(&output.stdout);
        // Should contain directory color
        assert!(stdout.contains("di=01;34"));
        // Should contain symlink color
        assert!(stdout.contains("ln=01;36"));
        // Should contain tar extension
        assert!(stdout.contains("*.tar=01;31"));
    }

    #[test]
    fn test_custom_config_file() {
        let dir = std::env::temp_dir();
        let config_path = dir.join("fdircolors_test_config.txt");
        {
            let mut f = std::fs::File::create(&config_path).unwrap();
            f.write_all(b"DIR 01;34\n.txt 00;32\n").unwrap();
        }
        let output = cmd()
            .arg("-b")
            .arg(config_path.to_str().unwrap())
            .output()
            .unwrap();
        assert!(output.status.success());
        let stdout = String::from_utf8_lossy(&output.stdout);
        assert!(stdout.contains("di=01;34"));
        assert!(stdout.contains("*.txt=00;32"));
        let _ = std::fs::remove_file(&config_path);
    }
    #[test]
    fn test_match_gnu_print_database_format() {
        let gnu = Command::new("dircolors").arg("-p").output();
        if let Ok(gnu) = gnu {
            let ours = cmd().arg("-p").output().unwrap();
            let gnu_stdout = String::from_utf8_lossy(&gnu.stdout);
            let our_stdout = String::from_utf8_lossy(&ours.stdout);

            // Both should have TERM entries
            assert!(gnu_stdout.contains("TERM"), "GNU should have TERM entries");
            assert!(our_stdout.contains("TERM"), "Ours should have TERM entries");

            // Both should have DIR entry
            assert!(gnu_stdout.contains("DIR"), "GNU should have DIR entry");
            assert!(our_stdout.contains("DIR"), "Ours should have DIR entry");

            // Both should have common extensions
            assert!(gnu_stdout.contains(".tar"), "GNU should have .tar");
            assert!(our_stdout.contains(".tar"), "Ours should have .tar");
        }
    }

    #[test]
    fn test_match_gnu_bourne_shell_structure() {
        let gnu = Command::new("dircolors").arg("-b").output();
        if let Ok(gnu) = gnu {
            let ours = cmd().arg("-b").output().unwrap();
            let gnu_stdout = String::from_utf8_lossy(&gnu.stdout);
            let our_stdout = String::from_utf8_lossy(&ours.stdout);

            // Both should produce LS_COLORS export
            assert!(gnu_stdout.contains("LS_COLORS="));
            assert!(our_stdout.contains("LS_COLORS="));
            assert!(gnu_stdout.contains("export LS_COLORS"));
            assert!(our_stdout.contains("export LS_COLORS"));
        }
    }

    #[test]
    fn test_p_and_file_mutual_exclusion() {
        let dir = std::env::temp_dir();
        let config_path = dir.join("fdircolors_test_mutex.txt");
        {
            let mut f = std::fs::File::create(&config_path).unwrap();
            f.write_all(b"DIR 01;34\n").unwrap();
        }
        let output = cmd()
            .arg("-p")
            .arg(config_path.to_str().unwrap())
            .output()
            .unwrap();
        assert!(!output.status.success());
        let _ = std::fs::remove_file(&config_path);
    }
}
