; fmd5sum.asm — GNU-compatible md5sum in x86-64 Linux assembly
;
; Implements the full MD5 hash algorithm (RFC 1321) with:
;   - All GNU md5sum flags (-b, -c, -t, -w, -z, --tag, --quiet, --status, --strict, --ignore-missing)
;   - Proper filename escaping (backslash, newline)
;   - Check mode with BSD and standard format parsing
;   - SIGPIPE handling, EINTR retry, partial write handling
;   - 64KB I/O buffers for high throughput

%include "include/linux.inc"
%include "include/macros.inc"

section .text
global _start

; ── MD5 constants (T table) ──
; T[i] = floor(2^32 * abs(sin(i+1)))
section .rodata
align 16
md5_T:
    dd 0xd76aa478, 0xe8c7b756, 0x242070db, 0xc1bdceee
    dd 0xf57c0faf, 0x4787c62a, 0xa8304613, 0xfd469501
    dd 0x698098d8, 0x8b44f7af, 0xffff5bb1, 0x895cd7be
    dd 0x6b901122, 0xfd987193, 0xa679438e, 0x49b40821
    dd 0xf61e2562, 0xc040b340, 0x265e5a51, 0xe9b6c7aa
    dd 0xd62f105d, 0x02441453, 0xd8a1e681, 0xe7d3fbc8
    dd 0x21e1cde6, 0xc33707d6, 0xf4d50d87, 0x455a14ed
    dd 0xa9e3e905, 0xfcefa3f8, 0x676f02d9, 0x8d2a4c8a
    dd 0xfffa3942, 0x8771f681, 0x6d9d6122, 0xfde5380c
    dd 0xa4beea44, 0x4bdecfa9, 0xf6bb4b60, 0xbebfbc70
    dd 0x289b7ec6, 0xeaa127fa, 0xd4ef3085, 0x04881d05
    dd 0xd9d4d039, 0xe6db99e5, 0x1fa27cf8, 0xc4ac5665
    dd 0xf4292244, 0x432aff97, 0xab9423a7, 0xfc93a039
    dd 0x655b59c3, 0x8f0ccc92, 0xffeff47d, 0x85845dd1
    dd 0x6fa87e4f, 0xfe2ce6e0, 0xa3014314, 0x4e0811a1
    dd 0xf7537e82, 0xbd3af235, 0x2ad7d2bb, 0xeb86d391

; Shift amounts per round
md5_S:
    db 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22
    db 5,  9, 14, 20, 5,  9, 14, 20, 5,  9, 14, 20, 5,  9, 14, 20
    db 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23
    db 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21

; Message schedule index: which 32-bit word of the block to use per step
md5_G:
    db  0,  1,  2,  3,  4,  5,  6,  7,  8,  9, 10, 11, 12, 13, 14, 15
    db  1,  6, 11,  0,  5, 10, 15,  4,  9, 14,  3,  8, 13,  2,  7, 12
    db  5,  8, 11, 14,  1,  4,  7, 10, 13,  0,  3,  6,  9, 12, 15,  2
    db  0,  7, 14,  5, 12,  3, 10,  1,  8, 15,  6, 13,  4, 11,  2,  9

; Hex digits for conversion
hex_digits: db "0123456789abcdef"

; ── String constants ──
str_help:
    db "Usage: md5sum [OPTION]... [FILE]...", 10
    db "Print or check MD5 (128-bit) checksums.", 10, 10
    db "With no FILE, or when FILE is -, read standard input.", 10
    db "  -b, --binary          read in binary mode", 10
    db "  -c, --check           read checksums from the FILEs and check them", 10
    db "      --tag             create a BSD-style checksum", 10
    db "  -t, --text            read in text mode (default)", 10
    db "  -z, --zero            end each output line with NUL, not newline,", 10
    db "                          and disable file name escaping", 10, 10
    db "The following five options are useful only when verifying checksums:", 10
    db "      --ignore-missing  don't fail or report status for missing files", 10
    db "      --quiet           don't print OK for each successfully verified file", 10
    db "      --status          don't output anything, status code shows success", 10
    db "      --strict          exit non-zero for improperly formatted checksum lines", 10
    db "  -w, --warn            warn about improperly formatted checksum lines", 10, 10
    db "      --help        display this help and exit", 10
    db "      --version     output version information and exit", 10, 10
    db "The sums are computed as described in RFC 1321.", 10
    db "When checking, the input should be a former output of this program.", 10
    db "The default mode is to print a line with: checksum, a space,", 10
    db "a character indicating input mode ('*' for binary, ' ' for text", 10
    db "or where binary is insignificant), and name for each FILE.", 10, 10
    db "Note: There is no difference between binary mode and text mode on GNU systems.", 10
str_help_len equ $ - str_help

str_version:
    db "md5sum (fcoreutils) 0.1.0", 10
str_version_len equ $ - str_version

str_ok: db ": OK", 10
str_ok_len equ $ - str_ok
str_failed: db ": FAILED", 10
str_failed_len equ $ - str_failed
str_failed_open: db ": FAILED open or read", 10
str_failed_open_len equ $ - str_failed_open

str_md5_tag: db "MD5 ("
str_md5_tag_len equ $ - str_md5_tag
str_tag_eq: db ") = "
str_tag_eq_len equ $ - str_tag_eq

str_colon_space: db ": "
str_colon_space_len equ $ - str_colon_space
str_newline: db 10
str_dash: db "-", 0
str_stdin_name: db "standard input", 0

; Error message fragments
err_prefix: db "md5sum: "
err_prefix_len equ $ - err_prefix
err_no_such: db ": No such file or directory", 10
err_no_such_len equ $ - err_no_such
err_perm: db ": Permission denied", 10
err_perm_len equ $ - err_perm
err_is_dir: db ": Is a directory", 10
err_is_dir_len equ $ - err_is_dir
err_io: db ": Input/output error", 10
err_io_len equ $ - err_io

err_unrec: db "md5sum: unrecognized option '"
err_unrec_len equ $ - err_unrec
err_inval: db "md5sum: invalid option -- '"
err_inval_len equ $ - err_inval
err_suffix: db "'", 10, "Try 'md5sum --help' for more information.", 10
err_suffix_len equ $ - err_suffix

err_tag_check: db "md5sum: the --tag option is meaningless when verifying checksums", 10
               db "Try 'md5sum --help' for more information.", 10
err_tag_check_len equ $ - err_tag_check

str_warn_prefix: db "md5sum: WARNING: "
str_warn_prefix_len equ $ - str_warn_prefix
str_checksum_not_match_1: db "1 computed checksum did NOT match", 10
str_checksum_not_match_1_len equ $ - str_checksum_not_match_1
str_checksums_not_match: db " computed checksums did NOT match", 10
str_checksums_not_match_len equ $ - str_checksums_not_match
str_file_not_read_1: db "1 listed file could not be read", 10
str_file_not_read_1_len equ $ - str_file_not_read_1
str_files_not_read: db " listed files could not be read", 10
str_files_not_read_len equ $ - str_files_not_read
str_line_improper_1: db "1 line is improperly formatted", 10
str_line_improper_1_len equ $ - str_line_improper_1
str_lines_improper: db " lines are improperly formatted", 10
str_lines_improper_len equ $ - str_lines_improper

str_no_proper: db ": no properly formatted checksum lines found", 10
str_no_proper_len equ $ - str_no_proper
str_no_file_verified: db ": no file was verified", 10
str_no_file_verified_len equ $ - str_no_file_verified
str_improperly: db ": improperly formatted MD5 checksum line", 10
str_improperly_len equ $ - str_improperly

; ── BSS section ──
section .bss
    io_buf:     resb 65536          ; 64KB I/O read buffer (for check file reading)
    io_buf2:    resb 65536          ; 64KB I/O read buffer (for hashing files in check mode)
    out_buf:    resb 4096           ; output line buffer
    line_buf:   resb 65536          ; line buffer for check mode
    hash_state: resd 4              ; MD5 state (A, B, C, D)
    msg_len:    resq 1              ; total message length in bytes
    block_buf:  resb 64             ; 64-byte block assembly buffer
    block_used: resd 1              ; bytes used in block_buf
    hex_out:    resb 33             ; hex output buffer (32 chars + null)
    fname_buf:  resb 4096           ; escaped filename buffer
    num_buf:    resb 32             ; number to string buffer

    ; Flags
    flag_binary:    resb 1
    flag_check:     resb 1
    flag_tag:       resb 1
    flag_text:      resb 1
    flag_ignore:    resb 1
    flag_quiet:     resb 1
    flag_status:    resb 1
    flag_strict:    resb 1
    flag_warn:      resb 1
    flag_zero:      resb 1

    ; Counters for check mode
    cnt_ok:         resd 1
    cnt_mismatch:   resd 1
    cnt_format_err: resd 1
    cnt_read_err:   resd 1
    cnt_ignored:    resd 1

    had_error:      resb 1
    argc_save:      resd 1
    argv_save:      resq 1          ; pointer to argv[0]

    ; file list
    file_args:      resq 256        ; up to 256 file arguments
    file_count:     resd 1

section .text

; ════════════════════════════════════════════════════════════════════
; _start — Entry point
; ════════════════════════════════════════════════════════════════════
_start:
    ; Block SIGPIPE so write() returns -EPIPE instead of killing us
    sub     rsp, 16
    mov     qword [rsp], 0x1000     ; sigset: bit 12 = SIGPIPE
    mov     eax, SYS_RT_SIGPROCMASK
    xor     edi, edi                ; SIG_BLOCK = 0
    mov     rsi, rsp
    xor     edx, edx                ; old_set = NULL
    mov     r10d, 8                 ; sigsetsize = 8
    syscall
    add     rsp, 16

    ; Save argc/argv
    mov     eax, [rsp]              ; argc
    mov     [argc_save], eax
    lea     rax, [rsp + 8]          ; &argv[0]
    mov     [argv_save], rax

    ; Parse arguments
    call    parse_args

    ; Validate: --tag and --check conflict
    cmp     byte [flag_tag], 0
    je      .no_tag_check
    cmp     byte [flag_check], 0
    je      .no_tag_check
    ; Error: --tag + --check
    WRITE   STDERR, err_tag_check, err_tag_check_len
    EXIT    1
.no_tag_check:

    ; If check mode, go to check handler
    cmp     byte [flag_check], 0
    jne     do_check_mode

    ; If no files, add "-" (stdin)
    cmp     dword [file_count], 0
    jne     .has_files
    mov     qword [file_args], str_dash
    mov     dword [file_count], 1
.has_files:

    ; Hash mode: process each file
    xor     r12d, r12d              ; file index
.hash_loop:
    cmp     r12d, [file_count]
    jge     .hash_done

    mov     rdi, [file_args + r12*8] ; filename pointer
    call    hash_one_file
    inc     r12d
    jmp     .hash_loop

.hash_done:
    ; Exit with error if any file failed
    movzx   edi, byte [had_error]
    EXIT    rdi

; ════════════════════════════════════════════════════════════════════
; parse_args — Parse command-line arguments
; ════════════════════════════════════════════════════════════════════
parse_args:
    push    rbx
    push    r12
    push    r13

    mov     r12, [argv_save]        ; r12 = argv base
    mov     r13d, [argc_save]       ; r13 = argc
    xor     ebx, ebx                ; index = 1 (skip argv[0])
    inc     ebx
    xor     ecx, ecx                ; saw_dashdash = 0
    mov     dword [file_count], 0

.arg_loop:
    cmp     ebx, r13d
    jge     .arg_done
    mov     rsi, [r12 + rbx*8]      ; current arg

    test    ecx, ecx                ; past "--"?
    jnz     .add_file

    ; Check for "--"
    cmp     word [rsi], 0x2D2D      ; "--"
    jne     .not_dashdash
    cmp     byte [rsi+2], 0
    jne     .not_dashdash
    mov     ecx, 1                  ; saw "--"
    inc     ebx
    jmp     .arg_loop

.not_dashdash:
    cmp     byte [rsi], '-'
    jne     .add_file

    cmp     byte [rsi+1], 0         ; just "-" = stdin
    je      .add_file

    cmp     byte [rsi+1], '-'
    je      .long_opt

    ; Short options: parse each char after '-'
    inc     rsi                     ; skip '-'
.short_loop:
    movzx   eax, byte [rsi]
    test    al, al
    jz      .next_arg
    cmp     al, 'b'
    je      .set_binary
    cmp     al, 'c'
    je      .set_check
    cmp     al, 't'
    je      .set_text
    cmp     al, 'w'
    je      .set_warn
    cmp     al, 'z'
    je      .set_zero
    ; Invalid short option — save char first (WRITE clobbers rax)
    sub     rsp, 8
    mov     [rsp], al               ; save option char on stack
    ; Write prefix
    WRITE   STDERR, err_inval, err_inval_len
    ; Write the saved char
    WRITE   STDERR, rsp, 1
    add     rsp, 8
    ; Write suffix
    WRITE   STDERR, err_suffix, err_suffix_len
    EXIT    1

.set_binary:
    mov     byte [flag_binary], 1
    inc     rsi
    jmp     .short_loop
.set_check:
    mov     byte [flag_check], 1
    inc     rsi
    jmp     .short_loop
.set_text:
    mov     byte [flag_text], 1
    inc     rsi
    jmp     .short_loop
.set_warn:
    mov     byte [flag_warn], 1
    inc     rsi
    jmp     .short_loop
.set_zero:
    mov     byte [flag_zero], 1
    inc     rsi
    jmp     .short_loop

.long_opt:
    ; Check each long option by comparing suffix after "--"
    push    rcx

    mov     rdi, [r12 + rbx*8]      ; get the arg again
    add     rdi, 2                   ; skip "--"

    ; Try each long option
    lea     rsi, [rel .s_binary]
    call    strcmp
    test    eax, eax
    jz      .lo_binary_set

    mov     rdi, [r12 + rbx*8]
    add     rdi, 2
    lea     rsi, [rel .s_check]
    call    strcmp
    test    eax, eax
    jz      .lo_check_set

    mov     rdi, [r12 + rbx*8]
    add     rdi, 2
    lea     rsi, [rel .s_tag]
    call    strcmp
    test    eax, eax
    jz      .lo_tag_set

    mov     rdi, [r12 + rbx*8]
    add     rdi, 2
    lea     rsi, [rel .s_text]
    call    strcmp
    test    eax, eax
    jz      .lo_text_set

    mov     rdi, [r12 + rbx*8]
    add     rdi, 2
    lea     rsi, [rel .s_ignore_missing]
    call    strcmp
    test    eax, eax
    jz      .lo_ignore_set

    mov     rdi, [r12 + rbx*8]
    add     rdi, 2
    lea     rsi, [rel .s_quiet]
    call    strcmp
    test    eax, eax
    jz      .lo_quiet_set

    mov     rdi, [r12 + rbx*8]
    add     rdi, 2
    lea     rsi, [rel .s_status]
    call    strcmp
    test    eax, eax
    jz      .lo_status_set

    mov     rdi, [r12 + rbx*8]
    add     rdi, 2
    lea     rsi, [rel .s_strict]
    call    strcmp
    test    eax, eax
    jz      .lo_strict_set

    mov     rdi, [r12 + rbx*8]
    add     rdi, 2
    lea     rsi, [rel .s_warn]
    call    strcmp
    test    eax, eax
    jz      .lo_warn_set

    mov     rdi, [r12 + rbx*8]
    add     rdi, 2
    lea     rsi, [rel .s_zero]
    call    strcmp
    test    eax, eax
    jz      .lo_zero_set

    mov     rdi, [r12 + rbx*8]
    add     rdi, 2
    lea     rsi, [rel .s_help]
    call    strcmp
    test    eax, eax
    jz      .lo_help

    mov     rdi, [r12 + rbx*8]
    add     rdi, 2
    lea     rsi, [rel .s_version]
    call    strcmp
    test    eax, eax
    jz      .lo_version

    ; Unrecognized long option
    pop     rcx
    WRITE   STDERR, err_unrec, err_unrec_len
    ; Write the option
    mov     rdi, [r12 + rbx*8]
    call    strlen
    mov     rdx, rax
    mov     rsi, [r12 + rbx*8]
    WRITE   STDERR, rsi, rdx
    WRITE   STDERR, err_suffix, err_suffix_len
    EXIT    1

.lo_binary_set:
    pop     rcx
    mov     byte [flag_binary], 1
    jmp     .next_arg
.lo_check_set:
    pop     rcx
    mov     byte [flag_check], 1
    jmp     .next_arg
.lo_tag_set:
    pop     rcx
    mov     byte [flag_tag], 1
    jmp     .next_arg
.lo_text_set:
    pop     rcx
    mov     byte [flag_text], 1
    jmp     .next_arg
.lo_ignore_set:
    pop     rcx
    mov     byte [flag_ignore], 1
    jmp     .next_arg
.lo_quiet_set:
    pop     rcx
    mov     byte [flag_quiet], 1
    jmp     .next_arg
.lo_status_set:
    pop     rcx
    mov     byte [flag_status], 1
    jmp     .next_arg
.lo_strict_set:
    pop     rcx
    mov     byte [flag_strict], 1
    jmp     .next_arg
.lo_warn_set:
    pop     rcx
    mov     byte [flag_warn], 1
    jmp     .next_arg
.lo_zero_set:
    pop     rcx
    mov     byte [flag_zero], 1
    jmp     .next_arg
.lo_help:
    pop     rcx
    WRITE   STDOUT, str_help, str_help_len
    EXIT    0
.lo_version:
    pop     rcx
    WRITE   STDOUT, str_version, str_version_len
    EXIT    0

.add_file:
    mov     eax, [file_count]
    cmp     eax, 255
    jge     .next_arg               ; too many files, skip
    mov     [file_args + rax*8], rsi
    inc     dword [file_count]

.next_arg:
    inc     ebx
    jmp     .arg_loop

.arg_done:
    pop     r13
    pop     r12
    pop     rbx
    ret

; Long option name strings
section .rodata
.s_binary: db "binary", 0
.s_check: db "check", 0
.s_tag: db "tag", 0
.s_text: db "text", 0
.s_ignore_missing: db "ignore-missing", 0
.s_quiet: db "quiet", 0
.s_status: db "status", 0
.s_strict: db "strict", 0
.s_warn: db "warn", 0
.s_zero: db "zero", 0
.s_help: db "help", 0
.s_version: db "version", 0
.str_binary: db "binary", 0

section .text

; ════════════════════════════════════════════════════════════════════
; strcmp(rdi, rsi) — Compare two null-terminated strings
; Returns 0 if equal, non-zero if different
; ════════════════════════════════════════════════════════════════════
strcmp:
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
    mov     eax, 1
    ret

; ════════════════════════════════════════════════════════════════════
; strlen(rdi) — Get length of null-terminated string
; Returns length in rax
; ════════════════════════════════════════════════════════════════════
strlen:
    xor     eax, eax
.loop:
    cmp     byte [rdi + rax], 0
    je      .done
    inc     rax
    jmp     .loop
.done:
    ret

; ════════════════════════════════════════════════════════════════════
; write_all(rdi=fd, rsi=buf, rdx=len) — Write all bytes, handle EINTR + partial
; ════════════════════════════════════════════════════════════════════
write_all:
    push    rbx
    push    r12
    push    r13
    mov     rbx, rdi                ; fd
    mov     r12, rsi                ; buf
    mov     r13, rdx                ; remaining
.loop:
    test    r13, r13
    jle     .done
    mov     rax, SYS_WRITE
    mov     rdi, rbx
    mov     rsi, r12
    mov     rdx, r13
    syscall
    cmp     rax, -EINTR
    je      .loop                   ; EINTR, retry
    test    rax, rax
    js      .done                   ; error
    add     r12, rax
    sub     r13, rax
    jmp     .loop
.done:
    pop     r13
    pop     r12
    pop     rbx
    ret

; ════════════════════════════════════════════════════════════════════
; write_stderr(rsi=buf, rdx=len) — Convenience write to stderr
; ════════════════════════════════════════════════════════════════════
write_stderr:
    mov     rdi, STDERR
    jmp     write_all

; ════════════════════════════════════════════════════════════════════
; MD5 Implementation
; ════════════════════════════════════════════════════════════════════

; md5_init — Initialize MD5 state
md5_init:
    mov     dword [hash_state],     0x67452301  ; A
    mov     dword [hash_state+4],   0xefcdab89  ; B
    mov     dword [hash_state+8],   0x98badcfe  ; C
    mov     dword [hash_state+12],  0x10325476  ; D
    mov     qword [msg_len], 0
    mov     dword [block_used], 0
    ret

; ════════════════════════════════════════════════════════════════════
; md5_transform_v2(rdi=pointer to 64-byte block)
; Fully unrolled MD5 compression — all 64 rounds inline
; Registers: eax=a, ebx=b, ecx=c, edx=d, r14=block, r8d=scratch
; ════════════════════════════════════════════════════════════════════

; F(b,c,d) = d ^ (b & (c ^ d))
%macro ROUND_F 7
    mov     r8d, %4
    xor     r8d, %3
    and     r8d, %2
    xor     r8d, %4
    add     %1, r8d
    add     %1, dword [r14 + 4*%5]
    add     %1, %7
    rol     %1, %6
    add     %1, %2
%endmacro

; G(b,c,d) = c ^ (d & (b ^ c))
%macro ROUND_G 7
    mov     r8d, %2
    xor     r8d, %3
    and     r8d, %4
    xor     r8d, %3
    add     %1, r8d
    add     %1, dword [r14 + 4*%5]
    add     %1, %7
    rol     %1, %6
    add     %1, %2
%endmacro

; H(b,c,d) = b ^ c ^ d
%macro ROUND_H 7
    mov     r8d, %2
    xor     r8d, %3
    xor     r8d, %4
    add     %1, r8d
    add     %1, dword [r14 + 4*%5]
    add     %1, %7
    rol     %1, %6
    add     %1, %2
%endmacro

; I(b,c,d) = c ^ (b | ~d)
%macro ROUND_I 7
    mov     r8d, %4
    not     r8d
    or      r8d, %2
    xor     r8d, %3
    add     %1, r8d
    add     %1, dword [r14 + 4*%5]
    add     %1, %7
    rol     %1, %6
    add     %1, %2
%endmacro

md5_transform_v2:
    push    rbx
    push    r14
    mov     r14, rdi
    mov     eax, [hash_state]
    mov     ebx, [hash_state+4]
    mov     ecx, [hash_state+8]
    mov     edx, [hash_state+12]
    push    rax
    push    rbx
    push    rcx
    push    rdx

    ROUND_F eax, ebx, ecx, edx,  0,  7, 0xd76aa478
    ROUND_F edx, eax, ebx, ecx,  1, 12, 0xe8c7b756
    ROUND_F ecx, edx, eax, ebx,  2, 17, 0x242070db
    ROUND_F ebx, ecx, edx, eax,  3, 22, 0xc1bdceee
    ROUND_F eax, ebx, ecx, edx,  4,  7, 0xf57c0faf
    ROUND_F edx, eax, ebx, ecx,  5, 12, 0x4787c62a
    ROUND_F ecx, edx, eax, ebx,  6, 17, 0xa8304613
    ROUND_F ebx, ecx, edx, eax,  7, 22, 0xfd469501
    ROUND_F eax, ebx, ecx, edx,  8,  7, 0x698098d8
    ROUND_F edx, eax, ebx, ecx,  9, 12, 0x8b44f7af
    ROUND_F ecx, edx, eax, ebx, 10, 17, 0xffff5bb1
    ROUND_F ebx, ecx, edx, eax, 11, 22, 0x895cd7be
    ROUND_F eax, ebx, ecx, edx, 12,  7, 0x6b901122
    ROUND_F edx, eax, ebx, ecx, 13, 12, 0xfd987193
    ROUND_F ecx, edx, eax, ebx, 14, 17, 0xa679438e
    ROUND_F ebx, ecx, edx, eax, 15, 22, 0x49b40821

    ROUND_G eax, ebx, ecx, edx,  1,  5, 0xf61e2562
    ROUND_G edx, eax, ebx, ecx,  6,  9, 0xc040b340
    ROUND_G ecx, edx, eax, ebx, 11, 14, 0x265e5a51
    ROUND_G ebx, ecx, edx, eax,  0, 20, 0xe9b6c7aa
    ROUND_G eax, ebx, ecx, edx,  5,  5, 0xd62f105d
    ROUND_G edx, eax, ebx, ecx, 10,  9, 0x02441453
    ROUND_G ecx, edx, eax, ebx, 15, 14, 0xd8a1e681
    ROUND_G ebx, ecx, edx, eax,  4, 20, 0xe7d3fbc8
    ROUND_G eax, ebx, ecx, edx,  9,  5, 0x21e1cde6
    ROUND_G edx, eax, ebx, ecx, 14,  9, 0xc33707d6
    ROUND_G ecx, edx, eax, ebx,  3, 14, 0xf4d50d87
    ROUND_G ebx, ecx, edx, eax,  8, 20, 0x455a14ed
    ROUND_G eax, ebx, ecx, edx, 13,  5, 0xa9e3e905
    ROUND_G edx, eax, ebx, ecx,  2,  9, 0xfcefa3f8
    ROUND_G ecx, edx, eax, ebx,  7, 14, 0x676f02d9
    ROUND_G ebx, ecx, edx, eax, 12, 20, 0x8d2a4c8a

    ROUND_H eax, ebx, ecx, edx,  5,  4, 0xfffa3942
    ROUND_H edx, eax, ebx, ecx,  8, 11, 0x8771f681
    ROUND_H ecx, edx, eax, ebx, 11, 16, 0x6d9d6122
    ROUND_H ebx, ecx, edx, eax, 14, 23, 0xfde5380c
    ROUND_H eax, ebx, ecx, edx,  1,  4, 0xa4beea44
    ROUND_H edx, eax, ebx, ecx,  4, 11, 0x4bdecfa9
    ROUND_H ecx, edx, eax, ebx,  7, 16, 0xf6bb4b60
    ROUND_H ebx, ecx, edx, eax, 10, 23, 0xbebfbc70
    ROUND_H eax, ebx, ecx, edx, 13,  4, 0x289b7ec6
    ROUND_H edx, eax, ebx, ecx,  0, 11, 0xeaa127fa
    ROUND_H ecx, edx, eax, ebx,  3, 16, 0xd4ef3085
    ROUND_H ebx, ecx, edx, eax,  6, 23, 0x04881d05
    ROUND_H eax, ebx, ecx, edx,  9,  4, 0xd9d4d039
    ROUND_H edx, eax, ebx, ecx, 12, 11, 0xe6db99e5
    ROUND_H ecx, edx, eax, ebx, 15, 16, 0x1fa27cf8
    ROUND_H ebx, ecx, edx, eax,  2, 23, 0xc4ac5665

    ROUND_I eax, ebx, ecx, edx,  0,  6, 0xf4292244
    ROUND_I edx, eax, ebx, ecx,  7, 10, 0x432aff97
    ROUND_I ecx, edx, eax, ebx, 14, 15, 0xab9423a7
    ROUND_I ebx, ecx, edx, eax,  5, 21, 0xfc93a039
    ROUND_I eax, ebx, ecx, edx, 12,  6, 0x655b59c3
    ROUND_I edx, eax, ebx, ecx,  3, 10, 0x8f0ccc92
    ROUND_I ecx, edx, eax, ebx, 10, 15, 0xffeff47d
    ROUND_I ebx, ecx, edx, eax,  1, 21, 0x85845dd1
    ROUND_I eax, ebx, ecx, edx,  8,  6, 0x6fa87e4f
    ROUND_I edx, eax, ebx, ecx, 15, 10, 0xfe2ce6e0
    ROUND_I ecx, edx, eax, ebx,  6, 15, 0xa3014314
    ROUND_I ebx, ecx, edx, eax, 13, 21, 0x4e0811a1
    ROUND_I eax, ebx, ecx, edx,  4,  6, 0xf7537e82
    ROUND_I edx, eax, ebx, ecx, 11, 10, 0xbd3af235
    ROUND_I ecx, edx, eax, ebx,  2, 15, 0x2ad7d2bb
    ROUND_I ebx, ecx, edx, eax,  9, 21, 0xeb86d391

    pop     r8
    add     edx, r8d
    pop     r8
    add     ecx, r8d
    pop     r8
    add     ebx, r8d
    pop     r8
    add     eax, r8d
    mov     [hash_state], eax
    mov     [hash_state+4], ebx
    mov     [hash_state+8], ecx
    mov     [hash_state+12], edx
    pop     r14
    pop     rbx
    ret

; ════════════════════════════════════════════════════════════════════
; ════════════════════════════════════════════════════════════════════
; md5_update(rdi=data, rsi=len) — Feed data into MD5
; ════════════════════════════════════════════════════════════════════
md5_update:
    push    rbx
    push    r12
    push    r13
    push    r14

    mov     r12, rdi                ; data pointer
    mov     r13, rsi                ; data length
    add     [msg_len], r13          ; update total message length

    ; If we have partial block data, fill it first
    mov     eax, [block_used]
    test    eax, eax
    jz      .full_blocks

    ; Fill partial block
    mov     ecx, 64
    sub     ecx, eax                ; space remaining in block
    cmp     r13, rcx
    jl      .partial_only

    ; Fill remaining space and transform
    lea     rdi, [block_buf + rax]
    mov     rsi, r12
    mov     rdx, rcx
    call    memcpy
    add     r12, rcx
    sub     r13, rcx
    mov     dword [block_used], 0
    lea     rdi, [block_buf]
    call    md5_transform_v2
    jmp     .full_blocks

.partial_only:
    ; Not enough data to fill block
    lea     rdi, [block_buf + rax]
    mov     rsi, r12
    mov     rdx, r13
    call    memcpy
    add     eax, r13d
    mov     [block_used], eax
    jmp     .update_done

.full_blocks:
    ; Process full 64-byte blocks
    cmp     r13, 64
    jl      .remaining

    mov     rdi, r12
    call    md5_transform_v2
    add     r12, 64
    sub     r13, 64
    jmp     .full_blocks

.remaining:
    ; Store remaining bytes in block_buf
    test    r13, r13
    jz      .update_done
    lea     rdi, [block_buf]
    mov     rsi, r12
    mov     rdx, r13
    call    memcpy
    mov     [block_used], r13d

.update_done:
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

; ════════════════════════════════════════════════════════════════════
; md5_final — Finalize MD5 hash (padding + length)
; Result is in hash_state (16 bytes, little-endian)
; ════════════════════════════════════════════════════════════════════
md5_final:
    push    rbx

    ; Append 0x80 byte
    mov     eax, [block_used]
    mov     byte [block_buf + rax], 0x80
    inc     eax

    ; If we have more than 56 bytes, need extra block
    cmp     eax, 56
    jle     .pad_zeros

    ; Zero rest of current block
    lea     rdi, [block_buf + rax]
    mov     ecx, 64
    sub     ecx, eax
    xor     al, al
    rep     stosb
    ; Transform this block
    lea     rdi, [block_buf]
    call    md5_transform_v2
    ; Start fresh block
    xor     eax, eax

.pad_zeros:
    ; Zero bytes from current position to byte 56
    lea     rdi, [block_buf + rax]
    mov     ecx, 56
    sub     ecx, eax
    xor     al, al
    rep     stosb

    ; Append 64-bit message length in bits (little-endian)
    mov     rax, [msg_len]
    shl     rax, 3                  ; bytes to bits
    mov     [block_buf + 56], rax

    ; Final transform
    lea     rdi, [block_buf]
    call    md5_transform_v2

    pop     rbx
    ret

; ════════════════════════════════════════════════════════════════════
; md5_to_hex — Convert hash_state to hex string in hex_out
; ════════════════════════════════════════════════════════════════════
md5_to_hex:
    xor     ecx, ecx                ; byte index
.loop:
    cmp     ecx, 16
    jge     .done
    movzx   eax, byte [hash_state + rcx]
    mov     edx, eax
    shr     edx, 4                  ; high nibble
    movzx   edx, byte [hex_digits + rdx]
    mov     [hex_out + rcx*2], dl
    and     eax, 0x0F               ; low nibble
    movzx   eax, byte [hex_digits + rax]
    mov     [hex_out + rcx*2 + 1], al
    inc     ecx
    jmp     .loop
.done:
    mov     byte [hex_out + 32], 0  ; null terminate
    ret

; ════════════════════════════════════════════════════════════════════
; memcpy(rdi=dst, rsi=src, rdx=len)
; ════════════════════════════════════════════════════════════════════
memcpy:
    mov     rcx, rdx
    rep     movsb
    ret

; ════════════════════════════════════════════════════════════════════
; hash_one_file(rdi=filename) — Hash one file and print result
; ════════════════════════════════════════════════════════════════════
hash_one_file:
    push    rbx
    push    r12
    push    r13

    mov     r12, rdi                ; save filename

    ; Initialize MD5
    call    md5_init

    ; Open file (or use stdin)
    cmp     byte [r12], '-'
    jne     .open_file
    cmp     byte [r12+1], 0
    jne     .open_file
    ; stdin
    xor     ebx, ebx                ; fd = 0
    jmp     .read_loop

.open_file:
    mov     rax, SYS_OPEN
    mov     rdi, r12
    xor     esi, esi                ; O_RDONLY
    xor     edx, edx
    syscall
    test    rax, rax
    js      .open_error
    mov     ebx, eax                ; fd

.read_loop:
    mov     rax, SYS_READ
    mov     edi, ebx
    lea     rsi, [io_buf]
    mov     edx, 65536
    syscall
    cmp     rax, -EINTR
    je      .read_loop              ; retry on EINTR
    test    rax, rax
    js      .read_error
    jz      .read_done              ; EOF

    ; Feed data to MD5
    lea     rdi, [io_buf]
    mov     rsi, rax
    call    md5_update
    jmp     .read_loop

.read_done:
    ; Close file if not stdin
    test    ebx, ebx
    jz      .finalize
    mov     rax, SYS_CLOSE
    mov     edi, ebx
    syscall

.finalize:
    call    md5_final
    call    md5_to_hex

    ; Format and print output
    ; Check if tag mode
    cmp     byte [flag_tag], 0
    jne     .output_tag

    ; Standard format: [\\]<hash> <mode><filename>[\n|\0]
    ; Check if filename needs escaping
    cmp     byte [flag_zero], 0
    jne     .output_no_escape       ; -z disables escaping

    mov     rdi, r12
    call    needs_escape
    test    eax, eax
    jz      .output_no_escape

    ; Escaped output: \<hash> <mode><escaped_filename>\n
    lea     rdi, [out_buf]
    mov     byte [rdi], '\'
    inc     rdi
    ; Copy hash
    lea     rsi, [hex_out]
    mov     ecx, 32
    rep     movsb
    ; Space + mode indicator
    mov     byte [rdi], ' '
    inc     rdi
    cmp     byte [flag_binary], 0
    je      .esc_text_mode
    mov     byte [rdi], '*'
    jmp     .esc_mode_done
.esc_text_mode:
    mov     byte [rdi], ' '
.esc_mode_done:
    inc     rdi
    ; Escaped filename
    mov     rsi, r12
    call    escape_filename_to      ; rdi = dest, rsi = src, returns new rdi
    ; Terminator
    mov     byte [rdi], 10          ; newline
    inc     rdi
    ; Calculate length and write
    lea     rsi, [out_buf]
    mov     rdx, rdi
    sub     rdx, rsi
    mov     rdi, STDOUT
    call    write_all
    jmp     .hash_file_done

.output_no_escape:
    ; <hash> <mode><filename>[\n|\0]
    lea     rdi, [out_buf]
    ; Copy hash
    lea     rsi, [hex_out]
    mov     ecx, 32
    rep     movsb
    ; Space + mode indicator
    mov     byte [rdi], ' '
    inc     rdi
    cmp     byte [flag_binary], 0
    je      .ne_text_mode
    mov     byte [rdi], '*'
    jmp     .ne_mode_done
.ne_text_mode:
    mov     byte [rdi], ' '
.ne_mode_done:
    inc     rdi
    ; Copy filename
    mov     rsi, r12
.copy_fname:
    lodsb
    test    al, al
    jz      .fname_done
    stosb
    jmp     .copy_fname
.fname_done:
    ; Terminator
    cmp     byte [flag_zero], 0
    jne     .zero_term
    mov     byte [rdi], 10          ; newline
    jmp     .term_done
.zero_term:
    mov     byte [rdi], 0           ; NUL
.term_done:
    inc     rdi
    ; Write
    lea     rsi, [out_buf]
    mov     rdx, rdi
    sub     rdx, rsi
    mov     rdi, STDOUT
    call    write_all
    jmp     .hash_file_done

.output_tag:
    ; BSD tag format: MD5 (<filename>) = <hash>[\n|\0]
    lea     rdi, [out_buf]
    ; "MD5 ("
    lea     rsi, [str_md5_tag]
    mov     ecx, str_md5_tag_len
    rep     movsb
    ; filename
    mov     rsi, r12
.tag_copy_fname:
    lodsb
    test    al, al
    jz      .tag_fname_done
    stosb
    jmp     .tag_copy_fname
.tag_fname_done:
    ; ") = "
    lea     rsi, [str_tag_eq]
    mov     ecx, str_tag_eq_len
    rep     movsb
    ; hash
    lea     rsi, [hex_out]
    mov     ecx, 32
    rep     movsb
    ; terminator
    cmp     byte [flag_zero], 0
    jne     .tag_zero
    mov     byte [rdi], 10
    jmp     .tag_term_done
.tag_zero:
    mov     byte [rdi], 0
.tag_term_done:
    inc     rdi
    lea     rsi, [out_buf]
    mov     rdx, rdi
    sub     rdx, rsi
    mov     rdi, STDOUT
    call    write_all
    jmp     .hash_file_done

.open_error:
    ; Print error to stderr
    mov     r13, rax                ; save errno (negative)
    neg     r13d
    mov     byte [had_error], 1
    ; "md5sum: "
    WRITE   STDERR, err_prefix, err_prefix_len
    ; filename
    mov     rdi, r12
    call    strlen
    mov     rdx, rax
    WRITE   STDERR, r12, rdx
    ; error message based on errno
    cmp     r13d, 2                 ; ENOENT
    je      .err_noent
    cmp     r13d, 13                ; EACCES
    je      .err_perm
    cmp     r13d, 21                ; EISDIR
    je      .err_isdir
    ; Generic I/O error
    WRITE   STDERR, err_io, err_io_len
    jmp     .hash_file_done
.err_noent:
    WRITE   STDERR, err_no_such, err_no_such_len
    jmp     .hash_file_done
.err_perm:
    WRITE   STDERR, err_perm, err_perm_len
    jmp     .hash_file_done
.err_isdir:
    WRITE   STDERR, err_is_dir, err_is_dir_len
    jmp     .hash_file_done

.read_error:
    mov     byte [had_error], 1
    ; Close fd if not stdin
    test    ebx, ebx
    jz      .re_msg
    push    rax
    mov     rax, SYS_CLOSE
    mov     edi, ebx
    syscall
    pop     rax
.re_msg:
    neg     eax
    mov     r13d, eax
    WRITE   STDERR, err_prefix, err_prefix_len
    mov     rdi, r12
    call    strlen
    mov     rdx, rax
    WRITE   STDERR, r12, rdx
    ; Select error message based on errno
    cmp     r13d, 21                ; EISDIR
    je      .re_isdir
    WRITE   STDERR, err_io, err_io_len
    jmp     .hash_file_done
.re_isdir:
    WRITE   STDERR, err_is_dir, err_is_dir_len

.hash_file_done:
    pop     r13
    pop     r12
    pop     rbx
    ret

; ════════════════════════════════════════════════════════════════════
; needs_escape(rdi=filename) — Check if filename contains \ or \n
; Returns eax=1 if yes, 0 if no
; ════════════════════════════════════════════════════════════════════
needs_escape:
.loop:
    movzx   eax, byte [rdi]
    test    al, al
    jz      .no
    cmp     al, '\'
    je      .yes
    cmp     al, 10
    je      .yes
    inc     rdi
    jmp     .loop
.no:
    xor     eax, eax
    ret
.yes:
    mov     eax, 1
    ret

; ════════════════════════════════════════════════════════════════════
; escape_filename_to(rdi=dest, rsi=src) — Escape \ and \n in filename
; Returns: rdi pointing past last written byte
; ════════════════════════════════════════════════════════════════════
escape_filename_to:
.loop:
    lodsb
    test    al, al
    jz      .done
    cmp     al, '\'
    je      .esc_backslash
    cmp     al, 10
    je      .esc_newline
    stosb
    jmp     .loop
.esc_backslash:
    mov     byte [rdi], '\'
    mov     byte [rdi+1], '\'
    add     rdi, 2
    jmp     .loop
.esc_newline:
    mov     byte [rdi], '\'
    mov     byte [rdi+1], 'n'
    add     rdi, 2
    jmp     .loop
.done:
    ret

; ════════════════════════════════════════════════════════════════════
; do_check_mode — Process files in check mode
; ════════════════════════════════════════════════════════════════════
do_check_mode:
    ; If no files, add stdin
    cmp     dword [file_count], 0
    jne     .cm_has_files
    mov     qword [file_args], str_dash
    mov     dword [file_count], 1
.cm_has_files:

    ; Zero counters
    mov     dword [cnt_ok], 0
    mov     dword [cnt_mismatch], 0
    mov     dword [cnt_format_err], 0
    mov     dword [cnt_read_err], 0
    mov     dword [cnt_ignored], 0

    xor     r12d, r12d              ; file index
.cm_file_loop:
    cmp     r12d, [file_count]
    jge     .cm_files_done

    mov     rdi, [file_args + r12*8]
    call    check_one_file
    inc     r12d
    jmp     .cm_file_loop

.cm_files_done:
    ; Check if no properly formatted lines found
    mov     eax, [cnt_ok]
    add     eax, [cnt_mismatch]
    add     eax, [cnt_read_err]
    test    eax, eax
    jnz     .cm_has_valid

    cmp     dword [cnt_format_err], 0
    je      .cm_skip_no_proper

    ; "no properly formatted checksum lines found"
    cmp     byte [flag_status], 0
    jne     .cm_set_error
    WRITE   STDERR, err_prefix, err_prefix_len
    ; Print filename (first file or "standard input")
    cmp     dword [file_count], 1
    jne     .cm_np_fname
    mov     rdi, [file_args]
    cmp     byte [rdi], '-'
    jne     .cm_np_fname
    cmp     byte [rdi+1], 0
    jne     .cm_np_fname
    WRITE   STDERR, str_stdin_name, 14
    jmp     .cm_np_msg
.cm_np_fname:
    mov     rdi, [file_args]
    call    strlen
    mov     rdx, rax
    WRITE   STDERR, [file_args], rdx
.cm_np_msg:
    WRITE   STDERR, str_no_proper, str_no_proper_len
.cm_set_error:
    mov     byte [had_error], 1
    ; Skip per-category warnings when "no properly formatted" was shown
    jmp     .cm_exit

.cm_has_valid:
.cm_skip_no_proper:

.cm_print_warnings:
    cmp     byte [flag_status], 0
    jne     .cm_exit

    ; Print warning summaries (GNU order: format errors, read errors, mismatches)
    cmp     dword [cnt_format_err], 0
    je      .cm_no_fmt_err
    WRITE   STDERR, str_warn_prefix, str_warn_prefix_len
    cmp     dword [cnt_format_err], 1
    jne     .cm_fmt_err_plural
    WRITE   STDERR, str_line_improper_1, str_line_improper_1_len
    jmp     .cm_no_fmt_err
.cm_fmt_err_plural:
    mov     edi, [cnt_format_err]
    call    print_number_stderr
    WRITE   STDERR, str_lines_improper, str_lines_improper_len
.cm_no_fmt_err:

    cmp     dword [cnt_read_err], 0
    je      .cm_no_read_err
    WRITE   STDERR, str_warn_prefix, str_warn_prefix_len
    cmp     dword [cnt_read_err], 1
    jne     .cm_read_err_plural
    WRITE   STDERR, str_file_not_read_1, str_file_not_read_1_len
    jmp     .cm_no_read_err
.cm_read_err_plural:
    mov     edi, [cnt_read_err]
    call    print_number_stderr
    WRITE   STDERR, str_files_not_read, str_files_not_read_len
.cm_no_read_err:

    cmp     dword [cnt_mismatch], 0
    je      .cm_no_mismatch
    WRITE   STDERR, str_warn_prefix, str_warn_prefix_len
    cmp     dword [cnt_mismatch], 1
    jne     .cm_mismatch_plural
    WRITE   STDERR, str_checksum_not_match_1, str_checksum_not_match_1_len
    jmp     .cm_no_mismatch
.cm_mismatch_plural:
    mov     edi, [cnt_mismatch]
    call    print_number_stderr
    WRITE   STDERR, str_checksums_not_match, str_checksums_not_match_len
.cm_no_mismatch:

.cm_exit:
    ; Determine exit code
    movzx   edi, byte [had_error]
    cmp     dword [cnt_mismatch], 0
    je      .cm_no_m2
    mov     edi, 1
.cm_no_m2:
    cmp     dword [cnt_read_err], 0
    je      .cm_no_r2
    mov     edi, 1
.cm_no_r2:
    cmp     byte [flag_strict], 0
    je      .cm_no_s2
    cmp     dword [cnt_format_err], 0
    je      .cm_no_s2
    mov     edi, 1
.cm_no_s2:
    EXIT    rdi

; ════════════════════════════════════════════════════════════════════
; check_one_file(rdi=filename) — Process one checksum file in check mode
; ════════════════════════════════════════════════════════════════════
check_one_file:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 16                 ; local: [rsp+0]=checksum_fd, [rsp+4]=line_pos, [rsp+8]=buf_len

    mov     r12, rdi                ; checksum filename

    ; Open file or use stdin
    cmp     byte [r12], '-'
    jne     .cof_open
    cmp     byte [r12+1], 0
    jne     .cof_open
    xor     ebx, ebx                ; stdin
    jmp     .cof_read_lines

.cof_open:
    mov     rax, SYS_OPEN
    mov     rdi, r12
    xor     esi, esi
    xor     edx, edx
    syscall
    test    rax, rax
    js      .cof_open_err
    mov     ebx, eax

.cof_read_lines:
    ; Read file and process line by line
    mov     [rsp], ebx              ; save checksum file fd
    mov     dword [rsp+4], 0        ; line_pos = 0
    mov     dword [rsp+8], 0        ; buf_len = 0
    xor     r13d, r13d              ; line number counter

.cof_next_line:
    ; Read a line into line_buf
    lea     rdi, [line_buf]
    xor     r14d, r14d              ; line length

.cof_getchar:
    ; Check if we need to read more data
    mov     eax, [rsp+4]
    cmp     eax, [rsp+8]
    jl      .cof_have_char

    ; Read more data
    mov     rax, SYS_READ
    mov     edi, ebx
    lea     rsi, [io_buf]
    mov     edx, 65536
    syscall
    cmp     rax, -EINTR
    je      .cof_getchar
    test    rax, rax
    jle     .cof_eof
    mov     [rsp+8], eax            ; buf_len
    mov     dword [rsp+4], 0        ; line_pos = 0

.cof_have_char:
    mov     eax, [rsp+4]
    movzx   ecx, byte [io_buf + rax]
    inc     dword [rsp+4]
    cmp     cl, 10                  ; newline?
    je      .cof_have_line
    cmp     r14d, 65530             ; bounds check
    jge     .cof_getchar            ; skip excess chars
    mov     [line_buf + r14], cl
    inc     r14d
    jmp     .cof_getchar

.cof_eof:
    test    r14d, r14d
    jz      .cof_done               ; no more data

.cof_have_line:
    inc     r13d                    ; line number
    mov     byte [line_buf + r14], 0 ; null terminate

    ; Parse the checksum line
    ; Format 1: <32 hex chars>  <filename>
    ; Format 1b: <32 hex chars> *<filename>
    ; Format 2 (BSD): MD5 (<filename>) = <32 hex chars>
    ; Also: line may start with \ for escaped filenames

    lea     rsi, [line_buf]
    xor     r15d, r15d              ; escaped flag

    ; Check for escaped prefix (backslash)
    cmp     byte [rsi], '\'
    jne     .cof_no_esc_prefix
    mov     r15d, 1
    inc     rsi
.cof_no_esc_prefix:

    ; Check for BSD format "MD5 ("
    cmp     dword [rsi], 0x2035444D ; "MD5 " in little-endian
    jne     .cof_try_standard
    cmp     byte [rsi+4], '('
    jne     .cof_try_standard

    ; BSD format: parse filename between "(" and ") = "
    add     rsi, 5                  ; skip "MD5 ("
    mov     rdi, rsi                ; start of filename
    ; Find ") = "
.cof_find_paren:
    cmp     byte [rsi], 0
    je      .cof_bad_format
    cmp     byte [rsi], ')'
    jne     .cof_fp_next
    cmp     byte [rsi+1], ' '
    jne     .cof_fp_next
    cmp     byte [rsi+2], '='
    jne     .cof_fp_next
    cmp     byte [rsi+3], ' '
    jne     .cof_fp_next
    ; Found ") = "
    mov     byte [rsi], 0           ; null-terminate filename
    add     rsi, 4                  ; point to hash
    ; rdi = filename, rsi = hash
    jmp     .cof_verify

.cof_fp_next:
    inc     rsi
    jmp     .cof_find_paren

.cof_try_standard:
    ; Standard format: check for 32 hex chars
    mov     rdi, rsi
    xor     ecx, ecx
.cof_count_hex:
    movzx   eax, byte [rdi + rcx]
    ; Check if hex digit
    cmp     al, '0'
    jl      .cof_hex_end
    cmp     al, '9'
    jle     .cof_hex_ok
    cmp     al, 'a'
    jl      .cof_hex_end
    cmp     al, 'f'
    jle     .cof_hex_ok
    cmp     al, 'A'
    jl      .cof_hex_end
    cmp     al, 'F'
    jle     .cof_hex_ok
    jmp     .cof_hex_end
.cof_hex_ok:
    inc     ecx
    jmp     .cof_count_hex
.cof_hex_end:
    cmp     ecx, 32
    jne     .cof_bad_format

    ; Should be followed by "  " or " *"
    mov     rsi, rdi                ; hash start
    lea     rdi, [rsi + 32]         ; after hash
    cmp     byte [rdi], ' '
    jne     .cof_bad_format
    inc     rdi
    cmp     byte [rdi], ' '
    je      .cof_std_text
    cmp     byte [rdi], '*'
    je      .cof_std_binary
    jmp     .cof_bad_format
.cof_std_text:
.cof_std_binary:
    inc     rdi                     ; rdi = filename start
    ; rsi = hash start, rdi = filename start — already correct for .cof_verify

.cof_verify:
    ; rdi = filename to check, rsi = expected hash (32 hex chars)
    push    rsi                     ; save expected hash
    push    rdi                     ; save filename

    ; Hash the file (ebx will be reused for target fd, restored later)
    call    md5_init
    ; Open and hash
    mov     rdi, [rsp]              ; filename
    cmp     byte [rdi], '-'
    jne     .cv_open
    cmp     byte [rdi+1], 0
    jne     .cv_open
    xor     ebx, ebx
    jmp     .cv_read

.cv_open:
    mov     rax, SYS_OPEN
    mov     rdi, [rsp]
    xor     esi, esi
    xor     edx, edx
    syscall
    test    rax, rax
    js      .cv_open_err
    mov     ebx, eax

.cv_read:
    ; Use io_buf2 (separate BSS buffer) to avoid clobbering io_buf
.cv_read_loop:
    mov     rax, SYS_READ
    mov     edi, ebx
    lea     rsi, [io_buf2]
    mov     edx, 65536
    syscall
    cmp     rax, -EINTR
    je      .cv_read_loop
    test    rax, rax
    js      .cv_read_err
    jz      .cv_read_done

    lea     rdi, [io_buf2]
    mov     rsi, rax
    call    md5_update
    jmp     .cv_read_loop

.cv_read_done:
    test    ebx, ebx
    jz      .cv_finalize
    push    rbx
    mov     rax, SYS_CLOSE
    mov     edi, ebx
    syscall
    pop     rbx

.cv_finalize:
    call    md5_final
    call    md5_to_hex

    pop     rdi                     ; filename
    pop     rsi                     ; expected hash

    ; Compare hex_out with expected hash (32 chars, case-insensitive)
    lea     rax, [hex_out]
    xor     ecx, ecx
.cv_cmp:
    cmp     ecx, 32
    jge     .cv_match
    movzx   edx, byte [rax + rcx]
    movzx   r8d, byte [rsi + rcx]
    ; Lowercase both
    cmp     dl, 'A'
    jl      .cv_c1
    cmp     dl, 'F'
    jg      .cv_c1
    add     dl, 32
.cv_c1:
    cmp     r8b, 'A'
    jl      .cv_c2
    cmp     r8b, 'F'
    jg      .cv_c2
    add     r8b, 32
.cv_c2:
    cmp     dl, r8b
    jne     .cv_no_match
    inc     ecx
    jmp     .cv_cmp

.cv_match:
    inc     dword [cnt_ok]
    ; Print "<filename>: OK\n" unless --quiet or --status
    cmp     byte [flag_status], 0
    jne     .cof_next_line_jmp
    cmp     byte [flag_quiet], 0
    jne     .cof_next_line_jmp
    ; Print filename
    push    rdi
    call    strlen
    mov     rdx, rax
    pop     rsi
    push    rsi
    WRITE   STDOUT, rsi, rdx
    WRITE   STDOUT, str_ok, str_ok_len
    pop     rdi
    jmp     .cof_next_line_jmp

.cv_no_match:
    inc     dword [cnt_mismatch]
    mov     byte [had_error], 1
    cmp     byte [flag_status], 0
    jne     .cof_next_line_jmp
    ; Print "<filename>: FAILED\n"
    push    rdi
    call    strlen
    mov     rdx, rax
    pop     rsi
    push    rsi
    WRITE   STDOUT, rsi, rdx
    WRITE   STDOUT, str_failed, str_failed_len
    pop     rdi
    jmp     .cof_next_line_jmp

.cv_open_err:
    pop     rdi                     ; filename
    pop     rsi                     ; expected hash

    ; Check if ignore-missing
    cmp     byte [flag_ignore], 0
    jne     .cv_ignored

    inc     dword [cnt_read_err]
    mov     byte [had_error], 1
    cmp     byte [flag_status], 0
    jne     .cof_next_line_jmp

    ; Save filename in r15 (callee-saved, preserved across syscalls)
    mov     r15, rdi

    ; Print error to stderr: "md5sum: <filename>: No such file or directory\n"
    WRITE   STDERR, err_prefix, err_prefix_len
    mov     rdi, r15
    call    strlen
    mov     rdx, rax
    WRITE   STDERR, r15, rdx
    WRITE   STDERR, err_no_such, err_no_such_len

    ; Print "<filename>: FAILED open or read\n" to stdout
    mov     rdi, r15
    call    strlen
    mov     rdx, rax
    WRITE   STDOUT, r15, rdx
    WRITE   STDOUT, str_failed_open, str_failed_open_len
    jmp     .cof_next_line_jmp

.cv_ignored:
    inc     dword [cnt_ignored]
    jmp     .cof_next_line_jmp

.cv_read_err:
    ; Close target file fd if not stdin
    test    ebx, ebx
    jz      .cv_re_no_close
    push    rax
    mov     rax, SYS_CLOSE
    mov     edi, ebx
    syscall
    pop     rax
.cv_re_no_close:
    pop     rdi
    pop     rsi
    inc     dword [cnt_read_err]
    mov     byte [had_error], 1
    jmp     .cof_next_line_jmp

.cof_bad_format:
    inc     dword [cnt_format_err]
    ; If --warn, print warning
    cmp     byte [flag_warn], 0
    je      .cof_next_line_jmp
    ; "md5sum: <checkfile>: <linenum>: improperly formatted..."
    WRITE   STDERR, err_prefix, err_prefix_len
    ; Print checksum filename
    push    r12
    mov     rdi, r12
    cmp     byte [rdi], '-'
    jne     .bf_not_stdin
    cmp     byte [rdi+1], 0
    jne     .bf_not_stdin
    WRITE   STDERR, str_stdin_name, 14
    jmp     .bf_colon
.bf_not_stdin:
    call    strlen
    mov     rdx, rax
    WRITE   STDERR, r12, rdx
.bf_colon:
    WRITE   STDERR, str_colon_space, str_colon_space_len
    ; Print line number
    mov     edi, r13d
    call    print_number_stderr
    ; ": improperly formatted MD5 checksum line\n"
    WRITE   STDERR, str_improperly, str_improperly_len
    pop     r12

.cof_next_line_jmp:
    mov     ebx, [rsp]              ; restore checksum file fd
    jmp     .cof_next_line

.cof_done:
    ; Close file if not stdin
    test    ebx, ebx
    jz      .cof_end
    mov     rax, SYS_CLOSE
    mov     edi, ebx
    syscall

.cof_end:
    ; Check ignore-missing: if no file was verified, print warning
    cmp     byte [flag_ignore], 0
    je      .cof_ret
    mov     eax, [cnt_ok]
    add     eax, [cnt_mismatch]
    test    eax, eax
    jnz     .cof_ret
    cmp     dword [cnt_ignored], 0
    je      .cof_ret
    cmp     byte [flag_status], 0
    jne     .cof_set_err
    WRITE   STDERR, err_prefix, err_prefix_len
    mov     rdi, r12
    cmp     byte [rdi], '-'
    jne     .cof_nv_fname
    cmp     byte [rdi+1], 0
    jne     .cof_nv_fname
    WRITE   STDERR, str_stdin_name, 14
    jmp     .cof_nv_msg
.cof_nv_fname:
    call    strlen
    mov     rdx, rax
    WRITE   STDERR, r12, rdx
.cof_nv_msg:
    WRITE   STDERR, str_no_file_verified, str_no_file_verified_len
.cof_set_err:
    mov     byte [had_error], 1

.cof_ret:
    add     rsp, 16
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

.cof_open_err:
    WRITE   STDERR, err_prefix, err_prefix_len
    mov     rdi, r12
    call    strlen
    mov     rdx, rax
    WRITE   STDERR, r12, rdx
    WRITE   STDERR, err_no_such, err_no_such_len
    mov     byte [had_error], 1
    jmp     .cof_ret

; ════════════════════════════════════════════════════════════════════
; print_number_stderr(edi=number) — Print decimal number to stderr
; ════════════════════════════════════════════════════════════════════
print_number_stderr:
    push    rbx
    lea     rbx, [num_buf + 30]     ; end of buffer
    mov     byte [rbx+1], 0
    mov     eax, edi
    test    eax, eax
    jnz     .pn_loop
    mov     byte [rbx], '0'
    dec     rbx
    jmp     .pn_done
.pn_loop:
    test    eax, eax
    jz      .pn_done
    xor     edx, edx
    mov     ecx, 10
    div     ecx
    add     dl, '0'
    mov     [rbx], dl
    dec     rbx
    jmp     .pn_loop
.pn_done:
    inc     rbx
    lea     rsi, [rbx]
    lea     rdx, [num_buf + 31]
    sub     rdx, rbx
    WRITE   STDERR, rsi, rdx
    pop     rbx
    ret

; NX stack
section .note.GNU-stack noalloc noexec nowrite progbits
