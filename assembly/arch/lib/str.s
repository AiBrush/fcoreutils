.intel_syntax noprefix
.section .note.GNU-stack,"",@progbits
.include "include/linux.inc"

.global asm_strlen
.global asm_strcmp

.section .text

# asm_strlen(rdi=str) -> rax=length (not counting null terminator)
asm_strlen:
    xor     rax, rax
.Lstrlen_loop:
    cmp     byte ptr [rdi + rax], 0
    je      .Lstrlen_done
    inc     rax
    jmp     .Lstrlen_loop
.Lstrlen_done:
    ret

# asm_strcmp(rdi=s1, rsi=s2) -> rax: 0 if equal, nonzero if different
asm_strcmp:
    xor     rcx, rcx
.Lstrcmp_loop:
    mov     al, byte ptr [rdi + rcx]
    mov     dl, byte ptr [rsi + rcx]
    cmp     al, dl
    jne     .Lstrcmp_diff
    test    al, al
    jz      .Lstrcmp_equal
    inc     rcx
    jmp     .Lstrcmp_loop
.Lstrcmp_equal:
    xor     rax, rax
    ret
.Lstrcmp_diff:
    movzx   rax, al
    movzx   rdx, dl
    sub     rax, rdx
    ret
