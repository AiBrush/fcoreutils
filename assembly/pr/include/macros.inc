; macros.inc — Reusable assembly macros for fcoreutils
; Shared across all fcoreutils assembly tools

%ifndef MACROS_INC
%define MACROS_INC

; WRITE fd, buf, len — raw write syscall
%macro WRITE 3
    mov     rax, SYS_WRITE
    mov     rdi, %1
    mov     rsi, %2
    mov     rdx, %3
    syscall
%endmacro

; READ fd, buf, len — raw read syscall
%macro READ 3
    mov     rax, SYS_READ
    mov     rdi, %1
    mov     rsi, %2
    mov     rdx, %3
    syscall
%endmacro

; EXIT code — exit process
%macro EXIT 1
    mov     rax, SYS_EXIT
    mov     rdi, %1
    syscall
%endmacro

; OPEN path, flags, mode — open file
%macro OPEN 3
    mov     rax, SYS_OPEN
    mov     rdi, %1
    mov     rsi, %2
    mov     rdx, %3
    syscall
%endmacro

; CLOSE fd — close file descriptor
%macro CLOSE 1
    mov     rax, SYS_CLOSE
    mov     rdi, %1
    syscall
%endmacro

; BLOCK_SIGPIPE — block SIGPIPE so write returns EPIPE instead of killing us
%macro BLOCK_SIGPIPE 0
    sub     rsp, 16
    mov     qword [rsp], (1 << (SIGPIPE - 1))
    mov     eax, SYS_RT_SIGPROCMASK
    xor     edi, edi            ; SIG_BLOCK
    mov     rsi, rsp
    xor     edx, edx            ; old_set = NULL
    mov     r10d, 8             ; sigsetsize
    syscall
    add     rsp, 16
%endmacro

%endif
