; io.asm — I/O library functions for fcoreutils assembly tools
; Canonical shared version
%include "include/linux.inc"

global asm_write
global asm_write_all
global asm_write_err
global asm_read
global asm_open
global asm_close
global asm_exit

section .text

; asm_write(rdi=fd, rsi=buf, rdx=len) -> rax=bytes_written
; Single write + EINTR retry
asm_write:
.retry:
    mov     rax, SYS_WRITE
    syscall
    cmp     rax, EINTR
    je      .retry
    ret

; asm_write_all(rdi=fd, rsi=buf, rdx=len) -> rax=0 on success, -1 on error
; Full partial-write loop + EINTR retry
asm_write_all:
    push    rbx
    push    r12
    push    r13
    mov     rbx, rdi
    mov     r12, rsi
    mov     r13, rdx
.loop:
    test    r13, r13
    jle     .success
    mov     rdi, rbx
    mov     rsi, r12
    mov     rdx, r13
    mov     rax, SYS_WRITE
    syscall
    cmp     rax, EINTR
    je      .loop
    test    rax, rax
    js      .error
    add     r12, rax
    sub     r13, rax
    jmp     .loop
.success:
    xor     eax, eax
    pop     r13
    pop     r12
    pop     rbx
    ret
.error:
    mov     rax, -1
    pop     r13
    pop     r12
    pop     rbx
    ret

; asm_write_err(rsi=buf, rdx=len) -> rax=bytes_written
; Convenience: writes to STDERR
asm_write_err:
    mov     rdi, STDERR
    jmp     asm_write

; asm_read(rdi=fd, rsi=buf, rdx=len) -> rax=bytes_read
; Single read + EINTR retry
asm_read:
.retry:
    mov     rax, SYS_READ
    syscall
    cmp     rax, EINTR
    je      .retry
    ret

; asm_open(rdi=path, rsi=flags, rdx=mode) -> rax=fd
; EINTR retry on open
asm_open:
.retry:
    mov     rax, SYS_OPEN
    syscall
    cmp     rax, EINTR
    je      .retry
    ret

; asm_close(rdi=fd) -> rax=0 or error
; EINTR retry on close
asm_close:
.retry:
    mov     rax, SYS_CLOSE
    syscall
    cmp     rax, EINTR
    je      .retry
    ret

; asm_exit(rdi=code)
; Exit process, never returns
asm_exit:
    mov     rax, SYS_EXIT
    syscall

section .note.GNU-stack noalloc noexec nowrite progbits
