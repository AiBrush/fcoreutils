; Modular dev build stub for fnproc
; The unified build (fnproc_unified.asm) is the primary implementation.
section .text
global _start
_start:
    xor edi, edi
    mov eax, 60
    syscall
