%include "include/linux.inc"

global asm_strlen
global asm_strcmp
global asm_starts_with

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

; asm_strcmp(rdi=s1, rsi=s2) -> rax: 0 if equal, nonzero otherwise
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

; asm_starts_with(rdi=str, rsi=prefix) -> rax: 1 if starts with, 0 otherwise
asm_starts_with:
.loop:
    movzx   ecx, byte [rsi]
    test    cl, cl
    jz      .yes            ; end of prefix = match
    movzx   eax, byte [rdi]
    cmp     al, cl
    jne     .no
    inc     rdi
    inc     rsi
    jmp     .loop
.yes:
    mov     eax, 1
    ret
.no:
    xor     eax, eax
    ret
