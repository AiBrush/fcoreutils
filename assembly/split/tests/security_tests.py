#!/usr/bin/env python3
"""Security tests for fsplit — uses shared framework."""
import sys, os, subprocess, tempfile, shutil
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', '..', 'tests'))
from security_framework import SecurityTestFramework

config = {
    'tool_name': 'split',
    'bin_name': 'fsplit',
    'gnu_path': '/usr/bin/split',
    'bss_size': 131072,
    'max_binary_size': 30000,
    'test_args': [],
    'test_stdin': b'line1\nline2\nline3\n',
    'timeout': 10,
}

TIMEOUT = 10


def _run_split(bin_path, args, cwd=None, stdin_data=None):
    """Run split binary with cwd support (needed because split writes to cwd)."""
    try:
        p = subprocess.Popen(
            [bin_path] + args,
            stdin=subprocess.PIPE if stdin_data is not None else subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            cwd=cwd,
        )
        out, err = p.communicate(input=stdin_data, timeout=TIMEOUT)
        return p.returncode, out, err
    except subprocess.TimeoutExpired:
        p.kill()
        out, err = p.communicate()
        return 124, out, err
    except (OSError, ValueError):
        return 126, b'', b'OSError'


def _cleanup_outputs(tmpdir, prefix="x"):
    """Remove split output files from tmpdir."""
    for fn in os.listdir(tmpdir):
        if fn.startswith(prefix):
            os.unlink(os.path.join(tmpdir, fn))


def tool_specific_tests(fw):
    """13. Tool-specific: split file splitting tests."""
    fw.log("\n=== Split-Specific Tests ===")
    bin_path = fw.bin_path

    with tempfile.TemporaryDirectory() as tmpdir:
        # Create test file
        testfile = os.path.join(tmpdir, "input.txt")
        with open(testfile, "w") as f:
            for i in range(25):
                f.write(f"line{i}\n")

        # Test 1: Default split (1000 lines - single file since only 25 lines)
        rc, _, _ = _run_split(bin_path, [testfile], cwd=tmpdir)
        outfiles = sorted(fn for fn in os.listdir(tmpdir) if fn.startswith("x"))
        fw.report_result(rc == 0 and len(outfiles) == 1,
                        "split: default 1000 lines -> 1 file for 25 lines")
        _cleanup_outputs(tmpdir)

        # Test 2: -l 5 should create 5 files
        rc, _, _ = _run_split(bin_path, ["-l", "5", testfile], cwd=tmpdir)
        outfiles = sorted(fn for fn in os.listdir(tmpdir) if fn.startswith("x"))
        fw.report_result(len(outfiles) == 5,
                        f"split: -l 5 on 25 lines -> 5 files (got {len(outfiles)})")
        all_5 = all(len(open(os.path.join(tmpdir, fn)).readlines()) == 5 for fn in outfiles)
        fw.report_result(all_5, "split: each piece has exactly 5 lines")
        _cleanup_outputs(tmpdir)

        # Test 3: suffix naming (xaa, xab, xac, ...)
        rc, _, _ = _run_split(bin_path, ["-l", "5", testfile], cwd=tmpdir)
        outfiles = sorted(fn for fn in os.listdir(tmpdir) if fn.startswith("x"))
        expected_names = ["xaa", "xab", "xac", "xad", "xae"]
        fw.report_result(outfiles == expected_names, f"split: suffix naming {outfiles}")
        _cleanup_outputs(tmpdir)

        # Test 4: custom prefix
        rc, _, _ = _run_split(bin_path, ["-l", "5", testfile, "myprefix_"], cwd=tmpdir)
        outfiles = sorted(fn for fn in os.listdir(tmpdir) if fn.startswith("myprefix_"))
        expected = ["myprefix_aa", "myprefix_ab", "myprefix_ac", "myprefix_ad", "myprefix_ae"]
        fw.report_result(outfiles == expected, f"split: custom prefix {outfiles}")
        _cleanup_outputs(tmpdir, "myprefix_")

        # Test 5: numeric suffixes
        rc, _, _ = _run_split(bin_path, ["-d", "-l", "5", testfile], cwd=tmpdir)
        outfiles = sorted(fn for fn in os.listdir(tmpdir) if fn.startswith("x"))
        expected_numeric = ["x00", "x01", "x02", "x03", "x04"]
        fw.report_result(outfiles == expected_numeric, f"split: -d numeric suffixes {outfiles}")
        _cleanup_outputs(tmpdir)

        # Test 6: -a suffix length
        rc, _, _ = _run_split(bin_path, ["-a", "3", "-l", "5", testfile], cwd=tmpdir)
        outfiles = sorted(fn for fn in os.listdir(tmpdir) if fn.startswith("x"))
        expected_3 = ["xaaa", "xaab", "xaac", "xaad", "xaae"]
        fw.report_result(outfiles == expected_3, f"split: -a 3 suffix length {outfiles}")
        _cleanup_outputs(tmpdir)

        # Test 7: byte split
        binfile = os.path.join(tmpdir, "binary.bin")
        with open(binfile, "wb") as f:
            f.write(b"A" * 1000)
        rc, _, _ = _run_split(bin_path, ["-b", "300", binfile], cwd=tmpdir)
        outfiles = sorted(fn for fn in os.listdir(tmpdir) if fn.startswith("x"))
        fw.report_result(len(outfiles) == 4,
                        f"split: -b 300 on 1000 bytes -> 4 files (got {len(outfiles)})")
        sizes = [os.path.getsize(os.path.join(tmpdir, fn)) for fn in outfiles]
        fw.report_result(sizes == [300, 300, 300, 100], f"split: byte sizes {sizes}")
        _cleanup_outputs(tmpdir)

        # Test 8: byte split with K suffix
        bigfile = os.path.join(tmpdir, "big.bin")
        with open(bigfile, "wb") as f:
            f.write(b"X" * 3072)
        rc, _, _ = _run_split(bin_path, ["-b", "1K", bigfile], cwd=tmpdir)
        outfiles = sorted(fn for fn in os.listdir(tmpdir) if fn.startswith("x"))
        fw.report_result(len(outfiles) == 3,
                        f"split: -b 1K on 3KB -> 3 files (got {len(outfiles)})")
        _cleanup_outputs(tmpdir)

        # Test 9: reconstruction from line split
        rc, _, _ = _run_split(bin_path, ["-l", "5", testfile], cwd=tmpdir)
        outfiles = sorted(fn for fn in os.listdir(tmpdir) if fn.startswith("x"))
        reconstructed = b""
        for fn in outfiles:
            with open(os.path.join(tmpdir, fn), "rb") as f:
                reconstructed += f.read()
        with open(testfile, "rb") as f:
            original = f.read()
        fw.report_result(reconstructed == original,
                        "split: line split reconstruction matches original")
        _cleanup_outputs(tmpdir)

        # Test 10: stdin input
        rc, _, _ = _run_split(bin_path, ["-l", "2", "-"],
                              stdin_data=b"a\nb\nc\nd\n", cwd=tmpdir)
        outfiles = sorted(fn for fn in os.listdir(tmpdir) if fn.startswith("x"))
        fw.report_result(len(outfiles) == 2,
                        f"split: stdin -> 2 files (got {len(outfiles)})")
        _cleanup_outputs(tmpdir)

        # Test 11: --verbose
        rc, out, err = _run_split(bin_path, ["--verbose", "-l", "5", testfile], cwd=tmpdir)
        err_text = err.decode(errors="replace")
        fw.report_result("creating file" in err_text,
                        "split: --verbose prints creating messages")
        _cleanup_outputs(tmpdir)

        # Test 12: --help
        rc, out, _ = fw.run_asm(["--help"])
        fw.report_result(rc == 0 and b"Usage:" in out, "split: --help shows usage")

        # Test 13: --version
        rc, out, _ = fw.run_asm(["--version"])
        fw.report_result(rc == 0 and b"split" in out, "split: --version shows version")

        # Test 14: Compare with GNU split if available
        gnu_path = fw.gnu_path
        if gnu_path and os.path.exists(gnu_path):
            gnu_dir = os.path.join(tmpdir, "gnu_out")
            asm_dir = os.path.join(tmpdir, "asm_out")
            os.makedirs(gnu_dir, exist_ok=True)
            os.makedirs(asm_dir, exist_ok=True)

            _run_split(gnu_path, ["-l", "5", testfile], cwd=gnu_dir)
            _run_split(bin_path, ["-l", "5", testfile], cwd=asm_dir)

            gnu_files = sorted(os.listdir(gnu_dir))
            asm_files = sorted(os.listdir(asm_dir))
            fw.report_result(gnu_files == asm_files,
                            f"split: matches GNU file names (GNU={gnu_files} ASM={asm_files})")

            if gnu_files == asm_files:
                content_match = True
                for fn in gnu_files:
                    with open(os.path.join(gnu_dir, fn), "rb") as f1, \
                         open(os.path.join(asm_dir, fn), "rb") as f2:
                        if f1.read() != f2.read():
                            content_match = False
                fw.report_result(content_match, "split: matches GNU file contents")

            shutil.rmtree(gnu_dir, ignore_errors=True)
            shutil.rmtree(asm_dir, ignore_errors=True)

        # Test 15: additional suffix
        rc, _, _ = _run_split(bin_path, ["--additional-suffix=.txt", "-l", "5", testfile],
                              cwd=tmpdir)
        outfiles = sorted(fn for fn in os.listdir(tmpdir) if fn.startswith("x"))
        has_suffix = all(fn.endswith(".txt") for fn in outfiles)
        fw.report_result(has_suffix and len(outfiles) == 5,
                        f"split: --additional-suffix=.txt {outfiles}")
        _cleanup_outputs(tmpdir)

        # Test 16: numeric with -a 3
        rc, _, _ = _run_split(bin_path, ["-d", "-a", "3", "-l", "5", testfile], cwd=tmpdir)
        outfiles = sorted(fn for fn in os.listdir(tmpdir) if fn.startswith("x"))
        expected_d3 = ["x000", "x001", "x002", "x003", "x004"]
        fw.report_result(outfiles == expected_d3, f"split: -d -a 3 -> {outfiles}")
        _cleanup_outputs(tmpdir)

if __name__ == '__main__':
    fw = SecurityTestFramework(config)
    fw.run_all(tool_specific_fn=tool_specific_tests)
