; ============================================================
; flogname_unified.asm — AUTO-GENERATED unified file
; Builds with: nasm -f bin flogname_unified.asm -o flogname_release
; ============================================================

BITS 64
ORG 0x400000

; ── Linux syscall numbers ────────────────────────────────────
%define SYS_READ        0
%define SYS_WRITE       1
%define SYS_OPEN        2
%define SYS_CLOSE       3
%define SYS_EXIT       60
%define SYS_READLINK   89

%define STDIN           0
%define STDOUT          1
%define STDERR          2

%define UTMP_ENTRY_SIZE 384
%define UTMP_TYPE_OFF   0
%define UTMP_LINE_OFF   8
%define UTMP_USER_OFF   44
%define USER_PROCESS    7
%define UT_NAMESIZE     32

; ── ELF64 Header (64 bytes) ─────────────────────────────────
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
    dw 64                       ; ELF header size
    dw 56                       ; program header entry size
    dw 2                        ; 2 program headers
    dw 64                       ; section header entry size
    dw 0                        ; section header count
    dw 0                        ; section name index

; ── Program Headers (2 × 56 bytes) ──────────────────────────
phdr:
; PT_LOAD: code + rodata (R+X)
    dd 1                        ; PT_LOAD
    dd 5                        ; PF_R | PF_X
    dq 0                        ; offset in file
    dq $$                       ; virtual address
    dq $$                       ; physical address
    dq file_size                ; file size
    dq mem_size                 ; memory size (includes BSS)
    dq 0x200000                 ; alignment

; PT_GNU_STACK: non-executable stack
    dd 0x6474e551               ; PT_GNU_STACK
    dd 6                        ; PF_R | PF_W (no X)
    dq 0
    dq 0
    dq 0
    dq 0
    dq 0
    dq 0x10                     ; alignment

; ══════════════════════════════════════════════════════════════
; CODE SECTION
; ══════════════════════════════════════════════════════════════

_start:
    ; Get argc/argv from stack
    mov     r14, [rsp]
    lea     r15, [rsp + 8]

    ; If argc <= 1, do logname
    cmp     r14, 1
    jbe     .do_logname

    ; Process argv[1]
    mov     r13, [r15 + 8]

    cmp     byte [r13], '-'
    jne     .err_extra_operand

    cmp     byte [r13 + 1], '-'
    je      .check_long_option

    ; Single dash: check for bare "-"
    cmp     byte [r13 + 1], 0
    je      .err_extra_operand
    jmp     .err_invalid_option

.check_long_option:
    cmp     byte [r13 + 2], 0
    je      .handle_double_dash

    ; Check --help
    mov     rdi, r13
    mov     rsi, str_help_flag
    call    str_eq_func
    test    rax, rax
    jnz     .show_help

    ; Check --version
    mov     rdi, r13
    mov     rsi, str_version_flag
    call    str_eq_func
    test    rax, rax
    jnz     .show_version

    jmp     .err_unrecognized

.handle_double_dash:
    cmp     r14, 2
    jbe     .do_logname
    mov     r13, [r15 + 16]
    jmp     .err_extra_operand

; ── Output handlers ──────────────────────────────────────────

.show_help:
    mov     rdi, STDOUT
    mov     rsi, str_help
    mov     rdx, str_help_len
    call    do_write
    xor     rdi, rdi
    jmp     do_exit

.show_version:
    mov     rdi, STDOUT
    mov     rsi, str_version
    mov     rdx, str_version_len
    call    do_write
    xor     rdi, rdi
    jmp     do_exit

; ── Error handlers ───────────────────────────────────────────

.err_unrecognized:
    mov     rsi, str_prefix
    mov     rdx, str_prefix_len
    call    do_write_err
    mov     rsi, str_unrecog
    mov     rdx, str_unrecog_len
    call    do_write_err
    mov     rdi, r13
    call    str_len_func
    mov     rdx, rax
    mov     rsi, r13
    call    do_write_err
    mov     rsi, str_sq_nl
    mov     rdx, 2
    call    do_write_err
    jmp     .err_try_exit

.err_invalid_option:
    mov     rsi, str_prefix
    mov     rdx, str_prefix_len
    call    do_write_err
    mov     rsi, str_invalid
    mov     rdx, str_invalid_len
    call    do_write_err
    lea     rsi, [r13 + 1]
    mov     rdx, 1
    call    do_write_err
    mov     rsi, str_sq_nl
    mov     rdx, 2
    call    do_write_err
    jmp     .err_try_exit

.err_extra_operand:
    mov     rsi, str_prefix
    mov     rdx, str_prefix_len
    call    do_write_err
    mov     rsi, str_extra
    mov     rdx, str_extra_len
    call    do_write_err
    mov     rdi, r13
    call    str_len_func
    mov     rdx, rax
    mov     rsi, r13
    call    do_write_err
    mov     rsi, str_sq_nl
    mov     rdx, 2
    call    do_write_err
    jmp     .err_try_exit

.err_try_exit:
    mov     rsi, str_try
    mov     rdx, str_try_len
    call    do_write_err
    mov     rdi, 1
    jmp     do_exit

; ── Main logname logic ───────────────────────────────────────

.do_logname:
    call    try_loginuid
    test    rax, rax
    jnz     .print_name

    call    try_utmp
    test    rax, rax
    jnz     .print_name

    mov     rsi, str_no_login
    mov     rdx, str_no_login_len
    call    do_write_err
    mov     rdi, 1
    jmp     do_exit

.print_name:
    mov     r12, rax
    mov     rdi, r12
    call    str_len_func
    mov     rdx, rax
    mov     rdi, STDOUT
    mov     rsi, r12
    call    do_write
    mov     rdi, STDOUT
    mov     rsi, str_newline
    mov     rdx, 1
    call    do_write
    xor     rdi, rdi
    jmp     do_exit

; ══════════════════════════════════════════════════════════════
; LIBRARY FUNCTIONS (inlined from lib/)
; ══════════════════════════════════════════════════════════════

; do_write(rdi=fd, rsi=buf, rdx=len) -> rax
do_write:
    mov     rax, SYS_WRITE
    syscall
    cmp     rax, -4
    je      do_write
    ret

; do_write_err(rsi=buf, rdx=len) -> rax
do_write_err:
    mov     rdi, STDERR
    jmp     do_write

; do_read(rdi=fd, rsi=buf, rdx=len) -> rax
do_read:
    mov     rax, SYS_READ
    syscall
    cmp     rax, -4
    je      do_read
    ret

; do_exit(rdi=code) — never returns
do_exit:
    mov     rax, SYS_EXIT
    syscall

; str_len_func(rdi=string) -> rax=length
str_len_func:
    xor     rax, rax
.sl_loop:
    cmp     byte [rdi + rax], 0
    je      .sl_done
    inc     rax
    jmp     .sl_loop
.sl_done:
    ret

; str_eq_func(rdi=str1, rsi=str2) -> rax=1 if equal, 0 if not
str_eq_func:
    xor     rcx, rcx
.se_loop:
    movzx   eax, byte [rdi + rcx]
    movzx   edx, byte [rsi + rcx]
    cmp     al, dl
    jne     .se_ne
    test    al, al
    jz      .se_eq
    inc     rcx
    jmp     .se_loop
.se_eq:
    mov     rax, 1
    ret
.se_ne:
    xor     rax, rax
    ret

; ══════════════════════════════════════════════════════════════
; Method 1: /proc/self/loginuid -> /etc/passwd
; ══════════════════════════════════════════════════════════════

try_loginuid:
    push    rbx
    push    r12
    push    r13

    mov     rax, SYS_OPEN
    mov     rdi, path_loginuid
    xor     rsi, rsi
    xor     rdx, rdx
    syscall
    test    rax, rax
    js      .tl_fail

    mov     r12, rax

    mov     rdi, r12
    mov     rsi, uid_str
    mov     rdx, 31
    call    do_read

    push    rax
    mov     rax, SYS_CLOSE
    mov     rdi, r12
    syscall
    pop     rax

    test    rax, rax
    jle     .tl_fail

    mov     r12, rax
    mov     byte [uid_str + r12], 0
    dec     r12
    cmp     byte [uid_str + r12], 10
    jne     .tl_no_trim
    mov     byte [uid_str + r12], 0
.tl_no_trim:

    mov     rdi, uid_str
    mov     rsi, str_invalid_uid
    call    str_eq_func
    test    rax, rax
    jnz     .tl_fail

    mov     rax, SYS_OPEN
    mov     rdi, path_passwd
    xor     rsi, rsi
    xor     rdx, rdx
    syscall
    test    rax, rax
    js      .tl_fail

    mov     r12, rax
    call    scan_passwd

    push    rax
    mov     rax, SYS_CLOSE
    mov     rdi, r12
    syscall
    pop     rax

    pop     r13
    pop     r12
    pop     rbx
    ret

.tl_fail:
    xor     rax, rax
    pop     r13
    pop     r12
    pop     rbx
    ret

; ══════════════════════════════════════════════════════════════
; Scan /etc/passwd for UID matching uid_str
; r12 = fd. Returns: rax = pointer to name_buf or 0
; ══════════════════════════════════════════════════════════════

scan_passwd:
    push    rbx
    push    r13
    push    r14
    push    r15
    push    rbp

    xor     rbp, rbp

.sp_read:
    mov     rdi, r12
    lea     rsi, [read_buf + rbp]
    mov     rdx, 4095
    sub     rdx, rbp
    jle     .sp_nf
    call    do_read
    test    rax, rax
    jle     .sp_leftover

    add     rbp, rax
    xor     r13, r13

.sp_scan:
    cmp     r13, rbp
    jge     .sp_more

    mov     r14, r13
.sp_nl:
    cmp     r14, rbp
    jge     .sp_partial
    cmp     byte [read_buf + r14], 10
    je      .sp_line
    inc     r14
    jmp     .sp_nl

.sp_line:
    mov     rcx, r13
    xor     rbx, rbx
.sp_fc:
    cmp     rcx, r14
    jge     .sp_next
    cmp     byte [read_buf + rcx], ':'
    jne     .sp_fc2
    inc     rbx
    cmp     rbx, 2
    je      .sp_us
.sp_fc2:
    inc     rcx
    jmp     .sp_fc

.sp_us:
    inc     rcx
    mov     r15, rcx
.sp_ue:
    cmp     rcx, r14
    jge     .sp_next
    cmp     byte [read_buf + rcx], ':'
    je      .sp_cmp
    inc     rcx
    jmp     .sp_ue

.sp_cmp:
    push    rcx
    mov     rdi, uid_str
    call    str_len_func
    pop     rcx

    mov     rdx, rcx
    sub     rdx, r15
    cmp     rax, rdx
    jne     .sp_next

    xor     rbx, rbx
.sp_cb:
    cmp     rbx, rax
    je      .sp_match
    movzx   edx, byte [read_buf + r15 + rbx]
    cmp     dl, byte [uid_str + rbx]
    jne     .sp_next
    inc     rbx
    jmp     .sp_cb

.sp_match:
    lea     rsi, [read_buf + r13]
    mov     rdi, name_buf
    xor     rcx, rcx
.sp_cn:
    cmp     byte [rsi + rcx], ':'
    je      .sp_cd
    cmp     rcx, 255
    jge     .sp_cd
    mov     al, [rsi + rcx]
    mov     [rdi + rcx], al
    inc     rcx
    jmp     .sp_cn
.sp_cd:
    mov     byte [rdi + rcx], 0
    mov     rax, name_buf
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     rbx
    ret

.sp_next:
    lea     r13, [r14 + 1]
    jmp     .sp_scan

.sp_partial:
    mov     rcx, rbp
    sub     rcx, r13
    test    rcx, rcx
    jz      .sp_noleft
    push    rsi
    push    rdi
    lea     rsi, [read_buf + r13]
    mov     rdi, read_buf
    mov     rbp, rcx
    rep     movsb
    pop     rdi
    pop     rsi
    jmp     .sp_read

.sp_noleft:
    xor     rbp, rbp
.sp_more:
    xor     rbp, rbp
    jmp     .sp_read

.sp_leftover:
    test    rbp, rbp
    jz      .sp_nf
    mov     r13, 0
    mov     r14, rbp
    jmp     .sp_line

.sp_nf:
    xor     rax, rax
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     rbx
    ret

; ══════════════════════════════════════════════════════════════
; Method 2: utmp lookup
; ══════════════════════════════════════════════════════════════

try_utmp:
    push    rbx
    push    r12
    push    r13

    mov     rax, SYS_READLINK
    mov     rdi, path_fd0
    mov     rsi, tty_buf
    mov     rdx, 255
    syscall
    test    rax, rax
    jle     .tu_fail

    mov     byte [tty_buf + rax], 0

    cmp     byte [tty_buf], '/'
    jne     .tu_fail
    cmp     byte [tty_buf + 1], 'd'
    jne     .tu_fail
    cmp     byte [tty_buf + 2], 'e'
    jne     .tu_fail
    cmp     byte [tty_buf + 3], 'v'
    jne     .tu_fail
    cmp     byte [tty_buf + 4], '/'
    jne     .tu_fail

    lea     r13, [tty_buf + 5]

    mov     rax, SYS_OPEN
    mov     rdi, path_utmp
    xor     rsi, rsi
    xor     rdx, rdx
    syscall
    test    rax, rax
    js      .tu_fail

    mov     r12, rax

.tu_read:
    mov     rdi, r12
    mov     rsi, utmp_entry
    mov     rdx, UTMP_ENTRY_SIZE
    call    do_read
    cmp     rax, UTMP_ENTRY_SIZE
    jne     .tu_close

    movzx   eax, word [utmp_entry + UTMP_TYPE_OFF]
    cmp     eax, USER_PROCESS
    jne     .tu_read

    lea     rdi, [utmp_entry + UTMP_LINE_OFF]
    mov     rsi, r13
    call    str_eq_func
    test    rax, rax
    jz      .tu_read

    lea     rsi, [utmp_entry + UTMP_USER_OFF]
    mov     rdi, name_buf
    xor     rcx, rcx
.tu_cn:
    cmp     rcx, UT_NAMESIZE - 1
    jge     .tu_cd
    movzx   eax, byte [rsi + rcx]
    test    al, al
    jz      .tu_cd
    mov     [rdi + rcx], al
    inc     rcx
    jmp     .tu_cn
.tu_cd:
    mov     byte [rdi + rcx], 0
    mov     rax, SYS_CLOSE
    mov     rdi, r12
    syscall
    mov     rax, name_buf
    pop     r13
    pop     r12
    pop     rbx
    ret

.tu_close:
    mov     rax, SYS_CLOSE
    mov     rdi, r12
    syscall
.tu_fail:
    xor     rax, rax
    pop     r13
    pop     r12
    pop     rbx
    ret

; ══════════════════════════════════════════════════════════════
; READ-ONLY DATA
; ══════════════════════════════════════════════════════════════

str_help:
    db "Usage: logname [OPTION]", 10
    db "Print the user's login name.", 10
    db 10
    db "      --help        display this help and exit", 10
    db "      --version     output version information and exit", 10
    db 10
    db "GNU coreutils online help: <https://www.gnu.org/software/coreutils/>", 10
    db "Report any translation bugs to <https://translationproject.org/team/>", 10
    db "Full documentation <https://www.gnu.org/software/coreutils/logname>", 10
    db "or available locally via: info '(coreutils) logname invocation'", 10
str_help_len equ $ - str_help

str_version:
    db "logname (GNU coreutils) 9.4", 10
    db "Copyright (C) 2023 Free Software Foundation, Inc.", 10
    db "License GPLv3+: GNU GPL version 3 or later <https://gnu.org/licenses/gpl.html>.", 10
    db "This is free software: you are free to change and redistribute it.", 10
    db "There is NO WARRANTY, to the extent permitted by law.", 10
    db 10
    db "Written by FIXME: unknown.", 10
str_version_len equ $ - str_version

str_prefix:      db "logname: "
str_prefix_len   equ $ - str_prefix
str_unrecog:     db "unrecognized option '"
str_unrecog_len  equ $ - str_unrecog
str_invalid:     db "invalid option -- '"
str_invalid_len  equ $ - str_invalid
str_extra:       db "extra operand '"
str_extra_len    equ $ - str_extra
str_sq_nl:       db "'", 10
str_try:         db "Try 'logname --help' for more information.", 10
str_try_len      equ $ - str_try
str_no_login:    db "logname: no login name", 10
str_no_login_len equ $ - str_no_login
str_newline:     db 10

path_loginuid:   db "/proc/self/loginuid", 0
path_passwd:     db "/etc/passwd", 0
path_utmp:       db "/var/run/utmp", 0
path_fd0:        db "/proc/self/fd/0", 0

str_help_flag:    db "--help", 0
str_version_flag: db "--version", 0
str_invalid_uid:  db "4294967295", 0

; Mark end of file data
file_size equ $ - $$

; ══════════════════════════════════════════════════════════════
; BSS (virtual addresses only — not stored in file)
; The PT_LOAD header maps mem_size bytes, kernel zeros the rest
; ══════════════════════════════════════════════════════════════

%define BSS_BASE ($$ + file_size)
read_buf     equ BSS_BASE
name_buf     equ BSS_BASE + 4096
uid_str      equ BSS_BASE + 4096 + 256
tty_buf      equ BSS_BASE + 4096 + 256 + 32
utmp_entry   equ BSS_BASE + 4096 + 256 + 32 + 256

mem_size equ BSS_BASE + 4096 + 256 + 32 + 256 + UTMP_ENTRY_SIZE - $$
