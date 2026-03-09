; macros.inc — Reusable assembly macros

%macro WRITE 3
    mov     rax, SYS_WRITE
    mov     rdi, %1
    mov     rsi, %2
    mov     rdx, %3
    syscall
%endmacro

%macro EXIT 1
    mov     rax, SYS_EXIT
    mov     rdi, %1
    syscall
%endmacro

%macro READ 3
    mov     rax, SYS_READ
    mov     rdi, %1
    mov     rsi, %2
    mov     rdx, %3
    syscall
%endmacro

; Block SIGPIPE via rt_sigprocmask so we get EPIPE instead of killed
%macro BLOCK_SIGPIPE 0
    ; Set up signal mask with bit 13 (SIGPIPE)
    sub     rsp, 16
    mov     qword [rsp], 0
    mov     qword [rsp+8], 0
    bts     qword [rsp], SIGPIPE
    mov     rax, SYS_RT_SIGPROCMASK
    mov     rdi, SIG_BLOCK
    mov     rsi, rsp
    xor     rdx, rdx
    mov     r10, 8
    syscall
    add     rsp, 16
%endmacro
