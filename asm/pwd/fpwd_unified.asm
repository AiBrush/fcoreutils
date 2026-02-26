; ============================================================
; fpwd_unified.asm — unified single-file build (nasm -f bin)
; AUTO-GENERATED — do not edit manually
; ============================================================
BITS 64
ORG 0x400000

; ── Linux syscall numbers ──
%define SYS_READ        0
%define SYS_WRITE       1
%define SYS_OPEN        2
%define SYS_CLOSE       3
%define SYS_STAT        4
%define SYS_FSTAT       5
%define SYS_EXIT       60
%define SYS_NANOSLEEP  35
%define SYS_GETCWD     79
%define SYS_GETUID     102
%define SYS_GETEUID    107
%define SYS_UNAME      63
%define SYS_SYNC       162

%define STDIN           0
%define STDOUT          1
%define STDERR          2

%define BUF_SIZE    65536
%define ARG_BUF      4096
%define PATH_MAX     4096
%define STAT_SIZE     144

; ── ELF Header (64 bytes) ──
ehdr:
    db 0x7f, 'E', 'L', 'F'         ; magic
    db 2                             ; 64-bit
    db 1                             ; little endian
    db 1                             ; ELF version
    db 0                             ; OS/ABI: System V
    dq 0                             ; padding
    dw 2                             ; ET_EXEC
    dw 0x3e                          ; x86_64
    dd 1                             ; ELF version
    dq _start                        ; entry point
    dq phdr - $$                     ; program header offset
    dq 0                             ; section header offset (none)
    dd 0                             ; flags
    dw 64                            ; ELF header size
    dw 56                            ; program header entry size
    dw 2                             ; 2 program headers
    dw 64                            ; section header entry size
    dw 0                             ; section header count
    dw 0                             ; section name index

; ── Program Header: PT_LOAD (code+data) ──
phdr:
    dd 1                             ; PT_LOAD
    dd 7                             ; PF_R | PF_W | PF_X
    dq 0                             ; offset
    dq $$                            ; virtual address
    dq $$                            ; physical address
    dq file_size                     ; file size
    dq file_size + bss_size          ; memory size (includes BSS)
    dq 0x200000                      ; alignment

; ── Program Header: PT_GNU_STACK (NX stack) ──
    dd 0x6474e551                    ; PT_GNU_STACK
    dd 6                             ; PF_R | PF_W (no exec)
    dq 0
    dq 0
    dq 0
    dq 0
    dq 0
    dq 0x10                          ; alignment

; ════════════════════════════════════════════════════════════
; DATA SECTION
; ════════════════════════════════════════════════════════════

; --- Help text (split for argv[0] insertion) ---
str_usage_pre:  db "Usage: ", 0
str_usage_pre_len equ $ - str_usage_pre - 1

str_help_post:
    db " [OPTION]...", 10
    db "Print the full filename of the current working directory.", 10
    db 10
    db "  -L, --logical   use PWD from environment, even if it contains symlinks", 10
    db "  -P, --physical  avoid all symlinks", 10
    db "      --help        display this help and exit", 10
    db "      --version     output version information and exit", 10
    db 10
    db "If no option is specified, -P is assumed.", 10
    db 10
    db "NOTE: your shell may have its own version of pwd, which usually supersedes", 10
    db "the version described here.  Please refer to your shell's documentation", 10
    db "for details about the options it supports.", 10
    db 10
    db "GNU coreutils online help: <https://www.gnu.org/software/coreutils/>", 10
    db "Report any translation bugs to <https://translationproject.org/team/>", 10
    db "Full documentation <https://www.gnu.org/software/coreutils/pwd>", 10
    db "or available locally via: info '(coreutils) pwd invocation'", 10
str_help_post_len equ $ - str_help_post

; --- Version text ---
str_version:
    db "pwd (GNU coreutils) 9.4", 10
    db "Copyright (C) 2023 Free Software Foundation, Inc.", 10
    db "License GPLv3+: GNU GPL version 3 or later <https://gnu.org/licenses/gpl.html>.", 10
    db "This is free software: you are free to change and redistribute it.", 10
    db "There is NO WARRANTY, to the extent permitted by law.", 10
    db 10
    db "Written by Jim Meyering.", 10
str_version_len equ $ - str_version

; --- Error messages ---
str_unrecog_pre:    db ": unrecognized option '", 0
str_unrecog_pre_len equ $ - str_unrecog_pre - 1

str_invalid_pre:    db ": invalid option -- '", 0
str_invalid_pre_len equ $ - str_invalid_pre - 1

str_quote_nl:       db "'", 10
str_quote_nl_len    equ $ - str_quote_nl

str_try_pre:        db "Try '", 0
str_try_pre_len     equ $ - str_try_pre - 1

str_try_post:       db " --help' for more information.", 10
str_try_post_len    equ $ - str_try_post

str_ignore_args:    db ": ignoring non-option arguments", 10
str_ignore_args_len equ $ - str_ignore_args

; --- Option strings ---
str_help_opt:       db "--help", 0
str_version_opt:    db "--version", 0
str_logical_opt:    db "--logical", 0
str_physical_opt:   db "--physical", 0
str_dashdash:       db "--", 0

; --- Environment variable prefix ---
str_pwd_env:        db "PWD=", 0
str_pwd_env_len     equ 4

; --- Misc ---
str_dot:            db ".", 0
newline:            db 10

; ════════════════════════════════════════════════════════════
; TEXT SECTION — all code
; ════════════════════════════════════════════════════════════

; ── lib/io.asm (inlined) ──

asm_write:
.retry:
    mov     rax, SYS_WRITE
    syscall
    cmp     rax, -4
    je      .retry
    ret

asm_write_err:
    mov     rdi, STDERR
    jmp     asm_write

asm_exit:
    mov     rax, SYS_EXIT
    syscall

; ── lib/str.asm (inlined) ──

asm_strlen:
    xor     rax, rax
.strlen_loop:
    cmp     byte [rdi + rax], 0
    je      .strlen_done
    inc     rax
    jmp     .strlen_loop
.strlen_done:
    ret

asm_strcmp:
.strcmp_loop:
    movzx   eax, byte [rdi]
    movzx   ecx, byte [rsi]
    cmp     al, cl
    jne     .strcmp_diff
    test    al, al
    jz      .strcmp_equal
    inc     rdi
    inc     rsi
    jmp     .strcmp_loop
.strcmp_equal:
    xor     eax, eax
    ret
.strcmp_diff:
    sub     eax, ecx
    ret

; ── lib/args.asm (inlined) ──

asm_find_env:
    push    rbx
    push    r12
    push    r13
    mov     rbx, rdi
    mov     r12, rsi
    mov     r13, rdx
.env_loop:
    mov     rdi, [rbx]
    test    rdi, rdi
    jz      .env_not_found
    mov     rsi, r12
    mov     rcx, r13
.env_cmp:
    test    rcx, rcx
    jz      .env_found
    movzx   eax, byte [rdi]
    cmp     al, byte [rsi]
    jne     .env_next
    inc     rdi
    inc     rsi
    dec     rcx
    jmp     .env_cmp
.env_found:
    mov     rax, rdi
    pop     r13
    pop     r12
    pop     rbx
    ret
.env_next:
    add     rbx, 8
    jmp     .env_loop
.env_not_found:
    xor     eax, eax
    pop     r13
    pop     r12
    pop     rbx
    ret

; ── tools/fpwd.asm — main entry point ──

_start:
    mov     r14, [rsp]
    lea     r15, [rsp + 8]
    mov     rax, r14
    inc     rax
    lea     r13, [r15 + rax*8]
    mov     r12, [r15]

    xor     ebx, ebx
    xor     ebp, ebp

    mov     ecx, 1
    cmp     r14, 1
    jle     .run_main

.parse_loop:
    cmp     rcx, r14
    jge     .check_non_opt
    mov     rsi, [r15 + rcx*8]
    push    rcx

    cmp     byte [rsi], '-'
    jne     .non_option_arg
    cmp     byte [rsi + 1], 0
    je      .non_option_arg
    cmp     byte [rsi + 1], '-'
    jne     .short_flags

    ; Long option
    mov     rdi, rsi
    push    rsi
    mov     rsi, str_dashdash
    call    asm_strcmp
    pop     rsi
    test    eax, eax
    jz      .end_of_options

    mov     rdi, rsi
    push    rsi
    mov     rsi, str_help_opt
    call    asm_strcmp
    pop     rsi
    test    eax, eax
    jz      .show_help

    mov     rdi, rsi
    push    rsi
    mov     rsi, str_version_opt
    call    asm_strcmp
    pop     rsi
    test    eax, eax
    jz      .show_version

    mov     rdi, rsi
    push    rsi
    mov     rsi, str_logical_opt
    call    asm_strcmp
    pop     rsi
    test    eax, eax
    jz      .set_logical

    mov     rdi, rsi
    push    rsi
    mov     rsi, str_physical_opt
    call    asm_strcmp
    pop     rsi
    test    eax, eax
    jz      .set_physical

    jmp     .err_unrecognized

.set_logical:
    mov     ebx, 1
    pop     rcx
    inc     rcx
    jmp     .parse_loop

.set_physical:
    xor     ebx, ebx
    pop     rcx
    inc     rcx
    jmp     .parse_loop

.end_of_options:
    pop     rcx
    inc     rcx
    cmp     rcx, r14
    jl      .mark_non_opt
    jmp     .run_main

.mark_non_opt:
    mov     ebp, 1
    jmp     .run_main

.short_flags:
    inc     rsi
.short_loop:
    movzx   eax, byte [rsi]
    test    al, al
    jz      .short_done
    cmp     al, 'L'
    je      .short_L
    cmp     al, 'P'
    je      .short_P
    mov     r8b, al
    jmp     .err_invalid_short

.short_L:
    mov     ebx, 1
    inc     rsi
    jmp     .short_loop

.short_P:
    xor     ebx, ebx
    inc     rsi
    jmp     .short_loop

.short_done:
    pop     rcx
    inc     rcx
    jmp     .parse_loop

.non_option_arg:
    mov     ebp, 1
    pop     rcx
    inc     rcx
    jmp     .parse_loop

.check_non_opt:
    cmp     ebp, 0
    je      .run_main
    mov     rdi, r12
    call    asm_strlen
    mov     rdx, rax
    mov     rsi, r12
    mov     rdi, STDERR
    call    asm_write
    mov     rdi, STDERR
    mov     rsi, str_ignore_args
    mov     rdx, str_ignore_args_len
    call    asm_write
    jmp     .run_main

.show_help:
    pop     rcx
    mov     rdi, STDOUT
    mov     rsi, str_usage_pre
    mov     rdx, str_usage_pre_len
    call    asm_write
    mov     rdi, r12
    call    asm_strlen
    mov     rdx, rax
    mov     rdi, STDOUT
    mov     rsi, r12
    call    asm_write
    mov     rdi, STDOUT
    mov     rsi, str_help_post
    mov     rdx, str_help_post_len
    call    asm_write
    xor     edi, edi
    call    asm_exit

.show_version:
    pop     rcx
    mov     rdi, STDOUT
    mov     rsi, str_version
    mov     rdx, str_version_len
    call    asm_write
    xor     edi, edi
    call    asm_exit

.err_unrecognized:
    push    rsi
    mov     rdi, r12
    call    asm_strlen
    mov     rdx, rax
    mov     rdi, STDERR
    mov     rsi, r12
    call    asm_write
    mov     rdi, STDERR
    mov     rsi, str_unrecog_pre
    mov     rdx, str_unrecog_pre_len
    call    asm_write
    pop     rsi
    push    rsi
    mov     rdi, rsi
    call    asm_strlen
    mov     rdx, rax
    pop     rsi
    mov     rdi, STDERR
    call    asm_write
    mov     rdi, STDERR
    mov     rsi, str_quote_nl
    mov     rdx, str_quote_nl_len
    call    asm_write
    mov     rdi, STDERR
    mov     rsi, str_try_pre
    mov     rdx, str_try_pre_len
    call    asm_write
    mov     rdi, r12
    call    asm_strlen
    mov     rdx, rax
    mov     rdi, STDERR
    mov     rsi, r12
    call    asm_write
    mov     rdi, STDERR
    mov     rsi, str_try_post
    mov     rdx, str_try_post_len
    call    asm_write
    mov     edi, 1
    call    asm_exit

.err_invalid_short:
    pop     rcx
    push    r8
    mov     rdi, r12
    call    asm_strlen
    mov     rdx, rax
    mov     rdi, STDERR
    mov     rsi, r12
    call    asm_write
    mov     rdi, STDERR
    mov     rsi, str_invalid_pre
    mov     rdx, str_invalid_pre_len
    call    asm_write
    lea     rsi, [rsp]
    mov     rdx, 1
    mov     rdi, STDERR
    call    asm_write
    mov     rdi, STDERR
    mov     rsi, str_quote_nl
    mov     rdx, str_quote_nl_len
    call    asm_write
    pop     r8
    mov     rdi, STDERR
    mov     rsi, str_try_pre
    mov     rdx, str_try_pre_len
    call    asm_write
    mov     rdi, r12
    call    asm_strlen
    mov     rdx, rax
    mov     rdi, STDERR
    mov     rsi, r12
    call    asm_write
    mov     rdi, STDERR
    mov     rsi, str_try_post
    mov     rdx, str_try_post_len
    call    asm_write
    mov     edi, 1
    call    asm_exit

.run_main:
    test    ebx, ebx
    jnz     .logical_mode

.physical_mode:
    mov     rax, SYS_GETCWD
    lea     rdi, [cwd_buf]
    mov     rsi, PATH_MAX
    syscall
    test    rax, rax
    js      .getcwd_error
    lea     rdi, [cwd_buf]
    call    asm_strlen
    mov     rdx, rax
    mov     rdi, STDOUT
    lea     rsi, [cwd_buf]
    call    asm_write
    mov     rdi, STDOUT
    mov     rsi, newline
    mov     rdx, 1
    call    asm_write
    xor     edi, edi
    call    asm_exit

.logical_mode:
    mov     rdi, r13
    mov     rsi, str_pwd_env
    mov     rdx, str_pwd_env_len
    call    asm_find_env
    test    rax, rax
    jz      .physical_mode
    mov     r8, rax
    cmp     byte [r8], '/'
    jne     .physical_mode
    mov     rax, SYS_STAT
    mov     rdi, r8
    lea     rsi, [stat_buf1]
    syscall
    test    rax, rax
    js      .physical_mode
    mov     rax, SYS_STAT
    lea     rdi, [str_dot]
    lea     rsi, [stat_buf2]
    syscall
    test    rax, rax
    js      .physical_mode
    mov     rax, [stat_buf1]
    cmp     rax, [stat_buf2]
    jne     .physical_mode
    mov     rax, [stat_buf1 + 8]
    cmp     rax, [stat_buf2 + 8]
    jne     .physical_mode
    mov     rdi, r8
    call    asm_strlen
    mov     rdx, rax
    mov     rdi, STDOUT
    mov     rsi, r8
    call    asm_write
    mov     rdi, STDOUT
    mov     rsi, newline
    mov     rdx, 1
    call    asm_write
    xor     edi, edi
    call    asm_exit

.getcwd_error:
    mov     edi, 1
    call    asm_exit

; ════════════════════════════════════════════════════════════
; BSS SECTION (uninitialized data, after file end)
; ════════════════════════════════════════════════════════════

file_size equ $ - $$

; BSS — addresses beyond file_size, zeroed by kernel via memsz > filesz
; Using equ instead of resb to avoid padding the binary with zeros
cwd_buf     equ $$ + file_size
stat_buf1   equ cwd_buf + PATH_MAX
stat_buf2   equ stat_buf1 + STAT_SIZE
bss_end     equ stat_buf2 + STAT_SIZE

bss_size equ bss_end - cwd_buf
