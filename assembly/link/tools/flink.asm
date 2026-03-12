; flink.asm — modular dev build entry point
; This is a stub that delegates to the unified build for link.
; For development, use: nasm -f bin flink_unified.asm -o flink
section .text
global _start
extern asm_write, asm_write_stdout, asm_write_err, asm_exit
extern asm_strlen

_start:
    ; Stub: actual implementation is in flink_unified.asm
    mov     rdi, 0
    mov     rax, 60
    syscall
