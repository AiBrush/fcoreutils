%include "include/linux.inc"

global asm_strlen
global asm_strcmp

section .text

; asm_strlen(rdi=str) -> rax=length (not counting NUL)
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
    jne     .diff
    test    al, al
    jz      .equal
    inc     rcx
    jmp     .loop
.equal:
    xor     rax, rax
    ret
.diff:
    movzx   rax, al
    movzx   rdx, dl
    sub     rax, rdx
    ret

section .note.GNU-stack noalloc noexec nowrite progbits
