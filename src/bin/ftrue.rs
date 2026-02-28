// ftrue — exit with status 0
//
// GNU true ignores ALL arguments and always exits 0.

fn main() {
    // true always exits 0, ignoring all arguments
}

#[cfg(test)]
mod tests {
    use std::process::Command;

    fn cmd() -> Command {
        let mut path = std::env::current_exe().unwrap();
        path.pop(); // remove test binary name
        path.pop(); // remove deps/
        path.push("ftrue");
        Command::new(path)
    }

    #[test]
    fn test_true_exit_code() {
        let output = cmd().output().unwrap();
        assert_eq!(output.status.code(), Some(0));
        assert!(output.stdout.is_empty());
    }

    #[test]
    fn test_true_ignores_args() {
        let output = cmd().args(["foo", "bar", "--baz"]).output().unwrap();
        assert_eq!(output.status.code(), Some(0));
    }
    #[test]
    fn test_true_matches_gnu() {
        let gnu = Command::new("true").output();
        if let Ok(gnu) = gnu {
            let ours = cmd().output().unwrap();
            assert_eq!(ours.status.code(), gnu.status.code(), "Exit code mismatch");
        }
    }

    #[test]
    fn test_true_no_stderr() {
        let output = cmd().output().unwrap();
        assert!(output.stderr.is_empty());
    }

    #[test]
    fn test_true_many_args() {
        let output = cmd()
            .args(["a", "b", "c", "d", "e", "--unknown", "-x", "--", "foo"])
            .output()
            .unwrap();
        assert_eq!(output.status.code(), Some(0));
        assert!(output.stdout.is_empty());
        assert!(output.stderr.is_empty());
    }

    #[test]
    fn test_true_dashdash() {
        let output = cmd().arg("--").output().unwrap();
        assert_eq!(output.status.code(), Some(0));
    }

    #[test]
    fn test_true_stdin_ignored() {
        use std::process::Stdio;
        let mut child = cmd()
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .unwrap();
        // Drop stdin immediately — true should still exit 0
        drop(child.stdin.take().unwrap());
        let output = child.wait_with_output().unwrap();
        assert_eq!(output.status.code(), Some(0));
        assert!(output.stdout.is_empty());
    }

    #[test]
    fn test_true_special_chars_args() {
        let output = cmd()
            .args(["--=", "-", "\n", "🎉", "hello world"])
            .output()
            .unwrap();
        assert_eq!(output.status.code(), Some(0));
    }
}
