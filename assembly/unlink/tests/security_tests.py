#!/usr/bin/env python3
"""security_tests.py -- Security & memory safety tests for funlink (assembly unlink).

Uses shared SecurityTestFramework.
funlink removes a single file using the unlink() system call.
"""

import os
import sys
import tempfile

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', '..', 'tests'))
from security_framework import SecurityTestFramework
from shutil import which

config = {
    'tool_name': 'unlink',
    'bin_name': 'funlink',
    'gnu_path': '/usr/bin/unlink',
    'bss_size': 65536,
    'max_binary_size': 30000,
    'test_args': ['/nonexistent'],
    'test_stdin': None,
    'timeout': 5,
}


def tool_specific_tests(fw):
    """13. unlink-specific tests: file removal behavior."""
    fw.log("\n=== 13. Tool-Specific: unlink ===")

    gnu_path = which('unlink')

    with tempfile.TemporaryDirectory() as tmpdir:
        # Core unlink behavior: remove file
        target = os.path.join(tmpdir, "target")
        with open(target, "w") as f:
            f.write("hello world")

        rc, out, err = fw.run_asm([target])
        fw.report_result(rc == 0, "unlink: basic file removal exits 0")
        fw.report_result(out == b"", "unlink: no stdout on success")
        fw.report_result(err == b"", "unlink: no stderr on success")
        fw.report_result(not os.path.exists(target), "unlink: file actually removed")

        # ENOENT: file doesn't exist
        rc, out, err = fw.run_asm([os.path.join(tmpdir, "nosuch")])
        fw.report_result(rc == 1, "unlink: ENOENT exits 1")
        err_text = err.decode(errors="replace")
        fw.report_result("No such file or directory" in err_text,
                         "unlink: ENOENT error message")

        # EISDIR: trying to unlink a directory
        testdir = os.path.join(tmpdir, "testdir")
        os.mkdir(testdir)
        rc, out, err = fw.run_asm([testdir])
        fw.report_result(rc == 1, "unlink: EISDIR exits 1")
        err_text = err.decode(errors="replace")
        fw.report_result("Is a directory" in err_text or "Operation not permitted" in err_text,
                         "unlink: EISDIR/EPERM error message for directory")
        os.rmdir(testdir)

        # Error message format check
        rc, out, err = fw.run_asm([os.path.join(tmpdir, "nosuch")])
        err_text = err.decode(errors="replace")
        fw.report_result(err_text.startswith("unlink: cannot unlink '"),
                         "unlink: error format starts with 'unlink: cannot unlink '")

        # Unlink only removes one link, original stays
        src = os.path.join(tmpdir, "src")
        lnk = os.path.join(tmpdir, "lnk")
        with open(src, "w") as f:
            f.write("multilink")
        os.link(src, lnk)
        rc, out, err = fw.run_asm([lnk])
        fw.report_result(rc == 0, "unlink: remove one hard link exits 0")
        fw.report_result(os.path.exists(src), "unlink: original file still exists")
        fw.report_result(not os.path.exists(lnk), "unlink: hard link removed")
        os.unlink(src)

        # Unlink symlink (removes the symlink, not the target)
        src2 = os.path.join(tmpdir, "src2")
        sym = os.path.join(tmpdir, "sym")
        with open(src2, "w") as f:
            f.write("symtest")
        os.symlink(src2, sym)
        rc, out, err = fw.run_asm([sym])
        fw.report_result(rc == 0, "unlink: remove symlink exits 0")
        fw.report_result(os.path.exists(src2), "unlink: symlink target still exists")
        fw.report_result(not os.path.exists(sym), "unlink: symlink removed")
        os.unlink(src2)

    # Missing operand messages
    rc, out, err = fw.run_asm([])
    err_text = err.decode(errors="replace")
    fw.report_result("missing operand" in err_text, "unlink: missing operand message")
    fw.report_result("Try 'unlink --help'" in err_text, "unlink: missing operand try help hint")

    rc, out, err = fw.run_asm(["a", "b"])
    err_text = err.decode(errors="replace")
    fw.report_result("extra operand" in err_text, "unlink: extra operand message")
    # Accept both ASCII quotes ('b') and Unicode smart quotes (\u2018b\u2019)
    fw.report_result("'b'" in err_text or "\u2018b\u2019" in err_text,
                     "unlink: extra operand includes the extra arg")

    # --help goes to stdout
    rc, out, err = fw.run_asm(["--help"])
    fw.report_result(rc == 0, "unlink: --help exits 0")
    fw.report_result(len(out) > 50, "unlink: --help produces output")
    fw.report_result(b"Usage:" in out, "unlink: --help contains 'Usage:'")

    # --version goes to stdout
    rc, out, err = fw.run_asm(["--version"])
    fw.report_result(rc == 0, "unlink: --version exits 0")
    fw.report_result(b"unlink" in out, "unlink: --version contains 'unlink'")

    # Compare error messages with GNU (normalize smart quotes and path)
    if gnu_path:
        c_env = os.environ.copy()
        c_env["LC_ALL"] = "C"

        def _normalize_quotes(b):
            """Replace Unicode smart quotes with ASCII single quotes."""
            return b.replace(b'\xe2\x80\x98', b"'").replace(b'\xe2\x80\x99', b"'")

        for args_list in [[], ["a", "b"]]:
            rc_f, _, err_f = fw.run_asm(args_list)
            rc_g, _, err_g = fw.run([gnu_path] + args_list, env=c_env)
            err_g_norm = err_g.replace(gnu_path.encode(), b"unlink")
            err_f_norm = _normalize_quotes(err_f)
            err_g_norm = _normalize_quotes(err_g_norm)
            fw.report_result(err_f_norm == err_g_norm,
                             f"unlink: error msg byte-match GNU for args={args_list}")


if __name__ == '__main__':
    fw = SecurityTestFramework(config)
    fw.run_all(tool_specific_fn=tool_specific_tests)
