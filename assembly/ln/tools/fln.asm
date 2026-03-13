; fln.asm — modular dev build entry point
; This is a stub that delegates to the unified build for ln.
; For development, use: nasm -f bin fln_unified.asm -o fln
section .text
global _start
extern asm_write, asm_write_stdout, asm_write_err, asm_exit
extern asm_strlen

_start:
    ; Stub: actual implementation is in fln_unified.asm
    mov     rdi, 0
    mov     rax, 60
    syscall
