; ============================================================
; fcksum_unified.asm — GNU-compatible 'cksum' command
; Builds with: nasm -f bin fcksum_unified.asm -o fcksum
;
; cksum: Print CRC checksum and byte count of each file.
; Uses POSIX CRC algorithm with polynomial 0x04C11DB7.
; ============================================================

BITS 64
ORG 0x400000

%define SYS_READ        0
%define SYS_WRITE       1
%define SYS_OPEN        2
%define SYS_CLOSE       3
%define SYS_EXIT       60
%define SYS_RT_SIGPROCMASK 14

%define STDOUT          1
%define STDERR          2
%define STDIN           0
%define SIG_BLOCK       0
%define SIGPIPE        13

%define O_RDONLY        0

%define BSS_ADDR    0x500000
%define BSS_SIZE    131072       ; 64KB read buffer + 32 bytes num buf + padding
%define READ_BUF    BSS_ADDR
%define READ_BUF_SZ 65536
%define NUM_BUF     (BSS_ADDR + 65536)  ; 64 bytes for number-to-string conversion
%define OUT_BUF     (BSS_ADDR + 65600)  ; 256 bytes for output line assembly

; --- ELF Header ---
ehdr:
    db 0x7f, 'E','L','F'
    db 2, 1, 1, 0
    dq 0
    dw 2, 0x3e
    dd 1
    dq _start
    dq phdr - $$
    dq 0
    dd 0
    dw 64, 56, 3, 64, 0, 0

; --- Program Headers ---
phdr:
    ; PT_LOAD: code + data (R+X)
    dd 1, 5
    dq 0, $$, $$, file_size, file_size, 0x200000

    ; PT_LOAD: BSS (R+W)
    dd 1, 6
    dq 0, BSS_ADDR, BSS_ADDR, 0, BSS_SIZE, 0x200000

    ; PT_GNU_STACK (NX)
    dd 0x6474e551, 6
    dq 0, 0, 0, 0, 0, 0x10

; ============================================================
_start:
    ; Block SIGPIPE
    sub     rsp, 16
    mov     qword [rsp], 0
    bts     qword [rsp], SIGPIPE
    mov     eax, SYS_RT_SIGPROCMASK
    mov     edi, SIG_BLOCK
    mov     rsi, rsp
    xor     edx, edx
    mov     r10d, 8
    syscall
    add     rsp, 16

    mov     r14d, [rsp]         ; argc
    lea     r15, [rsp + 8]      ; argv

    ; Parse options
    mov     ecx, 1              ; arg index
    xor     r12d, r12d          ; exit status

.parse_opts:
    cmp     ecx, r14d
    jge     .done_opts
    mov     rdi, [r15 + rcx*8]
    cmp     byte [rdi], '-'
    jne     .done_opts
    cmp     byte [rdi + 1], 0
    je      .done_opts           ; bare "-" means stdin
    cmp     byte [rdi + 1], '-'
    je      .check_long

    ; Short options - cksum doesn't have short options we support
    ; but we need to handle unknown ones
    mov     r13, rdi
    mov     rsi, str_prefix
    mov     edx, str_prefix_len
    call    do_write_err
    mov     rsi, str_invalid
    mov     edx, str_invalid_len
    call    do_write_err
    lea     rsi, [r13 + 1]
    mov     edx, 1
    call    do_write_err
    mov     rsi, str_sq_nl
    mov     edx, 2
    call    do_write_err
    mov     rsi, str_try
    mov     edx, str_try_len
    call    do_write_err
    mov     edi, 1
    jmp     do_exit

.check_long:
    cmp     byte [rdi + 2], 0
    je      .double_dash
    mov     r9, rdi
    push    rcx
    ; --help
    mov     rsi, str_help_flag
    call    str_eq
    test    eax, eax
    jnz     .pop_show_help
    ; --version
    mov     rdi, r9
    mov     rsi, str_version_flag
    call    str_eq
    test    eax, eax
    jnz     .pop_show_version
    ; Unrecognized
    pop     rcx
    mov     rsi, str_prefix
    mov     edx, str_prefix_len
    call    do_write_err
    mov     rsi, str_unrecog
    mov     edx, str_unrecog_len
    call    do_write_err
    mov     rdi, r9
    call    str_len
    mov     edx, eax
    mov     rsi, r9
    call    do_write_err
    mov     rsi, str_sq_nl
    mov     edx, 2
    call    do_write_err
    mov     rsi, str_try
    mov     edx, str_try_len
    call    do_write_err
    mov     edi, 1
    jmp     do_exit

.pop_show_help:
    pop     rcx
    mov     edi, STDOUT
    mov     rsi, str_help
    mov     edx, str_help_len
    call    do_write
    xor     edi, edi
    jmp     do_exit

.pop_show_version:
    pop     rcx
    mov     edi, STDOUT
    mov     rsi, str_version
    mov     edx, str_version_len
    call    do_write
    xor     edi, edi
    jmp     do_exit

.double_dash:
    inc     ecx
    jmp     .done_opts

.done_opts:
    ; ecx = index of first file arg
    ; If no file args, read from stdin
    cmp     ecx, r14d
    jl      .process_files

    ; No files: read from stdin
    xor     edi, edi            ; fd = stdin
    xor     esi, esi            ; filename = NULL (no name to print)
    call    process_one_file
    mov     r12d, eax           ; exit status
    jmp     .final_exit

.process_files:
    ; Process each file argument
    mov     ebx, ecx            ; file arg index
.file_loop:
    cmp     ebx, r14d
    jge     .final_exit

    mov     rdi, [r15 + rbx*8]
    push    rbx

    ; Check if arg is "-" (stdin)
    cmp     byte [rdi], '-'
    jne     .open_file
    cmp     byte [rdi + 1], 0
    jne     .open_file

    ; It's "-", read from stdin
    xor     edi, edi            ; fd = stdin
    xor     esi, esi            ; no filename
    call    process_one_file
    test    eax, eax
    jz      .file_next
    mov     r12d, 1
    jmp     .file_next

.open_file:
    mov     r13, rdi            ; save filename
    mov     esi, O_RDONLY
    xor     edx, edx
    mov     eax, SYS_OPEN
    syscall
    test    rax, rax
    js      .open_error

    mov     edi, eax            ; fd
    mov     rsi, r13            ; filename
    push    rdi                 ; save fd
    call    process_one_file
    mov     ebx, eax            ; save result
    pop     rdi                 ; restore fd
    ; Close fd
    push    rbx
    mov     eax, SYS_CLOSE
    syscall
    pop     rbx
    test    ebx, ebx
    jz      .file_next
    mov     r12d, 1
    jmp     .file_next

.open_error:
    ; Print error: "cksum: FILENAME: No such file or directory\n"
    neg     rax
    mov     r8, rax             ; errno
    mov     rsi, str_prefix
    mov     edx, str_prefix_len
    call    do_write_err
    mov     rdi, r13
    call    str_len
    mov     edx, eax
    mov     rsi, r13
    call    do_write_err
    mov     rsi, str_open_colon
    mov     edx, str_open_colon_len
    call    do_write_err
    ; Map errno
    cmp     r8d, 2              ; ENOENT
    je      .err_enoent
    cmp     r8d, 13             ; EACCES
    je      .err_eacces
    cmp     r8d, 21             ; EISDIR
    je      .err_eisdir
    mov     rsi, str_err_generic
    mov     edx, str_err_generic_len
    jmp     .err_print
.err_enoent:
    mov     rsi, str_enoent
    mov     edx, str_enoent_len
    jmp     .err_print
.err_eacces:
    mov     rsi, str_eacces
    mov     edx, str_eacces_len
    jmp     .err_print
.err_eisdir:
    mov     rsi, str_eisdir
    mov     edx, str_eisdir_len
.err_print:
    call    do_write_err
    mov     r12d, 1
    jmp     .file_next

.file_next:
    pop     rbx
    inc     ebx
    jmp     .file_loop

.final_exit:
    mov     edi, r12d
    jmp     do_exit

; ============================================================
; process_one_file: compute CRC and byte count, print result
; Input: edi = fd, rsi = filename (0 = no filename)
; Output: eax = 0 on success, 1 on error
; ============================================================
process_one_file:
    push    rbp
    mov     rbp, rsp
    sub     rsp, 48             ; local vars
    ; [rbp-4]  = fd
    ; [rbp-8]  = (unused)
    ; [rbp-16] = filename ptr (0 = none)
    ; [rbp-24] = total_bytes (64-bit)
    ; [rbp-28] = crc (32-bit)

    mov     [rbp-4], edi
    mov     [rbp-16], rsi
    mov     qword [rbp-24], 0   ; total_bytes = 0
    mov     dword [rbp-28], 0   ; crc = 0

.read_loop:
    mov     eax, SYS_READ
    mov     edi, [rbp-4]
    mov     rsi, READ_BUF
    mov     edx, READ_BUF_SZ
    syscall
    cmp     rax, -4             ; EINTR
    je      .read_loop
    test    rax, rax
    js      .read_error
    jz      .read_done

    ; rax = bytes read
    mov     r8, rax             ; bytes_read
    add     [rbp-24], r8        ; total_bytes += bytes_read

    ; Update CRC for each byte
    mov     ecx, [rbp-28]      ; ecx = crc
    xor     r9d, r9d           ; index = 0
    lea     r10, [crc_table]   ; table base

.crc_byte_loop:
    cmp     r9, r8
    jge     .crc_byte_done

    ; crc = (crc << 8) ^ table[(crc >> 24) ^ byte]
    movzx   eax, byte [READ_BUF + r9]
    mov     edx, ecx
    shr     edx, 24
    xor     eax, edx
    and     eax, 0xFF
    shl     ecx, 8
    xor     ecx, [r10 + rax*4]

    inc     r9
    jmp     .crc_byte_loop

.crc_byte_done:
    mov     [rbp-28], ecx
    jmp     .read_loop

.read_done:
    ; Encode length into CRC
    mov     ecx, [rbp-28]      ; crc
    mov     r8, [rbp-24]       ; length (64-bit)
    lea     r10, [crc_table]

.encode_len:
    test    r8, r8
    jz      .finalize_crc

    ; crc = (crc << 8) ^ table[(crc >> 24) ^ (length & 0xFF)]
    mov     eax, r8d
    and     eax, 0xFF
    mov     edx, ecx
    shr     edx, 24
    xor     eax, edx
    and     eax, 0xFF
    shl     ecx, 8
    xor     ecx, [r10 + rax*4]

    shr     r8, 8
    jmp     .encode_len

.finalize_crc:
    xor     ecx, 0xFFFFFFFF    ; final inversion
    mov     [rbp-28], ecx

    ; Now format output: "CRC BYTES [FILENAME]\n"
    ; Convert CRC (unsigned 32-bit) to decimal
    mov     eax, ecx
    ; Use NUM_BUF area for conversion
    ; We need to convert a 32-bit unsigned to decimal string
    ; Max is 4294967295 = 10 digits
    lea     rdi, [NUM_BUF + 20]
    mov     byte [rdi], 0       ; null terminator
    dec     rdi
    mov     r9d, 10

    ; Handle zero specially
    test    eax, eax
    jnz     .crc_itoa
    mov     byte [rdi], '0'
    dec     rdi
    jmp     .crc_itoa_done

.crc_itoa:
    ; Convert using div - but eax is 32-bit, use edx:eax
    xor     edx, edx
    div     r9d
    add     dl, '0'
    mov     [rdi], dl
    dec     rdi
    test    eax, eax
    jnz     .crc_itoa

.crc_itoa_done:
    inc     rdi                 ; rdi points to first digit of CRC
    mov     r8, rdi             ; save CRC string start

    ; Write CRC string
    lea     edx, [NUM_BUF + 20]
    sub     rdx, r8             ; length of CRC string
    mov     rsi, r8
    mov     edi, STDOUT
    call    do_write

    ; Write space
    mov     edi, STDOUT
    mov     rsi, str_space
    mov     edx, 1
    call    do_write

    ; Convert byte count to decimal
    mov     rax, [rbp-24]       ; total_bytes (64-bit)
    lea     rdi, [NUM_BUF + 50]
    mov     byte [rdi], 0
    dec     rdi
    mov     r9d, 10

    test    rax, rax
    jnz     .bytes_itoa
    mov     byte [rdi], '0'
    dec     rdi
    jmp     .bytes_itoa_done

.bytes_itoa:
    xor     edx, edx
    div     r9                  ; 64-bit divide
    add     dl, '0'
    mov     [rdi], dl
    dec     rdi
    test    rax, rax
    jnz     .bytes_itoa

.bytes_itoa_done:
    inc     rdi
    mov     r8, rdi             ; save bytes string start

    ; Write bytes string
    lea     edx, [NUM_BUF + 50]
    sub     rdx, r8
    mov     rsi, r8
    mov     edi, STDOUT
    call    do_write

    ; If filename is not null, write space + filename
    mov     rsi, [rbp-16]
    test    rsi, rsi
    jz      .write_newline

    ; Write space
    push    rsi
    mov     edi, STDOUT
    mov     rsi, str_space
    mov     edx, 1
    call    do_write
    pop     rsi

    ; Write filename
    mov     rdi, rsi
    push    rdi
    call    str_len
    mov     edx, eax
    pop     rsi
    mov     edi, STDOUT
    call    do_write

.write_newline:
    mov     edi, STDOUT
    mov     rsi, str_newline
    mov     edx, 1
    call    do_write

    xor     eax, eax            ; return 0 (success)
    leave
    ret

.read_error:
    ; Print error and return 1
    mov     rsi, str_prefix
    mov     edx, str_prefix_len
    call    do_write_err
    mov     rsi, str_read_err
    mov     edx, str_read_err_len
    call    do_write_err
    mov     eax, 1
    leave
    ret

; ============================================================
; Utility functions
; ============================================================
do_write:
    mov     eax, SYS_WRITE
    syscall
    cmp     rax, -4
    je      do_write
    ret

do_write_err:
    mov     edi, STDERR
    jmp     do_write

do_exit:
    mov     eax, SYS_EXIT
    syscall

str_len:
    xor     eax, eax
.sl_loop:
    cmp     byte [rdi + rax], 0
    je      .sl_done
    inc     eax
    jmp     .sl_loop
.sl_done:
    ret

str_eq:
    xor     r8d, r8d
.se_loop:
    movzx   eax, byte [rdi + r8]
    movzx   edx, byte [rsi + r8]
    cmp     al, dl
    jne     .se_ne
    test    al, al
    jz      .se_eq
    inc     r8d
    jmp     .se_loop
.se_eq:
    mov     eax, 1
    ret
.se_ne:
    xor     eax, eax
    ret

; ============================================================
; CRC32 Lookup Table (POSIX, polynomial 0x04C11DB7)
; ============================================================
crc_table:
    dd 0x00000000, 0x04C11DB7, 0x09823B6E, 0x0D4326D9, 0x130476DC, 0x17C56B6B, 0x1A864DB2, 0x1E475005
    dd 0x2608EDB8, 0x22C9F00F, 0x2F8AD6D6, 0x2B4BCB61, 0x350C9B64, 0x31CD86D3, 0x3C8EA00A, 0x384FBDBD
    dd 0x4C11DB70, 0x48D0C6C7, 0x4593E01E, 0x4152FDA9, 0x5F15ADAC, 0x5BD4B01B, 0x569796C2, 0x52568B75
    dd 0x6A1936C8, 0x6ED82B7F, 0x639B0DA6, 0x675A1011, 0x791D4014, 0x7DDC5DA3, 0x709F7B7A, 0x745E66CD
    dd 0x9823B6E0, 0x9CE2AB57, 0x91A18D8E, 0x95609039, 0x8B27C03C, 0x8FE6DD8B, 0x82A5FB52, 0x8664E6E5
    dd 0xBE2B5B58, 0xBAEA46EF, 0xB7A96036, 0xB3687D81, 0xAD2F2D84, 0xA9EE3033, 0xA4AD16EA, 0xA06C0B5D
    dd 0xD4326D90, 0xD0F37027, 0xDDB056FE, 0xD9714B49, 0xC7361B4C, 0xC3F706FB, 0xCEB42022, 0xCA753D95
    dd 0xF23A8028, 0xF6FB9D9F, 0xFBB8BB46, 0xFF79A6F1, 0xE13EF6F4, 0xE5FFEB43, 0xE8BCCD9A, 0xEC7DD02D
    dd 0x34867077, 0x30476DC0, 0x3D044B19, 0x39C556AE, 0x278206AB, 0x23431B1C, 0x2E003DC5, 0x2AC12072
    dd 0x128E9DCF, 0x164F8078, 0x1B0CA6A1, 0x1FCDBB16, 0x018AEB13, 0x054BF6A4, 0x0808D07D, 0x0CC9CDCA
    dd 0x7897AB07, 0x7C56B6B0, 0x71159069, 0x75D48DDE, 0x6B93DDDB, 0x6F52C06C, 0x6211E6B5, 0x66D0FB02
    dd 0x5E9F46BF, 0x5A5E5B08, 0x571D7DD1, 0x53DC6066, 0x4D9B3063, 0x495A2DD4, 0x44190B0D, 0x40D816BA
    dd 0xACA5C697, 0xA864DB20, 0xA527FDF9, 0xA1E6E04E, 0xBFA1B04B, 0xBB60ADFC, 0xB6238B25, 0xB2E29692
    dd 0x8AAD2B2F, 0x8E6C3698, 0x832F1041, 0x87EE0DF6, 0x99A95DF3, 0x9D684044, 0x902B669D, 0x94EA7B2A
    dd 0xE0B41DE7, 0xE4750050, 0xE9362689, 0xEDF73B3E, 0xF3B06B3B, 0xF771768C, 0xFA325055, 0xFEF34DE2
    dd 0xC6BCF05F, 0xC27DEDE8, 0xCF3ECB31, 0xCBFFD686, 0xD5B88683, 0xD1799B34, 0xDC3ABDED, 0xD8FBA05A
    dd 0x690CE0EE, 0x6DCDFD59, 0x608EDB80, 0x644FC637, 0x7A089632, 0x7EC98B85, 0x738AAD5C, 0x774BB0EB
    dd 0x4F040D56, 0x4BC510E1, 0x46863638, 0x42472B8F, 0x5C007B8A, 0x58C1663D, 0x558240E4, 0x51435D53
    dd 0x251D3B9E, 0x21DC2629, 0x2C9F00F0, 0x285E1D47, 0x36194D42, 0x32D850F5, 0x3F9B762C, 0x3B5A6B9B
    dd 0x0315D626, 0x07D4CB91, 0x0A97ED48, 0x0E56F0FF, 0x1011A0FA, 0x14D0BD4D, 0x19939B94, 0x1D528623
    dd 0xF12F560E, 0xF5EE4BB9, 0xF8AD6D60, 0xFC6C70D7, 0xE22B20D2, 0xE6EA3D65, 0xEBA91BBC, 0xEF68060B
    dd 0xD727BBB6, 0xD3E6A601, 0xDEA580D8, 0xDA649D6F, 0xC423CD6A, 0xC0E2D0DD, 0xCDA1F604, 0xC960EBB3
    dd 0xBD3E8D7E, 0xB9FF90C9, 0xB4BCB610, 0xB07DABA7, 0xAE3AFBA2, 0xAAFBE615, 0xA7B8C0CC, 0xA379DD7B
    dd 0x9B3660C6, 0x9FF77D71, 0x92B45BA8, 0x9675461F, 0x8832161A, 0x8CF30BAD, 0x81B02D74, 0x857130C3
    dd 0x5D8A9099, 0x594B8D2E, 0x5408ABF7, 0x50C9B640, 0x4E8EE645, 0x4A4FFBF2, 0x470CDD2B, 0x43CDC09C
    dd 0x7B827D21, 0x7F436096, 0x7200464F, 0x76C15BF8, 0x68860BFD, 0x6C47164A, 0x61043093, 0x65C52D24
    dd 0x119B4BE9, 0x155A565E, 0x18197087, 0x1CD86D30, 0x029F3D35, 0x065E2082, 0x0B1D065B, 0x0FDC1BEC
    dd 0x3793A651, 0x3352BBE6, 0x3E119D3F, 0x3AD08088, 0x2497D08D, 0x2056CD3A, 0x2D15EBE3, 0x29D4F654
    dd 0xC5A92679, 0xC1683BCE, 0xCC2B1D17, 0xC8EA00A0, 0xD6AD50A5, 0xD26C4D12, 0xDF2F6BCB, 0xDBEE767C
    dd 0xE3A1CBC1, 0xE760D676, 0xEA23F0AF, 0xEEE2ED18, 0xF0A5BD1D, 0xF464A0AA, 0xF9278673, 0xFDE69BC4
    dd 0x89B8FD09, 0x8D79E0BE, 0x803AC667, 0x84FBDBD0, 0x9ABC8BD5, 0x9E7D9662, 0x933EB0BB, 0x97FFAD0C
    dd 0xAFB010B1, 0xAB710D06, 0xA6322BDF, 0xA2F33668, 0xBCB4666D, 0xB8757BDA, 0xB5365D03, 0xB1F740B4

; ============================================================
; Data
; ============================================================
; @@DATA_START@@
str_help:
    db "Usage: cksum [FILE]...", 10
    db "Print CRC checksum and byte counts of each FILE.", 10, 10
    db "      --help        display this help and exit", 10
    db "      --version     output version information and exit", 10, 10
    db "GNU coreutils online help: <https://www.gnu.org/software/coreutils/>", 10
    db "Full documentation <https://www.gnu.org/software/coreutils/cksum>", 10
    db "or available locally via: info '(coreutils) cksum invocation'", 10
str_help_len equ $ - str_help

str_version:
    db "cksum (GNU coreutils) 9.7", 10
    db "Copyright (C) 2025 Free Software Foundation, Inc.", 10
    db "License GPLv3+: GNU GPL version 3 or later <https://gnu.org/licenses/gpl.html>.", 10
    db "This is free software: you are free to change and redistribute it.", 10
    db "There is NO WARRANTY, to the extent permitted by law.", 10, 10
    db "Written by Q. Frank Xia.", 10
str_version_len equ $ - str_version

str_prefix:      db "cksum: "
str_prefix_len   equ $ - str_prefix
str_unrecog:     db "unrecognized option '"
str_unrecog_len  equ $ - str_unrecog
str_invalid:     db "invalid option -- '"
str_invalid_len  equ $ - str_invalid
str_sq_nl:       db "'", 10
str_try:         db "Try 'cksum --help' for more information.", 10
str_try_len      equ $ - str_try
str_open_colon:  db ": "
str_open_colon_len equ $ - str_open_colon
str_enoent:      db "No such file or directory", 10
str_enoent_len   equ $ - str_enoent
str_eacces:      db "Permission denied", 10
str_eacces_len   equ $ - str_eacces
str_eisdir:      db "Is a directory", 10
str_eisdir_len   equ $ - str_eisdir
str_err_generic: db "Input/output error", 10
str_err_generic_len equ $ - str_err_generic
str_read_err:    db "read error", 10
str_read_err_len equ $ - str_read_err
; @@DATA_END@@

str_space:       db " "
str_newline:     db 10
str_help_flag:   db "--help", 0
str_version_flag: db "--version", 0

file_size equ $ - $$
