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

    #[test]
    fn test_dir_multiple_files() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(dir.path().join("aaa"), "").unwrap();
        std::fs::write(dir.path().join("bbb"), "").unwrap();
        std::fs::write(dir.path().join("ccc"), "").unwrap();
        let output = cmd().arg(dir.path().to_str().unwrap()).output().unwrap();
        assert!(output.status.success());
        let stdout = String::from_utf8_lossy(&output.stdout);
        assert!(stdout.contains("aaa"));
        assert!(stdout.contains("bbb"));
        assert!(stdout.contains("ccc"));
    }

    #[test]
    fn test_dir_empty_directory() {
        let dir = tempfile::tempdir().unwrap();
        let output = cmd().arg(dir.path().to_str().unwrap()).output().unwrap();
        assert!(output.status.success());
    }

    #[test]
    fn test_dir_nonexistent() {
        let output = cmd().arg("/nonexistent/dir/xyz").output().unwrap();
        assert!(!output.status.success());
    }

    #[test]
    fn test_dir_no_hidden_by_default() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(dir.path().join(".hidden"), "").unwrap();
        std::fs::write(dir.path().join("visible"), "").unwrap();
        let output = cmd().arg(dir.path().to_str().unwrap()).output().unwrap();
        assert!(output.status.success());
        let stdout = String::from_utf8_lossy(&output.stdout);
        assert!(stdout.contains("visible"));
        assert!(!stdout.contains(".hidden"));
    }

    #[test]
    fn test_dir_show_all() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(dir.path().join(".hidden"), "").unwrap();
        let output = cmd()
            .args(["-a", dir.path().to_str().unwrap()])
            .output()
            .unwrap();
        assert!(output.status.success());
        let stdout = String::from_utf8_lossy(&output.stdout);
        assert!(stdout.contains(".hidden"));
    }

    #[test]
    fn test_dir_long_format() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(dir.path().join("file.txt"), "content").unwrap();
        let output = cmd()
            .args(["-l", dir.path().to_str().unwrap()])
            .output()
            .unwrap();
        assert!(output.status.success());
        let stdout = String::from_utf8_lossy(&output.stdout);
        assert!(stdout.contains("file.txt"));
    }

    #[test]
    fn test_dir_recursive() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::create_dir(dir.path().join("sub")).unwrap();
        std::fs::write(dir.path().join("sub").join("inner.txt"), "").unwrap();
        let output = cmd()
            .args(["-R", dir.path().to_str().unwrap()])
            .output()
            .unwrap();
        assert!(output.status.success());
        let stdout = String::from_utf8_lossy(&output.stdout);
        assert!(stdout.contains("inner.txt"));
    }
}
