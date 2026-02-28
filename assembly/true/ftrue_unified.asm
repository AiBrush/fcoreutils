; ============================================================
; ftrue_unified.asm — GNU-compatible 'true' command
; Single nasm -f bin file with hand-crafted ELF header.
;
; true: ignores all arguments, always exits with code 0.
; Handles --help and --version when argc == 2 (GNU behavior).
;
; BUILD:
;   nasm -f bin ftrue_unified.asm -o ftrue_release && chmod +x ftrue_release
; ============================================================

BITS 64
ORG 0x400000

; --- ELF Header (64 bytes) ---
ehdr:
    db 0x7f, 'E','L','F'       ; magic
    db 2                        ; 64-bit
    db 1                        ; little endian
    db 1                        ; ELF version
    db 0                        ; OS/ABI: System V
    dq 0                        ; padding
    dw 2                        ; ET_EXEC
    dw 0x3e                     ; x86_64
    dd 1                        ; ELF version
    dq _start                   ; entry point
    dq phdr - $$                ; program header offset
    dq 0                        ; section header offset (none)
    dd 0                        ; flags
    dw ehdr_size                ; ELF header size
    dw phdr_size                ; program header entry size
    dw 2                        ; 2 program headers (PT_LOAD + PT_GNU_STACK)
    dw 64                       ; section header entry size
    dw 0                        ; section header count
    dw 0                        ; section name index
ehdr_size equ $ - ehdr

; --- Program Header 1: PT_LOAD (code + data) ---
phdr:
    dd 1                        ; PT_LOAD
    dd 5                        ; PF_R | PF_X
    dq 0                        ; offset
    dq $$                       ; virtual address
    dq $$                       ; physical address
    dq file_size                ; file size
    dq file_size                ; memory size
    dq 0x200000                 ; alignment
phdr_size equ $ - phdr

; --- Program Header 2: PT_GNU_STACK (non-executable stack) ---
    dd 0x6474E551               ; PT_GNU_STACK
    dd 6                        ; PF_R | PF_W (no PF_X — NX stack)
    dq 0, 0, 0, 0, 0           ; offset, vaddr, paddr, filesz, memsz: unused
    dq 0x10                     ; alignment

; --- Code ---
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
    mov     esi, help_text
    mov     edx, help_text_len
    jmp     .print_exit

.chk_ver:
    ; Check for "--version" (10 bytes: '-','-','v','e','r','s','i','o','n','\0')
    cmp     dword [rbx], 0x65762D2D     ; "--ve"
    jne     .exit_ok
    cmp     dword [rbx+4], 0x6F697372   ; "rsio"
    jne     .exit_ok
    cmp     word [rbx+8], 0x006E        ; "n\0"
    jne     .exit_ok

    ; Matched "--version" — print version text to stdout
    mov     esi, version_text
    mov     edx, version_text_len

.print_exit:
    mov     eax, 1              ; SYS_WRITE
    mov     edi, 1              ; fd = STDOUT
    syscall
    ; Fall through to exit_ok (ignore write errors — GNU true exits 0 regardless)

.exit_ok:
    xor     edi, edi            ; exit code 0
    mov     eax, 60             ; SYS_EXIT
    syscall


; --- Data ---
; @@DATA_START@@
help_text:
    db "Usage: true [ignored command line arguments]", 10
    db "  or:  true OPTION", 10
    db "Exit with a status code indicating success.", 10, 10
    db "      --help        display this help and exit", 10
    db "      --version     output version information and exit", 10, 10
    db "Your shell may have its own version of true, which usually supersedes", 10
    db "the version described here.  Please refer to your shell's documentation", 10
    db "for details about the options it supports.", 10, 10
    db "GNU coreutils online help: <https://www.gnu.org/software/coreutils/>", 10
    db "Full documentation <https://www.gnu.org/software/coreutils/true>", 10
    db "or available locally via: info '(coreutils) true invocation'", 10
help_text_len equ $ - help_text

version_text:
    db "true (GNU coreutils) 9.7", 10
    db "Packaged by Debian (9.7-3)", 10
    db "Copyright (C) 2025 Free Software Foundation, Inc.", 10
    db "License GPLv3+: GNU GPL version 3 or later <https://gnu.org/licenses/gpl.html>.", 10
    db "This is free software: you are free to change and redistribute it.", 10
    db "There is NO WARRANTY, to the extent permitted by law.", 10, 10
    db "Written by Jim Meyering.", 10
version_text_len equ $ - version_text
; @@DATA_END@@

file_size equ $ - $$
