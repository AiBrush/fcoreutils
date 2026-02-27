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

; asm_strcmp(rdi=s1, rsi=s2) -> rax=0 if equal, nonzero otherwise
asm_strcmp:
    xor     rcx, rcx
.loop:
    mov     al, [rdi + rcx]
    mov     dl, [rsi + rcx]
    cmp     al, dl
    jne     .not_equal
    test    al, al
    jz      .equal
    inc     rcx
    jmp     .loop
.equal:
    xor     rax, rax
    ret
.not_equal:
    movzx   rax, al
    movzx   rdx, dl
    sub     rax, rdx
    ret

; asm_starts_with(rdi=str, rsi=prefix) -> rax=1 if match, 0 if not
asm_starts_with:
    xor     rcx, rcx
.loop:
    mov     dl, [rsi + rcx]
    test    dl, dl
    jz      .match
    cmp     dl, [rdi + rcx]
    jne     .no_match
    inc     rcx
    jmp     .loop
.match:
    mov     rax, 1
    ret
.no_match:
    xor     rax, rax
    ret
