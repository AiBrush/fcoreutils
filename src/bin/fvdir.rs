#[cfg(not(unix))]
fn main() {
    eprintln!("vdir: only available on Unix");
    std::process::exit(1);
}

// fvdir -- list directory contents in long format with C-style escapes
//
// vdir is equivalent to: ls -l -b
//
// Uses our native ls module with LsFlavor::Vdir defaults.

#[cfg(unix)]
fn main() {
    coreutils_rs::common::reset_sigpipe();
    coreutils_rs::ls::run_ls(coreutils_rs::ls::LsFlavor::Vdir);
}

#[cfg(all(test, unix))]
mod tests {
    use std::process::Command;

    fn cmd() -> Command {
        let mut path = std::env::current_exe().unwrap();
        path.pop();
        path.pop();
        path.push("fvdir");
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
        // vdir is ls -l, so should show permissions and filename
        assert!(stdout.contains("hello.txt"));
    }

    #[test]
    fn test_current_dir() {
        let output = cmd().output().unwrap();
        assert!(output.status.success());
        assert!(!output.stdout.is_empty());
    }

    #[test]
    fn test_vdir_long_format() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(dir.path().join("test.txt"), "hello").unwrap();
        let output = cmd().arg(dir.path().to_str().unwrap()).output().unwrap();
        assert!(output.status.success());
        let stdout = String::from_utf8_lossy(&output.stdout);
        // Long format should show permissions
        assert!(
            stdout.contains("rw") || stdout.contains("-r"),
            "Should show file permissions"
        );
    }

    #[test]
    fn test_vdir_empty_dir() {
        let dir = tempfile::tempdir().unwrap();
        let output = cmd().arg(dir.path().to_str().unwrap()).output().unwrap();
        assert!(output.status.success());
    }

    #[test]
    fn test_vdir_multiple_files() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(dir.path().join("a.txt"), "a").unwrap();
        std::fs::write(dir.path().join("b.txt"), "b").unwrap();
        std::fs::write(dir.path().join("c.txt"), "c").unwrap();
        let output = cmd().arg(dir.path().to_str().unwrap()).output().unwrap();
        assert!(output.status.success());
        let stdout = String::from_utf8_lossy(&output.stdout);
        assert!(stdout.contains("a.txt") && stdout.contains("b.txt") && stdout.contains("c.txt"));
    }

    #[test]
    fn test_vdir_nonexistent() {
        let output = cmd().arg("/nonexistent_xyz_vdir").output().unwrap();
        assert!(!output.status.success());
    }

    #[test]
    fn test_vdir_hidden_files() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(dir.path().join(".hidden"), "x").unwrap();
        std::fs::write(dir.path().join("visible"), "x").unwrap();
        let output = cmd().arg(dir.path().to_str().unwrap()).output().unwrap();
        assert!(output.status.success());
        let stdout = String::from_utf8_lossy(&output.stdout);
        // Default: hidden files not shown
        assert!(!stdout.contains(".hidden"));
        assert!(stdout.contains("visible"));
    }
}
