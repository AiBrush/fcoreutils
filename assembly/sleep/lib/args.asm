%include "include/linux.inc"

global parse_args

section .text

; parse_args - placeholder for argument parsing helpers
; Sleep uses custom parsing in the main tool file
parse_args:
    ret

; Non-executable stack
section .note.GNU-stack noalloc noexec nowrite progbits
