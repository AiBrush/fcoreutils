%include "include/linux.inc"

global asm_check_flag

extern asm_strcmp

section .data
    str_help_flag:    db "--help", 0
    str_version_flag: db "--version", 0

section .text

; asm_check_flag(rdi=argv_ptr) -> rax: 0=none, 1=help, 2=version
; Checks if the string at rdi matches --help or --version
asm_check_flag:
    push    rbx
    mov     rbx, rdi        ; save the argument string

    ; Check --help
    mov     rdi, rbx
    lea     rsi, [rel str_help_flag]
    call    asm_strcmp
    test    rax, rax
    jnz     .check_version
    mov     rax, 1          ; return 1 for --help
    pop     rbx
    ret

.check_version:
    mov     rdi, rbx
    lea     rsi, [rel str_version_flag]
    call    asm_strcmp
    test    rax, rax
    jnz     .none
    mov     rax, 2          ; return 2 for --version
    pop     rbx
    ret

.none:
    xor     rax, rax        ; return 0 for no match
    pop     rbx
    ret
