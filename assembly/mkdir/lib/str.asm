; String library for mkdir (modular build)
section .text
global asm_strlen, asm_strcmp

asm_strlen:
    xor     rax, rax
.loop:
    cmp     byte [rdi + rax], 0
    je      .done
    inc     rax
    jmp     .loop
.done:
    ret

asm_strcmp:
    xor     rcx, rcx
.loop:
    mov     al, byte [rdi + rcx]
    mov     dl, byte [rsi + rcx]
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
