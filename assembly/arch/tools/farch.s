.intel_syntax noprefix
.section .note.GNU-stack,"",@progbits
.include "include/linux.inc"

.extern asm_write
.extern asm_exit
.extern asm_write_stdout
.extern asm_write_err
.extern asm_strlen
.extern asm_strcmp

.global _start

# =========================================================
# Data section — all GNU-identical strings
# =========================================================
.section .rodata

str_help:
    .ascii "Usage: arch [OPTION]...\n"
    .ascii "Print machine architecture.\n"
    .ascii "\n"
    .ascii "      --help        display this help and exit\n"
    .ascii "      --version     output version information and exit\n"
    .ascii "\n"
    .ascii "GNU coreutils online help: <https://www.gnu.org/software/coreutils/>\n"
    .ascii "Full documentation <https://www.gnu.org/software/coreutils/arch>\n"
    .ascii "or available locally via: info '(coreutils) arch invocation'\n"
str_help_end:
.equ str_help_len, str_help_end - str_help

str_version:
    .ascii "arch (GNU coreutils) 9.7\n"
    .ascii "Packaged by Debian (9.7-3)\n"
    .ascii "Copyright (C) 2025 Free Software Foundation, Inc.\n"
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

# Error message fragments
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

# =========================================================
# BSS section — fixed-size buffers
# =========================================================
.section .bss
    .lcomm utsname_buf, UTSNAME_SIZE

# =========================================================
# Text section
# =========================================================
.section .text

_start:
    # 1. Parse argc/argv from stack
    mov     r14, [rsp]          # argc
    lea     r15, [rsp + 8]      # argv

    # 2. If argc == 1, just print architecture
    cmp     r14, 1
    jle     .run_main

    # 3. argc >= 2: examine argv[1]
    mov     r12, [r15 + 8]      # r12 = argv[1]

    # Check if first byte is '-'
    movzx   eax, byte ptr [r12]
    cmp     al, '-'
    jne     .extra_operand

    # Starts with '-'. Check second byte.
    movzx   eax, byte ptr [r12 + 1]
    test    al, al
    jz      .extra_operand      # Just "-" alone → extra operand (GNU treats single "-" as operand)

    cmp     al, '-'
    jne     .invalid_short_opt  # Single dash + char → invalid option -X

    # Starts with '--'. Check third byte.
    movzx   eax, byte ptr [r12 + 2]
    test    al, al
    jz      .handle_dashdash    # Just "--" → end of options

    # Long option: compare with --help
    lea     rdi, [r12]
    lea     rsi, [rip + str_dashdash_help]
    call    asm_strcmp
    test    rax, rax
    jz      .print_help

    # Compare with --version
    lea     rdi, [r12]
    lea     rsi, [rip + str_dashdash_version]
    call    asm_strcmp
    test    rax, rax
    jz      .print_version

    # Unrecognized long option
    jmp     .unrecognized_option

# ── Handle "--" (end of options) ──────────────────────────
.handle_dashdash:
    # If argc == 2, just "--" → print architecture
    cmp     r14, 2
    jle     .run_main

    # argc > 2: argv[2] is an extra operand
    mov     r12, [r15 + 16]     # argv[2]
    jmp     .extra_operand

# ── Print help ────────────────────────────────────────────
.print_help:
    lea     rsi, [rip + str_help]
    mov     rdx, str_help_len
    call    asm_write_stdout
    xor     rdi, rdi
    call    asm_exit

# ── Print version ─────────────────────────────────────────
.print_version:
    lea     rsi, [rip + str_version]
    mov     rdx, str_version_len
    call    asm_write_stdout
    xor     rdi, rdi
    call    asm_exit

# ── Error: unrecognized option (--something) ──────────────
.unrecognized_option:
    # Build error: "arch: unrecognized option '--something'\n"
    # Write to stderr in parts
    lea     rsi, [rip + str_err_prefix]
    mov     rdx, str_err_prefix_len
    call    asm_write_err

    lea     rsi, [rip + str_unrecognized]
    mov     rdx, str_unrecognized_len
    call    asm_write_err

    # Write the argument itself
    mov     rdi, r12
    call    asm_strlen
    mov     rdx, rax
    mov     rsi, r12
    call    asm_write_err

    # Write suffix: "'\n"
    lea     rsi, [rip + str_err_suffix]
    mov     rdx, str_err_suffix_len
    call    asm_write_err

    # Write: "Try 'arch --help' for more information.\n"
    lea     rsi, [rip + str_try_help]
    mov     rdx, str_try_help_len
    call    asm_write_err

    mov     rdi, 1
    call    asm_exit

# ── Error: invalid option (short -X) ─────────────────────
.invalid_short_opt:
    # "arch: invalid option -- 'X'\n"
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

# ── Error: extra operand ─────────────────────────────────
.extra_operand:
    lea     rsi, [rip + str_err_prefix]
    mov     rdx, str_err_prefix_len
    call    asm_write_err

    lea     rsi, [rip + str_extra_operand]
    mov     rdx, str_extra_operand_len
    call    asm_write_err

    # Write the operand
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

# ── Main: print machine architecture ─────────────────────
.run_main:
    # Call uname(buf)
    mov     rax, SYS_UNAME
    lea     rdi, [rip + utsname_buf]
    syscall

    # Check for error
    test    rax, rax
    jnz     .uname_error

    # Get pointer to machine field (offset 260)
    lea     rdi, [rip + utsname_buf + UTS_MACHINE]

    # Calculate length
    call    asm_strlen
    mov     r13, rax            # save length

    # Write machine name
    lea     rsi, [rip + utsname_buf + UTS_MACHINE]
    mov     rdx, r13
    call    asm_write_stdout

    # Write newline
    lea     rsi, [rip + str_newline]
    mov     rdx, 1
    call    asm_write_stdout

    # Exit 0
    xor     rdi, rdi
    call    asm_exit

.uname_error:
    # Should never happen, but exit 1 if it does
    mov     rdi, 1
    call    asm_exit
