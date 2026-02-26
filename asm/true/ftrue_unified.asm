; ============================================================
; ftrue_unified.asm — AUTO-GENERATED unified file
; GNU-compatible 'true' command in a single nasm -f bin file
;
; true: ignores all arguments, always exits with code 0
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
    dw 1                        ; 1 program header
    dw 64                       ; section header entry size
    dw 0                        ; section header count
    dw 0                        ; section name index
ehdr_size equ $ - ehdr

; --- Program Header (56 bytes) ---
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

; --- Code ---
_start:
    xor     edi, edi            ; exit code 0
    mov     eax, 60             ; SYS_EXIT
    syscall

file_size equ $ - $$
