%include "include/linux.inc"

global asm_strlen
global asm_strcmp
global asm_memcpy

section .text

; asm_strlen(rdi=str) -> rax=length (not counting null)
asm_strlen:
    xor     rax, rax
.loop:
    cmp     byte [rdi + rax], 0
    je      .done
    inc     rax
    jmp     .loop
.done:
    ret

; asm_strcmp(rdi=s1, rsi=s2) -> rax: 0=equal, nonzero=different
asm_strcmp:
.loop:
    movzx   eax, byte [rdi]
    movzx   ecx, byte [rsi]
    cmp     al, cl
    jne     .diff
    test    al, al
    jz      .equal
    inc     rdi
    inc     rsi
    jmp     .loop
.equal:
    xor     eax, eax
    ret
.diff:
    sub     eax, ecx
    ret

; asm_memcpy(rdi=dest, rsi=src, rdx=len) -> rdi=dest
asm_memcpy:
    mov     rcx, rdx
    mov     rax, rdi
    rep     movsb
    ret
