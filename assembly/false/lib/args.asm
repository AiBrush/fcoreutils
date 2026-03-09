; args.asm — argument parsing utilities
; Not needed for false, but included for project structure completeness

section .text
global parse_args_noop

; No-op argument parser (false ignores all arguments)
parse_args_noop:
    ret
