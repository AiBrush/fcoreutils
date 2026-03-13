section .text
global _start
_start:
    xor edi, edi
    mov eax, 60
    syscall
