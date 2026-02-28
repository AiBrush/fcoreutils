#[cfg(not(unix))]
fn main() {
    eprintln!("dir: only available on Unix");
    std::process::exit(1);
}

// fdir -- list directory contents in multi-column format with C-style escapes
//
// dir is equivalent to: ls -C -b
//
// Uses our native ls module with LsFlavor::Dir defaults.

#[cfg(unix)]
fn main() {
    coreutils_rs::common::reset_sigpipe();
    coreutils_rs::ls::run_ls(coreutils_rs::ls::LsFlavor::Dir);
}

#[cfg(all(test, unix))]
mod tests {
    use std::process::Command;

    fn cmd() -> Command {
        let mut path = std::env::current_exe().unwrap();
        path.pop();
        path.pop();
        path.push("fdir");
        Command::new(path)
    }

    #[test]
    fn test_help() {
        let output = cmd().arg("--help").output().unwrap();
        assert!(output.status.success());
        let stdout = String::from_utf8_lossy(&output.stdout);
        assert!(stdout.contains("Usage"));
    }

    #[test]
    fn test_version() {
        let output = cmd().arg("--version").output().unwrap();
        assert!(output.status.success());
        let stdout = String::from_utf8_lossy(&output.stdout);
        assert!(stdout.contains("fcoreutils"));
    }

    #[test]
    fn test_basic() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(dir.path().join("hello.txt"), "hi").unwrap();
        let output = cmd().arg(dir.path().to_str().unwrap()).output().unwrap();
        assert!(output.status.success());
        let stdout = String::from_utf8_lossy(&output.stdout);
        assert!(stdout.contains("hello.txt"));
    }

    #[test]
    fn test_current_dir() {
        let output = cmd().output().unwrap();
        assert!(output.status.success());
        assert!(!output.stdout.is_empty());
    }
}
