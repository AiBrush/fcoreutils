#!/usr/bin/env python3
"""Security tests for fsha1sum — uses shared framework."""
import sys, os, hashlib, random, tempfile
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', '..', 'tests'))
from security_framework import SecurityTestFramework

config = {
    'tool_name': 'sha1sum',
    'bin_name': 'fsha1sum',
    'gnu_path': '/usr/bin/sha1sum',
    'bss_size': 65536,
    'max_binary_size': 100000,
    'test_args': [],
    'test_stdin': b'hello world\n',
    'timeout': 5,
}

def sha1(data):
    """Compute SHA-1 hash of data using Python hashlib."""
    return hashlib.sha1(data).hexdigest()

def tool_specific_tests(fw):
    """13. Tool-specific: sha1sum tests."""
    fw.log("\n=== Sha1sum-Specific Tests ===")

    # Known hash test vectors (FIPS 180-1)
    vectors = [
        (b"", "da39a3ee5e6b4b0d3255bfef95601890afd80709"),
        (b"abc", "a9993e364706816aba3e25717850c26c9cd0d89d"),
        (b"abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq",
         "84983e441c3bd26ebaae4aa1f95129e5e54670f1"),
    ]

    for data, expected_hash in vectors:
        rc, out, _ = fw.run_asm([], stdin_data=data)
        if rc == 0:
            output_hash = out.decode().strip().split()[0] if out else ""
            fw.report_result(output_hash == expected_hash,
                             f"sha1: vector '{data[:20].decode(errors='replace')}...' = {expected_hash[:16]}...")
        else:
            fw.report_result(False, f"sha1: vector failed (rc={rc})")

    # Compare with GNU on all vectors
    for data, expected_hash in vectors:
        rc_a, out_a, _ = fw.run_asm([], stdin_data=data)
        rc_g, out_g, _ = fw.run_gnu([], stdin_data=data)
        if rc_a == 0 and rc_g == 0:
            hash_a = out_a.decode().strip().split()[0] if out_a else ""
            hash_g = out_g.decode().strip().split()[0] if out_g else ""
            fw.report_result(hash_a == hash_g, f"sha1: GNU match '{data[:20].decode(errors='replace')}...'")

    # Verify output format: "hash  -\n" (two spaces and dash for stdin)
    rc, out, _ = fw.run_asm([], stdin_data=b"test")
    if rc == 0:
        out_str = out.decode().strip()
        parts = out_str.split()
        fw.report_result(len(parts) >= 2 and len(parts[0]) == 40 and parts[1] == "-",
                         "sha1: output format 'hash  -'")
    else:
        fw.report_result(False, "sha1: output format check (command failed)")

    # Compare with GNU output format
    rc_a, out_a, _ = fw.run_asm([], stdin_data=b"hello\n")
    rc_g, out_g, _ = fw.run_gnu([], stdin_data=b"hello\n")
    fw.report_result(out_a == out_g, "sha1: output format matches GNU exactly")

    # Binary data hashing (all 256 byte values)
    all_bytes = bytes(range(256))
    expected = sha1(all_bytes)
    rc, out, _ = fw.run_asm([], stdin_data=all_bytes)
    if rc == 0:
        output_hash = out.decode().strip().split()[0] if out else ""
        fw.report_result(output_hash == expected, "sha1: all 256 byte values hash correct")

    # Large file hashing (1MB+)
    large_data = os.urandom(1024 * 1024)
    expected = sha1(large_data)
    rc, out, _ = fw.run_asm([], stdin_data=large_data, timeout=15)
    if rc == 0:
        output_hash = out.decode().strip().split()[0] if out else ""
        fw.report_result(output_hash == expected, "sha1: 1MB hash correct")
    else:
        fw.report_result(False, "sha1: 1MB hash (command failed)")

    # Random data hashing accuracy (compare with Python hashlib)
    for i in range(20):
        size = random.randint(1, 10000)
        data = os.urandom(size)
        expected = sha1(data)
        rc, out, _ = fw.run_asm([], stdin_data=data)
        if rc == 0:
            output_hash = out.decode().strip().split()[0] if out else ""
            fw.report_result(output_hash == expected, f"sha1: random {size} bytes hash correct")
        else:
            fw.report_result(False, f"sha1: random {size} bytes (command failed)")

    # File hashing
    with tempfile.TemporaryDirectory() as td:
        fpath = os.path.join(td, "test.txt")
        with open(fpath, "wb") as f:
            f.write(b"hello\n")
        rc_a, out_a, _ = fw.run_asm([fpath])
        rc_g, out_g, _ = fw.run_gnu([fpath])
        fw.report_result(out_a == out_g and rc_a == rc_g, "sha1: file hash matches GNU")

    # --help/--version
    rc_a, out_a, _ = fw.run_asm(["--help"])
    fw.report_result(rc_a == 0 and len(out_a) > 0, "sha1sum: --help works")

    rc_a, out_a, _ = fw.run_asm(["--version"])
    fw.report_result(rc_a == 0 and len(out_a) > 0, "sha1sum: --version works")

if __name__ == '__main__':
    fw = SecurityTestFramework(config)
    fw.run_all(tool_specific_fn=tool_specific_tests)
