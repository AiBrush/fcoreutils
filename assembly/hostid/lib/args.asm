%include "include/linux.inc"

global asm_check_flag

section .data
    str_help_flag:    db "--help", 0
    str_version_flag: db "--version", 0

section .text

; asm_check_flag(rdi=argv_ptr) -> rax: 0=none, 1=help, 2=version
; Checks if the string at rdi is a prefix of --help or --version
; (matching GNU getopt_long prefix matching behavior)
asm_check_flag:
    push    rbx
    mov     rbx, rdi            ; save the argument string

    ; Try prefix match against --help
    lea     rsi, [rel str_help_flag]
    call    .prefix_match
    test    rax, rax
    jnz     .is_help

    ; Try prefix match against --version
    mov     rdi, rbx
    lea     rsi, [rel str_version_flag]
    call    .prefix_match
    test    rax, rax
    jnz     .is_version

    ; No match
    xor     rax, rax
    pop     rbx
    ret

.is_help:
    mov     rax, 1
    pop     rbx
    ret

.is_version:
    mov     rax, 2
    pop     rbx
    ret

; .prefix_match(rdi=input, rsi=full_option) -> rax: 1=match, 0=no match
; Input must be a prefix of full_option (at least 3 chars: '--' + first char)
; Input must end where it ends (null terminator) and full_option continues or matches
.prefix_match:
    ; Check that input starts with '--' and has at least one more char
    cmp     byte [rdi], '-'
    jne     .pm_no
    cmp     byte [rdi + 1], '-'
    jne     .pm_no
    cmp     byte [rdi + 2], 0
    je      .pm_no              ; bare "--" is not a prefix match

    ; Compare char by char
    xor     rcx, rcx
.pm_loop:
    mov     al, [rdi + rcx]
    test    al, al
    jz      .pm_yes             ; input ended, it was a prefix
    cmp     al, [rsi + rcx]
    jne     .pm_no              ; mismatch
    inc     rcx
    jmp     .pm_loop

.pm_yes:
    mov     rax, 1
    ret
.pm_no:
    xor     rax, rax
    ret

section .note.GNU-stack noalloc noexec nowrite progbits
