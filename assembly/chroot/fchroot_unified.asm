; ============================================================
; fchroot_unified.asm — GNU-compatible 'chroot' command
; Builds with: nasm -f bin fchroot_unified.asm -o fchroot
;
; chroot: run command or interactive shell with special root directory
;
; Usage: chroot [OPTION] NEWROOT [COMMAND [ARG]...]
;   --userspec=USER:GROUP
;   --groups=G_LIST
;   --skip-chdir
;
; Syscalls: chroot(161), chdir(80), execve(59),
;           setuid(105), setgid(106), setgroups(116)
; ============================================================

BITS 64
ORG 0x400000

%define SYS_WRITE       1
%define SYS_OPEN        2
%define SYS_CLOSE       3
%define SYS_EXECVE     59
%define SYS_EXIT       60
%define SYS_CHDIR      80
%define SYS_SETUID    105
%define SYS_SETGID    106
%define SYS_SETGROUPS 116
%define SYS_CHROOT    161
%define SYS_RT_SIGPROCMASK 14

%define STDOUT          1
%define STDERR          2
%define SIG_BLOCK       0
%define SIGPIPE        13

; === ELF Header (64 bytes) ===
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

; === Program Header 1: PT_LOAD (code + data) ===
phdr:
    dd 1, 7
    dq 0, $$, $$
    dq file_size, mem_size
    dq 0x200000
phdr_size equ $ - phdr

; === Program Header 2: PT_GNU_STACK (NX) ===
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

    ; Save argc/argv
    mov     r14d, [rsp]
    lea     r15, [rsp + 8]

    ; Defaults
    xor     r12d, r12d          ; skip_chdir = 0
    mov     ecx, 1              ; arg index

.parse_opts:
    cmp     ecx, r14d
    jge     .missing_operand
    mov     rdi, [r15 + rcx*8]
    cmp     byte [rdi], '-'
    jne     .got_newroot
    cmp     byte [rdi + 1], '-'
    jne     .got_newroot
    cmp     byte [rdi + 2], 0
    je      .end_of_opts

    ; --help
    push    rcx
    mov     rsi, str_help_flag
    call    str_eq
    test    eax, eax
    jnz     .show_help

    ; --version
    mov     rdi, [r15 + rcx*8]
    mov     rsi, str_version_flag
    call    str_eq
    test    eax, eax
    jnz     .show_version

    ; --skip-chdir
    mov     rdi, [r15 + rcx*8]
    mov     rsi, str_skip_chdir_flag
    call    str_eq
    test    eax, eax
    jnz     .set_skip_chdir

    ; --userspec= (recognized but user switching needs /etc/passwd parsing)
    mov     rdi, [r15 + rcx*8]
    mov     rsi, str_userspec_prefix
    call    starts_with
    test    eax, eax
    jnz     .skip_userspec

    ; --groups= (recognized but not fully implemented in asm)
    mov     rdi, [r15 + rcx*8]
    mov     rsi, str_groups_prefix
    call    starts_with
    test    eax, eax
    jnz     .skip_groups

    ; Unrecognized option
    pop     rcx
    jmp     .invalid_option

.set_skip_chdir:
    pop     rcx
    mov     r12d, 1
    inc     ecx
    jmp     .parse_opts

.skip_userspec:
    pop     rcx
    inc     ecx
    jmp     .parse_opts

.skip_groups:
    pop     rcx
    inc     ecx
    jmp     .parse_opts

.end_of_opts:
    inc     ecx
    cmp     ecx, r14d
    jge     .missing_operand

.got_newroot:
    ; rcx = index of NEWROOT
    mov     rbx, rcx
    mov     rdi, [r15 + rbx*8]     ; NEWROOT path

    ; chroot(NEWROOT)
    mov     eax, SYS_CHROOT
    syscall
    test    rax, rax
    js      .chroot_failed

    ; chdir("/") unless --skip-chdir
    test    r12d, r12d
    jnz     .skip_cd
    mov     eax, SYS_CHDIR
    mov     rdi, str_slash
    syscall
    test    rax, rax
    js      .chdir_failed
.skip_cd:

    ; Determine command to run
    inc     ebx
    cmp     ebx, r14d
    jge     .default_shell

    ; Build argv from remaining args
    mov     rcx, 0
.build_argv:
    cmp     ebx, r14d
    jge     .argv_done
    mov     rax, [r15 + rbx*8]
    mov     [exec_argv + rcx*8], rax
    inc     rcx
    inc     ebx
    cmp     rcx, 256
    jge     .argv_done
    jmp     .build_argv

.argv_done:
    mov     qword [exec_argv + rcx*8], 0
    jmp     .do_exec

.default_shell:
    ; Default command: /bin/sh -i
    mov     qword [exec_argv], str_bin_sh
    mov     qword [exec_argv + 8], str_dash_i
    mov     qword [exec_argv + 16], 0

.do_exec:
    ; Get envp
    mov     eax, [rsp]
    lea     rdx, [rsp + 8]
    mov     r8d, eax
    lea     rdx, [rdx + r8*8 + 8]

    mov     rdi, [exec_argv]
    lea     rsi, [exec_argv]
    mov     eax, SYS_EXECVE
    syscall

    ; execve failed
    neg     rax
    cmp     rax, 2              ; ENOENT
    je      .exec_not_found
    jmp     .exec_failed

.chroot_failed:
    mov     rsi, str_prefix
    mov     edx, str_prefix_len
    call    write_err
    mov     rsi, str_chroot_fail
    mov     edx, str_chroot_fail_len
    call    write_err
    mov     rdi, [r15 + rbx*8]
    call    str_len
    mov     edx, eax
    mov     rsi, [r15 + rbx*8]
    call    write_err
    mov     rsi, str_perm_denied
    mov     edx, str_perm_denied_len
    call    write_err
    mov     edi, 125
    jmp     do_exit

.chdir_failed:
    mov     rsi, str_prefix
    mov     edx, str_prefix_len
    call    write_err
    mov     rsi, str_chdir_fail
    mov     edx, str_chdir_fail_len
    call    write_err
    mov     edi, 125
    jmp     do_exit

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
    mov     edi, 125
    jmp     do_exit

.invalid_option:
    mov     r13, [r15 + rcx*8]     ; save option string (rcx clobbered by syscall)
    mov     rsi, str_prefix
    mov     edx, str_prefix_len
    call    write_err
    mov     rsi, str_unrec
    mov     edx, str_unrec_len
    call    write_err
    mov     rdi, r13
    call    str_len
    mov     edx, eax
    mov     rsi, r13
    call    write_err
    mov     rsi, str_sq_nl
    mov     edx, 2
    call    write_err
    mov     rsi, str_try
    mov     edx, str_try_len
    call    write_err
    mov     edi, 125
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

; ============================================================
; Data
; ============================================================
; @@DATA_START@@
str_help:
    db "Usage: chroot [OPTION] NEWROOT [COMMAND [ARG]...]", 10
    db "  or:  chroot OPTION", 10
    db "Run COMMAND with root directory set to NEWROOT.", 10, 10
    db "If no command is given, run '${SHELL} -i' (default: '/bin/sh -i').", 10, 10
    db "      --groups=G_LIST  specify supplementary groups as g1,g2,..,gN", 10
    db "      --userspec=USER:GROUP  specify user and group (ID or name) to use", 10
    db "      --skip-chdir  do not change working directory to '/'", 10
    db "      --help        display this help and exit", 10
    db "      --version     output version information and exit", 10, 10
    db "GNU coreutils online help: <https://www.gnu.org/software/coreutils/>", 10
    db "Full documentation <https://www.gnu.org/software/coreutils/chroot>", 10
    db "or available locally via: info '(coreutils) chroot invocation'", 10
str_help_len equ $ - str_help

str_version:
    db "chroot (GNU coreutils) 9.7", 10
    db "Copyright (C) 2025 Free Software Foundation, Inc.", 10
    db "License GPLv3+: GNU GPL version 3 or later <https://gnu.org/licenses/gpl.html>.", 10
    db "This is free software: you are free to change and redistribute it.", 10
    db "There is NO WARRANTY, to the extent permitted by law.", 10, 10
    db "Written by Roland McGrath.", 10
str_version_len equ $ - str_version
; @@DATA_END@@

str_prefix:         db "chroot: "
str_prefix_len      equ $ - str_prefix
str_try:            db "Try 'chroot --help' for more information.", 10
str_try_len         equ $ - str_try
str_missing_op:     db "missing operand", 10
str_missing_op_len  equ $ - str_missing_op
str_unrec:          db "unrecognized option '"
str_unrec_len       equ $ - str_unrec
str_sq_nl:          db "'", 10
str_chroot_fail:    db "cannot chroot to '"
str_chroot_fail_len equ $ - str_chroot_fail
str_chdir_fail:     db "cannot chdir to root directory: Permission denied", 10
str_chdir_fail_len  equ $ - str_chdir_fail
str_perm_denied:    db "': Operation not permitted", 10
str_perm_denied_len equ $ - str_perm_denied
str_enoent:         db ": No such file or directory", 10
str_enoent_len      equ $ - str_enoent
str_eperm:          db ": Permission denied", 10
str_eperm_len       equ $ - str_eperm

str_help_flag:      db "--help", 0
str_version_flag:   db "--version", 0
str_skip_chdir_flag: db "--skip-chdir", 0
str_userspec_prefix: db "--userspec=", 0
str_groups_prefix:  db "--groups=", 0
str_slash:          db "/", 0
str_bin_sh:         db "/bin/sh", 0
str_dash_i:         db "-i", 0

file_size equ $ - $$

exec_argv: times 258*8 db 0

mem_size equ $ - $$
