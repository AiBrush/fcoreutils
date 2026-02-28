; str.asm — string utilities
; Not needed for true, but included for project structure completeness

section .text
global asm_strlen

; asm_strlen(rdi=str) -> rax=length (not counting null terminator)
asm_strlen:
    xor     rax, rax
.loop:
    cmp     byte [rdi + rax], 0
    je      .done
    inc     rax
    jmp     .loop
.done:
    ret
