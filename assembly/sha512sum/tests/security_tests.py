#!/usr/bin/env python3
"""Security tests for fsha512sum — uses shared framework."""
import sys, os, random, hashlib
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', '..', 'tests'))
from security_framework import SecurityTestFramework

config = {
    'tool_name': 'sha512sum',
    'bin_name': 'fsha512sum',
    'gnu_path': '/usr/bin/sha512sum',
    'bss_size': 65536,
    'max_binary_size': 30000,
    'test_args': [],
    'test_stdin': b'hello world\n',
}

def tool_specific_tests(fw):
    """13. Tool-specific: SHA-512 hash correctness tests."""
    fw.log("\n=== Sha512sum-Specific Tests ===")

    # FIPS 180-4 known test vectors
    vectors = [
        (b"", "cf83e1357eefb8bdf1542850d66d8007d620e4050b5715dc83f4a921d36ce9ce47d0d13c5d85f2b0ff8318d2877eec2f63b931bd47417a81a538327af927da3e"),
        (b"abc", "ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f"),
        (b"abcdefghbcdefghicdefghijdefghijkefghijklfghijklmghijklmnhijklmnoijklmnopjklmnopqklmnopqrlmnopqrsmnopqrstnopqrstu",
         "8e959b75dae313da8cf4f72814fc143f8f7779c6eb9f7fa17299aeadb6889018501d289e4900f7e4331b99dec4b5433ac7d329eeb6dd26545e96e55b874be909"),
    ]

    for data, expected_hash in vectors:
        rc, out, _ = fw.run_asm([], stdin_data=data)
        if rc == 0:
            output_hash = out.decode().strip().split()[0] if out else ""
            fw.report_result(output_hash == expected_hash,
                f"sha512: vector '{data[:20].decode(errors='replace')}...' = {expected_hash[:16]}...")
        else:
            fw.report_result(False, f"sha512: vector failed (rc={rc})")

    # Compare with GNU on all vectors
    for data, expected_hash in vectors:
        rc_a, out_a, _ = fw.run_asm([], stdin_data=data)
        rc_g, out_g, _ = fw.run_gnu([], stdin_data=data)
        if rc_a == 0 and rc_g == 0:
            hash_a = out_a.decode().strip().split()[0] if out_a else ""
            hash_g = out_g.decode().strip().split()[0] if out_g else ""
            fw.report_result(hash_a == hash_g,
                f"sha512: GNU match '{data[:20].decode(errors='replace')}...'")

    # Verify output format: "hash  -\n"
    rc, out, _ = fw.run_asm([], stdin_data=b"test")
    if rc == 0:
        out_str = out.decode().strip()
        parts = out_str.split()
        fw.report_result(len(parts) >= 2 and len(parts[0]) == 128 and parts[1] == "-",
            "sha512: output format 'hash  -'")

    # Compare with GNU output format
    rc_a, out_a, _ = fw.run_asm([], stdin_data=b"hello\n")
    rc_g, out_g, _ = fw.run_gnu([], stdin_data=b"hello\n")
    fw.report_result(out_a == out_g, "sha512: output format matches GNU exactly")

    # Binary data hashing (all 256 byte values)
    all_bytes = bytes(range(256))
    expected = hashlib.sha512(all_bytes).hexdigest()
    rc, out, _ = fw.run_asm([], stdin_data=all_bytes)
    if rc == 0:
        output_hash = out.decode().strip().split()[0] if out else ""
        fw.report_result(output_hash == expected, "sha512: all 256 byte values hash correct")

    # Large file hashing (1MB)
    large_data = os.urandom(1024 * 1024)
    expected = hashlib.sha512(large_data).hexdigest()
    rc, out, _ = fw.run_asm([], stdin_data=large_data, timeout=15)
    if rc == 0:
        output_hash = out.decode().strip().split()[0] if out else ""
        fw.report_result(output_hash == expected, "sha512: 1MB hash correct")

    # Random data hashing accuracy
    for i in range(20):
        size = random.randint(1, 10000)
        data = os.urandom(size)
        expected = hashlib.sha512(data).hexdigest()
        rc, out, _ = fw.run_asm([], stdin_data=data)
        if rc == 0:
            output_hash = out.decode().strip().split()[0] if out else ""
            fw.report_result(output_hash == expected, f"sha512: random {size} bytes hash correct")

    # --help/--version
    rc_a, out_a, _ = fw.run_asm(["--help"])
    fw.report_result(rc_a == 0 and len(out_a) > 0, "sha512sum: --help works")
    rc_a, out_a, _ = fw.run_asm(["--version"])
    fw.report_result(rc_a == 0 and len(out_a) > 0, "sha512sum: --version works")

if __name__ == '__main__':
    fw = SecurityTestFramework(config)
    fw.run_all(tool_specific_fn=tool_specific_tests)
