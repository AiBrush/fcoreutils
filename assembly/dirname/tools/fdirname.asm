; fdirname.asm — Dev build entry point (stub)
; For production, use fdirname_unified.asm with nasm -f bin
section .text
global _start
_start:
    mov     eax, 60
    xor     edi, edi
    syscall
