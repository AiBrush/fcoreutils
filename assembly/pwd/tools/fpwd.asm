%include "include/linux.inc"
%include "include/macros.inc"

extern asm_write
extern asm_exit
extern asm_write_err
extern asm_strlen
extern asm_strcmp
extern asm_find_env

global _start

section .data
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
        db "Your shell may have its own version of pwd, which usually supersedes", 10
        db "the version described here.  Please refer to your shell's documentation", 10
        db "for details about the options it supports.", 10
        db 10
        db "GNU coreutils online help: <https://www.gnu.org/software/coreutils/>", 10
        db "Full documentation <https://www.gnu.org/software/coreutils/pwd>", 10
        db "or available locally via: info '(coreutils) pwd invocation'", 10
    str_help_post_len equ $ - str_help_post

    ; --- Version text ---
    str_version:
        db "pwd (GNU coreutils) 9.7", 10
    db "Packaged by Debian (9.7-3)", 10
        db "Copyright (C) 2025 Free Software Foundation, Inc.", 10
        db "License GPLv3+: GNU GPL version 3 or later <https://gnu.org/licenses/gpl.html>.", 10
        db "This is free software: you are free to change and redistribute it.", 10
        db "There is NO WARRANTY, to the extent permitted by law.", 10
        db 10
        db "Written by Jim Meyering.", 10
    str_version_len equ $ - str_version

    ; --- Error messages (split for argv[0] insertion) ---
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

section .bss
    cwd_buf:    resb PATH_MAX       ; buffer for getcwd result
    stat_buf1:  resb STAT_SIZE      ; stat buffer for PWD
    stat_buf2:  resb STAT_SIZE      ; stat buffer for "."

section .text

_start:
    ; Save argc, argv, compute envp
    mov     r14, [rsp]              ; argc
    lea     r15, [rsp + 8]          ; argv
    ; envp = argv + (argc+1)*8
    mov     rax, r14
    inc     rax
    lea     r13, [r15 + rax*8]      ; envp

    ; Save argv[0] for error messages
    mov     r12, [r15]              ; r12 = argv[0]

    ; Default mode: physical (like GNU /usr/bin/pwd)
    xor     ebx, ebx                ; rbx = 0 means physical, 1 means logical
    xor     ebp, ebp                ; rbp = 0, set to 1 if non-option args seen

    ; Parse arguments
    mov     ecx, 1                  ; arg index, start at 1
    cmp     r14, 1
    jle     .run_main               ; no args, just run

.parse_loop:
    cmp     rcx, r14
    jge     .check_non_opt          ; done parsing
    mov     rsi, [r15 + rcx*8]     ; argv[i]
    push    rcx                     ; save index

    ; Check if starts with '-'
    cmp     byte [rsi], '-'
    jne     .non_option_arg

    ; Check if it's just "-"
    cmp     byte [rsi + 1], 0
    je      .non_option_arg

    ; Check if starts with "--"
    cmp     byte [rsi + 1], '-'
    jne     .short_flags

    ; --- Long option ---
    ; Check for "--" (end of options)
    mov     rdi, rsi
    push    rsi
    mov     rsi, str_dashdash
    call    asm_strcmp
    pop     rsi
    test    eax, eax
    jz      .end_of_options

    ; Check --help
    mov     rdi, rsi
    push    rsi
    mov     rsi, str_help_opt
    call    asm_strcmp
    pop     rsi
    test    eax, eax
    jz      .show_help

    ; Check --version
    mov     rdi, rsi
    push    rsi
    mov     rsi, str_version_opt
    call    asm_strcmp
    pop     rsi
    test    eax, eax
    jz      .show_version

    ; Check --logical
    mov     rdi, rsi
    push    rsi
    mov     rsi, str_logical_opt
    call    asm_strcmp
    pop     rsi
    test    eax, eax
    jz      .set_logical

    ; Check --physical
    mov     rdi, rsi
    push    rsi
    mov     rsi, str_physical_opt
    call    asm_strcmp
    pop     rsi
    test    eax, eax
    jz      .set_physical

    ; Unrecognized long option
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
    ; Skip remaining args (they're non-option), but mark if any exist
    pop     rcx
    inc     rcx
    cmp     rcx, r14
    jl      .mark_non_opt
    jmp     .run_main

.mark_non_opt:
    mov     ebp, 1
    jmp     .run_main

.short_flags:
    ; rsi points to argv[i] which starts with '-'
    ; Process each character after '-'
    inc     rsi                     ; skip '-'
.short_loop:
    movzx   eax, byte [rsi]
    test    al, al
    jz      .short_done

    cmp     al, 'L'
    je      .short_L
    cmp     al, 'P'
    je      .short_P

    ; Invalid short option
    ; Save the bad character
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
    ; Non-option argument — mark and continue
    mov     ebp, 1
    pop     rcx
    inc     rcx
    jmp     .parse_loop

.check_non_opt:
    cmp     ebp, 0
    je      .run_main
    ; Print warning: "argv[0]: ignoring non-option arguments\n" to stderr
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

    ; ── Show help ──
.show_help:
    pop     rcx                     ; clean stack
    ; "Usage: "
    mov     rdi, STDOUT
    mov     rsi, str_usage_pre
    mov     rdx, str_usage_pre_len
    call    asm_write
    ; argv[0]
    mov     rdi, r12
    call    asm_strlen
    mov     rdx, rax
    mov     rdi, STDOUT
    mov     rsi, r12
    call    asm_write
    ; rest of help
    mov     rdi, STDOUT
    mov     rsi, str_help_post
    mov     rdx, str_help_post_len
    call    asm_write
    ; exit 0
    xor     edi, edi
    call    asm_exit

    ; ── Show version ──
.show_version:
    pop     rcx                     ; clean stack
    mov     rdi, STDOUT
    mov     rsi, str_version
    mov     rdx, str_version_len
    call    asm_write
    xor     edi, edi
    call    asm_exit

    ; ── Error: unrecognized option ──
.err_unrecognized:
    ; rsi = the bad argv string
    push    rsi                     ; save bad arg
    ; argv[0]
    mov     rdi, r12
    call    asm_strlen
    mov     rdx, rax
    mov     rdi, STDERR
    mov     rsi, r12
    call    asm_write
    ; ": unrecognized option '"
    mov     rdi, STDERR
    mov     rsi, str_unrecog_pre
    mov     rdx, str_unrecog_pre_len
    call    asm_write
    ; the bad arg
    pop     rsi
    push    rsi
    mov     rdi, rsi
    call    asm_strlen
    mov     rdx, rax
    pop     rsi
    mov     rdi, STDERR
    call    asm_write
    ; "'\n"
    mov     rdi, STDERR
    mov     rsi, str_quote_nl
    mov     rdx, str_quote_nl_len
    call    asm_write
    ; "Try '"
    mov     rdi, STDERR
    mov     rsi, str_try_pre
    mov     rdx, str_try_pre_len
    call    asm_write
    ; argv[0]
    mov     rdi, r12
    call    asm_strlen
    mov     rdx, rax
    mov     rdi, STDERR
    mov     rsi, r12
    call    asm_write
    ; " --help' for more information.\n"
    mov     rdi, STDERR
    mov     rsi, str_try_post
    mov     rdx, str_try_post_len
    call    asm_write
    ; exit 1
    mov     edi, 1
    call    asm_exit

    ; ── Error: invalid short option ──
.err_invalid_short:
    ; r8b = the bad character
    pop     rcx                     ; clean parse stack
    push    r8                      ; save bad char on stack
    ; argv[0]
    mov     rdi, r12
    call    asm_strlen
    mov     rdx, rax
    mov     rdi, STDERR
    mov     rsi, r12
    call    asm_write
    ; ": invalid option -- '"
    mov     rdi, STDERR
    mov     rsi, str_invalid_pre
    mov     rdx, str_invalid_pre_len
    call    asm_write
    ; the bad character (1 byte from stack)
    lea     rsi, [rsp]
    mov     rdx, 1
    mov     rdi, STDERR
    call    asm_write
    ; "'\n"
    mov     rdi, STDERR
    mov     rsi, str_quote_nl
    mov     rdx, str_quote_nl_len
    call    asm_write
    pop     r8                      ; clean stack
    ; "Try '"
    mov     rdi, STDERR
    mov     rsi, str_try_pre
    mov     rdx, str_try_pre_len
    call    asm_write
    ; argv[0]
    mov     rdi, r12
    call    asm_strlen
    mov     rdx, rax
    mov     rdi, STDERR
    mov     rsi, r12
    call    asm_write
    ; " --help' for more information.\n"
    mov     rdi, STDERR
    mov     rsi, str_try_post
    mov     rdx, str_try_post_len
    call    asm_write
    ; exit 1
    mov     edi, 1
    call    asm_exit

    ; ── Main logic ──
.run_main:
    test    ebx, ebx
    jnz     .logical_mode

.physical_mode:
    ; Use getcwd syscall
    mov     rax, SYS_GETCWD
    lea     rdi, [cwd_buf]
    mov     rsi, PATH_MAX
    syscall
    test    rax, rax
    js      .getcwd_error

    ; Find length of result
    lea     rdi, [cwd_buf]
    call    asm_strlen
    mov     rdx, rax

    ; Write path to stdout
    mov     rdi, STDOUT
    lea     rsi, [cwd_buf]
    call    asm_write

    ; Write newline
    mov     rdi, STDOUT
    mov     rsi, newline
    mov     rdx, 1
    call    asm_write

    ; exit 0
    xor     edi, edi
    call    asm_exit

.logical_mode:
    ; Try to get PWD from environment
    mov     rdi, r13                ; envp
    mov     rsi, str_pwd_env        ; "PWD="
    mov     rdx, str_pwd_env_len    ; 4
    call    asm_find_env
    test    rax, rax
    jz      .physical_mode          ; PWD not found, fall back

    ; rax = pointer to value after "PWD="
    mov     r8, rax                 ; save PWD value pointer

    ; Check PWD is absolute (starts with '/')
    cmp     byte [r8], '/'
    jne     .physical_mode

    ; Stat the PWD path
    mov     rax, SYS_STAT
    mov     rdi, r8
    lea     rsi, [stat_buf1]
    syscall
    test    rax, rax
    js      .physical_mode          ; stat failed, fall back

    ; Stat "."
    mov     rax, SYS_STAT
    lea     rdi, [str_dot]
    lea     rsi, [stat_buf2]
    syscall
    test    rax, rax
    js      .physical_mode          ; stat failed, fall back

    ; Compare st_dev (offset 0, 8 bytes)
    mov     rax, [stat_buf1]
    cmp     rax, [stat_buf2]
    jne     .physical_mode

    ; Compare st_ino (offset 8, 8 bytes)
    mov     rax, [stat_buf1 + 8]
    cmp     rax, [stat_buf2 + 8]
    jne     .physical_mode

    ; PWD is valid — print it
    mov     rdi, r8
    call    asm_strlen
    mov     rdx, rax

    mov     rdi, STDOUT
    mov     rsi, r8
    call    asm_write

    ; Write newline
    mov     rdi, STDOUT
    mov     rsi, newline
    mov     rdx, 1
    call    asm_write

    ; exit 0
    xor     edi, edi
    call    asm_exit

.getcwd_error:
    ; Print error: "argv[0]: error" — simplified
    ; For now, just exit 1
    mov     edi, 1
    call    asm_exit
