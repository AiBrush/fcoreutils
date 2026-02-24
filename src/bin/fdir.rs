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
