%include "include/linux.inc"

global asm_find_env

section .text

; asm_find_env(rdi=envp, rsi=name, rdx=name_len) -> rax=pointer to value or 0
; Searches environment block for variable with given name prefix (including '=')
; Returns pointer to the character after '=' or 0 if not found
asm_find_env:
    push    rbx
    push    r12
    push    r13
    mov     rbx, rdi            ; envp
    mov     r12, rsi            ; name prefix (e.g. "PWD=")
    mov     r13, rdx            ; name prefix length
.loop:
    mov     rdi, [rbx]
    test    rdi, rdi
    jz      .not_found          ; NULL = end of envp
    ; Compare first name_len bytes
    mov     rsi, r12
    mov     rcx, r13
.cmp:
    test    rcx, rcx
    jz      .found              ; all bytes matched
    movzx   eax, byte [rdi]
    cmp     al, byte [rsi]
    jne     .next
    inc     rdi
    inc     rsi
    dec     rcx
    jmp     .cmp
.found:
    mov     rax, rdi            ; pointer to value (after prefix)
    pop     r13
    pop     r12
    pop     rbx
    ret
.next:
    add     rbx, 8
    jmp     .loop
.not_found:
    xor     eax, eax
    pop     r13
    pop     r12
    pop     rbx
    ret
