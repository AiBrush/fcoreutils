; ftty.asm — print the file name of the terminal connected to standard input
; GNU-compatible implementation of tty(1)

%include "include/linux.inc"
%include "include/macros.inc"

extern asm_write
extern asm_write_err
extern asm_exit
extern asm_strlen
extern asm_strcmp

global _start

; ============================================================
; Data section — all GNU-identical strings
; ============================================================
section .data

str_help:
    db "Usage: tty [OPTION]...", 10
    db "Print the file name of the terminal connected to standard input.", 10
    db 10
    db "  -s, --silent, --quiet   print nothing, only return an exit status", 10
    db "      --help        display this help and exit", 10
    db "      --version     output version information and exit", 10
    db 10
    db "GNU coreutils online help: <https://www.gnu.org/software/coreutils/>", 10
    db "Report any translation bugs to <https://translationproject.org/team/>", 10
    db "Full documentation <https://www.gnu.org/software/coreutils/tty>", 10
    db "or available locally via: info '(coreutils) tty invocation'", 10
str_help_len equ $ - str_help

str_version:
    db "tty (GNU coreutils) 9.4", 10
    db "Copyright (C) 2023 Free Software Foundation, Inc.", 10
    db "License GPLv3+: GNU GPL version 3 or later <https://gnu.org/licenses/gpl.html>.", 10
    db "This is free software: you are free to change and redistribute it.", 10
    db "There is NO WARRANTY, to the extent permitted by law.", 10
    db 10
    db "Written by David MacKenzie.", 10
str_version_len equ $ - str_version

str_not_a_tty:
    db "not a tty", 10
str_not_a_tty_len equ $ - str_not_a_tty

str_newline:
    db 10
str_newline_len equ 1

; Error message fragments
str_err_prefix:
    db "tty: "
str_err_prefix_len equ $ - str_err_prefix

str_err_invalid_opt:
    db "invalid option -- '"
str_err_invalid_opt_len equ $ - str_err_invalid_opt

str_err_unrecognized:
    db "unrecognized option '"
str_err_unrecognized_len equ $ - str_err_unrecognized

str_err_extra_operand:
    db "extra operand '"
str_err_extra_operand_len equ $ - str_err_extra_operand

str_err_quote_nl:
    db "'", 10
str_err_quote_nl_len equ $ - str_err_quote_nl

str_try_help:
    db "Try 'tty --help' for more information.", 10
str_try_help_len equ $ - str_try_help

str_opt_help:
    db "--help", 0
str_opt_version:
    db "--version", 0
str_opt_silent:
    db "--silent", 0
str_opt_quiet:
    db "--quiet", 0
str_opt_s:
    db "-s", 0

str_proc_fd0:
    db "/proc/self/fd/0", 0

; ============================================================
; BSS section — fixed-size buffers
; ============================================================
section .bss
    termios_buf:    resb 64         ; for ioctl TCGETS
    ttyname_buf:    resb PATH_MAX   ; for readlink result

; ============================================================
; Text section
; ============================================================
section .text

_start:
    ; Get argc and argv from stack
    mov     r14, [rsp]          ; argc
    lea     r15, [rsp + 8]      ; argv

    ; r12 = silent flag (0 = not silent)
    xor     r12, r12

    ; Parse arguments: loop from argv[1] to argv[argc-1]
    cmp     r14, 1
    jle     .run_main           ; no arguments, go directly to main

    mov     r13, 1              ; i = 1 (current arg index)

.arg_loop:
    cmp     r13, r14
    jge     .run_main           ; done parsing all args

    mov     rsi, [r15 + r13*8]  ; argv[i]

    ; Check if arg starts with '-'
    cmp     byte [rsi], '-'
    jne     .err_extra_operand

    ; Check if it's just "-" (not really an option)
    cmp     byte [rsi + 1], 0
    je      .err_extra_operand

    ; Check if it starts with '--'
    cmp     byte [rsi + 1], '-'
    je      .check_long_opt

    ; Short option(s): parse each character after '-'
    jmp     .parse_short_opts

.check_long_opt:
    ; rsi points to the arg starting with '--'
    ; Check --help
    mov     rdi, str_opt_help
    push    rsi
    mov     rdi, rsi
    mov     rsi, str_opt_help
    call    asm_strcmp
    pop     rsi
    test    rax, rax
    jz      .do_help

    ; Check --version
    push    rsi
    mov     rdi, rsi
    mov     rsi, str_opt_version
    call    asm_strcmp
    pop     rsi
    test    rax, rax
    jz      .do_version

    ; Check --silent
    push    rsi
    mov     rdi, rsi
    mov     rsi, str_opt_silent
    call    asm_strcmp
    pop     rsi
    test    rax, rax
    jz      .set_silent

    ; Check --quiet
    push    rsi
    mov     rdi, rsi
    mov     rsi, str_opt_quiet
    call    asm_strcmp
    pop     rsi
    test    rax, rax
    jz      .set_silent

    ; Unrecognized long option
    jmp     .err_unrecognized_opt

.parse_short_opts:
    ; rsi points to the arg string, start parsing from rsi+1
    mov     rbx, rsi
    add     rbx, 1             ; skip the '-'

.short_opt_loop:
    movzx   eax, byte [rbx]
    test    al, al
    jz      .next_arg          ; end of this short option string

    cmp     al, 's'
    je      .short_s

    ; Invalid short option character
    ; Save the char in r8b for error message
    mov     r8b, al
    jmp     .err_invalid_short_opt

.short_s:
    mov     r12, 1              ; set silent flag
    inc     rbx
    jmp     .short_opt_loop

.set_silent:
    mov     r12, 1
    jmp     .next_arg

.next_arg:
    inc     r13
    jmp     .arg_loop

; ── Help output ──────────────────────────────────────────────
.do_help:
    mov     rdi, STDOUT
    mov     rsi, str_help
    mov     rdx, str_help_len
    call    asm_write
    xor     rdi, rdi
    call    asm_exit

; ── Version output ───────────────────────────────────────────
.do_version:
    mov     rdi, STDOUT
    mov     rsi, str_version
    mov     rdx, str_version_len
    call    asm_write
    xor     rdi, rdi
    call    asm_exit

; ── Main logic: check if stdin is a tty ──────────────────────
.run_main:
    ; ioctl(STDIN, TCGETS, termios_buf) to check isatty
    mov     rax, SYS_IOCTL
    mov     rdi, STDIN
    mov     rsi, TCGETS
    lea     rdx, [rel termios_buf]
    syscall

    ; If rax == 0, stdin is a tty
    test    rax, rax
    jnz     .not_a_tty

    ; stdin IS a tty — get tty name via readlink("/proc/self/fd/0")
    cmp     r12, 1
    je      .exit_success       ; silent mode, just exit 0

    mov     rax, SYS_READLINK
    lea     rdi, [rel str_proc_fd0]
    lea     rsi, [rel ttyname_buf]
    mov     rdx, PATH_MAX - 1
    syscall

    ; rax = length of readlink result, or negative errno
    test    rax, rax
    jle     .not_a_tty          ; readlink failed, treat as not a tty

    ; Null-terminate the result (readlink doesn't)
    lea     rdi, [rel ttyname_buf]
    mov     byte [rdi + rax], 10  ; append newline
    inc     rax                   ; include newline in length

    ; Write the tty name
    mov     rdx, rax
    mov     rsi, rdi
    mov     rdi, STDOUT
    call    asm_write

.exit_success:
    xor     rdi, rdi            ; exit code 0
    call    asm_exit

.not_a_tty:
    ; Not a tty
    cmp     r12, 1
    je      .exit_not_tty       ; silent mode, just exit 1

    mov     rdi, STDOUT
    mov     rsi, str_not_a_tty
    mov     rdx, str_not_a_tty_len
    call    asm_write

.exit_not_tty:
    mov     rdi, 1              ; exit code 1
    call    asm_exit

; ── Error handlers ───────────────────────────────────────────

; Error: invalid short option (char in r8b)
.err_invalid_short_opt:
    ; "tty: invalid option -- 'X'\n"
    mov     rsi, str_err_prefix
    mov     rdx, str_err_prefix_len
    call    asm_write_err

    mov     rsi, str_err_invalid_opt
    mov     rdx, str_err_invalid_opt_len
    call    asm_write_err

    ; Write the single invalid character
    mov     byte [rel ttyname_buf], r8b
    mov     byte [rel ttyname_buf + 1], 0x27  ; single quote
    mov     byte [rel ttyname_buf + 2], 10    ; newline
    lea     rsi, [rel ttyname_buf]
    mov     rdx, 3
    call    asm_write_err

    ; "Try 'tty --help' for more information.\n"
    mov     rsi, str_try_help
    mov     rdx, str_try_help_len
    call    asm_write_err

    mov     rdi, 2
    call    asm_exit

; Error: unrecognized long option (rsi points to the arg)
.err_unrecognized_opt:
    ; Save the arg pointer
    mov     rbx, rsi

    ; "tty: "
    mov     rsi, str_err_prefix
    mov     rdx, str_err_prefix_len
    call    asm_write_err

    ; "unrecognized option '"
    mov     rsi, str_err_unrecognized
    mov     rdx, str_err_unrecognized_len
    call    asm_write_err

    ; the option string itself
    mov     rdi, rbx
    call    asm_strlen
    mov     rdx, rax
    mov     rsi, rbx
    call    asm_write_err

    ; "'\n"
    mov     rsi, str_err_quote_nl
    mov     rdx, str_err_quote_nl_len
    call    asm_write_err

    ; "Try 'tty --help' for more information.\n"
    mov     rsi, str_try_help
    mov     rdx, str_try_help_len
    call    asm_write_err

    mov     rdi, 2
    call    asm_exit

; Error: extra operand (rsi points to the arg)
.err_extra_operand:
    ; Save the arg pointer
    mov     rbx, rsi

    ; "tty: "
    mov     rsi, str_err_prefix
    mov     rdx, str_err_prefix_len
    call    asm_write_err

    ; "extra operand '"
    mov     rsi, str_err_extra_operand
    mov     rdx, str_err_extra_operand_len
    call    asm_write_err

    ; the operand string itself
    mov     rdi, rbx
    call    asm_strlen
    mov     rdx, rax
    mov     rsi, rbx
    call    asm_write_err

    ; "'\n"
    mov     rsi, str_err_quote_nl
    mov     rdx, str_err_quote_nl_len
    call    asm_write_err

    ; "Try 'tty --help' for more information.\n"
    mov     rsi, str_try_help
    mov     rdx, str_try_help_len
    call    asm_write_err

    mov     rdi, 2
    call    asm_exit
