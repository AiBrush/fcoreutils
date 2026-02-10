# Contributing to fcoreutils

Thank you for your interest in contributing! This guide will help you get started.

## Getting Started

1. Fork the repository
2. Clone your fork:
   ```bash
   git clone https://github.com/<your-username>/coreutils-rs.git
   cd coreutils-rs
   ```
3. Create a feature branch:
   ```bash
   git checkout -b feature/your-feature-name
   ```
4. Make your changes and ensure tests pass:
   ```bash
   cargo test --release
   cargo clippy -- -D warnings
   cargo fmt -- --check
   ```

## Development Setup

- **Rust**: Install via [rustup](https://rustup.rs/) (stable toolchain)
- **Build**: `cargo build --release`
- **Test**: `cargo test --release`
- **Bench**: `cargo bench --bench wc_benchmark`

## Project Structure

```
src/
  lib.rs           # Shared library (coreutils_rs)
  bin/
    fwc.rs         # wc replacement
    fcut.rs        # cut replacement
    fsha256sum.rs  # sha256sum replacement
    fmd5sum.rs     # md5sum replacement
    fb2sum.rs      # b2sum replacement
    fbase64.rs     # base64 replacement
    fsort.rs       # sort replacement
    ftr.rs         # tr replacement
    funiq.rs       # uniq replacement
    ftac.rs        # tac replacement
```

## Contribution Guidelines

### Code Style

- Run `cargo fmt` before committing
- All code must pass `cargo clippy -- -D warnings`
- Follow existing patterns in the codebase

### Performance

Performance is a core goal of this project. Contributions should:

- **Not regress performance** on existing commands
- **Target 10x speedup** over GNU equivalents where possible
- Use zero-copy I/O (`mmap`) for large files
- Leverage SIMD via `memchr` where applicable
- Include benchmark results for performance-sensitive changes

### GNU Compatibility

All tools must produce **byte-identical output** to their GNU coreutils counterparts. When implementing a new tool:

1. Study the GNU man page and info page for the command
2. Support all documented flags and options
3. Match output format exactly (column alignment, spacing, ordering)
4. Test edge cases (empty input, stdin, multiple files, error conditions)

### Testing

- Add unit tests for new functionality
- Add integration tests for CLI behavior
- Test against GNU output for compatibility
- Run the full test suite before submitting

### Commits

- Write clear, concise commit messages
- Use imperative mood ("Add feature" not "Added feature")
- Keep commits focused on a single change

## Pull Requests

1. Update documentation if your change affects user-facing behavior
2. Ensure CI passes (tests, clippy, formatting)
3. Fill out the PR template
4. Link any related issues

## Reporting Bugs

Use the [bug report template](https://github.com/AiBrush/coreutils-rs/issues/new?template=bug_report.yml) to file a bug. Include:

- Steps to reproduce
- Expected vs actual behavior
- GNU coreutils output for comparison (if applicable)

## Feature Requests

Use the [feature request template](https://github.com/AiBrush/coreutils-rs/issues/new?template=feature_request.yml).

## Security

For security vulnerabilities, please see our [Security Policy](SECURITY.md). **Do NOT open a public issue.**

## License

By contributing, you agree that your contributions will be licensed under the MIT License.
