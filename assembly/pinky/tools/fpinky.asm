; fpinky.asm — Dev build entry point (stub)
; The unified build (fpinky_unified.asm) is the primary build target.
section .text
global _start
_start:
    mov     eax, 60
    xor     edi, edi
    syscall
