; ============================================================
; fmknod_unified.asm — GNU-compatible 'mknod' command
; Builds with: nasm -f bin fmknod_unified.asm -o fmknod
;
; mknod: Create special files (block, char, pipe).
;
; Usage: mknod [OPTION]... NAME TYPE [MAJOR MINOR]
;   TYPE: b (block), c/u (char), p (pipe/fifo)
;   For p type, MAJOR MINOR are not used.
;
; Register allocation:
;   r14d = argc, r15 = argv
;   ebp  = exit code
;   r12d = mode
;   ebx  = flags (bit 0 = -m set)
; ============================================================

BITS 64
ORG 0x400000

%define SYS_WRITE       1
%define SYS_MKNOD       133
%define SYS_EXIT        60
%define SYS_RT_SIGPROCMASK 14

%define STDOUT          1
%define STDERR          2
%define SIG_BLOCK       0
%define SIGPIPE         13

; File type bits
%define S_IFIFO         0o10000
%define S_IFCHR         0o20000
%define S_IFBLK         0o60000

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

    ; Initialize
    xor     ebx, ebx            ; flags
    xor     ebp, ebp            ; exit code = 0
    mov     r12d, 0o666         ; default mode
    mov     ecx, 1              ; arg index

    ; Parse options
.parse_opts:
    cmp     ecx, r14d
    jge     .err_missing_operand
    mov     rdi, [r15 + rcx*8]
    cmp     byte [rdi], '-'
    jne     .done_opts
    cmp     byte [rdi + 1], 0
    je      .done_opts
    cmp     byte [rdi + 1], '-'
    je      .check_long

    ; Short options: -m
    inc     rdi
.short_loop:
    movzx   eax, byte [rdi]
    test    al, al
    jz      .next_opt
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

.set_mode_short:
    or      bl, 1
    inc     rdi
    cmp     byte [rdi], 0
    jne     .parse_mode_val
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
    mov     rsi, str_help_flag
    call    str_eq
    test    eax, eax
    jnz     .pop_show_help
    mov     rdi, r13
    mov     rsi, str_version_flag
    call    str_eq
    test    eax, eax
    jnz     .pop_show_version
    mov     rdi, r13
    mov     rsi, str_mode_eq_flag
    call    str_starts_with
    test    eax, eax
    jnz     .pop_set_mode_long_eq
    mov     rdi, r13
    mov     rsi, str_mode_flag
    call    str_eq
    test    eax, eax
    jnz     .pop_set_mode_long
    ; Unrecognized
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
.pop_set_mode_long_eq:
    pop     rcx
    or      bl, 1
    lea     rdi, [r13 + 7]
    call    parse_octal_mode
    test    eax, eax
    js      .err_invalid_mode
    mov     r12d, eax
    jmp     .next_opt
.pop_set_mode_long:
    pop     rcx
    or      bl, 1
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
    ; ecx = index of NAME arg
    ; Need at least NAME and TYPE (2 args remaining)
    mov     r13d, ecx           ; save NAME index
    cmp     ecx, r14d
    jge     .err_missing_operand

    ; Get NAME
    mov     r8, [r15 + rcx*8]  ; NAME pointer

    ; Need TYPE
    inc     ecx
    cmp     ecx, r14d
    jge     .err_missing_type

    ; Get TYPE
    mov     rdi, [r15 + rcx*8]
    movzx   eax, byte [rdi]
    cmp     byte [rdi + 1], 0
    jne     .err_invalid_type

    ; Determine type
    cmp     al, 'p'
    je      .type_pipe
    cmp     al, 'b'
    je      .type_block
    cmp     al, 'c'
    je      .type_char
    cmp     al, 'u'
    je      .type_char
    jmp     .err_invalid_type

.type_pipe:
    ; For pipe, no MAJOR MINOR needed
    inc     ecx
    ; Check for extra operands
    cmp     ecx, r14d
    jl      .err_extra_operand_pipe

    ; mknod(NAME, S_IFIFO | mode, 0)
    mov     eax, SYS_MKNOD
    mov     rdi, r8
    mov     esi, r12d
    or      esi, S_IFIFO
    xor     edx, edx
    syscall
    jmp     .check_result

.type_block:
    ; Need MAJOR MINOR
    inc     ecx
    cmp     ecx, r14d
    jge     .err_missing_major
    mov     rdi, [r15 + rcx*8]
    call    parse_decimal
    test    r9d, r9d
    jnz     .err_invalid_major
    mov     r10d, eax           ; major

    inc     ecx
    cmp     ecx, r14d
    jge     .err_missing_minor
    mov     rdi, [r15 + rcx*8]
    call    parse_decimal
    test    r9d, r9d
    jnz     .err_invalid_minor
    mov     r11d, eax           ; minor

    inc     ecx
    cmp     ecx, r14d
    jl      .err_extra_operand

    ; Calculate dev number: makedev(major, minor)
    call    makedev             ; r10d=major, r11d=minor -> rax=dev

    ; mknod(NAME, S_IFBLK | mode, dev)
    mov     rdx, rax            ; dev
    mov     eax, SYS_MKNOD
    mov     rdi, r8
    mov     esi, r12d
    or      esi, S_IFBLK
    syscall
    jmp     .check_result

.type_char:
    ; Need MAJOR MINOR
    inc     ecx
    cmp     ecx, r14d
    jge     .err_missing_major
    mov     rdi, [r15 + rcx*8]
    call    parse_decimal
    test    r9d, r9d
    jnz     .err_invalid_major
    mov     r10d, eax           ; major

    inc     ecx
    cmp     ecx, r14d
    jge     .err_missing_minor
    mov     rdi, [r15 + rcx*8]
    call    parse_decimal
    test    r9d, r9d
    jnz     .err_invalid_minor
    mov     r11d, eax           ; minor

    inc     ecx
    cmp     ecx, r14d
    jl      .err_extra_operand

    ; Calculate dev number
    call    makedev

    ; mknod(NAME, S_IFCHR | mode, dev)
    mov     rdx, rax
    mov     eax, SYS_MKNOD
    mov     rdi, r8
    mov     esi, r12d
    or      esi, S_IFCHR
    syscall
    jmp     .check_result

.check_result:
    test    rax, rax
    jz      .success

    ; Error
    neg     rax
    push    rax
    mov     rsi, str_prefix
    mov     edx, str_prefix_len
    call    do_write_err
    mov     rsi, str_cannot
    mov     edx, str_cannot_len
    call    do_write_err
    mov     rdi, r8
    call    str_len
    mov     edx, eax
    mov     rsi, r8
    call    do_write_err
    mov     rsi, str_colon_sep
    mov     edx, str_colon_sep_len
    call    do_write_err
    pop     rax
    call    print_errno
    mov     edi, 1
    jmp     do_exit

.success:
    xor     edi, edi
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

.err_missing_type:
    mov     rsi, str_prefix
    mov     edx, str_prefix_len
    call    do_write_err
    mov     rsi, str_missing_type
    mov     edx, str_missing_type_len
    call    do_write_err
    mov     rdi, r8
    call    str_len
    mov     edx, eax
    mov     rsi, r8
    call    do_write_err
    mov     rsi, str_sq_nl
    mov     edx, 2
    call    do_write_err
    mov     rsi, str_try
    mov     edx, str_try_len
    call    do_write_err
    mov     edi, 1
    jmp     do_exit

.err_invalid_type:
    mov     rsi, str_prefix
    mov     edx, str_prefix_len
    call    do_write_err
    mov     rsi, str_invalid_type
    mov     edx, str_invalid_type_len
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
    mov     edi, 1
    jmp     do_exit

.err_missing_major:
    mov     rsi, str_prefix
    mov     edx, str_prefix_len
    call    do_write_err
    mov     rsi, str_missing_major
    mov     edx, str_missing_major_len
    call    do_write_err
    mov     rsi, str_try
    mov     edx, str_try_len
    call    do_write_err
    mov     edi, 1
    jmp     do_exit

.err_missing_minor:
    mov     rsi, str_prefix
    mov     edx, str_prefix_len
    call    do_write_err
    mov     rsi, str_missing_minor
    mov     edx, str_missing_minor_len
    call    do_write_err
    mov     rsi, str_try
    mov     edx, str_try_len
    call    do_write_err
    mov     edi, 1
    jmp     do_exit

.err_invalid_major:
    mov     rsi, str_prefix
    mov     edx, str_prefix_len
    call    do_write_err
    mov     rsi, str_invalid_major
    mov     edx, str_invalid_major_len
    call    do_write_err
    mov     edi, 1
    jmp     do_exit

.err_invalid_minor:
    mov     rsi, str_prefix
    mov     edx, str_prefix_len
    call    do_write_err
    mov     rsi, str_invalid_minor
    mov     edx, str_invalid_minor_len
    call    do_write_err
    mov     edi, 1
    jmp     do_exit

.err_extra_operand:
    mov     r13, [r15 + rcx*8] ; save extra operand ptr (syscall clobbers rcx)
    mov     rsi, str_prefix
    mov     edx, str_prefix_len
    call    do_write_err
    mov     rsi, str_extra
    mov     edx, str_extra_len
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
    mov     edi, 1
    jmp     do_exit

.err_extra_operand_pipe:
    mov     r13, [r15 + rcx*8] ; save extra operand ptr (syscall clobbers rcx)
    mov     rsi, str_prefix
    mov     edx, str_prefix_len
    call    do_write_err
    mov     rsi, str_extra
    mov     edx, str_extra_len
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
    mov     edi, 1
    jmp     do_exit

; ============================================================
; makedev: construct device number from major/minor
; Input: r10d = major, r11d = minor
; Output: rax = device number
; dev = (minor & 0xff) | ((major & 0xfff) << 8) |
;       ((minor & ~0xff) << 12) | ((major & ~0xfff) << 32)
; ============================================================
makedev:
    xor     rax, rax

    ; (minor & 0xff)
    movzx   ecx, r11b           ; minor & 0xff
    or      rax, rcx

    ; ((major & 0xfff) << 8)
    mov     ecx, r10d
    and     ecx, 0xfff
    shl     rcx, 8
    or      rax, rcx

    ; ((minor & ~0xff) << 12)
    mov     ecx, r11d
    and     ecx, 0xffffff00
    shl     rcx, 12
    or      rax, rcx

    ; ((major & ~0xfff) << 32)
    mov     ecx, r10d
    and     ecx, 0xfffff000
    mov     rcx, rcx            ; zero-extend to 64 bits
    shl     rcx, 32
    or      rax, rcx

    ret

; ============================================================
; parse_decimal: parse unsigned decimal integer
; Input: rdi = string pointer
; Output: eax = value, r9d = 0 if ok, 1 if error
; ============================================================
parse_decimal:
    xor     eax, eax
    xor     r9d, r9d
    movzx   ecx, byte [rdi]
    test    cl, cl
    jz      .pd_err
.pd_loop:
    movzx   ecx, byte [rdi]
    test    cl, cl
    jz      .pd_done
    cmp     cl, '0'
    jb      .pd_err
    cmp     cl, '9'
    ja      .pd_err
    ; eax = eax * 10 + (cl - '0')
    mov     r9d, eax
    shl     eax, 1              ; *2
    shl     r9d, 3              ; *8
    add     eax, r9d            ; *10
    sub     cl, '0'
    movzx   ecx, cl
    add     eax, ecx
    inc     rdi
    jmp     .pd_loop
.pd_done:
    xor     r9d, r9d
    ret
.pd_err:
    mov     r9d, 1
    ret

; ============================================================
; parse_octal_mode
; ============================================================
parse_octal_mode:
    xor     eax, eax
    movzx   r9d, byte [rdi]
    test    r9d, r9d
    jz      .pom_err
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
    cmp     eax, 0o7777
    ja      .pom_err
    ret
.pom_err:
    mov     eax, -1
    ret

; ============================================================
; print_errno
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
    cmp     eax, EINVAL
    je      .pe_inval
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
    db "Usage: mknod [OPTION]... NAME TYPE [MAJOR MINOR]", 10
    db "Create the special file NAME of the given TYPE.", 10, 10
    db "Mandatory arguments to long options are mandatory for short options too.", 10
    db "  -m, --mode=MODE   set file permission bits to MODE, not a=rw - umask", 10
    db "  -Z                   set the SELinux security context to default type", 10
    db "      --context[=CTX]  like -Z, or if CTX is specified then set the SELinux", 10
    db "                         or SMACK security context to CTX", 10
    db "      --help        display this help and exit", 10
    db "      --version     output version information and exit", 10, 10
    db "Both MAJOR and MINOR must be specified when TYPE is b, c, or u, and they", 10
    db "must be omitted when TYPE is p.  If MAJOR or MINOR begins with 0x or 0X,", 10
    db "it is interpreted as hexadecimal; otherwise, if it begins with 0, as octal;", 10
    db "otherwise, as decimal.  TYPE may be:", 10, 10
    db "  b      create a block (buffered) special file", 10
    db "  c, u   create a character (unbuffered) special file", 10
    db "  p      create a FIFO", 10, 10
    db "NOTE: your shell may have its own version of mknod, which usually supersedes", 10
    db "the version described here.  Please refer to your shell's documentation", 10
    db "for details about the options it supports.", 10, 10
    db "GNU coreutils online help: <https://www.gnu.org/software/coreutils/>", 10
    db "Full documentation <https://www.gnu.org/software/coreutils/mknod>", 10
    db "or available locally via: info '(coreutils) mknod invocation'", 10
str_help_len equ $ - str_help

str_version:
    db "mknod (GNU coreutils) 9.4", 10
    db "Copyright (C) 2023 Free Software Foundation, Inc.", 10
    db "License GPLv3+: GNU GPL version 3 or later <https://gnu.org/licenses/gpl.html>.", 10
    db "This is free software: you are free to change and redistribute it.", 10
    db "There is NO WARRANTY, to the extent permitted by law.", 10, 10
    db "Written by David MacKenzie.", 10
str_version_len equ $ - str_version

str_prefix:      db "mknod: "
str_prefix_len   equ $ - str_prefix
str_unrecog:     db "unrecognized option '"
str_unrecog_len  equ $ - str_unrecog
str_invalid:     db "invalid option -- '"
str_invalid_len  equ $ - str_invalid
str_missing:     db "missing operand", 10
str_missing_len  equ $ - str_missing
str_sq_nl:       db "'", 10
str_try:         db "Try 'mknod --help' for more information.", 10
str_try_len      equ $ - str_try
str_cannot:      db "cannot create special file '"
str_cannot_len   equ $ - str_cannot    ; NOTE: GNU says "cannot create special file"
str_colon_sep:   db "': "
str_colon_sep_len equ $ - str_colon_sep
str_missing_type: db "missing operand after '"
str_missing_type_len equ $ - str_missing_type
str_invalid_type: db "invalid device type", 10
str_invalid_type_len equ $ - str_invalid_type    ; NOTE: simplified
str_missing_mode: db "option requires an argument -- 'm'", 10
str_missing_mode_len equ $ - str_missing_mode
str_invalid_mode: db "invalid mode", 10
str_invalid_mode_len equ $ - str_invalid_mode
str_missing_major: db "missing operand", 10
str_missing_major_len equ $ - str_missing_major
str_missing_minor: db "missing operand", 10
str_missing_minor_len equ $ - str_missing_minor
str_invalid_major: db "invalid major device number", 10
str_invalid_major_len equ $ - str_invalid_major
str_invalid_minor: db "invalid minor device number", 10
str_invalid_minor_len equ $ - str_invalid_minor
str_extra:       db "extra operand '"
str_extra_len    equ $ - str_extra
; @@DATA_END@@

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
str_err_inval:     db "Invalid argument", 10
str_err_inval_len  equ $ - str_err_inval
str_err_unknown:   db "Unknown error", 10
str_err_unknown_len equ $ - str_err_unknown

str_newline:     db 10
str_help_flag:   db "--help", 0
str_version_flag: db "--version", 0
str_mode_flag:   db "--mode", 0
str_mode_eq_flag: db "--mode=", 0

file_size equ $ - $$
