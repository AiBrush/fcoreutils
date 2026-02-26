; str.asm — String helper functions
%include "include/linux.inc"

global asm_strlen
global asm_memcpy
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

; asm_memcpy(rdi=dest, rsi=src, rdx=len) -> rax=dest
asm_memcpy:
    mov     rax, rdi
    mov     rcx, rdx
    rep movsb
    ret

; asm_itoa(rdi=value, rsi=buf) -> rax=length
; Converts unsigned 64-bit integer to decimal string
; Writes digits into buf, returns number of digits
asm_itoa:
    push    rbx
    mov     rax, rdi            ; value
    mov     rbx, rsi            ; buf start
    mov     rcx, rsi            ; save start

    ; Handle zero
    test    rax, rax
    jnz     .convert
    mov     byte [rsi], '0'
    mov     rax, 1
    pop     rbx
    ret

.convert:
    ; Write digits in reverse
    mov     r8, rsi             ; save start
.digit_loop:
    xor     edx, edx
    mov     rcx, 10
    div     rcx                 ; rax = quotient, rdx = remainder
    add     dl, '0'
    mov     [rsi], dl
    inc     rsi
    test    rax, rax
    jnz     .digit_loop

    mov     rax, rsi
    sub     rax, r8             ; length = end - start

    ; Reverse the digits in place
    dec     rsi                 ; rsi = last digit
    mov     rdi, r8             ; rdi = first digit
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
