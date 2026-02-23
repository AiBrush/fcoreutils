#[cfg(not(unix))]
fn main() {
    eprintln!("dir: only available on Unix");
    std::process::exit(1);
}

#[cfg(unix)]
fn main() {
    coreutils_rs::common::reset_sigpipe();
    coreutils_rs::ls::run_ls(coreutils_rs::ls::LsFlavor::Dir);
}
