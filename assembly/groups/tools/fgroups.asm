; fgroups.asm — modular dev build entry point
; This is a stub that delegates to the unified build for groups.
; For development, use: nasm -f bin fgroups_unified.asm -o fgroups
section .text
global _start
extern asm_write, asm_write_err, asm_exit
extern asm_strlen

_start:
    ; Stub: actual implementation is in fgroups_unified.asm
    mov     rdi, 0
    mov     rax, 60
    syscall
