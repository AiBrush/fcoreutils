; ============================================================
; frmdir_unified.asm — GNU-compatible 'rmdir' command
; Builds with: nasm -f bin frmdir_unified.asm -o frmdir
;
; rmdir: Remove empty directories.
;
; Register allocation:
;   r14d = argc, r15 = argv, ebx = flags, ecx = arg index
;   r13  = dir index during dir loop
;   ebp  = exit code (0 = success, 1 = error)
;
; Flags in ebx:
;   bit 0 = -p/--parents
;   bit 1 = --ignore-fail-on-non-empty
;   bit 2 = -v/--verbose
; ============================================================

BITS 64
ORG 0x400000

%define SYS_WRITE       1
%define SYS_RMDIR       84
%define SYS_EXIT        60
%define SYS_RT_SIGPROCMASK 14

%define STDOUT          1
%define STDERR          2
%define SIG_BLOCK       0
%define SIGPIPE         13

; errno values
%define ENOENT          2
%define EACCES          13
%define EBUSY           16
%define EEXIST          17
%define ENOTDIR         20
%define EINVAL          22
%define ENOTEMPTY       39
%define EPERM           1

; --- ELF Header (64 bytes) ---
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
    dw 64, 56, 2, 64, 0, 0

; --- Program Header: PT_LOAD ---
phdr:
    dd 1, 5
    dq 0, $$, $$, file_size, file_size, 0x200000

; --- Program Header: PT_GNU_STACK (NX) ---
    dd 0x6474e551, 6
    dq 0, 0, 0, 0, 0, 0x10

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
    mov     r14d, [rsp]         ; argc
    lea     r15, [rsp + 8]      ; argv

    ; Initialize flags and exit code
    xor     ebx, ebx            ; flags
    xor     ebp, ebp            ; exit code = 0
    mov     ecx, 1              ; arg index (start after argv[0])

    ; Parse options
.parse_opts:
    cmp     ecx, r14d
    jge     .err_missing_operand
    mov     rdi, [r15 + rcx*8]
    cmp     byte [rdi], '-'
    jne     .done_opts
    cmp     byte [rdi + 1], 0
    je      .done_opts           ; bare "-" is not an option
    cmp     byte [rdi + 1], '-'
    je      .check_long

    ; Short options: -p, -v (can be combined: -pv)
    inc     rdi
.short_loop:
    movzx   eax, byte [rdi]
    test    al, al
    jz      .next_opt
    cmp     al, 'p'
    je      .set_parents
    cmp     al, 'v'
    je      .set_verbose
    ; Invalid short option
    mov     r13, rdi
    mov     rsi, str_prefix
    mov     edx, str_prefix_len
    call    do_write_err
    mov     rsi, str_invalid
    mov     edx, str_invalid_len
    call    do_write_err
    mov     rsi, r13
    mov     edx, 1
    call    do_write_err
    mov     rsi, str_sq_nl
    mov     edx, 2
    call    do_write_err
    mov     rsi, str_try
    mov     edx, str_try_len
    call    do_write_err
    mov     edi, 1
    jmp     do_exit

.set_parents:
    or      bl, 1
    inc     rdi
    jmp     .short_loop

.set_verbose:
    or      bl, 4
    inc     rdi
    jmp     .short_loop

.check_long:
    cmp     byte [rdi + 2], 0
    je      .double_dash
    mov     r13, rdi
    push    rcx
    ; Check --help
    mov     rsi, str_help_flag
    call    str_eq
    test    eax, eax
    jnz     .pop_show_help
    ; Check --version
    mov     rdi, r13
    mov     rsi, str_version_flag
    call    str_eq
    test    eax, eax
    jnz     .pop_show_version
    ; Check --parents
    mov     rdi, r13
    mov     rsi, str_parents_flag
    call    str_eq
    test    eax, eax
    jnz     .pop_set_parents
    ; Check --verbose
    mov     rdi, r13
    mov     rsi, str_verbose_flag
    call    str_eq
    test    eax, eax
    jnz     .pop_set_verbose
    ; Check --ignore-fail-on-non-empty
    mov     rdi, r13
    mov     rsi, str_ignore_flag
    call    str_eq
    test    eax, eax
    jnz     .pop_set_ignore
    ; Unrecognized long option
    mov     rsi, str_prefix
    mov     edx, str_prefix_len
    call    do_write_err
    mov     rsi, str_unrecog
    mov     edx, str_unrecog_len
    call    do_write_err
    mov     rdi, r13
    call    str_len
    mov     edx, eax
    mov     rsi, r13
    call    do_write_err
    mov     rsi, str_sq_nl
    mov     edx, 2
    call    do_write_err
    mov     rsi, str_try
    mov     edx, str_try_len
    call    do_write_err
    pop     rcx
    mov     edi, 1
    jmp     do_exit

.pop_show_help:
    pop     rcx
    jmp     .show_help
.pop_show_version:
    pop     rcx
    jmp     .show_version
.pop_set_parents:
    pop     rcx
    or      bl, 1
    jmp     .next_opt
.pop_set_verbose:
    pop     rcx
    or      bl, 4
    jmp     .next_opt
.pop_set_ignore:
    pop     rcx
    or      bl, 2
    jmp     .next_opt

.double_dash:
    inc     ecx
    jmp     .done_opts

.next_opt:
    inc     ecx
    jmp     .parse_opts

.done_opts:
    ; ecx = index of first directory arg
    cmp     ecx, r14d
    jge     .err_missing_operand

    ; Process directories
    mov     r13d, ecx
.dir_loop:
    cmp     r13d, r14d
    jge     .exit_done
    mov     rdi, [r15 + r13*8]
    call    do_rmdir
    inc     r13d
    jmp     .dir_loop

.exit_done:
    mov     edi, ebp
    jmp     do_exit

.show_help:
    mov     edi, STDOUT
    mov     rsi, str_help
    mov     edx, str_help_len
    call    do_write
    xor     edi, edi
    jmp     do_exit

.show_version:
    mov     edi, STDOUT
    mov     rsi, str_version
    mov     edx, str_version_len
    call    do_write
    xor     edi, edi
    jmp     do_exit

.err_missing_operand:
    mov     rsi, str_prefix
    mov     edx, str_prefix_len
    call    do_write_err
    mov     rsi, str_missing
    mov     edx, str_missing_len
    call    do_write_err
    mov     rsi, str_try
    mov     edx, str_try_len
    call    do_write_err
    mov     edi, 1
    jmp     do_exit

; ============================================================
; do_rmdir: remove one directory (and parents if -p)
; Input: rdi = directory path string pointer
; Uses: ebx = flags, ebp = exit code accumulator
; ============================================================
do_rmdir:
    push    r12
    push    r13
    push    r14
    push    r15
    ; Save flags in a callee-safe place
    mov     r12d, ebx           ; flags
    mov     r15d, ebp           ; exit code

    ; Copy path to stack buffer for manipulation (max 4096 bytes)
    mov     r14, rdi            ; original path pointer
    sub     rsp, 4104           ; 4096 + 8 alignment
    mov     r13, rsp            ; buffer pointer

    ; Copy path to buffer
    call    str_len
    cmp     eax, 4095
    jg      .rd_too_long
    mov     ecx, eax
    inc     ecx                 ; include NUL
    mov     rsi, r14
    mov     rdi, r13
    rep movsb

.rd_do_rmdir:
    ; Verbose output before rmdir
    test    r12d, 4             ; -v flag
    jz      .rd_skip_verbose
    ; Print "rmdir: removing directory, 'PATH'\n"
    mov     rsi, str_verbose_pre
    mov     edx, str_verbose_pre_len
    call    do_write_err
    ; Print path
    mov     rdi, r13
    call    str_len
    mov     edx, eax
    mov     rsi, r13
    call    do_write_err
    ; Print "'\n"
    mov     rsi, str_sq_nl
    mov     edx, 2
    call    do_write_err

.rd_skip_verbose:
    ; Call rmdir syscall
    mov     rax, SYS_RMDIR
    mov     rdi, r13
    syscall

    ; Check result
    test    rax, rax
    jz      .rd_success

    ; Error: rax = -errno
    neg     rax                 ; now eax = errno

    ; If --ignore-fail-on-non-empty and errno is ENOTEMPTY or EEXIST, skip
    test    r12d, 2
    jz      .rd_report_error
    cmp     eax, ENOTEMPTY
    je      .rd_ignored
    cmp     eax, EEXIST
    je      .rd_ignored

.rd_report_error:
    ; Set exit code to 1
    mov     r15d, 1

    ; Print error message: "rmdir: failed to remove 'PATH': ERROR\n"
    push    rax                 ; save errno
    mov     rsi, str_prefix
    mov     edx, str_prefix_len
    call    do_write_err
    mov     rsi, str_failed
    mov     edx, str_failed_len
    call    do_write_err
    ; Print path
    mov     rdi, r13
    call    str_len
    mov     edx, eax
    mov     rsi, r13
    call    do_write_err
    ; Print "': "
    mov     rsi, str_colon_sep
    mov     edx, str_colon_sep_len
    call    do_write_err
    ; Print errno message
    pop     rax
    call    print_errno
    jmp     .rd_done

.rd_ignored:
    ; Silently skip non-empty error
    jmp     .rd_done

.rd_success:
    ; If -p flag, strip last component and try again
    test    r12d, 1
    jz      .rd_done

    ; Strip trailing slashes from path
    mov     rdi, r13
    call    str_len
    test    eax, eax
    jz      .rd_done
    lea     ecx, [eax - 1]
.rd_strip_trailing:
    cmp     ecx, 0
    jle     .rd_done
    cmp     byte [r13 + rcx], '/'
    jne     .rd_find_slash
    dec     ecx
    jmp     .rd_strip_trailing

.rd_find_slash:
    ; Find the last slash
.rd_find_slash_loop:
    cmp     ecx, 0
    jl      .rd_done            ; no slash found, we're done
    cmp     byte [r13 + rcx], '/'
    je      .rd_found_slash
    dec     ecx
    jmp     .rd_find_slash_loop

.rd_found_slash:
    ; Strip trailing slashes from parent
    cmp     ecx, 0
    jl      .rd_done
.rd_strip_parent_trailing:
    cmp     ecx, 0
    jl      .rd_done
    cmp     byte [r13 + rcx], '/'
    jne     .rd_set_parent
    dec     ecx
    jmp     .rd_strip_parent_trailing

.rd_set_parent:
    ; Terminate path at ecx+1
    inc     ecx
    mov     byte [r13 + rcx], 0

    ; Check if remaining path is empty or "."
    cmp     byte [r13], 0
    je      .rd_done
    cmp     byte [r13], '.'
    jne     .rd_do_rmdir
    cmp     byte [r13 + 1], 0
    je      .rd_done
    jmp     .rd_do_rmdir

.rd_too_long:
    ; Path too long, print error
    mov     r15d, 1
    mov     rsi, str_prefix
    mov     edx, str_prefix_len
    call    do_write_err
    mov     rsi, str_failed
    mov     edx, str_failed_len
    call    do_write_err
    mov     rdi, r14
    call    str_len
    mov     edx, eax
    mov     rsi, r14
    call    do_write_err
    mov     rsi, str_colon_sep
    mov     edx, str_colon_sep_len
    call    do_write_err
    ; Use EINVAL error
    mov     eax, EINVAL
    call    print_errno

.rd_done:
    add     rsp, 4104
    mov     ebp, r15d           ; restore exit code
    mov     ebx, r12d           ; restore flags
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    ret

; ============================================================
; print_errno: print error string for errno value in eax
; Writes to stderr, includes trailing newline
; ============================================================
print_errno:
    cmp     eax, ENOENT
    je      .pe_noent
    cmp     eax, ENOTEMPTY
    je      .pe_notempty
    cmp     eax, ENOTDIR
    je      .pe_notdir
    cmp     eax, EACCES
    je      .pe_acces
    cmp     eax, EPERM
    je      .pe_perm
    cmp     eax, EEXIST
    je      .pe_exist
    cmp     eax, EBUSY
    je      .pe_busy
    cmp     eax, EINVAL
    je      .pe_inval
    ; Default: unknown error
    mov     rsi, str_err_unknown
    mov     edx, str_err_unknown_len
    jmp     do_write_err

.pe_noent:
    mov     rsi, str_err_noent
    mov     edx, str_err_noent_len
    jmp     do_write_err
.pe_notempty:
    mov     rsi, str_err_notempty
    mov     edx, str_err_notempty_len
    jmp     do_write_err
.pe_notdir:
    mov     rsi, str_err_notdir
    mov     edx, str_err_notdir_len
    jmp     do_write_err
.pe_acces:
    mov     rsi, str_err_acces
    mov     edx, str_err_acces_len
    jmp     do_write_err
.pe_perm:
    mov     rsi, str_err_perm
    mov     edx, str_err_perm_len
    jmp     do_write_err
.pe_exist:
    mov     rsi, str_err_exist
    mov     edx, str_err_exist_len
    jmp     do_write_err
.pe_busy:
    mov     rsi, str_err_busy
    mov     edx, str_err_busy_len
    jmp     do_write_err
.pe_inval:
    mov     rsi, str_err_inval
    mov     edx, str_err_inval_len
    jmp     do_write_err

; ============================================================
; Utility functions
; ============================================================
do_write:
    mov     eax, SYS_WRITE
    syscall
    cmp     rax, -4
    je      do_write
    ret

do_write_err:
    mov     edi, STDERR
    jmp     do_write

do_exit:
    mov     eax, SYS_EXIT
    syscall

str_len:
    xor     eax, eax
.sl_loop:
    cmp     byte [rdi + rax], 0
    je      .sl_done
    inc     eax
    jmp     .sl_loop
.sl_done:
    ret

; str_eq: compare two NUL-terminated strings
; rdi = s1, rsi = s2; returns eax: 1=equal, 0=not equal
; Clobbers: r8, eax, edx
str_eq:
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
    mov     eax, 1
    ret
.se_ne:
    xor     eax, eax
    ret

; ============================================================
; Data
; ============================================================
; @@DATA_START@@
str_help:
    db "Usage: rmdir [OPTION]... DIRECTORY...", 10
    db "Remove the DIRECTORY(ies), if they are empty.", 10, 10
    db "      --ignore-fail-on-non-empty", 10
    db "                  ignore each failure that is solely because a directory", 10
    db "                    is non-empty", 10
    db "  -p, --parents   remove DIRECTORY and its ancestors; e.g., 'rmdir -p a/b/c' is", 10
    db "                    similar to 'rmdir a/b/c a/b a'", 10
    db "  -v, --verbose   output a diagnostic for every directory processed", 10
    db "      --help        display this help and exit", 10
    db "      --version     output version information and exit", 10, 10
    db "GNU coreutils online help: <https://www.gnu.org/software/coreutils/>", 10
    db "Full documentation <https://www.gnu.org/software/coreutils/rmdir>", 10
    db "or available locally via: info '(coreutils) rmdir invocation'", 10
str_help_len equ $ - str_help

str_version:
    db "rmdir (GNU coreutils) 9.7", 10
    db "Copyright (C) 2025 Free Software Foundation, Inc.", 10
    db "License GPLv3+: GNU GPL version 3 or later <https://gnu.org/licenses/gpl.html>.", 10
    db "This is free software: you are free to change and redistribute it.", 10
    db "There is NO WARRANTY, to the extent permitted by law.", 10, 10
    db "Written by David MacKenzie.", 10
str_version_len equ $ - str_version

str_prefix:      db "rmdir: "
str_prefix_len   equ $ - str_prefix
str_unrecog:     db "unrecognized option '"
str_unrecog_len  equ $ - str_unrecog
str_invalid:     db "invalid option -- '"
str_invalid_len  equ $ - str_invalid
str_missing:     db "missing operand", 10
str_missing_len  equ $ - str_missing
str_sq_nl:       db "'", 10
str_try:         db "Try 'rmdir --help' for more information.", 10
str_try_len      equ $ - str_try
str_failed:      db "failed to remove '"
str_failed_len   equ $ - str_failed
str_colon_sep:   db "': "
str_colon_sep_len equ $ - str_colon_sep
str_verbose_pre: db "rmdir: removing directory, '"
str_verbose_pre_len equ $ - str_verbose_pre
; @@DATA_END@@

; Error messages (with newline)
str_err_noent:     db "No such file or directory", 10
str_err_noent_len  equ $ - str_err_noent
str_err_notempty:  db "Directory not empty", 10
str_err_notempty_len equ $ - str_err_notempty
str_err_notdir:    db "Not a directory", 10
str_err_notdir_len equ $ - str_err_notdir
str_err_acces:     db "Permission denied", 10
str_err_acces_len  equ $ - str_err_acces
str_err_perm:      db "Operation not permitted", 10
str_err_perm_len   equ $ - str_err_perm
str_err_exist:     db "File exists", 10
str_err_exist_len  equ $ - str_err_exist
str_err_busy:      db "Device or resource busy", 10
str_err_busy_len   equ $ - str_err_busy
str_err_inval:     db "Invalid argument", 10
str_err_inval_len  equ $ - str_err_inval
str_err_unknown:   db "Unknown error", 10
str_err_unknown_len equ $ - str_err_unknown

str_newline:     db 10
str_help_flag:   db "--help", 0
str_version_flag: db "--version", 0
str_parents_flag: db "--parents", 0
str_verbose_flag: db "--verbose", 0
str_ignore_flag: db "--ignore-fail-on-non-empty", 0

file_size equ $ - $$
