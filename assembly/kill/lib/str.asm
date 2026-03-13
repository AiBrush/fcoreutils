; str.asm — String helper functions
%include "include/linux.inc"

global asm_strlen
global asm_itoa

section .text

; asm_strlen(rdi=str) -> rax=length
asm_strlen:
    xor     eax, eax
.loop:
    cmp     byte [rdi + rax], 0
    je      .done
    inc     rax
    jmp     .loop
.done:
    ret

; asm_itoa(rdi=value, rsi=buf) -> rax=length
asm_itoa:
    push    rbx
    mov     rax, rdi
    mov     rbx, rsi

    test    rax, rax
    jnz     .convert
    mov     byte [rsi], '0'
    mov     rax, 1
    pop     rbx
    ret

.convert:
    mov     r8, rsi
.digit_loop:
    xor     edx, edx
    mov     rcx, 10
    div     rcx
    add     dl, '0'
    mov     [rsi], dl
    inc     rsi
    test    rax, rax
    jnz     .digit_loop

    mov     rax, rsi
    sub     rax, r8

    dec     rsi
    mov     rdi, r8
.reverse_loop:
    cmp     rdi, rsi
    jge     .reverse_done
    mov     cl, [rdi]
    mov     ch, [rsi]
    mov     [rdi], ch
    mov     [rsi], cl
    inc     rdi
    dec     rsi
    jmp     .reverse_loop

.reverse_done:
    pop     rbx
    ret

section .note.GNU-stack noalloc noexec nowrite progbits
