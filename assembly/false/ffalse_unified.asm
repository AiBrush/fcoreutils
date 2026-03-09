; ============================================================
; ffalse_unified.asm — GNU-compatible 'false' command
; Single nasm -f bin file with hand-crafted ELF header.
;
; false: ignores all arguments, always exits with code 1.
;
; BUILD:
;   nasm -f bin ffalse_unified.asm -o ffalse && chmod +x ffalse
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
    ; false: ignore all arguments, exit with code 1
    mov     edi, 1              ; exit code 1
    mov     eax, 60             ; SYS_EXIT
    syscall

file_size equ $ - $$
