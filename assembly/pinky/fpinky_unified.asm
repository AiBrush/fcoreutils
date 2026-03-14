; ============================================================
; fpinky_unified.asm — GNU-compatible 'pinky' command
; Builds with: nasm -f bin fpinky_unified.asm -o fpinky
;
; pinky: lightweight finger information lookup
;
; Usage: pinky [OPTION]... [USER]...
;   -l: long format
;   -s: short format (default)
;   -f: omit heading in short format
;   -w: omit full name in short format
;   -i: omit full name and remote host in short format
;   -q: omit full name, remote host and idle time
;   -b: omit home directory and shell in long format
;   -h: omit project file in long format
;   -p: omit plan file in long format
;
; Reads /var/run/utmp for login sessions
; ============================================================

BITS 64
ORG 0x400000

%define SYS_READ        0
%define SYS_WRITE       1
%define SYS_OPEN        2
%define SYS_CLOSE       3
%define SYS_EXIT       60
%define SYS_RT_SIGPROCMASK 14

%define O_RDONLY        0
%define STDOUT          1
%define STDERR          2
%define SIG_BLOCK       0
%define SIGPIPE        13

; utmp record size and fields (Linux x86-64)
%define UT_LINESIZE     32
%define UT_NAMESIZE     32
%define UT_HOSTSIZE    256
%define UTMP_SIZE      384    ; sizeof(struct utmp)
%define USER_PROCESS     7

; Offsets in struct utmp
%define UT_TYPE          0    ; short (2 bytes)
%define UT_PID           4    ; pid_t (4 bytes)
%define UT_LINE          8    ; char[32]
%define UT_USER         36    ; char[32] (at offset 8+32-4 = 36)
%define UT_HOST         76    ; char[256]

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

    ; Defaults
    xor     r12d, r12d          ; flags: bit0=long, bit1=no_heading, bit2=no_name
    mov     ecx, 1

    cmp     r14d, 2
    jl      .no_more_opts

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

.parse_opts:
    cmp     ecx, r14d
    jge     .no_more_opts
    mov     rdi, [r15 + rcx*8]
    cmp     byte [rdi], '-'
    jne     .no_more_opts
    cmp     byte [rdi + 1], '-'
    je      .check_long_opt
    cmp     byte [rdi + 1], 0
    je      .no_more_opts
    ; Parse short flags
    inc     rdi
.short_loop:
    movzx   eax, byte [rdi]
    test    al, al
    jz      .next_opt
    cmp     al, 'l'
    je      .set_long
    cmp     al, 's'
    je      .set_short
    cmp     al, 'f'
    je      .set_no_heading
    cmp     al, 'w'
    je      .set_no_name
    cmp     al, 'i'
    je      .set_no_name
    cmp     al, 'q'
    je      .set_no_name
    cmp     al, 'b'
    je      .skip_flag
    cmp     al, 'h'
    je      .skip_flag
    cmp     al, 'p'
    je      .skip_flag
    ; Invalid
    jmp     .invalid_short
.set_long:
    or      r12d, 1
    inc     rdi
    jmp     .short_loop
.set_short:
    and     r12d, ~1
    inc     rdi
    jmp     .short_loop
.set_no_heading:
    or      r12d, 2
    inc     rdi
    jmp     .short_loop
.set_no_name:
    or      r12d, 4
    inc     rdi
    jmp     .short_loop
.skip_flag:
    inc     rdi
    jmp     .short_loop
.next_opt:
    inc     ecx
    jmp     .parse_opts

.check_long_opt:
    ; rdi points to arg starting with "--"
    cmp     byte [rdi + 2], 0
    je      .no_more_opts          ; bare "--" ends option parsing
    ; Check --help
    push    rcx
    mov     rsi, str_help_flag
    call    str_eq
    test    eax, eax
    jnz     .show_help
    ; Check --version
    mov     rdi, [r15 + rcx*8]
    mov     rsi, str_version_flag
    call    str_eq
    test    eax, eax
    jnz     .show_version
    pop     rcx
    ; Unknown long option — report error
    mov     rdi, [r15 + rcx*8]
    jmp     .invalid_long

.invalid_long:
    ; rdi = the unknown option string
    push    rdi
    mov     rsi, str_prefix
    mov     edx, str_prefix_len
    call    write_err
    mov     rsi, str_unrecognized
    mov     edx, str_unrecognized_len
    call    write_err
    pop     rdi
    push    rdi
    call    str_len
    mov     edx, eax
    pop     rsi
    call    write_err
    mov     rsi, str_sq_nl
    mov     edx, 2
    call    write_err
    mov     rsi, str_try
    mov     edx, str_try_len
    call    write_err
    mov     edi, 1
    jmp     do_exit

.no_more_opts:
    ; ecx = first non-option arg (user filter)
    mov     ebx, ecx            ; save first user arg index

    ; Print heading (short format, unless -f)
    test    r12d, 1
    jnz     .skip_heading       ; long format: no heading
    test    r12d, 2
    jnz     .skip_heading       ; -f: no heading
    mov     edi, STDOUT
    mov     rsi, str_heading
    mov     edx, str_heading_len
    call    do_write
.skip_heading:

    ; Open /var/run/utmp
    mov     eax, SYS_OPEN
    mov     rdi, str_utmp_path
    xor     esi, esi            ; O_RDONLY
    xor     edx, edx
    syscall
    test    rax, rax
    js      .no_utmp
    mov     r13, rax            ; utmp fd

.read_utmp:
    mov     eax, SYS_READ
    mov     edi, r13d
    lea     rsi, [utmp_buf]
    mov     edx, UTMP_SIZE
    syscall
    cmp     rax, UTMP_SIZE
    jl      .close_utmp

    ; Check ut_type == USER_PROCESS
    movzx   eax, word [utmp_buf + UT_TYPE]
    cmp     eax, USER_PROCESS
    jne     .read_utmp

    ; If user filter specified, check match
    cmp     ebx, r14d
    jge     .print_entry        ; no filter, show all

    ; Check if this user matches any filter arg
    mov     r8d, ebx
.check_user_filter:
    cmp     r8d, r14d
    jge     .read_utmp          ; no match
    lea     rdi, [utmp_buf + UT_USER]
    mov     rsi, [r15 + r8*8]
    push    r8
    call    str_eq_n
    pop     r8
    test    eax, eax
    jnz     .print_entry
    inc     r8d
    jmp     .check_user_filter

.print_entry:
    ; Print user login name (8 chars, space-padded)
    lea     rsi, [utmp_buf + UT_USER]
    mov     rdi, rsi
    call    str_len_max
    mov     edx, eax
    mov     edi, STDOUT
    call    do_write

    ; Pad to column 9
    cmp     eax, 8
    jge     .print_space
    mov     r8d, eax
.pad_user:
    cmp     r8d, 9
    jge     .print_tty
    mov     edi, STDOUT
    mov     rsi, str_space
    mov     edx, 1
    push    r8
    call    do_write
    pop     r8
    inc     r8d
    jmp     .pad_user
.print_space:
    mov     edi, STDOUT
    mov     rsi, str_space
    mov     edx, 1
    call    do_write

.print_tty:
    ; Print TTY
    lea     rsi, [utmp_buf + UT_LINE]
    mov     rdi, rsi
    call    str_len_max
    mov     edx, eax
    mov     edi, STDOUT
    call    do_write

    ; Print newline
    mov     edi, STDOUT
    mov     rsi, str_newline
    mov     edx, 1
    call    do_write

    jmp     .read_utmp

.close_utmp:
    mov     eax, SYS_CLOSE
    mov     edi, r13d
    syscall

.no_utmp:
    xor     edi, edi
    jmp     do_exit

.invalid_short:
    mov     r8b, [rdi]
    mov     rsi, str_prefix
    mov     edx, str_prefix_len
    call    write_err
    mov     rsi, str_invalid
    mov     edx, str_invalid_len
    call    write_err
    mov     [char_buf], r8b
    mov     rsi, char_buf
    mov     edx, 1
    call    write_err
    mov     rsi, str_sq_nl
    mov     edx, 2
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

; str_len_max: like str_len but max 32 bytes
str_len_max:
    xor     eax, eax
.loop:
    cmp     eax, 32
    jge     .done
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

; str_eq_n: compare utmp username (may not be NUL-terminated if 32 chars)
; rdi = utmp field, rsi = NUL-terminated user string
str_eq_n:
    xor     r8d, r8d
.loop:
    cmp     r8d, UT_NAMESIZE
    jge     .check_end
    movzx   eax, byte [rdi + r8]
    movzx   edx, byte [rsi + r8]
    test    al, al
    jz      .check_end
    test    dl, dl
    jz      .check_utmp_end
    cmp     al, dl
    jne     .ne
    inc     r8d
    jmp     .loop
.check_end:
    ; utmp field ended — rsi must also end
    cmp     byte [rsi + r8], 0
    je      .eq
    jmp     .ne
.check_utmp_end:
    ; rsi ended — utmp must also be NUL
    cmp     byte [rdi + r8], 0
    je      .eq
.ne:
    xor     eax, eax
    ret
.eq:
    mov     eax, 1
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
    db "Usage: pinky [OPTION]... [USER]...", 10, 10
    db "  -l              produce long format output for the specified USERs", 10
    db "  -b              omit the user's home directory and shell in long format", 10
    db "  -h              omit the user's project file in long format", 10
    db "  -p              omit the user's plan file in long format", 10
    db "  -s              do short format output, this is the default", 10
    db "  -f              omit the line of column headings in short format", 10
    db "  -w              omit the user's full name in short format", 10
    db "  -i              omit the user's full name and remote host in short format", 10
    db "  -q              omit the user's full name, remote host and idle time", 10
    db "                  in short format", 10
    db "      --help        display this help and exit", 10
    db "      --version     output version information and exit", 10, 10
    db "A lightweight 'finger' program;  print user information.", 10
    db "The utmp file will be /var/run/utmp.", 10, 10
    db "GNU coreutils online help: <https://www.gnu.org/software/coreutils/>", 10
    db "Full documentation <https://www.gnu.org/software/coreutils/pinky>", 10
    db "or available locally via: info '(coreutils) pinky invocation'", 10
str_help_len equ $ - str_help

str_version:
    db "pinky (GNU coreutils) 9.7", 10
    db "Copyright (C) 2025 Free Software Foundation, Inc.", 10
    db "License GPLv3+: GNU GPL version 3 or later <https://gnu.org/licenses/gpl.html>.", 10
    db "This is free software: you are free to change and redistribute it.", 10
    db "There is NO WARRANTY, to the extent permitted by law.", 10, 10
    db "Written by Joseph Arceneaux.", 10
str_version_len equ $ - str_version
; @@DATA_END@@

str_prefix:         db "pinky: "
str_prefix_len      equ $ - str_prefix
str_try:            db "Try 'pinky --help' for more information.", 10
str_try_len         equ $ - str_try
str_invalid:        db "invalid option -- '"
str_invalid_len     equ $ - str_invalid
str_unrecognized:   db "unrecognized option '"
str_unrecognized_len equ $ - str_unrecognized
str_sq_nl:          db "'", 10

str_heading:        db "Login    Name                 TTY", 10
str_heading_len     equ $ - str_heading

str_help_flag:      db "--help", 0
str_version_flag:   db "--version", 0
str_utmp_path:      db "/var/run/utmp", 0
str_newline:        db 10
str_space:          db " "

file_size equ $ - $$

utmp_buf: times UTMP_SIZE db 0
char_buf: db 0, 0

mem_size equ $ - $$
