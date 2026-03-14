#!/usr/bin/env python3
"""Security tests for fshred — uses shared framework."""
import sys, os, re, tempfile, shutil, atexit
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', '..', 'tests'))
from security_framework import SecurityTestFramework

# Create a temp file for test_args (shred on /dev/null hangs GNU shred)
_shred_test_file = '/tmp/__fshred_security_test__.dat'
def _setup_shred_test_file():
    with open(_shred_test_file, 'wb') as f:
        f.write(b'security test data\n')
def _cleanup_shred_test_file():
    try:
        os.unlink(_shred_test_file)
    except OSError:
        pass
_setup_shred_test_file()
atexit.register(_cleanup_shred_test_file)

config = {
    'tool_name': 'shred',
    'bin_name': 'fshred',
    'gnu_path': '/usr/bin/shred',
    'bss_size': 65536,
    'max_binary_size': 100000,
    'test_args': ['-n', '1', _shred_test_file],
    'test_stdin': None,
    'timeout': 10,
}

def tool_specific_tests(fw):
    """13. Tool-specific: shred tests."""
    fw.log("\n=== Shred-Specific Tests ===")

    tmpdir = tempfile.mkdtemp()
    try:
        # Basic shred
        test_file = os.path.join(tmpdir, "basic.dat")
        with open(test_file, "wb") as f:
            f.write(b"test data\n")
        rc, _, _ = fw.run_asm(["-n", "1", test_file])
        fw.report_result(rc == 0, "shred: basic shred completes")

        # Large file
        large_file = os.path.join(tmpdir, "large.dat")
        with open(large_file, "wb") as f:
            f.write(os.urandom(1024 * 1024))
        rc, _, _ = fw.run_asm(["-n", "1", large_file])
        fw.report_result(rc == 0, "shred: 1MB file shred succeeds")

        # Empty file
        empty_file = os.path.join(tmpdir, "empty.dat")
        with open(empty_file, "wb") as f:
            pass
        rc, _, _ = fw.run_asm(["-n", "1", "-z", empty_file])
        fw.report_result(rc == 0, "shred: empty file shred succeeds")

        # File with size at buffer boundary (128KB)
        boundary_file = os.path.join(tmpdir, "boundary.dat")
        with open(boundary_file, "wb") as f:
            f.write(os.urandom(131072))
        rc, _, _ = fw.run_asm(["-n", "1", "-x", boundary_file])
        fw.report_result(rc == 0, "shred: 128KB boundary file succeeds")

        # Single byte file with -x -z
        one_file = os.path.join(tmpdir, "one.dat")
        with open(one_file, "wb") as f:
            f.write(b"X")
        rc, _, _ = fw.run_asm(["-n", "1", "-x", "-z", one_file])
        fw.report_result(rc == 0, "shred: 1-byte file succeeds")
        with open(one_file, "rb") as f:
            content = f.read()
        fw.report_result(content == b"\x00", "shred: 1-byte file zeroed correctly")

        # Verify file is actually overwritten
        integrity_file = os.path.join(tmpdir, "integrity.dat")
        original = b"ORIGINAL_SECRET_DATA_" * 100
        with open(integrity_file, "wb") as f:
            f.write(original)
        rc, _, _ = fw.run_asm(["-n", "1", "-x", integrity_file])
        fw.report_result(rc == 0, "shred: overwrite succeeds")
        with open(integrity_file, "rb") as f:
            content = f.read()
        fw.report_result(len(content) == len(original), "shred: file size preserved with -x")
        fw.report_result(content != original, "shred: content actually changed")

        # Zero pass produces all zeros
        zero_file = os.path.join(tmpdir, "zeros.dat")
        with open(zero_file, "wb") as f:
            f.write(b"secret" * 100)
        rc, _, _ = fw.run_asm(["-z", "-x", zero_file])
        fw.report_result(rc == 0, "shred: zero pass succeeds")
        with open(zero_file, "rb") as f:
            content = f.read()
        fw.report_result(all(b == 0 for b in content), "shred: zero pass produces all zeros")

        # -u actually removes
        remove_file = os.path.join(tmpdir, "removeme.dat")
        with open(remove_file, "wb") as f:
            f.write(b"remove this")
        rc, _, _ = fw.run_asm(["-u", "-n", "1", remove_file])
        fw.report_result(rc == 0, "shred: remove succeeds")
        fw.report_result(not os.path.exists(remove_file), "shred: file actually removed")

        # -s overrides size
        size_file = os.path.join(tmpdir, "sized.dat")
        with open(size_file, "wb") as f:
            f.write(b"small")
        rc, _, _ = fw.run_asm(["-s", "2048", "-z", size_file])
        fw.report_result(rc == 0, "shred: -s override succeeds")
        stat = os.stat(size_file)
        fw.report_result(stat.st_size == 2048, f"shred: -s 2048 produced {stat.st_size} bytes")

        # Random data is actually random
        rand_file = os.path.join(tmpdir, "random.dat")
        with open(rand_file, "wb") as f:
            f.write(b"\x00" * 4096)
        rc, _, _ = fw.run_asm(["-n", "1", "-x", rand_file])
        fw.report_result(rc == 0, "shred: random overwrite succeeds")
        with open(rand_file, "rb") as f:
            content = f.read()
        unique_bytes = len(set(content))
        fw.report_result(unique_bytes > 100, f"shred: random data has {unique_bytes} unique byte values")

        # 255-char filename
        long_name = os.path.join(tmpdir, "A" * 255)
        try:
            with open(long_name, "w") as f:
                f.write("test")
            rc, _, _ = fw.run_asm(["-n", "1", long_name])
            fw.report_result(rc == 0, "shred: 255-char filename accepted")
        except OSError:
            fw.skip_test("shred: 255-char filename", "OS rejected filename")

        # Filename with spaces
        special_file = os.path.join(tmpdir, "file with spaces.txt")
        with open(special_file, "w") as f:
            f.write("test")
        rc, _, _ = fw.run_asm(["-n", "1", special_file])
        fw.report_result(rc == 0, "shred: filename with spaces")

        # Many files at once
        files = []
        for i in range(50):
            fpath = os.path.join(tmpdir, f"multi_{i}.txt")
            with open(fpath, "w") as f:
                f.write(f"data {i}")
            files.append(fpath)
        rc, _, _ = fw.run_asm(["-n", "1"] + files)
        fw.report_result(rc == 0, "shred: 50 files at once")

        # Invalid iteration count
        rc, _, err = fw.run_asm(["-n", "abc", os.path.join(tmpdir, "basic.dat")])
        fw.report_result(rc != 0, "shred: -n abc rejected")

        # Nonexistent file
        rc, _, err = fw.run_asm(["/nonexistent/path/file"])
        fw.report_result(rc != 0, "shred: nonexistent file rejected")

        # No args
        rc, _, err = fw.run_asm([])
        fw.report_result(rc != 0, "shred: no-args exits non-zero")
        fw.report_result(b"missing file operand" in err, "shred: no-args error message")

    finally:
        shutil.rmtree(tmpdir, ignore_errors=True)

    # GNU compatibility
    if os.path.exists(fw.gnu_path):
        tmpdir2 = tempfile.mkdtemp()
        try:
            for args_desc, args in [
                ("1 pass", ["-v", "-n", "1"]),
                ("3 passes", ["-v", "-n", "3"]),
                ("1 pass + zero", ["-v", "-n", "1", "-z"]),
                ("0 passes + zero", ["-v", "-n", "0", "-z"]),
            ]:
                gnu_file = os.path.join(tmpdir2, f"gnu_{args_desc.replace(' ', '_')}.txt")
                asm_file = os.path.join(tmpdir2, f"asm_{args_desc.replace(' ', '_')}.txt")
                for f in [gnu_file, asm_file]:
                    with open(f, "w") as fh:
                        fh.write("test data")

                gnu_rc, _, gnu_err = fw.run_gnu(args + [gnu_file])
                asm_rc, _, asm_err = fw.run_asm(args + [asm_file])

                gnu_out = gnu_err.decode(errors="replace").replace(gnu_file, "FILE")
                asm_out = asm_err.decode(errors="replace").replace(asm_file, "FILE")

                fw.report_result(gnu_rc == asm_rc, f"compat: exit code match ({args_desc})")
                pass_re = re.compile(r"pass\s+(\d+)/(\d+)\s+\(([^)]+)\)")
                gnu_passes = pass_re.findall(gnu_out)
                asm_passes = pass_re.findall(asm_out)
                verbose_ok = (len(gnu_passes) == len(asm_passes) and
                              all(g[2] == a[2] for g, a in zip(gnu_passes, asm_passes)))
                fw.report_result(verbose_ok, f"compat: verbose output match ({args_desc})")

            # Compare error messages (nonexistent file)
            gnu_rc, _, gnu_err = fw.run_gnu(["/nonexistent_xyz_file"])
            asm_rc, _, asm_err = fw.run_asm(["/nonexistent_xyz_file"])
            fw.report_result(gnu_rc == asm_rc, "compat: nonexistent file exit code")

            # Compare no-args behavior
            gnu_rc, _, gnu_err = fw.run_gnu([])
            asm_rc, _, asm_err = fw.run_asm([])
            fw.report_result(gnu_rc == asm_rc, "compat: no-args exit code")
        finally:
            shutil.rmtree(tmpdir2, ignore_errors=True)

if __name__ == '__main__':
    fw = SecurityTestFramework(config)
    fw.run_all(tool_specific_fn=tool_specific_tests)
