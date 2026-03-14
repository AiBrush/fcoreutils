#!/usr/bin/env python3
"""Security tests for fb2sum — uses shared framework."""
import sys, os, tempfile, hashlib, random
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', '..', 'tests'))
from security_framework import SecurityTestFramework

config = {
    'tool_name': 'b2sum',
    'bin_name': 'fb2sum',
    'gnu_path': '/usr/bin/b2sum',
    'bss_size': 65536,
    'max_binary_size': 100000,
    'test_args': [],
    'test_stdin': b"hello world\n",
    'timeout': 5,
}

def blake2b_hash(data):
    """Compute BLAKE2b-512 hash of data using Python hashlib."""
    return hashlib.blake2b(data).hexdigest()

def tool_specific_tests(fw):
    """13. Tool-specific: b2sum BLAKE2b checksum tests."""
    fw.log("\n=== B2sum-Specific Tests ===")

    # Known hash test vectors (BLAKE2b-512)
    vectors = [
        (b"", "786a02f742015903c6c6fd852552d272912f4740e15847618a86e217f71f5419d25e1031afee585313896444934eb04b903a685b1448b755d56f701afe9be2ce"),
        (b"abc", "ba80a53f981c4d0d6a2797b69f12f6e94c212f14685ac4b74b12bb6fdbffa2d17d87c5392aab792dc252d5de4533cc9518d38aa8dbf1925ab92386edd4009923"),
    ]

    for data, expected_hash in vectors:
        rc, out, _ = fw.run_asm([], stdin_data=data)
        if rc == 0:
            output_hash = out.decode().strip().split()[0] if out else ""
            fw.report_result(output_hash == expected_hash,
                             f"b2sum: vector '{data[:20].decode(errors='replace')}' = {expected_hash[:16]}...")
        else:
            fw.report_result(False, f"b2sum: vector failed (rc={rc})")

    # Compare with GNU on all vectors
    for data, expected_hash in vectors:
        rc_a, out_a, _ = fw.run_asm([], stdin_data=data)
        rc_g, out_g, _ = fw.run_gnu([], stdin_data=data)
        if rc_a == 0 and rc_g == 0:
            hash_a = out_a.decode().strip().split()[0] if out_a else ""
            hash_g = out_g.decode().strip().split()[0] if out_g else ""
            fw.report_result(hash_a == hash_g, f"b2sum: GNU match '{data[:20].decode(errors='replace')}'")

    # Verify output format: "hash  -\n" (two spaces and dash for stdin)
    rc, out, _ = fw.run_asm([], stdin_data=b"test")
    if rc == 0:
        out_str = out.decode().strip()
        parts = out_str.split()
        fw.report_result(len(parts) >= 2 and len(parts[0]) == 128 and parts[1] == "-",
                         "b2sum: output format 'hash  -'")
    else:
        fw.report_result(False, "b2sum: output format check (command failed)")

    # Compare with GNU output format
    rc_a, out_a, _ = fw.run_asm([], stdin_data=b"hello\n")
    rc_g, out_g, _ = fw.run_gnu([], stdin_data=b"hello\n")
    fw.report_result(out_a == out_g, "b2sum: output format matches GNU exactly")

    # Binary data hashing (all 256 byte values)
    all_bytes = bytes(range(256))
    expected = blake2b_hash(all_bytes)
    rc, out, _ = fw.run_asm([], stdin_data=all_bytes)
    if rc == 0:
        output_hash = out.decode().strip().split()[0] if out else ""
        fw.report_result(output_hash == expected, "b2sum: all 256 byte values hash correct")

    # Large file hashing (1MB+)
    large_data = os.urandom(1024 * 1024)
    expected = blake2b_hash(large_data)
    rc, out, _ = fw.run_asm([], stdin_data=large_data, timeout=15)
    if rc == 0:
        output_hash = out.decode().strip().split()[0] if out else ""
        fw.report_result(output_hash == expected, "b2sum: 1MB hash correct")
    else:
        fw.report_result(False, "b2sum: 1MB hash (command failed)")

    # Random data hashing accuracy (compare with Python hashlib)
    for i in range(20):
        size = random.randint(1, 10000)
        data = os.urandom(size)
        expected = blake2b_hash(data)
        rc, out, _ = fw.run_asm([], stdin_data=data)
        if rc == 0:
            output_hash = out.decode().strip().split()[0] if out else ""
            fw.report_result(output_hash == expected, f"b2sum: random {size} bytes hash correct")
        else:
            fw.report_result(False, f"b2sum: random {size} bytes (command failed)")

    # File hashing
    with tempfile.TemporaryDirectory() as td:
        fpath = os.path.join(td, "test.txt")
        with open(fpath, "wb") as f:
            f.write(b"hello\n")
        rc_a, out_a, _ = fw.run_asm([fpath])
        rc_g, out_g, _ = fw.run_gnu([fpath])
        fw.report_result(out_a == out_g and rc_a == rc_g, "b2sum: file hash matches GNU")

    # --help/--version
    rc_a, out_a, _ = fw.run_asm(["--help"])
    fw.report_result(rc_a == 0 and len(out_a) > 0, "b2sum: --help works")

    rc_a, out_a, _ = fw.run_asm(["--version"])
    fw.report_result(rc_a == 0 and len(out_a) > 0, "b2sum: --version works")

if __name__ == '__main__':
    fw = SecurityTestFramework(config)
    fw.run_all(tool_specific_fn=tool_specific_tests)
