; ============================================================
; fusers_unified.asm — GNU-compatible 'users' command
; Builds with: nasm -f bin unified/fusers_unified.asm -o fusers
;
; Reads /var/run/utmp (or a file argument), parses utmp entries,
; extracts usernames from USER_PROCESS entries, sorts them,
; and prints them space-separated followed by a newline.
; ============================================================

BITS 64
ORG 0x400000

%define SYS_READ        0
%define SYS_WRITE       1
%define SYS_OPEN        2
%define SYS_CLOSE       3
%define SYS_EXIT       60

%define STDIN           0
%define STDOUT          1
%define STDERR          2

%define UTMP_ENTRY_SIZE 384
%define UTMP_TYPE_OFF   0
%define UTMP_USER_OFF   44
%define UT_NAMESIZE     32
%define USER_PROCESS    7

%define BASE_ADDR       0x400000
%define BSS_ADDR        0x800000
%define BSS_SIZE        65536

; BSS layout:
;   0x0000 - 0x3FFF  : utmp read buffer (16384 bytes, ~42 entries)
;   0x4000 - 0x7FFF  : user name table (up to 512 names * 32 bytes = 16384)
;   0x8000 - 0xBFFF  : output buffer (16384 bytes)
;   0xC000 - 0xFFFF  : scratch / utmp entry read buf

%define OFF_UTMP_BUF    0x0000
%define UTMP_BUF_SIZE   16384
%define OFF_NAME_TABLE  0x4000
%define NAME_TABLE_SIZE 16384
%define OFF_OUTPUT_BUF  0x8000
%define OUTPUT_BUF_SIZE 16384
%define MAX_USERS       512

; ── ELF header ──
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
    dw 64, 56, 3, 64, 0, 0

phdr:
    ; PT_LOAD: code + rodata (rx)
    dd 1, 5
    dq 0, BASE_ADDR, BASE_ADDR, file_size, file_size, 0x200000

    ; PT_LOAD: bss (rw)
    dd 1, 6
    dq 0, BSS_ADDR, BSS_ADDR, 0, BSS_SIZE, 0x200000

    ; PT_GNU_STACK: non-executable stack
    dd 0x6474e551, 6
    dq 0, 0, 0, 0, 0, 0x10

; ============================================================
_start:
    ; r14 = argc, r15 = &argv[0]
    mov     r14, [rsp]
    lea     r15, [rsp + 8]

    ; Default utmp path
    mov     r12, path_utmp

    ; Parse arguments
    cmp     r14, 1
    jbe     .do_users           ; no args → use default utmp

    ; Check argv[1]
    mov     r13, [r15 + 8]
    cmp     byte [r13], '-'
    jne     .got_file_arg       ; not starting with '-' → file argument

    cmp     byte [r13 + 1], '-'
    je      .check_long_option
    cmp     byte [r13 + 1], 0
    je      .got_file_arg       ; bare "-" treated as file
    jmp     .err_invalid_option ; -x invalid short option

.check_long_option:
    cmp     byte [r13 + 2], 0
    je      .handle_double_dash ; bare "--"

    mov     rdi, r13
    mov     rsi, str_help_flag
    call    str_eq_func
    test    rax, rax
    jnz     .show_help

    mov     rdi, r13
    mov     rsi, str_version_flag
    call    str_eq_func
    test    rax, rax
    jnz     .show_version

    jmp     .err_unrecognized

.handle_double_dash:
    ; After "--", next arg is file, or no arg → use default
    cmp     r14, 2
    jbe     .do_users
    mov     r12, [r15 + 16]     ; argv[2] is the file
    cmp     r14, 3
    jbe     .do_users
    ; extra operand
    mov     r13, [r15 + 24]
    jmp     .err_extra_operand

.got_file_arg:
    mov     r12, r13            ; argv[1] is the utmp file
    cmp     r14, 2
    jbe     .do_users
    ; Check if argv[2] is another file → extra operand error
    mov     r13, [r15 + 16]
    jmp     .err_extra_operand

; ── Help ──
.show_help:
    mov     rdi, STDOUT
    mov     rsi, str_help
    mov     rdx, str_help_len
    call    do_write
    xor     rdi, rdi
    jmp     do_exit

; ── Version ──
.show_version:
    mov     rdi, STDOUT
    mov     rsi, str_version
    mov     rdx, str_version_len
    call    do_write
    xor     rdi, rdi
    jmp     do_exit

; ── Error: unrecognized option ──
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

; ── Error: invalid option ──
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

; ── Error: extra operand ──
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
    mov     rsi, str_sq_uni_nl
    mov     rdx, 4
    call    do_write_err
    jmp     .err_try_exit

.err_try_exit:
    mov     rsi, str_try
    mov     rdx, str_try_len
    call    do_write_err
    mov     rdi, 1
    jmp     do_exit

; ============================================================
; Main logic: read utmp, extract USER_PROCESS names, sort, print
; ============================================================
.do_users:
    ; r12 = path to utmp file
    ; rbx = user count (stored in name table)

    xor     ebx, ebx            ; user count = 0

    ; Open the utmp file
    mov     rax, SYS_OPEN
    mov     rdi, r12
    xor     rsi, rsi            ; O_RDONLY
    xor     rdx, rdx
    syscall
    test    rax, rax
    js      .print_newline      ; file doesn't exist → just print newline (GNU compat)

    mov     r12, rax            ; r12 = fd

    ; Read the entire utmp file in chunks
.read_loop:
    mov     rdi, r12
    mov     rsi, BSS_ADDR + OFF_UTMP_BUF
    mov     rdx, UTMP_BUF_SIZE
    call    do_read
    test    rax, rax
    jle     .done_reading

    ; rax = bytes read
    mov     r14, rax            ; r14 = bytes read
    xor     r15d, r15d          ; r15 = offset into buffer

.parse_entries:
    ; Check if we have a full entry left
    mov     rax, r14
    sub     rax, r15
    cmp     rax, UTMP_ENTRY_SIZE
    jl      .read_loop          ; not enough for a full entry, read more

    ; Check ut_type == USER_PROCESS (7)
    mov     eax, [BSS_ADDR + OFF_UTMP_BUF + r15 + UTMP_TYPE_OFF]
    cmp     eax, USER_PROCESS
    jne     .next_entry

    ; Check we haven't exceeded max users
    cmp     ebx, MAX_USERS
    jge     .next_entry

    ; Copy username (up to 32 bytes) to name table
    lea     rsi, [BSS_ADDR + OFF_UTMP_BUF + r15 + UTMP_USER_OFF]
    ; Calculate destination: BSS_ADDR + OFF_NAME_TABLE + (user_count * 32)
    mov     eax, ebx
    shl     eax, 5              ; * 32
    lea     rdi, [BSS_ADDR + OFF_NAME_TABLE + rax]
    ; Copy UT_NAMESIZE bytes
    xor     ecx, ecx
.copy_name:
    cmp     ecx, UT_NAMESIZE
    jge     .copy_done
    movzx   edx, byte [rsi + rcx]
    mov     [rdi + rcx], dl
    inc     ecx
    jmp     .copy_name
.copy_done:
    ; Ensure null termination
    mov     byte [rdi + UT_NAMESIZE - 1], 0
    ; Skip empty usernames
    cmp     byte [rdi], 0
    je      .next_entry
    inc     ebx                 ; user count++

.next_entry:
    add     r15, UTMP_ENTRY_SIZE
    jmp     .parse_entries

.done_reading:
    ; Close the file
    mov     rax, SYS_CLOSE
    mov     rdi, r12
    syscall

    ; If no users, just print newline
    test    ebx, ebx
    jz      .print_newline

    ; ── Sort the usernames (bubble sort) ──
    ; ebx = count
    mov     r14d, ebx           ; r14 = count
    cmp     r14d, 1
    jle     .print_users        ; 0 or 1 users → no sort needed

.bubble_outer:
    xor     ecx, ecx            ; swapped = false
    mov     r15d, 0             ; i = 0

.bubble_inner:
    lea     eax, [r15d + 1]
    cmp     eax, r14d
    jge     .bubble_check

    ; Compare name[i] vs name[i+1]
    mov     eax, r15d
    shl     eax, 5
    lea     rsi, [BSS_ADDR + OFF_NAME_TABLE + rax]
    add     eax, 32
    lea     rdi, [BSS_ADDR + OFF_NAME_TABLE + rax]

    ; strcmp(rsi, rdi) — if rsi > rdi, swap
    push    rcx
    push    r15
    call    strcmp_func
    pop     r15
    pop     rcx
    ; rax > 0 means rsi > rdi → swap
    test    rax, rax
    jle     .no_swap

    ; Swap 32-byte name entries
    mov     eax, r15d
    shl     eax, 5
    lea     rsi, [BSS_ADDR + OFF_NAME_TABLE + rax]
    lea     rdi, [rsi + 32]

    ; Swap using stack as temp (32 bytes)
    push    rcx
    xor     ecx, ecx
.swap_loop:
    cmp     ecx, 32
    jge     .swap_done
    movzx   edx, byte [rsi + rcx]
    movzx   r8d, byte [rdi + rcx]
    mov     [rsi + rcx], r8b
    mov     [rdi + rcx], dl
    inc     ecx
    jmp     .swap_loop
.swap_done:
    pop     rcx
    mov     ecx, 1              ; swapped = true

.no_swap:
    inc     r15d
    jmp     .bubble_inner

.bubble_check:
    test    ecx, ecx
    jnz     .bubble_outer       ; if swapped, repeat

; ── Print users ──
.print_users:
    ; Build output in output buffer
    xor     r15d, r15d          ; output position
    xor     ecx, ecx            ; user index

.print_loop:
    cmp     ecx, r14d
    jge     .flush_output

    ; If not the first user, add a space separator
    test    ecx, ecx
    jz      .no_space
    mov     byte [BSS_ADDR + OFF_OUTPUT_BUF + r15], ' '
    inc     r15d
.no_space:

    ; Copy username to output buffer
    push    rcx
    mov     eax, ecx
    shl     eax, 5
    lea     rsi, [BSS_ADDR + OFF_NAME_TABLE + rax]

.copy_to_output:
    movzx   edx, byte [rsi]
    test    dl, dl
    jz      .copy_to_output_done
    mov     [BSS_ADDR + OFF_OUTPUT_BUF + r15], dl
    inc     r15d
    inc     rsi
    ; Safety: don't overflow output buffer
    cmp     r15d, OUTPUT_BUF_SIZE - 2
    jge     .copy_to_output_done
    jmp     .copy_to_output

.copy_to_output_done:
    pop     rcx
    inc     ecx
    jmp     .print_loop

.flush_output:
    ; Add trailing newline
    mov     byte [BSS_ADDR + OFF_OUTPUT_BUF + r15], 10
    inc     r15d

    ; Write the output
    mov     rdi, STDOUT
    mov     rsi, BSS_ADDR + OFF_OUTPUT_BUF
    mov     edx, r15d
    call    do_write

    xor     rdi, rdi
    jmp     do_exit

.print_newline:
    mov     rdi, STDOUT
    mov     rsi, str_newline
    mov     rdx, 1
    call    do_write
    xor     rdi, rdi
    jmp     do_exit

; ============================================================
; Utility functions
; ============================================================

; do_write: write(rdi=fd, rsi=buf, rdx=len)
do_write:
    mov     rax, SYS_WRITE
    syscall
    cmp     rax, -4             ; EINTR
    je      do_write
    ret

do_write_err:
    mov     rdi, STDERR
    jmp     do_write

; do_read: read(rdi=fd, rsi=buf, rdx=len) → rax=bytes
do_read:
    mov     rax, SYS_READ
    syscall
    cmp     rax, -4
    je      do_read
    ret

do_exit:
    mov     rax, SYS_EXIT
    syscall

; str_len_func: rdi=str → rax=length
str_len_func:
    xor     rax, rax
.sl_loop:
    cmp     byte [rdi + rax], 0
    je      .sl_done
    inc     rax
    jmp     .sl_loop
.sl_done:
    ret

; str_eq_func: rdi=s1, rsi=s2 → rax=1 if equal, 0 otherwise
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

; strcmp_func: rsi=s1, rdi=s2 → rax: <0 if s1<s2, 0 if equal, >0 if s1>s2
strcmp_func:
    xor     rcx, rcx
.sc_loop:
    movzx   eax, byte [rsi + rcx]
    movzx   edx, byte [rdi + rcx]
    sub     eax, edx
    jnz     .sc_done
    cmp     byte [rsi + rcx], 0
    je      .sc_done
    inc     rcx
    jmp     .sc_loop
.sc_done:
    movsx   rax, eax
    ret

; ============================================================
; Data section
; ============================================================

; @@DATA_START@@
str_help:
    db "Usage: users [OPTION]... [FILE]", 10
    db "Output who is currently logged in according to FILE.", 10
    db "If FILE is not specified, use /var/run/utmp.  /var/log/wtmp as FILE is common.", 10, 10
    db "      --help        display this help and exit", 10
    db "      --version     output version information and exit", 10, 10
    db "GNU coreutils online help: <https://www.gnu.org/software/coreutils/>", 10
    db "Full documentation <https://www.gnu.org/software/coreutils/users>", 10
    db "or available locally via: info '(coreutils) users invocation'", 10
str_help_len equ $ - str_help

str_version:
    db "users (GNU coreutils) 9.7", 10
    db "Packaged by Debian (9.7-3)", 10
    db "Copyright (C) 2025 Free Software Foundation, Inc.", 10
    db "License GPLv3+: GNU GPL version 3 or later <https://gnu.org/licenses/gpl.html>.", 10
    db "This is free software: you are free to change and redistribute it.", 10
    db "There is NO WARRANTY, to the extent permitted by law.", 10, 10
    db "Written by Joseph Arceneaux and David MacKenzie.", 10
str_version_len equ $ - str_version

str_prefix:      db "users: "
str_prefix_len   equ $ - str_prefix
str_unrecog:     db "unrecognized option '"
str_unrecog_len  equ $ - str_unrecog
str_invalid:     db "invalid option -- '"
str_invalid_len  equ $ - str_invalid
str_extra:       db "extra operand ", 0xE2, 0x80, 0x98
str_extra_len    equ $ - str_extra
str_sq_nl:       db "'", 10
str_sq_uni_nl:   db 0xE2, 0x80, 0x99, 10
str_try:         db "Try 'users --help' for more information.", 10
str_try_len      equ $ - str_try
; @@DATA_END@@

str_newline:     db 10
path_utmp:       db "/var/run/utmp", 0
str_help_flag:   db "--help", 0
str_version_flag: db "--version", 0

file_size equ $ - $$
