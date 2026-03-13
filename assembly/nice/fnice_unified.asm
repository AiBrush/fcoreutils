; ============================================================
; fnice_unified.asm — AUTO-GENERATED unified file
; nice (GNU coreutils compatible) — x86_64 Linux
; Build: nasm -f bin fnice_unified.asm -o fnice_release
; ============================================================
BITS 64
ORG 0x400000

; === ELF Header (64 bytes) ===
ehdr:
    db 0x7f, 'E','L','F'       ; magic
    db 2                        ; 64-bit
    db 1                        ; little endian
    db 1                        ; ELF version
    db 0                        ; OS/ABI: System V
    dq 0                        ; padding
    dw 2                        ; ET_EXEC
    dw 0x3e                     ; x86_64
    dd 1                        ; ELF version
    dq _start                   ; entry point
    dq phdr - $$                ; program header offset
    dq 0                        ; section header offset (none)
    dd 0                        ; flags
    dw ehdr_size                ; ELF header size
    dw phdr_size                ; program header entry size
    dw 2                        ; 2 program headers
    dw 64                       ; section header entry size
    dw 0                        ; section header count
    dw 0                        ; section name index
ehdr_size equ $ - ehdr

; === Program Header 1: PT_LOAD (code + data) ===
phdr:
    dd 1                        ; PT_LOAD
    dd 7                        ; PF_R | PF_W | PF_X
    dq 0                        ; offset in file
    dq $$                       ; virtual address
    dq $$                       ; physical address
    dq file_size                ; file size
    dq mem_size                 ; memory size (includes BSS)
    dq 0x200000                 ; alignment
phdr_size equ $ - phdr

; === Program Header 2: PT_GNU_STACK (NX stack) ===
    dd 0x6474e551               ; PT_GNU_STACK
    dd 6                        ; PF_R | PF_W (no PF_X)
    dq 0
    dq 0
    dq 0
    dq 0
    dq 0
    dq 16                       ; alignment

; ============================================================
; Syscall numbers
; ============================================================
%define SYS_WRITE       1
%define SYS_EXECVE     59
%define SYS_EXIT       60
%define SYS_GETPRIORITY 140
%define SYS_SETPRIORITY 141
%define PRIO_PROCESS    0
%define STDOUT          1
%define STDERR          2

; ============================================================
; Code Section
; ============================================================

_start:
    ; Save stack frame
    mov     r14, [rsp]          ; argc
    lea     r15, [rsp + 8]      ; argv

    ; Default adjustment = 10
    mov     r12, 10             ; adjustment
    mov     rbx, 1              ; current argv index

    ; ── Scan for --help / --version first ──
    cmp     r14, 2
    jl      .parse_options
    mov     rdi, [r15 + 8]      ; argv[1]
    mov     rsi, str_opt_help
    call    _strcmp
    test    eax, eax
    jz      .show_help
    mov     rdi, [r15 + 8]
    mov     rsi, str_opt_version
    call    _strcmp
    test    eax, eax
    jz      .show_version

.parse_options:
    cmp     rbx, r14
    jge     .no_command

    mov     rdi, [r15 + rbx*8]

    ; Check if starts with '-'
    cmp     byte [rdi], '-'
    jne     .exec_command

    ; Check for "--"
    cmp     byte [rdi + 1], '-'
    jne     .check_short_n

    ; Check for "--adjustment="
    mov     rsi, str_opt_adjustment
    push    rdi
    call    _starts_with
    pop     rdi
    test    eax, eax
    jnz     .parse_adjustment_eq

    ; Check for "--adjustment" alone
    mov     rdi, [r15 + rbx*8]
    mov     rsi, str_opt_adj_only
    call    _strcmp
    test    eax, eax
    jz      .parse_adjustment_space

    ; Check for exactly "--"
    mov     rdi, [r15 + rbx*8]
    cmp     byte [rdi + 2], 0
    je      .end_of_options

    jmp     .invalid_option

.check_short_n:
    cmp     byte [rdi + 1], 'n'
    jne     .check_numeric_opt
    cmp     byte [rdi + 2], 0
    jne     .check_n_attached

    ; "-n N"
    inc     rbx
    cmp     rbx, r14
    jge     .missing_adjustment
    mov     rdi, [r15 + rbx*8]
    call    _parse_int
    test    ecx, ecx
    jnz     .invalid_adjustment
    mov     r12, rax
    inc     rbx
    jmp     .parse_options

.check_n_attached:
    ; "-nN"
    lea     rdi, [rdi + 2]
    call    _parse_int
    test    ecx, ecx
    jnz     .invalid_adjustment
    mov     r12, rax
    inc     rbx
    jmp     .parse_options

.check_numeric_opt:
    ; Check for "-NUMBER"
    movzx   eax, byte [rdi + 1]
    cmp     al, '0'
    jb      .invalid_option
    cmp     al, '9'
    ja      .invalid_option
    lea     rdi, [rdi + 1]
    call    _parse_int
    test    ecx, ecx
    jnz     .invalid_adjustment
    mov     r12, rax
    inc     rbx
    jmp     .parse_options

.parse_adjustment_eq:
    mov     rdi, [r15 + rbx*8]
.find_eq:
    cmp     byte [rdi], '='
    je      .found_eq
    cmp     byte [rdi], 0
    je      .invalid_adjustment
    inc     rdi
    jmp     .find_eq
.found_eq:
    inc     rdi
    cmp     byte [rdi], 0
    je      .invalid_adjustment
    call    _parse_int
    test    ecx, ecx
    jnz     .invalid_adjustment
    mov     r12, rax
    inc     rbx
    jmp     .parse_options

.parse_adjustment_space:
    inc     rbx
    cmp     rbx, r14
    jge     .missing_adjustment
    mov     rdi, [r15 + rbx*8]
    call    _parse_int
    test    ecx, ecx
    jnz     .invalid_adjustment
    mov     r12, rax
    inc     rbx
    jmp     .parse_options

.end_of_options:
    inc     rbx
    jmp     .exec_command

.no_command:
    ; No command — print current niceness
    mov     eax, SYS_GETPRIORITY
    xor     edi, edi
    xor     esi, esi
    syscall
    sub     rax, 20
    mov     rdi, rax
    call    _int_to_str
    mov     edi, STDOUT
    call    _write
    mov     edi, STDOUT
    mov     rsi, str_newline
    mov     edx, 1
    call    _write
    xor     edi, edi
    mov     eax, SYS_EXIT
    syscall

.exec_command:
    cmp     rbx, r14
    jge     .no_command

    ; Set priority
    push    rbx
    mov     eax, SYS_GETPRIORITY
    xor     edi, edi
    xor     esi, esi
    syscall
    sub     rax, 20
    add     rax, r12
    cmp     rax, -20
    jge     .not_too_low
    mov     rax, -20
.not_too_low:
    cmp     rax, 19
    jle     .not_too_high
    mov     rax, 19
.not_too_high:
    mov     rdx, rax
    mov     eax, SYS_SETPRIORITY
    xor     edi, edi
    xor     esi, esi
    syscall
    pop     rbx

    ; Build argv in BSS
    mov     rcx, 0
.build_argv:
    cmp     rbx, r14
    jge     .argv_done
    mov     rax, [r15 + rbx*8]
    mov     [exec_argv + rcx*8], rax
    inc     rcx
    inc     rbx
    cmp     rcx, 256
    jge     .argv_done
    jmp     .build_argv
.argv_done:
    mov     qword [exec_argv + rcx*8], 0

    ; Get envp
    mov     rax, [rsp]
    lea     rdx, [rsp + 8]
    lea     rdx, [rdx + rax*8 + 8]
    mov     r13, rdx

    ; Try direct execve
    mov     rdi, [exec_argv]
    lea     rsi, [exec_argv]
    mov     rdx, r13
    mov     eax, SYS_EXECVE
    syscall

    cmp     rax, -2
    je      .try_path
    cmp     rax, -13
    je      .try_path
    cmp     rax, -20
    je      .try_path
    jmp     .exec_failed

.try_path:
    mov     rdi, r13
    call    _find_path_env
    test    rax, rax
    jz      .exec_not_found
    mov     r8, rax
    mov     r9, [exec_argv]

.path_loop:
    cmp     byte [r8], 0
    je      .exec_not_found

    lea     rdi, [path_buf]
    mov     rcx, 0
.copy_path_component:
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
    jmp     .copy_path_component
.path_sep:
    cmp     byte [r8], ':'
    jne     .no_skip_colon
    inc     r8
.no_skip_colon:
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
    mov     edi, STDERR
    mov     rsi, str_prog_prefix
    mov     edx, str_prog_prefix_len
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

.exec_failed:
    mov     edi, STDERR
    mov     rsi, str_prog_prefix
    mov     edx, str_prog_prefix_len
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

.show_help:
    mov     edi, STDOUT
    mov     rsi, str_help
    mov     edx, str_help_len
    call    _write
    xor     edi, edi
    mov     eax, SYS_EXIT
    syscall

.show_version:
    mov     edi, STDOUT
    mov     rsi, str_version
    mov     edx, str_version_len
    call    _write
    xor     edi, edi
    mov     eax, SYS_EXIT
    syscall

.invalid_option:
    mov     edi, STDERR
    mov     rsi, str_inv_opt_pre
    mov     edx, str_inv_opt_pre_len
    call    _write
    mov     rdi, [r15 + rbx*8]
    call    _strlen
    mov     rdx, rax
    mov     rsi, [r15 + rbx*8]
    mov     edi, STDERR
    call    _write
    mov     edi, STDERR
    mov     rsi, str_inv_opt_post
    mov     edx, str_inv_opt_post_len
    call    _write
    mov     edi, STDERR
    mov     rsi, str_try
    mov     edx, str_try_len
    call    _write
    mov     edi, 125
    mov     eax, SYS_EXIT
    syscall

.missing_adjustment:
    mov     edi, STDERR
    mov     rsi, str_missing_adj
    mov     edx, str_missing_adj_len
    call    _write
    mov     edi, STDERR
    mov     rsi, str_try
    mov     edx, str_try_len
    call    _write
    mov     edi, 125
    mov     eax, SYS_EXIT
    syscall

.invalid_adjustment:
    mov     edi, STDERR
    mov     rsi, str_inv_adj_pre
    mov     edx, str_inv_adj_pre_len
    call    _write
    mov     rdi, [r15 + rbx*8]
    call    _strlen
    mov     rdx, rax
    mov     rsi, [r15 + rbx*8]
    mov     edi, STDERR
    call    _write
    mov     edi, STDERR
    mov     rsi, str_inv_adj_post
    mov     edx, str_inv_adj_post_len
    call    _write
    mov     edi, 125
    mov     eax, SYS_EXIT
    syscall

; ============================================================
; Utility functions
; ============================================================

_write:
    mov     eax, SYS_WRITE
    syscall
    cmp     rax, -4
    je      _write
    ret

_strlen:
    xor     eax, eax
.loop:
    cmp     byte [rdi + rax], 0
    je      .done
    inc     rax
    jmp     .loop
.done:
    ret

_strcmp:
.loop:
    movzx   eax, byte [rdi]
    movzx   ecx, byte [rsi]
    cmp     al, cl
    jne     .diff
    test    al, al
    jz      .equal
    inc     rdi
    inc     rsi
    jmp     .loop
.equal:
    xor     eax, eax
    ret
.diff:
    sub     eax, ecx
    ret

_starts_with:
.loop:
    movzx   eax, byte [rsi]
    test    al, al
    jz      .match
    movzx   ecx, byte [rdi]
    cmp     al, cl
    jne     .no_match
    inc     rdi
    inc     rsi
    jmp     .loop
.match:
    mov     eax, 1
    ret
.no_match:
    xor     eax, eax
    ret

_parse_int:
    xor     eax, eax
    xor     ecx, ecx
    xor     r10d, r10d
    movzx   edx, byte [rdi]
    cmp     dl, '-'
    jne     .pi_check_plus
    mov     r10d, 1
    inc     rdi
    jmp     .pi_digits
.pi_check_plus:
    cmp     dl, '+'
    jne     .pi_digits
    inc     rdi
.pi_digits:
    movzx   edx, byte [rdi]
    test    dl, dl
    jz      .pi_apply_sign
    cmp     dl, '0'
    jb      .pi_error
    cmp     dl, '9'
    ja      .pi_error
    sub     dl, '0'
    imul    rax, 10
    movzx   edx, dl
    add     rax, rdx
    inc     rdi
    jmp     .pi_digits
.pi_apply_sign:
    test    r10d, r10d
    jz      .pi_done
    neg     rax
.pi_done:
    ret
.pi_error:
    mov     ecx, 1
    ret

_int_to_str:
    lea     rsi, [num_buf + 20]
    mov     byte [rsi], 0
    mov     rax, rdi
    xor     ecx, ecx
    test    rax, rax
    jns     .its_positive
    mov     ecx, 1
    neg     rax
.its_positive:
    mov     rbx, 10
.its_loop:
    xor     edx, edx
    div     rbx
    add     dl, '0'
    dec     rsi
    mov     [rsi], dl
    test    rax, rax
    jnz     .its_loop
    test    ecx, ecx
    jz      .its_done
    dec     rsi
    mov     byte [rsi], '-'
.its_done:
    lea     rdx, [num_buf + 20]
    sub     rdx, rsi
    ret

_find_path_env:
.loop:
    mov     rax, [rdi]
    test    rax, rax
    jz      .not_found
    cmp     dword [rax], 0x48544150     ; "PATH"
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
; Data Section
; ============================================================

; @@DATA_START@@
str_help:
    db "Usage: nice [OPTION] [COMMAND [ARG]...]", 10
    db "Run COMMAND with an adjusted niceness, which affects process scheduling.", 10
    db "With no COMMAND, print the current niceness.  Niceness values range from", 10
    db "-20 (most favorable to the process) to 19 (least favorable to the process).", 10
    db 10
    db "Mandatory arguments to long options are mandatory for short options too.", 10
    db "  -n, --adjustment=N   add integer N to the niceness (default 10)", 10
    db "      --help        display this help and exit", 10
    db "      --version     output version information and exit", 10
    db 10
    db "NOTE: your shell may have its own version of nice, which usually supersedes", 10
    db "the version described here.  Please refer to your shell's documentation", 10
    db "for details about the options it supports.", 10
    db 10
    db "GNU coreutils online help: <https://www.gnu.org/software/coreutils/>", 10
    db "Full documentation <https://www.gnu.org/software/coreutils/nice>", 10
    db "or available locally via: info '(coreutils) nice invocation'", 10
str_help_len equ $ - str_help

str_version:
    db "nice (GNU coreutils) 9.7", 10
    db "Packaged by Debian (9.7-3)", 10
    db "Copyright (C) 2025 Free Software Foundation, Inc.", 10
    db "License GPLv3+: GNU GPL version 3 or later <https://gnu.org/licenses/gpl.html>.", 10
    db "This is free software: you are free to change and redistribute it.", 10
    db "There is NO WARRANTY, to the extent permitted by law.", 10
    db 10
    db "Written by David MacKenzie.", 10
str_version_len equ $ - str_version

str_try:
    db "Try 'nice --help' for more information.", 10
str_try_len equ $ - str_try

str_inv_opt_pre:
    db "nice: unrecognized option '", 0
str_inv_opt_pre_len equ $ - str_inv_opt_pre - 1

str_inv_opt_post:
    db "'", 10, 0
str_inv_opt_post_len equ $ - str_inv_opt_post - 1

str_missing_adj:
    db "nice: option requires an argument -- 'n'", 10
str_missing_adj_len equ $ - str_missing_adj

str_inv_adj_pre:
    db "nice: invalid adjustment '", 0
str_inv_adj_pre_len equ $ - str_inv_adj_pre - 1

str_inv_adj_post:
    db "'", 10, 0
str_inv_adj_post_len equ $ - str_inv_adj_post - 1

str_prog_prefix:
    db "nice: ", 0
str_prog_prefix_len equ $ - str_prog_prefix - 1

str_enoent:
    db ": No such file or directory", 10
str_enoent_len equ $ - str_enoent

str_eperm:
    db ": Permission denied", 10
str_eperm_len equ $ - str_eperm
; @@DATA_END@@

str_opt_help:
    db "--help", 0

str_opt_version:
    db "--version", 0

str_opt_adjustment:
    db "--adjustment=", 0

str_opt_adj_only:
    db "--adjustment", 0

str_newline:
    db 10

; ============================================================
; BSS — writable area after file data
; ============================================================
file_size equ $ - $$

exec_argv: times 258*8 db 0
path_buf: times 4096 db 0
num_buf: times 32 db 0

mem_size equ $ - $$
