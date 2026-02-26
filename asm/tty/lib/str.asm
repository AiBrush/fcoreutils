%include "include/linux.inc"

global asm_strlen
global asm_strcmp

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
    mov     al, [rdi]
    mov     cl, [rsi]
    cmp     al, cl
    jne     .neq
    test    al, al
    jz      .eq
    inc     rdi
    inc     rsi
    jmp     .loop
.eq:
    xor     rax, rax
    ret
.neq:
    movzx   rax, al
    movzx   rcx, cl
    sub     rax, rcx
    ret

; Mark stack as non-executable
section .note.GNU-stack noalloc noexec nowrite progbits
