; args.asm — argument parsing utilities
; Not needed for true, but included for project structure completeness

section .text
global parse_args_noop

; No-op argument parser (true ignores all arguments)
parse_args_noop:
    ret

section .note.GNU-stack noalloc noexec nowrite progbits
