; ============================================================
; fsync_unified.asm — sync: synchronize cached writes to persistent storage
; AUTO-GENERATED unified file — do not edit manually
; Build: nasm -f bin fsync_unified.asm -o fsync_release
; ============================================================

BITS 64
ORG 0x400000

; ── Linux x86_64 syscall numbers ───────────────────────────
%define SYS_READ        0
%define SYS_WRITE       1
%define SYS_OPEN        2
%define SYS_CLOSE       3
%define SYS_EXIT       60
%define SYS_SYNC       162
%define SYS_FSYNC      74
%define SYS_FDATASYNC  75
%define SYS_SYNCFS     306

%define O_RDONLY        0
%define STDIN           0
%define STDOUT          1
%define STDERR          2
%define EINTR           4
%define ENOENT          2
%define EACCES          13
%define ENOTDIR         20
%define EISDIR          21
%define ENOMEM          12
%define EMFILE          24
%define ELOOP           40
%define ENAMETOOLONG    36
%define EIO             5
%define EBADF           9
%define EINVAL          22

; ── ELF64 Header (64 bytes) ───────────────────────────────
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
    dw 64                       ; ELF header size
    dw 56                       ; program header entry size
    dw 2                        ; 2 program headers
    dw 64                       ; section header entry size
    dw 0                        ; section header count
    dw 0                        ; section name index

; ── Program Headers (2 x 56 bytes) ────────────────────────
phdr:
    ; PT_LOAD: code + rodata + BSS (RWX)
    dd 1                        ; PT_LOAD
    dd 7                        ; PF_R | PF_W | PF_X
    dq 0                        ; offset
    dq $$                       ; virtual address
    dq $$                       ; physical address
    dq file_size                ; file size
    dq file_size + bss_size     ; memory size (includes BSS)
    dq 0x200000                 ; alignment

    ; PT_GNU_STACK: non-executable stack
    dd 0x6474e551               ; PT_GNU_STACK
    dd 6                        ; PF_R | PF_W (no PF_X)
    dq 0
    dq 0
    dq 0
    dq 0
    dq 0
    dq 0x10                     ; alignment

; ============================================================
; Code section
; ============================================================

_start:
    ; Get argc and argv from stack
    mov     r14, [rsp]          ; argc
    lea     r15, [rsp + 8]      ; argv

    ; Initialize flags (in BSS area, already zero after load)
    mov     byte [flag_data], 0
    mov     byte [flag_filesystem], 0
    mov     qword [file_count], 0

    ; Parse arguments: skip argv[0], start from argv[1]
    mov     r12, 1              ; arg index
    xor     r13, r13            ; 0 = still parsing options, 1 = after --

.parse_loop:
    cmp     r12, r14
    jge     .parse_done

    mov     rbx, [r15 + r12 * 8]   ; argv[i]

    ; If we've seen --, treat everything as a file
    test    r13, r13
    jnz     .add_file

    ; Check first character
    cmp     byte [rbx], '-'
    jne     .add_file

    ; Check if it's just "-" (treat as file)
    cmp     byte [rbx + 1], 0
    je      .add_file

    ; Check if it starts with "--"
    cmp     byte [rbx + 1], '-'
    je      .long_opt

    ; It's a short option string like -d, -f, -df
    jmp     .short_opts

.long_opt:
    ; Check for "--" (end of options)
    cmp     byte [rbx + 2], 0
    jne     .check_long_opts
    mov     r13, 1              ; set after-- flag
    inc     r12
    jmp     .parse_loop

.check_long_opts:
    ; Check --help
    mov     rdi, rbx
    lea     rsi, [rel opt_help]
    call    _strcmp
    test    rax, rax
    jz      .do_help

    ; Check --version
    mov     rdi, rbx
    lea     rsi, [rel opt_version]
    call    _strcmp
    test    rax, rax
    jz      .do_version

    ; Check --data
    mov     rdi, rbx
    lea     rsi, [rel opt_data]
    call    _strcmp
    test    rax, rax
    jz      .set_data

    ; Check --file-system
    mov     rdi, rbx
    lea     rsi, [rel opt_filesystem]
    call    _strcmp
    test    rax, rax
    jz      .set_filesystem

    ; Unrecognized long option
    jmp     .err_unrecognized_opt

.set_data:
    mov     byte [flag_data], 1
    inc     r12
    jmp     .parse_loop

.set_filesystem:
    mov     byte [flag_filesystem], 1
    inc     r12
    jmp     .parse_loop

.short_opts:
    ; Parse each character in the short option string (skip '-')
    lea     rbp, [rbx + 1]     ; pointer to first char after '-'

.short_loop:
    movzx   eax, byte [rbp]
    test    al, al
    jz      .short_done

    cmp     al, 'd'
    je      .short_d
    cmp     al, 'f'
    je      .short_f

    ; Invalid short option
    jmp     .err_invalid_short

.short_d:
    mov     byte [flag_data], 1
    inc     rbp
    jmp     .short_loop

.short_f:
    mov     byte [flag_filesystem], 1
    inc     rbp
    jmp     .short_loop

.short_done:
    inc     r12
    jmp     .parse_loop

.add_file:
    ; Add file pointer to list
    mov     rcx, [file_count]
    cmp     rcx, 255
    jge     .next_arg
    mov     [file_ptrs + rcx * 8], rbx
    inc     qword [file_count]

.next_arg:
    inc     r12
    jmp     .parse_loop

; ── Argument parsing complete ──────────────────────────────

.parse_done:
    ; Check: cannot specify both --data and --file-system
    cmp     byte [flag_data], 0
    je      .no_both_check
    cmp     byte [flag_filesystem], 0
    je      .no_both_check
    ; Both flags set — error
    mov     rdi, STDERR
    lea     rsi, [rel err_prefix]
    mov     rdx, err_prefix_len
    call    _write
    mov     rdi, STDERR
    lea     rsi, [rel err_both]
    mov     rdx, err_both_len
    call    _write
    mov     rdi, 1
    jmp     _exit

.no_both_check:
    ; Check if we have files
    cmp     qword [file_count], 0
    jne     .sync_files

    ; No files — check if -d is set
    cmp     byte [flag_data], 0
    je      .sync_all

    ; -d without files: error
    mov     rdi, STDERR
    lea     rsi, [rel err_prefix]
    mov     rdx, err_prefix_len
    call    _write
    mov     rdi, STDERR
    lea     rsi, [rel err_data_needs]
    mov     rdx, err_data_needs_len
    call    _write
    mov     rdi, 1
    jmp     _exit

.sync_all:
    ; Call sync() syscall — sync all filesystems
    mov     rax, SYS_SYNC
    syscall
    ; Exit 0
    xor     rdi, rdi
    jmp     _exit

; ── Sync individual files ──────────────────────────────────

.sync_files:
    xor     r12, r12            ; file index
    xor     r13, r13            ; exit code (0 = success)

.file_loop:
    cmp     r12, [file_count]
    jge     .file_done

    ; Get file path
    mov     rbx, [file_ptrs + r12 * 8]

    ; open(path, O_RDONLY)
    mov     rax, SYS_OPEN
    mov     rdi, rbx
    xor     rsi, rsi            ; O_RDONLY
    xor     rdx, rdx
    syscall

    ; Check for error (negative return = error)
    test    rax, rax
    js      .open_error

    ; Save fd
    mov     rbp, rax            ; fd in rbp

    ; Determine which sync to call
    cmp     byte [flag_filesystem], 0
    jne     .do_syncfs
    cmp     byte [flag_data], 0
    jne     .do_fdatasync

    ; fsync(fd)
    mov     rax, SYS_FSYNC
    mov     rdi, rbp
    syscall
    jmp     .check_sync_result

.do_syncfs:
    mov     rax, SYS_SYNCFS
    mov     rdi, rbp
    syscall
    jmp     .check_sync_result

.do_fdatasync:
    mov     rax, SYS_FDATASYNC
    mov     rdi, rbp
    syscall

.check_sync_result:
    ; Save sync result
    mov     rcx, rax

    ; close(fd) regardless of sync result
    push    rcx
    mov     rax, SYS_CLOSE
    mov     rdi, rbp
    syscall
    pop     rcx

    ; Check sync result
    test    rcx, rcx
    js      .sync_error

    ; Success — next file
    inc     r12
    jmp     .file_loop

.open_error:
    ; rax = negative errno, rbx = filename
    neg     rax                 ; make errno positive
    push    rax                 ; save errno
    push    r12
    push    r13

    ; Print: "sync: error opening '"
    mov     rdi, STDERR
    lea     rsi, [rel err_prefix]
    mov     rdx, err_prefix_len
    call    _write

    mov     rdi, STDERR
    lea     rsi, [rel err_opening]
    mov     rdx, err_opening_len
    call    _write

    ; Print filename
    mov     rdi, rbx
    call    _strlen
    mov     rdx, rax
    mov     rdi, STDERR
    mov     rsi, rbx
    call    _write

    ; Print "': "
    mov     rdi, STDERR
    lea     rsi, [rel err_quote_colon]
    mov     rdx, err_quote_colon_len
    call    _write

    ; Print errno message
    pop     r13
    pop     r12
    pop     rax                 ; errno
    call    print_errno

    mov     r13, 1              ; set exit code to 1
    inc     r12
    jmp     .file_loop

.sync_error:
    ; rcx = negative errno, rbx = filename
    neg     rcx                 ; make errno positive
    push    rcx
    push    r12
    push    r13

    ; Print: "sync: error syncing '"
    mov     rdi, STDERR
    lea     rsi, [rel err_prefix]
    mov     rdx, err_prefix_len
    call    _write

    mov     rdi, STDERR
    lea     rsi, [rel err_syncing]
    mov     rdx, err_syncing_len
    call    _write

    ; Print filename
    mov     rdi, rbx
    call    _strlen
    mov     rdx, rax
    mov     rdi, STDERR
    mov     rsi, rbx
    call    _write

    ; Print "': "
    mov     rdi, STDERR
    lea     rsi, [rel err_quote_colon]
    mov     rdx, err_quote_colon_len
    call    _write

    ; Print errno message
    pop     r13
    pop     r12
    pop     rax                 ; errno
    call    print_errno

    mov     r13, 1              ; set exit code to 1
    inc     r12
    jmp     .file_loop

.file_done:
    mov     rdi, r13
    jmp     _exit

; ── --help ─────────────────────────────────────────────────

.do_help:
    mov     rdi, STDOUT
    lea     rsi, [rel str_help]
    mov     rdx, str_help_len
    call    _write
    xor     rdi, rdi
    jmp     _exit

; ── --version ──────────────────────────────────────────────

.do_version:
    mov     rdi, STDOUT
    lea     rsi, [rel str_version]
    mov     rdx, str_version_len
    call    _write
    xor     rdi, rdi
    jmp     _exit

; ── Error: unrecognized long option ────────────────────────

.err_unrecognized_opt:
    ; rbx = the option string
    push    rbx

    mov     rdi, STDERR
    lea     rsi, [rel err_prefix]
    mov     rdx, err_prefix_len
    call    _write

    mov     rdi, STDERR
    lea     rsi, [rel err_unrecognized]
    mov     rdx, err_unrecognized_len
    call    _write

    pop     rbx
    mov     rdi, rbx
    call    _strlen
    mov     rdx, rax
    mov     rdi, STDERR
    mov     rsi, rbx
    call    _write

    mov     rdi, STDERR
    lea     rsi, [rel char_quote]
    mov     rdx, 2              ; quote + newline
    call    _write

    mov     rdi, STDERR
    lea     rsi, [rel err_try_help]
    mov     rdx, err_try_help_len
    call    _write

    mov     rdi, 1
    jmp     _exit

; ── Error: invalid short option ────────────────────────────

.err_invalid_short:
    ; al = the invalid character
    push    rax

    mov     rdi, STDERR
    lea     rsi, [rel err_prefix]
    mov     rdx, err_prefix_len
    call    _write

    mov     rdi, STDERR
    lea     rsi, [rel err_invalid_opt]
    mov     rdx, err_invalid_opt_len
    call    _write

    pop     rax
    sub     rsp, 8
    mov     [rsp], al
    mov     rdi, STDERR
    mov     rsi, rsp
    mov     rdx, 1
    call    _write
    add     rsp, 8

    mov     rdi, STDERR
    lea     rsi, [rel char_quote]
    mov     rdx, 2              ; quote + newline
    call    _write

    mov     rdi, STDERR
    lea     rsi, [rel err_try_help]
    mov     rdx, err_try_help_len
    call    _write

    mov     rdi, 1
    jmp     _exit

; ── print_errno: print error string for errno in rax ───────

print_errno:
    cmp     rax, ENOENT
    je      .pe_enoent
    cmp     rax, EACCES
    je      .pe_eacces
    cmp     rax, ENOTDIR
    je      .pe_enotdir
    cmp     rax, EISDIR
    je      .pe_eisdir
    cmp     rax, ENOMEM
    je      .pe_enomem
    cmp     rax, EMFILE
    je      .pe_emfile
    cmp     rax, ELOOP
    je      .pe_eloop
    cmp     rax, ENAMETOOLONG
    je      .pe_enametoolong
    cmp     rax, EIO
    je      .pe_eio
    cmp     rax, EBADF
    je      .pe_ebadf
    cmp     rax, EINVAL
    je      .pe_einval
    mov     rdi, STDERR
    lea     rsi, [rel errno_unknown]
    mov     rdx, errno_unknown_len
    call    _write
    ret

.pe_enoent:
    lea     rsi, [rel errno_enoent]
    mov     rdx, errno_enoent_len
    jmp     .pe_print
.pe_eacces:
    lea     rsi, [rel errno_eacces]
    mov     rdx, errno_eacces_len
    jmp     .pe_print
.pe_enotdir:
    lea     rsi, [rel errno_enotdir]
    mov     rdx, errno_enotdir_len
    jmp     .pe_print
.pe_eisdir:
    lea     rsi, [rel errno_eisdir]
    mov     rdx, errno_eisdir_len
    jmp     .pe_print
.pe_enomem:
    lea     rsi, [rel errno_enomem]
    mov     rdx, errno_enomem_len
    jmp     .pe_print
.pe_emfile:
    lea     rsi, [rel errno_emfile]
    mov     rdx, errno_emfile_len
    jmp     .pe_print
.pe_eloop:
    lea     rsi, [rel errno_eloop]
    mov     rdx, errno_eloop_len
    jmp     .pe_print
.pe_enametoolong:
    lea     rsi, [rel errno_enametoolong]
    mov     rdx, errno_enametoolong_len
    jmp     .pe_print
.pe_eio:
    lea     rsi, [rel errno_eio]
    mov     rdx, errno_eio_len
    jmp     .pe_print
.pe_ebadf:
    lea     rsi, [rel errno_ebadf]
    mov     rdx, errno_ebadf_len
    jmp     .pe_print
.pe_einval:
    lea     rsi, [rel errno_einval]
    mov     rdx, errno_einval_len
.pe_print:
    mov     rdi, STDERR
    call    _write
    ret

; ── Inlined library functions ──────────────────────────────

; _write(rdi=fd, rsi=buf, rdx=len) -> rax=bytes or negative errno
; Retries on EINTR automatically
_write:
    mov     rax, SYS_WRITE
    syscall
    cmp     rax, -EINTR
    je      _write
    ret

; _exit(rdi=code) — never returns
_exit:
    mov     rax, SYS_EXIT
    syscall

; _strlen(rdi=str) -> rax=length
_strlen:
    xor     rax, rax
.sl_loop:
    cmp     byte [rdi + rax], 0
    je      .sl_done
    inc     rax
    jmp     .sl_loop
.sl_done:
    ret

; _strcmp(rdi=s1, rsi=s2) -> rax=0 if equal, nonzero otherwise
_strcmp:
    xor     rcx, rcx
.sc_loop:
    mov     al, [rdi + rcx]
    mov     dl, [rsi + rcx]
    cmp     al, dl
    jne     .sc_ne
    test    al, al
    jz      .sc_eq
    inc     rcx
    jmp     .sc_loop
.sc_eq:
    xor     rax, rax
    ret
.sc_ne:
    movzx   rax, al
    movzx   rdx, dl
    sub     rax, rdx
    ret

; ============================================================
; Read-only data
; ============================================================

; GNU-identical --help output
str_help:
    db "Usage: sync [OPTION] [FILE]...", 10
    db "Synchronize cached writes to persistent storage", 10
    db 10
    db "If one or more files are specified, sync only them,", 10
    db "or their containing file systems.", 10
    db 10
    db "  -d, --data             sync only file data, no unneeded metadata", 10
    db "  -f, --file-system      sync the file systems that contain the files", 10
    db "      --help        display this help and exit", 10
    db "      --version     output version information and exit", 10
    db 10
    db "GNU coreutils online help: <https://www.gnu.org/software/coreutils/>", 10
    db "Full documentation <https://www.gnu.org/software/coreutils/sync>", 10
    db "or available locally via: info '(coreutils) sync invocation'", 10
str_help_end:
str_help_len equ str_help_end - str_help

; GNU-identical --version output
str_version:
    db "sync (GNU coreutils) 9.7", 10
    db "Packaged by Debian (9.7-3)", 10
    db "Copyright (C) 2025 Free Software Foundation, Inc.", 10
    db "License GPLv3+: GNU GPL version 3 or later <https://gnu.org/licenses/gpl.html>.", 10
    db "This is free software: you are free to change and redistribute it.", 10
    db "There is NO WARRANTY, to the extent permitted by law.", 10
    db 10
    db "Written by Jim Meyering and Giuseppe Scrivano.", 10
str_version_end:
str_version_len equ str_version_end - str_version

; Option strings
opt_help:       db "--help", 0
opt_version:    db "--version", 0
opt_data:       db "--data", 0
opt_filesystem: db "--file-system", 0

; Error message parts
err_prefix:     db "sync: ", 0
err_prefix_len equ 6

err_unrecognized: db "unrecognized option '", 0
err_unrecognized_len equ 21

err_invalid_opt:  db "invalid option -- '", 0
err_invalid_opt_len equ 19

err_try_help:   db "Try 'sync --help' for more information.", 10
err_try_help_len equ 40

err_both:       db "cannot specify both --data and --file-system", 10
err_both_len equ 45

err_data_needs: db "--data needs at least one argument", 10
err_data_needs_len equ 35

err_opening:    db "error opening '", 0
err_opening_len equ 15

err_syncing:    db "error syncing '", 0
err_syncing_len equ 15

err_quote_colon: db "': ", 0
err_quote_colon_len equ 3

; Errno strings
errno_enoent:   db "No such file or directory", 10
errno_enoent_len equ 26
errno_eacces:   db "Permission denied", 10
errno_eacces_len equ 18
errno_enotdir:  db "Not a directory", 10
errno_enotdir_len equ 16
errno_eisdir:   db "Is a directory", 10
errno_eisdir_len equ 15
errno_enomem:   db "Cannot allocate memory", 10
errno_enomem_len equ 23
errno_emfile:   db "Too many open files", 10
errno_emfile_len equ 20
errno_eloop:    db "Too many levels of symbolic links", 10
errno_eloop_len equ 34
errno_enametoolong: db "File name too long", 10
errno_enametoolong_len equ 19
errno_eio:      db "Input/output error", 10
errno_eio_len equ 19
errno_ebadf:    db "Bad file descriptor", 10
errno_ebadf_len equ 20
errno_einval:   db "Invalid argument", 10
errno_einval_len equ 17
errno_unknown:  db "Unknown error", 10
errno_unknown_len equ 14

char_quote:     db "'"
char_newline:   db 10

; File size marker (everything above is in the file)
file_size equ $ - $$

; ============================================================
; BSS — virtual addresses after the file image (not in file)
; The PT_LOAD header's memsz > filesz causes the loader to
; zero-fill these addresses automatically.
; ============================================================
bss_base     equ $$ + file_size
file_ptrs    equ bss_base                      ; 256 * 8 = 2048 bytes
file_count   equ file_ptrs + (256 * 8)         ; 8 bytes
flag_data    equ file_count + 8                 ; 1 byte
flag_filesystem equ flag_data + 1               ; 1 byte
bss_size     equ (flag_filesystem + 1) - bss_base
