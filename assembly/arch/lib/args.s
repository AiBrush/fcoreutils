.intel_syntax noprefix
.section .note.GNU-stack,"",@progbits
.include "include/linux.inc"

.global parse_args

.section .text

# parse_args - placeholder for arg parsing utilities
# For arch, arg parsing is done inline in the tool
parse_args:
    ret
