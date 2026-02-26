#!/usr/bin/env python3
"""Build unified fhead_unified.asm from modular sources."""

import re

# Read source files
with open('tools/fhead.asm') as f:
    fhead_src = f.read()

with open('lib/io.asm') as f:
    io_src = f.read()

# Extract sections from fhead.asm
lines = fhead_src.split('\n')

# Remove includes, externs, globals, section directives
text_lines = []
data_lines = []
bss_lines = []
current_section = None

for line in lines:
    stripped = line.strip()

    # Skip includes, externs, globals
    if stripped.startswith('%include'):
        continue
    if stripped.startswith('extern '):
        continue
    if stripped.startswith('global '):
        continue
    if stripped == 'section .note.GNU-stack noalloc noexec nowrite progbits':
        continue

    # Track sections
    if stripped == 'section .text':
        current_section = 'text'
        continue
    elif stripped == 'section .data':
        current_section = 'data'
        continue
    elif stripped == 'section .bss':
        current_section = 'bss'
        continue

    if current_section == 'text':
        text_lines.append(line)
    elif current_section == 'data':
        data_lines.append(line)
    elif current_section == 'bss':
        bss_lines.append(line)

# Extract io.asm functions (just the text section)
io_lines = []
in_text = False
for line in io_src.split('\n'):
    stripped = line.strip()
    if stripped.startswith('%include'):
        continue
    if stripped.startswith('global '):
        continue
    if stripped == 'section .text':
        in_text = True
        continue
    if stripped == 'section .note.GNU-stack noalloc noexec nowrite progbits':
        continue
    if stripped.startswith('section .'):
        in_text = False
        continue
    if in_text:
        io_lines.append(line)

# Parse BSS entries to calculate sizes
bss_entries = []
total_bss = 0
for line in bss_lines:
    stripped = line.strip()
    if not stripped or stripped.startswith(';'):
        continue
    # Parse entries like: argc:   resq    1
    m = re.match(r'(\w+):\s+res([bwdq])\s+(\S+)', stripped)
    if m:
        name = m.group(1)
        size_type = m.group(2)
        count_str = m.group(3)

        # Evaluate count (might have expressions)
        count_str = count_str.replace('IOBUF_SIZE', '65536')
        count_str = count_str.replace('FROMBUF_SIZE', str(4*1024*1024))
        count = eval(count_str)

        type_sizes = {'b': 1, 'w': 2, 'd': 4, 'q': 8}
        size = type_sizes[size_type] * count
        bss_entries.append((name, total_bss, size))
        total_bss += size

# Replace [rel xxx] with [xxx] in text and data lines
def fix_rel(lines):
    result = []
    for line in lines:
        # Replace lea reg, [rel name] -> lea reg, [name]
        line = re.sub(r'\[rel (\w+)\]', r'[\1]', line)
        # Replace EXIT macro usage
        # EXIT rdi -> mov rax, 60 \n mov rdi, rdi \n syscall
        # Actually keep EXIT macro since we'll define it
        result.append(line)
    return result

text_lines = fix_rel(text_lines)
data_lines = fix_rel(data_lines)
io_lines = fix_rel(io_lines)

# Build the unified file
output = []

output.append('; ============================================================================')
output.append(';  fhead_unified.asm — Unified build of fhead')
output.append(';  Auto-merged from modular source — DO NOT EDIT')
output.append(';  Edit the modular files in tools/ and lib/ instead')
output.append(';  Source files: tools/fhead.asm, lib/io.asm')
output.append('; ============================================================================')
output.append('')
output.append('BITS 64')
output.append('org 0x400000')
output.append('')

# Constants
output.append('; ── Constants ──')
output.append('%define SYS_READ         0')
output.append('%define SYS_WRITE        1')
output.append('%define SYS_OPEN         2')
output.append('%define SYS_CLOSE        3')
output.append('%define SYS_MMAP         9')
output.append('%define SYS_MUNMAP      11')
output.append('%define SYS_RT_SIGPROCMASK 14')
output.append('%define SYS_EXIT        60')
output.append('')
output.append('%define STDIN            0')
output.append('%define STDOUT           1')
output.append('%define STDERR           2')
output.append('%define O_RDONLY         0')
output.append('%define EINTR            4')
output.append('%define EPIPE           32')
output.append('')
output.append('%define IOBUF_SIZE      65536')
output.append('%define FROMBUF_SIZE    (4 * 1024 * 1024)')
output.append('')
output.append('%define MODE_LINES       0')
output.append('%define MODE_BYTES       1')
output.append('%define MODE_LINES_END   2')
output.append('%define MODE_BYTES_END   3')
output.append('')
output.append('%define PROT_READ        1')
output.append('%define PROT_WRITE       2')
output.append('%define MAP_PRIVATE      2')
output.append('%define MAP_ANONYMOUS    0x20')
output.append('')

# Macros
output.append('; ── Macros ──')
output.append('%macro EXIT 1')
output.append('    mov     rax, SYS_EXIT')
output.append('    mov     rdi, %1')
output.append('    syscall')
output.append('%endmacro')
output.append('')

# ELF Header
output.append('; ── ELF Header ──')
output.append('ehdr:')
output.append('    db      0x7f, "ELF"')
output.append('    db      2, 1, 1, 0')
output.append('    dq      0')
output.append('    dw      2')
output.append('    dw      0x3E')
output.append('    dd      1')
output.append('    dq      _start')
output.append('    dq      phdr - ehdr')
output.append('    dq      0')
output.append('    dd      0')
output.append('    dw      ehdr_end - ehdr')
output.append('    dw      phdr_size')
output.append('    dw      3')
output.append('    dw      0, 0, 0')
output.append('ehdr_end:')
output.append('')

# Program Headers
output.append('; ── Program Headers ──')
output.append('phdr:')
output.append('    ; Code + Data (R+X)')
output.append('    dd      1')
output.append('    dd      5')
output.append('    dq      0')
output.append('    dq      0x400000')
output.append('    dq      0x400000')
output.append('    dq      file_end - ehdr')
output.append('    dq      file_end - ehdr')
output.append('    dq      0x1000')
output.append('phdr_size equ $ - phdr')
output.append('')
output.append('    ; BSS (R+W)')
output.append('    dd      1')
output.append('    dd      6')
output.append('    dq      0')
output.append('    dq      bss_start')
output.append('    dq      bss_start')
output.append('    dq      0')
output.append('    dq      bss_size')
output.append('    dq      0x1000')
output.append('')
output.append('    ; GNU_STACK (NX)')
output.append('    dd      0x6474E551')
output.append('    dd      6')
output.append('    dq      0, 0, 0, 0, 0')
output.append('    dq      0x10')
output.append('')

# Code section
output.append('; ============================================================================')
output.append(';                           CODE SECTION')
output.append('; ============================================================================')
output.append('')

# Add main code from fhead.asm
for line in text_lines:
    output.append(line)

output.append('')
output.append('; ============================================================================')
output.append(';                        SHARED LIBRARY FUNCTIONS')
output.append('; ============================================================================')
output.append('')

# Add io.asm functions
for line in io_lines:
    output.append(line)

output.append('')
output.append('; ============================================================================')
output.append(';                           DATA SECTION')
output.append('; ============================================================================')
output.append('')

# Add data
for line in data_lines:
    output.append(line)

output.append('')
output.append('file_end:')
output.append('')

# BSS section using absolute addressing
output.append('; ============================================================================')
output.append(';                           BSS SECTION')
output.append('; ============================================================================')
# Calculate aligned BSS start
output.append(f'bss_start equ (file_end - ehdr + 0x400000 + 0xFFF) & ~0xFFF')
output.append('')

for name, offset, size in bss_entries:
    output.append(f'{name} equ bss_start + {offset}')

output.append('')
output.append(f'bss_size equ {total_bss}')

# Write output
with open('unified/fhead_unified.asm', 'w') as f:
    f.write('\n'.join(output) + '\n')

print(f"Generated unified/fhead_unified.asm")
print(f"  Code lines: {len(text_lines)}")
print(f"  Data lines: {len(data_lines)}")
print(f"  IO lines: {len(io_lines)}")
print(f"  BSS entries: {len(bss_entries)} ({total_bss} bytes)")
