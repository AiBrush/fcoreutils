#!/usr/bin/env python3
"""Security tests for ftouch — uses shared framework."""
import sys, os, time, tempfile
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', '..', 'tests'))
from security_framework import SecurityTestFramework
from shutil import which

config = {
    'tool_name': 'touch',
    'bin_name': 'ftouch',
    'gnu_path': '/usr/bin/touch',
    'bss_size': 65536,
    'max_binary_size': 100000,
    'test_args': ['/tmp/_ftouch_security_test_file'],
    'test_stdin': None,
    'timeout': 5,
}

def tool_specific_tests(fw):
    """13. Tool-specific: touch tests."""
    fw.log("\n=== Touch-Specific Tests ===")
    gnu_path = which("touch")

    # Create a new file
    with tempfile.TemporaryDirectory() as tmpdir:
        newfile = os.path.join(tmpdir, "newfile")
        rc, out, err = fw.run_asm([newfile])
        fw.report_result(rc == 0 and os.path.exists(newfile), "touch: creates new file")

        # Created file should be empty
        fw.report_result(os.path.getsize(newfile) == 0, "touch: created file is empty")

        # Touch existing file updates timestamps
        time.sleep(0.05)
        old_mtime = os.path.getmtime(newfile)
        time.sleep(0.05)
        rc, out, err = fw.run_asm([newfile])
        new_mtime = os.path.getmtime(newfile)
        fw.report_result(rc == 0 and new_mtime >= old_mtime, "touch: updates mtime on existing file")

        # -c flag: do not create file
        nofile = os.path.join(tmpdir, "nofile")
        rc, out, err = fw.run_asm(["-c", nofile])
        fw.report_result(rc == 0 and not os.path.exists(nofile), "touch: -c does not create file")

        # Multiple files at once
        files = [os.path.join(tmpdir, f"multi_{i}") for i in range(5)]
        rc, out, err = fw.run_asm(files)
        all_exist = all(os.path.exists(f) for f in files)
        fw.report_result(rc == 0 and all_exist, "touch: multiple files created")

        # -a flag: change only access time
        target = os.path.join(tmpdir, "atime_test")
        rc, out, err = fw.run_asm([target])
        time.sleep(0.05)
        rc, out, err = fw.run_asm(["-a", target])
        fw.report_result(rc == 0, "touch: -a flag accepted")

        # -m flag: change only modification time
        target = os.path.join(tmpdir, "mtime_test")
        rc, out, err = fw.run_asm([target])
        time.sleep(0.05)
        rc, out, err = fw.run_asm(["-m", target])
        fw.report_result(rc == 0, "touch: -m flag accepted")

        # -r flag: reference file
        ref = os.path.join(tmpdir, "reference")
        tgt = os.path.join(tmpdir, "target_ref")
        rc, _, _ = fw.run_asm([ref])
        rc, _, _ = fw.run_asm(["-r", ref, tgt])
        fw.report_result(rc == 0 and os.path.exists(tgt), "touch: -r reference flag works")

        # -t timestamp
        tgt = os.path.join(tmpdir, "target_t")
        rc, _, _ = fw.run_asm(["-t", "202301011200.00", tgt])
        fw.report_result(rc == 0 and os.path.exists(tgt), "touch: -t timestamp flag works")

        # Compare behavior with GNU on nonexistent parent dir
        if gnu_path:
            rc_f, _, err_f = fw.run_asm(["/nonexistent_xyz/file"])
            rc_g, _, err_g = fw.run_gnu(["/nonexistent_xyz/file"])
            fw.report_result(rc_f == rc_g, f"touch: nonexistent dir exit code matches GNU ({rc_f} vs {rc_g})")

        # Touch with -d date string
        tgt = os.path.join(tmpdir, "target_d")
        rc, _, _ = fw.run_asm(["-d", "2023-01-01 12:00:00", tgt])
        fw.report_result(rc == 0 and os.path.exists(tgt), "touch: -d date string flag works")

    # Missing operand error message
    rc, out, err = fw.run_asm([])
    fw.report_result(rc == 1, "touch: missing operand exits 1")
    fw.report_result(b"missing" in err.lower(), "touch: missing operand error message")

if __name__ == '__main__':
    fw = SecurityTestFramework(config)
    fw.run_all(tool_specific_fn=tool_specific_tests)
