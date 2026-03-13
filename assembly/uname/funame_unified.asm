; ============================================================
; funame_unified.asm — GNU-compatible 'uname' command
; Builds with: nasm -f bin funame_unified.asm -o funame
;
; uname: Print system information using the uname() syscall.
;
; Register allocation:
;   r14d = argc, r15 = argv
;   ebx  = field bitmask (bit 0=s, 1=n, 2=r, 3=v, 4=m, 5=p, 6=i, 7=o)
;   r12d = need_space flag (for separating fields)
;   r13  = scratch
; ============================================================

BITS 64
ORG 0x400000

%define SYS_WRITE       1
%define SYS_UNAME      63
%define SYS_EXIT       60
%define SYS_RT_SIGPROCMASK 14

%define STDOUT          1
%define STDERR          2
%define SIG_BLOCK       0
%define SIGPIPE        13

%define BSS_ADDR    0x500000
%define BSS_SIZE    4096
%define UTSNAME_BUF BSS_ADDR          ; 390 bytes for struct utsname

; struct utsname field offsets (each field is 65 bytes, NUL-terminated)
%define UTS_SYSNAME     0
%define UTS_NODENAME   65
%define UTS_RELEASE   130
%define UTS_VERSION   195
%define UTS_MACHINE   260

; Field bitmask bits
%define FLAG_S  0   ; sysname
%define FLAG_N  1   ; nodename
%define FLAG_R  2   ; release
%define FLAG_V  3   ; version
%define FLAG_M  4   ; machine
%define FLAG_P  5   ; processor
%define FLAG_I  6   ; hardware-platform
%define FLAG_O  7   ; operating-system
%define FLAG_ALL 0xFF
; -a omits -p and -i when they are "unknown" (always on Linux)
%define FLAG_ALL_A (FLAG_ALL & ~((1 << FLAG_P) | (1 << FLAG_I)))

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
    dw 64, 56, 3, 64, 0, 0

; --- Program Headers ---
phdr:
    ; PT_LOAD: code + data (R+X)
    dd 1, 5
    dq 0, $$, $$, file_size, file_size, 0x200000

    ; PT_LOAD: BSS (R+W)
    dd 1, 6
    dq 0, BSS_ADDR, BSS_ADDR, 0, BSS_SIZE, 0x200000

    ; PT_GNU_STACK (NX)
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

    ; Initialize field bitmask
    xor     ebx, ebx            ; field bitmask
    mov     ecx, 1              ; arg index

; Parse options
.parse_opts:
    cmp     ecx, r14d
    jge     .done_opts
    mov     rdi, [r15 + rcx*8]
    cmp     byte [rdi], '-'
    jne     .err_extra_operand
    cmp     byte [rdi + 1], 0
    je      .err_extra_operand   ; bare "-" is extra operand
    cmp     byte [rdi + 1], '-'
    je      .check_long

    ; Short options: -s, -n, -r, -v, -m, -p, -i, -o, -a
    inc     rdi
.short_loop:
    movzx   eax, byte [rdi]
    test    al, al
    jz      .next_opt
    cmp     al, 's'
    je      .set_s
    cmp     al, 'n'
    je      .set_n
    cmp     al, 'r'
    je      .set_r
    cmp     al, 'v'
    je      .set_v
    cmp     al, 'm'
    je      .set_m
    cmp     al, 'p'
    je      .set_p
    cmp     al, 'i'
    je      .set_i
    cmp     al, 'o'
    je      .set_o
    cmp     al, 'a'
    je      .set_a
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

.set_s:
    or      bl, (1 << FLAG_S)
    inc     rdi
    jmp     .short_loop
.set_n:
    or      bl, (1 << FLAG_N)
    inc     rdi
    jmp     .short_loop
.set_r:
    or      bl, (1 << FLAG_R)
    inc     rdi
    jmp     .short_loop
.set_v:
    or      bl, (1 << FLAG_V)
    inc     rdi
    jmp     .short_loop
.set_m:
    or      bl, (1 << FLAG_M)
    inc     rdi
    jmp     .short_loop
.set_p:
    or      bl, (1 << FLAG_P)
    inc     rdi
    jmp     .short_loop
.set_i:
    or      bl, (1 << FLAG_I)
    inc     rdi
    jmp     .short_loop
.set_o:
    or      bl, (1 << FLAG_O)
    inc     rdi
    jmp     .short_loop
.set_a:
    or      bl, FLAG_ALL_A
    inc     rdi
    jmp     .short_loop

.check_long:
    cmp     byte [rdi + 2], 0
    je      .err_extra_operand   ; bare "--" treated as extra operand by uname
    push    rcx
    mov     r9, rdi
    ; --help
    mov     rsi, str_help_flag
    call    str_eq
    test    eax, eax
    jnz     .pop_show_help
    ; --version
    mov     rdi, r9
    mov     rsi, str_version_flag
    call    str_eq
    test    eax, eax
    jnz     .pop_show_version
    ; --kernel-name
    mov     rdi, r9
    mov     rsi, str_kernel_name_flag
    call    str_eq
    test    eax, eax
    jnz     .pop_set_s
    ; --nodename
    mov     rdi, r9
    mov     rsi, str_nodename_flag
    call    str_eq
    test    eax, eax
    jnz     .pop_set_n
    ; --kernel-release
    mov     rdi, r9
    mov     rsi, str_kernel_release_flag
    call    str_eq
    test    eax, eax
    jnz     .pop_set_r
    ; --kernel-version
    mov     rdi, r9
    mov     rsi, str_kernel_version_flag
    call    str_eq
    test    eax, eax
    jnz     .pop_set_v
    ; --machine
    mov     rdi, r9
    mov     rsi, str_machine_flag
    call    str_eq
    test    eax, eax
    jnz     .pop_set_m
    ; --processor
    mov     rdi, r9
    mov     rsi, str_processor_flag
    call    str_eq
    test    eax, eax
    jnz     .pop_set_p
    ; --hardware-platform
    mov     rdi, r9
    mov     rsi, str_hwplatform_flag
    call    str_eq
    test    eax, eax
    jnz     .pop_set_i
    ; --operating-system
    mov     rdi, r9
    mov     rsi, str_opsys_flag
    call    str_eq
    test    eax, eax
    jnz     .pop_set_o
    ; --all
    mov     rdi, r9
    mov     rsi, str_all_flag
    call    str_eq
    test    eax, eax
    jnz     .pop_set_all
    ; Unrecognized long option
    pop     rcx
    mov     rsi, str_prefix
    mov     edx, str_prefix_len
    call    do_write_err
    mov     rsi, str_unrecog
    mov     edx, str_unrecog_len
    call    do_write_err
    mov     rdi, r9
    call    str_len
    mov     edx, eax
    mov     rsi, r9
    call    do_write_err
    mov     rsi, str_sq_nl
    mov     edx, 2
    call    do_write_err
    mov     rsi, str_try
    mov     edx, str_try_len
    call    do_write_err
    mov     edi, 1
    jmp     do_exit

.pop_show_help:
    pop     rcx
    mov     edi, STDOUT
    mov     rsi, str_help
    mov     edx, str_help_len
    call    do_write
    xor     edi, edi
    jmp     do_exit

.pop_show_version:
    pop     rcx
    mov     edi, STDOUT
    mov     rsi, str_version
    mov     edx, str_version_len
    call    do_write
    xor     edi, edi
    jmp     do_exit

.pop_set_s:
    pop     rcx
    or      bl, (1 << FLAG_S)
    inc     ecx
    jmp     .parse_opts
.pop_set_n:
    pop     rcx
    or      bl, (1 << FLAG_N)
    inc     ecx
    jmp     .parse_opts
.pop_set_r:
    pop     rcx
    or      bl, (1 << FLAG_R)
    inc     ecx
    jmp     .parse_opts
.pop_set_v:
    pop     rcx
    or      bl, (1 << FLAG_V)
    inc     ecx
    jmp     .parse_opts
.pop_set_m:
    pop     rcx
    or      bl, (1 << FLAG_M)
    inc     ecx
    jmp     .parse_opts
.pop_set_p:
    pop     rcx
    or      bl, (1 << FLAG_P)
    inc     ecx
    jmp     .parse_opts
.pop_set_i:
    pop     rcx
    or      bl, (1 << FLAG_I)
    inc     ecx
    jmp     .parse_opts
.pop_set_o:
    pop     rcx
    or      bl, (1 << FLAG_O)
    inc     ecx
    jmp     .parse_opts
.pop_set_all:
    pop     rcx
    or      bl, FLAG_ALL_A
    inc     ecx
    jmp     .parse_opts

.next_opt:
    inc     ecx
    jmp     .parse_opts

.err_extra_operand:
    mov     r8, rdi
    mov     rsi, str_prefix
    mov     edx, str_prefix_len
    call    do_write_err
    mov     rsi, str_extra
    mov     edx, str_extra_len
    call    do_write_err
    ; Unicode left quote U+2018
    mov     rsi, str_lquote
    mov     edx, str_lquote_len
    call    do_write_err
    mov     rdi, r8
    call    str_len
    mov     edx, eax
    mov     rsi, r8
    call    do_write_err
    ; Unicode right quote U+2019 + newline
    mov     rsi, str_rquote_nl
    mov     edx, str_rquote_nl_len
    call    do_write_err
    mov     rsi, str_try
    mov     edx, str_try_len
    call    do_write_err
    mov     edi, 1
    jmp     do_exit

.done_opts:
    ; If no flags set, default to -s
    test    bl, bl
    jnz     .do_uname
    or      bl, (1 << FLAG_S)

.do_uname:
    ; Call uname() syscall
    mov     eax, SYS_UNAME
    mov     rdi, UTSNAME_BUF
    syscall
    test    rax, rax
    js      .uname_failed

    ; Now iterate through fields and print requested ones
    xor     r12d, r12d          ; need_space = 0

    ; Field 0: sysname (bit 0)
    test    bl, (1 << FLAG_S)
    jz      .check_n
    lea     rsi, [UTSNAME_BUF + UTS_SYSNAME]
    call    .print_field

.check_n:
    test    bl, (1 << FLAG_N)
    jz      .check_r
    lea     rsi, [UTSNAME_BUF + UTS_NODENAME]
    call    .print_field

.check_r:
    test    bl, (1 << FLAG_R)
    jz      .check_v
    lea     rsi, [UTSNAME_BUF + UTS_RELEASE]
    call    .print_field

.check_v:
    test    bl, (1 << FLAG_V)
    jz      .check_m
    lea     rsi, [UTSNAME_BUF + UTS_VERSION]
    call    .print_field

.check_m:
    test    bl, (1 << FLAG_M)
    jz      .check_p
    lea     rsi, [UTSNAME_BUF + UTS_MACHINE]
    call    .print_field

.check_p:
    test    bl, (1 << FLAG_P)
    jz      .check_i
    lea     rsi, str_unknown
    call    .print_field

.check_i:
    test    bl, (1 << FLAG_I)
    jz      .check_o
    lea     rsi, str_unknown
    call    .print_field

.check_o:
    test    bl, (1 << FLAG_O)
    jz      .done_fields
    lea     rsi, str_gnu_linux
    call    .print_field

.done_fields:
    ; Print final newline
    mov     edi, STDOUT
    mov     rsi, str_newline
    mov     edx, 1
    call    do_write
    xor     edi, edi
    jmp     do_exit

.uname_failed:
    mov     rsi, str_prefix
    mov     edx, str_prefix_len
    call    do_write_err
    mov     rsi, str_uname_fail
    mov     edx, str_uname_fail_len
    call    do_write_err
    mov     edi, 1
    jmp     do_exit

; ---- print_field subroutine ----
; Input: rsi = pointer to NUL-terminated field string
; Uses r12d as need_space flag
.print_field:
    push    rsi
    ; Print space separator if not first field
    test    r12d, r12d
    jz      .pf_no_space
    mov     edi, STDOUT
    mov     rsi, str_space
    mov     edx, 1
    call    do_write
.pf_no_space:
    pop     rsi
    mov     r12d, 1             ; next field needs space
    ; Get field length
    mov     rdi, rsi
    push    rsi
    call    str_len
    pop     rsi
    mov     edx, eax
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

str_prefix_match:
    xor     r8d, r8d
.sp_loop:
    cmp     r8d, edx
    jge     .sp_match
    movzx   eax, byte [rdi + r8]
    cmp     al, byte [rsi + r8]
    jne     .sp_nomatch
    inc     r8d
    jmp     .sp_loop
.sp_match:
    mov     eax, 1
    ret
.sp_nomatch:
    xor     eax, eax
    ret

; ============================================================
; Data
; ============================================================
; @@DATA_START@@
str_help:
    db "Usage: uname [OPTION]...", 10
    db "Print certain system information.  With no OPTION, same as -s.", 10, 10
    db "  -a, --all                print all information, in the following order,", 10
    db "                             except omit -p and -i if unknown:", 10
    db "  -s, --kernel-name        print the kernel name", 10
    db "  -n, --nodename           print the network node hostname", 10
    db "  -r, --kernel-release     print the kernel release", 10
    db "  -v, --kernel-version     print the kernel version", 10
    db "  -m, --machine            print the machine hardware name", 10
    db "  -p, --processor          print the processor type (non-portable)", 10
    db "  -i, --hardware-platform  print the hardware platform (non-portable)", 10
    db "  -o, --operating-system   print the operating system", 10
    db "      --help        display this help and exit", 10
    db "      --version     output version information and exit", 10, 10
    db "GNU coreutils online help: <https://www.gnu.org/software/coreutils/>", 10
    db "Full documentation <https://www.gnu.org/software/coreutils/uname>", 10
    db "or available locally via: info '(coreutils) uname invocation'", 10
str_help_len equ $ - str_help

str_version:
    db "uname (GNU coreutils) 9.7", 10
    db "Copyright (C) 2025 Free Software Foundation, Inc.", 10
    db "License GPLv3+: GNU GPL version 3 or later <https://gnu.org/licenses/gpl.html>.", 10
    db "This is free software: you are free to change and redistribute it.", 10
    db "There is NO WARRANTY, to the extent permitted by law.", 10, 10
    db "Written by David MacKenzie.", 10
str_version_len equ $ - str_version

str_prefix:      db "uname: "
str_prefix_len   equ $ - str_prefix
str_unrecog:     db "unrecognized option '"
str_unrecog_len  equ $ - str_unrecog
str_invalid:     db "invalid option -- '"
str_invalid_len  equ $ - str_invalid
str_extra:       db "extra operand "
str_extra_len    equ $ - str_extra
str_sq_nl:       db "'", 10
str_try:         db "Try 'uname --help' for more information.", 10
str_try_len      equ $ - str_try
str_uname_fail:  db "cannot get system information", 10
str_uname_fail_len equ $ - str_uname_fail
; @@DATA_END@@

str_newline:     db 10
str_space:       db ' '
str_gnu_linux:   db "GNU/Linux", 0
str_unknown:     db "unknown", 0

; Unicode curly quotes for extra-operand error (U+2018 / U+2019)
str_lquote:      db 0xe2, 0x80, 0x98
str_lquote_len   equ $ - str_lquote
str_rquote:      db 0xe2, 0x80, 0x99
str_rquote_len   equ $ - str_rquote
str_rquote_nl:   db 0xe2, 0x80, 0x99, 10
str_rquote_nl_len equ $ - str_rquote_nl

str_help_flag:          db "--help", 0
str_version_flag:       db "--version", 0
str_kernel_name_flag:   db "--kernel-name", 0
str_nodename_flag:      db "--nodename", 0
str_kernel_release_flag: db "--kernel-release", 0
str_kernel_version_flag: db "--kernel-version", 0
str_machine_flag:       db "--machine", 0
str_processor_flag:     db "--processor", 0
str_hwplatform_flag:    db "--hardware-platform", 0
str_opsys_flag:         db "--operating-system", 0
str_all_flag:           db "--all", 0

file_size equ $ - $$
