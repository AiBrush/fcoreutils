%include "include/linux.inc"

global asm_strlen
global asm_strcmp
global asm_uint_to_str

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

; asm_strcmp(rdi=s1, rsi=s2) -> rax: 0 if equal, non-zero otherwise
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

; asm_uint_to_str(rdi=value, rsi=buf, rdx=bufsize) -> rax=length
asm_uint_to_str:
    push    rbx
    push    r12
    mov     r12, rsi
    mov     rbx, rdx
    xor     ecx, ecx
    mov     rax, rdi
    mov     r8, 10
.digit_loop:
    xor     edx, edx
    div     r8
    add     dl, '0'
    push    rdx
    inc     ecx
    test    rax, rax
    jnz     .digit_loop
    xor     eax, eax
.store_loop:
    cmp     eax, ebx
    jge     .done
    pop     rdx
    mov     byte [r12 + rax], dl
    inc     eax
    dec     ecx
    jnz     .store_loop
.done:
    pop     r12
    pop     rbx
    ret
