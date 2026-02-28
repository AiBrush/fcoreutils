#!/usr/bin/env python3
"""
build_tool.py — Unified build script for all assembly coreutils tools.

Detects the system's GNU tool output (help text, version text, error messages),
patches the assembly DATA section, assembles, and optionally verifies.

Usage:
    python3 build_tool.py TOOL                    # build a single tool
    python3 build_tool.py --all                   # build all tools
    python3 build_tool.py TOOL --detect           # show detected data only
    python3 build_tool.py TOOL --no-verify        # skip verification
    python3 build_tool.py TOOL -o /path/to/out    # custom output path

Supports three assembly build types:
  1. NASM flat binary (most tools) — nasm -f bin
  2. NASM modular + linker (wc)    — nasm -f elf64 + ld
  3. GAS + linker (arch)           — as --64 + ld

The script auto-detects which type each tool uses by checking for markers
in the source files.
"""

import subprocess
import sys
import os
import shutil
import argparse
import tempfile
import re

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))

# Markers in assembly source files — content between these is replaced.
MARKER_NASM = ("; @@DATA_START@@", "; @@DATA_END@@")
MARKER_GAS  = ("// @@DATA_START@@", "// @@DATA_END@@")

# Tool registry: tool_name -> build configuration
# "type" is one of:
#   "nasm_unified"    — single .asm file, nasm -f bin
#   "nasm_subdir"     — unified/ subdir .asm file, nasm -f bin
#   "nasm_modular"    — multiple .asm files, nasm -f elf64 + ld
#   "gas_unified"     — single .s file, as + ld
# "gnu_bin" is the GNU binary name (defaults to tool name)
# "source" is the primary assembly source file (relative to assembly/{tool}/)
TOOLS = {
    "true":    {"type": "nasm_unified", "source": "ftrue_unified.asm"},
    "logname": {"type": "nasm_unified", "source": "flogname_unified.asm"},
    "hostid":  {"type": "nasm_unified", "source": "fhostid_unified.asm"},
    "tty":     {"type": "nasm_unified", "source": "ftty_unified.asm"},
    "whoami":  {"type": "nasm_unified", "source": "fwhoami_unified.asm"},
    "pwd":     {"type": "nasm_unified", "source": "fpwd_unified.asm",
                "help_split": True},
    "sync":    {"type": "nasm_unified", "source": "fsync_unified.asm"},
    "sleep":   {"type": "nasm_unified", "source": "fsleep_unified.asm"},
    "echo":    {"type": "nasm_unified", "source": "fecho_unified.asm"},
    "head":    {"type": "nasm_subdir",  "source": "unified/fhead_unified.asm"},
    "tail":    {"type": "nasm_subdir",  "source": "unified/ftail_unified.asm"},
    "tac":     {"type": "nasm_subdir",  "source": "unified/ftac_unified.asm"},
    "rev":     {"type": "nasm_subdir",  "source": "unified/frev_unified.asm",
                "gnu_bin": "rev", "skip_verify": True,
                "help_flag": "-h", "version_flag": "-V"},
    "cut":     {"type": "nasm_subdir",  "source": "unified/fcut_unified.asm"},
    "tr":      {"type": "nasm_subdir",  "source": "unified/ftr_unified.asm"},
    "base64":  {"type": "nasm_subdir",  "source": "unified/fbase64_unified.asm"},
    "md5sum":  {"type": "nasm_subdir",  "source": "unified/fmd5sum_unified.asm"},
    "wc":      {"type": "nasm_modular", "source": "tools/fwc.asm",
                "modules": ["lib/io.asm", "lib/str.asm"],
                "include": "."},
    "arch":    {"type": "gas_unified",  "source": "farch_unified.s"},
}


# =============================================================================
# Subprocess helpers
# =============================================================================

def capture(args):
    """Run a command; return (stdout, stderr, returncode)."""
    try:
        p = subprocess.run(args, capture_output=True, timeout=10)
        return p.stdout, p.stderr, p.returncode
    except FileNotFoundError:
        return b"", "{}: not found".format(args[0]).encode(), 127
    except subprocess.TimeoutExpired:
        return b"", "{}: timed out".format(args[0]).encode(), 124


def run_cmd(args, check=True):
    """Run a command, optionally checking return code."""
    result = subprocess.run(args, capture_output=True)
    if check and result.returncode != 0:
        print("Error: {} failed:".format(" ".join(args)), file=sys.stderr)
        if result.stderr:
            print(result.stderr.decode(errors="replace"), file=sys.stderr)
        sys.exit(1)
    return result


# =============================================================================
# GNU binary detection
# =============================================================================

def find_gnu_binary(tool_name):
    """Find the system's GNU binary for the given tool."""
    # rev is from util-linux, not coreutils
    if tool_name == "rev":
        for path in ["/usr/bin/rev", shutil.which("rev")]:
            if path and os.path.isfile(path):
                return path
        return None

    # Try direct path first (most Linux systems)
    candidates = [
        "/usr/bin/{}".format(tool_name),
        shutil.which(tool_name),
    ]

    # macOS: try gnubin paths
    for prefix in ["/opt/homebrew/opt/coreutils/libexec/gnubin",
                   "/usr/local/opt/coreutils/libexec/gnubin"]:
        candidates.append(os.path.join(prefix, tool_name))
    # macOS: also try g-prefixed
    candidates.append(shutil.which("g{}".format(tool_name)))

    for c in candidates:
        if c and os.path.isfile(c):
            return c
    return None


def detect_tool_data(tool_name, config):
    """
    Capture help/version/error output from the system's GNU binary.
    Returns a dict: {help, version, err_unrec, err_inval, err_suffix}
    or None if detection fails.
    """
    gnu_name = config.get("gnu_bin", tool_name)
    gnu_bin = find_gnu_binary(gnu_name)
    if gnu_bin is None:
        print("  [info] GNU {} not found".format(gnu_name), file=sys.stderr)
        return None

    help_flag = config.get("help_flag", "--help")
    version_flag = config.get("version_flag", "--version")
    help_out, help_err, help_rc = capture([gnu_bin, help_flag])
    ver_out, ver_err, ver_rc = capture([gnu_bin, version_flag])

    # Some tools send help to stderr (e.g., true with --help might differ)
    # Use whichever stream has output
    help_text = help_out if help_out else help_err
    ver_text = ver_out if ver_out else ver_err

    # Normalize: replace the full path with just the tool name in help text
    # GNU tools use argv[0] for the Usage line
    help_text = help_text.replace(gnu_bin.encode(), gnu_name.encode())
    ver_text = ver_text.replace(gnu_bin.encode(), gnu_name.encode())

    # Detect error message format by probing with bogus options
    LONG_PROBE = "--bogus_test_option_xyz"
    SHORT_PROBE = "Z"
    _, err_long, _ = capture([gnu_bin, LONG_PROBE])
    _, err_short, _ = capture([gnu_bin, "-{}".format(SHORT_PROBE)])

    err_unrec = b""
    err_inval = b""
    err_suffix = b""

    if err_long:
        long_lines = err_long.split(b"\n")
        line1_long = long_lines[0]
        opt_pos = line1_long.find(LONG_PROBE.encode())
        if opt_pos >= 0:
            err_unrec = line1_long[:opt_pos]
            close_quote = line1_long[opt_pos + len(LONG_PROBE):]
            try_line = long_lines[1] if len(long_lines) > 1 else b""
            err_suffix = close_quote + b"\n" + try_line + b"\n"
            # Normalize tool path in error messages
            err_unrec = err_unrec.replace(gnu_bin.encode(), gnu_name.encode())
            err_suffix = err_suffix.replace(gnu_bin.encode(), gnu_name.encode())

    if err_short:
        short_lines = err_short.split(b"\n")
        line1_short = short_lines[0]
        short_pos = line1_short.find(SHORT_PROBE.encode())
        if short_pos >= 0:
            err_inval = line1_short[:short_pos]
            err_inval = err_inval.replace(gnu_bin.encode(), gnu_name.encode())

    return {
        "help": help_text,
        "version": ver_text,
        "err_unrec": err_unrec,
        "err_inval": err_inval,
        "err_suffix": err_suffix,
    }


# =============================================================================
# Data section generation
# =============================================================================

def bytes_to_nasm_db(data, label):
    """Convert bytes to NASM `db` directives with hex encoding."""
    if not data:
        return "{:<24}db 0\n{}_len equ 0".format(label + ":", "", label)
    lines = []
    for i in range(0, len(data), 16):
        chunk = data[i:i + 16]
        hexb = ", ".join("0x{:02x}".format(b) for b in chunk)
        if i == 0:
            lines.append("{:<24}db {}".format(label + ":", hexb))
        else:
            lines.append("                        db {}".format(hexb))
    lines.append("{}_len equ $ - {}".format(label, label))
    return "\n".join(lines)


def bytes_to_gas_directives(data, label):
    """Convert bytes to GAS .byte directives with hex encoding."""
    if not data:
        return "{}:\n    .byte 0\n    .set {}_len, 0".format(label, label)
    lines = ["{}:".format(label)]
    for i in range(0, len(data), 16):
        chunk = data[i:i + 16]
        hexb = ", ".join("0x{:02x}".format(b) for b in chunk)
        lines.append("    .byte {}".format(hexb))
    lines.append("    .set {}_len, . - {}".format(label, label))
    return "\n".join(lines)


# =============================================================================
# Source patching — preserves existing label structure
# =============================================================================

def parse_data_section(content, is_gas=False):
    """
    Parse the data section between markers to identify label groups.
    Returns a list of (label_name, role) tuples where role is one of:
      "help", "version", or "other" (preserved as-is).
    """
    markers = MARKER_GAS if is_gas else MARKER_NASM
    start_marker, end_marker = markers
    start_idx = content.find(start_marker)
    end_idx = content.find(end_marker)
    if start_idx < 0 or end_idx < 0:
        return []

    start_line_end = content.index("\n", start_idx) + 1
    section = content[start_line_end:end_idx]

    # Find the help and version label names used in this file
    help_label = None
    version_label = None

    if is_gas:
        label_re = re.compile(r'^(\w+):$', re.MULTILINE)
    else:
        label_re = re.compile(r'^(\w+):', re.MULTILINE)

    for m in label_re.finditer(section):
        name = m.group(1)
        nl = name.lower()
        if ("help" in nl and "flag" not in nl and "opt" not in nl
                and "dash" not in nl and "try" not in nl
                and "_len" not in nl and "_end" not in nl):
            if help_label is None:
                help_label = name
        elif ("version" in nl and "flag" not in nl and "opt" not in nl
                and "dash" not in nl
                and "_len" not in nl and "_end" not in nl):
            if version_label is None:
                version_label = name

    return help_label, version_label


def replace_label_content(content, label, new_bytes, is_gas=False):
    """
    Replace the byte content of a labeled data block in the assembly source.
    Preserves the label name and length calculation, replaces db/byte directives.

    For NASM: label:  db 0x... lines until _len equ or next label
    For GAS:  label:  .byte/.ascii lines until .set/_len or next label
    """
    lines = content.split("\n")
    result = []
    i = 0
    replaced = False

    while i < len(lines):
        line = lines[i]
        stripped = line.strip()

        # Check if this line starts the target label
        if is_gas:
            is_label = stripped == "{}:".format(label)
        else:
            is_label = stripped.startswith("{}:".format(label)) or \
                       stripped.startswith("{} :".format(label))

        if is_label and not replaced:
            replaced = True
            # Emit the label
            if is_gas:
                result.append("{}:".format(label))
                # Emit new bytes as .byte directives
                for j in range(0, len(new_bytes), 16):
                    chunk = new_bytes[j:j + 16]
                    hexb = ", ".join("0x{:02x}".format(b) for b in chunk)
                    result.append("    .byte {}".format(hexb))
            else:
                # Emit label with first db line
                for j in range(0, len(new_bytes), 16):
                    chunk = new_bytes[j:j + 16]
                    hexb = ", ".join("0x{:02x}".format(b) for b in chunk)
                    if j == 0:
                        result.append("{:<24}db {}".format(label + ":", hexb))
                    else:
                        result.append("                        db {}".format(hexb))

            # Skip original content lines until we hit the length calc or next label
            i += 1
            while i < len(lines):
                sl = lines[i].strip()
                # Check for length calculation line (keep it)
                if is_gas:
                    if sl.startswith(".set {}_len".format(label)):
                        result.append("    .set {}_len, . - {}".format(label, label))
                        i += 1
                        break
                    elif sl.startswith(".equ {}_len".format(label)):
                        result.append(".equ {}_len, . - {}".format(label, label))
                        i += 1
                        break
                    # Check for _end label pattern
                    elif sl == "{}_end:".format(label):
                        # Skip the _end label, emit it, then look for the equ
                        result.append("{}_end:".format(label))
                        i += 1
                        if i < len(lines):
                            sl2 = lines[i].strip()
                            if "_len" in sl2:
                                result.append(lines[i])
                                i += 1
                        break
                else:
                    if sl.startswith("{}_len".format(label)):
                        result.append("{}_len equ $ - {}".format(label, label))
                        i += 1
                        break
                    # Check for _end label pattern
                    elif sl.startswith("{}_end".format(label)):
                        # Skip the _end label line + equ line
                        i += 1
                        if i < len(lines):
                            sl2 = lines[i].strip()
                            if "_len" in sl2:
                                result.append("{}_len equ $ - {}".format(label, label))
                                i += 1
                        break
                    # Another label starts — don't consume it
                    elif re.match(r'^\w+:', sl) and "db" not in sl.lower():
                        break

                # Skip db/byte/.ascii lines (old content)
                sl_lower = sl.lower()
                if (sl_lower.startswith("db ") or "db 0x" in sl_lower
                        or sl_lower.startswith(".byte") or sl_lower.startswith(".ascii")
                        or sl == "" or sl.startswith(";") or sl.startswith("//")
                        or sl.startswith("                ")):
                    i += 1
                else:
                    break
        else:
            result.append(line)
            i += 1

    return "\n".join(result)


def patch_source(source_path, data, is_gas=False):
    """
    Patch the assembly source file, replacing help/version text content.
    Preserves all label names and the existing data section structure.
    Returns the patched source as a string.
    """
    with open(source_path, "r") as f:
        content = f.read()

    markers = MARKER_GAS if is_gas else MARKER_NASM
    start_marker, end_marker = markers
    if start_marker not in content or end_marker not in content:
        print("  [warn] No data markers found in {}".format(source_path),
              file=sys.stderr)
        return content

    # Identify which labels are used for help and version
    help_label, version_label = parse_data_section(content, is_gas)

    # Check if this tool has split help (uses argv[0] in help output)
    tool_name = os.path.basename(os.path.dirname(source_path))
    if tool_name in ("unified",):
        tool_name = os.path.basename(os.path.dirname(os.path.dirname(source_path)))
    tool_config = TOOLS.get(tool_name, {})
    skip_help_patch = tool_config.get("help_split", False)

    if help_label and data.get("help") and not skip_help_patch:
        content = replace_label_content(
            content, help_label, data["help"], is_gas)
        print("  Patched: {} ({} bytes)".format(help_label, len(data["help"])))
    elif skip_help_patch:
        print("  [skip] Help patch skipped (split help with argv[0])")

    if version_label and data.get("version"):
        content = replace_label_content(
            content, version_label, data["version"], is_gas)
        print("  Patched: {} ({} bytes)".format(
            version_label, len(data["version"])))

    return content


# =============================================================================
# Build functions
# =============================================================================

def build_nasm_flat(tool_name, source_path, output_path, data=None):
    """Build a NASM flat binary (nasm -f bin)."""
    if data:
        patched = patch_source(source_path, data)
        tmp = tempfile.NamedTemporaryFile(suffix=".asm", delete=False, mode="w")
        tmp.write(patched)
        tmp.close()
        asm_input = tmp.name
    else:
        asm_input = source_path

    try:
        run_cmd(["nasm", "-f", "bin", asm_input, "-o", output_path])
        os.chmod(output_path, 0o755)
        print("  Built: {} ({} bytes)".format(
            output_path, os.path.getsize(output_path)))
    finally:
        if data and os.path.exists(asm_input):
            os.unlink(asm_input)


def build_nasm_modular(tool_name, config, output_path, data=None):
    """Build a modular NASM tool (nasm -f elf64 + ld)."""
    tool_dir = os.path.join(SCRIPT_DIR, tool_name)
    include_dir = os.path.join(tool_dir, config.get("include", "."))
    main_source = os.path.join(tool_dir, config["source"])
    modules = [os.path.join(tool_dir, m) for m in config.get("modules", [])]

    with tempfile.TemporaryDirectory() as tmpdir:
        # Patch main source if data available
        if data:
            patched = patch_source(main_source, data)
            patched_path = os.path.join(tmpdir, "main.asm")
            with open(patched_path, "w") as f:
                f.write(patched)
            main_source = patched_path

        # Assemble all modules
        obj_files = []
        for mod in modules:
            obj_name = os.path.join(tmpdir,
                os.path.basename(mod).replace(".asm", ".o"))
            run_cmd(["nasm", "-f", "elf64", "-I", include_dir + "/",
                     mod, "-o", obj_name])
            obj_files.append(obj_name)

        # Assemble main source
        main_obj = os.path.join(tmpdir, "main.o")
        run_cmd(["nasm", "-f", "elf64", "-I", include_dir + "/",
                 main_source, "-o", main_obj])

        # Link (strip debug info to remove source paths)
        run_cmd(["ld", "--gc-sections", "-n", "-s", main_obj] + obj_files +
                ["-o", output_path])
        os.chmod(output_path, 0o755)
        print("  Built: {} ({} bytes)".format(
            output_path, os.path.getsize(output_path)))


def build_gas(tool_name, source_path, output_path, data=None):
    """Build a GAS tool (as + ld)."""
    if data:
        patched = patch_source(source_path, data, is_gas=True)
        tmp = tempfile.NamedTemporaryFile(suffix=".s", delete=False, mode="w")
        tmp.write(patched)
        tmp.close()
        asm_input = tmp.name
    else:
        asm_input = source_path

    with tempfile.TemporaryDirectory() as tmpdir:
        obj_path = os.path.join(tmpdir, "output.o")
        try:
            run_cmd(["as", "--64", asm_input, "-o", obj_path])
            run_cmd(["ld", "-o", output_path, obj_path])
            os.chmod(output_path, 0o755)
            print("  Built: {} ({} bytes)".format(
                output_path, os.path.getsize(output_path)))
        finally:
            if data and os.path.exists(asm_input):
                os.unlink(asm_input)


def build_tool(tool_name, config, output_path=None, data=None):
    """Build a single tool using the appropriate method."""
    tool_dir = os.path.join(SCRIPT_DIR, tool_name)
    source_path = os.path.join(tool_dir, config["source"])

    if output_path is None:
        output_path = os.path.join(tool_dir, "f{}".format(tool_name))

    build_type = config["type"]
    if build_type in ("nasm_unified", "nasm_subdir"):
        build_nasm_flat(tool_name, source_path, output_path, data)
    elif build_type == "nasm_modular":
        build_nasm_modular(tool_name, config, output_path, data)
    elif build_type == "gas_unified":
        build_gas(tool_name, source_path, output_path, data)
    else:
        print("Error: unknown build type '{}'".format(build_type),
              file=sys.stderr)
        sys.exit(1)

    return output_path


# =============================================================================
# Verification
# =============================================================================

def verify_tool(tool_name, binary_path, data):
    """Verify the built binary matches GNU output for --help/--version."""
    if data is None:
        print("  [skip] No GNU data to verify against")
        return True

    config = TOOLS[tool_name]
    if config.get("skip_verify"):
        print("  [skip] Verification skipped for {} (non-coreutils tool)".format(
            tool_name))
        return True

    gnu_name = config.get("gnu_bin", tool_name)
    help_flag = config.get("help_flag", "--help")
    version_flag = config.get("version_flag", "--version")
    ok = True

    # Test --help (skip for tools with split help that use argv[0])
    if not config.get("help_split"):
        our_help, _, _ = capture([binary_path, help_flag])
        expected_help = data["help"].replace(
            gnu_name.encode(), tool_name.encode())
        our_help_norm = our_help.replace(
            binary_path.encode(), tool_name.encode())

        if our_help_norm != expected_help:
            print("  FAIL: {} output differs".format(help_flag), file=sys.stderr)
            print("  Expected ({} bytes): {}...".format(
                len(expected_help), expected_help[:100]), file=sys.stderr)
            print("  Got      ({} bytes): {}...".format(
                len(our_help_norm), our_help_norm[:100]), file=sys.stderr)
            ok = False
        else:
            print("  {}: OK ({} bytes)".format(help_flag, len(our_help_norm)))
    else:
        print("  --help: skipped (split help with argv[0])")

    # Test --version
    our_ver, _, _ = capture([binary_path, version_flag])
    expected_ver = data["version"].replace(
        gnu_name.encode(), tool_name.encode())
    our_ver_norm = our_ver.replace(
        binary_path.encode(), tool_name.encode())

    if our_ver_norm != expected_ver:
        print("  FAIL: {} output differs".format(version_flag), file=sys.stderr)
        print("  Expected: {}".format(expected_ver[:100]), file=sys.stderr)
        print("  Got:      {}".format(our_ver_norm[:100]), file=sys.stderr)
        ok = False
    else:
        print("  {}: OK ({} bytes)".format(version_flag, len(our_ver_norm)))

    return ok


# =============================================================================
# Main
# =============================================================================

def main():
    parser = argparse.ArgumentParser(
        description="Unified build script for assembly coreutils tools")
    parser.add_argument("tool", nargs="?",
        help="Tool name to build (e.g., 'echo', 'head')")
    parser.add_argument("--all", action="store_true",
        help="Build all tools")
    parser.add_argument("--detect", action="store_true",
        help="Only detect and display GNU data, don't build")
    parser.add_argument("--no-verify", action="store_true",
        help="Skip verification step after building")
    parser.add_argument("--no-patch", action="store_true",
        help="Build without patching data (use existing source as-is)")
    parser.add_argument("-o", "--output",
        help="Output binary path (single tool only)")
    parser.add_argument("--list", action="store_true",
        help="List all supported tools")

    args = parser.parse_args()

    if args.list:
        for name, config in sorted(TOOLS.items()):
            print("  {:<12} type={:<16} source={}".format(
                name, config["type"], config["source"]))
        return

    if not args.tool and not args.all:
        parser.print_help()
        sys.exit(1)

    tools_to_build = sorted(TOOLS.keys()) if args.all else [args.tool]

    if args.tool and args.tool not in TOOLS:
        print("Error: unknown tool '{}'. Use --list to see available tools.".format(
            args.tool), file=sys.stderr)
        sys.exit(1)

    total_ok = 0
    total_fail = 0

    for tool_name in tools_to_build:
        config = TOOLS[tool_name]
        print("\n=== {} ===".format(tool_name))

        # Detect GNU data
        data = None
        if not args.no_patch:
            data = detect_tool_data(tool_name, config)
            if data:
                print("  Detected: --help={} bytes, --version={} bytes".format(
                    len(data["help"]), len(data["version"])))
            else:
                print("  [info] Using existing source data (no patching)")

        if args.detect:
            if data:
                for key in ["help", "version", "err_unrec", "err_inval", "err_suffix"]:
                    val = data.get(key, b"")
                    print("  {:<12} {:>5} bytes: {}".format(
                        key, len(val), repr(val[:80])))
            continue

        # Build
        output_path = args.output if (args.output and not args.all) else None
        binary = build_tool(tool_name, config, output_path, data)

        # Verify
        if not args.no_verify:
            if verify_tool(tool_name, binary, data):
                total_ok += 1
            else:
                total_fail += 1
        else:
            total_ok += 1

    if not args.detect:
        print("\n" + "=" * 50)
        print("Results: {} OK, {} FAIL out of {} tools".format(
            total_ok, total_fail, len(tools_to_build)))
        if total_fail > 0:
            sys.exit(1)


if __name__ == "__main__":
    main()
