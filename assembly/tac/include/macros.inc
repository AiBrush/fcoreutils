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

; Block SIGPIPE so write() returns EPIPE instead of killing the process
%macro BLOCK_SIGPIPE 0
    sub     rsp, 16
    mov     qword [rsp], 0x1000     ; sigset: bit 12 = SIGPIPE
    mov     eax, SYS_RT_SIGPROCMASK
    xor     edi, edi                ; SIG_BLOCK = 0
    mov     rsi, rsp
    xor     edx, edx                ; old_set = NULL
    mov     r10d, 8                 ; sigsetsize = 8
    syscall
    add     rsp, 16
%endmacro
