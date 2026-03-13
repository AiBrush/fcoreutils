#!/usr/bin/env python3
"""Security tests for fmd5sum — uses shared framework."""
import sys, os, random, hashlib
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', '..', 'tests'))
from security_framework import SecurityTestFramework

config = {
    'tool_name': 'md5sum',
    'bin_name': 'fmd5sum',
    'gnu_path': '/usr/bin/md5sum',
    'bss_size': 65536,
    'max_binary_size': 30000,
    'test_args': [],
    'test_stdin': b'hello world\n',
}

def md5(data):
    return hashlib.md5(data).hexdigest()

def tool_specific_tests(fw):
    """13. Tool-specific: md5sum hash correctness tests."""
    fw.log("\n=== Md5sum-Specific Tests ===")

    # Known hash test vectors (RFC 1321)
    vectors = [
        (b"", "d41d8cd98f00b204e9800998ecf8427e"),
        (b"a", "0cc175b9c0f1b6a831c399e269772661"),
        (b"abc", "900150983cd24fb0d6963f7d28e17f72"),
        (b"message digest", "f96b697d7cb7938d525a2f31aaf161d0"),
        (b"abcdefghijklmnopqrstuvwxyz", "c3fcd3d76192e4007dfb496cca67e13b"),
        (b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789",
         "d174ab98d277d9f5a5611c2c9f419d9f"),
        (b"12345678901234567890123456789012345678901234567890123456789012345678901234567890",
         "57edf4a22be3c955ac49da2e2107b67a"),
    ]

    for data, expected_hash in vectors:
        rc, out, _ = fw.run_asm([], stdin_data=data)
        if rc == 0:
            output_hash = out.decode().strip().split()[0] if out else ""
            fw.report_result(output_hash == expected_hash,
                             f"md5: vector '{data[:20].decode(errors='replace')}...' = {expected_hash[:16]}...")
        else:
            fw.report_result(False, f"md5: vector failed (rc={rc})")

    # Compare with GNU on all vectors
    for data, expected_hash in vectors:
        rc_a, out_a, _ = fw.run_asm([], stdin_data=data)
        rc_g, out_g, _ = fw.run_gnu([], stdin_data=data)
        if rc_a == 0 and rc_g == 0:
            hash_a = out_a.decode().strip().split()[0] if out_a else ""
            hash_g = out_g.decode().strip().split()[0] if out_g else ""
            fw.report_result(hash_a == hash_g, f"md5: GNU match '{data[:20].decode(errors='replace')}...'")

    # Output format: "hash  -\n"
    rc, out, _ = fw.run_asm([], stdin_data=b"test")
    if rc == 0:
        out_str = out.decode().strip()
        parts = out_str.split()
        fw.report_result(len(parts) >= 2 and len(parts[0]) == 32 and parts[1] == "-",
                         "md5: output format 'hash  -'")

    # Compare with GNU output format
    rc_a, out_a, _ = fw.run_asm([], stdin_data=b"hello\n")
    rc_g, out_g, _ = fw.run_gnu([], stdin_data=b"hello\n")
    fw.report_result(out_a == out_g, "md5: output format matches GNU exactly")

    # Binary data hashing (all 256 byte values)
    all_bytes = bytes(range(256))
    expected = md5(all_bytes)
    rc, out, _ = fw.run_asm([], stdin_data=all_bytes)
    if rc == 0:
        output_hash = out.decode().strip().split()[0] if out else ""
        fw.report_result(output_hash == expected, "md5: all 256 byte values hash correct")

    # Large file hashing (1MB)
    large_data = os.urandom(1024 * 1024)
    expected = md5(large_data)
    rc, out, _ = fw.run_asm([], stdin_data=large_data, timeout=15)
    if rc == 0:
        output_hash = out.decode().strip().split()[0] if out else ""
        fw.report_result(output_hash == expected, "md5: 1MB hash correct")
    else:
        fw.report_result(False, "md5: 1MB hash (command failed)")

    # Empty input hash
    expected = "d41d8cd98f00b204e9800998ecf8427e"
    rc, out, _ = fw.run_asm([], stdin_data=b"")
    if rc == 0:
        output_hash = out.decode().strip().split()[0] if out else ""
        fw.report_result(output_hash == expected, "md5: empty input hash correct")

    # Random data hashing accuracy
    for i in range(20):
        size = random.randint(1, 10000)
        data = os.urandom(size)
        expected = md5(data)
        rc, out, _ = fw.run_asm([], stdin_data=data)
        if rc == 0:
            output_hash = out.decode().strip().split()[0] if out else ""
            fw.report_result(output_hash == expected, f"md5: random {size} bytes hash correct")
        else:
            fw.report_result(False, f"md5: random {size} bytes (command failed)")

    # Hash at BSS boundaries
    BSS_SIZE = fw.bss_size
    for size_name, size in [("BSS_SIZE-1", BSS_SIZE-1), ("BSS_SIZE", BSS_SIZE),
                             ("BSS_SIZE+1", BSS_SIZE+1), ("2*BSS_SIZE", BSS_SIZE*2)]:
        data = b"A" * size
        expected = md5(data)
        rc, out, _ = fw.run_asm([], stdin_data=data)
        if rc == 0:
            output_hash = out.decode().strip().split()[0] if out else ""
            fw.report_result(output_hash == expected, f"md5: BSS boundary {size_name} hash correct")
        else:
            fw.report_result(False, f"md5: BSS boundary {size_name} (command failed)")

    # Block boundary tests (55, 56, 64 bytes)
    for desc, size in [("55 bytes (block boundary)", 55),
                       ("56 bytes (padding boundary)", 56),
                       ("64 bytes (one block)", 64)]:
        data = b"A" * size
        expected = md5(data)
        rc, out, _ = fw.run_asm([], stdin_data=data)
        if rc == 0:
            output_hash = out.decode().strip().split()[0] if out else ""
            fw.report_result(output_hash == expected, f"md5: {desc} hash correct")

    # --help/--version
    rc_a, out_a, _ = fw.run_asm(["--help"])
    fw.report_result(rc_a == 0 and len(out_a) > 0, "md5sum: --help works")

    rc_a, out_a, _ = fw.run_asm(["--version"])
    fw.report_result(rc_a == 0 and len(out_a) > 0, "md5sum: --version works")

if __name__ == '__main__':
    fw = SecurityTestFramework(config)
    fw.run_all(tool_specific_fn=tool_specific_tests)
