%include "include/linux.inc"

global asm_check_flag

section .text

; asm_check_flag(rdi=argv_entry, rsi=flag_str) -> rax: 0 if match, non-zero otherwise
; Simple string comparison wrapper for argument checking
asm_check_flag:
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
