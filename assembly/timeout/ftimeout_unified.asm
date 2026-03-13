; ============================================================
; ftimeout_unified.asm — AUTO-GENERATED unified file
; timeout (GNU coreutils compatible) — x86_64 Linux
; Build: nasm -f bin ftimeout_unified.asm -o ftimeout_release
; ============================================================
BITS 64
ORG 0x400000

ehdr:
    db 0x7f, 'E','L','F'
    db 2, 1, 1, 0
    dq 0
    dw 2
    dw 0x3e
    dd 1
    dq _start
    dq phdr - $$
    dq 0
    dd 0
    dw ehdr_size
    dw phdr_size
    dw 2
    dw 64
    dw 0
    dw 0
ehdr_size equ $ - ehdr

phdr:
    dd 1                        ; PT_LOAD
    dd 7                        ; PF_R | PF_W | PF_X (flat binary)
    dq 0
    dq $$
    dq $$
    dq file_size
    dq mem_size
    dq 0x200000
phdr_size equ $ - phdr

    dd 0x6474e551               ; PT_GNU_STACK
    dd 6                        ; PF_R | PF_W
    dq 0, 0, 0, 0, 0
    dq 16

%define SYS_WRITE       1
%define SYS_FORK       57
%define SYS_EXECVE     59
%define SYS_EXIT       60
%define SYS_WAIT4      61
%define SYS_KILL       62
%define SYS_ALARM      37
%define SYS_SETPGID    109
%define SYS_RT_SIGACTION 13
%define SIGALRM         14
%define SIGTERM         15
%define SIGKILL          9
%define SA_RESTORER     0x04000000
%define STDOUT          1
%define STDERR          2

; Writable data
child_pid: dq 0
kill_signal: dd 15
kill_duration: dq 0
foreground_flag: db 0
timed_out_flag: db 0

alarm_handler:
    mov     byte [timed_out_flag], 1
    ret

sig_restorer:
    mov     eax, 15             ; SYS_RT_SIGRETURN
    syscall

_write:
    mov     eax, SYS_WRITE
    syscall
    cmp     rax, -4
    je      _write
    ret

_strlen:
    xor     eax, eax
.l:
    cmp     byte [rdi + rax], 0
    je      .d
    inc     rax
    jmp     .l
.d:
    ret

_strcmp:
.l:
    movzx   eax, byte [rdi]
    movzx   ecx, byte [rsi]
    cmp     al, cl
    jne     .df
    test    al, al
    jz      .eq
    inc     rdi
    inc     rsi
    jmp     .l
.eq:
    xor     eax, eax
    ret
.df:
    sub     eax, ecx
    ret

starts_with:
.l:
    movzx   eax, byte [rsi]
    test    al, al
    jz      .m
    movzx   ecx, byte [rdi]
    cmp     al, cl
    jne     .n
    inc     rdi
    inc     rsi
    jmp     .l
.m:
    mov     eax, 1
    ret
.n:
    xor     eax, eax
    ret

parse_duration:
    push    rbx
    xor     eax, eax
    xor     ecx, ecx
.pdl:
    movzx   edx, byte [rdi]
    cmp     dl, '0'
    jb      .pds
    cmp     dl, '9'
    ja      .pds
    sub     dl, '0'
    imul    rax, 10
    movzx   edx, dl
    add     rax, rdx
    inc     ecx
    inc     rdi
    jmp     .pdl
.pds:
    test    ecx, ecx
    jz      .pddef
    movzx   edx, byte [rdi]
    test    dl, dl
    jz      .pdd
    cmp     dl, 's'
    je      .pdd
    cmp     dl, 'm'
    je      .pdm
    cmp     dl, 'h'
    je      .pdh
    cmp     dl, 'd'
    je      .pdday
    cmp     dl, '.'
    je      .pdskip
    jmp     .pdd
.pdskip:
    inc     rdi
.pdskl:
    movzx   edx, byte [rdi]
    cmp     dl, '0'
    jb      .pdcs
    cmp     dl, '9'
    ja      .pdcs
    inc     rdi
    jmp     .pdskl
.pdcs:
    movzx   edx, byte [rdi]
    cmp     dl, 's'
    je      .pdd
    cmp     dl, 'm'
    je      .pdm
    cmp     dl, 'h'
    je      .pdh
    cmp     dl, 'd'
    je      .pdday
    jmp     .pdd
.pdm:
    imul    rax, 60
    jmp     .pdd
.pdh:
    imul    rax, 3600
    jmp     .pdd
.pdday:
    imul    rax, 86400
    jmp     .pdd
.pddef:
    xor     eax, eax
.pdd:
    pop     rbx
    ret

parse_signal:
    push    rbx
    movzx   eax, byte [rdi]
    cmp     al, '0'
    jb      .psn
    cmp     al, '9'
    ja      .psn
    xor     eax, eax
.psnm:
    movzx   edx, byte [rdi]
    test    dl, dl
    jz      .psd
    cmp     dl, '0'
    jb      .psd
    cmp     dl, '9'
    ja      .psd
    sub     dl, '0'
    imul    eax, 10
    add     eax, edx
    inc     rdi
    jmp     .psnm
.psn:
    cmp     byte [rdi], 'S'
    jne     .psc
    cmp     byte [rdi+1], 'I'
    jne     .psc
    cmp     byte [rdi+2], 'G'
    jne     .psc
    add     rdi, 3
.psc:
    push    rdi
    mov     rsi, s_TERM
    call    _strcmp
    pop     rdi
    test    eax, eax
    jz      .psterm
    push    rdi
    mov     rsi, s_KILL
    call    _strcmp
    pop     rdi
    test    eax, eax
    jz      .pskill
    push    rdi
    mov     rsi, s_INT
    call    _strcmp
    pop     rdi
    test    eax, eax
    jz      .psint
    push    rdi
    mov     rsi, s_HUP
    call    _strcmp
    pop     rdi
    test    eax, eax
    jz      .pshup
    mov     eax, SIGTERM
    jmp     .psd
.psterm:
    mov     eax, SIGTERM
    jmp     .psd
.pskill:
    mov     eax, SIGKILL
    jmp     .psd
.psint:
    mov     eax, 2
    jmp     .psd
.pshup:
    mov     eax, 1
.psd:
    pop     rbx
    ret

find_path_env:
.l:
    mov     rax, [rdi]
    test    rax, rax
    jz      .nf
    cmp     dword [rax], 0x48544150
    jne     .nx
    cmp     byte [rax+4], '='
    jne     .nx
    lea     rax, [rax+5]
    ret
.nx:
    add     rdi, 8
    jmp     .l
.nf:
    xor     eax, eax
    ret

_start:
    mov     r14, [rsp]
    lea     r15, [rsp+8]
    xor     r12d, r12d
    mov     rbx, 1

    cmp     r14, 2
    jl      .missing
    mov     rdi, [r15+8]
    mov     rsi, s_help
    call    _strcmp
    test    eax, eax
    jz      .sh
    mov     rdi, [r15+8]
    mov     rsi, s_version
    call    _strcmp
    test    eax, eax
    jz      .sv

.po:
    cmp     rbx, r14
    jge     .missing
    mov     rdi, [r15+rbx*8]
    cmp     byte [rdi], '-'
    jne     .pdur
    push    rbx
    mov     rsi, s_foreground
    call    _strcmp
    pop     rbx
    test    eax, eax
    jz      .sfg
    mov     rdi, [r15+rbx*8]
    cmp     byte [rdi+1], 's'
    jne     .ck
    cmp     byte [rdi+2], 0
    jne     .csa
    inc     rbx
    cmp     rbx, r14
    jge     .missing
    mov     rdi, [r15+rbx*8]
    call    parse_signal
    mov     [kill_signal], eax
    inc     rbx
    jmp     .po
.csa:
    lea     rdi, [rdi+2]
    call    parse_signal
    mov     [kill_signal], eax
    inc     rbx
    jmp     .po
.ck:
    cmp     byte [rdi+1], 'k'
    jne     .csl
    cmp     byte [rdi+2], 0
    jne     .cka
    inc     rbx
    cmp     rbx, r14
    jge     .missing
    mov     rdi, [r15+rbx*8]
    call    parse_duration
    mov     [kill_duration], rax
    inc     rbx
    jmp     .po
.cka:
    lea     rdi, [rdi+2]
    call    parse_duration
    mov     [kill_duration], rax
    inc     rbx
    jmp     .po
.csl:
    push    rbx
    mov     rdi, [r15+rbx*8]
    mov     rsi, s_signal_eq
    call    starts_with
    pop     rbx
    test    eax, eax
    jnz     .pse
    push    rbx
    mov     rdi, [r15+rbx*8]
    mov     rsi, s_kill_eq
    call    starts_with
    pop     rbx
    test    eax, eax
    jnz     .pke
    mov     rdi, [r15+rbx*8]
    cmp     byte [rdi+1], '-'
    jne     .inv
    cmp     byte [rdi+2], 0
    jne     .inv
    inc     rbx
    jmp     .pdur
.pse:
    mov     rdi, [r15+rbx*8]
.fes:
    cmp     byte [rdi], '='
    je      .fes2
    inc     rdi
    jmp     .fes
.fes2:
    inc     rdi
    call    parse_signal
    mov     [kill_signal], eax
    inc     rbx
    jmp     .po
.pke:
    mov     rdi, [r15+rbx*8]
.fek:
    cmp     byte [rdi], '='
    je      .fek2
    inc     rdi
    jmp     .fek
.fek2:
    inc     rdi
    call    parse_duration
    mov     [kill_duration], rax
    inc     rbx
    jmp     .po
.sfg:
    mov     byte [foreground_flag], 1
    inc     rbx
    jmp     .po

.pdur:
    cmp     rbx, r14
    jge     .missing
    mov     rdi, [r15+rbx*8]
    call    parse_duration
    mov     r12, rax
    inc     rbx
    cmp     rbx, r14
    jge     .missing

    ; Build argv
    mov     rcx, 0
.ba:
    cmp     rbx, r14
    jge     .bad
    mov     rax, [r15+rbx*8]
    mov     [exec_argv+rcx*8], rax
    inc     rcx
    inc     rbx
    cmp     rcx, 256
    jge     .bad
    jmp     .ba
.bad:
    mov     qword [exec_argv+rcx*8], 0

    mov     rax, [rsp]
    lea     rdx, [rsp+8]
    lea     rdx, [rdx+rax*8+8]
    mov     rbp, rdx

    test    r12, r12
    jz      .dur0

    ; Install SIGALRM handler
    lea     rax, [alarm_handler]
    mov     [sigact], rax
    mov     qword [sigact+8], SA_RESTORER
    lea     rax, [sig_restorer]
    mov     [sigact+16], rax
    xor     eax, eax
    mov     [sigact+24], rax
    mov     [sigact+32], rax
    mov     eax, SYS_RT_SIGACTION
    mov     edi, SIGALRM
    lea     rsi, [sigact]
    lea     rdx, [sigact_old]
    mov     r10, 8
    syscall

    ; Fork
    mov     eax, SYS_FORK
    syscall
    test    rax, rax
    js      .forkfail
    jz      .child

    mov     [child_pid], rax
    cmp     byte [foreground_flag], 0
    jne     .nspg
    mov     edi, eax
    mov     esi, eax
    mov     eax, SYS_SETPGID
    syscall
.nspg:
    mov     edi, r12d
    mov     eax, SYS_ALARM
    syscall

.wl:
    sub     rsp, 8
    mov     rdi, [child_pid]
    mov     rsi, rsp
    xor     edx, edx
    xor     r10, r10
    mov     eax, SYS_WAIT4
    syscall
    cmp     rax, -4
    jne     .wd
    cmp     byte [timed_out_flag], 0
    je      .wr

    ; Timed out
    mov     rdi, [child_pid]
    cmp     byte [foreground_flag], 0
    jne     .kc
    neg     rdi
.kc:
    mov     esi, [kill_signal]
    mov     eax, SYS_KILL
    syscall
    mov     rax, [kill_duration]
    test    rax, rax
    jz      .wfd
    mov     edi, eax
    mov     eax, SYS_ALARM
    syscall
    mov     byte [timed_out_flag], 0
.wfd:
    mov     rdi, [child_pid]
    mov     rsi, rsp
    xor     edx, edx
    xor     r10, r10
    mov     eax, SYS_WAIT4
    syscall
    cmp     rax, -4
    jne     .wdt
    cmp     byte [timed_out_flag], 0
    je      .wfd
    mov     rdi, [child_pid]
    cmp     byte [foreground_flag], 0
    jne     .k9c
    neg     rdi
.k9c:
    mov     esi, SIGKILL
    mov     eax, SYS_KILL
    syscall
    mov     rdi, [child_pid]
    mov     rsi, rsp
    xor     edx, edx
    xor     r10, r10
    mov     eax, SYS_WAIT4
    syscall
.wdt:
    pop     rax
    mov     edi, 124
    mov     eax, SYS_EXIT
    syscall

.wr:
    add     rsp, 8
    jmp     .wl

.wd:
    cmp     rax, 0
    jl      .we
    pop     rax
    push    rax
    xor     edi, edi
    mov     eax, SYS_ALARM
    syscall
    pop     rax
    mov     edx, eax
    and     edx, 0x7f
    test    edx, edx
    jnz     .cs
    shr     eax, 8
    and     eax, 0xff
    mov     edi, eax
    mov     eax, SYS_EXIT
    syscall
.cs:
    mov     edi, edx
    add     edi, 128
    mov     eax, SYS_EXIT
    syscall
.we:
    add     rsp, 8
    mov     edi, 125
    mov     eax, SYS_EXIT
    syscall

.dur0:
    mov     eax, SYS_FORK
    syscall
    test    rax, rax
    js      .forkfail
    jz      .child
    mov     [child_pid], rax
    mov     rdi, rax
    mov     esi, [kill_signal]
    mov     eax, SYS_KILL
    syscall
    sub     rsp, 8
    mov     rdi, [child_pid]
    mov     rsi, rsp
    xor     edx, edx
    xor     r10, r10
    mov     eax, SYS_WAIT4
    syscall
    pop     rax
    mov     edi, 124
    mov     eax, SYS_EXIT
    syscall

.child:
    cmp     byte [foreground_flag], 0
    jne     .cexec
    xor     edi, edi
    xor     esi, esi
    mov     eax, SYS_SETPGID
    syscall
.cexec:
    mov     rdi, [exec_argv]
    lea     rsi, [exec_argv]
    mov     rdx, rbp
    mov     eax, SYS_EXECVE
    syscall
    cmp     rax, -2
    je      .cpath
    cmp     rax, -13
    je      .cpath
    cmp     rax, -20
    je      .cpath
    jmp     .cefail
.cpath:
    mov     rdi, rbp
    call    find_path_env
    test    rax, rax
    jz      .cnf
    mov     r8, rax
    mov     r9, [exec_argv]
.cpl:
    cmp     byte [r8], 0
    je      .cnf
    lea     rdi, [path_buf]
    mov     rcx, 0
.ccp:
    movzx   eax, byte [r8]
    cmp     al, ':'
    je      .cps
    test    al, al
    jz      .cps
    mov     [rdi+rcx], al
    inc     rcx
    inc     r8
    cmp     rcx, 4000
    jge     .cps
    jmp     .ccp
.cps:
    cmp     byte [r8], ':'
    jne     .cns
    inc     r8
.cns:
    mov     byte [rdi+rcx], '/'
    inc     rcx
    push    r8
    mov     rsi, r9
.ccm:
    movzx   eax, byte [rsi]
    test    al, al
    jz      .ccd
    mov     [rdi+rcx], al
    inc     rcx
    inc     rsi
    cmp     rcx, 4090
    jge     .ccd
    jmp     .ccm
.ccd:
    mov     byte [rdi+rcx], 0
    pop     r8
    lea     rdi, [path_buf]
    lea     rsi, [exec_argv]
    mov     rdx, rbp
    mov     eax, SYS_EXECVE
    syscall
    jmp     .cpl
.cnf:
    mov     edi, STDERR
    mov     rsi, str_err_p
    mov     edx, str_err_p_len
    call    _write
    mov     rdi, [exec_argv]
    call    _strlen
    mov     rdx, rax
    mov     rsi, [exec_argv]
    mov     edi, STDERR
    call    _write
    mov     edi, STDERR
    mov     rsi, str_enoent
    mov     edx, str_enoent_len
    call    _write
    mov     edi, 127
    mov     eax, SYS_EXIT
    syscall
.cefail:
    mov     edi, STDERR
    mov     rsi, str_err_p
    mov     edx, str_err_p_len
    call    _write
    mov     rdi, [exec_argv]
    call    _strlen
    mov     rdx, rax
    mov     rsi, [exec_argv]
    mov     edi, STDERR
    call    _write
    mov     edi, STDERR
    mov     rsi, str_eperm
    mov     edx, str_eperm_len
    call    _write
    mov     edi, 126
    mov     eax, SYS_EXIT
    syscall

.forkfail:
    mov     edi, STDERR
    mov     rsi, str_forkf
    mov     edx, str_forkf_len
    call    _write
    mov     edi, 125
    mov     eax, SYS_EXIT
    syscall

.sh:
    mov     edi, STDOUT
    mov     rsi, str_help_t
    mov     edx, str_help_t_len
    call    _write
    xor     edi, edi
    mov     eax, SYS_EXIT
    syscall

.sv:
    mov     edi, STDOUT
    mov     rsi, str_ver_t
    mov     edx, str_ver_t_len
    call    _write
    xor     edi, edi
    mov     eax, SYS_EXIT
    syscall

.missing:
    mov     edi, STDERR
    mov     rsi, str_miss
    mov     edx, str_miss_len
    call    _write
    mov     edi, STDERR
    mov     rsi, str_try_t
    mov     edx, str_try_t_len
    call    _write
    mov     edi, 125
    mov     eax, SYS_EXIT
    syscall

.inv:
    mov     edi, STDERR
    mov     rsi, str_inv_pre
    mov     edx, str_inv_pre_len
    call    _write
    mov     rdi, [r15+rbx*8]
    call    _strlen
    mov     rdx, rax
    mov     rsi, [r15+rbx*8]
    mov     edi, STDERR
    call    _write
    mov     edi, STDERR
    mov     rsi, str_inv_post
    mov     edx, str_inv_post_len
    call    _write
    mov     edi, STDERR
    mov     rsi, str_try_t
    mov     edx, str_try_t_len
    call    _write
    mov     edi, 125
    mov     eax, SYS_EXIT
    syscall

; @@DATA_START@@
str_help_t:
    db "Usage: timeout [OPTION] DURATION COMMAND [ARG]...", 10
    db "  or:  timeout [OPTION]", 10
    db "Start COMMAND, and kill it if still running after DURATION.", 10, 10
    db "      --foreground   don't create a separate background process group", 10
    db "  -k, --kill-after=DURATION", 10
    db "                     also send a KILL signal if COMMAND is still running", 10
    db "  -s, --signal=SIGNAL", 10
    db "                     specify the signal to be sent on timeout", 10
    db "      --help        display this help and exit", 10
    db "      --version     output version information and exit", 10, 10
    db "GNU coreutils online help: <https://www.gnu.org/software/coreutils/>", 10
    db "Full documentation <https://www.gnu.org/software/coreutils/timeout>", 10
    db "or available locally via: info '(coreutils) timeout invocation'", 10
str_help_t_len equ $ - str_help_t

str_ver_t:
    db "timeout (GNU coreutils) 9.7", 10
    db "Packaged by Debian (9.7-3)", 10
    db "Copyright (C) 2025 Free Software Foundation, Inc.", 10
    db "License GPLv3+: GNU GPL version 3 or later <https://gnu.org/licenses/gpl.html>.", 10
    db "This is free software: you are free to change and redistribute it.", 10
    db "There is NO WARRANTY, to the extent permitted by law.", 10, 10
    db "Written by Padraig Brady.", 10
str_ver_t_len equ $ - str_ver_t

str_try_t:
    db "Try 'timeout --help' for more information.", 10
str_try_t_len equ $ - str_try_t

str_miss:
    db "timeout: missing operand", 10
str_miss_len equ $ - str_miss

str_err_p:
    db "timeout: ", 0
str_err_p_len equ $ - str_err_p - 1

str_enoent:
    db ": No such file or directory", 10
str_enoent_len equ $ - str_enoent

str_eperm:
    db ": Permission denied", 10
str_eperm_len equ $ - str_eperm

str_forkf:
    db "timeout: fork: Cannot allocate memory", 10
str_forkf_len equ $ - str_forkf

str_inv_pre:
    db "timeout: unrecognized option '", 0
str_inv_pre_len equ $ - str_inv_pre - 1

str_inv_post:
    db "'", 10, 0
str_inv_post_len equ $ - str_inv_post - 1
; @@DATA_END@@

s_help:
    db "--help", 0
s_version:
    db "--version", 0
s_foreground:
    db "--foreground", 0
s_signal_eq:
    db "--signal=", 0
s_kill_eq:
    db "--kill-after=", 0
s_TERM:
    db "TERM", 0
s_KILL:
    db "KILL", 0
s_INT:
    db "INT", 0
s_HUP:
    db "HUP", 0

file_size equ $ - $$

exec_argv: times 258*8 db 0
path_buf: times 4096 db 0
sigact: times 152 db 0
sigact_old: times 152 db 0

mem_size equ $ - $$
