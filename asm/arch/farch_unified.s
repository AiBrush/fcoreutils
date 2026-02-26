# ============================================================
# farch_unified.s — AUTO-GENERATED unified assembly file
# Implements: arch (print machine architecture)
# All modules inlined, no external dependencies
# ============================================================
.intel_syntax noprefix

# Mark stack as non-executable
.section .note.GNU-stack,"",@progbits

# ── Constants (from include/linux.inc) ────────────────────
.equ SYS_WRITE,      1
.equ SYS_EXIT,      60
.equ SYS_UNAME,     63
.equ STDOUT,         1
.equ STDERR,         2
.equ UTS_MACHINE,  260
.equ UTSNAME_SIZE, 390
.equ ARG_BUF,     4096

# ── Entry point ───────────────────────────────────────────
.global _start

.section .rodata

str_help:
    .ascii "Usage: arch [OPTION]...\n"
    .ascii "Print machine architecture.\n"
    .ascii "\n"
    .ascii "      --help        display this help and exit\n"
    .ascii "      --version     output version information and exit\n"
    .ascii "\n"
    .ascii "GNU coreutils online help: <https://www.gnu.org/software/coreutils/>\n"
    .ascii "Report any translation bugs to <https://translationproject.org/team/>\n"
    .ascii "Full documentation <https://www.gnu.org/software/coreutils/arch>\n"
    .ascii "or available locally via: info '(coreutils) arch invocation'\n"
str_help_end:
.equ str_help_len, str_help_end - str_help

str_version:
    .ascii "arch (GNU coreutils) 9.4\n"
    .ascii "Copyright (C) 2023 Free Software Foundation, Inc.\n"
    .ascii "License GPLv3+: GNU GPL version 3 or later <https://gnu.org/licenses/gpl.html>.\n"
    .ascii "This is free software: you are free to change and redistribute it.\n"
    .ascii "There is NO WARRANTY, to the extent permitted by law.\n"
    .ascii "\n"
    .ascii "Written by David MacKenzie and Karel Zak.\n"
str_version_end:
.equ str_version_len, str_version_end - str_version

str_dashdash_help:
    .asciz "--help"
str_dashdash_version:
    .asciz "--version"

str_err_prefix:
    .ascii "arch: "
str_err_prefix_end:
.equ str_err_prefix_len, str_err_prefix_end - str_err_prefix

str_unrecognized:
    .ascii "unrecognized option '"
str_unrecognized_end:
.equ str_unrecognized_len, str_unrecognized_end - str_unrecognized

str_invalid_opt:
    .ascii "invalid option -- '"
str_invalid_opt_end:
.equ str_invalid_opt_len, str_invalid_opt_end - str_invalid_opt

str_extra_operand:
    .ascii "extra operand '"
str_extra_operand_end:
.equ str_extra_operand_len, str_extra_operand_end - str_extra_operand

str_err_suffix:
    .ascii "'\n"
str_err_suffix_end:
.equ str_err_suffix_len, str_err_suffix_end - str_err_suffix

str_try_help:
    .ascii "Try 'arch --help' for more information.\n"
str_try_help_end:
.equ str_try_help_len, str_try_help_end - str_try_help

str_newline:
    .byte 10

# ── BSS section ───────────────────────────────────────────
.section .bss
    .lcomm utsname_buf, UTSNAME_SIZE

# ── Text section ──────────────────────────────────────────
.section .text

# ── Inlined library: io ───────────────────────────────────
# asm_write(rdi=fd, rsi=buf, rdx=len) -> rax
asm_write:
.Lretry_write:
    mov     rax, SYS_WRITE
    syscall
    cmp     rax, -4
    je      .Lretry_write
    ret

asm_write_stdout:
    mov     rdi, STDOUT
    jmp     asm_write

asm_write_err:
    mov     rdi, STDERR
    jmp     asm_write

asm_exit:
    mov     rax, SYS_EXIT
    syscall

# ── Inlined library: str ──────────────────────────────────
# asm_strlen(rdi=str) -> rax=length
asm_strlen:
    xor     rax, rax
.Lstrlen_loop:
    cmp     byte ptr [rdi + rax], 0
    je      .Lstrlen_done
    inc     rax
    jmp     .Lstrlen_loop
.Lstrlen_done:
    ret

# asm_strcmp(rdi=s1, rsi=s2) -> rax: 0 if equal
asm_strcmp:
    xor     rcx, rcx
.Lstrcmp_loop:
    mov     al, byte ptr [rdi + rcx]
    mov     dl, byte ptr [rsi + rcx]
    cmp     al, dl
    jne     .Lstrcmp_diff
    test    al, al
    jz      .Lstrcmp_equal
    inc     rcx
    jmp     .Lstrcmp_loop
.Lstrcmp_equal:
    xor     rax, rax
    ret
.Lstrcmp_diff:
    movzx   rax, al
    movzx   rdx, dl
    sub     rax, rdx
    ret

# ── Main program ──────────────────────────────────────────
_start:
    mov     r14, [rsp]
    lea     r15, [rsp + 8]

    cmp     r14, 1
    jle     .run_main

    mov     r12, [r15 + 8]

    movzx   eax, byte ptr [r12]
    cmp     al, '-'
    jne     .extra_operand

    movzx   eax, byte ptr [r12 + 1]
    test    al, al
    jz      .extra_operand

    cmp     al, '-'
    jne     .invalid_short_opt

    movzx   eax, byte ptr [r12 + 2]
    test    al, al
    jz      .handle_dashdash

    lea     rdi, [r12]
    lea     rsi, [rip + str_dashdash_help]
    call    asm_strcmp
    test    rax, rax
    jz      .print_help

    lea     rdi, [r12]
    lea     rsi, [rip + str_dashdash_version]
    call    asm_strcmp
    test    rax, rax
    jz      .print_version

    jmp     .unrecognized_option

.handle_dashdash:
    cmp     r14, 2
    jle     .run_main
    mov     r12, [r15 + 16]
    jmp     .extra_operand

.print_help:
    lea     rsi, [rip + str_help]
    mov     rdx, str_help_len
    call    asm_write_stdout
    xor     rdi, rdi
    call    asm_exit

.print_version:
    lea     rsi, [rip + str_version]
    mov     rdx, str_version_len
    call    asm_write_stdout
    xor     rdi, rdi
    call    asm_exit

.unrecognized_option:
    lea     rsi, [rip + str_err_prefix]
    mov     rdx, str_err_prefix_len
    call    asm_write_err
    lea     rsi, [rip + str_unrecognized]
    mov     rdx, str_unrecognized_len
    call    asm_write_err
    mov     rdi, r12
    call    asm_strlen
    mov     rdx, rax
    mov     rsi, r12
    call    asm_write_err
    lea     rsi, [rip + str_err_suffix]
    mov     rdx, str_err_suffix_len
    call    asm_write_err
    lea     rsi, [rip + str_try_help]
    mov     rdx, str_try_help_len
    call    asm_write_err
    mov     rdi, 1
    call    asm_exit

.invalid_short_opt:
    lea     rsi, [rip + str_err_prefix]
    mov     rdx, str_err_prefix_len
    call    asm_write_err
    lea     rsi, [rip + str_invalid_opt]
    mov     rdx, str_invalid_opt_len
    call    asm_write_err
    # Write only the single char after '-' (GNU prints just the first invalid char)
    lea     rsi, [r12 + 1]
    mov     rdx, 1
    call    asm_write_err
    lea     rsi, [rip + str_err_suffix]
    mov     rdx, str_err_suffix_len
    call    asm_write_err
    lea     rsi, [rip + str_try_help]
    mov     rdx, str_try_help_len
    call    asm_write_err
    mov     rdi, 1
    call    asm_exit

.extra_operand:
    lea     rsi, [rip + str_err_prefix]
    mov     rdx, str_err_prefix_len
    call    asm_write_err
    lea     rsi, [rip + str_extra_operand]
    mov     rdx, str_extra_operand_len
    call    asm_write_err
    mov     rdi, r12
    call    asm_strlen
    mov     rdx, rax
    mov     rsi, r12
    call    asm_write_err
    lea     rsi, [rip + str_err_suffix]
    mov     rdx, str_err_suffix_len
    call    asm_write_err
    lea     rsi, [rip + str_try_help]
    mov     rdx, str_try_help_len
    call    asm_write_err
    mov     rdi, 1
    call    asm_exit

.run_main:
    mov     rax, SYS_UNAME
    lea     rdi, [rip + utsname_buf]
    syscall
    test    rax, rax
    jnz     .uname_error

    lea     rdi, [rip + utsname_buf + UTS_MACHINE]
    call    asm_strlen
    mov     r13, rax

    lea     rsi, [rip + utsname_buf + UTS_MACHINE]
    mov     rdx, r13
    call    asm_write_stdout

    lea     rsi, [rip + str_newline]
    mov     rdx, 1
    call    asm_write_stdout

    xor     rdi, rdi
    call    asm_exit

.uname_error:
    mov     rdi, 1
    call    asm_exit
