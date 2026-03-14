#!/usr/bin/env python3
"""Security tests for ffmt — uses shared framework."""
import sys, os, tempfile
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', '..', 'tests'))
from security_framework import SecurityTestFramework

config = {
    'tool_name': 'fmt',
    'bin_name': 'ffmt',
    'gnu_path': '/usr/bin/fmt',
    'bss_size': 65536,
    'max_binary_size': 100000,
    'test_args': [],
    'test_stdin': b'hello world\n',
    'timeout': 5,
}

def tool_specific_tests(fw):
    """13. Tool-specific: fmt tests."""
    fw.log("\n=== Fmt-Specific Tests ===")

    # Basic formatting -- should wrap at default width (75)
    long_text = b"This is a very long line that definitely exceeds the default width of seventy-five characters and needs to be wrapped.\n"
    rc, out, _ = fw.run_asm([], stdin_data=long_text)
    fw.report_result(rc == 0, "fmt: basic formatting works")
    if out:
        max_line_len = max(len(l) for l in out.decode().splitlines()) if out.strip() else 0
        fw.report_result(max_line_len <= 75, f"fmt: default width <= 75 (got {max_line_len})")

    # Paragraphs preserved
    text = b"First paragraph text.\n\nSecond paragraph text.\n"
    rc, out, _ = fw.run_asm([], stdin_data=text)
    fw.report_result(b"\n\n" in out, "fmt: preserves paragraph breaks")

    # Width option
    text = b"Hello world this is a test of the fmt command.\n"
    rc, out, _ = fw.run_asm(["-w", "20"], stdin_data=text)
    if out:
        max_line_len = max(len(l) for l in out.decode().splitlines()) if out.strip() else 0
        fw.report_result(max_line_len <= 20, f"fmt: -w 20 lines <= 20 chars (got {max_line_len})")

    # Empty input
    rc, out, _ = fw.run_asm([], stdin_data=b"")
    fw.report_result(rc == 0 and out == b"", "fmt: empty input -> empty output")

    # Newline only
    rc, out, _ = fw.run_asm([], stdin_data=b"\n")
    fw.report_result(rc == 0, "fmt: newline-only input")

    # Compare with GNU on various inputs
    gnu_path = fw.gnu_path
    if os.path.exists(gnu_path):
        test_texts = [
            b"Hello world.\n",
            b"This is a test of the fmt command which reformats text to a given width.\n",
            b"Short.\n\nAnother paragraph.\n",
            b"  Indented line.\n",
            b"word " * 50 + b"\n",
        ]
        for text in test_texts:
            rc_f, out_f, _ = fw.run_asm([], stdin_data=text)
            rc_g, out_g, _ = fw.run_gnu([], stdin_data=text)
            fw.report_result(out_f == out_g and rc_f == rc_g,
                             f"fmt: matches GNU for '{text[:40].decode(errors='replace').strip()}'")

        # Width options comparison
        for width in ["20", "40", "60", "80"]:
            text = b"word " * 30 + b"\n"
            rc_f, out_f, _ = fw.run_asm(["-w", width], stdin_data=text)
            rc_g, out_g, _ = fw.run_gnu(["-w", width], stdin_data=text)
            fw.report_result(out_f == out_g, f"fmt: -w {width} matches GNU")

    # File input
    with tempfile.TemporaryDirectory() as td:
        fpath = os.path.join(td, "test.txt")
        with open(fpath, "w") as f:
            f.write("This is a test file with some text that needs formatting.\n")
        rc, out, _ = fw.run_asm([fpath])
        fw.report_result(rc == 0 and len(out) > 0, "fmt: file input works")

    # Multiple files
    with tempfile.TemporaryDirectory() as td:
        for i in range(3):
            fpath = os.path.join(td, f"file{i}.txt")
            with open(fpath, "w") as f:
                f.write(f"Text from file {i}.\n")
        files = [os.path.join(td, f"file{i}.txt") for i in range(3)]
        rc, out, _ = fw.run_asm(files)
        fw.report_result(rc == 0, "fmt: multiple files work")

    # --help and --version
    rc, out, _ = fw.run_asm(["--help"])
    fw.report_result(rc == 0 and len(out) > 0, "fmt: --help works")

    rc, out, _ = fw.run_asm(["--version"])
    fw.report_result(rc == 0 and len(out) > 0, "fmt: --version works")

if __name__ == '__main__':
    fw = SecurityTestFramework(config)
    fw.run_all(tool_specific_fn=tool_specific_tests)
