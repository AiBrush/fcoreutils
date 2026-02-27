%include "include/linux.inc"

global str_len
global str_eq

section .text

; str_len(rdi=string) -> rax=length (not counting null terminator)
str_len:
    xor     rax, rax
.loop:
    cmp     byte [rdi + rax], 0
    je      .done
    inc     rax
    jmp     .loop
.done:
    ret

; str_eq(rdi=str1, rsi=str2) -> rax=1 if equal, 0 if not
; Both strings must be null-terminated
str_eq:
    xor     rcx, rcx
.loop:
    movzx   eax, byte [rdi + rcx]
    movzx   edx, byte [rsi + rcx]
    cmp     al, dl
    jne     .not_equal
    test    al, al
    jz      .equal
    inc     rcx
    jmp     .loop
.equal:
    mov     rax, 1
    ret
.not_equal:
    xor     rax, rax
    ret
