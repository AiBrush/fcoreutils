; str.asm — string utilities
; Not needed for false, but included for project structure completeness

section .text
global str_noop

str_noop:
    ret

; Non-executable stack
section .note.GNU-stack noalloc noexec nowrite progbits
