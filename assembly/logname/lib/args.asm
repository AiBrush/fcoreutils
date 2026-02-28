%include "include/linux.inc"

global check_flag

section .text

; check_flag(rdi=argv_entry, rsi=flag_string) -> rax=1 if match, 0 if not
; Both strings must be null-terminated
check_flag:
    xor     rcx, rcx
.loop:
    movzx   eax, byte [rdi + rcx]
    movzx   edx, byte [rsi + rcx]
    cmp     al, dl
    jne     .no_match
    test    al, al
    jz      .match
    inc     rcx
    jmp     .loop
.match:
    mov     rax, 1
    ret
.no_match:
    xor     rax, rax
    ret
