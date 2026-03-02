use std::cell::RefCell;
use std::fs::File;
use std::io::{self, BufRead, Read, Write};
use std::path::Path;

use std::sync::atomic::AtomicUsize;
#[cfg(target_os = "linux")]
use std::sync::atomic::{AtomicBool, Ordering};

use digest::Digest;
use md5::Md5;

// ── OpenSSL dynamic loading for SHA-384/512 (Linux only) ──────────────
// GNU coreutils links against OpenSSL which has AVX-512 optimized SHA-512 assembly.
// We dynamically load libcrypto at runtime via dlopen/dlsym to get the same
// performance without requiring a compile-time dependency on libssl-dev.
// If libcrypto is unavailable, we fall back to ring (BoringSSL AVX2 assembly).
#[cfg(target_os = "linux")]
mod openssl_sha512 {
    use std::ffi::CStr;
    use std::io;
    use std::ptr;
    use std::sync::OnceLock;

    // OpenSSL EVP types (opaque pointers)
    type EvpMdCtx = *mut libc::c_void;
    type EvpMd = *const libc::c_void;
    type Engine = *const libc::c_void;

    // Function pointer types matching OpenSSL's EVP API
    type FnEvpSha384 = unsafe extern "C" fn() -> EvpMd;
    type FnEvpSha512 = unsafe extern "C" fn() -> EvpMd;
    type FnEvpMdCtxNew = unsafe extern "C" fn() -> EvpMdCtx;
    type FnEvpDigestInitEx = unsafe extern "C" fn(EvpMdCtx, EvpMd, Engine) -> libc::c_int;
    type FnEvpDigestUpdate =
        unsafe extern "C" fn(EvpMdCtx, *const libc::c_void, libc::size_t) -> libc::c_int;
    type FnEvpDigestFinalEx =
        unsafe extern "C" fn(EvpMdCtx, *mut u8, *mut libc::c_uint) -> libc::c_int;
    type FnEvpMdCtxFree = unsafe extern "C" fn(EvpMdCtx);

    struct OpenSslFns {
        evp_sha384: FnEvpSha384,
        evp_sha512: FnEvpSha512,
        evp_md_ctx_new: FnEvpMdCtxNew,
        evp_digest_init_ex: FnEvpDigestInitEx,
        evp_digest_update: FnEvpDigestUpdate,
        evp_digest_final_ex: FnEvpDigestFinalEx,
        evp_md_ctx_free: FnEvpMdCtxFree,
        _handle: *mut libc::c_void, // kept alive so symbols stay valid
    }

    // SAFETY: The function pointers are valid for the lifetime of the process
    // (dlopen handle is never closed). The pointers themselves are immutable
    // after initialization via OnceLock.
    unsafe impl Send for OpenSslFns {}
    unsafe impl Sync for OpenSslFns {}

    /// Cached OpenSSL function pointers. Initialized once on first use.
    /// `None` inside means libcrypto was not found or symbols were missing.
    static FNS: OnceLock<Option<OpenSslFns>> = OnceLock::new();

    fn dlsym_checked(handle: *mut libc::c_void, name: &CStr) -> Option<*mut libc::c_void> {
        let ptr = unsafe { libc::dlsym(handle, name.as_ptr()) };
        if ptr.is_null() { None } else { Some(ptr) }
    }

    fn try_load() -> Option<OpenSslFns> {
        // Try OpenSSL 3.x first, then 1.1.x
        let handle = unsafe {
            let h = libc::dlopen(
                c"libcrypto.so.3".as_ptr(),
                libc::RTLD_LAZY | libc::RTLD_LOCAL,
            );
            if h.is_null() {
                let h = libc::dlopen(
                    c"libcrypto.so.1.1".as_ptr(),
                    libc::RTLD_LAZY | libc::RTLD_LOCAL,
                );
                if h.is_null() {
                    return None;
                }
                h
            } else {
                h
            }
        };

        unsafe {
            let evp_sha384: FnEvpSha384 =
                std::mem::transmute(dlsym_checked(handle, c"EVP_sha384")?);
            let evp_sha512: FnEvpSha512 =
                std::mem::transmute(dlsym_checked(handle, c"EVP_sha512")?);
            let evp_md_ctx_new: FnEvpMdCtxNew =
                std::mem::transmute(dlsym_checked(handle, c"EVP_MD_CTX_new")?);
            let evp_digest_init_ex: FnEvpDigestInitEx =
                std::mem::transmute(dlsym_checked(handle, c"EVP_DigestInit_ex")?);
            let evp_digest_update: FnEvpDigestUpdate =
                std::mem::transmute(dlsym_checked(handle, c"EVP_DigestUpdate")?);
            let evp_digest_final_ex: FnEvpDigestFinalEx =
                std::mem::transmute(dlsym_checked(handle, c"EVP_DigestFinal_ex")?);
            let evp_md_ctx_free: FnEvpMdCtxFree =
                std::mem::transmute(dlsym_checked(handle, c"EVP_MD_CTX_free")?);

            Some(OpenSslFns {
                evp_sha384,
                evp_sha512,
                evp_md_ctx_new,
                evp_digest_init_ex,
                evp_digest_update,
                evp_digest_final_ex,
                evp_md_ctx_free,
                _handle: handle,
            })
        }
    }

    fn get_fns() -> Option<&'static OpenSslFns> {
        FNS.get_or_init(try_load).as_ref()
    }

    /// Returns true if OpenSSL's libcrypto is available for SHA-384/512.
    pub fn is_available() -> bool {
        get_fns().is_some()
    }

    /// RAII wrapper for EVP_MD_CTX that frees on drop.
    struct EvpCtx {
        ctx: EvpMdCtx,
        free_fn: FnEvpMdCtxFree,
    }

    impl Drop for EvpCtx {
        fn drop(&mut self) {
            if !self.ctx.is_null() {
                unsafe {
                    (self.free_fn)(self.ctx);
                }
            }
        }
    }

    /// Which SHA-2 variant to use.
    #[derive(Clone, Copy)]
    pub enum Sha2Variant {
        Sha384,
        Sha512,
    }

    impl Sha2Variant {
        fn digest_len(self) -> usize {
            match self {
                Sha2Variant::Sha384 => 48,
                Sha2Variant::Sha512 => 64,
            }
        }
    }

    /// Single-shot hash of a byte slice using OpenSSL EVP.
    pub fn hash_bytes(variant: Sha2Variant, data: &[u8]) -> io::Result<Vec<u8>> {
        let fns = get_fns().ok_or_else(|| io::Error::other("OpenSSL not available"))?;

        unsafe {
            let md = match variant {
                Sha2Variant::Sha384 => (fns.evp_sha384)(),
                Sha2Variant::Sha512 => (fns.evp_sha512)(),
            };
            if md.is_null() {
                return Err(io::Error::other("EVP_sha* returned null"));
            }

            let ctx = (fns.evp_md_ctx_new)();
            if ctx.is_null() {
                return Err(io::Error::other("EVP_MD_CTX_new failed"));
            }
            let _guard = EvpCtx {
                ctx,
                free_fn: fns.evp_md_ctx_free,
            };

            if (fns.evp_digest_init_ex)(ctx, md, ptr::null()) != 1 {
                return Err(io::Error::other("EVP_DigestInit_ex failed"));
            }
            if !data.is_empty()
                && (fns.evp_digest_update)(ctx, data.as_ptr() as *const libc::c_void, data.len())
                    != 1
            {
                return Err(io::Error::other("EVP_DigestUpdate failed"));
            }

            let mut out = vec![0u8; variant.digest_len()];
            let mut out_len: libc::c_uint = 0;
            if (fns.evp_digest_final_ex)(ctx, out.as_mut_ptr(), &mut out_len) != 1 {
                return Err(io::Error::other("EVP_DigestFinal_ex failed"));
            }
            out.truncate(out_len as usize);
            Ok(out)
        }
    }

    /// Streaming hash: create context, feed chunks, finalize.
    pub fn hash_reader(
        variant: Sha2Variant,
        mut reader: impl std::io::Read,
    ) -> io::Result<Vec<u8>> {
        let fns = get_fns().ok_or_else(|| io::Error::other("OpenSSL not available"))?;

        unsafe {
            let md = match variant {
                Sha2Variant::Sha384 => (fns.evp_sha384)(),
                Sha2Variant::Sha512 => (fns.evp_sha512)(),
            };
            if md.is_null() {
                return Err(io::Error::other("EVP_sha* returned null"));
            }

            let ctx = (fns.evp_md_ctx_new)();
            if ctx.is_null() {
                return Err(io::Error::other("EVP_MD_CTX_new failed"));
            }
            let _guard = EvpCtx {
                ctx,
                free_fn: fns.evp_md_ctx_free,
            };

            if (fns.evp_digest_init_ex)(ctx, md, ptr::null()) != 1 {
                return Err(io::Error::other("EVP_DigestInit_ex failed"));
            }

            super::STREAM_BUF.with(|cell| {
                let mut buf = cell.borrow_mut();
                super::ensure_stream_buf(&mut buf);
                loop {
                    let n = super::read_full(&mut reader, &mut buf)?;
                    if n == 0 {
                        break;
                    }
                    if (fns.evp_digest_update)(ctx, buf[..n].as_ptr() as *const libc::c_void, n)
                        != 1
                    {
                        return Err(io::Error::other("EVP_DigestUpdate failed"));
                    }
                }
                Ok(())
            })?;

            let mut out = vec![0u8; variant.digest_len()];
            let mut out_len: libc::c_uint = 0;
            if (fns.evp_digest_final_ex)(ctx, out.as_mut_ptr(), &mut out_len) != 1 {
                return Err(io::Error::other("EVP_DigestFinal_ex failed"));
            }
            out.truncate(out_len as usize);
            Ok(out)
        }
    }

    /// Streaming hash with a prefix already read into memory.
    pub fn hash_reader_with_prefix(
        variant: Sha2Variant,
        prefix: &[u8],
        mut reader: impl std::io::Read,
    ) -> io::Result<Vec<u8>> {
        let fns = get_fns().ok_or_else(|| io::Error::other("OpenSSL not available"))?;

        unsafe {
            let md = match variant {
                Sha2Variant::Sha384 => (fns.evp_sha384)(),
                Sha2Variant::Sha512 => (fns.evp_sha512)(),
            };
            if md.is_null() {
                return Err(io::Error::other("EVP_sha* returned null"));
            }

            let ctx = (fns.evp_md_ctx_new)();
            if ctx.is_null() {
                return Err(io::Error::other("EVP_MD_CTX_new failed"));
            }
            let _guard = EvpCtx {
                ctx,
                free_fn: fns.evp_md_ctx_free,
            };

            if (fns.evp_digest_init_ex)(ctx, md, ptr::null()) != 1 {
                return Err(io::Error::other("EVP_DigestInit_ex failed"));
            }

            // Feed prefix
            if !prefix.is_empty()
                && (fns.evp_digest_update)(
                    ctx,
                    prefix.as_ptr() as *const libc::c_void,
                    prefix.len(),
                ) != 1
            {
                return Err(io::Error::other("EVP_DigestUpdate failed"));
            }

            // Stream rest
            super::STREAM_BUF.with(|cell| {
                let mut buf = cell.borrow_mut();
                super::ensure_stream_buf(&mut buf);
                loop {
                    let n = super::read_full(&mut reader, &mut buf)?;
                    if n == 0 {
                        break;
                    }
                    if (fns.evp_digest_update)(ctx, buf[..n].as_ptr() as *const libc::c_void, n)
                        != 1
                    {
                        return Err(io::Error::other("EVP_DigestUpdate failed"));
                    }
                }
                Ok(())
            })?;

            let mut out = vec![0u8; variant.digest_len()];
            let mut out_len: libc::c_uint = 0;
            if (fns.evp_digest_final_ex)(ctx, out.as_mut_ptr(), &mut out_len) != 1 {
                return Err(io::Error::other("EVP_DigestFinal_ex failed"));
            }
            out.truncate(out_len as usize);
            Ok(out)
        }
    }

    /// Pipelined hash for the double-buffered reader thread path.
    /// Returns raw digest bytes for the caller to hex-encode.
    pub fn hash_pipelined(
        variant: Sha2Variant,
        rx: &std::sync::mpsc::Receiver<(Vec<u8>, usize)>,
        buf_tx: &std::sync::mpsc::SyncSender<Vec<u8>>,
    ) -> io::Result<Vec<u8>> {
        let fns = get_fns().ok_or_else(|| io::Error::other("OpenSSL not available"))?;

        unsafe {
            let md = match variant {
                Sha2Variant::Sha384 => (fns.evp_sha384)(),
                Sha2Variant::Sha512 => (fns.evp_sha512)(),
            };
            if md.is_null() {
                return Err(io::Error::other("EVP_sha* returned null"));
            }

            let ctx = (fns.evp_md_ctx_new)();
            if ctx.is_null() {
                return Err(io::Error::other("EVP_MD_CTX_new failed"));
            }
            let _guard = EvpCtx {
                ctx,
                free_fn: fns.evp_md_ctx_free,
            };

            if (fns.evp_digest_init_ex)(ctx, md, ptr::null()) != 1 {
                return Err(io::Error::other("EVP_DigestInit_ex failed"));
            }

            while let Ok((buf, n)) = rx.recv() {
                if (fns.evp_digest_update)(ctx, buf[..n].as_ptr() as *const libc::c_void, n) != 1 {
                    let _ = buf_tx.send(buf);
                    return Err(io::Error::other("EVP_DigestUpdate failed"));
                }
                let _ = buf_tx.send(buf);
            }

            let mut out = vec![0u8; variant.digest_len()];
            let mut out_len: libc::c_uint = 0;
            if (fns.evp_digest_final_ex)(ctx, out.as_mut_ptr(), &mut out_len) != 1 {
                return Err(io::Error::other("EVP_DigestFinal_ex failed"));
            }
            out.truncate(out_len as usize);
            Ok(out)
        }
    }
}

/// Supported hash algorithms.
#[derive(Debug, Clone, Copy)]
pub enum HashAlgorithm {
    Sha1,
    Sha224,
    Sha256,
    Sha384,
    Sha512,
    Md5,
    Blake2b,
}

impl HashAlgorithm {
    pub fn name(self) -> &'static str {
        match self {
            HashAlgorithm::Sha1 => "SHA1",
            HashAlgorithm::Sha224 => "SHA224",
            HashAlgorithm::Sha256 => "SHA256",
            HashAlgorithm::Sha384 => "SHA384",
            HashAlgorithm::Sha512 => "SHA512",
            HashAlgorithm::Md5 => "MD5",
            HashAlgorithm::Blake2b => "BLAKE2b",
        }
    }
}

// ── Generic hash helpers ────────────────────────────────────────────

/// Single-shot hash using the Digest trait.
fn hash_digest<D: Digest>(data: &[u8]) -> String {
    hex_encode(&D::digest(data))
}

/// Streaming hash using thread-local buffer via the Digest trait.
fn hash_reader_impl<D: Digest>(mut reader: impl Read) -> io::Result<String> {
    STREAM_BUF.with(|cell| {
        let mut buf = cell.borrow_mut();
        ensure_stream_buf(&mut buf);
        let mut hasher = D::new();
        loop {
            let n = read_full(&mut reader, &mut buf)?;
            if n == 0 {
                break;
            }
            hasher.update(&buf[..n]);
        }
        Ok(hex_encode(&hasher.finalize()))
    })
}

// ── Public hashing API ──────────────────────────────────────────────

/// Buffer size for streaming hash I/O.
/// 128KB matches GNU coreutils' buffer size (BUFSIZE=131072), which works well with kernel readahead.
/// Many small reads allow the kernel to pipeline I/O efficiently, reducing latency
/// vs fewer large reads that stall waiting for the full buffer to fill.
const HASH_READ_BUF: usize = 131072;

// Thread-local reusable buffer for streaming hash I/O.
// Allocated LAZILY (only on first streaming-hash call) to avoid 8MB cost for
// small-file-only workloads (e.g., "sha256sum *.txt" where every file is <1MB).
thread_local! {
    static STREAM_BUF: RefCell<Vec<u8>> = const { RefCell::new(Vec::new()) };
}

/// Ensure the streaming buffer is at least HASH_READ_BUF bytes.
/// Called only on the streaming path, so small-file workloads never allocate 8MB.
#[inline]
fn ensure_stream_buf(buf: &mut Vec<u8>) {
    if buf.len() < HASH_READ_BUF {
        buf.resize(HASH_READ_BUF, 0);
    }
}

// ── Ring-accelerated hash functions (non-Apple targets) ───────────────
// ring provides BoringSSL assembly with optimized SHA-512/384/256/1 for x86-64/aarch64.

/// Single-shot hash using ring::digest (non-Apple).
#[cfg(not(target_vendor = "apple"))]
#[inline]
fn ring_hash_bytes(algo: &'static ring::digest::Algorithm, data: &[u8]) -> io::Result<String> {
    Ok(hex_encode(ring::digest::digest(algo, data).as_ref()))
}

/// Streaming hash using ring::digest::Context (non-Apple).
#[cfg(not(target_vendor = "apple"))]
fn ring_hash_reader(
    algo: &'static ring::digest::Algorithm,
    mut reader: impl Read,
) -> io::Result<String> {
    STREAM_BUF.with(|cell| {
        let mut buf = cell.borrow_mut();
        ensure_stream_buf(&mut buf);
        let mut ctx = ring::digest::Context::new(algo);
        loop {
            let n = read_full(&mut reader, &mut buf)?;
            if n == 0 {
                break;
            }
            ctx.update(&buf[..n]);
        }
        Ok(hex_encode(ctx.finish().as_ref()))
    })
}

// ── SHA-256 ───────────────────────────────────────────────────────────
// Linux/Apple: sha2 crate (cpufeatures runtime SHA-NI dispatch, no startup overhead)
// Windows/FreeBSD: ring (BoringSSL assembly)

#[cfg(any(target_os = "linux", target_vendor = "apple"))]
fn sha256_bytes(data: &[u8]) -> io::Result<String> {
    Ok(hash_digest::<sha2::Sha256>(data))
}

#[cfg(all(not(target_os = "linux"), not(target_vendor = "apple")))]
fn sha256_bytes(data: &[u8]) -> io::Result<String> {
    ring_hash_bytes(&ring::digest::SHA256, data)
}

#[cfg(any(target_os = "linux", target_vendor = "apple"))]
fn sha256_reader(reader: impl Read) -> io::Result<String> {
    hash_reader_impl::<sha2::Sha256>(reader)
}

#[cfg(all(not(target_os = "linux"), not(target_vendor = "apple")))]
fn sha256_reader(reader: impl Read) -> io::Result<String> {
    ring_hash_reader(&ring::digest::SHA256, reader)
}

// ── SHA-1 ─────────────────────────────────────────────────────────────
// ring's BoringSSL assembly for SHA-1 on non-Apple targets.

#[cfg(target_vendor = "apple")]
fn sha1_bytes(data: &[u8]) -> io::Result<String> {
    Ok(hash_digest::<sha1::Sha1>(data))
}

#[cfg(not(target_vendor = "apple"))]
fn sha1_bytes(data: &[u8]) -> io::Result<String> {
    ring_hash_bytes(&ring::digest::SHA1_FOR_LEGACY_USE_ONLY, data)
}

#[cfg(target_vendor = "apple")]
fn sha1_reader(reader: impl Read) -> io::Result<String> {
    hash_reader_impl::<sha1::Sha1>(reader)
}

#[cfg(not(target_vendor = "apple"))]
fn sha1_reader(reader: impl Read) -> io::Result<String> {
    ring_hash_reader(&ring::digest::SHA1_FOR_LEGACY_USE_ONLY, reader)
}

// ── SHA-224 ───────────────────────────────────────────────────────────
// ring does not support SHA-224. Use sha2 crate on all platforms.

fn sha224_bytes(data: &[u8]) -> io::Result<String> {
    Ok(hash_digest::<sha2::Sha224>(data))
}

fn sha224_reader(reader: impl Read) -> io::Result<String> {
    hash_reader_impl::<sha2::Sha224>(reader)
}

// ── SHA-384 ───────────────────────────────────────────────────────────
// Linux: OpenSSL libcrypto (AVX-512 optimized) via dlopen, fallback to ring (AVX2).
// Apple: sha2 crate. Other: ring (BoringSSL assembly).

#[cfg(target_vendor = "apple")]
fn sha384_bytes(data: &[u8]) -> io::Result<String> {
    Ok(hash_digest::<sha2::Sha384>(data))
}

#[cfg(target_os = "linux")]
fn sha384_bytes(data: &[u8]) -> io::Result<String> {
    if openssl_sha512::is_available() {
        let digest = openssl_sha512::hash_bytes(openssl_sha512::Sha2Variant::Sha384, data)?;
        return Ok(hex_encode(&digest));
    }
    ring_hash_bytes(&ring::digest::SHA384, data)
}

#[cfg(all(not(target_os = "linux"), not(target_vendor = "apple")))]
fn sha384_bytes(data: &[u8]) -> io::Result<String> {
    ring_hash_bytes(&ring::digest::SHA384, data)
}

#[cfg(target_vendor = "apple")]
fn sha384_reader(reader: impl Read) -> io::Result<String> {
    hash_reader_impl::<sha2::Sha384>(reader)
}

#[cfg(target_os = "linux")]
fn sha384_reader(reader: impl Read) -> io::Result<String> {
    if openssl_sha512::is_available() {
        let digest = openssl_sha512::hash_reader(openssl_sha512::Sha2Variant::Sha384, reader)?;
        return Ok(hex_encode(&digest));
    }
    ring_hash_reader(&ring::digest::SHA384, reader)
}

#[cfg(all(not(target_os = "linux"), not(target_vendor = "apple")))]
fn sha384_reader(reader: impl Read) -> io::Result<String> {
    ring_hash_reader(&ring::digest::SHA384, reader)
}

// ── SHA-512 ───────────────────────────────────────────────────────────
// Linux: OpenSSL libcrypto (AVX-512 optimized) via dlopen, fallback to ring (AVX2).
// Apple: sha2 crate. Other: ring (BoringSSL assembly).

#[cfg(target_vendor = "apple")]
fn sha512_bytes(data: &[u8]) -> io::Result<String> {
    Ok(hash_digest::<sha2::Sha512>(data))
}

#[cfg(target_os = "linux")]
fn sha512_bytes(data: &[u8]) -> io::Result<String> {
    if openssl_sha512::is_available() {
        let digest = openssl_sha512::hash_bytes(openssl_sha512::Sha2Variant::Sha512, data)?;
        return Ok(hex_encode(&digest));
    }
    ring_hash_bytes(&ring::digest::SHA512, data)
}

#[cfg(all(not(target_os = "linux"), not(target_vendor = "apple")))]
fn sha512_bytes(data: &[u8]) -> io::Result<String> {
    ring_hash_bytes(&ring::digest::SHA512, data)
}

#[cfg(target_vendor = "apple")]
fn sha512_reader(reader: impl Read) -> io::Result<String> {
    hash_reader_impl::<sha2::Sha512>(reader)
}

#[cfg(target_os = "linux")]
fn sha512_reader(reader: impl Read) -> io::Result<String> {
    if openssl_sha512::is_available() {
        let digest = openssl_sha512::hash_reader(openssl_sha512::Sha2Variant::Sha512, reader)?;
        return Ok(hex_encode(&digest));
    }
    ring_hash_reader(&ring::digest::SHA512, reader)
}

#[cfg(all(not(target_os = "linux"), not(target_vendor = "apple")))]
fn sha512_reader(reader: impl Read) -> io::Result<String> {
    ring_hash_reader(&ring::digest::SHA512, reader)
}

/// Compute hash of a byte slice directly (zero-copy fast path).
/// Returns an error if the underlying crypto library rejects the algorithm.
pub fn hash_bytes(algo: HashAlgorithm, data: &[u8]) -> io::Result<String> {
    match algo {
        HashAlgorithm::Sha1 => sha1_bytes(data),
        HashAlgorithm::Sha224 => sha224_bytes(data),
        HashAlgorithm::Sha256 => sha256_bytes(data),
        HashAlgorithm::Sha384 => sha384_bytes(data),
        HashAlgorithm::Sha512 => sha512_bytes(data),
        HashAlgorithm::Md5 => md5_bytes(data),
        HashAlgorithm::Blake2b => {
            let hash = blake2b_simd::blake2b(data);
            Ok(hex_encode(hash.as_bytes()))
        }
    }
}

/// Hash data and write hex result directly into an output buffer.
/// Returns the number of hex bytes written. Avoids String allocation
/// on the critical single-file fast path.
/// `out` must be at least 128 bytes for BLAKE2b/SHA512 (64 * 2), 64 for SHA256, 32 for MD5, etc.
#[cfg(target_os = "linux")]
pub fn hash_bytes_to_buf(algo: HashAlgorithm, data: &[u8], out: &mut [u8]) -> io::Result<usize> {
    match algo {
        HashAlgorithm::Md5 => {
            let digest = Md5::digest(data);
            hex_encode_to_slice(&digest, out);
            Ok(32)
        }
        HashAlgorithm::Sha1 => {
            let digest = ring::digest::digest(&ring::digest::SHA1_FOR_LEGACY_USE_ONLY, data);
            hex_encode_to_slice(digest.as_ref(), out);
            Ok(40)
        }
        HashAlgorithm::Sha224 => {
            let digest = sha2::Sha224::digest(data);
            hex_encode_to_slice(&digest, out);
            Ok(56)
        }
        HashAlgorithm::Sha256 => {
            let digest = sha2::Sha256::digest(data);
            hex_encode_to_slice(&digest, out);
            Ok(64)
        }
        HashAlgorithm::Sha384 => {
            if openssl_sha512::is_available() {
                let digest = openssl_sha512::hash_bytes(openssl_sha512::Sha2Variant::Sha384, data)?;
                hex_encode_to_slice(&digest, out);
                return Ok(96);
            }
            let digest = ring::digest::digest(&ring::digest::SHA384, data);
            hex_encode_to_slice(digest.as_ref(), out);
            Ok(96)
        }
        HashAlgorithm::Sha512 => {
            if openssl_sha512::is_available() {
                let digest = openssl_sha512::hash_bytes(openssl_sha512::Sha2Variant::Sha512, data)?;
                hex_encode_to_slice(&digest, out);
                return Ok(128);
            }
            let digest = ring::digest::digest(&ring::digest::SHA512, data);
            hex_encode_to_slice(digest.as_ref(), out);
            Ok(128)
        }
        HashAlgorithm::Blake2b => {
            let hash = blake2b_simd::blake2b(data);
            let bytes = hash.as_bytes();
            hex_encode_to_slice(bytes, out);
            Ok(bytes.len() * 2)
        }
    }
}

/// Hash a single file using raw syscalls and write hex directly to output buffer.
/// Returns number of hex bytes written.
/// This is the absolute minimum-overhead path for single-file hashing:
/// raw open + fstat + read + hash + hex encode, with zero String allocation.
#[cfg(target_os = "linux")]
pub fn hash_file_raw_to_buf(algo: HashAlgorithm, path: &Path, out: &mut [u8]) -> io::Result<usize> {
    use std::os::unix::ffi::OsStrExt;

    let path_bytes = path.as_os_str().as_bytes();
    let c_path = std::ffi::CString::new(path_bytes)
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "path contains null byte"))?;

    let mut flags = libc::O_RDONLY | libc::O_CLOEXEC;
    if NOATIME_SUPPORTED.load(Ordering::Relaxed) {
        flags |= libc::O_NOATIME;
    }

    let fd = unsafe { libc::open(c_path.as_ptr(), flags) };
    if fd < 0 {
        let err = io::Error::last_os_error();
        if err.raw_os_error() == Some(libc::EPERM) && flags & libc::O_NOATIME != 0 {
            NOATIME_SUPPORTED.store(false, Ordering::Relaxed);
            let fd2 = unsafe { libc::open(c_path.as_ptr(), libc::O_RDONLY | libc::O_CLOEXEC) };
            if fd2 < 0 {
                return Err(io::Error::last_os_error());
            }
            return hash_from_raw_fd_to_buf(algo, fd2, out);
        }
        return Err(err);
    }
    hash_from_raw_fd_to_buf(algo, fd, out)
}

/// Hash from raw fd and write hex directly to output buffer.
/// For tiny files (<8KB), the entire path is raw syscalls + stack buffer — zero heap.
/// For larger files, falls back to hash_file_raw() which allocates a String.
#[cfg(target_os = "linux")]
fn hash_from_raw_fd_to_buf(algo: HashAlgorithm, fd: i32, out: &mut [u8]) -> io::Result<usize> {
    let mut stat: libc::stat = unsafe { std::mem::zeroed() };
    if unsafe { libc::fstat(fd, &mut stat) } != 0 {
        let err = io::Error::last_os_error();
        unsafe {
            libc::close(fd);
        }
        return Err(err);
    }
    let size = stat.st_size as u64;
    let is_regular = (stat.st_mode & libc::S_IFMT) == libc::S_IFREG;

    // Empty regular file
    if is_regular && size == 0 {
        unsafe {
            libc::close(fd);
        }
        return hash_bytes_to_buf(algo, &[], out);
    }

    // Tiny files (<8KB): fully raw path — zero heap allocation
    if is_regular && size < TINY_FILE_LIMIT {
        let mut buf = [0u8; 8192];
        let mut total = 0usize;
        while total < size as usize {
            let n = unsafe {
                libc::read(
                    fd,
                    buf[total..].as_mut_ptr() as *mut libc::c_void,
                    (size as usize) - total,
                )
            };
            if n < 0 {
                let err = io::Error::last_os_error();
                if err.kind() == io::ErrorKind::Interrupted {
                    continue;
                }
                unsafe {
                    libc::close(fd);
                }
                return Err(err);
            }
            if n == 0 {
                break;
            }
            total += n as usize;
        }
        unsafe {
            libc::close(fd);
        }
        return hash_bytes_to_buf(algo, &buf[..total], out);
    }

    // Larger files: fall back to hash_from_raw_fd which returns a String,
    // then copy the hex into out.
    use std::os::unix::io::FromRawFd;
    let file = unsafe { File::from_raw_fd(fd) };
    let hash_str = if is_regular && size > 0 {
        hash_regular_file(algo, file, size)?
    } else {
        hash_reader(algo, file)?
    };
    let hex_bytes = hash_str.as_bytes();
    out[..hex_bytes.len()].copy_from_slice(hex_bytes);
    Ok(hex_bytes.len())
}

// ── MD5 ─────────────────────────────────────────────────────────────
// All platforms: md-5 crate (cpufeatures runtime dispatch on supported CPUs)

fn md5_bytes(data: &[u8]) -> io::Result<String> {
    Ok(hash_digest::<Md5>(data))
}

fn md5_reader(reader: impl Read) -> io::Result<String> {
    hash_reader_impl::<Md5>(reader)
}

/// Compute hash of data from a reader, returning hex string.
pub fn hash_reader<R: Read>(algo: HashAlgorithm, reader: R) -> io::Result<String> {
    match algo {
        HashAlgorithm::Sha1 => sha1_reader(reader),
        HashAlgorithm::Sha224 => sha224_reader(reader),
        HashAlgorithm::Sha256 => sha256_reader(reader),
        HashAlgorithm::Sha384 => sha384_reader(reader),
        HashAlgorithm::Sha512 => sha512_reader(reader),
        HashAlgorithm::Md5 => md5_reader(reader),
        HashAlgorithm::Blake2b => blake2b_hash_reader(reader, 64),
    }
}

/// Track whether O_NOATIME is supported to avoid repeated failed open() attempts.
/// After the first EPERM, we never try O_NOATIME again (saves one syscall per file).
#[cfg(target_os = "linux")]
static NOATIME_SUPPORTED: AtomicBool = AtomicBool::new(true);

/// Open a file with O_NOATIME on Linux to avoid atime update overhead.
/// Caches whether O_NOATIME works to avoid double-open on every file.
#[cfg(target_os = "linux")]
fn open_noatime(path: &Path) -> io::Result<File> {
    use std::os::unix::fs::OpenOptionsExt;
    if NOATIME_SUPPORTED.load(Ordering::Relaxed) {
        match std::fs::OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_NOATIME)
            .open(path)
        {
            Ok(f) => return Ok(f),
            Err(ref e) if e.raw_os_error() == Some(libc::EPERM) => {
                // O_NOATIME requires file ownership or CAP_FOWNER — disable globally
                NOATIME_SUPPORTED.store(false, Ordering::Relaxed);
            }
            Err(e) => return Err(e), // Real error, propagate
        }
    }
    File::open(path)
}

#[cfg(not(target_os = "linux"))]
fn open_noatime(path: &Path) -> io::Result<File> {
    File::open(path)
}

/// Open a file and get its metadata in one step.
/// On Linux uses fstat directly on the fd to avoid an extra syscall layer.
#[cfg(target_os = "linux")]
#[inline]
fn open_and_stat(path: &Path) -> io::Result<(File, u64, bool)> {
    let file = open_noatime(path)?;
    let fd = {
        use std::os::unix::io::AsRawFd;
        file.as_raw_fd()
    };
    let mut stat: libc::stat = unsafe { std::mem::zeroed() };
    if unsafe { libc::fstat(fd, &mut stat) } != 0 {
        return Err(io::Error::last_os_error());
    }
    let is_regular = (stat.st_mode & libc::S_IFMT) == libc::S_IFREG;
    let size = stat.st_size as u64;
    Ok((file, size, is_regular))
}

#[cfg(not(target_os = "linux"))]
#[inline]
fn open_and_stat(path: &Path) -> io::Result<(File, u64, bool)> {
    let file = open_noatime(path)?;
    let metadata = file.metadata()?;
    Ok((file, metadata.len(), metadata.file_type().is_file()))
}

/// Minimum file size to issue fadvise hint (1MB).
/// For small files, the syscall overhead exceeds the readahead benefit.
#[cfg(target_os = "linux")]
const FADVISE_MIN_SIZE: u64 = 1024 * 1024;

/// Maximum file size for single-read hash optimization.
/// Files up to this size are read entirely into a thread-local buffer and hashed
/// with single-shot hash. This avoids mmap/munmap overhead (~100µs each) and
/// MAP_POPULATE page faults (~300ns/page). The thread-local buffer is reused
/// across files in sequential mode, saving re-allocation.
/// 16MB covers typical benchmark files (10MB) while keeping memory usage bounded.
const SMALL_FILE_LIMIT: u64 = 16 * 1024 * 1024;

/// Threshold for tiny files that can be read into a stack buffer.
/// Below this size, we use a stack-allocated buffer + single read() syscall,
/// completely avoiding any heap allocation for the data path.
const TINY_FILE_LIMIT: u64 = 8 * 1024;

// Thread-local reusable buffer for single-read hash.
// Grows lazily up to SMALL_FILE_LIMIT (16MB). Initial 64KB allocation
// handles tiny files; larger files trigger one grow that persists for reuse.
thread_local! {
    static SMALL_FILE_BUF: RefCell<Vec<u8>> = RefCell::new(Vec::with_capacity(64 * 1024));
}

/// Optimized hash for large files (>=16MB) on Linux.
/// Hash large files (>=16MB) using streaming I/O with fadvise + ring Context.
/// Uses sequential fadvise hint for kernel readahead, then streams through
/// hash context in large chunks. For large files (>64MB), uses double-buffered
/// reader thread to overlap I/O and hashing.
#[cfg(target_os = "linux")]
fn hash_file_pipelined(algo: HashAlgorithm, file: File, file_size: u64) -> io::Result<String> {
    // For very large files, double-buffered reader thread overlaps I/O and CPU.
    // For medium files, single-thread streaming is faster (avoids thread overhead).
    if file_size >= 64 * 1024 * 1024 {
        hash_file_pipelined_read(algo, file, file_size)
    } else {
        hash_file_streaming(algo, file, file_size)
    }
}

/// Simple single-thread streaming hash with fadvise.
/// Optimal for files 16-64MB where thread overhead exceeds I/O overlap benefit.
#[cfg(target_os = "linux")]
fn hash_file_streaming(algo: HashAlgorithm, file: File, file_size: u64) -> io::Result<String> {
    use std::os::unix::io::AsRawFd;

    let _ = unsafe {
        libc::posix_fadvise(
            file.as_raw_fd(),
            0,
            file_size as i64,
            libc::POSIX_FADV_SEQUENTIAL,
        )
    };

    hash_reader(algo, file)
}

/// Streaming fallback for large files when mmap is unavailable.
/// Uses double-buffered reader thread with fadvise hints.
/// Fixed: uses blocking recv() to eliminate triple-buffer allocation bug.
#[cfg(target_os = "linux")]
fn hash_file_pipelined_read(
    algo: HashAlgorithm,
    mut file: File,
    file_size: u64,
) -> io::Result<String> {
    use std::os::unix::io::AsRawFd;

    const PIPE_BUF_SIZE: usize = 4 * 1024 * 1024; // 4MB per buffer

    let _ = unsafe {
        libc::posix_fadvise(
            file.as_raw_fd(),
            0,
            file_size as i64,
            libc::POSIX_FADV_SEQUENTIAL,
        )
    };

    let (tx, rx) = std::sync::mpsc::sync_channel::<(Vec<u8>, usize)>(1);
    let (buf_tx, buf_rx) = std::sync::mpsc::sync_channel::<Vec<u8>>(1);
    let _ = buf_tx.send(vec![0u8; PIPE_BUF_SIZE]);

    let reader_handle = std::thread::spawn(move || -> io::Result<()> {
        while let Ok(mut buf) = buf_rx.recv() {
            let mut total = 0;
            while total < buf.len() {
                match file.read(&mut buf[total..]) {
                    Ok(0) => break,
                    Ok(n) => total += n,
                    Err(ref e) if e.kind() == io::ErrorKind::Interrupted => continue,
                    Err(e) => return Err(e),
                }
            }
            if total == 0 {
                break;
            }
            if tx.send((buf, total)).is_err() {
                break;
            }
        }
        Ok(())
    });

    // Use Digest trait for all hash algorithms.
    macro_rules! hash_pipelined_digest {
        ($hasher_init:expr) => {{
            let mut hasher = $hasher_init;
            while let Ok((buf, n)) = rx.recv() {
                hasher.update(&buf[..n]);
                let _ = buf_tx.send(buf);
            }
            Ok(hex_encode(&hasher.finalize()))
        }};
    }

    let hash_result: io::Result<String> = match algo {
        HashAlgorithm::Blake2b => {
            let mut state = blake2b_simd::Params::new().to_state();
            while let Ok((buf, n)) = rx.recv() {
                state.update(&buf[..n]);
                let _ = buf_tx.send(buf);
            }
            Ok(hex_encode(state.finalize().as_bytes()))
        }
        HashAlgorithm::Md5 => hash_pipelined_digest!(Md5::new()),
        HashAlgorithm::Sha224 => hash_pipelined_digest!(sha2::Sha224::new()),
        HashAlgorithm::Sha256 => hash_pipelined_digest!(sha2::Sha256::new()),
        // SHA-1/384/512: use ring's BoringSSL assembly for better throughput
        HashAlgorithm::Sha1 => {
            let mut ctx = ring::digest::Context::new(&ring::digest::SHA1_FOR_LEGACY_USE_ONLY);
            while let Ok((buf, n)) = rx.recv() {
                ctx.update(&buf[..n]);
                let _ = buf_tx.send(buf);
            }
            Ok(hex_encode(ctx.finish().as_ref()))
        }
        HashAlgorithm::Sha384 => {
            if openssl_sha512::is_available() {
                let digest = openssl_sha512::hash_pipelined(
                    openssl_sha512::Sha2Variant::Sha384,
                    &rx,
                    &buf_tx,
                )?;
                Ok(hex_encode(&digest))
            } else {
                let mut ctx = ring::digest::Context::new(&ring::digest::SHA384);
                while let Ok((buf, n)) = rx.recv() {
                    ctx.update(&buf[..n]);
                    let _ = buf_tx.send(buf);
                }
                Ok(hex_encode(ctx.finish().as_ref()))
            }
        }
        HashAlgorithm::Sha512 => {
            if openssl_sha512::is_available() {
                let digest = openssl_sha512::hash_pipelined(
                    openssl_sha512::Sha2Variant::Sha512,
                    &rx,
                    &buf_tx,
                )?;
                Ok(hex_encode(&digest))
            } else {
                let mut ctx = ring::digest::Context::new(&ring::digest::SHA512);
                while let Ok((buf, n)) = rx.recv() {
                    ctx.update(&buf[..n]);
                    let _ = buf_tx.send(buf);
                }
                Ok(hex_encode(ctx.finish().as_ref()))
            }
        }
    };

    match reader_handle.join() {
        Ok(Ok(())) => {}
        Ok(Err(e)) => {
            if hash_result.is_ok() {
                return Err(e);
            }
        }
        Err(payload) => {
            let msg = if let Some(s) = payload.downcast_ref::<&str>() {
                format!("reader thread panicked: {}", s)
            } else if let Some(s) = payload.downcast_ref::<String>() {
                format!("reader thread panicked: {}", s)
            } else {
                "reader thread panicked".to_string()
            };
            return Err(io::Error::other(msg));
        }
    }

    hash_result
}

/// Hash a known-regular file using tiered I/O strategy based on size.
/// - Large (>=16MB): mmap with HugePage/PopulateRead hints, pipelined fallback
/// - Small/Medium (8KB-16MB): single read into thread-local buffer + single-shot hash
///
/// SAFETY: mmap is safe for regular local files opened just above. The fallback
/// to streaming I/O (hash_reader/hash_file_pipelined) handles mmap failures at
/// map time, but cannot protect against post-map truncation. If the file is
/// truncated or backing storage disappears after mapping (e.g. NFS), the kernel
/// delivers SIGBUS — acceptable, matching other mmap tools.
fn hash_regular_file(algo: HashAlgorithm, file: File, file_size: u64) -> io::Result<String> {
    // Large files (>=SMALL_FILE_LIMIT): mmap for zero-copy single-shot hash.
    if file_size >= SMALL_FILE_LIMIT {
        let mmap_result = unsafe { memmap2::MmapOptions::new().map(&file) };
        if let Ok(mmap) = mmap_result {
            #[cfg(target_os = "linux")]
            {
                let _ = mmap.advise(memmap2::Advice::Sequential);
                // PopulateRead (Linux 5.14+) synchronously faults all pages into
                // TLB before returning. This costs ~200µs/GB but eliminates TLB
                // miss stalls during the hash computation, which is net positive
                // for files that fit comfortably in page cache.
                if mmap.advise(memmap2::Advice::PopulateRead).is_err() {
                    let _ = mmap.advise(memmap2::Advice::WillNeed);
                }
            }
            return hash_bytes(algo, &mmap);
        }
        // mmap failed — fall back to streaming I/O
        #[cfg(target_os = "linux")]
        {
            return hash_file_pipelined(algo, file, file_size);
        }
        #[cfg(not(target_os = "linux"))]
        {
            return hash_reader(algo, file);
        }
    }
    // Small/medium files (8KB-16MB): single read into thread-local buffer.
    // One read() + one single-shot hash call. The thread-local buffer grows
    // lazily and persists across files, so allocation cost is amortized.
    // This outperforms streaming (128KB chunks × N syscalls × N trait dispatches)
    // for files that fit comfortably in the page cache.
    #[cfg(target_os = "linux")]
    {
        use std::os::unix::io::AsRawFd;
        let _ = unsafe {
            libc::posix_fadvise(
                file.as_raw_fd(),
                0,
                file_size as i64,
                libc::POSIX_FADV_SEQUENTIAL,
            )
        };
    }
    hash_file_small(algo, file, file_size as usize)
}

/// Hash a file by path. Uses tiered I/O strategy for regular files,
/// streaming read for non-regular files.
pub fn hash_file(algo: HashAlgorithm, path: &Path) -> io::Result<String> {
    let (file, file_size, is_regular) = open_and_stat(path)?;

    if is_regular && file_size == 0 {
        return hash_bytes(algo, &[]);
    }

    if file_size > 0 && is_regular {
        if file_size < TINY_FILE_LIMIT {
            return hash_file_tiny(algo, file, file_size as usize);
        }
        return hash_regular_file(algo, file, file_size);
    }

    // Non-regular files or fallback: stream
    #[cfg(target_os = "linux")]
    if file_size >= FADVISE_MIN_SIZE {
        use std::os::unix::io::AsRawFd;
        let _ = unsafe {
            libc::posix_fadvise(
                file.as_raw_fd(),
                0,
                file_size as i64,
                libc::POSIX_FADV_SEQUENTIAL,
            )
        };
    }
    hash_reader(algo, file)
}

/// Hash a tiny file (<8KB) using a stack-allocated buffer.
/// Single read() syscall, zero heap allocation on the data path.
/// Optimal for the "100 small files" benchmark where per-file overhead dominates.
#[inline]
fn hash_file_tiny(algo: HashAlgorithm, mut file: File, size: usize) -> io::Result<String> {
    let mut buf = [0u8; 8192];
    let mut total = 0;
    // Read with known size — usually completes in a single read() for regular files
    while total < size {
        match file.read(&mut buf[total..size]) {
            Ok(0) => break,
            Ok(n) => total += n,
            Err(ref e) if e.kind() == io::ErrorKind::Interrupted => continue,
            Err(e) => return Err(e),
        }
    }
    hash_bytes(algo, &buf[..total])
}

/// Hash a small file by reading it entirely into a thread-local buffer,
/// then using the single-shot hash function. Avoids per-file Hasher allocation.
#[inline]
fn hash_file_small(algo: HashAlgorithm, mut file: File, size: usize) -> io::Result<String> {
    SMALL_FILE_BUF.with(|cell| {
        let mut buf = cell.borrow_mut();
        // Reset length but keep allocation, then grow if needed
        buf.clear();
        buf.reserve(size);
        // SAFETY: capacity >= size after clear+reserve. We read into the buffer
        // directly and only access buf[..total] where total <= size <= capacity.
        unsafe {
            buf.set_len(size);
        }
        let mut total = 0;
        while total < size {
            match file.read(&mut buf[total..size]) {
                Ok(0) => break,
                Ok(n) => total += n,
                Err(ref e) if e.kind() == io::ErrorKind::Interrupted => continue,
                Err(e) => return Err(e),
            }
        }
        hash_bytes(algo, &buf[..total])
    })
}

/// Hash stdin. Uses fadvise for file redirects, streaming for pipes.
pub fn hash_stdin(algo: HashAlgorithm) -> io::Result<String> {
    let stdin = io::stdin();
    // Hint kernel for sequential access if stdin is a regular file (redirect)
    #[cfg(target_os = "linux")]
    {
        use std::os::unix::io::AsRawFd;
        let fd = stdin.as_raw_fd();
        let mut stat: libc::stat = unsafe { std::mem::zeroed() };
        if unsafe { libc::fstat(fd, &mut stat) } == 0
            && (stat.st_mode & libc::S_IFMT) == libc::S_IFREG
            && stat.st_size > 0
        {
            unsafe {
                libc::posix_fadvise(fd, 0, stat.st_size, libc::POSIX_FADV_SEQUENTIAL);
            }
        }
    }
    // Streaming hash — works for both pipe and file-redirect stdin
    hash_reader(algo, stdin.lock())
}

/// Check if parallel hashing is worthwhile for the given file paths.
/// Always parallelize with 2+ files — rayon's thread pool is lazily initialized
/// once and reused, so per-file work-stealing overhead is negligible (~1µs).
/// Removing the stat()-based size check eliminates N extra syscalls for N files.
pub fn should_use_parallel(paths: &[&Path]) -> bool {
    paths.len() >= 2
}

/// Issue readahead hints for a list of file paths to warm the page cache.
/// Uses POSIX_FADV_WILLNEED which is non-blocking and batches efficiently.
/// Only issues hints for files >= 1MB; small files are read fast enough
/// that the fadvise syscall overhead isn't worth it.
#[cfg(target_os = "linux")]
pub fn readahead_files(paths: &[&Path]) {
    use std::os::unix::io::AsRawFd;
    for path in paths {
        if let Ok(file) = open_noatime(path) {
            if let Ok(meta) = file.metadata() {
                let len = meta.len();
                if meta.file_type().is_file() && len >= FADVISE_MIN_SIZE {
                    unsafe {
                        libc::posix_fadvise(
                            file.as_raw_fd(),
                            0,
                            len as i64,
                            libc::POSIX_FADV_WILLNEED,
                        );
                    }
                }
            }
        }
    }
}

#[cfg(not(target_os = "linux"))]
pub fn readahead_files(_paths: &[&Path]) {
    // No-op on non-Linux
}

// --- BLAKE2b variable-length functions (using blake2b_simd) ---

/// Hash raw data with BLAKE2b variable output length.
/// `output_bytes` is the output size in bytes (e.g., 32 for 256-bit).
pub fn blake2b_hash_data(data: &[u8], output_bytes: usize) -> String {
    let hash = blake2b_simd::Params::new()
        .hash_length(output_bytes)
        .hash(data);
    hex_encode(hash.as_bytes())
}

/// Hash a reader with BLAKE2b variable output length.
/// Uses thread-local buffer for cache-friendly streaming.
pub fn blake2b_hash_reader<R: Read>(mut reader: R, output_bytes: usize) -> io::Result<String> {
    STREAM_BUF.with(|cell| {
        let mut buf = cell.borrow_mut();
        ensure_stream_buf(&mut buf);
        let mut state = blake2b_simd::Params::new()
            .hash_length(output_bytes)
            .to_state();
        loop {
            let n = read_full(&mut reader, &mut buf)?;
            if n == 0 {
                break;
            }
            state.update(&buf[..n]);
        }
        Ok(hex_encode(state.finalize().as_bytes()))
    })
}

/// Hash a file with BLAKE2b variable output length.
/// Uses mmap for large files (zero-copy), single-read for small files,
/// and streaming read as fallback.
pub fn blake2b_hash_file(path: &Path, output_bytes: usize) -> io::Result<String> {
    let (file, file_size, is_regular) = open_and_stat(path)?;

    if is_regular && file_size == 0 {
        return Ok(blake2b_hash_data(&[], output_bytes));
    }

    if file_size > 0 && is_regular {
        // Tiny files (<8KB): stack buffer + single read() — zero heap allocation
        if file_size < TINY_FILE_LIMIT {
            return blake2b_hash_file_tiny(file, file_size as usize, output_bytes);
        }
        // Large files (>=16MB): I/O pipelining on Linux, mmap on other platforms
        if file_size >= SMALL_FILE_LIMIT {
            #[cfg(target_os = "linux")]
            {
                return blake2b_hash_file_pipelined(file, file_size, output_bytes);
            }
            #[cfg(not(target_os = "linux"))]
            {
                let mmap_result = unsafe { memmap2::MmapOptions::new().map(&file) };
                if let Ok(mmap) = mmap_result {
                    return Ok(blake2b_hash_data(&mmap, output_bytes));
                }
            }
        }
        // Small files (8KB..16MB): single read into thread-local buffer, then single-shot hash
        if file_size < SMALL_FILE_LIMIT {
            return blake2b_hash_file_small(file, file_size as usize, output_bytes);
        }
    }

    // Non-regular files or fallback: stream
    #[cfg(target_os = "linux")]
    if file_size >= FADVISE_MIN_SIZE {
        use std::os::unix::io::AsRawFd;
        let _ = unsafe {
            libc::posix_fadvise(
                file.as_raw_fd(),
                0,
                file_size as i64,
                libc::POSIX_FADV_SEQUENTIAL,
            )
        };
    }
    blake2b_hash_reader(file, output_bytes)
}

/// Hash a tiny BLAKE2b file (<8KB) using a stack-allocated buffer.
#[inline]
fn blake2b_hash_file_tiny(mut file: File, size: usize, output_bytes: usize) -> io::Result<String> {
    let mut buf = [0u8; 8192];
    let mut total = 0;
    while total < size {
        match file.read(&mut buf[total..size]) {
            Ok(0) => break,
            Ok(n) => total += n,
            Err(ref e) if e.kind() == io::ErrorKind::Interrupted => continue,
            Err(e) => return Err(e),
        }
    }
    Ok(blake2b_hash_data(&buf[..total], output_bytes))
}

/// Hash a small file with BLAKE2b by reading it entirely into a thread-local buffer.
#[inline]
fn blake2b_hash_file_small(mut file: File, size: usize, output_bytes: usize) -> io::Result<String> {
    SMALL_FILE_BUF.with(|cell| {
        let mut buf = cell.borrow_mut();
        buf.clear();
        buf.reserve(size);
        // SAFETY: capacity >= size after clear+reserve
        unsafe {
            buf.set_len(size);
        }
        let mut total = 0;
        while total < size {
            match file.read(&mut buf[total..size]) {
                Ok(0) => break,
                Ok(n) => total += n,
                Err(ref e) if e.kind() == io::ErrorKind::Interrupted => continue,
                Err(e) => return Err(e),
            }
        }
        Ok(blake2b_hash_data(&buf[..total], output_bytes))
    })
}

/// Optimized BLAKE2b hash for large files (>=16MB) on Linux.
/// Primary path: mmap with HUGEPAGE + POPULATE_READ for zero-copy, single-shot hash.
/// Eliminates thread spawn, channel synchronization, buffer allocation (24MB→0),
/// and read() memcpy overhead. Falls back to streaming I/O if mmap fails.
#[cfg(target_os = "linux")]
fn blake2b_hash_file_pipelined(
    file: File,
    file_size: u64,
    output_bytes: usize,
) -> io::Result<String> {
    // Primary path: mmap with huge pages for zero-copy single-shot hash.
    // Eliminates: thread spawn (~50µs), channel sync, buffer allocs (24MB),
    // 13+ read() syscalls, and page-cache → user-buffer memcpy.
    match unsafe { memmap2::MmapOptions::new().map(&file) } {
        Ok(mmap) => {
            // HUGEPAGE MUST come before any page faults: reduces 25,600 minor
            // faults (4KB) to ~50 faults (2MB) for 100MB. Saves ~12ms overhead.
            if file_size >= 2 * 1024 * 1024 {
                let _ = mmap.advise(memmap2::Advice::HugePage);
            }
            let _ = mmap.advise(memmap2::Advice::Sequential);
            // POPULATE_READ (Linux 5.14+): synchronously prefaults all pages with
            // huge pages before hashing begins. Falls back to WillNeed on older kernels.
            if file_size >= 4 * 1024 * 1024 {
                if mmap.advise(memmap2::Advice::PopulateRead).is_err() {
                    let _ = mmap.advise(memmap2::Advice::WillNeed);
                }
            } else {
                let _ = mmap.advise(memmap2::Advice::WillNeed);
            }
            // Single-shot hash: processes entire file in one call, streaming
            // directly from page cache with no user-space buffer copies.
            Ok(blake2b_hash_data(&mmap, output_bytes))
        }
        Err(_) => {
            // mmap failed (FUSE, NFS without mmap support, etc.) — fall back
            // to streaming pipelined I/O.
            blake2b_hash_file_streamed(file, file_size, output_bytes)
        }
    }
}

/// Streaming fallback for BLAKE2b large files when mmap is unavailable.
/// Uses double-buffered reader thread with fadvise hints.
/// Fixed: uses blocking recv() to eliminate triple-buffer allocation bug.
#[cfg(target_os = "linux")]
fn blake2b_hash_file_streamed(
    mut file: File,
    file_size: u64,
    output_bytes: usize,
) -> io::Result<String> {
    use std::os::unix::io::AsRawFd;

    const PIPE_BUF_SIZE: usize = 8 * 1024 * 1024; // 8MB per buffer

    // Hint kernel for sequential access
    unsafe {
        libc::posix_fadvise(
            file.as_raw_fd(),
            0,
            file_size as i64,
            libc::POSIX_FADV_SEQUENTIAL,
        );
    }

    // Double-buffered channels: reader fills one buffer while hasher processes another.
    let (tx, rx) = std::sync::mpsc::sync_channel::<(Vec<u8>, usize)>(1);
    let (buf_tx, buf_rx) = std::sync::mpsc::sync_channel::<Vec<u8>>(1);
    let _ = buf_tx.send(vec![0u8; PIPE_BUF_SIZE]);

    let reader_handle = std::thread::spawn(move || -> io::Result<()> {
        // Blocking recv reuses hasher's returned buffer (2 buffers total, not 3).
        while let Ok(mut buf) = buf_rx.recv() {
            let mut total = 0;
            while total < buf.len() {
                match file.read(&mut buf[total..]) {
                    Ok(0) => break,
                    Ok(n) => total += n,
                    Err(ref e) if e.kind() == io::ErrorKind::Interrupted => continue,
                    Err(e) => return Err(e),
                }
            }
            if total == 0 {
                break;
            }
            if tx.send((buf, total)).is_err() {
                break;
            }
        }
        Ok(())
    });

    let mut state = blake2b_simd::Params::new()
        .hash_length(output_bytes)
        .to_state();
    while let Ok((buf, n)) = rx.recv() {
        state.update(&buf[..n]);
        let _ = buf_tx.send(buf);
    }
    let hash_result = Ok(hex_encode(state.finalize().as_bytes()));

    match reader_handle.join() {
        Ok(Ok(())) => {}
        Ok(Err(e)) => {
            if hash_result.is_ok() {
                return Err(e);
            }
        }
        Err(payload) => {
            let msg = if let Some(s) = payload.downcast_ref::<&str>() {
                format!("reader thread panicked: {}", s)
            } else if let Some(s) = payload.downcast_ref::<String>() {
                format!("reader thread panicked: {}", s)
            } else {
                "reader thread panicked".to_string()
            };
            return Err(io::Error::other(msg));
        }
    }

    hash_result
}

/// Hash stdin with BLAKE2b variable output length.
/// Tries fadvise if stdin is a regular file (shell redirect), then streams.
pub fn blake2b_hash_stdin(output_bytes: usize) -> io::Result<String> {
    let stdin = io::stdin();
    #[cfg(target_os = "linux")]
    {
        use std::os::unix::io::AsRawFd;
        let fd = stdin.as_raw_fd();
        let mut stat: libc::stat = unsafe { std::mem::zeroed() };
        if unsafe { libc::fstat(fd, &mut stat) } == 0
            && (stat.st_mode & libc::S_IFMT) == libc::S_IFREG
            && stat.st_size > 0
        {
            unsafe {
                libc::posix_fadvise(fd, 0, stat.st_size, libc::POSIX_FADV_SEQUENTIAL);
            }
        }
    }
    blake2b_hash_reader(stdin.lock(), output_bytes)
}

/// Internal enum for file content in batch hashing.
/// Keeps data alive (either as mmap or owned Vec) while hash_many references it.
enum FileContent {
    Mmap(memmap2::Mmap),
    Buf(Vec<u8>),
}

impl AsRef<[u8]> for FileContent {
    fn as_ref(&self) -> &[u8] {
        match self {
            FileContent::Mmap(m) => m,
            FileContent::Buf(v) => v,
        }
    }
}

/// Open a file and load its content for batch hashing.
/// Uses read for tiny files (avoids mmap syscall overhead), mmap for large
/// files (zero-copy), and read-to-end for non-regular files.
fn open_file_content(path: &Path) -> io::Result<FileContent> {
    let (file, size, is_regular) = open_and_stat(path)?;
    if is_regular && size == 0 {
        return Ok(FileContent::Buf(Vec::new()));
    }
    if is_regular && size > 0 {
        // Tiny files: read directly into Vec. The mmap syscall + page fault
        // overhead exceeds the data transfer cost for files under 8KB.
        // For the 100-file benchmark (55 bytes each), this saves ~100 mmap calls.
        if size < TINY_FILE_LIMIT {
            let mut buf = vec![0u8; size as usize];
            let mut total = 0;
            let mut f = file;
            while total < size as usize {
                match f.read(&mut buf[total..]) {
                    Ok(0) => break,
                    Ok(n) => total += n,
                    Err(ref e) if e.kind() == io::ErrorKind::Interrupted => continue,
                    Err(e) => return Err(e),
                }
            }
            buf.truncate(total);
            return Ok(FileContent::Buf(buf));
        }
        // HUGEPAGE + PopulateRead for optimal page faulting
        let mmap_result = unsafe { memmap2::MmapOptions::new().map(&file) };
        if let Ok(mmap) = mmap_result {
            #[cfg(target_os = "linux")]
            {
                if size >= 2 * 1024 * 1024 {
                    let _ = mmap.advise(memmap2::Advice::HugePage);
                }
                let _ = mmap.advise(memmap2::Advice::Sequential);
                if mmap.advise(memmap2::Advice::PopulateRead).is_err() {
                    let _ = mmap.advise(memmap2::Advice::WillNeed);
                }
            }
            return Ok(FileContent::Mmap(mmap));
        }
        // Fallback: read into Vec
        let mut buf = vec![0u8; size as usize];
        let mut total = 0;
        let mut f = file;
        while total < size as usize {
            match f.read(&mut buf[total..]) {
                Ok(0) => break,
                Ok(n) => total += n,
                Err(ref e) if e.kind() == io::ErrorKind::Interrupted => continue,
                Err(e) => return Err(e),
            }
        }
        buf.truncate(total);
        return Ok(FileContent::Buf(buf));
    }
    // Non-regular: read to end
    let mut buf = Vec::new();
    let mut f = file;
    f.read_to_end(&mut buf)?;
    Ok(FileContent::Buf(buf))
}

/// Read remaining file content from an already-open fd into a Vec.
/// Used when the initial stack buffer is exhausted and we need to read
/// the rest without re-opening the file.
fn read_remaining_to_vec(prefix: &[u8], mut file: File) -> io::Result<FileContent> {
    let mut buf = Vec::with_capacity(prefix.len() + 65536);
    buf.extend_from_slice(prefix);
    file.read_to_end(&mut buf)?;
    Ok(FileContent::Buf(buf))
}

/// Open a file and read all content without fstat — just open+read+close.
/// For many-file workloads (100+ files), skipping fstat saves ~5µs/file
/// (~0.5ms for 100 files). Uses a small initial buffer for tiny files (< 4KB),
/// then falls back to larger buffer or read_to_end for bigger files.
fn open_file_content_fast(path: &Path) -> io::Result<FileContent> {
    let mut file = open_noatime(path)?;
    // Try small stack buffer first — optimal for benchmark's ~55 byte files.
    // For tiny files, allocate exact-size Vec to avoid waste.
    let mut small_buf = [0u8; 4096];
    match file.read(&mut small_buf) {
        Ok(0) => return Ok(FileContent::Buf(Vec::new())),
        Ok(n) if n < small_buf.len() => {
            // File fits in small buffer — allocate exact size
            let mut vec = Vec::with_capacity(n);
            vec.extend_from_slice(&small_buf[..n]);
            return Ok(FileContent::Buf(vec));
        }
        Ok(n) => {
            // Might be more data — allocate heap buffer and read into it directly
            let mut buf = vec![0u8; 65536];
            buf[..n].copy_from_slice(&small_buf[..n]);
            let mut total = n;
            loop {
                match file.read(&mut buf[total..]) {
                    Ok(0) => {
                        buf.truncate(total);
                        return Ok(FileContent::Buf(buf));
                    }
                    Ok(n) => {
                        total += n;
                        if total >= buf.len() {
                            // File > 64KB: read rest from existing fd
                            return read_remaining_to_vec(&buf[..total], file);
                        }
                    }
                    Err(ref e) if e.kind() == io::ErrorKind::Interrupted => continue,
                    Err(e) => return Err(e),
                }
            }
        }
        Err(ref e) if e.kind() == io::ErrorKind::Interrupted => {
            let mut buf = vec![0u8; 65536];
            let mut total = 0;
            loop {
                match file.read(&mut buf[total..]) {
                    Ok(0) => {
                        buf.truncate(total);
                        return Ok(FileContent::Buf(buf));
                    }
                    Ok(n) => {
                        total += n;
                        if total >= buf.len() {
                            // File > 64KB: read rest from existing fd
                            return read_remaining_to_vec(&buf[..total], file);
                        }
                    }
                    Err(ref e) if e.kind() == io::ErrorKind::Interrupted => continue,
                    Err(e) => return Err(e),
                }
            }
        }
        Err(e) => return Err(e),
    }
}

/// Batch-hash multiple files with BLAKE2b using multi-buffer SIMD.
///
/// Uses blake2b_simd::many::hash_many for 4-way AVX2 parallel hashing.
/// All files are pre-loaded into memory (mmap for large, read for small),
/// then hashed simultaneously. Returns results in input order.
///
/// For 100 files on AVX2: 4x throughput from SIMD parallelism.
pub fn blake2b_hash_files_many(paths: &[&Path], output_bytes: usize) -> Vec<io::Result<String>> {
    use blake2b_simd::many::{HashManyJob, hash_many};

    // Phase 1: Read all files into memory.
    // For small file counts (≤10), load sequentially to avoid thread::scope
    // overhead (~120µs). For many files, use parallel loading with lightweight
    // OS threads. For 100+ files, use fast path that skips fstat.
    let use_fast = paths.len() >= 20;

    let file_data: Vec<io::Result<FileContent>> = if paths.len() <= 10 {
        // Sequential loading — avoids thread spawn overhead for small batches
        paths.iter().map(|&path| open_file_content(path)).collect()
    } else {
        let num_threads = std::thread::available_parallelism()
            .map(|n| n.get())
            .unwrap_or(4)
            .min(paths.len());
        let chunk_size = (paths.len() + num_threads - 1) / num_threads;

        std::thread::scope(|s| {
            let handles: Vec<_> = paths
                .chunks(chunk_size)
                .map(|chunk| {
                    s.spawn(move || {
                        chunk
                            .iter()
                            .map(|&path| {
                                if use_fast {
                                    open_file_content_fast(path)
                                } else {
                                    open_file_content(path)
                                }
                            })
                            .collect::<Vec<_>>()
                    })
                })
                .collect();

            handles
                .into_iter()
                .flat_map(|h| h.join().unwrap())
                .collect()
        })
    };

    // Phase 2: Build hash_many jobs for successful reads
    let hash_results = {
        let mut params = blake2b_simd::Params::new();
        params.hash_length(output_bytes);

        let ok_entries: Vec<(usize, &[u8])> = file_data
            .iter()
            .enumerate()
            .filter_map(|(i, r)| r.as_ref().ok().map(|c| (i, c.as_ref())))
            .collect();

        let mut jobs: Vec<HashManyJob> = ok_entries
            .iter()
            .map(|(_, data)| HashManyJob::new(&params, data))
            .collect();

        // Phase 3: Run multi-buffer SIMD hash (4-way AVX2)
        hash_many(jobs.iter_mut());

        // Extract hashes into a map
        let mut hm: Vec<Option<String>> = vec![None; paths.len()];
        for (j, &(orig_i, _)) in ok_entries.iter().enumerate() {
            hm[orig_i] = Some(hex_encode(jobs[j].to_hash().as_bytes()));
        }
        hm
    }; // file_data borrow released here

    // Phase 4: Combine hashes and errors in original order
    hash_results
        .into_iter()
        .zip(file_data)
        .map(|(hash_opt, result)| match result {
            Ok(_) => Ok(hash_opt.unwrap()),
            Err(e) => Err(e),
        })
        .collect()
}

/// Batch-hash multiple files with BLAKE2b using the best strategy for the workload.
/// Samples a few files to estimate total data size. For small workloads, uses
/// single-core SIMD batch hashing (`blake2b_hash_files_many`) to avoid stat and
/// thread spawn overhead. For larger workloads, uses multi-core work-stealing
/// parallelism where each worker calls `blake2b_hash_file` (with I/O pipelining
/// for large files on Linux).
/// Returns results in input order.
pub fn blake2b_hash_files_parallel(
    paths: &[&Path],
    output_bytes: usize,
) -> Vec<io::Result<String>> {
    let n = paths.len();

    // Sample a few files to estimate whether parallel processing is worthwhile.
    // This avoids the cost of statting ALL files (~70µs/file) when the workload
    // is too small for parallelism to help.
    let sample_count = n.min(5);
    let mut sample_max: u64 = 0;
    let mut sample_total: u64 = 0;
    for &p in paths.iter().take(sample_count) {
        let size = std::fs::metadata(p).map(|m| m.len()).unwrap_or(0);
        sample_total += size;
        sample_max = sample_max.max(size);
    }
    let estimated_total = if sample_count > 0 {
        sample_total * (n as u64) / (sample_count as u64)
    } else {
        0
    };

    // For small workloads, thread spawn overhead (~120µs × N_threads) exceeds
    // any parallelism benefit. Use SIMD batch hashing directly (no stat pass).
    if estimated_total < 1024 * 1024 && sample_max < SMALL_FILE_LIMIT {
        return blake2b_hash_files_many(paths, output_bytes);
    }

    // Full stat pass for parallel scheduling — worth it for larger workloads.
    let mut indexed: Vec<(usize, &Path, u64)> = paths
        .iter()
        .enumerate()
        .map(|(i, &p)| {
            let size = std::fs::metadata(p).map(|m| m.len()).unwrap_or(0);
            (i, p, size)
        })
        .collect();

    // Sort largest first: ensures big files start hashing immediately while
    // small files fill in gaps, minimizing tail latency.
    indexed.sort_by(|a, b| b.2.cmp(&a.2));

    // Warm page cache for the largest files using async readahead(2).
    // Each hash call handles its own mmap prefaulting, but issuing readahead
    // here lets the kernel start I/O for upcoming files while workers process
    // current ones. readahead(2) returns immediately (non-blocking).
    #[cfg(target_os = "linux")]
    {
        use std::os::unix::io::AsRawFd;
        for &(_, path, size) in indexed.iter().take(20) {
            if size >= 1024 * 1024 {
                if let Ok(file) = open_noatime(path) {
                    unsafe {
                        libc::readahead(file.as_raw_fd(), 0, size as usize);
                    }
                }
            }
        }
    }

    let num_threads = std::thread::available_parallelism()
        .map(|n| n.get())
        .unwrap_or(4)
        .min(n);

    // Atomic work index for dynamic work-stealing.
    let work_idx = AtomicUsize::new(0);

    std::thread::scope(|s| {
        let work_idx = &work_idx;
        let indexed = &indexed;

        let handles: Vec<_> = (0..num_threads)
            .map(|_| {
                s.spawn(move || {
                    let mut local_results = Vec::new();
                    loop {
                        let idx = work_idx.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
                        if idx >= indexed.len() {
                            break;
                        }
                        let (orig_idx, path, _size) = indexed[idx];
                        let result = blake2b_hash_file(path, output_bytes);
                        local_results.push((orig_idx, result));
                    }
                    local_results
                })
            })
            .collect();

        // Collect results and reorder to match original input order.
        let mut results: Vec<Option<io::Result<String>>> = (0..n).map(|_| None).collect();
        for handle in handles {
            for (orig_idx, result) in handle.join().unwrap() {
                results[orig_idx] = Some(result);
            }
        }
        results
            .into_iter()
            .map(|opt| opt.unwrap_or_else(|| Err(io::Error::other("missing result"))))
            .collect()
    })
}

/// Auto-dispatch multi-file hashing: picks sequential or parallel based on workload.
///
/// For small files (<64KB sample), sequential avoids thread spawn + readahead overhead
/// that dominates for tiny files. On the "100 × 55-byte files" benchmark, this saves
/// ~5ms of overhead (thread creation + 200 stat() calls + 100 fadvise() calls).
///
/// For large files (>=64KB), parallel processing amortizes thread spawn cost over
/// substantial per-file hash work. Returns results in input order.
pub fn hash_files_auto(paths: &[&Path], algo: HashAlgorithm) -> Vec<io::Result<String>> {
    let n = paths.len();
    if n == 0 {
        return Vec::new();
    }
    if n == 1 {
        return vec![hash_file_nostat(algo, paths[0])];
    }

    // Sample up to 3 files (max size) to correctly dispatch mixed workloads
    // like `md5sum small.txt big1.gb big2.gb`. Costs at most 3 stat calls (~6µs)
    // to save potentially 3-6ms of thread overhead for small-file workloads.
    let sample_size = paths
        .iter()
        .take(3)
        .filter_map(|p| std::fs::metadata(p).ok())
        .map(|m| m.len())
        .max()
        .unwrap_or(0);

    if sample_size < 65536 {
        // Small files: sequential loop avoiding thread spawn overhead.
        #[cfg(target_os = "linux")]
        {
            // Raw syscall path: reuses CString buffer, avoids OpenOptions/File overhead
            let mut c_path_buf = Vec::with_capacity(256);
            paths
                .iter()
                .map(|&p| hash_file_raw_nostat(algo, p, &mut c_path_buf))
                .collect()
        }
        #[cfg(not(target_os = "linux"))]
        {
            paths.iter().map(|&p| hash_file_nostat(algo, p)).collect()
        }
    } else if n >= 20 {
        hash_files_batch(paths, algo)
    } else {
        hash_files_parallel_fast(paths, algo)
    }
}

/// Batch-hash multiple files with SHA-256/MD5 using work-stealing parallelism.
/// Files are sorted by size (largest first) so the biggest files start processing
/// immediately. Each worker thread grabs the next unprocessed file via atomic index,
/// eliminating tail latency from uneven file sizes.
/// Returns results in input order.
pub fn hash_files_parallel(paths: &[&Path], algo: HashAlgorithm) -> Vec<io::Result<String>> {
    let n = paths.len();

    // Build (original_index, path, size) tuples — stat all files for scheduling.
    // The stat cost (~5µs/file) is repaid by better work distribution.
    let mut indexed: Vec<(usize, &Path, u64)> = paths
        .iter()
        .enumerate()
        .map(|(i, &p)| {
            let size = std::fs::metadata(p).map(|m| m.len()).unwrap_or(0);
            (i, p, size)
        })
        .collect();

    // Sort largest first: ensures big files start hashing immediately while
    // small files fill in gaps, minimizing tail latency.
    indexed.sort_by(|a, b| b.2.cmp(&a.2));

    // Warm page cache for the largest files using async readahead(2).
    // Each hash call handles its own mmap prefaulting, but issuing readahead
    // here lets the kernel start I/O for upcoming files while workers process
    // current ones. readahead(2) returns immediately (non-blocking).
    #[cfg(target_os = "linux")]
    {
        use std::os::unix::io::AsRawFd;
        for &(_, path, size) in indexed.iter().take(20) {
            if size >= 1024 * 1024 {
                if let Ok(file) = open_noatime(path) {
                    unsafe {
                        libc::readahead(file.as_raw_fd(), 0, size as usize);
                    }
                }
            }
        }
    }

    let num_threads = std::thread::available_parallelism()
        .map(|n| n.get())
        .unwrap_or(4)
        .min(n);

    // Atomic work index for dynamic work-stealing.
    let work_idx = AtomicUsize::new(0);

    std::thread::scope(|s| {
        let work_idx = &work_idx;
        let indexed = &indexed;

        let handles: Vec<_> = (0..num_threads)
            .map(|_| {
                s.spawn(move || {
                    let mut local_results = Vec::new();
                    loop {
                        let idx = work_idx.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
                        if idx >= indexed.len() {
                            break;
                        }
                        let (orig_idx, path, _size) = indexed[idx];
                        let result = hash_file(algo, path);
                        local_results.push((orig_idx, result));
                    }
                    local_results
                })
            })
            .collect();

        // Collect results and reorder to match original input order.
        let mut results: Vec<Option<io::Result<String>>> = (0..n).map(|_| None).collect();
        for handle in handles {
            for (orig_idx, result) in handle.join().unwrap() {
                results[orig_idx] = Some(result);
            }
        }
        results
            .into_iter()
            .map(|opt| opt.unwrap_or_else(|| Err(io::Error::other("missing result"))))
            .collect()
    })
}

/// Fast parallel hash for multi-file workloads. Skips the stat-all-and-sort phase
/// of `hash_files_parallel()` and uses `hash_file_nostat()` per worker to minimize
/// per-file syscall overhead. For 100 tiny files, this eliminates ~200 stat() calls
/// (100 from the sort phase + 100 from open_and_stat inside each worker).
/// Returns results in input order.
pub fn hash_files_parallel_fast(paths: &[&Path], algo: HashAlgorithm) -> Vec<io::Result<String>> {
    let n = paths.len();
    if n == 0 {
        return Vec::new();
    }
    if n == 1 {
        return vec![hash_file_nostat(algo, paths[0])];
    }

    // Issue readahead for all files (no size threshold — even tiny files benefit
    // from batched WILLNEED hints when processing 100+ files)
    #[cfg(target_os = "linux")]
    readahead_files_all(paths);

    let num_threads = std::thread::available_parallelism()
        .map(|n| n.get())
        .unwrap_or(4)
        .min(n);

    let work_idx = AtomicUsize::new(0);

    std::thread::scope(|s| {
        let work_idx = &work_idx;

        let handles: Vec<_> = (0..num_threads)
            .map(|_| {
                s.spawn(move || {
                    let mut local_results = Vec::new();
                    loop {
                        let idx = work_idx.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
                        if idx >= n {
                            break;
                        }
                        let result = hash_file_nostat(algo, paths[idx]);
                        local_results.push((idx, result));
                    }
                    local_results
                })
            })
            .collect();

        let mut results: Vec<Option<io::Result<String>>> = (0..n).map(|_| None).collect();
        for handle in handles {
            for (idx, result) in handle.join().unwrap() {
                results[idx] = Some(result);
            }
        }
        results
            .into_iter()
            .map(|opt| opt.unwrap_or_else(|| Err(io::Error::other("missing result"))))
            .collect()
    })
}

/// Batch-hash multiple files: pre-read all files into memory in parallel,
/// then hash all data in parallel. Optimal for many small files where per-file
/// overhead (open/read/close syscalls) dominates over hash computation.
///
/// Reuses the same parallel file loading pattern as `blake2b_hash_files_many()`.
/// For 100 × 55-byte files: all 5500 bytes are loaded in parallel across threads,
/// then hashed in parallel — minimizing wall-clock time for syscall-bound workloads.
/// Returns results in input order.
pub fn hash_files_batch(paths: &[&Path], algo: HashAlgorithm) -> Vec<io::Result<String>> {
    let n = paths.len();
    if n == 0 {
        return Vec::new();
    }

    // Issue readahead for all files
    #[cfg(target_os = "linux")]
    readahead_files_all(paths);

    // Phase 1: Load all files into memory in parallel.
    // For 20+ files, use fast path that skips fstat.
    let use_fast = n >= 20;

    let file_data: Vec<io::Result<FileContent>> = if n <= 10 {
        // Sequential loading — avoids thread spawn overhead for small batches
        paths
            .iter()
            .map(|&path| {
                if use_fast {
                    open_file_content_fast(path)
                } else {
                    open_file_content(path)
                }
            })
            .collect()
    } else {
        let num_threads = std::thread::available_parallelism()
            .map(|t| t.get())
            .unwrap_or(4)
            .min(n);
        let chunk_size = (n + num_threads - 1) / num_threads;

        std::thread::scope(|s| {
            let handles: Vec<_> = paths
                .chunks(chunk_size)
                .map(|chunk| {
                    s.spawn(move || {
                        chunk
                            .iter()
                            .map(|&path| {
                                if use_fast {
                                    open_file_content_fast(path)
                                } else {
                                    open_file_content(path)
                                }
                            })
                            .collect::<Vec<_>>()
                    })
                })
                .collect();

            handles
                .into_iter()
                .flat_map(|h| h.join().unwrap())
                .collect()
        })
    };

    // Phase 2: Hash all loaded data. For tiny files hash is negligible;
    // for larger files the parallel hashing across threads helps.
    let num_hash_threads = std::thread::available_parallelism()
        .map(|t| t.get())
        .unwrap_or(4)
        .min(n);
    let work_idx = AtomicUsize::new(0);

    std::thread::scope(|s| {
        let work_idx = &work_idx;
        let file_data = &file_data;

        let handles: Vec<_> = (0..num_hash_threads)
            .map(|_| {
                s.spawn(move || {
                    let mut local_results = Vec::new();
                    loop {
                        let idx = work_idx.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
                        if idx >= n {
                            break;
                        }
                        let result = match &file_data[idx] {
                            Ok(content) => hash_bytes(algo, content.as_ref()),
                            Err(e) => Err(io::Error::new(e.kind(), e.to_string())),
                        };
                        local_results.push((idx, result));
                    }
                    local_results
                })
            })
            .collect();

        let mut results: Vec<Option<io::Result<String>>> = (0..n).map(|_| None).collect();
        for handle in handles {
            for (idx, result) in handle.join().unwrap() {
                results[idx] = Some(result);
            }
        }
        results
            .into_iter()
            .map(|opt| opt.unwrap_or_else(|| Err(io::Error::other("missing result"))))
            .collect()
    })
}

/// Stream-hash a file that already has a prefix read into memory.
/// Feeds `prefix` into the hasher first, then streams the rest from `file`.
/// Avoids re-opening and re-reading the file when the initial buffer is exhausted.
fn hash_stream_with_prefix(
    algo: HashAlgorithm,
    prefix: &[u8],
    mut file: File,
) -> io::Result<String> {
    // Blake2b uses its own hasher on all platforms
    if matches!(algo, HashAlgorithm::Blake2b) {
        let mut state = blake2b_simd::Params::new().to_state();
        state.update(prefix);
        return STREAM_BUF.with(|cell| {
            let mut buf = cell.borrow_mut();
            ensure_stream_buf(&mut buf);
            loop {
                let n = read_full(&mut file, &mut buf)?;
                if n == 0 {
                    break;
                }
                state.update(&buf[..n]);
            }
            Ok(hex_encode(state.finalize().as_bytes()))
        });
    }

    match algo {
        HashAlgorithm::Sha224 => hash_stream_with_prefix_digest::<sha2::Sha224>(prefix, file),
        HashAlgorithm::Sha256 => hash_stream_with_prefix_digest::<sha2::Sha256>(prefix, file),
        HashAlgorithm::Md5 => hash_stream_with_prefix_digest::<md5::Md5>(prefix, file),
        // SHA-1/384/512: use ring's BoringSSL assembly on non-Apple, sha2 crate on Apple
        #[cfg(not(target_vendor = "apple"))]
        HashAlgorithm::Sha1 => {
            hash_stream_with_prefix_ring(&ring::digest::SHA1_FOR_LEGACY_USE_ONLY, prefix, file)
        }
        #[cfg(target_vendor = "apple")]
        HashAlgorithm::Sha1 => hash_stream_with_prefix_digest::<sha1::Sha1>(prefix, file),
        #[cfg(target_os = "linux")]
        HashAlgorithm::Sha384 => {
            if openssl_sha512::is_available() {
                let digest = openssl_sha512::hash_reader_with_prefix(
                    openssl_sha512::Sha2Variant::Sha384,
                    prefix,
                    file,
                )?;
                Ok(hex_encode(&digest))
            } else {
                hash_stream_with_prefix_ring(&ring::digest::SHA384, prefix, file)
            }
        }
        #[cfg(all(not(target_os = "linux"), not(target_vendor = "apple")))]
        HashAlgorithm::Sha384 => hash_stream_with_prefix_ring(&ring::digest::SHA384, prefix, file),
        #[cfg(target_vendor = "apple")]
        HashAlgorithm::Sha384 => hash_stream_with_prefix_digest::<sha2::Sha384>(prefix, file),
        #[cfg(target_os = "linux")]
        HashAlgorithm::Sha512 => {
            if openssl_sha512::is_available() {
                let digest = openssl_sha512::hash_reader_with_prefix(
                    openssl_sha512::Sha2Variant::Sha512,
                    prefix,
                    file,
                )?;
                Ok(hex_encode(&digest))
            } else {
                hash_stream_with_prefix_ring(&ring::digest::SHA512, prefix, file)
            }
        }
        #[cfg(all(not(target_os = "linux"), not(target_vendor = "apple")))]
        HashAlgorithm::Sha512 => hash_stream_with_prefix_ring(&ring::digest::SHA512, prefix, file),
        #[cfg(target_vendor = "apple")]
        HashAlgorithm::Sha512 => hash_stream_with_prefix_digest::<sha2::Sha512>(prefix, file),
        HashAlgorithm::Blake2b => unreachable!(),
    }
}

/// Generic stream-hash with prefix using Digest trait (all platforms).
fn hash_stream_with_prefix_digest<D: digest::Digest>(
    prefix: &[u8],
    mut file: File,
) -> io::Result<String> {
    STREAM_BUF.with(|cell| {
        let mut buf = cell.borrow_mut();
        ensure_stream_buf(&mut buf);
        let mut hasher = D::new();
        hasher.update(prefix);
        loop {
            let n = read_full(&mut file, &mut buf)?;
            if n == 0 {
                break;
            }
            hasher.update(&buf[..n]);
        }
        Ok(hex_encode(&hasher.finalize()))
    })
}

/// Stream-hash with prefix using ring's BoringSSL assembly (non-Apple targets).
#[cfg(not(target_vendor = "apple"))]
fn hash_stream_with_prefix_ring(
    algo: &'static ring::digest::Algorithm,
    prefix: &[u8],
    mut file: File,
) -> io::Result<String> {
    STREAM_BUF.with(|cell| {
        let mut buf = cell.borrow_mut();
        ensure_stream_buf(&mut buf);
        let mut ctx = ring::digest::Context::new(algo);
        ctx.update(prefix);
        loop {
            let n = read_full(&mut file, &mut buf)?;
            if n == 0 {
                break;
            }
            ctx.update(&buf[..n]);
        }
        Ok(hex_encode(ctx.finish().as_ref()))
    })
}

/// Hash a file without fstat — just open, read until EOF, hash.
/// For many-file workloads (100+ tiny files), skipping fstat saves ~5µs/file.
/// Uses a two-tier buffer strategy: small stack buffer (4KB) for the initial read,
/// then falls back to a larger stack buffer (64KB) or streaming hash for bigger files.
/// For benchmark's 55-byte files: one read() fills the 4KB buffer, hash immediately.
pub fn hash_file_nostat(algo: HashAlgorithm, path: &Path) -> io::Result<String> {
    let mut file = open_noatime(path)?;
    // First try a small stack buffer — optimal for tiny files (< 4KB).
    // Most "many_files" benchmark files are ~55 bytes, so this completes
    // with a single read() syscall and no fallback.
    let mut small_buf = [0u8; 4096];
    match file.read(&mut small_buf) {
        Ok(0) => return hash_bytes(algo, &[]),
        Ok(n) if n < small_buf.len() => {
            // File fits in small buffer — hash directly (common case)
            return hash_bytes(algo, &small_buf[..n]);
        }
        Ok(n) => {
            // Might be more data — fall back to larger buffer
            let mut buf = [0u8; 65536];
            buf[..n].copy_from_slice(&small_buf[..n]);
            let mut total = n;
            loop {
                match file.read(&mut buf[total..]) {
                    Ok(0) => return hash_bytes(algo, &buf[..total]),
                    Ok(n) => {
                        total += n;
                        if total >= buf.len() {
                            // File > 64KB: stream-hash from existing fd instead of
                            // re-opening. Feed already-read prefix, continue streaming.
                            return hash_stream_with_prefix(algo, &buf[..total], file);
                        }
                    }
                    Err(ref e) if e.kind() == io::ErrorKind::Interrupted => continue,
                    Err(e) => return Err(e),
                }
            }
        }
        Err(ref e) if e.kind() == io::ErrorKind::Interrupted => {
            // Retry with full buffer on interrupt
            let mut buf = [0u8; 65536];
            let mut total = 0;
            loop {
                match file.read(&mut buf[total..]) {
                    Ok(0) => return hash_bytes(algo, &buf[..total]),
                    Ok(n) => {
                        total += n;
                        if total >= buf.len() {
                            // File > 64KB: stream-hash from existing fd
                            return hash_stream_with_prefix(algo, &buf[..total], file);
                        }
                    }
                    Err(ref e) if e.kind() == io::ErrorKind::Interrupted => continue,
                    Err(e) => return Err(e),
                }
            }
        }
        Err(e) => return Err(e),
    }
}

/// Hash a small file using raw Linux syscalls without fstat.
/// For the multi-file sequential path where we already know files are small.
/// Avoids: OpenOptions builder, CString per-file alloc (reuses caller's buffer),
/// fstat overhead (unnecessary when we just need open+read+close).
/// Returns hash as hex string.
#[cfg(target_os = "linux")]
fn hash_file_raw_nostat(
    algo: HashAlgorithm,
    path: &Path,
    c_path_buf: &mut Vec<u8>,
) -> io::Result<String> {
    use std::os::unix::ffi::OsStrExt;

    let path_bytes = path.as_os_str().as_bytes();

    // Reuse caller's buffer for null-terminated path (avoids heap alloc per file)
    c_path_buf.clear();
    c_path_buf.reserve(path_bytes.len() + 1);
    c_path_buf.extend_from_slice(path_bytes);
    c_path_buf.push(0);

    let mut flags = libc::O_RDONLY | libc::O_CLOEXEC;
    if NOATIME_SUPPORTED.load(Ordering::Relaxed) {
        flags |= libc::O_NOATIME;
    }

    let fd = unsafe { libc::open(c_path_buf.as_ptr() as *const libc::c_char, flags) };
    if fd < 0 {
        let err = io::Error::last_os_error();
        if err.raw_os_error() == Some(libc::EPERM) && flags & libc::O_NOATIME != 0 {
            NOATIME_SUPPORTED.store(false, Ordering::Relaxed);
            let fd2 = unsafe {
                libc::open(
                    c_path_buf.as_ptr() as *const libc::c_char,
                    libc::O_RDONLY | libc::O_CLOEXEC,
                )
            };
            if fd2 < 0 {
                return Err(io::Error::last_os_error());
            }
            return hash_fd_small(algo, fd2);
        }
        return Err(err);
    }
    hash_fd_small(algo, fd)
}

/// Read a small file from fd, hash it, close fd. No fstat needed.
#[cfg(target_os = "linux")]
#[inline]
fn hash_fd_small(algo: HashAlgorithm, fd: i32) -> io::Result<String> {
    let mut buf = [0u8; 4096];
    let n = loop {
        let ret = unsafe { libc::read(fd, buf.as_mut_ptr() as *mut libc::c_void, buf.len()) };
        if ret >= 0 {
            break ret;
        }
        let err = io::Error::last_os_error();
        if err.kind() == io::ErrorKind::Interrupted {
            continue;
        }
        unsafe {
            libc::close(fd);
        }
        return Err(err);
    };
    let n = n as usize;
    if n < buf.len() {
        // File fits in 4KB — common case for small files
        unsafe {
            libc::close(fd);
        }
        return hash_bytes(algo, &buf[..n]);
    }
    // File > 4KB: fall back to hash_file_nostat-style reading
    // Wrap fd in File for RAII close
    use std::os::unix::io::FromRawFd;
    let mut file = unsafe { File::from_raw_fd(fd) };
    let mut big_buf = [0u8; 65536];
    big_buf[..n].copy_from_slice(&buf[..n]);
    let mut total = n;
    loop {
        match std::io::Read::read(&mut file, &mut big_buf[total..]) {
            Ok(0) => return hash_bytes(algo, &big_buf[..total]),
            Ok(n) => {
                total += n;
                if total >= big_buf.len() {
                    return hash_stream_with_prefix(algo, &big_buf[..total], file);
                }
            }
            Err(ref e) if e.kind() == io::ErrorKind::Interrupted => continue,
            Err(e) => return Err(e),
        }
    }
}

/// Hash a single file using raw Linux syscalls for minimum overhead.
/// Bypasses Rust's File abstraction entirely: raw open/fstat/read/close.
/// For the single-file fast path, this eliminates OpenOptions builder,
/// CString heap allocation, File wrapper overhead, and Read trait dispatch.
///
/// Size-based dispatch:
/// - Tiny (<8KB): stack buffer + raw read + hash_bytes (3 syscalls total)
/// - Small (8KB-16MB): wraps fd in File, reads into thread-local buffer
/// - Large (>=16MB): wraps fd in File, mmaps with HugePage + PopulateRead
/// - Non-regular: wraps fd in File, streaming hash_reader
#[cfg(target_os = "linux")]
pub fn hash_file_raw(algo: HashAlgorithm, path: &Path) -> io::Result<String> {
    use std::os::unix::ffi::OsStrExt;

    let path_bytes = path.as_os_str().as_bytes();
    let c_path = std::ffi::CString::new(path_bytes)
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "path contains null byte"))?;

    // Raw open with O_RDONLY | O_CLOEXEC, optionally O_NOATIME
    let mut flags = libc::O_RDONLY | libc::O_CLOEXEC;
    if NOATIME_SUPPORTED.load(Ordering::Relaxed) {
        flags |= libc::O_NOATIME;
    }

    let fd = unsafe { libc::open(c_path.as_ptr(), flags) };
    if fd < 0 {
        let err = io::Error::last_os_error();
        if err.raw_os_error() == Some(libc::EPERM) && flags & libc::O_NOATIME != 0 {
            NOATIME_SUPPORTED.store(false, Ordering::Relaxed);
            let fd2 = unsafe { libc::open(c_path.as_ptr(), libc::O_RDONLY | libc::O_CLOEXEC) };
            if fd2 < 0 {
                return Err(io::Error::last_os_error());
            }
            return hash_from_raw_fd(algo, fd2);
        }
        return Err(err);
    }
    hash_from_raw_fd(algo, fd)
}

/// Hash from a raw fd — dispatches by file size for optimal I/O strategy.
/// Handles tiny (stack buffer), small (thread-local buffer), large (mmap), and
/// non-regular (streaming) files.
#[cfg(target_os = "linux")]
fn hash_from_raw_fd(algo: HashAlgorithm, fd: i32) -> io::Result<String> {
    // Raw fstat to determine size and type
    let mut stat: libc::stat = unsafe { std::mem::zeroed() };
    if unsafe { libc::fstat(fd, &mut stat) } != 0 {
        let err = io::Error::last_os_error();
        unsafe {
            libc::close(fd);
        }
        return Err(err);
    }
    let size = stat.st_size as u64;
    let is_regular = (stat.st_mode & libc::S_IFMT) == libc::S_IFREG;

    // Empty regular file
    if is_regular && size == 0 {
        unsafe {
            libc::close(fd);
        }
        return hash_bytes(algo, &[]);
    }

    // Tiny files (<8KB): raw read into stack buffer, no File wrapper needed.
    // Entire I/O in 3 raw syscalls: open + read + close.
    if is_regular && size < TINY_FILE_LIMIT {
        let mut buf = [0u8; 8192];
        let mut total = 0usize;
        while total < size as usize {
            let n = unsafe {
                libc::read(
                    fd,
                    buf[total..].as_mut_ptr() as *mut libc::c_void,
                    (size as usize) - total,
                )
            };
            if n < 0 {
                let err = io::Error::last_os_error();
                if err.kind() == io::ErrorKind::Interrupted {
                    continue;
                }
                unsafe {
                    libc::close(fd);
                }
                return Err(err);
            }
            if n == 0 {
                break;
            }
            total += n as usize;
        }
        unsafe {
            libc::close(fd);
        }
        return hash_bytes(algo, &buf[..total]);
    }

    // For larger files, wrap fd in File for RAII close and existing optimized paths.
    use std::os::unix::io::FromRawFd;
    let file = unsafe { File::from_raw_fd(fd) };

    if is_regular && size > 0 {
        return hash_regular_file(algo, file, size);
    }

    // Non-regular files: streaming hash
    hash_reader(algo, file)
}

/// Issue readahead hints for ALL file paths (no size threshold).
/// For multi-file benchmarks, even small files benefit from batched readahead.
#[cfg(target_os = "linux")]
pub fn readahead_files_all(paths: &[&Path]) {
    use std::os::unix::io::AsRawFd;
    for path in paths {
        if let Ok(file) = open_noatime(path) {
            if let Ok(meta) = file.metadata() {
                if meta.file_type().is_file() {
                    let len = meta.len();
                    unsafe {
                        libc::posix_fadvise(
                            file.as_raw_fd(),
                            0,
                            len as i64,
                            libc::POSIX_FADV_WILLNEED,
                        );
                    }
                }
            }
        }
    }
}

#[cfg(not(target_os = "linux"))]
pub fn readahead_files_all(_paths: &[&Path]) {}

/// Print hash result in GNU format: "hash  filename\n"
/// Uses raw byte writes to avoid std::fmt overhead.
pub fn print_hash(
    out: &mut impl Write,
    hash: &str,
    filename: &str,
    binary: bool,
) -> io::Result<()> {
    let mode = if binary { b'*' } else { b' ' };
    out.write_all(hash.as_bytes())?;
    out.write_all(&[b' ', mode])?;
    out.write_all(filename.as_bytes())?;
    out.write_all(b"\n")
}

/// Print hash in GNU format with NUL terminator instead of newline.
pub fn print_hash_zero(
    out: &mut impl Write,
    hash: &str,
    filename: &str,
    binary: bool,
) -> io::Result<()> {
    let mode = if binary { b'*' } else { b' ' };
    out.write_all(hash.as_bytes())?;
    out.write_all(&[b' ', mode])?;
    out.write_all(filename.as_bytes())?;
    out.write_all(b"\0")
}

// ── Single-write output buffer ─────────────────────────────────────
// For multi-file workloads, batch the entire "hash  filename\n" line into
// a single write() call. This halves the number of BufWriter flushes.

// Thread-local output line buffer for batched writes.
// Reused across files to avoid per-file allocation.
thread_local! {
    static LINE_BUF: RefCell<Vec<u8>> = RefCell::new(Vec::with_capacity(256));
}

/// Build and write the standard GNU hash output line in a single write() call.
/// Format: "hash  filename\n" or "hash *filename\n" (binary mode).
/// For escaped filenames: "\hash  escaped_filename\n".
#[inline]
pub fn write_hash_line(
    out: &mut impl Write,
    hash: &str,
    filename: &str,
    binary: bool,
    zero: bool,
    escaped: bool,
) -> io::Result<()> {
    LINE_BUF.with(|cell| {
        let mut buf = cell.borrow_mut();
        buf.clear();
        let mode = if binary { b'*' } else { b' ' };
        let term = if zero { b'\0' } else { b'\n' };
        if escaped {
            buf.push(b'\\');
        }
        buf.extend_from_slice(hash.as_bytes());
        buf.push(b' ');
        buf.push(mode);
        buf.extend_from_slice(filename.as_bytes());
        buf.push(term);
        out.write_all(&buf)
    })
}

/// Build and write BSD tag format output in a single write() call.
/// Format: "ALGO (filename) = hash\n"
#[inline]
pub fn write_hash_tag_line(
    out: &mut impl Write,
    algo_name: &str,
    hash: &str,
    filename: &str,
    zero: bool,
) -> io::Result<()> {
    LINE_BUF.with(|cell| {
        let mut buf = cell.borrow_mut();
        buf.clear();
        let term = if zero { b'\0' } else { b'\n' };
        buf.extend_from_slice(algo_name.as_bytes());
        buf.extend_from_slice(b" (");
        buf.extend_from_slice(filename.as_bytes());
        buf.extend_from_slice(b") = ");
        buf.extend_from_slice(hash.as_bytes());
        buf.push(term);
        out.write_all(&buf)
    })
}

/// Print hash result in BSD tag format: "ALGO (filename) = hash\n"
pub fn print_hash_tag(
    out: &mut impl Write,
    algo: HashAlgorithm,
    hash: &str,
    filename: &str,
) -> io::Result<()> {
    out.write_all(algo.name().as_bytes())?;
    out.write_all(b" (")?;
    out.write_all(filename.as_bytes())?;
    out.write_all(b") = ")?;
    out.write_all(hash.as_bytes())?;
    out.write_all(b"\n")
}

/// Print hash in BSD tag format with NUL terminator.
pub fn print_hash_tag_zero(
    out: &mut impl Write,
    algo: HashAlgorithm,
    hash: &str,
    filename: &str,
) -> io::Result<()> {
    out.write_all(algo.name().as_bytes())?;
    out.write_all(b" (")?;
    out.write_all(filename.as_bytes())?;
    out.write_all(b") = ")?;
    out.write_all(hash.as_bytes())?;
    out.write_all(b"\0")
}

/// Print hash in BSD tag format with BLAKE2b length info:
/// "BLAKE2b (filename) = hash" for 512-bit, or
/// "BLAKE2b-256 (filename) = hash" for other lengths.
pub fn print_hash_tag_b2sum(
    out: &mut impl Write,
    hash: &str,
    filename: &str,
    bits: usize,
) -> io::Result<()> {
    if bits == 512 {
        out.write_all(b"BLAKE2b (")?;
    } else {
        // Use write! for the rare non-512 path (negligible overhead per file)
        write!(out, "BLAKE2b-{} (", bits)?;
    }
    out.write_all(filename.as_bytes())?;
    out.write_all(b") = ")?;
    out.write_all(hash.as_bytes())?;
    out.write_all(b"\n")
}

/// Print hash in BSD tag format with BLAKE2b length info and NUL terminator.
pub fn print_hash_tag_b2sum_zero(
    out: &mut impl Write,
    hash: &str,
    filename: &str,
    bits: usize,
) -> io::Result<()> {
    if bits == 512 {
        out.write_all(b"BLAKE2b (")?;
    } else {
        write!(out, "BLAKE2b-{} (", bits)?;
    }
    out.write_all(filename.as_bytes())?;
    out.write_all(b") = ")?;
    out.write_all(hash.as_bytes())?;
    out.write_all(b"\0")
}

/// Options for check mode.
pub struct CheckOptions {
    pub quiet: bool,
    pub status_only: bool,
    pub strict: bool,
    pub warn: bool,
    pub ignore_missing: bool,
    /// Prefix for per-line format warnings, e.g., "fmd5sum: checksums.txt".
    /// When non-empty, warnings use GNU format: "{prefix}: {line}: message".
    /// When empty, uses generic format: "line {line}: message".
    pub warn_prefix: String,
}

/// Result of check mode verification.
pub struct CheckResult {
    pub ok: usize,
    pub mismatches: usize,
    pub format_errors: usize,
    pub read_errors: usize,
    /// Number of files skipped because they were missing and --ignore-missing was set.
    pub ignored_missing: usize,
}

/// Verify checksums from a check file.
/// Each line should be "hash  filename" or "hash *filename" or "ALGO (filename) = hash".
pub fn check_file<R: BufRead>(
    algo: HashAlgorithm,
    reader: R,
    opts: &CheckOptions,
    out: &mut impl Write,
    err_out: &mut impl Write,
) -> io::Result<CheckResult> {
    let quiet = opts.quiet;
    let status_only = opts.status_only;
    let warn = opts.warn;
    let ignore_missing = opts.ignore_missing;
    let mut ok_count = 0;
    let mut mismatch_count = 0;
    let mut format_errors = 0;
    let mut read_errors = 0;
    let mut ignored_missing_count = 0;
    let mut line_num = 0;

    for line_result in reader.lines() {
        line_num += 1;
        let line = line_result?;
        let line = line.trim_end();

        if line.is_empty() {
            continue;
        }

        // Parse "hash  filename" or "hash *filename" or "ALGO (file) = hash"
        let (expected_hash, filename) = match parse_check_line(line) {
            Some(v) => v,
            None => {
                format_errors += 1;
                if warn {
                    out.flush()?;
                    if opts.warn_prefix.is_empty() {
                        writeln!(
                            err_out,
                            "line {}: improperly formatted {} checksum line",
                            line_num,
                            algo.name()
                        )?;
                    } else {
                        writeln!(
                            err_out,
                            "{}: {}: improperly formatted {} checksum line",
                            opts.warn_prefix,
                            line_num,
                            algo.name()
                        )?;
                    }
                }
                continue;
            }
        };

        // Compute actual hash
        let actual = match hash_file(algo, Path::new(filename)) {
            Ok(h) => h,
            Err(e) => {
                if ignore_missing && e.kind() == io::ErrorKind::NotFound {
                    ignored_missing_count += 1;
                    continue;
                }
                read_errors += 1;
                if !status_only {
                    out.flush()?;
                    writeln!(err_out, "{}: {}", filename, e)?;
                    writeln!(out, "{}: FAILED open or read", filename)?;
                }
                continue;
            }
        };

        if actual.eq_ignore_ascii_case(expected_hash) {
            ok_count += 1;
            if !quiet && !status_only {
                writeln!(out, "{}: OK", filename)?;
            }
        } else {
            mismatch_count += 1;
            if !status_only {
                writeln!(out, "{}: FAILED", filename)?;
            }
        }
    }

    Ok(CheckResult {
        ok: ok_count,
        mismatches: mismatch_count,
        format_errors,
        read_errors,
        ignored_missing: ignored_missing_count,
    })
}

/// Parse a checksum line in any supported format.
pub fn parse_check_line(line: &str) -> Option<(&str, &str)> {
    // Try BSD tag format: "ALGO (filename) = hash"
    let rest = line
        .strip_prefix("MD5 (")
        .or_else(|| line.strip_prefix("SHA1 ("))
        .or_else(|| line.strip_prefix("SHA224 ("))
        .or_else(|| line.strip_prefix("SHA256 ("))
        .or_else(|| line.strip_prefix("SHA384 ("))
        .or_else(|| line.strip_prefix("SHA512 ("))
        .or_else(|| line.strip_prefix("BLAKE2b ("))
        .or_else(|| {
            // Handle BLAKE2b-NNN (filename) = hash
            if line.starts_with("BLAKE2b-") {
                let after = &line["BLAKE2b-".len()..];
                if let Some(sp) = after.find(" (") {
                    if after[..sp].bytes().all(|b| b.is_ascii_digit()) {
                        return Some(&after[sp + 2..]);
                    }
                }
            }
            None
        });
    if let Some(rest) = rest {
        if let Some(paren_idx) = rest.find(") = ") {
            let filename = &rest[..paren_idx];
            let hash = &rest[paren_idx + 4..];
            return Some((hash, filename));
        }
    }

    // Handle backslash-escaped lines (leading '\')
    let line = line.strip_prefix('\\').unwrap_or(line);

    // Standard format: "hash  filename"
    if let Some(idx) = line.find("  ") {
        let hash = &line[..idx];
        let rest = &line[idx + 2..];
        return Some((hash, rest));
    }
    // Binary mode: "hash *filename"
    if let Some(idx) = line.find(" *") {
        let hash = &line[..idx];
        let rest = &line[idx + 2..];
        return Some((hash, rest));
    }
    None
}

/// Parse a BSD-style tag line: "ALGO (filename) = hash"
/// Returns (expected_hash, filename, optional_bits).
/// `bits` is the hash length parsed from the algo name (e.g., BLAKE2b-256 -> Some(256)).
pub fn parse_check_line_tag(line: &str) -> Option<(&str, &str, Option<usize>)> {
    let paren_start = line.find(" (")?;
    let algo_part = &line[..paren_start];
    let rest = &line[paren_start + 2..];
    let paren_end = rest.find(") = ")?;
    let filename = &rest[..paren_end];
    let hash = &rest[paren_end + 4..];

    // Parse optional bit length from algo name (e.g., "BLAKE2b-256" -> Some(256))
    let bits = if let Some(dash_pos) = algo_part.rfind('-') {
        algo_part[dash_pos + 1..].parse::<usize>().ok()
    } else {
        None
    };

    Some((hash, filename, bits))
}

/// Read as many bytes as possible into buf, retrying on partial reads.
/// Ensures each hash update gets a full buffer (fewer update calls = less overhead).
/// Fast path: regular file reads usually return the full buffer on the first call.
#[inline]
fn read_full(reader: &mut impl Read, buf: &mut [u8]) -> io::Result<usize> {
    // Fast path: first read() usually fills the entire buffer for regular files
    let n = reader.read(buf)?;
    if n == buf.len() || n == 0 {
        return Ok(n);
    }
    // Slow path: partial read — retry to fill buffer (pipes, slow devices)
    let mut total = n;
    while total < buf.len() {
        match reader.read(&mut buf[total..]) {
            Ok(0) => break,
            Ok(n) => total += n,
            Err(e) if e.kind() == io::ErrorKind::Interrupted => continue,
            Err(e) => return Err(e),
        }
    }
    Ok(total)
}

/// Compile-time generated 2-byte hex pair lookup table.
/// Each byte maps directly to its 2-char hex representation — single lookup per byte.
const fn generate_hex_table() -> [[u8; 2]; 256] {
    let hex = b"0123456789abcdef";
    let mut table = [[0u8; 2]; 256];
    let mut i = 0;
    while i < 256 {
        table[i] = [hex[i >> 4], hex[i & 0xf]];
        i += 1;
    }
    table
}

const HEX_TABLE: [[u8; 2]; 256] = generate_hex_table();

/// Fast hex encoding using 2-byte pair lookup table — one lookup per input byte.
/// Uses String directly instead of Vec<u8> to avoid the from_utf8 conversion overhead.
pub(crate) fn hex_encode(bytes: &[u8]) -> String {
    let len = bytes.len() * 2;
    let mut hex = String::with_capacity(len);
    // SAFETY: We write exactly `len` valid ASCII hex bytes into the String's buffer.
    unsafe {
        let buf = hex.as_mut_vec();
        buf.set_len(len);
        hex_encode_to_slice(bytes, buf);
    }
    hex
}

/// Encode bytes as hex directly into a pre-allocated output slice.
/// Output slice must be at least `bytes.len() * 2` bytes long.
#[inline]
fn hex_encode_to_slice(bytes: &[u8], out: &mut [u8]) {
    // SAFETY: We write exactly bytes.len()*2 bytes into `out`, which must be large enough.
    unsafe {
        let ptr = out.as_mut_ptr();
        for (i, &b) in bytes.iter().enumerate() {
            let pair = *HEX_TABLE.get_unchecked(b as usize);
            *ptr.add(i * 2) = pair[0];
            *ptr.add(i * 2 + 1) = pair[1];
        }
    }
}
