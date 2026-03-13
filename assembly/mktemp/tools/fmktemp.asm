; fmktemp.asm — modular dev build entry point
; Stub: actual implementation is in fmktemp_unified.asm
section .text
global _start
extern asm_write, asm_write_stdout, asm_write_err, asm_exit
extern asm_strlen

_start:
    mov     rdi, 0
    mov     rax, 60
    syscall
