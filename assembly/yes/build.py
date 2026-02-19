#!/usr/bin/env python3
"""
build.py -- Build fyes matched to the local system's GNU yes.

Supports four target platforms:
  - linux-x86_64   (NASM flat binary, no linker)
  - linux-arm64    (GNU as + ld, static ELF)
  - macos-x86_64   (NASM macho64 + ld)
  - macos-arm64    (Apple as + ld)

Detects your system's yes --help, --version, and error message format,
patches the assembly data section in a TEMP COPY (never mutates originals),
and assembles the binary.

Usage:
    python3 build.py                          # auto-detect platform, build ./fyes
    python3 build.py --target linux-x86_64    # explicit target
    python3 build.py --target macos-arm64 -o myyes
    python3 build.py --detect                 # just show what was detected
"""

import subprocess
import sys
import os
import shutil
import argparse
import platform
import tempfile

# Source assembly files (relative to script directory)
ASM_LINUX_X86_64 = "fyes.asm"
ASM_LINUX_ARM64 = "fyes_arm64.s"
ASM_MACOS_X86_64 = "fyes_macos_x86_64.asm"
ASM_MACOS_ARM64 = "fyes_macos_arm64.s"

# Marker formats per file type
NASM_MARKER_START = "; @@DATA_START@@"
NASM_MARKER_END = "; @@DATA_END@@"
GAS_MARKER_START = "// @@DATA_START@@"
GAS_MARKER_END = "// @@DATA_END@@"

VALID_TARGETS = ["linux-x86_64", "linux-arm64", "macos-x86_64", "macos-arm64"]


def capture(args: list[str]) -> tuple[bytes, bytes, int]:
    """Run a command and return (stdout, stderr, returncode)."""
    p = subprocess.run(args, capture_output=True, timeout=10)
    return p.stdout, p.stderr, p.returncode


def detect_platform() -> str:
    """Detect current OS and architecture, return target string."""
    os_name = platform.system()   # 'Linux', 'Darwin'
    arch = platform.machine()     # 'x86_64', 'aarch64', 'arm64'

    if os_name == "Linux":
        if arch == "x86_64":
            return "linux-x86_64"
        elif arch in ("aarch64", "arm64"):
            return "linux-arm64"
    elif os_name == "Darwin":
        if arch == "x86_64":
            return "macos-x86_64"
        elif arch in ("arm64", "aarch64"):
            return "macos-arm64"

    print(f"Error: unsupported platform {os_name}/{arch}", file=sys.stderr)
    sys.exit(1)


def is_gnu_yes() -> bool:
    """Check if the system yes is GNU coreutils."""
    try:
        out, _, rc = capture(["yes", "--version"])
        return rc == 0 and b"GNU coreutils" in out
    except Exception:
        return False


def detect_system_yes() -> dict | None:
    """Capture all output from the system's GNU yes. Returns None if not GNU."""
    yes_bin = shutil.which("yes")
    if not yes_bin:
        return None

    if not is_gnu_yes():
        print("  System yes is not GNU coreutils, using defaults", file=sys.stderr)
        return None

    # Capture --help and --version (stdout)
    help_out, _, _ = capture(["yes", "--help"])
    ver_out, _, _ = capture(["yes", "--version"])

    # Capture error messages (stderr) using known test options
    LONG_PROBE = "--bogus_test_option_xyz"
    SHORT_PROBE = "Z"
    _, err_long, _ = capture(["yes", LONG_PROBE])
    _, err_short, _ = capture(["yes", f"-{SHORT_PROBE}"])

    # Parse error structure
    long_lines = err_long.split(b"\n")
    short_lines = err_short.split(b"\n")

    line1_long = long_lines[0]
    line1_short = short_lines[0]
    try_line = long_lines[1] if len(long_lines) > 1 else b""

    # Find probe string to split prefix / suffix
    opt_pos = line1_long.find(LONG_PROBE.encode())
    if opt_pos < 0:
        print("Error: couldn't find probe option in error output", file=sys.stderr)
        print(f"  stderr was: {err_long!r}", file=sys.stderr)
        sys.exit(1)

    err_unrec = line1_long[:opt_pos]
    close_quote = line1_long[opt_pos + len(LONG_PROBE):]

    short_pos = line1_short.find(SHORT_PROBE.encode())
    if short_pos < 0:
        print("Error: couldn't find short probe in error output", file=sys.stderr)
        print(f"  stderr was: {err_short!r}", file=sys.stderr)
        sys.exit(1)

    err_inval = line1_short[:short_pos]
    err_suffix = close_quote + b"\n" + try_line + b"\n"

    return {
        "help": help_out,
        "version": ver_out,
        "err_unrec": err_unrec,
        "err_inval": err_inval,
        "err_suffix": err_suffix,
    }


# ============================================================================
#  Data section generators (NASM vs GNU as format)
# ============================================================================

def bytes_to_nasm(data: bytes, label: str) -> str:
    """Convert raw bytes to NASM db directives with a label."""
    lines = []
    for i in range(0, len(data), 16):
        chunk = data[i:i + 16]
        hexb = ", ".join(f"0x{b:02x}" for b in chunk)
        if i == 0:
            lines.append(f'{label:<16}db {hexb}')
        else:
            lines.append(f'                db {hexb}')
    return "\n".join(lines)


def bytes_to_gas(data: bytes, label: str) -> str:
    """Convert raw bytes to GNU as .byte directives with a label."""
    lines = [f"{label}"]
    for i in range(0, len(data), 16):
        chunk = data[i:i + 16]
        hexb = ", ".join(f"0x{b:02x}" for b in chunk)
        lines.append(f"    .byte {hexb}")
    return "\n".join(lines)


def generate_nasm_data(data: dict) -> str:
    """Generate NASM data section from detected data."""
    lines = []
    lines.append(bytes_to_nasm(data["help"], "help_text:"))
    lines.append("help_text_len equ $ - help_text")
    lines.append("")
    lines.append(bytes_to_nasm(data["version"], "version_text:"))
    lines.append("version_text_len equ $ - version_text")
    lines.append("")
    lines.append(bytes_to_nasm(data["err_unrec"], "err_unrec:"))
    lines.append("err_unrec_len equ $ - err_unrec")
    lines.append("")
    lines.append(bytes_to_nasm(data["err_inval"], "err_inval:"))
    lines.append("err_inval_len equ $ - err_inval")
    lines.append("")
    lines.append(bytes_to_nasm(data["err_suffix"], "err_suffix:"))
    lines.append("err_suffix_len equ $ - err_suffix")
    return "\n".join(lines)


def generate_gas_data(data: dict) -> str:
    """Generate GNU as data section from detected data."""
    lines = []
    lines.append(bytes_to_gas(data["help"], "help_text:"))
    lines.append("    .set    help_text_len, . - help_text")
    lines.append("")
    lines.append(bytes_to_gas(data["version"], "version_text:"))
    lines.append("    .set    version_text_len, . - version_text")
    lines.append("")
    lines.append(bytes_to_gas(data["err_unrec"], "err_unrec_pre:"))
    lines.append("    .set    err_unrec_pre_len, . - err_unrec_pre")
    lines.append("")
    lines.append(bytes_to_gas(data["err_inval"], "err_inval_pre:"))
    lines.append("    .set    err_inval_pre_len, . - err_inval_pre")
    lines.append("")
    lines.append(bytes_to_gas(data["err_suffix"], "err_suffix:"))
    lines.append("    .set    err_suffix_len, . - err_suffix")
    return "\n".join(lines)


# ============================================================================
#  Patching: copy to temp, replace DATA section, return temp path
# ============================================================================

def patch_asm_to_temp(src_path: str, new_data: str,
                      marker_start: str, marker_end: str) -> str:
    """Copy src_path to a temp file, patch DATA section, return temp path.

    NEVER mutates the original file.
    """
    with open(src_path, "r") as f:
        content = f.read()

    start_idx = content.find(marker_start)
    end_idx = content.find(marker_end)

    if start_idx < 0 or end_idx < 0:
        print(f"Error: markers not found in {src_path}", file=sys.stderr)
        print(f"  Expected {marker_start!r} and {marker_end!r}", file=sys.stderr)
        sys.exit(1)

    before = content[:start_idx + len(marker_start)]
    after = content[end_idx:]
    patched = f"{before}\n{new_data}\n{after}"

    # Determine suffix from source filename
    _, ext = os.path.splitext(src_path)
    fd, tmp_path = tempfile.mkstemp(suffix=ext, prefix="fyes_patched_")
    os.close(fd)
    with open(tmp_path, "w") as f:
        f.write(patched)

    return tmp_path


# ============================================================================
#  Build functions for each target
# ============================================================================

def build_linux_x86_64(data: dict | None, output: str) -> None:
    """Build Linux x86_64: NASM flat binary."""
    if not shutil.which("nasm"):
        print("Error: nasm not found in PATH", file=sys.stderr)
        sys.exit(1)

    src = ASM_LINUX_X86_64
    if data:
        nasm_data = generate_nasm_data(data)
        src = patch_asm_to_temp(ASM_LINUX_X86_64, nasm_data,
                                NASM_MARKER_START, NASM_MARKER_END)

    try:
        result = subprocess.run(
            ["nasm", "-f", "bin", src, "-o", output],
            capture_output=True,
        )
        if result.returncode != 0:
            print(f"Error: nasm failed:\n{result.stderr.decode()}", file=sys.stderr)
            sys.exit(1)
        os.chmod(output, 0o755)
    finally:
        if data and src != ASM_LINUX_X86_64:
            os.unlink(src)


def build_linux_arm64(data: dict | None, output: str) -> None:
    """Build Linux ARM64: GNU as + ld static ELF."""
    for tool in ("as", "ld"):
        if not shutil.which(tool):
            print(f"Error: {tool} not found in PATH", file=sys.stderr)
            sys.exit(1)

    src = ASM_LINUX_ARM64
    if data:
        gas_data = generate_gas_data(data)
        src = patch_asm_to_temp(ASM_LINUX_ARM64, gas_data,
                                GAS_MARKER_START, GAS_MARKER_END)

    obj_fd, obj_path = tempfile.mkstemp(suffix=".o", prefix="fyes_arm64_")
    os.close(obj_fd)

    try:
        # Assemble
        result = subprocess.run(
            ["as", "-o", obj_path, src],
            capture_output=True,
        )
        if result.returncode != 0:
            print(f"Error: as failed:\n{result.stderr.decode()}", file=sys.stderr)
            sys.exit(1)

        # Link
        result = subprocess.run(
            ["ld", "-static", "-s", "-e", "_start", "-o", output, obj_path],
            capture_output=True,
        )
        if result.returncode != 0:
            print(f"Error: ld failed:\n{result.stderr.decode()}", file=sys.stderr)
            sys.exit(1)

        os.chmod(output, 0o755)
    finally:
        if os.path.exists(obj_path):
            os.unlink(obj_path)
        if data and src != ASM_LINUX_ARM64:
            os.unlink(src)


def get_macos_sdk_path() -> str:
    """Get macOS SDK path via xcrun."""
    result = subprocess.run(
        ["xcrun", "--show-sdk-path"],
        capture_output=True, text=True,
    )
    if result.returncode != 0:
        print("Error: xcrun --show-sdk-path failed", file=sys.stderr)
        sys.exit(1)
    return result.stdout.strip()


def build_macos_x86_64(data: dict | None, output: str) -> None:
    """Build macOS x86_64: NASM macho64 + ld."""
    if not shutil.which("nasm"):
        print("Error: nasm not found in PATH", file=sys.stderr)
        sys.exit(1)

    src = ASM_MACOS_X86_64
    if data:
        nasm_data = generate_nasm_data(data)
        src = patch_asm_to_temp(ASM_MACOS_X86_64, nasm_data,
                                NASM_MARKER_START, NASM_MARKER_END)

    obj_fd, obj_path = tempfile.mkstemp(suffix=".o", prefix="fyes_macos_x86_64_")
    os.close(obj_fd)

    try:
        # Assemble
        result = subprocess.run(
            ["nasm", "-f", "macho64", src, "-o", obj_path],
            capture_output=True,
        )
        if result.returncode != 0:
            print(f"Error: nasm failed:\n{result.stderr.decode()}", file=sys.stderr)
            sys.exit(1)

        # Link
        sdk = get_macos_sdk_path()
        result = subprocess.run(
            ["ld", "-arch", "x86_64", "-o", output, obj_path,
             "-lSystem", "-syslibroot", sdk, "-e", "_start"],
            capture_output=True,
        )
        if result.returncode != 0:
            print(f"Error: ld failed:\n{result.stderr.decode()}", file=sys.stderr)
            sys.exit(1)

        os.chmod(output, 0o755)
    finally:
        if os.path.exists(obj_path):
            os.unlink(obj_path)
        if data and src != ASM_MACOS_X86_64:
            os.unlink(src)


def build_macos_arm64(data: dict | None, output: str) -> None:
    """Build macOS ARM64: Apple as + ld."""
    src = ASM_MACOS_ARM64
    if data:
        gas_data = generate_gas_data(data)
        src = patch_asm_to_temp(ASM_MACOS_ARM64, gas_data,
                                GAS_MARKER_START, GAS_MARKER_END)

    obj_fd, obj_path = tempfile.mkstemp(suffix=".o", prefix="fyes_macos_arm64_")
    os.close(obj_fd)

    try:
        # Assemble
        result = subprocess.run(
            ["as", "-arch", "arm64", "-o", obj_path, src],
            capture_output=True,
        )
        if result.returncode != 0:
            print(f"Error: as failed:\n{result.stderr.decode()}", file=sys.stderr)
            sys.exit(1)

        # Link
        sdk = get_macos_sdk_path()
        result = subprocess.run(
            ["ld", "-arch", "arm64", "-o", output, obj_path,
             "-lSystem", "-syslibroot", sdk, "-e", "_start"],
            capture_output=True,
        )
        if result.returncode != 0:
            print(f"Error: ld failed:\n{result.stderr.decode()}", file=sys.stderr)
            sys.exit(1)

        os.chmod(output, 0o755)
    finally:
        if os.path.exists(obj_path):
            os.unlink(obj_path)
        if data and src != ASM_MACOS_ARM64:
            os.unlink(src)


# ============================================================================
#  Detection display
# ============================================================================

def print_detection(data: dict) -> None:
    """Print what was detected."""
    def quote_style(b: bytes) -> str:
        if b"\xe2\x80\x98" in b:
            return "UTF-8 curly quotes"
        if b"\x27" in b:
            return "ASCII apostrophe (0x27)"
        return "unknown"

    print(f"  --help:        {len(data['help']):>4} bytes  quotes: {quote_style(data['help'])}")
    print(f"  --version:     {len(data['version']):>4} bytes")
    print(f"  err_unrec:     {len(data['err_unrec']):>4} bytes  {data['err_unrec']!r}")
    print(f"  err_inval:     {len(data['err_inval']):>4} bytes  {data['err_inval']!r}")
    print(f"  err_suffix:    {len(data['err_suffix']):>4} bytes  quotes: {quote_style(data['err_suffix'])}")


# ============================================================================
#  Verification
# ============================================================================

def verify(binary: str) -> None:
    """Quick verification against system yes."""
    if not is_gnu_yes():
        print("  Skipping verification (system yes is not GNU)")
        return

    passed = 0
    failed = 0

    tests = [
        ("--help", ["--help"], True),
        ("--version", ["--version"], True),
        ("--helpx error", ["--helpx"], True),
        ("-n error", ["-n"], True),
        ("--help extra", ["--help", "extra"], True),
    ]

    for label, args, _exact in tests:
        bin_path = binary if os.path.isabs(binary) else f"./{binary}"
        fo, fe, fr = capture([bin_path] + args)
        yo, ye, yr = capture(["yes"] + args)

        ok = (fo == yo and fe == ye and fr == yr)
        tag = "PASS" if ok else "FAIL"
        print(f"  [{tag}] {label}")
        if ok:
            passed += 1
        else:
            failed += 1
            if fo != yo:
                print(f"         stdout: fyes={len(fo)}b yes={len(yo)}b")
            if fe != ye:
                print(f"         stderr: fyes={fe[:60]!r}")
                print(f"                  yes={ye[:60]!r}")
            if fr != yr:
                print(f"         exit:   fyes={fr} yes={yr}")

    print(f"  {passed}/{passed + failed} passed")


# ============================================================================
#  Main
# ============================================================================

BUILD_FUNCS = {
    "linux-x86_64": build_linux_x86_64,
    "linux-arm64": build_linux_arm64,
    "macos-x86_64": build_macos_x86_64,
    "macos-arm64": build_macos_arm64,
}


def main():
    parser = argparse.ArgumentParser(
        description="Build fyes matched to system GNU yes"
    )
    parser.add_argument("-o", "--output", default="fyes",
                        help="Output binary name")
    parser.add_argument("--target", choices=VALID_TARGETS,
                        help="Target platform (auto-detected if omitted)")
    parser.add_argument("--detect", action="store_true",
                        help="Just detect, don't build")
    parser.add_argument("--no-verify", action="store_true",
                        help="Skip verification")
    args = parser.parse_args()

    script_dir = os.path.dirname(os.path.abspath(__file__))
    os.chdir(script_dir)

    target = args.target or detect_platform()
    print(f"[*] Target: {target}")

    print("[*] Detecting system yes...")
    data = detect_system_yes()
    if data:
        print_detection(data)
    else:
        print("  Using default data (GNU yes not available)")

    if args.detect:
        return

    print(f"[*] Building ({target})...")
    build_fn = BUILD_FUNCS[target]
    build_fn(data, args.output)

    size = os.path.getsize(args.output)
    print(f"  Built {args.output} ({size} bytes)")

    if not args.no_verify:
        print("[*] Verifying...")
        verify(args.output)


if __name__ == "__main__":
    main()
