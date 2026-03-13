; ============================================================
; fstty_unified.asm — GNU-compatible 'stty' command
; Builds with: nasm -f bin fstty_unified.asm -o fstty
;
; stty: change and print terminal line settings
;
; Usage: stty [-F DEVICE | --file=DEVICE] [SETTING]...
;        stty [-F DEVICE | --file=DEVICE] [-a|--all|-g|--save]
;
; Syscalls: ioctl(16) with TCGETS(0x5401)/TCSETS(0x5402)
; ============================================================

BITS 64
ORG 0x400000

%define SYS_WRITE       1
%define SYS_IOCTL      16
%define SYS_EXIT       60
%define SYS_RT_SIGPROCMASK 14

%define TCGETS          0x5401
%define TCSETS          0x5402
%define TIOCGWINSZ      0x5413

%define STDOUT          1
%define STDERR          2
%define STDIN           0
%define SIG_BLOCK       0
%define SIGPIPE        13

; struct termios offsets (Linux x86-64)
; c_iflag: 0 (4 bytes)
; c_oflag: 4 (4 bytes)
; c_cflag: 8 (4 bytes)
; c_lflag: 12 (4 bytes)
; c_line:  16 (1 byte)
; c_cc:    17 (32 bytes)
; c_ispeed: 52 (4 bytes)  [kernel termios2]
; c_ospeed: 56 (4 bytes)

; c_cflag baud bits
%define CBAUD    0o010017
%define B0       0o000000
%define B50      0o000001
%define B75      0o000002
%define B110     0o000003
%define B134     0o000004
%define B150     0o000005
%define B200     0o000006
%define B300     0o000007
%define B600     0o000010
%define B1200    0o000011
%define B1800    0o000012
%define B2400    0o000013
%define B4800    0o000014
%define B9600    0o000015
%define B19200   0o000016
%define B38400   0o000017
%define B115200  0o010002

; c_lflag bits
%define ECHO     0o000010
%define ICANON   0o000002
%define ISIG     0o000001
%define ECHOE    0o000020
%define ECHOK    0o000040
%define ECHONL   0o000100
%define IEXTEN   0o100000

; c_iflag bits
%define ICRNL    0o000400
%define IGNCR    0o000200
%define INLCR    0o000100
%define IXON     0o002000

; c_oflag bits
%define OPOST    0o000001
%define ONLCR    0o000004

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

    ; Default: fd = stdin
    xor     r12d, r12d          ; mode: 0=default, 1=all, 2=save
    mov     r13d, STDIN         ; fd to use

    mov     ecx, 1

    ; Check --help / --version first
    cmp     r14d, 2
    jl      .no_args
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
    jge     .no_args
    mov     rdi, [r15 + rcx*8]

    ; -a / --all
    cmp     byte [rdi], '-'
    jne     .do_settings
    cmp     byte [rdi + 1], 'a'
    jne     .check_g
    cmp     byte [rdi + 2], 0
    jne     .check_long_all
    mov     r12d, 1
    inc     ecx
    jmp     .parse_opts

.check_long_all:
    push    rcx
    mov     rsi, str_all_flag
    call    str_eq
    test    eax, eax
    pop     rcx
    jz      .check_g
    mov     r12d, 1
    inc     ecx
    jmp     .parse_opts

.check_g:
    cmp     byte [rdi + 1], 'g'
    jne     .check_F
    cmp     byte [rdi + 2], 0
    jne     .check_save
    mov     r12d, 2
    inc     ecx
    jmp     .parse_opts

.check_save:
    push    rcx
    mov     rsi, str_save_flag
    call    str_eq
    test    eax, eax
    pop     rcx
    jz      .check_F
    mov     r12d, 2
    inc     ecx
    jmp     .parse_opts

.check_F:
    cmp     byte [rdi + 1], 'F'
    jne     .do_settings
    ; -F DEVICE: skip; use stdin for now
    add     ecx, 2
    jmp     .parse_opts

.no_args:
    ; Get termios
    mov     eax, SYS_IOCTL
    mov     edi, r13d
    mov     esi, TCGETS
    lea     rdx, [termios_buf]
    syscall
    test    rax, rax
    js      .not_tty

    ; Get window size
    mov     eax, SYS_IOCTL
    mov     edi, r13d
    mov     esi, TIOCGWINSZ
    lea     rdx, [winsize_buf]
    syscall

    cmp     r12d, 2
    je      .print_save
    cmp     r12d, 1
    je      .print_all

    ; Default: print speed + line discipline + changed settings
    call    .print_speed
    mov     edi, STDOUT
    mov     rsi, str_newline
    mov     edx, 1
    call    do_write
    xor     edi, edi
    jmp     do_exit

.print_save:
    ; Print in stty-readable form (hex dump of termios)
    ; Format: iflag:oflag:cflag:lflag:cc bytes as hex
    lea     rsi, [termios_buf]
    mov     eax, [rsi]          ; c_iflag
    call    .print_hex32
    mov     edi, STDOUT
    mov     rsi, str_colon
    mov     edx, 1
    call    do_write
    lea     rsi, [termios_buf + 4]
    mov     eax, [rsi]          ; c_oflag
    call    .print_hex32
    mov     edi, STDOUT
    mov     rsi, str_colon
    mov     edx, 1
    call    do_write
    lea     rsi, [termios_buf + 8]
    mov     eax, [rsi]          ; c_cflag
    call    .print_hex32
    mov     edi, STDOUT
    mov     rsi, str_colon
    mov     edx, 1
    call    do_write
    lea     rsi, [termios_buf + 12]
    mov     eax, [rsi]          ; c_lflag
    call    .print_hex32
    ; Print cc bytes
    mov     r8d, 0
.save_cc:
    cmp     r8d, 32
    jge     .save_done
    mov     edi, STDOUT
    mov     rsi, str_colon
    mov     edx, 1
    push    r8
    call    do_write
    pop     r8
    movzx   eax, byte [termios_buf + 17 + r8]
    push    r8
    call    .print_hex8
    pop     r8
    inc     r8d
    jmp     .save_cc
.save_done:
    mov     edi, STDOUT
    mov     rsi, str_newline
    mov     edx, 1
    call    do_write
    xor     edi, edi
    jmp     do_exit

.print_all:
    ; Print speed
    call    .print_speed
    mov     edi, STDOUT
    mov     rsi, str_semicolon_sp
    mov     edx, 2
    call    do_write

    ; Print rows and columns
    mov     edi, STDOUT
    mov     rsi, str_rows
    mov     edx, str_rows_len
    call    do_write
    movzx   eax, word [winsize_buf]   ; ws_row
    call    .print_uint
    mov     edi, STDOUT
    mov     rsi, str_semicolon_sp
    mov     edx, 2
    call    do_write
    mov     edi, STDOUT
    mov     rsi, str_cols
    mov     edx, str_cols_len
    call    do_write
    movzx   eax, word [winsize_buf + 2]  ; ws_col
    call    .print_uint
    mov     edi, STDOUT
    mov     rsi, str_semicolon_nl
    mov     edx, 2
    call    do_write

    ; Print key settings flags
    ; c_lflag
    mov     eax, [termios_buf + 12]
    push    rax
    test    eax, ECHO
    jnz     .echo_on
    mov     edi, STDOUT
    mov     rsi, str_neg_echo
    mov     edx, str_neg_echo_len
    call    do_write
    jmp     .check_icanon
.echo_on:
    mov     edi, STDOUT
    mov     rsi, str_echo
    mov     edx, str_echo_len
    call    do_write
.check_icanon:
    pop     rax
    push    rax
    test    eax, ICANON
    jnz     .icanon_on
    mov     edi, STDOUT
    mov     rsi, str_neg_icanon
    mov     edx, str_neg_icanon_len
    call    do_write
    jmp     .check_isig
.icanon_on:
    mov     edi, STDOUT
    mov     rsi, str_icanon
    mov     edx, str_icanon_len
    call    do_write
.check_isig:
    pop     rax
    test    eax, ISIG
    jnz     .isig_on
    mov     edi, STDOUT
    mov     rsi, str_neg_isig
    mov     edx, str_neg_isig_len
    call    do_write
    jmp     .done_lflag
.isig_on:
    mov     edi, STDOUT
    mov     rsi, str_isig
    mov     edx, str_isig_len
    call    do_write
.done_lflag:
    mov     edi, STDOUT
    mov     rsi, str_newline
    mov     edx, 1
    call    do_write
    xor     edi, edi
    jmp     do_exit

.do_settings:
    ; Apply terminal settings changes
    ; Get current termios first
    mov     eax, SYS_IOCTL
    mov     edi, r13d
    mov     esi, TCGETS
    lea     rdx, [termios_buf]
    syscall
    test    rax, rax
    js      .not_tty

.setting_loop:
    cmp     ecx, r14d
    jge     .apply_settings
    mov     rdi, [r15 + rcx*8]

    ; Check for "raw"
    push    rcx
    mov     rsi, str_raw
    call    str_eq
    test    eax, eax
    pop     rcx
    jnz     .set_raw

    ; Check for "cooked" / "sane"
    push    rcx
    mov     rdi, [r15 + rcx*8]
    mov     rsi, str_cooked
    call    str_eq
    test    eax, eax
    pop     rcx
    jnz     .set_cooked
    push    rcx
    mov     rdi, [r15 + rcx*8]
    mov     rsi, str_sane
    call    str_eq
    test    eax, eax
    pop     rcx
    jnz     .set_cooked

    ; Check for "echo"
    mov     rdi, [r15 + rcx*8]
    cmp     byte [rdi], '-'
    je      .check_neg_setting
    push    rcx
    mov     rsi, str_echo_setting
    call    str_eq
    test    eax, eax
    pop     rcx
    jnz     .set_echo_on

    ; Unknown setting — skip
    inc     ecx
    jmp     .setting_loop

.check_neg_setting:
    ; "-echo", "-icanon", etc.
    inc     rdi
    push    rcx
    mov     rsi, str_echo_setting
    call    str_eq
    test    eax, eax
    pop     rcx
    jnz     .set_echo_off
    mov     rdi, [r15 + rcx*8]
    inc     rdi
    push    rcx
    mov     rsi, str_icanon_setting
    call    str_eq
    test    eax, eax
    pop     rcx
    jnz     .set_icanon_off
    inc     ecx
    jmp     .setting_loop

.set_raw:
    ; Raw mode: clear ICANON, ECHO, ECHOE, ECHOK, ISIG, IEXTEN
    and     dword [termios_buf + 12], ~(ICANON | ECHO | ECHOE | ECHOK | ISIG | IEXTEN)
    and     dword [termios_buf], ~(ICRNL | IXON)
    and     dword [termios_buf + 4], ~(OPOST)
    inc     ecx
    jmp     .setting_loop

.set_cooked:
    ; Cooked mode: set ICANON, ECHO, ISIG, IEXTEN
    or      dword [termios_buf + 12], (ICANON | ECHO | ISIG | IEXTEN)
    or      dword [termios_buf], (ICRNL | IXON)
    or      dword [termios_buf + 4], (OPOST | ONLCR)
    inc     ecx
    jmp     .setting_loop

.set_echo_on:
    or      dword [termios_buf + 12], ECHO
    inc     ecx
    jmp     .setting_loop

.set_echo_off:
    and     dword [termios_buf + 12], ~ECHO
    inc     ecx
    jmp     .setting_loop

.set_icanon_off:
    and     dword [termios_buf + 12], ~ICANON
    inc     ecx
    jmp     .setting_loop

.apply_settings:
    mov     eax, SYS_IOCTL
    mov     edi, r13d
    mov     esi, TCSETS
    lea     rdx, [termios_buf]
    syscall
    test    rax, rax
    js      .ioctl_failed
    xor     edi, edi
    jmp     do_exit

.not_tty:
    mov     rsi, str_prefix
    mov     edx, str_prefix_len
    call    write_err
    mov     rsi, str_not_tty
    mov     edx, str_not_tty_len
    call    write_err
    mov     edi, 1
    jmp     do_exit

.ioctl_failed:
    mov     rsi, str_prefix
    mov     edx, str_prefix_len
    call    write_err
    mov     rsi, str_ioctl_fail
    mov     edx, str_ioctl_fail_len
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

; ---- print_speed subroutine ----
.print_speed:
    mov     edi, STDOUT
    mov     rsi, str_speed
    mov     edx, str_speed_len
    call    do_write
    ; Extract baud rate from c_cflag
    mov     eax, [termios_buf + 8]
    and     eax, CBAUD
    ; Map baud constant to string
    cmp     eax, B9600
    je      .speed_9600
    cmp     eax, B38400
    je      .speed_38400
    cmp     eax, B19200
    je      .speed_19200
    cmp     eax, B1200
    je      .speed_1200
    cmp     eax, B4800
    je      .speed_4800
    cmp     eax, B2400
    je      .speed_2400
    cmp     eax, B300
    je      .speed_300
    cmp     eax, B600
    je      .speed_600
    cmp     eax, B115200
    je      .speed_115200
    ; Default
    mov     rsi, str_sp_38400
    mov     edx, str_sp_38400_len
    jmp     .speed_print
.speed_9600:
    mov     rsi, str_sp_9600
    mov     edx, str_sp_9600_len
    jmp     .speed_print
.speed_38400:
    mov     rsi, str_sp_38400
    mov     edx, str_sp_38400_len
    jmp     .speed_print
.speed_19200:
    mov     rsi, str_sp_19200
    mov     edx, str_sp_19200_len
    jmp     .speed_print
.speed_1200:
    mov     rsi, str_sp_1200
    mov     edx, str_sp_1200_len
    jmp     .speed_print
.speed_4800:
    mov     rsi, str_sp_4800
    mov     edx, str_sp_4800_len
    jmp     .speed_print
.speed_2400:
    mov     rsi, str_sp_2400
    mov     edx, str_sp_2400_len
    jmp     .speed_print
.speed_300:
    mov     rsi, str_sp_300
    mov     edx, str_sp_300_len
    jmp     .speed_print
.speed_600:
    mov     rsi, str_sp_600
    mov     edx, str_sp_600_len
    jmp     .speed_print
.speed_115200:
    mov     rsi, str_sp_115200
    mov     edx, str_sp_115200_len
.speed_print:
    mov     edi, STDOUT
    call    do_write
    mov     edi, STDOUT
    mov     rsi, str_baud
    mov     edx, str_baud_len
    call    do_write
    ret

; ---- print_hex32 ----
.print_hex32:
    ; eax = value to print
    push    rax
    shr     eax, 16
    call    .print_hex16
    pop     rax
    and     eax, 0xFFFF
.print_hex16:
    push    rax
    shr     eax, 8
    call    .print_hex8
    pop     rax
    and     eax, 0xFF
.print_hex8:
    push    rax
    shr     eax, 4
    and     eax, 0xF
    mov     al, [hex_chars + rax]
    mov     [hex_buf], al
    pop     rax
    and     eax, 0xF
    mov     al, [hex_chars + rax]
    mov     [hex_buf + 1], al
    mov     edi, STDOUT
    mov     rsi, hex_buf
    mov     edx, 2
    call    do_write
    ret

; ---- print_uint ----
.print_uint:
    ; eax = unsigned value
    lea     rsi, [num_buf + 20]
    mov     byte [rsi], 0
    mov     ecx, eax
    mov     ebx, 10
.pu_loop:
    xor     edx, edx
    mov     eax, ecx
    div     ebx
    mov     ecx, eax
    add     dl, '0'
    dec     rsi
    mov     [rsi], dl
    test    ecx, ecx
    jnz     .pu_loop
    lea     rdx, [num_buf + 20]
    sub     rdx, rsi
    mov     edi, STDOUT
    call    do_write
    ret

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
    db "Usage: stty [-F DEVICE | --file=DEVICE] [SETTING]...", 10
    db "  or:  stty [-F DEVICE | --file=DEVICE] [-a|--all|-g|--save]", 10
    db "Print or change terminal line settings.", 10, 10
    db "Mandatory arguments to long options are mandatory for short options too.", 10
    db "  -a, --all          print all current settings in human-readable form", 10
    db "  -g, --save         print all current settings in a stty-readable form", 10
    db "  -F, --file=DEVICE  open and use the specified DEVICE instead of stdin", 10
    db "      --help         display this help and exit", 10
    db "      --version      output version information and exit", 10, 10
    db "Optional - before SETTING indicates negation.  An * marks non-POSIX", 10
    db "settings.", 10, 10
    db "GNU coreutils online help: <https://www.gnu.org/software/coreutils/>", 10
    db "Full documentation <https://www.gnu.org/software/coreutils/stty>", 10
    db "or available locally via: info '(coreutils) stty invocation'", 10
str_help_len equ $ - str_help

str_version:
    db "stty (GNU coreutils) 9.7", 10
    db "Copyright (C) 2025 Free Software Foundation, Inc.", 10
    db "License GPLv3+: GNU GPL version 3 or later <https://gnu.org/licenses/gpl.html>.", 10
    db "This is free software: you are free to change and redistribute it.", 10
    db "There is NO WARRANTY, to the extent permitted by law.", 10, 10
    db "Written by David MacKenzie.", 10
str_version_len equ $ - str_version
; @@DATA_END@@

str_prefix:         db "stty: "
str_prefix_len      equ $ - str_prefix
str_not_tty:        db "standard input: Inappropriate ioctl for device", 10
str_not_tty_len     equ $ - str_not_tty
str_ioctl_fail:     db "unable to perform all requested operations", 10
str_ioctl_fail_len  equ $ - str_ioctl_fail

str_help_flag:      db "--help", 0
str_version_flag:   db "--version", 0
str_all_flag:       db "--all", 0
str_save_flag:      db "--save", 0

str_speed:          db "speed "
str_speed_len       equ $ - str_speed
str_baud:           db " baud;"
str_baud_len        equ $ - str_baud
str_newline:        db 10
str_colon:          db ":"
str_semicolon_sp:   db "; "
str_semicolon_nl:   db ";", 10

str_rows:           db "rows "
str_rows_len        equ $ - str_rows
str_cols:           db "columns "
str_cols_len        equ $ - str_cols

str_echo:           db " echo"
str_echo_len        equ $ - str_echo
str_neg_echo:       db " -echo"
str_neg_echo_len    equ $ - str_neg_echo
str_icanon:         db " icanon"
str_icanon_len      equ $ - str_icanon
str_neg_icanon:     db " -icanon"
str_neg_icanon_len  equ $ - str_neg_icanon
str_isig:           db " isig"
str_isig_len        equ $ - str_isig
str_neg_isig:       db " -isig"
str_neg_isig_len    equ $ - str_neg_isig

str_raw:            db "raw", 0
str_cooked:         db "cooked", 0
str_sane:           db "sane", 0
str_echo_setting:   db "echo", 0
str_icanon_setting: db "icanon", 0

str_sp_300:         db "300"
str_sp_300_len      equ $ - str_sp_300
str_sp_600:         db "600"
str_sp_600_len      equ $ - str_sp_600
str_sp_1200:        db "1200"
str_sp_1200_len     equ $ - str_sp_1200
str_sp_2400:        db "2400"
str_sp_2400_len     equ $ - str_sp_2400
str_sp_4800:        db "4800"
str_sp_4800_len     equ $ - str_sp_4800
str_sp_9600:        db "9600"
str_sp_9600_len     equ $ - str_sp_9600
str_sp_19200:       db "19200"
str_sp_19200_len    equ $ - str_sp_19200
str_sp_38400:       db "38400"
str_sp_38400_len    equ $ - str_sp_38400
str_sp_115200:      db "115200"
str_sp_115200_len   equ $ - str_sp_115200

hex_chars:          db "0123456789abcdef"

file_size equ $ - $$

termios_buf: times 64 db 0
winsize_buf: times 8 db 0
hex_buf: times 4 db 0
num_buf: times 32 db 0

mem_size equ $ - $$
