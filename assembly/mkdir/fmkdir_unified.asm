; ============================================================
; fmkdir_unified.asm — GNU-compatible 'mkdir' command
; Builds with: nasm -f bin fmkdir_unified.asm -o fmkdir
;
; mkdir: Create directories.
;
; Register allocation:
;   r14d = argc, r15 = argv, ebx = flags, ecx = arg index
;   r13  = dir index during dir loop
;   ebp  = exit code (0 = success, 1 = error)
;   r12d = mode (octal, default 0777 before umask)
;
; Flags in ebx:
;   bit 0 = -p/--parents
;   bit 1 = -v/--verbose
;   bit 2 = -m/--mode (mode set explicitly)
; ============================================================

BITS 64
ORG 0x400000

%define SYS_WRITE       1
%define SYS_MKDIR       83
%define SYS_CHMOD       90
%define SYS_EXIT        60
%define SYS_RT_SIGPROCMASK 14

%define STDOUT          1
%define STDERR          2
%define SIG_BLOCK       0
%define SIGPIPE         13

; errno values
%define EPERM           1
%define ENOENT          2
%define EACCES          13
%define EEXIST          17
%define ENOTDIR         20
%define EINVAL          22
%define ENOSPC          28
%define EROFS           30
%define ELOOP           40
%define ENAMETOOLONG    36
%define ENOMEM          12
%define EFAULT          14

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
    mov     r12d, 0o777         ; default mode
    mov     ecx, 1              ; arg index

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

    ; Short options: -p, -v, -m (can be combined)
    inc     rdi
.short_loop:
    movzx   eax, byte [rdi]
    test    al, al
    jz      .next_opt
    cmp     al, 'p'
    je      .set_parents
    cmp     al, 'v'
    je      .set_verbose
    cmp     al, 'm'
    je      .set_mode_short
    ; Invalid short option
    push    rcx
    push    rdi
    mov     rsi, str_prefix
    mov     edx, str_prefix_len
    call    do_write_err
    mov     rsi, str_invalid
    mov     edx, str_invalid_len
    call    do_write_err
    pop     rdi
    push    rdi
    mov     rsi, rdi
    mov     edx, 1
    call    do_write_err
    mov     rsi, str_sq_nl
    mov     edx, 2
    call    do_write_err
    mov     rsi, str_try
    mov     edx, str_try_len
    call    do_write_err
    pop     rdi
    pop     rcx
    mov     edi, 1
    jmp     do_exit

.set_parents:
    or      bl, 1
    inc     rdi
    jmp     .short_loop

.set_verbose:
    or      bl, 2
    inc     rdi
    jmp     .short_loop

.set_mode_short:
    or      bl, 4
    ; Check if mode follows immediately (e.g., -m755)
    inc     rdi
    cmp     byte [rdi], 0
    jne     .parse_mode_val
    ; Mode is next arg
    inc     ecx
    cmp     ecx, r14d
    jge     .err_missing_mode
    mov     rdi, [r15 + rcx*8]
.parse_mode_val:
    call    parse_octal_mode
    test    eax, eax
    js      .err_invalid_mode
    mov     r12d, eax
    jmp     .next_opt

.check_long:
    cmp     byte [rdi + 2], 0
    je      .double_dash
    push    rcx
    mov     r13, rdi
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
    ; Check --mode= prefix
    mov     rdi, r13
    mov     rsi, str_mode_eq_flag
    call    str_starts_with
    test    eax, eax
    jnz     .pop_set_mode_long_eq
    ; Check --mode (space-separated)
    mov     rdi, r13
    mov     rsi, str_mode_flag
    call    str_eq
    test    eax, eax
    jnz     .pop_set_mode_long
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
    or      bl, 2
    jmp     .next_opt
.pop_set_mode_long_eq:
    ; --mode=VALUE
    pop     rcx
    or      bl, 4
    lea     rdi, [r13 + 7]      ; skip "--mode="
    call    parse_octal_mode
    test    eax, eax
    js      .err_invalid_mode
    mov     r12d, eax
    jmp     .next_opt
.pop_set_mode_long:
    ; --mode VALUE
    pop     rcx
    or      bl, 4
    inc     ecx
    cmp     ecx, r14d
    jge     .err_missing_mode
    mov     rdi, [r15 + rcx*8]
    call    parse_octal_mode
    test    eax, eax
    js      .err_invalid_mode
    mov     r12d, eax
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
    call    do_mkdir
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

.err_missing_mode:
    mov     rsi, str_prefix
    mov     edx, str_prefix_len
    call    do_write_err
    mov     rsi, str_missing_mode
    mov     edx, str_missing_mode_len
    call    do_write_err
    mov     edi, 1
    jmp     do_exit

.err_invalid_mode:
    mov     rsi, str_prefix
    mov     edx, str_prefix_len
    call    do_write_err
    mov     rsi, str_invalid_mode
    mov     edx, str_invalid_mode_len
    call    do_write_err
    mov     rdi, [r15 + rcx*8]
    call    str_len
    mov     edx, eax
    mov     rsi, [r15 + rcx*8]
    call    do_write_err
    mov     rsi, str_sq_nl
    mov     edx, 2
    call    do_write_err
    mov     edi, 1
    jmp     do_exit

; ============================================================
; do_mkdir: create one directory (and parents if -p)
; Input: rdi = directory path string pointer
; Uses: ebx = flags, ebp = exit code, r12d = mode
; ============================================================
do_mkdir:
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbx
    mov     r15, rdi            ; original path pointer

    ; If -p flag, do mkdir_parents
    test    bl, 1
    jnz     .md_parents

    ; Simple mkdir
    mov     eax, SYS_MKDIR
    mov     rdi, r15
    mov     esi, r12d
    syscall

    test    rax, rax
    jz      .md_simple_ok

    ; Error
    neg     rax
    mov     r14d, eax           ; save errno
    mov     ebp, 1              ; set exit code

    ; Print error: "mkdir: cannot create directory 'PATH': ERROR\n"
    mov     rsi, str_prefix
    mov     edx, str_prefix_len
    call    do_write_err
    mov     rsi, str_cannot
    mov     edx, str_cannot_len
    call    do_write_err
    mov     rdi, r15
    call    str_len
    mov     edx, eax
    mov     rsi, r15
    call    do_write_err
    mov     rsi, str_colon_sep
    mov     edx, str_colon_sep_len
    call    do_write_err
    mov     eax, r14d
    call    print_errno
    jmp     .md_done

.md_simple_ok:
    ; If -m flag set and mode != 0777, chmod
    test    bl, 4
    jz      .md_simple_verbose
    mov     eax, SYS_CHMOD
    mov     rdi, r15
    mov     esi, r12d
    syscall

.md_simple_verbose:
    ; Verbose output
    test    bl, 2
    jz      .md_done
    mov     rsi, str_verbose_pre
    mov     edx, str_verbose_pre_len
    call    do_write_err
    mov     rdi, r15
    call    str_len
    mov     edx, eax
    mov     rsi, r15
    call    do_write_err
    mov     rsi, str_sq_nl
    mov     edx, 2
    call    do_write_err
    jmp     .md_done

.md_parents:
    ; mkdir -p: create each path component
    ; Copy path to stack buffer
    mov     rdi, r15
    call    str_len
    cmp     eax, 4095
    jg      .md_too_long
    mov     r14d, eax           ; path length
    sub     rsp, 4104
    mov     r13, rsp            ; buffer pointer

    ; Copy path to buffer
    mov     ecx, r14d
    inc     ecx
    mov     rsi, r15
    mov     rdi, r13
    rep movsb

    ; Walk path and create each component
    xor     ecx, ecx            ; current position
.md_p_loop:
    ; Skip leading slashes
    cmp     ecx, r14d
    jge     .md_p_final

    cmp     byte [r13 + rcx], '/'
    jne     .md_p_find_end
    inc     ecx
    jmp     .md_p_loop

.md_p_find_end:
    ; Find end of component
    mov     edx, ecx
.md_p_scan:
    cmp     edx, r14d
    jge     .md_p_create
    cmp     byte [r13 + rdx], '/'
    je      .md_p_create
    inc     edx
    jmp     .md_p_scan

.md_p_create:
    ; Temporarily NUL-terminate at edx
    mov     al, [r13 + rdx]
    push    rax                 ; save original char
    push    rdx                 ; save position
    mov     byte [r13 + rdx], 0

    ; Try mkdir
    mov     eax, SYS_MKDIR
    mov     rdi, r13
    mov     esi, 0o777          ; use 0777 for intermediate dirs
    syscall

    test    rax, rax
    jz      .md_p_created
    neg     rax
    cmp     eax, EEXIST
    je      .md_p_restore       ; already exists, continue

    ; Real error
    mov     r14d, eax
    mov     ebp, 1

    mov     rsi, str_prefix
    mov     edx, str_prefix_len
    call    do_write_err
    mov     rsi, str_cannot
    mov     edx, str_cannot_len
    call    do_write_err
    mov     rdi, r13
    call    str_len
    mov     edx, eax
    mov     rsi, r13
    call    do_write_err
    mov     rsi, str_colon_sep
    mov     edx, str_colon_sep_len
    call    do_write_err
    mov     eax, r14d
    call    print_errno

    pop     rdx
    pop     rax
    mov     byte [r13 + rdx], al
    jmp     .md_p_done

.md_p_created:
    ; Verbose output for intermediate dirs
    test    bl, 2
    jz      .md_p_restore
    push    rcx
    mov     rsi, str_verbose_pre
    mov     edx, str_verbose_pre_len
    call    do_write_err
    mov     rdi, r13
    call    str_len
    mov     edx, eax
    mov     rsi, r13
    call    do_write_err
    mov     rsi, str_sq_nl
    mov     edx, 2
    call    do_write_err
    pop     rcx

.md_p_restore:
    pop     rdx
    pop     rax
    mov     byte [r13 + rdx], al
    mov     ecx, edx
    jmp     .md_p_loop

.md_p_final:
    ; Create the final directory (may already exist from above)
    mov     eax, SYS_MKDIR
    mov     rdi, r13
    mov     esi, r12d           ; use requested mode for final dir
    syscall

    test    rax, rax
    jz      .md_p_final_ok
    neg     rax
    cmp     eax, EEXIST
    je      .md_p_done          ; -p ignores EEXIST

    ; Real error on final component
    mov     r14d, eax
    mov     ebp, 1
    mov     rsi, str_prefix
    mov     edx, str_prefix_len
    call    do_write_err
    mov     rsi, str_cannot
    mov     edx, str_cannot_len
    call    do_write_err
    mov     rdi, r15
    call    str_len
    mov     edx, eax
    mov     rsi, r15
    call    do_write_err
    mov     rsi, str_colon_sep
    mov     edx, str_colon_sep_len
    call    do_write_err
    mov     eax, r14d
    call    print_errno
    jmp     .md_p_done

.md_p_final_ok:
    ; If -m flag, chmod the final directory
    test    bl, 4
    jz      .md_p_final_verbose
    mov     eax, SYS_CHMOD
    mov     rdi, r13
    mov     esi, r12d
    syscall

.md_p_final_verbose:
    test    bl, 2
    jz      .md_p_done
    mov     rsi, str_verbose_pre
    mov     edx, str_verbose_pre_len
    call    do_write_err
    mov     rdi, r15
    call    str_len
    mov     edx, eax
    mov     rsi, r15
    call    do_write_err
    mov     rsi, str_sq_nl
    mov     edx, 2
    call    do_write_err

.md_p_done:
    add     rsp, 4104
    jmp     .md_done

.md_too_long:
    mov     ebp, 1
    mov     rsi, str_prefix
    mov     edx, str_prefix_len
    call    do_write_err
    mov     rsi, str_cannot
    mov     edx, str_cannot_len
    call    do_write_err
    mov     rdi, r15
    call    str_len
    mov     edx, eax
    mov     rsi, r15
    call    do_write_err
    mov     rsi, str_colon_sep
    mov     edx, str_colon_sep_len
    call    do_write_err
    mov     eax, ENAMETOOLONG
    call    print_errno

.md_done:
    pop     rbx
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    ret

; ============================================================
; parse_octal_mode: parse octal mode string
; Input: rdi = string pointer
; Output: eax = mode value (negative if error)
; Clobbers: r9 (uses r9 instead of ecx to avoid clobbering arg index)
; ============================================================
parse_octal_mode:
    xor     eax, eax
    movzx   r9d, byte [rdi]
    test    r9d, r9d
    jz      .pom_err            ; empty string
.pom_loop:
    movzx   r9d, byte [rdi]
    test    r9d, r9d
    jz      .pom_done
    cmp     r9d, '0'
    jb      .pom_err
    cmp     r9d, '7'
    ja      .pom_err
    shl     eax, 3
    sub     r9d, '0'
    add     eax, r9d
    inc     rdi
    jmp     .pom_loop
.pom_done:
    ; Validate range 0-7777
    cmp     eax, 0o7777
    ja      .pom_err
    ret
.pom_err:
    mov     eax, -1
    ret

; ============================================================
; print_errno: print error string for errno value in eax
; ============================================================
print_errno:
    cmp     eax, ENOENT
    je      .pe_noent
    cmp     eax, EEXIST
    je      .pe_exist
    cmp     eax, ENOTDIR
    je      .pe_notdir
    cmp     eax, EACCES
    je      .pe_acces
    cmp     eax, EPERM
    je      .pe_perm
    cmp     eax, ENOSPC
    je      .pe_nospc
    cmp     eax, EROFS
    je      .pe_rofs
    cmp     eax, ELOOP
    je      .pe_loop
    cmp     eax, ENAMETOOLONG
    je      .pe_nametoolong
    cmp     eax, EINVAL
    je      .pe_inval
    cmp     eax, ENOMEM
    je      .pe_nomem
    ; Default
    mov     rsi, str_err_unknown
    mov     edx, str_err_unknown_len
    jmp     do_write_err

.pe_noent:
    mov     rsi, str_err_noent
    mov     edx, str_err_noent_len
    jmp     do_write_err
.pe_exist:
    mov     rsi, str_err_exist
    mov     edx, str_err_exist_len
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
.pe_nospc:
    mov     rsi, str_err_nospc
    mov     edx, str_err_nospc_len
    jmp     do_write_err
.pe_rofs:
    mov     rsi, str_err_rofs
    mov     edx, str_err_rofs_len
    jmp     do_write_err
.pe_loop:
    mov     rsi, str_err_loop
    mov     edx, str_err_loop_len
    jmp     do_write_err
.pe_nametoolong:
    mov     rsi, str_err_nametoolong
    mov     edx, str_err_nametoolong_len
    jmp     do_write_err
.pe_inval:
    mov     rsi, str_err_inval
    mov     edx, str_err_inval_len
    jmp     do_write_err
.pe_nomem:
    mov     rsi, str_err_nomem
    mov     edx, str_err_nomem_len
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

; str_starts_with: check if rdi starts with rsi
; returns eax: 1=yes, 0=no
str_starts_with:
    xor     r8d, r8d
.ssw_loop:
    movzx   eax, byte [rsi + r8]
    test    al, al
    jz      .ssw_yes
    movzx   edx, byte [rdi + r8]
    cmp     al, dl
    jne     .ssw_no
    inc     r8d
    jmp     .ssw_loop
.ssw_yes:
    mov     eax, 1
    ret
.ssw_no:
    xor     eax, eax
    ret

; ============================================================
; Data
; ============================================================
; @@DATA_START@@
str_help:
    db "Usage: mkdir [OPTION]... DIRECTORY...", 10
    db "Create the DIRECTORY(ies), if they do not already exist.", 10, 10
    db "Mandatory arguments to long options are mandatory for short options too.", 10
    db "  -m, --mode=MODE   set file mode (as in chmod), not a=rwx - umask", 10
    db "  -p, --parents     no error if existing, make parent directories as needed,", 10
    db "                      with their file modes unaffected by any -m option.", 10
    db "  -v, --verbose     print a message for each created directory", 10
    db "  -Z                   set SELinux security context of each created directory", 10
    db "                         to the default type", 10
    db "      --context[=CTX]  like -Z, or if CTX is specified then set the SELinux", 10
    db "                         or SMACK security context to CTX", 10
    db "      --help        display this help and exit", 10
    db "      --version     output version information and exit", 10, 10
    db "GNU coreutils online help: <https://www.gnu.org/software/coreutils/>", 10
    db "Full documentation <https://www.gnu.org/software/coreutils/mkdir>", 10
    db "or available locally via: info '(coreutils) mkdir invocation'", 10
str_help_len equ $ - str_help

str_version:
    db "mkdir (GNU coreutils) 9.4", 10
    db "Copyright (C) 2023 Free Software Foundation, Inc.", 10
    db "License GPLv3+: GNU GPL version 3 or later <https://gnu.org/licenses/gpl.html>.", 10
    db "This is free software: you are free to change and redistribute it.", 10
    db "There is NO WARRANTY, to the extent permitted by law.", 10, 10
    db "Written by David MacKenzie.", 10
str_version_len equ $ - str_version

str_prefix:      db "mkdir: "
str_prefix_len   equ $ - str_prefix
str_unrecog:     db "unrecognized option '"
str_unrecog_len  equ $ - str_unrecog
str_invalid:     db "invalid option -- '"
str_invalid_len  equ $ - str_invalid
str_missing:     db "missing operand", 10
str_missing_len  equ $ - str_missing
str_sq_nl:       db "'", 10
str_try:         db "Try 'mkdir --help' for more information.", 10
str_try_len      equ $ - str_try
str_cannot:      db "cannot create directory '"
str_cannot_len   equ $ - str_cannot
str_colon_sep:   db "': "
str_colon_sep_len equ $ - str_colon_sep
str_verbose_pre: db "mkdir: created directory '"
str_verbose_pre_len equ $ - str_verbose_pre
str_missing_mode: db "option requires an argument -- 'm'", 10
str_missing_mode_len equ $ - str_missing_mode
str_invalid_mode: db "invalid mode '"
str_invalid_mode_len equ $ - str_invalid_mode
; @@DATA_END@@

; Error messages (with newline)
str_err_noent:     db "No such file or directory", 10
str_err_noent_len  equ $ - str_err_noent
str_err_exist:     db "File exists", 10
str_err_exist_len  equ $ - str_err_exist
str_err_notdir:    db "Not a directory", 10
str_err_notdir_len equ $ - str_err_notdir
str_err_acces:     db "Permission denied", 10
str_err_acces_len  equ $ - str_err_acces
str_err_perm:      db "Operation not permitted", 10
str_err_perm_len   equ $ - str_err_perm
str_err_nospc:     db "No space left on device", 10
str_err_nospc_len  equ $ - str_err_nospc
str_err_rofs:      db "Read-only file system", 10
str_err_rofs_len   equ $ - str_err_rofs
str_err_loop:      db "Too many levels of symbolic links", 10
str_err_loop_len   equ $ - str_err_loop
str_err_nametoolong: db "File name too long", 10
str_err_nametoolong_len equ $ - str_err_nametoolong
str_err_inval:     db "Invalid argument", 10
str_err_inval_len  equ $ - str_err_inval
str_err_nomem:     db "Cannot allocate memory", 10
str_err_nomem_len  equ $ - str_err_nomem
str_err_unknown:   db "Unknown error", 10
str_err_unknown_len equ $ - str_err_unknown

str_newline:     db 10
str_help_flag:   db "--help", 0
str_version_flag: db "--version", 0
str_parents_flag: db "--parents", 0
str_verbose_flag: db "--verbose", 0
str_mode_flag:   db "--mode", 0
str_mode_eq_flag: db "--mode=", 0

file_size equ $ - $$
