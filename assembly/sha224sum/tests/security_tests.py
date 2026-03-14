#!/usr/bin/env python3
"""Security tests for fsha224sum — uses shared framework."""
import sys, os, random, hashlib
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', '..', 'tests'))
from security_framework import SecurityTestFramework

config = {
    'tool_name': 'sha224sum',
    'bin_name': 'fsha224sum',
    'gnu_path': '/usr/bin/sha224sum',
    'bss_size': 65536,
    'max_binary_size': 30000,
    'test_args': [],
    'test_stdin': b'hello world\n',
}

def tool_specific_tests(fw):
    """13. Tool-specific: SHA-224 hash correctness tests."""
    fw.log("\n=== Sha224sum-Specific Tests ===")

    # FIPS 180-4 known test vectors
    vectors = [
        (b"", "d14a028c2a3a2bc9476102bb288234c415a2b01f828ea62ac5b3e42f"),
        (b"abc", "23097d223405d8228642a477bda255b32aadbce4bda0b3f7e36c9da7"),
        (b"abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq",
         "75388b16512776cc5dba5da1fd890150b0c6455cb4f58b1952522525"),
    ]

    for data, expected_hash in vectors:
        rc, out, _ = fw.run_asm([], stdin_data=data)
        if rc == 0:
            output_hash = out.decode().strip().split()[0] if out else ""
            fw.report_result(output_hash == expected_hash,
                f"sha224: vector '{data[:20].decode(errors='replace')}...' = {expected_hash[:16]}...")
        else:
            fw.report_result(False, f"sha224: vector failed (rc={rc})")

    # Compare with GNU on all vectors
    for data, expected_hash in vectors:
        rc_a, out_a, _ = fw.run_asm([], stdin_data=data)
        rc_g, out_g, _ = fw.run_gnu([], stdin_data=data)
        if rc_a == 0 and rc_g == 0:
            hash_a = out_a.decode().strip().split()[0] if out_a else ""
            hash_g = out_g.decode().strip().split()[0] if out_g else ""
            fw.report_result(hash_a == hash_g,
                f"sha224: GNU match '{data[:20].decode(errors='replace')}...'")

    # Verify output format: "hash  -\n"
    rc, out, _ = fw.run_asm([], stdin_data=b"test")
    if rc == 0:
        out_str = out.decode().strip()
        parts = out_str.split()
        fw.report_result(len(parts) >= 2 and len(parts[0]) == 56 and parts[1] == "-",
            "sha224: output format 'hash  -'")

    # Compare with GNU output format
    rc_a, out_a, _ = fw.run_asm([], stdin_data=b"hello\n")
    rc_g, out_g, _ = fw.run_gnu([], stdin_data=b"hello\n")
    fw.report_result(out_a == out_g, "sha224: output format matches GNU exactly")

    # Binary data hashing (all 256 byte values)
    all_bytes = bytes(range(256))
    expected = hashlib.sha224(all_bytes).hexdigest()
    rc, out, _ = fw.run_asm([], stdin_data=all_bytes)
    if rc == 0:
        output_hash = out.decode().strip().split()[0] if out else ""
        fw.report_result(output_hash == expected, "sha224: all 256 byte values hash correct")

    # Large file hashing (1MB)
    large_data = os.urandom(1024 * 1024)
    expected = hashlib.sha224(large_data).hexdigest()
    rc, out, _ = fw.run_asm([], stdin_data=large_data, timeout=15)
    if rc == 0:
        output_hash = out.decode().strip().split()[0] if out else ""
        fw.report_result(output_hash == expected, "sha224: 1MB hash correct")

    # Random data hashing accuracy
    for i in range(20):
        size = random.randint(1, 10000)
        data = os.urandom(size)
        expected = hashlib.sha224(data).hexdigest()
        rc, out, _ = fw.run_asm([], stdin_data=data)
        if rc == 0:
            output_hash = out.decode().strip().split()[0] if out else ""
            fw.report_result(output_hash == expected, f"sha224: random {size} bytes hash correct")

    # --help/--version
    rc_a, out_a, _ = fw.run_asm(["--help"])
    fw.report_result(rc_a == 0 and len(out_a) > 0, "sha224sum: --help works")
    rc_a, out_a, _ = fw.run_asm(["--version"])
    fw.report_result(rc_a == 0 and len(out_a) > 0, "sha224sum: --version works")

if __name__ == '__main__':
    fw = SecurityTestFramework(config)
    fw.run_all(tool_specific_fn=tool_specific_tests)
