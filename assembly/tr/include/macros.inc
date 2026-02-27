; macros.inc — Reusable assembly macros
; Shared across all assembly tools

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

; STRLEN src — result in rcx (clobbers rdi, rax, rcx)
; src must be null-terminated
%macro STRLEN 1
    mov     rdi, %1
    xor     ecx, ecx
    not     rcx
    xor     eax, eax
    repne scasb
    not     rcx
    dec     rcx
%endmacro

%endif
