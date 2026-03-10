; io.asm — I/O library functions for fcoreutils assembly tools
%include "include/linux.inc"

global asm_write
global asm_write_all
global asm_read
global asm_exit
global asm_open
global asm_close
global asm_fstat
global asm_mmap
global asm_munmap

section .text

; asm_write(rdi=fd, rsi=buf, rdx=len) -> rax=bytes_written or negative errno
; Handles EINTR
asm_write:
.retry:
    mov     rax, SYS_WRITE
    syscall
    cmp     rax, EINTR
    je      .retry
    ret

; asm_write_all(rdi=fd, rsi=buf, rdx=len) -> rax=0 on success, negative errno on error
; Handles partial writes + EINTR
asm_write_all:
    push    rbx
    push    r12
    push    r13
    mov     rbx, rdi            ; fd
    mov     r12, rsi            ; buf pointer
    mov     r13, rdx            ; remaining bytes
.loop:
    test    r13, r13
    jle     .success
    mov     rdi, rbx
    mov     rsi, r12
    mov     rdx, r13
    mov     rax, SYS_WRITE
    syscall
    cmp     rax, EINTR
    je      .loop               ; EINTR — retry
    test    rax, rax
    js      .error              ; negative = error
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
    ; Return the actual negative errno
    pop     r13
    pop     r12
    pop     rbx
    ret

; asm_read(rdi=fd, rsi=buf, rdx=len) -> rax=bytes_read or negative errno
; Handles EINTR automatically
asm_read:
.retry:
    mov     rax, SYS_READ
    syscall
    cmp     rax, EINTR
    je      .retry
    ret

; asm_open(rdi=path, rsi=flags, rdx=mode) -> rax=fd or negative errno
asm_open:
    mov     rax, SYS_OPEN
    syscall
    ret

; asm_close(rdi=fd) -> rax=0 or error
asm_close:
    mov     rax, SYS_CLOSE
    syscall
    ret

; asm_fstat(rdi=fd, rsi=stat_buf) -> rax=0 or negative errno
asm_fstat:
    mov     rax, SYS_FSTAT
    syscall
    ret

; asm_mmap(rdi=addr, rsi=len, rdx=prot, r10=flags, r8=fd, r9=offset) -> rax=ptr or negative errno
asm_mmap:
    mov     rax, SYS_MMAP
    syscall
    ret

; asm_munmap(rdi=addr, rsi=len) -> rax=0 or negative errno
asm_munmap:
    mov     rax, SYS_MUNMAP
    syscall
    ret

; asm_exit(rdi=code)
asm_exit:
    mov     rax, SYS_EXIT
    syscall

section .note.GNU-stack noalloc noexec nowrite progbits
