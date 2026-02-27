; ============================================================
; fwhoami_unified.asm — unified single-file whoami
; AUTO-GENERATED — do not edit manually
; Build: nasm -f bin fwhoami_unified.asm -o fwhoami_release
; ============================================================

BITS 64
ORG 0x400000

; ── Linux syscall numbers ──────────────────────────────────
%define SYS_READ        0
%define SYS_WRITE       1
%define SYS_OPEN        2
%define SYS_CLOSE       3
%define SYS_EXIT       60
%define SYS_GETEUID    107

%define STDIN           0
%define STDOUT          1
%define STDERR          2

%define O_RDONLY        0
%define BUF_SIZE    65536

; ── ELF64 Header (64 bytes) ───────────────────────────────
ehdr:
    db 0x7F, 'E','L','F'       ; magic
    db 2                        ; 64-bit
    db 1                        ; little-endian
    db 1                        ; ELF version
    db 0                        ; OS/ABI: System V
    dq 0                        ; padding
    dw 2                        ; ET_EXEC
    dw 0x3E                     ; x86_64
    dd 1                        ; ELF version
    dq _start                   ; entry point
    dq phdr - $$                ; program header offset
    dq 0                        ; section header offset (none)
    dd 0                        ; flags
    dw ehdr_size                ; ELF header size
    dw phdr_size                ; program header entry size
    dw 2                        ; 2 program headers (LOAD + GNU_STACK)
    dw 64                       ; section header entry size
    dw 0                        ; section header count
    dw 0                        ; section name index
ehdr_size equ $ - ehdr

; ── Program Headers ────────────────────────────────────────
phdr:
    ; PT_LOAD — load everything (RWX for code+bss in single segment)
    dd 1                        ; PT_LOAD
    dd 7                        ; PF_R | PF_W | PF_X
    dq 0                        ; offset in file
    dq $$                       ; virtual address
    dq $$                       ; physical address
    dq file_size                ; file size
    dq file_size + bss_size     ; memory size (includes bss)
    dq 0x200000                 ; alignment
phdr_size equ $ - phdr

    ; PT_GNU_STACK — non-executable stack
    dd 0x6474e551               ; PT_GNU_STACK
    dd 6                        ; PF_R | PF_W (no PF_X)
    dq 0
    dq 0
    dq 0
    dq 0
    dq 0
    dq 0x10                     ; alignment

; ── Read-only data ─────────────────────────────────────────
str_help:       db "Usage: whoami [OPTION]...", 10
                db "Print the user name associated with the current effective user ID.", 10
                db "Same as id -un.", 10
                db 10
                db "      --help        display this help and exit", 10
                db "      --version     output version information and exit", 10
                db 10
                db "GNU coreutils online help: <https://www.gnu.org/software/coreutils/>", 10
                db "Full documentation <https://www.gnu.org/software/coreutils/whoami>", 10
                db "or available locally via: info '(coreutils) whoami invocation'", 10
str_help_len    equ $ - str_help

str_version:    db "whoami (GNU coreutils) 9.7", 10
    db "Packaged by Debian (9.7-3)", 10
                db "Copyright (C) 2025 Free Software Foundation, Inc.", 10
                db "License GPLv3+: GNU GPL version 3 or later <https://gnu.org/licenses/gpl.html>.", 10
                db "This is free software: you are free to change and redistribute it.", 10
                db "There is NO WARRANTY, to the extent permitted by law.", 10
                db 10
                db "Written by Richard Mlynarik.", 10
str_ver_len     equ $ - str_version

str_flag_help:      db "--help", 0
str_flag_version:   db "--version", 0
str_passwd_path:    db "/etc/passwd", 0
str_err_prefix:     db "whoami: ", 0
str_err_no_name:    db "cannot find name for user ID ", 0
str_err_operand1:   db "whoami: extra operand ", 0xE2, 0x80, 0x98, 0
str_err_operand2:   db 0xE2, 0x80, 0x99, 10, "Try 'whoami --help' for more information.", 10, 0
str_err_unrec1:     db "whoami: unrecognized option '", 0
str_err_unrec2:     db "'", 10, "Try 'whoami --help' for more information.", 10, 0
str_err_invalid1:   db "whoami: invalid option -- '", 0
str_err_invalid2:   db "'", 10, "Try 'whoami --help' for more information.", 10, 0
newline:            db 10

; ── Code ───────────────────────────────────────────────────
_start:
    ; Get argc and argv from the stack
    mov     r14, [rsp]          ; argc
    lea     r15, [rsp + 8]      ; argv

    ; If argc >= 2, check for flags
    cmp     r14, 2
    jl      .run_main

    ; Get argv[1]
    mov     rsi, [r15 + 8]      ; argv[1]

    ; Check if argv[1] starts with '-'
    cmp     byte [rsi], '-'
    jne     .extra_operand_argv1

    ; argv[1] starts with '-'
    cmp     byte [rsi + 1], 0
    je      .extra_operand_argv1 ; "-" alone is an extra operand

    cmp     byte [rsi + 1], '-'
    jne     .invalid_short_option ; "-x" is an invalid short option

    ; argv[1] starts with '--'
    cmp     byte [rsi + 2], 0
    je      .end_of_options     ; "--" alone is end-of-options marker

    ; Check --help
    mov     rdi, rsi
    mov     rsi, str_flag_help
    call    _strcmp
    test    eax, eax
    jz      .show_help

    ; Check --version
    mov     rdi, [r15 + 8]
    mov     rsi, str_flag_version
    call    _strcmp
    test    eax, eax
    jz      .show_version

    ; Unrecognized option starting with --
    jmp     .unrecognized_option

.end_of_options:
    ; "--" means end of options
    ; If argc == 2, no more args after "--" -> run main
    cmp     r14, 2
    je      .run_main
    ; If argc > 2, argv[2] is an extra operand
    mov     rbx, [r15 + 16]     ; argv[2]
    jmp     .report_extra_operand

.invalid_short_option:
    ; "-x" -> "whoami: invalid option -- 'x'"
    mov     rdi, STDERR
    mov     rsi, str_err_invalid1
    call    _strlen_and_write

    ; Write the single option character (argv[1][1])
    mov     rsi, [r15 + 8]
    add     rsi, 1              ; point to char after '-'
    mov     rdi, STDERR
    mov     rdx, 1
    call    _write

    ; Write closing quote + try message
    mov     rdi, STDERR
    mov     rsi, str_err_invalid2
    call    _strlen_and_write

    mov     rdi, 1
    jmp     _exit

.extra_operand_argv1:
    mov     rbx, [r15 + 8]      ; argv[1]

.report_extra_operand:
    ; whoami: extra operand 'ARG'
    ; rbx = pointer to the operand string
    mov     rdi, STDERR
    mov     rsi, str_err_operand1
    call    _strlen_and_write

    ; Write the argument
    mov     rdi, rbx
    call    _strlen
    mov     rdx, rax
    mov     rsi, rbx
    mov     rdi, STDERR
    call    _write

    ; Write closing quote + rest
    mov     rdi, STDERR
    mov     rsi, str_err_operand2
    call    _strlen_and_write
    mov     rdi, 1
    jmp     _exit

.unrecognized_option:
    mov     rdi, STDERR
    mov     rsi, str_err_unrec1
    call    _strlen_and_write
    mov     rdi, [r15 + 8]
    push    rdi
    call    _strlen
    mov     rdx, rax
    pop     rsi
    mov     rdi, STDERR
    call    _write
    mov     rdi, STDERR
    mov     rsi, str_err_unrec2
    call    _strlen_and_write
    mov     rdi, 1
    jmp     _exit

.show_help:
    mov     rdi, STDOUT
    mov     rsi, str_help
    mov     rdx, str_help_len
    call    _write
    xor     rdi, rdi
    jmp     _exit

.show_version:
    mov     rdi, STDOUT
    mov     rsi, str_version
    mov     rdx, str_ver_len
    call    _write
    xor     rdi, rdi
    jmp     _exit

.run_main:
    ; geteuid() syscall
    mov     rax, SYS_GETEUID
    syscall
    mov     r12, rax            ; r12 = euid

    ; Open /etc/passwd
    mov     rdi, str_passwd_path
    xor     esi, esi            ; O_RDONLY
    xor     edx, edx
    mov     rax, SYS_OPEN
    syscall
    test    rax, rax
    js      .err_no_name
    mov     r13, rax            ; r13 = fd

    ; Read the file into buffer (bss area)
    xor     ebx, ebx            ; total bytes read
.read_loop:
    mov     rdi, r13
    lea     rsi, [rel passwd_buf]
    add     rsi, rbx
    mov     rdx, BUF_SIZE
    sub     rdx, rbx
    jle     .close_and_parse
    mov     rax, SYS_READ
    syscall
    cmp     rax, -4
    je      .read_loop
    test    rax, rax
    jle     .close_and_parse
    add     rbx, rax
    jmp     .read_loop

.close_and_parse:
    push    rbx
    mov     rdi, r13
    mov     rax, SYS_CLOSE
    syscall
    pop     rbx                 ; rbx = total bytes

    ; Parse /etc/passwd — find line where UID field matches r12
    xor     ecx, ecx
.parse_line:
    cmp     ecx, ebx
    jge     .err_no_name
    mov     r8d, ecx            ; start of username

    ; Skip to first colon
.find_colon1:
    cmp     ecx, ebx
    jge     .err_no_name
    cmp     byte [passwd_buf + ecx], ':'
    je      .found_colon1
    cmp     byte [passwd_buf + ecx], 10
    je      .next_line1
    inc     ecx
    jmp     .find_colon1
.next_line1:
    inc     ecx
    jmp     .parse_line
.found_colon1:
    mov     r9d, ecx            ; end of username
    inc     ecx

    ; Skip password field
.find_colon2:
    cmp     ecx, ebx
    jge     .err_no_name
    cmp     byte [passwd_buf + ecx], ':'
    je      .found_colon2
    cmp     byte [passwd_buf + ecx], 10
    je      .next_line2
    inc     ecx
    jmp     .find_colon2
.next_line2:
    inc     ecx
    jmp     .parse_line
.found_colon2:
    inc     ecx

    ; Parse UID number
    xor     eax, eax
    mov     r10d, 10
.parse_uid:
    cmp     ecx, ebx
    jge     .err_no_name
    movzx   edx, byte [passwd_buf + ecx]
    cmp     dl, ':'
    je      .uid_done
    cmp     dl, 10
    je      .skip_rest
    sub     dl, '0'
    cmp     dl, 9
    ja      .skip_rest
    imul    eax, r10d
    movzx   edx, dl
    add     eax, edx
    inc     ecx
    jmp     .parse_uid

.skip_rest:
    cmp     ecx, ebx
    jge     .err_no_name
    cmp     byte [passwd_buf + ecx], 10
    je      .at_nl
    inc     ecx
    jmp     .skip_rest
.at_nl:
    inc     ecx
    jmp     .parse_line

.uid_done:
    cmp     eax, r12d
    jne     .skip_rest

    ; Found! Copy username to name_buf
    mov     eax, r9d
    sub     eax, r8d
    cmp     eax, 255
    jg      .err_no_name
    xor     edx, edx
.copy_name:
    cmp     edx, eax
    jge     .name_copied
    movzx   ecx, byte [passwd_buf + r8d]
    mov     byte [name_buf + edx], cl
    inc     r8d
    inc     edx
    jmp     .copy_name
.name_copied:
    mov     byte [name_buf + edx], 10
    inc     edx
    mov     rdi, STDOUT
    mov     rsi, name_buf
    call    _write
    xor     rdi, rdi
    jmp     _exit

.err_no_name:
    mov     rdi, STDERR
    mov     rsi, str_err_prefix
    call    _strlen_and_write
    mov     rdi, STDERR
    mov     rsi, str_err_no_name
    call    _strlen_and_write
    ; Convert UID to string
    mov     rdi, r12
    mov     rsi, uid_str_buf
    mov     rdx, 32
    call    _uint_to_str
    mov     rdx, rax
    mov     rdi, STDERR
    mov     rsi, uid_str_buf
    call    _write
    mov     rdi, STDERR
    mov     rsi, newline
    mov     rdx, 1
    call    _write
    mov     rdi, 1
    jmp     _exit

; ── Inlined library functions ──────────────────────────────

; _write(rdi=fd, rsi=buf, rdx=len) — retries on EINTR
_write:
    mov     rax, SYS_WRITE
    syscall
    cmp     rax, -4
    je      _write
    ret

; _exit(rdi=code) — never returns
_exit:
    mov     rax, SYS_EXIT
    syscall

; _strlen(rdi=str) -> rax=length
_strlen:
    xor     eax, eax
.loop:
    cmp     byte [rdi + rax], 0
    je      .done
    inc     rax
    jmp     .loop
.done:
    ret

; _strcmp(rdi=s1, rsi=s2) -> eax: 0=equal
_strcmp:
.loop:
    movzx   eax, byte [rdi]
    movzx   ecx, byte [rsi]
    cmp     al, cl
    jne     .diff
    test    al, al
    jz      .equal
    inc     rdi
    inc     rsi
    jmp     .loop
.equal:
    xor     eax, eax
    ret
.diff:
    sub     eax, ecx
    ret

; _strlen_and_write(rdi=fd, rsi=null_terminated_string)
_strlen_and_write:
    push    rdi
    mov     rdi, rsi
    push    rsi
    call    _strlen
    mov     rdx, rax
    pop     rsi
    pop     rdi
    call    _write
    ret

; _uint_to_str(rdi=value, rsi=buf, rdx=bufsize) -> rax=length
_uint_to_str:
    push    rbx
    push    r12
    mov     r12, rsi
    mov     rbx, rdx
    xor     ecx, ecx
    mov     rax, rdi
    mov     r8, 10
.dloop:
    xor     edx, edx
    div     r8
    add     dl, '0'
    push    rdx
    inc     ecx
    test    rax, rax
    jnz     .dloop
    xor     eax, eax
.sloop:
    cmp     eax, ebx
    jge     .sdone
    pop     rdx
    mov     byte [r12 + rax], dl
    inc     eax
    dec     ecx
    jnz     .sloop
.sdone:
    pop     r12
    pop     rbx
    ret

; ── BSS (uninitialized data, after file end) ───────────────
file_size equ $ - $$

; BSS section — these addresses are in memory but not in the file
; They start at virtual address $$ + file_size
passwd_buf equ $$ + file_size
; 65536 bytes for passwd
name_buf   equ passwd_buf + BUF_SIZE
; 256 bytes for name
uid_str_buf equ name_buf + 256
; 32 bytes for uid string
bss_size   equ BUF_SIZE + 256 + 32
