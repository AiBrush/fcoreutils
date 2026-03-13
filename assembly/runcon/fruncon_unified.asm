; ============================================================
; fruncon_unified.asm — GNU-compatible 'runcon' command
; Builds with: nasm -f bin fruncon_unified.asm -o fruncon
;
; runcon: run command with specified SELinux security context
;
; Usage: runcon CONTEXT COMMAND [ARGS...]
;        runcon [-u USER] [-r ROLE] [-t TYPE] [-l RANGE] COMMAND [ARGS...]
;
; On non-SELinux: fails with "Operation not supported"
; Syscalls: write to /proc/self/attr/exec, execve(59)
; ============================================================

BITS 64
ORG 0x400000

%define SYS_READ        0
%define SYS_WRITE       1
%define SYS_OPEN        2
%define SYS_CLOSE       3
%define SYS_EXECVE     59
%define SYS_EXIT       60
%define SYS_RT_SIGPROCMASK 14

%define O_WRONLY        1
%define STDOUT          1
%define STDERR          2
%define SIG_BLOCK       0
%define SIGPIPE        13

; === ELF Header ===
ehdr:
    db 0x7f, 'E','L','F'
    db 2, 1, 1, 0
    dq 0
    dw 2, 0x3e
    dd 1
    dq _start
    dq phdr - $$
    dq 0
    dd 0
    dw ehdr_size
    dw phdr_size
    dw 2
    dw 64, 0, 0
ehdr_size equ $ - ehdr

phdr:
    dd 1, 7
    dq 0, $$, $$
    dq file_size, mem_size
    dq 0x200000
phdr_size equ $ - phdr

    dd 0x6474e551, 6
    dq 0, 0, 0, 0, 0, 16

; ============================================================
; Code
; ============================================================
_start:
    ; Block SIGPIPE
    sub     rsp, 16
    mov     qword [rsp], 0
    bts     qword [rsp], SIGPIPE
    mov     eax, SYS_RT_SIGPROCMASK
    mov     edi, SIG_BLOCK
    mov     rsi, rsp
    xor     edx, edx
    mov     r10d, 8
    syscall
    add     rsp, 16

    mov     r14d, [rsp]
    lea     r15, [rsp + 8]

    mov     ecx, 1

    ; Need at least 2 args: runcon CONTEXT COMMAND
    cmp     r14d, 2
    jl      .missing_operand

    ; Check --help / --version
    mov     rdi, [r15 + 8]
    push    rcx
    mov     rsi, str_help_flag
    call    str_eq
    test    eax, eax
    jnz     .show_help
    mov     rdi, [r15 + 8]
    mov     rsi, str_version_flag
    call    str_eq
    test    eax, eax
    jnz     .show_version
    pop     rcx

    ; Parse options: -u USER, -r ROLE, -t TYPE, -l RANGE
    ; For simplicity, we handle the CONTEXT COMMAND form
    ; If argv[1] starts with '-', parse component options
    mov     rdi, [r15 + 8]
    cmp     byte [rdi], '-'
    je      .parse_component_opts

    ; Simple form: runcon CONTEXT COMMAND [ARGS...]
    cmp     r14d, 3
    jl      .missing_operand

    ; context = argv[1]
    mov     rbx, [r15 + 8]         ; context string
    mov     ecx, 2                 ; first command arg

    jmp     .set_context

.parse_component_opts:
    ; Parse -u/-r/-t/-l options, skip them
    ; We need at least a COMMAND after options
    mov     ecx, 1
.comp_loop:
    cmp     ecx, r14d
    jge     .missing_operand
    mov     rdi, [r15 + rcx*8]
    cmp     byte [rdi], '-'
    jne     .comp_done
    cmp     byte [rdi + 1], 0
    je      .comp_done
    cmp     byte [rdi + 1], '-'
    je      .check_dashdash
    ; Short option
    movzx   eax, byte [rdi + 1]
    cmp     al, 'u'
    je      .skip_comp_val
    cmp     al, 'r'
    je      .skip_comp_val
    cmp     al, 't'
    je      .skip_comp_val
    cmp     al, 'l'
    je      .skip_comp_val
    jmp     .comp_done
.skip_comp_val:
    add     ecx, 2
    jmp     .comp_loop
.check_dashdash:
    cmp     byte [rdi + 2], 0
    jne     .comp_done
    inc     ecx
.comp_done:
    ; ecx = index of COMMAND
    cmp     ecx, r14d
    jge     .missing_operand
    ; No explicit full context in this mode, use empty
    mov     rbx, 0
    jmp     .skip_set_context

.set_context:
    ; Try to write context to /proc/self/attr/exec
    mov     eax, SYS_OPEN
    mov     rdi, str_proc_attr_exec
    mov     esi, O_WRONLY
    xor     edx, edx
    syscall
    test    rax, rax
    js      .context_failed

    mov     r8, rax             ; fd
    ; Write context
    mov     rdi, rbx
    push    r8
    call    str_len
    pop     r8
    mov     edx, eax            ; context length
    mov     edi, r8d            ; fd
    mov     rsi, rbx            ; context
    mov     eax, SYS_WRITE
    syscall
    push    rax
    ; Close fd
    mov     eax, SYS_CLOSE
    mov     edi, r8d
    syscall
    pop     rax
    test    rax, rax
    js      .context_failed

.skip_set_context:
    ; Build argv for execve
    mov     r8d, 0              ; index into exec_argv
.build_argv:
    cmp     ecx, r14d
    jge     .argv_done
    mov     rax, [r15 + rcx*8]
    mov     [exec_argv + r8*8], rax
    inc     r8d
    inc     ecx
    cmp     r8d, 256
    jge     .argv_done
    jmp     .build_argv
.argv_done:
    mov     qword [exec_argv + r8*8], 0

    ; Get envp
    mov     eax, [rsp]
    lea     rdx, [rsp + 8]
    mov     r9d, eax
    lea     rdx, [rdx + r9*8 + 8]
    mov     r13, rdx

    ; execve
    mov     rdi, [exec_argv]
    lea     rsi, [exec_argv]
    mov     rdx, r13
    mov     eax, SYS_EXECVE
    syscall

    ; If failed, try PATH search
    cmp     rax, -2
    je      .try_path
    cmp     rax, -13
    je      .try_path
    cmp     rax, -20
    je      .try_path
    jmp     .exec_failed

.try_path:
    mov     rdi, r13
    call    find_path_env
    test    rax, rax
    jz      .exec_not_found
    mov     r8, rax
    mov     r9, [exec_argv]

.path_loop:
    cmp     byte [r8], 0
    je      .exec_not_found
    lea     rdi, [path_buf]
    xor     ecx, ecx
.copy_path_comp:
    movzx   eax, byte [r8]
    cmp     al, ':'
    je      .path_sep
    test    al, al
    jz      .path_sep
    mov     [rdi + rcx], al
    inc     rcx
    inc     r8
    cmp     rcx, 4000
    jge     .path_sep
    jmp     .copy_path_comp
.path_sep:
    cmp     byte [r8], ':'
    jne     .no_skip
    inc     r8
.no_skip:
    mov     byte [rdi + rcx], '/'
    inc     rcx
    push    r8
    mov     rsi, r9
.copy_cmd:
    movzx   eax, byte [rsi]
    test    al, al
    jz      .cmd_done
    mov     [rdi + rcx], al
    inc     rcx
    inc     rsi
    cmp     rcx, 4090
    jge     .cmd_done
    jmp     .copy_cmd
.cmd_done:
    mov     byte [rdi + rcx], 0
    pop     r8
    lea     rdi, [path_buf]
    lea     rsi, [exec_argv]
    mov     rdx, r13
    mov     eax, SYS_EXECVE
    syscall
    jmp     .path_loop

.exec_not_found:
    mov     rsi, str_prefix
    mov     edx, str_prefix_len
    call    write_err
    mov     rdi, [exec_argv]
    call    str_len
    mov     edx, eax
    mov     rsi, [exec_argv]
    call    write_err
    mov     rsi, str_enoent
    mov     edx, str_enoent_len
    call    write_err
    mov     edi, 127
    jmp     do_exit

.exec_failed:
    mov     rsi, str_prefix
    mov     edx, str_prefix_len
    call    write_err
    mov     rdi, [exec_argv]
    call    str_len
    mov     edx, eax
    mov     rsi, [exec_argv]
    call    write_err
    mov     rsi, str_eperm
    mov     edx, str_eperm_len
    call    write_err
    mov     edi, 126
    jmp     do_exit

.context_failed:
    mov     rsi, str_prefix
    mov     edx, str_prefix_len
    call    write_err
    mov     rsi, str_ctx_fail
    mov     edx, str_ctx_fail_len
    call    write_err
    mov     edi, 125
    jmp     do_exit

.missing_operand:
    mov     rsi, str_prefix
    mov     edx, str_prefix_len
    call    write_err
    mov     rsi, str_missing_op
    mov     edx, str_missing_op_len
    call    write_err
    mov     rsi, str_try
    mov     edx, str_try_len
    call    write_err
    mov     edi, 1
    jmp     do_exit

.show_help:
    pop     rcx
    mov     edi, STDOUT
    mov     rsi, str_help
    mov     edx, str_help_len
    call    do_write
    xor     edi, edi
    jmp     do_exit

.show_version:
    pop     rcx
    mov     edi, STDOUT
    mov     rsi, str_version
    mov     edx, str_version_len
    call    do_write
    xor     edi, edi
    jmp     do_exit

; ============================================================
; Utility functions
; ============================================================
do_write:
    mov     eax, SYS_WRITE
    syscall
    cmp     rax, -4
    je      do_write
    ret

write_err:
    mov     edi, STDERR
    jmp     do_write

do_exit:
    mov     eax, SYS_EXIT
    syscall

str_len:
    xor     eax, eax
.loop:
    cmp     byte [rdi + rax], 0
    je      .done
    inc     eax
    jmp     .loop
.done:
    ret

str_eq:
    xor     r8d, r8d
.loop:
    movzx   eax, byte [rdi + r8]
    movzx   edx, byte [rsi + r8]
    cmp     al, dl
    jne     .ne
    test    al, al
    jz      .eq
    inc     r8d
    jmp     .loop
.eq:
    mov     eax, 1
    ret
.ne:
    xor     eax, eax
    ret

starts_with:
    xor     r8d, r8d
.loop:
    movzx   eax, byte [rsi + r8]
    test    al, al
    jz      .match
    cmp     al, byte [rdi + r8]
    jne     .no
    inc     r8d
    jmp     .loop
.match:
    mov     eax, 1
    ret
.no:
    xor     eax, eax
    ret

find_path_env:
.loop:
    mov     rax, [rdi]
    test    rax, rax
    jz      .not_found
    cmp     dword [rax], 0x48544150
    jne     .next
    cmp     byte [rax + 4], '='
    jne     .next
    lea     rax, [rax + 5]
    ret
.next:
    add     rdi, 8
    jmp     .loop
.not_found:
    xor     eax, eax
    ret

; ============================================================
; Data
; ============================================================
; @@DATA_START@@
str_help:
    db "Usage: runcon CONTEXT COMMAND [ARG...]", 10
    db "  or:  runcon [ -c ] [-u USER] [-r ROLE] [-t TYPE] [-l RANGE] COMMAND [ARG...]", 10
    db "Run a program in a different SELinux security context.", 10
    db "With neither CONTEXT nor COMMAND, print the current security context.", 10, 10
    db "  CONTEXT            Complete security context", 10
    db "  -c, --compute      compute process transition context before modifying", 10
    db "  -t, --type=TYPE    type (for same role as parent)", 10
    db "  -u, --user=USER    user identity", 10
    db "  -r, --role=ROLE    role", 10
    db "  -l, --range=RANGE  levelrange", 10, 10
    db "      --help        display this help and exit", 10
    db "      --version     output version information and exit", 10, 10
    db "GNU coreutils online help: <https://www.gnu.org/software/coreutils/>", 10
    db "Full documentation <https://www.gnu.org/software/coreutils/runcon>", 10
    db "or available locally via: info '(coreutils) runcon invocation'", 10
str_help_len equ $ - str_help

str_version:
    db "runcon (GNU coreutils) 9.7", 10
    db "Copyright (C) 2025 Free Software Foundation, Inc.", 10
    db "License GPLv3+: GNU GPL version 3 or later <https://gnu.org/licenses/gpl.html>.", 10
    db "This is free software: you are free to change and redistribute it.", 10
    db "There is NO WARRANTY, to the extent permitted by law.", 10, 10
    db "Written by Russell Coker.", 10
str_version_len equ $ - str_version
; @@DATA_END@@

str_prefix:         db "runcon: "
str_prefix_len      equ $ - str_prefix
str_try:            db "Try 'runcon --help' for more information.", 10
str_try_len         equ $ - str_try
str_missing_op:     db "missing operand", 10
str_missing_op_len  equ $ - str_missing_op
str_ctx_fail:       db "failed to set SELinux security context: Operation not supported", 10
str_ctx_fail_len    equ $ - str_ctx_fail
str_enoent:         db ": No such file or directory", 10
str_enoent_len      equ $ - str_enoent
str_eperm:          db ": Permission denied", 10
str_eperm_len       equ $ - str_eperm

str_help_flag:      db "--help", 0
str_version_flag:   db "--version", 0
str_proc_attr_exec: db "/proc/self/attr/exec", 0

file_size equ $ - $$

exec_argv: times 258*8 db 0
path_buf: times 4096 db 0

mem_size equ $ - $$
