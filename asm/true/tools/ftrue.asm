; ftrue.asm — exit with status 0
;
; GNU true handles --help and --version ONLY when argc == 2
; (i.e., the flag is the sole argument). All other arguments
; are silently ignored. Always exits with code 0.

%include "include/linux.inc"

extern asm_write
extern asm_exit

global _start

section .text

_start:
    mov     ecx, [rsp]          ; argc (32-bit sufficient)
    cmp     ecx, 2
    jne     .exit_ok            ; only check --help/--version when argc == 2

    mov     rbx, [rsp + 16]     ; argv[1] (callee-saved register)

    ; Check for "--help" (7 bytes: '-','-','h','e','l','p','\0')
    cmp     dword [rbx], 0x65682D2D     ; "--he" in little-endian
    jne     .chk_ver
    cmp     word [rbx+4], 0x706C        ; "lp"
    jne     .chk_ver
    cmp     byte [rbx+6], 0             ; null terminator
    jne     .chk_ver

    ; Matched "--help" — print help text to stdout
    mov     edi, STDOUT
    mov     rsi, help_text
    mov     edx, help_text_len
    call    asm_write
    jmp     .exit_ok

.chk_ver:
    ; Check for "--version" (10 bytes: '-','-','v','e','r','s','i','o','n','\0')
    cmp     dword [rbx], 0x65762D2D     ; "--ve"
    jne     .exit_ok
    cmp     dword [rbx+4], 0x6F697372   ; "rsio"
    jne     .exit_ok
    cmp     word [rbx+8], 0x006E        ; "n\0"
    jne     .exit_ok

    ; Matched "--version" — print version text to stdout
    mov     edi, STDOUT
    mov     rsi, version_text
    mov     edx, version_text_len
    call    asm_write

.exit_ok:
    xor     edi, edi            ; exit code 0
    call    asm_exit


section .rodata

help_text:
    db "Usage: true [ignored command line arguments]", 10
    db "  or:  true OPTION", 10
    db "Exit with a status code indicating success.", 10, 10
    db "      --help        display this help and exit", 10
    db "      --version     output version information and exit", 10, 10
    db "NOTE: your shell may have its own version of true, which usually supersedes", 10
    db "the version described here.  Please refer to your shell's documentation", 10
    db "for details about the options it supports.", 10, 10
    db "GNU coreutils online help: <https://www.gnu.org/software/coreutils/>", 10
    db "Report any translation bugs to <https://translationproject.org/team/>", 10
    db "Full documentation <https://www.gnu.org/software/coreutils/true>", 10
    db "or available locally via: info '(coreutils) true invocation'", 10
help_text_len equ $ - help_text

version_text:
    db "true (GNU coreutils) 9.4", 10
    db "Copyright (C) 2023 Free Software Foundation, Inc.", 10
    db "License GPLv3+: GNU GPL version 3 or later <https://gnu.org/licenses/gpl.html>.", 10
    db "This is free software: you are free to change and redistribute it.", 10
    db "There is NO WARRANTY, to the extent permitted by law.", 10, 10
    db "Written by Jim Meyering.", 10
version_text_len equ $ - version_text
