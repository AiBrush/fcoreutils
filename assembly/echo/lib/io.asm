%include "include/linux.inc"

global asm_write
global asm_exit
global asm_write_err

section .text

; asm_write(rdi=fd, rsi=buf, rdx=len) -> rax=0 on success, negative errno on error
; Retries on EINTR and handles short writes automatically
asm_write:
    push    rbx
    push    r12
    push    r13
    mov     rbx, rdi        ; fd
    mov     r12, rsi        ; buf
    mov     r13, rdx        ; remaining len
.retry:
    mov     rax, SYS_WRITE
    mov     rdi, rbx
    mov     rsi, r12
    mov     rdx, r13
    syscall
    cmp     rax, -4         ; -EINTR?
    je      .retry
    test    rax, rax
    js      .error          ; negative = errno
    add     r12, rax        ; advance buffer pointer
    sub     r13, rax        ; decrease remaining
    jnz     .retry          ; short write — retry with remainder
    ; Success: all bytes written
    xor     eax, eax
    pop     r13
    pop     r12
    pop     rbx
    ret
.error:
    pop     r13
    pop     r12
    pop     rbx
    ret                     ; rax = negative errno

; asm_write_err(rsi=buf, rdx=len) -- writes to stderr
asm_write_err:
    mov     rdi, STDERR
    jmp     asm_write

; asm_exit(rdi=code) -- never returns
asm_exit:
    mov     rax, SYS_EXIT
    syscall

section .note.GNU-stack noalloc noexec nowrite progbits
