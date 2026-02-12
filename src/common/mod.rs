pub mod io;

/// Get the GNU-compatible tool name by stripping the 'f' prefix.
/// e.g., "fmd5sum" -> "md5sum", "fcut" -> "cut"
#[inline]
pub fn gnu_name(binary_name: &str) -> &str {
    binary_name.strip_prefix('f').unwrap_or(binary_name)
}
