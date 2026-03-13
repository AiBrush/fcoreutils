; ============================================================
; fenv_unified.asm — GNU-compatible 'env' command
; Builds with: nasm -f bin fenv_unified.asm -o fenv
;
; env: Run a program in a modified environment.
;
; Register allocation:
;   r14d = argc, r15 = argv
;   r12  = envp base pointer
;   ebx  = flags (bit 0 = -i/--ignore-environment)
;   r13  = current arg index
; ============================================================

BITS 64
ORG 0x400000

%define SYS_READ        0
%define SYS_WRITE       1
%define SYS_OPEN        2
%define SYS_CLOSE       3
%define SYS_EXECVE     59
%define SYS_EXIT       60

%define STDOUT          1
%define STDERR          2

%define BUF_SIZE    65536
%define MAX_ENV      1024    ; max env vars we can track

; --- ELF Header (64 bytes) ---
ehdr:
    db 0x7F, 'E','L','F'
    db 2, 1, 1, 0
    dq 0
    dw 2, 0x3E
    dd 1
    dq _start
    dq phdr - $$
    dq 0
    dd 0
    dw ehdr_size, phdr_size, 2, 64, 0, 0
ehdr_size equ $ - ehdr

; --- Program Headers ---
phdr:
    ; PT_LOAD
    dd 1, 7
    dq 0, $$, $$, file_size, file_size + bss_size, 0x200000
phdr_size equ $ - phdr

    ; PT_GNU_STACK (NX)
    dd 0x6474e551, 6
    dq 0, 0, 0, 0, 0, 0x10

; ============================================================
; Code
; ============================================================
_start:
    ; Save argc/argv
    mov     r14d, [rsp]         ; argc
    lea     r15, [rsp + 8]      ; argv

    ; Compute envp: skip past argv[] and its NULL terminator
    mov     eax, r14d
    inc     eax
    lea     r12, [r15 + rax*8]  ; r12 = envp

    ; Initialize flags
    xor     ebx, ebx            ; flags: bit 0 = -i
    mov     r13d, 1             ; arg index (skip argv[0])

    ; -- Copy envp pointers into our env_ptrs array --
    ; Count envp entries
    xor     ecx, ecx
.count_env:
    cmp     qword [r12 + rcx*8], 0
    je      .count_env_done
    inc     ecx
    jmp     .count_env
.count_env_done:
    mov     [env_count], ecx
    ; Copy all pointers
    xor     edx, edx
.copy_env:
    cmp     edx, ecx
    jge     .copy_env_done
    mov     rax, [r12 + rdx*8]
    mov     [env_ptrs + rdx*8], rax
    inc     edx
    jmp     .copy_env
.copy_env_done:
    mov     qword [env_ptrs + rdx*8], 0  ; NULL terminate

    ; Parse options
.parse_opts:
    cmp     r13d, r14d
    jge     .no_command
    mov     rdi, [r15 + r13*8]
    cmp     byte [rdi], '-'
    jne     .check_assignment     ; not an option, could be VAR=VALUE or command
    cmp     byte [rdi + 1], 0
    je      .check_assignment     ; bare "-" is not an option

    ; Check for --
    cmp     byte [rdi + 1], '-'
    jne     .short_opt

    ; Long option
    cmp     byte [rdi + 2], 0
    je      .double_dash

    ; Check --help
    mov     rsi, str_help_flag
    call    _strcmp
    test    eax, eax
    jz      .show_help

    ; Check --version
    mov     rdi, [r15 + r13*8]
    mov     rsi, str_version_flag
    call    _strcmp
    test    eax, eax
    jz      .show_version

    ; Check --ignore-environment
    mov     rdi, [r15 + r13*8]
    mov     rsi, str_ignore_env_flag
    call    _strcmp
    test    eax, eax
    jz      .set_ignore_env

    ; Check --unset=VAR
    mov     rdi, [r15 + r13*8]
    mov     rsi, str_unset_eq_flag
    mov     ecx, 8              ; length of "--unset="
    call    _strncmp
    test    eax, eax
    jz      .unset_eq

    ; Unrecognized long option
    mov     rdi, STDERR
    mov     rsi, str_prefix
    call    _strlen_and_write
    mov     rdi, STDERR
    mov     rsi, str_unrecog
    call    _strlen_and_write
    mov     rdi, [r15 + r13*8]
    push    rdi
    call    _strlen
    mov     rdx, rax
    pop     rsi
    mov     rdi, STDERR
    call    _write
    mov     rdi, STDERR
    mov     rsi, str_sq_nl
    mov     rdx, 2
    call    _write
    mov     rdi, STDERR
    mov     rsi, str_try
    call    _strlen_and_write
    mov     rdi, 125
    jmp     _exit

.short_opt:
    ; Short options: -i, -u, -0
    mov     rdi, [r15 + r13*8]
    inc     rdi                 ; skip '-'
.short_loop:
    movzx   eax, byte [rdi]
    test    al, al
    jz      .next_opt
    cmp     al, 'i'
    je      .set_ignore_env_short
    cmp     al, 'u'
    je      .unset_short
    cmp     al, '0'
    je      .set_null_short
    ; Invalid short option
    push    rdi
    mov     rdi, STDERR
    mov     rsi, str_prefix
    call    _strlen_and_write
    mov     rdi, STDERR
    mov     rsi, str_invalid
    call    _strlen_and_write
    pop     rdi
    mov     rsi, rdi
    mov     rdi, STDERR
    mov     rdx, 1
    call    _write
    mov     rdi, STDERR
    mov     rsi, str_sq_nl
    mov     rdx, 2
    call    _write
    mov     rdi, STDERR
    mov     rsi, str_try
    call    _strlen_and_write
    mov     rdi, 125
    jmp     _exit

.set_ignore_env_short:
    or      bl, 1
    ; Immediately clear env when -i is encountered
    mov     dword [env_count], 0
    mov     qword [env_ptrs], 0
    inc     rdi
    jmp     .short_loop

.set_null_short:
    or      bl, 2               ; bit 1 = null terminator
    inc     rdi
    jmp     .short_loop

.unset_short:
    ; -u requires next argument as var name
    inc     rdi
    ; If there are more chars in this arg, they are the var name
    cmp     byte [rdi], 0
    jne     .do_unset_inline
    ; Otherwise, next argv is the var name
    inc     r13d
    cmp     r13d, r14d
    jge     .missing_arg_u
    mov     rdi, [r15 + r13*8]
.do_unset_inline:
    push    rdi
    call    _unset_var
    pop     rdi
    inc     r13d
    jmp     .parse_opts

.missing_arg_u:
    mov     rdi, STDERR
    mov     rsi, str_prefix
    call    _strlen_and_write
    mov     rdi, STDERR
    mov     rsi, str_missing_u
    call    _strlen_and_write
    mov     rdi, 125
    jmp     _exit

.set_ignore_env:
    or      bl, 1
    ; Immediately clear env when --ignore-environment is encountered
    mov     dword [env_count], 0
    mov     qword [env_ptrs], 0
    jmp     .next_opt

.unset_eq:
    ; --unset=VAR: var name starts at offset 8 of current arg
    mov     rdi, [r15 + r13*8]
    add     rdi, 8
    call    _unset_var
    jmp     .next_opt

.double_dash:
    inc     r13d
    jmp     .done_opts

.next_opt:
    inc     r13d
    jmp     .parse_opts

.check_assignment:
    ; Check if current arg contains '=' (VAR=VALUE)
    mov     rdi, [r15 + r13*8]
    call    _has_equals
    test    eax, eax
    jz      .done_opts          ; no '=' means it's a command

    ; It's a VAR=VALUE assignment — add/replace in env
    mov     rdi, [r15 + r13*8]
    call    _set_env_var
    inc     r13d
    jmp     .parse_opts

.done_opts:
    ; -i flag already cleared env during option parsing (before assignments)
    ; No need to clear again here

    ; Check if there's a command to run
    cmp     r13d, r14d
    jge     .no_command

    ; --- Execute command ---
    ; argv[r13d] is the command, rest are args
    ; Build new argv: command + remaining args + NULL
    mov     rdi, [r15 + r13*8]  ; command path

    ; Build argv array on stack area (env_argv)
    xor     ecx, ecx            ; index into env_argv
    mov     eax, r13d           ; start from current arg
.build_argv:
    cmp     eax, r14d
    jge     .argv_done
    mov     rdx, [r15 + rax*8]
    mov     [env_argv + rcx*8], rdx
    inc     ecx
    inc     eax
    jmp     .build_argv
.argv_done:
    mov     qword [env_argv + rcx*8], 0  ; NULL terminate

    ; execve(command, argv, envp)
    mov     rdi, [r15 + r13*8]  ; command
    mov     rsi, env_argv       ; argv
    mov     rdx, env_ptrs       ; envp
    mov     eax, SYS_EXECVE
    syscall

    ; If execve returns, it failed
    ; Check errno
    neg     rax                 ; make positive
    cmp     rax, 2              ; ENOENT
    je      .exec_not_found
    cmp     rax, 13             ; EACCES
    je      .exec_no_permission

    ; Generic exec error
    mov     rdi, STDERR
    mov     rsi, str_prefix
    call    _strlen_and_write
    mov     rdi, [r15 + r13*8]
    push    rdi
    call    _strlen
    mov     rdx, rax
    pop     rsi
    mov     rdi, STDERR
    call    _write
    mov     rdi, STDERR
    mov     rsi, str_exec_err
    call    _strlen_and_write
    mov     rdi, 126
    jmp     _exit

.exec_not_found:
    mov     rdi, STDERR
    mov     rsi, str_prefix
    call    _strlen_and_write
    mov     rdi, [r15 + r13*8]
    push    rdi
    call    _strlen
    mov     rdx, rax
    pop     rsi
    mov     rdi, STDERR
    call    _write
    mov     rdi, STDERR
    mov     rsi, str_no_file
    call    _strlen_and_write
    mov     rdi, 127
    jmp     _exit

.exec_no_permission:
    mov     rdi, STDERR
    mov     rsi, str_prefix
    call    _strlen_and_write
    mov     rdi, [r15 + r13*8]
    push    rdi
    call    _strlen
    mov     rdx, rax
    pop     rsi
    mov     rdi, STDERR
    call    _write
    mov     rdi, STDERR
    mov     rsi, str_perm_denied
    call    _strlen_and_write
    mov     rdi, 126
    jmp     _exit

.no_command:
    ; No command: print environment
    ; -i flag already cleared env during parsing

    xor     r13d, r13d          ; env index
.print_env_loop:
    mov     rdi, [env_ptrs + r13*8]
    test    rdi, rdi
    jz      .print_env_done
    push    rdi
    call    _strlen
    pop     rdi
    mov     rdx, rax
    mov     rsi, rdi
    mov     rdi, STDOUT
    test    edx, edx
    jz      .print_env_term
    call    _write
.print_env_term:
    test    bl, 2
    jnz     .print_env_nul
    mov     rdi, STDOUT
    mov     rsi, str_newline
    mov     rdx, 1
    call    _write
    jmp     .print_env_next
.print_env_nul:
    mov     rdi, STDOUT
    mov     rsi, str_nul
    mov     rdx, 1
    call    _write
.print_env_next:
    inc     r13d
    jmp     .print_env_loop
.print_env_done:
    xor     edi, edi
    jmp     _exit

.show_help:
    mov     rdi, STDOUT
    mov     rsi, str_help
    mov     rdx, str_help_len
    call    _write
    xor     edi, edi
    jmp     _exit

.show_version:
    mov     rdi, STDOUT
    mov     rsi, str_version
    mov     rdx, str_version_len
    call    _write
    xor     edi, edi
    jmp     _exit

; ============================================================
; _unset_var: remove VAR from env_ptrs
; Input: rdi = var name (NUL-terminated)
; ============================================================
_unset_var:
    push    rbx
    push    r12
    push    r13
    mov     r12, rdi            ; save var name
    ; Get length of var name
    call    _strlen
    mov     r13d, eax           ; r13d = name length

    xor     ecx, ecx            ; index
.uv_loop:
    mov     rsi, [env_ptrs + rcx*8]
    test    rsi, rsi
    jz      .uv_done
    ; Check if env entry starts with varname=
    xor     edx, edx
.uv_cmp:
    cmp     edx, r13d
    jge     .uv_check_eq
    movzx   eax, byte [r12 + rdx]
    movzx   ebx, byte [rsi + rdx]
    cmp     al, bl
    jne     .uv_next
    inc     edx
    jmp     .uv_cmp
.uv_check_eq:
    cmp     byte [rsi + rdx], '='
    jne     .uv_next
    ; Found! Remove by shifting rest down
    jmp     .uv_remove
.uv_next:
    inc     ecx
    jmp     .uv_loop
.uv_remove:
    mov     rax, [env_ptrs + rcx*8 + 8]
    mov     [env_ptrs + rcx*8], rax
    test    rax, rax
    jz      .uv_removed
    inc     ecx
    jmp     .uv_remove
.uv_removed:
    dec     dword [env_count]
.uv_done:
    pop     r13
    pop     r12
    pop     rbx
    ret

; ============================================================
; _set_env_var: add or replace VAR=VALUE in env_ptrs
; Input: rdi = "VAR=VALUE" string pointer
; ============================================================
_set_env_var:
    push    rbx
    push    r12
    push    r13
    mov     r12, rdi            ; save full string

    ; Find length of var name (up to '=')
    xor     ecx, ecx
.sev_find_eq:
    movzx   eax, byte [rdi + rcx]
    test    al, al
    jz      .sev_append         ; no '=' found, shouldn't happen
    cmp     al, '='
    je      .sev_got_len
    inc     ecx
    jmp     .sev_find_eq
.sev_got_len:
    mov     r13d, ecx           ; r13d = name length

    ; Search for existing entry with same var name
    xor     ecx, ecx
.sev_search:
    mov     rsi, [env_ptrs + rcx*8]
    test    rsi, rsi
    jz      .sev_append
    ; Compare first r13d bytes + check for '='
    xor     edx, edx
.sev_cmp:
    cmp     edx, r13d
    jge     .sev_check_eq
    movzx   eax, byte [r12 + rdx]
    movzx   ebx, byte [rsi + rdx]
    cmp     al, bl
    jne     .sev_next
    inc     edx
    jmp     .sev_cmp
.sev_check_eq:
    cmp     byte [rsi + rdx], '='
    jne     .sev_next
    ; Found existing entry, replace it
    mov     [env_ptrs + rcx*8], r12
    jmp     .sev_done
.sev_next:
    inc     ecx
    jmp     .sev_search

.sev_append:
    ; Add new entry at end
    mov     ecx, [env_count]
    cmp     ecx, MAX_ENV - 1
    jge     .sev_done           ; env full, silently ignore
    mov     [env_ptrs + rcx*8], r12
    inc     ecx
    mov     [env_count], ecx
    mov     qword [env_ptrs + rcx*8], 0  ; NULL terminate
.sev_done:
    pop     r13
    pop     r12
    pop     rbx
    ret

; ============================================================
; _has_equals: check if string contains '='
; Input: rdi = string
; Returns: eax = 1 if found, 0 if not
; ============================================================
_has_equals:
    xor     ecx, ecx
.he_loop:
    movzx   eax, byte [rdi + rcx]
    test    al, al
    jz      .he_no
    cmp     al, '='
    je      .he_yes
    inc     ecx
    jmp     .he_loop
.he_yes:
    mov     eax, 1
    ret
.he_no:
    xor     eax, eax
    ret

; ============================================================
; Utility functions
; ============================================================
_write:
    mov     eax, SYS_WRITE
    syscall
    cmp     rax, -4
    je      _write
    ret

_exit:
    mov     eax, SYS_EXIT
    syscall

_strlen:
    xor     eax, eax
.sl_loop:
    cmp     byte [rdi + rax], 0
    je      .sl_done
    inc     eax
    jmp     .sl_loop
.sl_done:
    ret

_strcmp:
    xor     r8d, r8d
.se_loop:
    movzx   eax, byte [rdi + r8]
    movzx   edx, byte [rsi + r8]
    cmp     al, dl
    jne     .se_ne
    test    al, al
    jz      .se_eq
    inc     r8d
    jmp     .se_loop
.se_eq:
    xor     eax, eax
    ret
.se_ne:
    sub     eax, edx
    ret

; _strncmp: compare first ecx bytes
; Input: rdi = s1, rsi = s2, ecx = n
; Returns: eax = 0 if equal for first n bytes
_strncmp:
    xor     r8d, r8d
.sn_loop:
    cmp     r8d, ecx
    jge     .sn_eq
    movzx   eax, byte [rdi + r8]
    movzx   edx, byte [rsi + r8]
    cmp     al, dl
    jne     .sn_ne
    inc     r8d
    jmp     .sn_loop
.sn_eq:
    xor     eax, eax
    ret
.sn_ne:
    sub     eax, edx
    ret

_strlen_and_write:
    push    rdi
    mov     rdi, rsi
    push    rsi
    call    _strlen
    mov     rdx, rax
    pop     rsi
    pop     rdi
    call    _write
    ret

; ============================================================
; Data
; ============================================================
; @@DATA_START@@
str_help:
    db "Usage: env [OPTION]... [-] [NAME=VALUE]... [COMMAND [ARG]...]", 10
    db "Set each NAME to VALUE in the environment and run COMMAND.", 10, 10
    db "Mandatory arguments to long options are mandatory for short options too.", 10
    db "  -i, --ignore-environment  start with an empty environment", 10
    db "  -0, --null           end each output line with NUL, not newline", 10
    db "  -u, --unset=NAME     remove variable from the environment", 10
    db "      --help        display this help and exit", 10
    db "      --version     output version information and exit", 10, 10
    db "A mere - implies -i.  If no COMMAND, print the resulting environment.", 10, 10
    db "GNU coreutils online help: <https://www.gnu.org/software/coreutils/>", 10
    db "Full documentation <https://www.gnu.org/software/coreutils/env>", 10
    db "or available locally via: info '(coreutils) env invocation'", 10
str_help_len equ $ - str_help

str_version:
    db "env (GNU coreutils) 9.7", 10
    db "Copyright (C) 2025 Free Software Foundation, Inc.", 10
    db "License GPLv3+: GNU GPL version 3 or later <https://gnu.org/licenses/gpl.html>.", 10
    db "This is free software: you are free to change and redistribute it.", 10
    db "There is NO WARRANTY, to the extent permitted by law.", 10, 10
    db "Written by Richard Mlynarik and David MacKenzie.", 10
str_version_len equ $ - str_version

str_prefix:         db "env: ", 0
str_unrecog:        db "unrecognized option '", 0
str_invalid:        db "invalid option -- '", 0
str_sq_nl:          db "'", 10
str_try:            db "Try 'env --help' for more information.", 10, 0
str_missing_u:      db "option requires an argument -- 'u'", 10, "Try 'env --help' for more information.", 10, 0
str_exec_err:       db ": No such file or directory", 10, 0
str_no_file:        db ": No such file or directory", 10, 0
str_perm_denied:    db ": Permission denied", 10, 0
; @@DATA_END@@

str_newline:        db 10
str_nul:            db 0
str_help_flag:      db "--help", 0
str_version_flag:   db "--version", 0
str_ignore_env_flag: db "--ignore-environment", 0
str_unset_eq_flag:  db "--unset=", 0

file_size equ $ - $$

; BSS section
env_ptrs   equ $$ + file_size           ; MAX_ENV * 8 bytes for pointers
env_count  equ env_ptrs + MAX_ENV * 8   ; 4 bytes for count
env_argv   equ env_count + 8            ; MAX_ENV * 8 bytes for argv
bss_size   equ MAX_ENV * 8 + 8 + MAX_ENV * 8
