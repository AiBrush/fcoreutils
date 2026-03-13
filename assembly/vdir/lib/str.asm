; str.asm — String helpers for fls
%include "include/linux.inc"

global asm_strlen
global asm_strcmp
global asm_strcpy
global asm_uint_to_str
global asm_uint_to_str_right

section .text

; asm_strlen(rdi=str) -> rax=length
asm_strlen:
    xor     rax, rax
.loop:
    cmp     byte [rdi + rax], 0
    je      .done
    inc     rax
    jmp     .loop
.done:
    ret

; asm_strcmp(rdi=s1, rsi=s2) -> rax: 0 if equal, <0 or >0 otherwise
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

; asm_strcpy(rdi=dest, rsi=src) -> rax=length copied
asm_strcpy:
    xor     rax, rax
.loop:
    movzx   ecx, byte [rsi + rax]
    mov     [rdi + rax], cl
    test    cl, cl
    jz      .done
    inc     rax
    jmp     .loop
.done:
    ret

; asm_uint_to_str(rdi=value, rsi=buf) -> rax=length
; Writes decimal string, returns length
asm_uint_to_str:
    push    rbx
    push    r12
    mov     r12, rsi
    xor     ecx, ecx           ; digit count
    mov     rax, rdi
    mov     r8, 10
    ; push digits in reverse
.digit_loop:
    xor     edx, edx
    div     r8
    add     dl, '0'
    push    rdx
    inc     ecx
    test    rax, rax
    jnz     .digit_loop
    ; pop digits to buffer
    mov     eax, ecx            ; save length
    mov     ebx, ecx
.store_loop:
    pop     rdx
    mov     [r12], dl
    inc     r12
    dec     ebx
    jnz     .store_loop
    pop     r12
    pop     rbx
    ret

; asm_uint_to_str_right(rdi=value, rsi=buf, edx=width) -> rax=width
; Right-justified number in buffer of given width (space padded)
asm_uint_to_str_right:
    push    rbx
    push    r12
    push    r13
    push    r14
    mov     r12, rsi            ; buf
    mov     r13d, edx           ; width
    mov     rax, rdi            ; value
    xor     ecx, ecx           ; digit count
    mov     r8, 10
    ; Fill buffer with spaces first
    xor     r14d, r14d
.fill_loop:
    cmp     r14d, r13d
    jge     .fill_done
    mov     byte [r12 + r14], ' '
    inc     r14d
    jmp     .fill_loop
.fill_done:
    ; Now put digits from right
    lea     r14, [r12 + r13 - 1]  ; rightmost position
.digit_loop2:
    xor     edx, edx
    div     r8
    add     dl, '0'
    mov     [r14], dl
    dec     r14
    inc     ecx
    test    rax, rax
    jnz     .digit_loop2

    mov     eax, r13d
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

section .note.GNU-stack noalloc noexec nowrite progbits
