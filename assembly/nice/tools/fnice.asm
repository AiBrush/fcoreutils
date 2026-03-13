; fnice.asm — GNU-compatible 'nice' command
;
; nice: run a program with modified scheduling priority
; - nice [OPTION] [COMMAND [ARG]...]
; - With no COMMAND: print current niceness and exit
; - Default adjustment is +10
; - -n N / --adjustment=N: set adjustment to N

%include "include/linux.inc"

extern asm_write
extern asm_exit
extern asm_strlen
extern asm_strcmp

global _start

section .bss
    ; Argument vector for execve (max 256 pointers + NULL)
    exec_argv: resq 257
    ; Buffer for PATH-based executable search
    path_buf: resb 4096
    ; Buffer for number formatting
    num_buf: resb 32

section .text

_start:
    mov     r14, [rsp]          ; argc
    lea     r15, [rsp + 8]      ; argv

    ; Default adjustment = 10
    mov     r12, 10             ; adjustment
    mov     rbx, 1              ; current argv index

    ; ── Scan for --help / --version first ──
    cmp     r14, 2
    jl      .parse_options
    mov     rdi, [r15 + 8]      ; argv[1]
    mov     rsi, str_opt_help
    call    asm_strcmp
    test    eax, eax
    jz      .show_help
    mov     rdi, [r15 + 8]
    mov     rsi, str_opt_version
    call    asm_strcmp
    test    eax, eax
    jz      .show_version

.parse_options:
    cmp     rbx, r14
    jge     .no_command

    mov     rdi, [r15 + rbx*8]  ; argv[i]

    ; Check if starts with '-'
    cmp     byte [rdi], '-'
    jne     .exec_command

    ; Check for "--"
    cmp     byte [rdi + 1], '-'
    jne     .check_short_n

    ; Check for "--adjustment="
    mov     rsi, str_opt_adjustment
    push    rdi
    call    .starts_with
    pop     rdi
    test    eax, eax
    jnz     .parse_adjustment_eq

    ; Check for "--adjustment" (space-separated)
    mov     rdi, [r15 + rbx*8]
    mov     rsi, str_opt_adj_only
    call    asm_strcmp
    test    eax, eax
    jz      .parse_adjustment_space

    ; Check for exactly "--"
    mov     rdi, [r15 + rbx*8]
    cmp     byte [rdi + 2], 0
    je      .end_of_options

    ; Unrecognized long option
    jmp     .invalid_option

.check_short_n:
    ; Check for "-n"
    cmp     byte [rdi + 1], 'n'
    jne     .check_numeric_opt
    cmp     byte [rdi + 2], 0
    jne     .check_n_attached

    ; "-n N" — next arg is the adjustment
    inc     rbx
    cmp     rbx, r14
    jge     .missing_adjustment
    mov     rdi, [r15 + rbx*8]
    call    .parse_int
    test    ecx, ecx
    jnz     .invalid_adjustment
    mov     r12, rax
    inc     rbx
    jmp     .parse_options

.check_n_attached:
    ; "-nN" — number attached
    lea     rdi, [rdi + 2]
    call    .parse_int
    test    ecx, ecx
    jnz     .invalid_adjustment
    mov     r12, rax
    inc     rbx
    jmp     .parse_options

.check_numeric_opt:
    ; Check for "-NUMBER" (e.g., "-5")
    movzx   eax, byte [rdi + 1]
    cmp     al, '0'
    jb      .invalid_option
    cmp     al, '9'
    ja      .check_negative_number
    ; It's -N (positive number as adjustment)
    lea     rdi, [rdi + 1]
    call    .parse_int
    test    ecx, ecx
    jnz     .invalid_adjustment
    mov     r12, rax
    inc     rbx
    jmp     .parse_options

.check_negative_number:
    ; Not a digit after '-', invalid option
    jmp     .invalid_option

.parse_adjustment_eq:
    ; "--adjustment=N" — find the '=' and parse number after it
    mov     rdi, [r15 + rbx*8]
.find_eq:
    cmp     byte [rdi], '='
    je      .found_eq
    cmp     byte [rdi], 0
    je      .invalid_adjustment
    inc     rdi
    jmp     .find_eq
.found_eq:
    inc     rdi              ; skip '='
    cmp     byte [rdi], 0
    je      .invalid_adjustment
    call    .parse_int
    test    ecx, ecx
    jnz     .invalid_adjustment
    mov     r12, rax
    inc     rbx
    jmp     .parse_options

.parse_adjustment_space:
    ; "--adjustment N" — next arg is the number
    inc     rbx
    cmp     rbx, r14
    jge     .missing_adjustment
    mov     rdi, [r15 + rbx*8]
    call    .parse_int
    test    ecx, ecx
    jnz     .invalid_adjustment
    mov     r12, rax
    inc     rbx
    jmp     .parse_options

.end_of_options:
    inc     rbx
    jmp     .exec_command

.no_command:
    ; No command — print current niceness
    ; getpriority(PRIO_PROCESS, 0)
    mov     eax, SYS_GETPRIORITY
    xor     edi, edi            ; PRIO_PROCESS = 0
    xor     esi, esi            ; who = 0 (self)
    syscall
    ; getpriority returns 20-priority, so actual nice = 20 - retval
    ; Actually on Linux, getpriority returns the nice value + 20
    ; so niceness = retval - 20
    sub     rax, 20
    mov     rdi, rax
    ; Convert to string and print
    call    .int_to_str         ; rdi=value -> rsi=buf, rdx=len
    mov     edi, STDOUT
    call    asm_write
    ; Print newline
    mov     edi, STDOUT
    mov     rsi, str_newline
    mov     edx, 1
    call    asm_write
    xor     edi, edi
    call    asm_exit

.exec_command:
    ; Remaining args from rbx onward are the command and its args
    cmp     rbx, r14
    jge     .no_command

    ; Set priority: setpriority(PRIO_PROCESS, 0, current + adjustment)
    ; First get current priority
    push    rbx
    mov     eax, SYS_GETPRIORITY
    xor     edi, edi            ; PRIO_PROCESS
    xor     esi, esi            ; self
    syscall
    sub     rax, 20             ; actual nice value
    add     rax, r12            ; new nice value
    ; Clamp to [-20, 19]
    cmp     rax, -20
    jge     .not_too_low
    mov     rax, -20
.not_too_low:
    cmp     rax, 19
    jle     .not_too_high
    mov     rax, 19
.not_too_high:
    mov     rdx, rax            ; priority value
    mov     eax, SYS_SETPRIORITY
    xor     edi, edi            ; PRIO_PROCESS
    xor     esi, esi            ; self
    syscall
    ; Ignore setpriority errors (may not have permission) — GNU nice does same
    pop     rbx

    ; Build argv for execve
    mov     rcx, 0              ; index into exec_argv
.build_argv:
    cmp     rbx, r14
    jge     .argv_done
    mov     rax, [r15 + rbx*8]
    mov     [rel exec_argv + rcx*8], rax
    inc     rcx
    inc     rbx
    cmp     rcx, 256
    jge     .argv_done
    jmp     .build_argv
.argv_done:
    mov     qword [rel exec_argv + rcx*8], 0  ; NULL terminate

    ; Try execve with the command directly first
    mov     rdi, [rel exec_argv]        ; filename = command
    lea     rsi, [rel exec_argv]        ; argv
    ; Build envp from original stack
    ; envp is at argv + argc*8 + 8
    mov     rax, [rsp]                  ; argc
    lea     rdx, [rsp + 8]              ; argv base
    lea     rdx, [rdx + rax*8 + 8]     ; envp
    mov     r13, rdx                    ; save envp
    mov     eax, SYS_EXECVE
    syscall

    ; If execve failed, try PATH search
    cmp     rax, -2                     ; -ENOENT
    je      .try_path
    cmp     rax, -13                    ; -EACCES
    je      .try_path
    cmp     rax, -20                    ; -ENOTDIR
    je      .try_path
    jmp     .exec_failed

.try_path:
    ; Get PATH from environment
    mov     rdi, r13                    ; envp
    call    .find_path_env
    test    rax, rax
    jz      .exec_not_found

    mov     r8, rax                     ; r8 = PATH value string
    mov     r9, [rel exec_argv]         ; r9 = command name

.path_loop:
    cmp     byte [r8], 0
    je      .exec_not_found

    ; Copy path component to path_buf
    lea     rdi, [rel path_buf]
    mov     rcx, 0
.copy_path_component:
    movzx   eax, byte [r8]
    cmp     al, ':'
    je      .path_sep
    test    al, al
    jz      .path_sep
    mov     [rdi + rcx], al
    inc     rcx
    inc     r8
    cmp     rcx, 4000
    jge     .path_sep
    jmp     .copy_path_component

.path_sep:
    ; Skip the ':'
    cmp     byte [r8], ':'
    jne     .no_skip_colon
    inc     r8
.no_skip_colon:
    ; Add '/' separator
    mov     byte [rdi + rcx], '/'
    inc     rcx
    ; Append command name
    push    r8
    mov     rsi, r9
.copy_cmd:
    movzx   eax, byte [rsi]
    test    al, al
    jz      .cmd_done
    mov     [rdi + rcx], al
    inc     rcx
    inc     rsi
    cmp     rcx, 4090
    jge     .cmd_done
    jmp     .copy_cmd
.cmd_done:
    mov     byte [rdi + rcx], 0
    pop     r8

    ; Try execve with this path
    lea     rdi, [rel path_buf]
    lea     rsi, [rel exec_argv]
    mov     rdx, r13                    ; envp
    mov     eax, SYS_EXECVE
    syscall
    ; If failed, try next PATH component
    jmp     .path_loop

.exec_not_found:
    ; Print error: "nice: 'CMD': No such file or directory"
    mov     edi, STDERR
    mov     rsi, str_prog_prefix
    mov     edx, str_prog_prefix_len
    call    asm_write
    mov     rdi, [rel exec_argv]
    call    asm_strlen
    mov     rdx, rax
    mov     rsi, [rel exec_argv]
    mov     edi, STDERR
    call    asm_write
    mov     edi, STDERR
    mov     rsi, str_enoent
    mov     edx, str_enoent_len
    call    asm_write
    mov     edi, 127
    call    asm_exit

.exec_failed:
    ; Permission denied or other error
    mov     edi, STDERR
    mov     rsi, str_prog_prefix
    mov     edx, str_prog_prefix_len
    call    asm_write
    mov     rdi, [rel exec_argv]
    call    asm_strlen
    mov     rdx, rax
    mov     rsi, [rel exec_argv]
    mov     edi, STDERR
    call    asm_write
    mov     edi, STDERR
    mov     rsi, str_eperm
    mov     edx, str_eperm_len
    call    asm_write
    mov     edi, 126
    call    asm_exit

.show_help:
    mov     edi, STDOUT
    mov     rsi, str_help
    mov     edx, str_help_len
    call    asm_write
    xor     edi, edi
    call    asm_exit

.show_version:
    mov     edi, STDOUT
    mov     rsi, str_version
    mov     edx, str_version_len
    call    asm_write
    xor     edi, edi
    call    asm_exit

.invalid_option:
    mov     edi, STDERR
    mov     rsi, str_inv_opt_pre
    mov     edx, str_inv_opt_pre_len
    call    asm_write
    mov     rdi, [r15 + rbx*8]
    call    asm_strlen
    mov     rdx, rax
    mov     rsi, [r15 + rbx*8]
    mov     edi, STDERR
    call    asm_write
    mov     edi, STDERR
    mov     rsi, str_inv_opt_post
    mov     edx, str_inv_opt_post_len
    call    asm_write
    mov     edi, STDERR
    mov     rsi, str_try
    mov     edx, str_try_len
    call    asm_write
    mov     edi, 125
    call    asm_exit

.missing_adjustment:
    mov     edi, STDERR
    mov     rsi, str_missing_adj
    mov     edx, str_missing_adj_len
    call    asm_write
    mov     edi, STDERR
    mov     rsi, str_try
    mov     edx, str_try_len
    call    asm_write
    mov     edi, 125
    call    asm_exit

.invalid_adjustment:
    mov     edi, STDERR
    mov     rsi, str_inv_adj_pre
    mov     edx, str_inv_adj_pre_len
    call    asm_write
    mov     rdi, [r15 + rbx*8]
    call    asm_strlen
    mov     rdx, rax
    mov     rsi, [r15 + rbx*8]
    mov     edi, STDERR
    call    asm_write
    mov     edi, STDERR
    mov     rsi, str_inv_adj_post
    mov     edx, str_inv_adj_post_len
    call    asm_write
    mov     edi, 125
    call    asm_exit

; ── Helper: parse integer (signed) ──
; Input: rdi = pointer to string
; Output: rax = value, ecx = 0 ok / 1 error
.parse_int:
    xor     eax, eax
    xor     ecx, ecx            ; error flag
    xor     r10d, r10d          ; negative flag
    movzx   edx, byte [rdi]
    cmp     dl, '-'
    jne     .pi_check_plus
    mov     r10d, 1
    inc     rdi
    jmp     .pi_digits
.pi_check_plus:
    cmp     dl, '+'
    jne     .pi_digits
    inc     rdi
.pi_digits:
    movzx   edx, byte [rdi]
    test    dl, dl
    jz      .pi_check_empty
    cmp     dl, '0'
    jb      .pi_error
    cmp     dl, '9'
    ja      .pi_error
    sub     dl, '0'
    imul    rax, 10
    movzx   edx, dl
    add     rax, rdx
    inc     rdi
    jmp     .pi_digits
.pi_check_empty:
    ; Check we parsed at least one digit
    test    rax, rax
    jnz     .pi_apply_sign
    ; Could be "0" or empty — check if first char was a digit
    ; If we get here with rax=0 and no error, it's valid (0)
    jmp     .pi_apply_sign
.pi_apply_sign:
    test    r10d, r10d
    jz      .pi_done
    neg     rax
.pi_done:
    ret
.pi_error:
    mov     ecx, 1
    ret

; ── Helper: integer to string ──
; Input: rdi = signed integer value
; Output: rsi = buffer pointer, rdx = length
.int_to_str:
    push    rbx
    lea     rsi, [rel num_buf + 20]
    mov     byte [rsi], 0
    mov     rax, rdi
    xor     ecx, ecx            ; negative flag
    test    rax, rax
    jns     .its_positive
    mov     ecx, 1
    neg     rax
.its_positive:
    mov     rbx, 10
.its_loop:
    xor     edx, edx
    div     rbx
    add     dl, '0'
    dec     rsi
    mov     [rsi], dl
    test    rax, rax
    jnz     .its_loop
    test    ecx, ecx
    jz      .its_done
    dec     rsi
    mov     byte [rsi], '-'
.its_done:
    ; Calculate length
    lea     rdx, [rel num_buf + 20]
    sub     rdx, rsi
    pop     rbx
    ret

; ── Helper: starts_with ──
; Input: rdi = string, rsi = prefix (must end at '=' for us)
; Output: eax = 1 if match, 0 if not
.starts_with:
    push    rbx
.sw_loop:
    movzx   eax, byte [rsi]
    test    al, al
    jz      .sw_match
    movzx   ecx, byte [rdi]
    cmp     al, cl
    jne     .sw_no_match
    inc     rdi
    inc     rsi
    jmp     .sw_loop
.sw_match:
    mov     eax, 1
    pop     rbx
    ret
.sw_no_match:
    xor     eax, eax
    pop     rbx
    ret

; ── Helper: find PATH in envp ──
; Input: rdi = envp (array of char*)
; Output: rax = pointer to PATH value or 0
.find_path_env:
    push    rbx
.fpe_loop:
    mov     rax, [rdi]
    test    rax, rax
    jz      .fpe_not_found
    ; Check if starts with "PATH="
    cmp     dword [rax], 0x48544150     ; "PATH" in little-endian
    jne     .fpe_next
    cmp     byte [rax + 4], '='
    jne     .fpe_next
    lea     rax, [rax + 5]              ; skip "PATH="
    pop     rbx
    ret
.fpe_next:
    add     rdi, 8
    jmp     .fpe_loop
.fpe_not_found:
    xor     eax, eax
    pop     rbx
    ret


section .rodata

str_opt_help:
    db "--help", 0

str_opt_version:
    db "--version", 0

str_opt_adjustment:
    db "--adjustment=", 0

str_opt_adj_only:
    db "--adjustment", 0

str_newline:
    db 10

str_help:
    db "Usage: nice [OPTION] [COMMAND [ARG]...]", 10
    db "Run COMMAND with an adjusted niceness, which affects process scheduling.", 10
    db "With no COMMAND, print the current niceness.  Niceness values range from", 10
    db "-20 (most favorable to the process) to 19 (least favorable to the process).", 10
    db 10
    db "Mandatory arguments to long options are mandatory for short options too.", 10
    db "  -n, --adjustment=N   add integer N to the niceness (default 10)", 10
    db "      --help        display this help and exit", 10
    db "      --version     output version information and exit", 10
    db 10
    db "NOTE: your shell may have its own version of nice, which usually supersedes", 10
    db "the version described here.  Please refer to your shell's documentation", 10
    db "for details about the options it supports.", 10
    db 10
    db "GNU coreutils online help: <https://www.gnu.org/software/coreutils/>", 10
    db "Full documentation <https://www.gnu.org/software/coreutils/nice>", 10
    db "or available locally via: info '(coreutils) nice invocation'", 10
str_help_len equ $ - str_help

str_version:
    db "nice (GNU coreutils) 9.7", 10
    db "Packaged by Debian (9.7-3)", 10
    db "Copyright (C) 2025 Free Software Foundation, Inc.", 10
    db "License GPLv3+: GNU GPL version 3 or later <https://gnu.org/licenses/gpl.html>.", 10
    db "This is free software: you are free to change and redistribute it.", 10
    db "There is NO WARRANTY, to the extent permitted by law.", 10
    db 10
    db "Written by David MacKenzie.", 10
str_version_len equ $ - str_version

str_try:
    db "Try 'nice --help' for more information.", 10
str_try_len equ $ - str_try

str_inv_opt_pre:
    db "nice: unrecognized option '", 0
str_inv_opt_pre_len equ $ - str_inv_opt_pre - 1

str_inv_opt_post:
    db "'", 10, 0
str_inv_opt_post_len equ $ - str_inv_opt_post - 1

str_missing_adj:
    db "nice: option requires an argument -- 'n'", 10
str_missing_adj_len equ $ - str_missing_adj

str_inv_adj_pre:
    db "nice: invalid adjustment '", 0
str_inv_adj_pre_len equ $ - str_inv_adj_pre - 1

str_inv_adj_post:
    db "'", 10, 0
str_inv_adj_post_len equ $ - str_inv_adj_post - 1

str_prog_prefix:
    db "nice: ", 0
str_prog_prefix_len equ $ - str_prog_prefix - 1

str_enoent:
    db ": No such file or directory", 10
str_enoent_len equ $ - str_enoent

str_eperm:
    db ": Permission denied", 10
str_eperm_len equ $ - str_eperm

; Non-executable stack
section .note.GNU-stack noalloc noexec nowrite progbits
