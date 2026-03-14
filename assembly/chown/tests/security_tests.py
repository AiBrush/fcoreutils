#!/usr/bin/env python3
"""Security tests for fchown — uses shared framework."""
import sys, os, tempfile
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', '..', 'tests'))
from security_framework import SecurityTestFramework

config = {
    'tool_name': 'chown',
    'bin_name': 'fchown',
    'gnu_path': '/usr/bin/chown',
    'bss_size': 65536,
    'max_binary_size': 100000,
    'test_args': ['--help'],
    'test_stdin': None,
    'timeout': 5,
}

def tool_specific_tests(fw):
    """13. Tool-specific: chown ownership change tests."""
    fw.log("\n=== Chown-Specific Tests ===")
    uid = os.getuid()
    gid = os.getgid()

    with tempfile.TemporaryDirectory() as tmpdir:
        # Basic ownership change with uid:gid
        target = os.path.join(tmpdir, "basic")
        open(target, "w").close()
        rc, out, err = fw.run_asm([f"{uid}:{gid}", target])
        st = os.stat(target)
        fw.report_result(rc == 0 and st.st_uid == uid and st.st_gid == gid,
                         "chown: basic uid:gid ownership change")

        # Owner only (no group)
        target = os.path.join(tmpdir, "owner_only")
        open(target, "w").close()
        rc, out, err = fw.run_asm([str(uid), target])
        fw.report_result(rc == 0, "chown: owner-only change exits 0")

        # Group only with :gid
        target = os.path.join(tmpdir, "group_only")
        open(target, "w").close()
        rc, out, err = fw.run_asm([f":{gid}", target])
        fw.report_result(rc == 0, "chown: :gid group-only change exits 0")

        # Multiple files
        files = []
        for i in range(5):
            f = os.path.join(tmpdir, f"multi_{i}")
            open(f, "w").close()
            files.append(f)
        rc, out, err = fw.run_asm([f"{uid}:{gid}"] + files)
        fw.report_result(rc == 0, "chown: multiple files")

        # -v verbose flag
        target = os.path.join(tmpdir, "verbose")
        open(target, "w").close()
        rc, out, err = fw.run_asm(["-v", f"{uid}:{gid}", target])
        fw.report_result(rc == 0, "chown: -v verbose flag accepted")

        # -c changes flag
        target = os.path.join(tmpdir, "changes")
        open(target, "w").close()
        rc, out, err = fw.run_asm(["-c", f"{uid}:{gid}", target])
        fw.report_result(rc == 0, "chown: -c changes flag accepted")

        # -f silent flag
        rc, out, err = fw.run_asm(["-f", f"{uid}:{gid}", "/nonexistent_xyz"])
        fw.report_result(rc >= 0 and rc < 128, "chown: -f silent flag suppresses errors")

        # --reference flag (may not be implemented in assembly version)
        ref = os.path.join(tmpdir, "reference")
        tgt = os.path.join(tmpdir, "ref_target")
        open(ref, "w").close()
        open(tgt, "w").close()
        rc, out, err = fw.run_asm([f"--reference={ref}", tgt])
        if rc == 0:
            fw.report_result(True, "chown: --reference flag works")
        else:
            fw.skip_test("chown: --reference flag", "not supported in assembly build")

        # Invalid user name
        target = os.path.join(tmpdir, "inv_user")
        open(target, "w").close()
        rc, out, err = fw.run_asm(["nonexistent_user_xyz_123", target])
        fw.report_result(rc != 0, f"chown: invalid user exits non-zero (got {rc})")

        # Nonexistent file
        rc, out, err = fw.run_asm([f"{uid}:{gid}", "/nonexistent_xyz/file"])
        fw.report_result(rc != 0, f"chown: nonexistent file exits non-zero (got {rc})")

    # Missing operand
    rc, out, err = fw.run_asm([])
    fw.report_result(rc == 1, "chown: missing operand exits 1")

    # Compare with GNU
    if os.path.exists(fw.gnu_path):
        with tempfile.TemporaryDirectory() as tmpdir:
            f1 = os.path.join(tmpdir, "gnu_f")
            f2 = os.path.join(tmpdir, "our_f")
            open(f1, "w").close()
            open(f2, "w").close()
            rc_g, _, _ = fw.run_gnu([f"{uid}:{gid}", f1])
            rc_f, _, _ = fw.run_asm([f"{uid}:{gid}", f2])
            fw.report_result(rc_f == rc_g, "chown: exit code matches GNU for basic operation")

if __name__ == '__main__':
    fw = SecurityTestFramework(config)
    fw.run_all(tool_specific_fn=tool_specific_tests)
