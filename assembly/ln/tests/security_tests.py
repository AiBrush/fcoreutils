#!/usr/bin/env python3
"""Security tests for fln — uses shared framework."""
import sys, os, tempfile
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', '..', 'tests'))
from security_framework import SecurityTestFramework

config = {
    'tool_name': 'ln',
    'bin_name': 'fln',
    'gnu_path': '/usr/bin/ln',
    'bss_size': 4096,
    'max_binary_size': 30000,
    'test_args': ['/tmp/_fln_test_src', '/tmp/_fln_test_dst'],
    'test_stdin': None,
}

# Create test source file for framework's generic tests
if not os.path.exists('/tmp/_fln_test_src'):
    with open('/tmp/_fln_test_src', 'w') as f:
        f.write('test')

def tool_specific_tests(fw):
    """13. Tool-specific: ln — hard and symbolic link creation."""
    fw.log("\n=== Tool-Specific: ln ===")

    with tempfile.TemporaryDirectory() as tmpdir:
        src = os.path.join(tmpdir, "src")
        dst = os.path.join(tmpdir, "dst")
        with open(src, "w") as f:
            f.write("hello world")

        # Hard link
        rc, out, err = fw.run_asm([src, dst])
        fw.report_result(rc == 0, "ln: basic hard link exits 0")
        fw.report_result(out == b"", "ln: no stdout on success")
        fw.report_result(err == b"", "ln: no stderr on success")

        if os.path.exists(dst):
            src_stat = os.stat(src)
            dst_stat = os.stat(dst)
            fw.report_result(src_stat.st_ino == dst_stat.st_ino, "ln: same inode (hard link)")
            fw.report_result(src_stat.st_nlink >= 2, "ln: link count >= 2")
        os.unlink(dst)

        # Symbolic link
        sym = os.path.join(tmpdir, "sym")
        rc, out, err = fw.run_asm(["-s", src, sym])
        fw.report_result(rc == 0, "ln: symbolic link exits 0")
        fw.report_result(os.path.islink(sym), "ln: is a symbolic link")
        if os.path.islink(sym):
            fw.report_result(os.readlink(sym) == src, "ln: symlink target matches")
            os.unlink(sym)

        # Force flag
        with open(dst, "w") as f:
            f.write("existing")
        rc, out, err = fw.run_asm(["-f", src, dst])
        fw.report_result(rc == 0, "ln: -f force link exits 0")
        if os.path.exists(dst):
            fw.report_result(os.stat(src).st_ino == os.stat(dst).st_ino, "ln: -f same inode")
        os.unlink(dst)

        # EEXIST without -f
        with open(dst, "w") as f:
            f.write("existing")
        rc, out, err = fw.run_asm([src, dst])
        fw.report_result(rc == 1, "ln: EEXIST exits 1")
        fw.report_result(b"File exists" in err, "ln: EEXIST error message")
        os.unlink(dst)

        # Verbose
        verb_dst = os.path.join(tmpdir, "verb")
        rc, out, err = fw.run_asm(["-v", src, verb_dst])
        fw.report_result(rc == 0, "ln: -v verbose exits 0")
        out_text = out.decode(errors="replace")
        fw.report_result("'" in out_text and "->" in out_text, "ln: verbose output format")
        if os.path.exists(verb_dst):
            os.unlink(verb_dst)

    # --help
    rc, out, err = fw.run_asm(['--help'])
    fw.report_result(rc == 0, "ln: --help exits 0")
    fw.report_result(b"Usage:" in out, "ln: --help contains Usage:")

    # --version
    rc, out, err = fw.run_asm(['--version'])
    fw.report_result(rc == 0, "ln: --version exits 0")
    fw.report_result(b"ln" in out, "ln: --version contains 'ln'")

    # Missing operand
    rc, out, err = fw.run_asm([])
    fw.report_result(b"missing" in err, "ln: missing operand message")

    # Cleanup
    try:
        os.unlink('/tmp/_fln_test_src')
        os.unlink('/tmp/_fln_test_dst')
    except OSError:
        pass

if __name__ == '__main__':
    fw = SecurityTestFramework(config)
    fw.run_all(tool_specific_fn=tool_specific_tests)
