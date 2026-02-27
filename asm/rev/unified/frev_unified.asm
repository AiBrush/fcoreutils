; frev_unified.asm
; Auto-merged from modular source — DO NOT EDIT
; Edit the modular files in tools/ and lib/ instead
; Generated: 2026-02-26
; Source files: tools/frev.asm, lib/io.asm
;
; Build: nasm -f bin frev_unified.asm -o frev && chmod +x frev
;
; GNU-compatible "rev" in x86_64 Linux assembly.
; Reverses each line of input characterwise.
; ~2KB static ELF binary, no libc, no dependencies.
; SSSE3 pshufb for fast 16-byte-at-a-time reversal.

BITS 64
org 0x400000

; ─── System Constants ────────────────────────────────────
%define SYS_READ        0
%define SYS_WRITE       1
%define SYS_OPEN        2
%define SYS_CLOSE       3
%define SYS_RT_SIGACTION 13
%define SYS_EXIT       60

%define STDIN           0
%define STDOUT          1
%define STDERR          2
%define O_RDONLY        0
%define SIGPIPE        13

%define READ_BUF_SIZE  65536
%define OUT_BUF_SIZE   1114112     ; >= LINE_BUF_SIZE + 1 to prevent overflow
%define LINE_BUF_SIZE  1048576
%define FLUSH_THRESHOLD 65536

; ─── ELF Header ──────────────────────────────────────────
ehdr:
    db 0x7F, "ELF"         ; magic
    db 2                    ; 64-bit
    db 1                    ; little endian
    db 1                    ; ELF version
    db 0                    ; OS/ABI
    dq 0                    ; padding
    dw 2                    ; ET_EXEC
    dw 0x3E                 ; x86-64
    dd 1                    ; ELF version
    dq _start               ; entry point
    dq phdr - ehdr          ; program header offset
    dq 0                    ; section header offset (none)
    dd 0                    ; flags
    dw ehdr_size            ; ELF header size
    dw phdr_size            ; program header entry size
    dw 2                    ; number of program headers
    dw 0                    ; section header entry size
    dw 0                    ; number of section headers
    dw 0                    ; section name string table index
ehdr_size equ $ - ehdr

; ─── Program Headers ─────────────────────────────────────
phdr:
    ; PT_LOAD: code + data
    dd 1                    ; PT_LOAD
    dd 5                    ; PF_R | PF_X
    dq 0                    ; offset
    dq 0x400000             ; vaddr
    dq 0x400000             ; paddr
    dq file_size            ; filesz
    dq file_size + bss_size ; memsz (includes BSS)
    dq 0x1000               ; align
phdr_size equ $ - phdr

    ; PT_GNU_STACK: non-executable stack
    dd 0x6474E551           ; PT_GNU_STACK
    dd 6                    ; PF_R | PF_W (no PF_X → NX stack)
    dq 0
    dq 0
    dq 0
    dq 0
    dq 0
    dq 0x10

; ─── Code ────────────────────────────────────────────────

_start:
    ; Set SIGPIPE to SIG_DFL
    mov     eax, SYS_RT_SIGACTION
    mov     edi, SIGPIPE
    lea     rsi, [rel sigact_buf]
    xor     edx, edx
    mov     r10d, 8
    syscall

    ; Parse argc/argv
    mov     r14, [rsp]              ; argc
    lea     r15, [rsp + 8]          ; argv[0]
    dec     r14                     ; skip argv[0]
    add     r15, 8

    ; Initialize global state
    xor     ebp, ebp                ; had_error = 0
    xor     r12d, r12d              ; out_buf_used = 0
    xor     r13d, r13d              ; processed_any = 0

    test    r14, r14
    jz      .done_files

    xor     ebx, ebx                ; arg index
    xor     ecx, ecx                ; seen_dashdash

.parse_loop:
    cmp     rbx, r14
    jge     .done_files

    mov     rsi, [r15 + rbx*8]

    test    ecx, ecx
    jnz     .is_file

    cmp     byte [rsi], '-'
    jne     .is_file
    cmp     byte [rsi+1], '-'
    jne     .check_dash_stdin

    ; Starts with "--"
    cmp     byte [rsi+2], 0
    je      .set_dashdash

    ; Check --help (compare 7 bytes: "--help\0")
    push    rcx
    push    rbx
    lea     rdi, [rel str_help]
    call    strcmp
    pop     rbx
    pop     rcx
    test    eax, eax
    jz      .do_help

    mov     rsi, [r15 + rbx*8]
    push    rcx
    push    rbx
    lea     rdi, [rel str_version]
    call    strcmp
    pop     rbx
    pop     rcx
    test    eax, eax
    jz      .do_version

    ; Unknown --option
    push    rcx
    push    rbx
    mov     rsi, [r15 + rbx*8]
    call    err_unrecognized_option
    pop     rbx
    pop     rcx
    mov     edi, 1
    mov     eax, SYS_EXIT
    syscall

.check_dash_stdin:
    cmp     byte [rsi+1], 0
    je      .is_stdin
    ; Check for -h (help)
    cmp     byte [rsi+1], 'h'
    jne     .check_V
    cmp     byte [rsi+2], 0
    je      .do_help
    jmp     .invalid_short_opt
.check_V:
    ; Check for -V (version)
    cmp     byte [rsi+1], 'V'
    jne     .invalid_short_opt
    cmp     byte [rsi+2], 0
    je      .do_version
.invalid_short_opt:
    push    rcx
    push    rbx
    mov     rsi, [r15 + rbx*8]
    call    err_invalid_option
    pop     rbx
    pop     rcx
    mov     edi, 1
    mov     eax, SYS_EXIT
    syscall

.set_dashdash:
    mov     ecx, 1
    jmp     .parse_next

.is_stdin:
    push    rcx
    push    rbx
    mov     r13d, 1                 ; mark as processed
    xor     edi, edi                ; STDIN = 0
    call    process_fd
    pop     rbx
    pop     rcx
    jmp     .parse_next

.is_file:
    push    rcx
    push    rbx
    mov     r13d, 1                 ; mark as processed
    mov     rsi, [r15 + rbx*8]
    call    open_and_process
    pop     rbx
    pop     rcx
    jmp     .parse_next

.parse_next:
    inc     rbx
    jmp     .parse_loop

.done_files:
    ; If no files/stdin were processed, read stdin
    test    r13, r13
    jnz     .final_flush
    xor     edi, edi
    call    process_fd

.final_flush:
    call    flush_output
    test    eax, eax
    jnz     .write_error_exit
    movzx   edi, bpl
    mov     eax, SYS_EXIT
    syscall

.write_error_exit:
    lea     rdi, [rel str_write_error]
    call    print_error_simple
    mov     edi, 1
    mov     eax, SYS_EXIT
    syscall

.do_help:
    call    flush_output
    mov     edi, STDOUT
    lea     rsi, [rel help_text]
    mov     edx, help_text_len
    call    write_all
    xor     edi, edi
    mov     eax, SYS_EXIT
    syscall

.do_version:
    call    flush_output
    mov     edi, STDOUT
    lea     rsi, [rel version_text]
    mov     edx, version_text_len
    call    write_all
    xor     edi, edi
    mov     eax, SYS_EXIT
    syscall

; ─── open_and_process(rsi=filename) ──────────────────────
open_and_process:
    push    rbx
    mov     rbx, rsi

    mov     rdi, rsi
    xor     esi, esi                ; O_RDONLY
    xor     edx, edx
    mov     eax, SYS_OPEN
    syscall

    test    rax, rax
    js      .oap_error

    push    rax                     ; save fd
    mov     edi, eax
    call    process_fd
    pop     rdi                     ; fd
    mov     eax, SYS_CLOSE
    syscall

    pop     rbx
    ret

.oap_error:
    neg     eax
    mov     rdi, rbx
    mov     esi, eax
    call    err_file
    mov     ebp, 1
    pop     rbx
    ret

; ─── process_fd(edi=fd) ─────────────────────────────────
process_fd:
    push    rbx
    push    r14
    push    r15

    mov     ebx, edi
    lea     r14, [rel line_buf]
    xor     r15d, r15d

.pf_read:
    mov     edi, ebx
    lea     rsi, [rel read_buf]
    mov     edx, READ_BUF_SIZE
.pf_read_retry:
    mov     eax, SYS_READ
    syscall
    cmp     rax, -4
    je      .pf_read_retry

    test    rax, rax
    js      .pf_error
    jz      .pf_eof

    xor     r8d, r8d                ; offset
    mov     r9, rax                 ; total bytes

    movdqa  xmm1, [rel newline_pattern]

.pf_simd:
    mov     rax, r9
    sub     rax, r8
    cmp     rax, 16
    jl      .pf_scalar

    lea     rdi, [rel read_buf]
    add     rdi, r8
    movdqu  xmm0, [rdi]
    pcmpeqb xmm0, xmm1
    pmovmskb eax, xmm0

    test    eax, eax
    jnz     .pf_simd_nl

    ; No newline — copy 16 bytes to line_buf
    lea     rcx, [r15 + 16]
    cmp     rcx, LINE_BUF_SIZE
    jge     .pf_overflow

    movdqu  xmm2, [rdi]
    movdqu  [r14 + r15], xmm2
    add     r15, 16
    add     r8, 16
    jmp     .pf_simd

.pf_simd_nl:
    bsf     ecx, eax                ; first \n position

    ; Copy bytes before newline
    test    ecx, ecx
    jz      .pf_simd_emit

    lea     rdx, [r15 + rcx]
    cmp     rdx, LINE_BUF_SIZE
    jge     .pf_overflow

    ; Copy ecx bytes with rep movsb
    lea     rsi, [rel read_buf]
    add     rsi, r8
    lea     rdi, [r14 + r15]
    push    rcx
    rep     movsb
    pop     rcx
    add     r15, rcx

.pf_simd_emit:
    push    r8
    push    r9
    push    rcx
    call    reverse_and_emit_line
    pop     rcx
    pop     r9
    pop     r8

    add     r8, rcx
    inc     r8                      ; skip \n
    xor     r15d, r15d
    jmp     .pf_simd

.pf_scalar:
    cmp     r8, r9
    jge     .pf_read

    lea     rsi, [rel read_buf]
    movzx   eax, byte [rsi + r8]
    cmp     al, 10
    je      .pf_scalar_nl

    cmp     r15, LINE_BUF_SIZE
    jge     .pf_overflow
    mov     [r14 + r15], al
    inc     r15
    inc     r8
    jmp     .pf_scalar

.pf_scalar_nl:
    push    r8
    push    r9
    call    reverse_and_emit_line
    pop     r9
    pop     r8
    inc     r8
    xor     r15d, r15d
    jmp     .pf_scalar

.pf_eof:
    test    r15, r15
    jz      .pf_done
    call    reverse_and_emit_nolf

.pf_done:
    pop     r15
    pop     r14
    pop     rbx
    ret

.pf_error:
    mov     ebp, 1
    jmp     .pf_done

.pf_overflow:
    push    r8
    push    r9
    call    reverse_and_emit_line
    pop     r9
    pop     r8
    xor     r15d, r15d
    jmp     .pf_scalar

; ─── reverse_and_emit_line() ─────────────────────────────
; Reverses line_buf[0..r15) + \n into out_buf.
reverse_and_emit_line:
    test    r15, r15
    jz      .rel_newline

    lea     rax, [r12 + r15 + 1]
    cmp     rax, OUT_BUF_SIZE
    jl      .rel_ok
    call    flush_output
    test    eax, eax
    jnz     .rel_err
.rel_ok:
    lea     rdi, [rel out_buf]
    add     rdi, r12
    mov     rcx, r15

    cmp     rcx, 16
    jl      .rel_sc

    movdqa  xmm3, [rel reverse_mask]
    lea     rsi, [r14 + r15]

.rel_simd:
    cmp     rcx, 16
    jl      .rel_tail
    sub     rsi, 16
    movdqu  xmm0, [rsi]
    pshufb  xmm0, xmm3
    movdqu  [rdi], xmm0
    add     rdi, 16
    sub     rcx, 16
    jmp     .rel_simd

.rel_tail:
    test    rcx, rcx
    jz      .rel_nl
    lea     rsi, [r14 + rcx - 1]
    jmp     .rel_sc_lp

.rel_sc:
    lea     rsi, [r14 + rcx - 1]
.rel_sc_lp:
    test    rcx, rcx
    jz      .rel_nl
    movzx   eax, byte [rsi]
    mov     [rdi], al
    dec     rsi
    inc     rdi
    dec     rcx
    jmp     .rel_sc_lp

.rel_nl:
    lea     rdi, [rel out_buf]
    add     rdi, r12
    add     rdi, r15
    mov     byte [rdi], 10
    lea     rax, [r15 + 1]
    add     r12, rax

    cmp     r12, FLUSH_THRESHOLD
    jl      .rel_ret
    call    flush_output
    test    eax, eax
    jnz     .rel_err
.rel_ret:
    ret

.rel_newline:
    lea     rax, [r12 + 1]
    cmp     rax, OUT_BUF_SIZE
    jl      .rel_nl_ok
    call    flush_output
    test    eax, eax
    jnz     .rel_err
.rel_nl_ok:
    lea     rdi, [rel out_buf]
    add     rdi, r12
    mov     byte [rdi], 10
    inc     r12
    cmp     r12, FLUSH_THRESHOLD
    jl      .rel_ret
    call    flush_output
    test    eax, eax
    jnz     .rel_err
    ret

.rel_err:
    mov     ebp, 1
    ret

; ─── reverse_and_emit_nolf() ─────────────────────────────
reverse_and_emit_nolf:
    test    r15, r15
    jz      .ren_ret

    lea     rax, [r12 + r15]
    cmp     rax, OUT_BUF_SIZE
    jl      .ren_ok
    call    flush_output
    test    eax, eax
    jnz     .ren_err
.ren_ok:
    lea     rdi, [rel out_buf]
    add     rdi, r12
    mov     rcx, r15

    cmp     rcx, 16
    jl      .ren_sc

    movdqa  xmm3, [rel reverse_mask]
    lea     rsi, [r14 + r15]

.ren_simd:
    cmp     rcx, 16
    jl      .ren_tail
    sub     rsi, 16
    movdqu  xmm0, [rsi]
    pshufb  xmm0, xmm3
    movdqu  [rdi], xmm0
    add     rdi, 16
    sub     rcx, 16
    jmp     .ren_simd

.ren_tail:
    test    rcx, rcx
    jz      .ren_upd
    lea     rsi, [r14 + rcx - 1]
    jmp     .ren_sc_lp

.ren_sc:
    lea     rsi, [r14 + rcx - 1]
.ren_sc_lp:
    test    rcx, rcx
    jz      .ren_upd
    movzx   eax, byte [rsi]
    mov     [rdi], al
    dec     rsi
    inc     rdi
    dec     rcx
    jmp     .ren_sc_lp

.ren_upd:
    add     r12, r15
.ren_ret:
    ret
.ren_err:
    mov     ebp, 1
    ret

; ─── flush_output() ──────────────────────────────────────
flush_output:
    test    r12, r12
    jz      .fo_zero
    mov     edi, STDOUT
    lea     rsi, [rel out_buf]
    mov     rdx, r12
    call    write_all
    xor     r12d, r12d
    ret
.fo_zero:
    xor     eax, eax
    ret

; ─── write_all(edi=fd, rsi=buf, rdx=len) → rax ──────────
; Handles partial writes + EINTR. Returns 0 success, -1 error.
write_all:
    push    rbx
    push    r13
    push    r14
    mov     ebx, edi
    mov     r13, rsi
    mov     r14, rdx
.wa_loop:
    test    r14, r14
    jle     .wa_ok
    mov     edi, ebx
    mov     rsi, r13
    mov     rdx, r14
    mov     eax, SYS_WRITE
    syscall
    cmp     rax, -4
    je      .wa_loop
    test    rax, rax
    js      .wa_fail
    add     r13, rax
    sub     r14, rax
    jmp     .wa_loop
.wa_ok:
    xor     eax, eax
    pop     r14
    pop     r13
    pop     rbx
    ret
.wa_fail:
    or      eax, -1
    pop     r14
    pop     r13
    pop     rbx
    ret

; ─── strcmp(rdi=s1, rsi=s2) → eax ────────────────────────
strcmp:
.sc_lp:
    movzx   eax, byte [rdi]
    movzx   ecx, byte [rsi]
    cmp     al, cl
    jne     .sc_ne
    test    al, al
    jz      .sc_eq
    inc     rdi
    inc     rsi
    jmp     .sc_lp
.sc_eq:
    xor     eax, eax
    ret
.sc_ne:
    mov     eax, 1
    ret

; ─── strlen(rdi=s) → rax ────────────────────────────────
strlen:
    xor     eax, eax
.sl_lp:
    cmp     byte [rdi + rax], 0
    je      .sl_r
    inc     eax
    jmp     .sl_lp
.sl_r:
    ret

; ─── print_error_simple(rdi=msg) ─────────────────────────
print_error_simple:
    push    rbx
    mov     rbx, rdi
    mov     edi, STDERR
    lea     rsi, [rel str_prefix]
    mov     edx, str_prefix_len
    call    write_all
    mov     rdi, rbx
    call    strlen
    mov     edx, eax
    mov     edi, STDERR
    mov     rsi, rbx
    call    write_all
    mov     edi, STDERR
    lea     rsi, [rel str_newline]
    mov     edx, 1
    call    write_all
    pop     rbx
    ret

; ─── err_file(rdi=name, esi=errno) ───────────────────────
err_file:
    push    rbx
    push    r13
    mov     rbx, rdi
    mov     r13d, esi

    mov     edi, STDERR
    lea     rsi, [rel str_cannot_open]
    mov     edx, str_cannot_open_len
    call    write_all

    mov     rdi, rbx
    call    strlen
    mov     edx, eax
    mov     edi, STDERR
    mov     rsi, rbx
    call    write_all

    mov     edi, STDERR
    lea     rsi, [rel str_colon_space]
    mov     edx, 2
    call    write_all

    mov     edi, r13d
    call    strerror
    mov     rbx, rax
    mov     rdi, rax
    call    strlen
    mov     edx, eax
    mov     edi, STDERR
    mov     rsi, rbx
    call    write_all

    mov     edi, STDERR
    lea     rsi, [rel str_newline]
    mov     edx, 1
    call    write_all

    pop     r13
    pop     rbx
    ret

; ─── err_unrecognized_option(rsi=opt) ────────────────────
err_unrecognized_option:
    push    rbx
    mov     rbx, rsi

    mov     edi, STDERR
    lea     rsi, [rel str_unrec]
    mov     edx, str_unrec_len
    call    write_all

    mov     rdi, rbx
    call    strlen
    mov     edx, eax
    mov     edi, STDERR
    mov     rsi, rbx
    call    write_all

    mov     edi, STDERR
    lea     rsi, [rel str_quote_nl]
    mov     edx, 2
    call    write_all

    mov     edi, STDERR
    lea     rsi, [rel str_try_help]
    mov     edx, str_try_help_len
    call    write_all

    pop     rbx
    ret

; ─── err_invalid_option(rsi=opt) ─────────────────────────
err_invalid_option:
    push    rbx
    mov     rbx, rsi

    mov     edi, STDERR
    lea     rsi, [rel str_invalid_opt]
    mov     edx, str_invalid_opt_len
    call    write_all

    mov     edi, STDERR
    lea     rsi, [rbx + 1]
    mov     edx, 1
    call    write_all

    mov     edi, STDERR
    lea     rsi, [rel str_quote_nl]
    mov     edx, 2
    call    write_all

    mov     edi, STDERR
    lea     rsi, [rel str_try_help]
    mov     edx, str_try_help_len
    call    write_all

    pop     rbx
    ret

; ─── strerror(edi=errno) → rax ───────────────────────────
strerror:
    cmp     edi, 2
    je      .se2
    cmp     edi, 13
    je      .se13
    cmp     edi, 21
    je      .se21
    cmp     edi, 1
    je      .se1
    cmp     edi, 5
    je      .se5
    cmp     edi, 12
    je      .se12
    cmp     edi, 20
    je      .se20
    lea     rax, [rel str_eunk]
    ret
.se1:
    lea     rax, [rel str_eperm]
    ret
.se2:
    lea     rax, [rel str_enoent]
    ret
.se5:
    lea     rax, [rel str_eio]
    ret
.se12:
    lea     rax, [rel str_enomem]
    ret
.se13:
    lea     rax, [rel str_eacces]
    ret
.se20:
    lea     rax, [rel str_enotdir]
    ret
.se21:
    lea     rax, [rel str_eisdir]
    ret

; ─── Data ────────────────────────────────────────────────
align 16
reverse_mask:
    db 15,14,13,12,11,10,9,8,7,6,5,4,3,2,1,0

align 16
newline_pattern:
    times 16 db 10

sigact_buf:
    dq 0, 0x04000000, 0, 0

str_prefix:     db "rev: "
str_prefix_len equ $ - str_prefix

str_cannot_open: db "rev: cannot open "
str_cannot_open_len equ $ - str_cannot_open

str_newline:    db 10
str_colon_space: db ": "

str_help:       db "--help", 0
str_version:    db "--version", 0

str_unrec: db "rev: unrecognized option '"
str_unrec_len equ $ - str_unrec

str_quote_nl:   db "'", 10
str_write_error: db "write error", 0

str_try_help: db "Try 'rev --help' for more information.", 10
str_try_help_len equ $ - str_try_help

str_invalid_opt: db "rev: invalid option -- '"
str_invalid_opt_len equ $ - str_invalid_opt

help_text:
    db 10
    db "Usage:", 10
    db " rev [options] [<file> ...]", 10
    db 10
    db "Reverse lines characterwise.", 10
    db 10
    db "Options:", 10
    db " -h, --help     display this help", 10
    db " -V, --version  display version", 10
    db 10
    db "For more details see rev(1).", 10
help_text_len equ $ - help_text

version_text:
    db "rev from util-linux 2.41", 10
version_text_len equ $ - version_text

str_eperm:   db "Operation not permitted", 0
str_enoent:  db "No such file or directory", 0
str_eio:     db "Input/output error", 0
str_enomem:  db "Cannot allocate memory", 0
str_eacces:  db "Permission denied", 0
str_enotdir: db "Not a directory", 0
str_eisdir:  db "Is a directory", 0
str_eunk:    db "Unknown error", 0

file_size equ $ - ehdr

; ─── BSS ─────────────────────────────────────────────────
absolute $ + 0x400000

read_buf:   resb READ_BUF_SIZE
out_buf:    resb OUT_BUF_SIZE
line_buf:   resb LINE_BUF_SIZE

bss_size equ $ - (file_size + 0x400000)
