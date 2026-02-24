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
