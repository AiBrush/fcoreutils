; ============================================================================
;  ffold.asm — GNU-compatible "fold" in x86_64 Linux assembly (SIMD optimized)
;
;  A drop-in replacement for GNU coreutils `fold`. Pure x86-64 assembly,
;  no libc, no dynamic linker. Handles all flags:
;    -b (count bytes), -s (break at spaces), -w WIDTH (column width),
;    --width=WIDTH, --bytes, --spaces, --help, --version, --
;
;  On glibc systems, GNU fold does NOT do multibyte. Column counting:
;    tab -> next multiple of 8, backspace -> col-1 (min 0),
;    \r -> col=0, \n -> output + col=0, all others -> col+1.
;
;  Optimization strategy:
;    - mmap input files for zero-copy access
;    - SSE2 SIMD to scan for special chars / newlines
;    - Line-at-a-time processing: scan for next special char, bulk copy
;    - Large output buffer (512KB) flushed only when near full
;
;  Register conventions (global state):
;    r12 = out_pos (bytes in output buffer)
;    ebp = had_error (0=ok, 1=error)
;
;  Build (modular):
;    nasm -f elf64 -I include/ tools/ffold.asm -o build/tools/ffold.o
;    nasm -f elf64 -I include/ lib/io.asm -o build/lib/io.o
;    ld --gc-sections -n build/tools/ffold.o build/lib/io.o -o ffold
; ============================================================================

%include "include/linux.inc"
%include "include/macros.inc"

default rel

extern asm_write_all
extern asm_read
extern asm_open
extern asm_close

; ── Constants ──────────────────────────────────────────────
%define READ_BUF_SIZE   131072          ; 128KB input buffer (for stdin)
%define OUT_BUF_SIZE    1048576         ; 1MB output buffer
%define FLUSH_THRESHOLD 786432          ; flush when output exceeds ~768KB
%define MAX_FILES       256
%define DEFAULT_WIDTH   80

; mmap constants
%define PROT_READ       1
%define MAP_PRIVATE     2
%define MAP_POPULATE    0x8000
%define MADV_SEQUENTIAL 2
%define MADV_HUGEPAGE   14
%define SYS_MADVISE     28

; struct stat offsets (x86-64)
%define STAT_SIZE       144
%define STAT_ST_SIZE    48
%define ST_SIZE_OFF     48

global _start

section .text

; ============================================================================
;  Entry Point
; ============================================================================
_start:
    BLOCK_SIGPIPE

    mov     ecx, [rsp]
    lea     r14, [rsp + 8]

    xor     ebp, ebp
    xor     r12d, r12d
    mov     dword [width], DEFAULT_WIDTH
    mov     byte [flag_bytes], 0
    mov     byte [flag_spaces], 0
    mov     dword [num_files], 0

    lea     rbx, [r14 + 8]
    dec     ecx
    mov     [argc_rem], ecx
    mov     byte [past_dashdash], 0

; ── Argument parsing ──────────────────────────────────────
.parse_loop:
    mov     ecx, [argc_rem]
    test    ecx, ecx
    jle     .parse_done
    mov     rsi, [rbx]
    test    rsi, rsi
    jz      .parse_done

    cmp     byte [past_dashdash], 1
    je      .add_file

    cmp     byte [rsi], '-'
    jne     .add_file
    cmp     byte [rsi + 1], 0
    je      .add_file

    cmp     byte [rsi + 1], '-'
    je      .check_long

    inc     rsi
    call    parse_short_options
    jmp     .next_arg

.check_long:
    cmp     byte [rsi + 2], 0
    jne     .long_opt
    mov     byte [past_dashdash], 1
    jmp     .next_arg

.long_opt:
    call    parse_long_option
    jmp     .next_arg

.add_file:
    mov     eax, [num_files]
    cmp     eax, MAX_FILES
    jge     .next_arg
    lea     rdi, [files]
    mov     [rdi + rax*8], rsi
    inc     eax
    mov     [num_files], eax
    jmp     .next_arg

.next_arg:
    add     rbx, 8
    dec     dword [argc_rem]
    jmp     .parse_loop

.parse_done:
    ; Initialize SSE2 constants
    call    init_simd_constants

    mov     eax, [num_files]
    test    eax, eax
    jnz     .process_files

    mov     edi, STDIN
    call    try_mmap_or_read
    jmp     .final_flush

.process_files:
    xor     r13d, r13d
.file_loop:
    cmp     r13d, [num_files]
    jge     .final_flush

    lea     rdi, [files]
    mov     rsi, [rdi + r13*8]

    cmp     byte [rsi], '-'
    jne     .open_file
    cmp     byte [rsi + 1], 0
    jne     .open_file
    push    r13
    mov     edi, STDIN
    call    try_mmap_or_read
    pop     r13
    jmp     .next_file

.open_file:
    push    r13
    call    open_and_process
    pop     r13

.next_file:
    inc     r13d
    jmp     .file_loop

.final_flush:
    call    flush_output
    test    eax, eax
    jnz     .write_error_exit

    movzx   rdi, bpl
    EXIT    rdi

.write_error_exit:
    lea     rdi, [str_write_error]
    call    print_error_msg
    mov     rdi, 1
    EXIT    rdi

; ============================================================================
;  init_simd_constants
; ============================================================================
init_simd_constants:
    ; xmm7 = all 0x0A (newline)
    mov     eax, 0x0A0A0A0A
    movd    xmm7, eax
    pshufd  xmm7, xmm7, 0

    ; xmm6 = all 0x0E (threshold: bytes < 0x0E are potentially special)
    mov     eax, 0x0E0E0E0E
    movd    xmm6, eax
    pshufd  xmm6, xmm6, 0

    ret

; ============================================================================
;  parse_short_options(rsi = first option char after '-')
; ============================================================================
parse_short_options:
    push    rbx

.pso_loop:
    movzx   eax, byte [rsi]
    test    al, al
    jz      .pso_done

    cmp     al, 'b'
    je      .pso_bytes
    cmp     al, 's'
    je      .pso_spaces
    cmp     al, 'w'
    je      .pso_width
    jmp     .pso_invalid

.pso_bytes:
    mov     byte [flag_bytes], 1
    inc     rsi
    jmp     .pso_loop

.pso_spaces:
    mov     byte [flag_spaces], 1
    inc     rsi
    jmp     .pso_loop

.pso_width:
    inc     rsi
    movzx   eax, byte [rsi]
    test    al, al
    jz      .pso_width_next_arg
    cmp     al, '0'
    jl      .pso_width_next_arg
    cmp     al, '9'
    jg      .pso_width_next_arg
    push    rsi
    call    parse_number
    test    eax, eax
    js      .pso_invalid_width_inline
    mov     [width], eax
    add     rsp, 8
    jmp     .pso_loop

.pso_invalid_width_inline:
    pop     rsi
    call    print_invalid_width
    mov     rdi, 1
    EXIT    rdi

.pso_width_next_arg:
    pop     rbx
    add     rbx, 8
    dec     dword [argc_rem]
    cmp     dword [argc_rem], 0
    jle     .pso_missing_width
    mov     rsi, [rbx]
    push    rsi
    push    rbx
    call    parse_number
    pop     rbx
    test    eax, eax
    js      .pso_invalid_width_nextarg
    mov     [width], eax
    add     rsp, 8
    push    rbx
    jmp     .pso_done

.pso_invalid_width_nextarg:
    pop     rsi
    call    print_invalid_width
    mov     rdi, 1
    EXIT    rdi

.pso_missing_width:
    lea     rdi, [str_prefix]
    mov     edx, str_prefix_len
    call    write_stderr
    lea     rdi, [str_w_requires_arg]
    mov     edx, str_w_requires_arg_len
    call    write_stderr
    lea     rdi, [str_newline]
    mov     edx, 1
    call    write_stderr
    lea     rdi, [str_try_help]
    mov     edx, str_try_help_len
    call    write_stderr
    mov     rdi, 1
    EXIT    rdi

.pso_invalid:
    mov     [opt_char_buf], al
    lea     rdi, [str_invalid_opt]
    mov     edx, str_invalid_opt_len
    call    write_stderr
    lea     rdi, [opt_char_buf]
    mov     edx, 1
    call    write_stderr
    lea     rdi, [str_quote_nl]
    mov     edx, 2
    call    write_stderr
    lea     rdi, [str_try_help]
    mov     edx, str_try_help_len
    call    write_stderr
    mov     rdi, 1
    EXIT    rdi

.pso_done:
    pop     rbx
    ret

; ============================================================================
;  parse_long_option(rsi = "--xxx..." string)
; ============================================================================
parse_long_option:
    push    rbx

    lea     rdi, [str_dashdash_help]
    call    strcmp
    test    eax, eax
    jz      .plo_help

    mov     rsi, [rbx]
    lea     rdi, [str_dashdash_version]
    call    strcmp
    test    eax, eax
    jz      .plo_version

    mov     rsi, [rbx]
    lea     rdi, [str_dashdash_bytes]
    call    strcmp
    test    eax, eax
    jz      .plo_bytes

    mov     rsi, [rbx]
    lea     rdi, [str_dashdash_spaces]
    call    strcmp
    test    eax, eax
    jz      .plo_spaces

    mov     rsi, [rbx]
    lea     rdi, [str_dashdash_width_eq]
    mov     ecx, 8
    call    strncmp
    test    eax, eax
    jz      .plo_width_eq

    mov     rsi, [rbx]
    lea     rdi, [str_dashdash_width]
    call    strcmp
    test    eax, eax
    jz      .plo_width_sep

    mov     rsi, [rbx]
    jmp     .plo_unrecognized

.plo_help:
    call    flush_output
    mov     rdi, STDOUT
    lea     rsi, [help_text]
    mov     rdx, help_text_len
    call    asm_write_all
    xor     edi, edi
    EXIT    rdi

.plo_version:
    call    flush_output
    mov     rdi, STDOUT
    lea     rsi, [version_text]
    mov     rdx, version_text_len
    call    asm_write_all
    xor     edi, edi
    EXIT    rdi

.plo_bytes:
    mov     byte [flag_bytes], 1
    pop     rbx
    ret

.plo_spaces:
    mov     byte [flag_spaces], 1
    pop     rbx
    ret

.plo_width_eq:
    mov     rsi, [rbx]
    add     rsi, 8
    cmp     byte [rsi], 0
    je      .plo_width_invalid
    push    rsi
    call    parse_number
    test    eax, eax
    js      .plo_width_invalid_pop
    mov     [width], eax
    add     rsp, 8
    pop     rbx
    ret

.plo_width_invalid_pop:
    pop     rsi
.plo_width_invalid:
    call    print_invalid_width
    mov     rdi, 1
    EXIT    rdi

.plo_width_sep:
    pop     rbx
    add     rbx, 8
    dec     dword [argc_rem]
    cmp     dword [argc_rem], 0
    jle     .plo_width_missing
    mov     rsi, [rbx]
    push    rsi
    push    rbx
    call    parse_number
    pop     rbx
    test    eax, eax
    js      .plo_width_sep_invalid
    mov     [width], eax
    add     rsp, 8
    push    rbx
    pop     rbx
    ret

.plo_width_sep_invalid:
    pop     rsi
    call    print_invalid_width
    mov     rdi, 1
    EXIT    rdi

.plo_width_missing:
    lea     rdi, [str_prefix]
    mov     edx, str_prefix_len
    call    write_stderr
    lea     rdi, [str_width_requires_arg]
    mov     edx, str_width_requires_arg_len
    call    write_stderr
    lea     rdi, [str_newline]
    mov     edx, 1
    call    write_stderr
    lea     rdi, [str_try_help]
    mov     edx, str_try_help_len
    call    write_stderr
    mov     rdi, 1
    EXIT    rdi

.plo_unrecognized:
    lea     rdi, [str_unrecognized]
    mov     edx, str_unrecognized_len
    call    write_stderr
    mov     rsi, [rbx]
    push    rsi
    mov     rdi, rsi
    call    strlen
    mov     rdx, rax
    pop     rsi
    mov     rdi, rsi
    call    write_stderr_buf
    lea     rdi, [str_quote_nl]
    mov     edx, 2
    call    write_stderr
    lea     rdi, [str_try_help]
    mov     edx, str_try_help_len
    call    write_stderr
    mov     rdi, 1
    EXIT    rdi

; ============================================================================
;  parse_number, print_invalid_width
; ============================================================================
parse_number:
    xor     eax, eax
    movzx   edx, byte [rsi]
    cmp     dl, '0'
    jl      .pn_bad
    cmp     dl, '9'
    jg      .pn_bad
.pn_loop:
    movzx   edx, byte [rsi]
    cmp     dl, '0'
    jl      .pn_check
    cmp     dl, '9'
    jg      .pn_check
    imul    eax, 10
    jo      .pn_bad
    sub     edx, '0'
    add     eax, edx
    jo      .pn_bad
    inc     rsi
    jmp     .pn_loop
.pn_check:
    test    dl, dl
    jnz     .pn_bad
    test    eax, eax
    jz      .pn_bad
    ret
.pn_bad:
    mov     eax, -1
    ret

print_invalid_width:
    push    rbx
    mov     rbx, rsi
    lea     rdi, [str_prefix]
    mov     edx, str_prefix_len
    call    write_stderr
    lea     rdi, [str_invalid_width_pre]
    mov     edx, str_invalid_width_pre_len
    call    write_stderr
    mov     rdi, rbx
    call    strlen
    mov     edx, eax
    mov     rdi, rbx
    call    write_stderr
    lea     rdi, [str_invalid_width_suf]
    mov     edx, str_invalid_width_suf_len
    call    write_stderr
    pop     rbx
    ret

; ============================================================================
;  open_and_process(rsi = filename)
; ============================================================================
; ─── try_mmap_or_read(edi=fd) ──────────────────────────────
; Try mmap on fd (works for stdin redirected from file).
; Falls back to read() for pipes/sockets.
try_mmap_or_read:
    push    r14
    push    r15
    mov     r14d, edi

    sub     rsp, STAT_SIZE
    mov     edi, r14d
    mov     rsi, rsp
    mov     rax, SYS_FSTAT
    syscall
    test    rax, rax
    js      .tmor_fstat_fail

    mov     r15, [rsp + ST_SIZE_OFF]
    add     rsp, STAT_SIZE

    test    r15, r15
    jle     .tmor_read

    xor     edi, edi
    mov     rsi, r15
    mov     edx, PROT_READ
    mov     r10d, MAP_PRIVATE | MAP_POPULATE
    mov     r8d, r14d
    xor     r9d, r9d
    mov     rax, SYS_MMAP
    syscall
    cmp     rax, -4096
    ja      .tmor_read

    mov     [mmap_addr], rax
    mov     [mmap_len], r15

    mov     rdi, rax
    mov     rsi, r15
    mov     edx, MADV_SEQUENTIAL
    mov     rax, SYS_MADVISE
    syscall

    mov     rdi, [mmap_addr]
    mov     rsi, [mmap_len]
    mov     edx, MADV_HUGEPAGE
    mov     rax, SYS_MADVISE
    syscall

    mov     rdi, [mmap_addr]
    mov     rsi, [mmap_len]
    call    process_mmap

    mov     rdi, [mmap_addr]
    mov     rsi, [mmap_len]
    mov     rax, SYS_MUNMAP
    syscall

    pop     r15
    pop     r14
    ret

.tmor_fstat_fail:
    add     rsp, STAT_SIZE
.tmor_read:
    mov     edi, r14d
    call    process_fd
    pop     r15
    pop     r14
    ret

open_and_process:
    push    rbx
    push    r14
    push    r15
    mov     rbx, rsi

    mov     rdi, rsi
    xor     esi, esi
    xor     edx, edx
    mov     rax, SYS_OPEN
    syscall
    test    rax, rax
    js      .oap_error

    mov     r14d, eax

    sub     rsp, STAT_SIZE
    mov     rdi, r14
    mov     rsi, rsp
    mov     rax, SYS_FSTAT
    syscall
    test    rax, rax
    js      .oap_fstat_fail

    mov     r15, [rsp + STAT_ST_SIZE]
    add     rsp, STAT_SIZE

    test    r15, r15
    jz      .oap_try_read

    xor     edi, edi
    mov     rsi, r15
    mov     edx, PROT_READ
    mov     r10d, MAP_PRIVATE | MAP_POPULATE
    mov     r8d, r14d
    xor     r9d, r9d
    mov     rax, SYS_MMAP
    syscall
    cmp     rax, -4096
    ja      .oap_try_read

    mov     [mmap_addr], rax
    mov     [mmap_len], r15

    mov     rdi, rax
    mov     rsi, r15
    mov     edx, MADV_SEQUENTIAL
    mov     rax, SYS_MADVISE
    syscall

    mov     rdi, [mmap_addr]
    mov     rsi, [mmap_len]
    mov     edx, MADV_HUGEPAGE
    mov     rax, SYS_MADVISE
    syscall

    mov     rdi, [mmap_addr]
    mov     rsi, [mmap_len]
    call    process_mmap

    mov     rdi, [mmap_addr]
    mov     rsi, [mmap_len]
    mov     rax, SYS_MUNMAP
    syscall

    mov     rdi, r14
    mov     rax, SYS_CLOSE
    syscall

    pop     r15
    pop     r14
    pop     rbx
    ret

.oap_fstat_fail:
    add     rsp, STAT_SIZE
.oap_try_read:
    mov     edi, r14d
    call    process_fd
    mov     rdi, r14
    mov     rax, SYS_CLOSE
    syscall
    pop     r15
    pop     r14
    pop     rbx
    ret

.oap_error:
    neg     rax
    mov     edi, eax
    mov     rsi, rbx
    call    err_open_file
    mov     ebp, 1
    pop     r15
    pop     r14
    pop     rbx
    ret

; ============================================================================
;  find_special_sse2(rbx=start, r13=end) -> rax = offset to first special char
;  or (end-start) if none found.
;  Special chars: bytes < 0x0E (covers \b=8, \t=9, \n=10, \r=13)
;  Preserves: rbx, r13, r14, r15, r12, rbp
;  Clobbers: rax, rcx, rdx, rsi, rdi, xmm0, xmm1, xmm2
; ============================================================================
find_special_sse2:
    mov     rsi, rbx                    ; current scan position
    mov     rcx, r13                    ; end

    ; Process 16 bytes at a time
.fs_simd_loop:
    mov     rax, rcx
    sub     rax, rsi
    cmp     rax, 16
    jl      .fs_tail

    movdqu  xmm0, [rsi]
    movdqa  xmm1, xmm0
    psubusb xmm1, xmm6                 ; 0 where byte < 0x0E
    pxor    xmm2, xmm2
    pcmpeqb xmm1, xmm2                 ; 0xFF where special
    pmovmskb eax, xmm1
    test    eax, eax
    jnz     .fs_found

    add     rsi, 16
    jmp     .fs_simd_loop

.fs_tail:
    ; Check remaining bytes one at a time
    cmp     rsi, rcx
    jge     .fs_not_found
    movzx   eax, byte [rsi]
    cmp     al, 0x0E
    jl      .fs_found_tail
    inc     rsi
    jmp     .fs_tail

.fs_found:
    bsf     eax, eax
    add     rsi, rax
.fs_found_tail:
    mov     rax, rsi
    sub     rax, rbx
    ret

.fs_not_found:
    mov     rax, r13
    sub     rax, rbx
    ret

; ============================================================================
;  find_newline_sse2(rbx=start, r13=end) -> rax = offset to first newline
;  or (end-start) if none found.
;  Preserves: rbx, r13, r14, r15, r12, rbp
; ============================================================================
find_newline_sse2:
    mov     rsi, rbx
    mov     rcx, r13

.fn_simd_loop:
    mov     rax, rcx
    sub     rax, rsi
    cmp     rax, 16
    jl      .fn_tail

    movdqu  xmm0, [rsi]
    movdqa  xmm1, xmm0
    pcmpeqb xmm1, xmm7                 ; xmm7 = all 0x0A
    pmovmskb eax, xmm1
    test    eax, eax
    jnz     .fn_found

    add     rsi, 16
    jmp     .fn_simd_loop

.fn_tail:
    cmp     rsi, rcx
    jge     .fn_not_found
    cmp     byte [rsi], 10
    je      .fn_found_tail
    inc     rsi
    jmp     .fn_tail

.fn_found:
    bsf     eax, eax
    add     rsi, rax
.fn_found_tail:
    mov     rax, rsi
    sub     rax, rbx
    ret

.fn_not_found:
    mov     rax, r13
    sub     rax, rbx
    ret

; ============================================================================
;  bulk_copy_to_output(src=rsi_arg, count=rdx_arg)
;  Copies count bytes from [rbx + offset] to out_buf using rep movsb.
;  Uses: rsi (src), rdi (dst), rcx (count). Callee should set up.
; ============================================================================

; ============================================================================
;  process_mmap(rdi = data_ptr, rsi = data_len)
;
;  Register allocation (callee-saved to survive flush calls):
;    rbx = current input pointer
;    r13 = input end pointer (non -s modes) or stored in [input_end] for -s modes
;    r14 = column/byte count
;    r15 = last_blank_out_pos (-1 = none) for -s
;    r12 = out_pos (global)
;    ebp = had_error (global)
; ============================================================================
process_mmap:
    push    rbx
    push    r13
    push    r14
    push    r15

    mov     rbx, rdi
    lea     r13, [rdi + rsi]

    xor     r14d, r14d
    mov     r15, -1

    cmp     byte [flag_bytes], 0
    jne     .pm_byte_dispatch
    cmp     byte [flag_spaces], 0
    jne     .pm_col_spaces_setup

    ; ── Column mode, no -s: LINE-ORIENTED APPROACH ──
    ; Strategy: scan for special chars with SIMD, bulk copy normal runs,
    ; insert fold newlines every WIDTH bytes.
    jmp     .pm_col_fast

.pm_byte_dispatch:
    cmp     byte [flag_spaces], 0
    jne     .pm_byte_spaces_setup
    jmp     .pm_byte_fast

; ============================================================================
;  Column mode fast path (no -s flag)
;
;  Two-level approach:
;  1. SIMD scan for specials (< 0x0E) in 16-byte chunks
;  2. When no specials found and col+16 <= width: bulk copy
;  3. When special found: copy bytes before it, handle special, continue
;  Uses xmm5 as permanent zero register.
; ============================================================================
.pm_col_fast:
    mov     r8d, [width]
    pxor    xmm5, xmm5                 ; permanent zero register

.pm_cf_loop:
    cmp     rbx, r13
    jge     .pm_done

    ; Flush output if needed
    cmp     r12, FLUSH_THRESHOLD
    jl      .pm_cf_no_flush
    push    r8
    call    flush_output_safe
    pop     r8
.pm_cf_no_flush:

    ; Check if we have 16 bytes remaining
    mov     rax, r13
    sub     rax, rbx
    cmp     rax, 16
    jl      .pm_cf_scalar_tail

    ; SIMD: load 16 bytes, check for specials (bytes < 0x0E)
    movdqu  xmm0, [rbx]
    movdqa  xmm1, xmm0
    psubusb xmm1, xmm6                 ; 0 where byte < 0x0E
    pcmpeqb xmm1, xmm5                 ; 0xFF where special
    pmovmskb eax, xmm1
    test    eax, eax
    jnz     .pm_cf_has_special

    ; No specials in 16 bytes. Check if col+16 <= width
    lea     ecx, [r14d + 16]
    cmp     ecx, r8d
    jg      .pm_cf_partial_width

    ; Fast path: bulk copy 16 bytes, advance col by 16
    movdqu  [out_buf + r12], xmm0
    add     r12, 16
    add     rbx, 16
    mov     r14d, ecx

    ; Tight inner loop: process 16 bytes/iteration
    ; No flush check needed: at most ~width bytes before a newline/special
    ; triggers exit. width << FLUSH_THRESHOLD headroom.
.pm_cf_inner:
    mov     rax, r13
    sub     rax, rbx
    cmp     rax, 16
    jl      .pm_cf_loop
    lea     ecx, [r14d + 16]
    cmp     ecx, r8d
    jg      .pm_cf_loop

    movdqu  xmm0, [rbx]
    movdqa  xmm1, xmm0
    psubusb xmm1, xmm6
    pcmpeqb xmm1, xmm5
    pmovmskb eax, xmm1
    test    eax, eax
    jnz     .pm_cf_loop
    movdqu  [out_buf + r12], xmm0
    add     r12, 16
    add     rbx, 16
    mov     r14d, ecx
    jmp     .pm_cf_inner

.pm_cf_partial_width:
    ; col + 16 > width, but no specials. Copy min(width-col, 16) then fold.
    mov     ecx, r8d
    sub     ecx, r14d                   ; available = width - col
    test    ecx, ecx
    jle     .pm_cf_need_fold

    ; Copy ecx bytes (< 16)
    ; Use overlapping 8-byte copies for speed
    cmp     ecx, 8
    jl      .pm_cf_pw_small
    mov     rax, [rbx]
    mov     [out_buf + r12], rax
    mov     rax, [rbx + rcx - 8]
    lea     rdx, [out_buf + r12]
    mov     [rdx + rcx - 8], rax
    jmp     .pm_cf_pw_done
.pm_cf_pw_small:
    cmp     ecx, 4
    jl      .pm_cf_pw_tiny
    mov     eax, [rbx]
    mov     [out_buf + r12], eax
    mov     eax, [rbx + rcx - 4]
    lea     rdx, [out_buf + r12]
    mov     [rdx + rcx - 4], eax
    jmp     .pm_cf_pw_done
.pm_cf_pw_tiny:
    ; 1-3 bytes
    movzx   eax, byte [rbx]
    mov     [out_buf + r12], al
    cmp     ecx, 1
    je      .pm_cf_pw_done
    movzx   eax, byte [rbx + 1]
    mov     [out_buf + r12 + 1], al
    cmp     ecx, 2
    je      .pm_cf_pw_done
    movzx   eax, byte [rbx + 2]
    mov     [out_buf + r12 + 2], al
.pm_cf_pw_done:
    add     r12, rcx
    add     rbx, rcx
    mov     r14d, r8d                   ; col = width
    ; Peek at next byte — if newline, let the newline handler deal with it
    ; (avoids double-newline when line length is exact multiple of width)
    cmp     rbx, r13
    jge     .pm_cf_pw_fold              ; at EOF, still need fold
    cmp     byte [rbx], 10
    je      .pm_cf_loop                 ; next is newline — skip fold
.pm_cf_pw_fold:
    mov     byte [out_buf + r12], 10
    inc     r12
    xor     r14d, r14d
    jmp     .pm_cf_loop

.pm_cf_has_special:
    ; eax = bitmask of specials in 16-byte chunk
    ; Find first special, copy normal bytes before it, then go scalar
    bsf     ecx, eax                    ; ecx = position of first special

    test    ecx, ecx
    jz      .pm_cf_scalar_at_special    ; first byte is special

    ; Copy ecx normal bytes (ecx < 16), clamped by width
    mov     edi, r8d
    sub     edi, r14d                   ; available = width - col
    cmp     ecx, edi
    jle     .pm_cf_hs_copy
    ; Would exceed width, copy what fits then fold
    test    edi, edi
    jle     .pm_cf_need_fold
    mov     ecx, edi

.pm_cf_hs_copy:
    ; Copy ecx bytes (1-15)
    add     r14d, ecx
    cmp     ecx, 8
    jl      .pm_cf_hsc_small
    mov     rax, [rbx]
    mov     [out_buf + r12], rax
    cmp     ecx, 8
    je      .pm_cf_hsc_done
    mov     rax, [rbx + rcx - 8]
    lea     rdx, [out_buf + r12]
    mov     [rdx + rcx - 8], rax
    jmp     .pm_cf_hsc_done
.pm_cf_hsc_small:
    cmp     ecx, 4
    jl      .pm_cf_hsc_tiny
    mov     eax, [rbx]
    mov     [out_buf + r12], eax
    cmp     ecx, 4
    je      .pm_cf_hsc_done
    mov     eax, [rbx + rcx - 4]
    lea     rdx, [out_buf + r12]
    mov     [rdx + rcx - 4], eax
    jmp     .pm_cf_hsc_done
.pm_cf_hsc_tiny:
    movzx   eax, byte [rbx]
    mov     [out_buf + r12], al
    cmp     ecx, 1
    je      .pm_cf_hsc_done
    movzx   eax, byte [rbx + 1]
    mov     [out_buf + r12 + 1], al
    cmp     ecx, 2
    je      .pm_cf_hsc_done
    movzx   eax, byte [rbx + 2]
    mov     [out_buf + r12 + 2], al
.pm_cf_hsc_done:
    add     r12, rcx
    add     rbx, rcx
    ; Check if we hit width
    cmp     r14d, r8d
    jl      .pm_cf_scalar_at_special
    ; At width boundary — but next byte is the special char at [rbx].
    ; If it's a newline, skip the fold (the newline handler emits it).
    cmp     rbx, r13
    jge     .pm_cf_hsc_fold             ; at EOF, still need fold
    cmp     byte [rbx], 10
    je      .pm_cf_scalar_at_special    ; next is newline — skip fold
.pm_cf_hsc_fold:
    mov     byte [out_buf + r12], 10
    inc     r12
    xor     r14d, r14d
    jmp     .pm_cf_loop

.pm_cf_scalar_at_special:
    ; Process special char at [rbx] scalarly
    cmp     rbx, r13
    jge     .pm_done
    movzx   eax, byte [rbx]

    cmp     al, 10
    je      .pm_cf_s_nl
    cmp     al, 9
    je      .pm_cf_s_tab
    cmp     al, 8
    je      .pm_cf_s_bs
    cmp     al, 13
    je      .pm_cf_s_cr

    ; Other control char
    lea     edx, [r14d + 1]
    cmp     edx, r8d
    jle     .pm_cf_s_ctrl_ok
    mov     byte [out_buf + r12], 10
    inc     r12
    xor     r14d, r14d
.pm_cf_s_ctrl_ok:
    inc     r14d
    mov     [out_buf + r12], al
    inc     r12
    inc     rbx
    jmp     .pm_cf_loop

.pm_cf_s_nl:
    mov     byte [out_buf + r12], 10
    inc     r12
    xor     r14d, r14d
    inc     rbx
    jmp     .pm_cf_loop

.pm_cf_s_bs:
    test    r14d, r14d
    jz      .pm_cf_s_bs_emit
    dec     r14d
.pm_cf_s_bs_emit:
    mov     byte [out_buf + r12], 8
    inc     r12
    inc     rbx
    jmp     .pm_cf_loop

.pm_cf_s_cr:
    xor     r14d, r14d
    mov     byte [out_buf + r12], 13
    inc     r12
    inc     rbx
    jmp     .pm_cf_loop

.pm_cf_s_tab:
    mov     eax, r14d
    add     eax, 8
    and     eax, ~7
    cmp     eax, r8d
    jle     .pm_cf_s_tab_nopf
    test    r14d, r14d
    jz      .pm_cf_s_tab_nopf
    mov     byte [out_buf + r12], 10
    inc     r12
    xor     r14d, r14d
    mov     eax, 8
.pm_cf_s_tab_nopf:
    mov     r14d, eax
    mov     byte [out_buf + r12], 9
    inc     r12
    cmp     r14d, r8d
    jle     .pm_cf_s_tab_done
    mov     byte [out_buf + r12], 10
    inc     r12
    xor     r14d, r14d
.pm_cf_s_tab_done:
    inc     rbx
    jmp     .pm_cf_loop

.pm_cf_need_fold:
    ; col >= width: insert fold newline (but skip if next byte is newline)
    cmp     rbx, r13
    jge     .pm_cf_nf_fold              ; at EOF, still need fold
    cmp     byte [rbx], 10
    je      .pm_cf_loop                 ; next is newline — skip fold
.pm_cf_nf_fold:
    mov     byte [out_buf + r12], 10
    inc     r12
    xor     r14d, r14d
    jmp     .pm_cf_loop

.pm_cf_scalar_tail:
    ; Less than 16 bytes remaining, process one at a time
    cmp     rbx, r13
    jge     .pm_done

    movzx   eax, byte [rbx]

    cmp     al, 10
    je      .pm_cf_s_nl
    cmp     al, 9
    je      .pm_cf_s_tab
    cmp     al, 8
    je      .pm_cf_s_bs
    cmp     al, 13
    je      .pm_cf_s_cr

    ; Regular char
    lea     edx, [r14d + 1]
    cmp     edx, r8d
    jle     .pm_cf_st_ok
    mov     byte [out_buf + r12], 10
    inc     r12
    xor     r14d, r14d
.pm_cf_st_ok:
    inc     r14d
    mov     [out_buf + r12], al
    inc     r12
    inc     rbx
    jmp     .pm_cf_scalar_tail

; ============================================================================
;  Column mode with -s flag
; ============================================================================
.pm_col_spaces_setup:
    mov     [input_end], r13
    xor     r13d, r13d                  ; blank_col = 0

.pm_cs_loop:
    cmp     rbx, [input_end]
    jge     .pm_done

    cmp     r12, FLUSH_THRESHOLD
    jl      .pm_cs_no_flush
    call    flush_output_safe
.pm_cs_no_flush:

    movzx   eax, byte [rbx]

    cmp     al, 10
    je      .pm_cs_newline
    cmp     al, 8
    je      .pm_cs_backspace
    cmp     al, 13
    je      .pm_cs_cr
    cmp     al, 9
    je      .pm_cs_tab

    lea     edx, [r14d + 1]
    cmp     edx, [width]
    jle     .pm_cs_regular_ok
    call    fold_line

.pm_cs_regular_ok:
    inc     r14d

    cmp     al, ' '
    jne     .pm_cs_regular_emit
    lea     rax, [r12 + 1]
    mov     r15, rax
    mov     r13d, r14d

.pm_cs_regular_emit:
    mov     [out_buf + r12], al
    inc     r12
    inc     rbx
    jmp     .pm_cs_loop

.pm_cs_newline:
    mov     byte [out_buf + r12], 10
    inc     r12
    xor     r14d, r14d
    mov     r15, -1
    inc     rbx
    jmp     .pm_cs_loop

.pm_cs_backspace:
    test    r14d, r14d
    jz      .pm_cs_bs_emit
    dec     r14d
.pm_cs_bs_emit:
    mov     byte [out_buf + r12], 8
    inc     r12
    inc     rbx
    jmp     .pm_cs_loop

.pm_cs_cr:
    xor     r14d, r14d
    mov     byte [out_buf + r12], 13
    inc     r12
    inc     rbx
    jmp     .pm_cs_loop

.pm_cs_tab:
    mov     eax, r14d
    add     eax, 8
    and     eax, ~7

    cmp     eax, [width]
    jle     .pm_cs_tab_no_prefold
    test    r14d, r14d
    jz      .pm_cs_tab_no_prefold

    mov     byte [out_buf + r12], 10
    inc     r12
    xor     r14d, r14d
    mov     r15, -1
    mov     eax, 8

.pm_cs_tab_no_prefold:
    mov     r14d, eax
    lea     rax, [r12 + 1]
    mov     r15, rax
    mov     r13d, r14d
    mov     byte [out_buf + r12], 9
    inc     r12

    mov     ecx, [width]
    cmp     r14d, ecx
    jle     .pm_cs_tab_done
    mov     byte [out_buf + r12], 10
    inc     r12
    xor     r14d, r14d
    mov     r15, -1

.pm_cs_tab_done:
    inc     rbx
    jmp     .pm_cs_loop

; ============================================================================
;  Byte mode fast path (no -s flag)
;  Single-pass SIMD: scan for newlines + copy + track byte count in one loop.
; ============================================================================
.pm_byte_fast:
    mov     r8d, [width]

.pm_bf_loop:
    cmp     rbx, r13
    jge     .pm_done

    ; Flush output if needed
    lea     rax, [r12 + 256]
    cmp     rax, OUT_BUF_SIZE
    jl      .pm_bf_no_flush
    push    r8
    call    flush_output_safe
    pop     r8
.pm_bf_no_flush:

    ; Check remaining bytes
    mov     rax, r13
    sub     rax, rbx
    cmp     rax, 16
    jl      .pm_bf_scalar_tail

    ; SIMD: scan for newlines
    movdqu  xmm0, [rbx]
    movdqa  xmm1, xmm0
    pcmpeqb xmm1, xmm7                 ; xmm7 = all 0x0A
    pmovmskb eax, xmm1
    test    eax, eax
    jnz     .pm_bf_has_newline

    ; No newlines in 16 bytes. Check byte count.
    lea     ecx, [r14d + 16]
    cmp     ecx, r8d
    jg      .pm_bf_partial

    ; Bulk copy 16 bytes
    movdqu  [out_buf + r12], xmm0
    add     r12, 16
    add     rbx, 16
    mov     r14d, ecx

    ; Tight inner loop
    mov     rax, r13
    sub     rax, rbx
    cmp     rax, 16
    jl      .pm_bf_loop
    lea     rax, [r12 + 256]
    cmp     rax, OUT_BUF_SIZE
    jge     .pm_bf_loop
    lea     ecx, [r14d + 16]
    cmp     ecx, r8d
    jg      .pm_bf_loop

    movdqu  xmm0, [rbx]
    movdqa  xmm1, xmm0
    pcmpeqb xmm1, xmm7
    pmovmskb eax, xmm1
    test    eax, eax
    jnz     .pm_bf_loop
    movdqu  [out_buf + r12], xmm0
    add     r12, 16
    add     rbx, 16
    mov     r14d, ecx
    jmp     .pm_bf_loop

.pm_bf_partial:
    ; Would exceed width. Copy what fits.
    mov     ecx, r8d
    sub     ecx, r14d
    test    ecx, ecx
    jle     .pm_bf_need_fold
    ; Copy ecx bytes
    cmp     ecx, 8
    jl      .pm_bf_p_small
    mov     rax, [rbx]
    mov     [out_buf + r12], rax
    cmp     ecx, 8
    je      .pm_bf_p_done
    mov     rax, [rbx + rcx - 8]
    lea     rdx, [out_buf + r12]
    mov     [rdx + rcx - 8], rax
    jmp     .pm_bf_p_done
.pm_bf_p_small:
    cmp     ecx, 4
    jl      .pm_bf_p_tiny
    mov     eax, [rbx]
    mov     [out_buf + r12], eax
    cmp     ecx, 4
    je      .pm_bf_p_done
    mov     eax, [rbx + rcx - 4]
    lea     rdx, [out_buf + r12]
    mov     [rdx + rcx - 4], eax
    jmp     .pm_bf_p_done
.pm_bf_p_tiny:
    movzx   eax, byte [rbx]
    mov     [out_buf + r12], al
    cmp     ecx, 1
    je      .pm_bf_p_done
    movzx   eax, byte [rbx + 1]
    mov     [out_buf + r12 + 1], al
    cmp     ecx, 2
    je      .pm_bf_p_done
    movzx   eax, byte [rbx + 2]
    mov     [out_buf + r12 + 2], al
.pm_bf_p_done:
    add     r12, rcx
    add     rbx, rcx
    mov     r14d, r8d
    ; Peek at next byte — skip fold if it's a newline
    cmp     rbx, r13
    jge     .pm_bf_p_fold
    cmp     byte [rbx], 10
    je      .pm_bf_loop                 ; next is newline — skip fold
.pm_bf_p_fold:
    mov     byte [out_buf + r12], 10
    inc     r12
    xor     r14d, r14d
    jmp     .pm_bf_loop

.pm_bf_has_newline:
    ; Copy bytes before newline
    bsf     ecx, eax
    test    ecx, ecx
    jz      .pm_bf_at_newline

    ; Check byte count
    lea     edx, [r14d + ecx]
    cmp     edx, r8d
    jle     .pm_bf_copy_before_nl

    ; Would exceed width before newline
    mov     ecx, r8d
    sub     ecx, r14d
    test    ecx, ecx
    jle     .pm_bf_need_fold
    cmp     ecx, 8
    jl      .pm_bf_hn_small
    mov     rax, [rbx]
    mov     [out_buf + r12], rax
    jmp     .pm_bf_hn_done
.pm_bf_hn_small:
    cmp     ecx, 4
    jl      .pm_bf_hn_tiny
    mov     eax, [rbx]
    mov     [out_buf + r12], eax
    jmp     .pm_bf_hn_done
.pm_bf_hn_tiny:
    movzx   eax, byte [rbx]
    mov     [out_buf + r12], al
    cmp     ecx, 1
    je      .pm_bf_hn_done
    movzx   eax, byte [rbx + 1]
    mov     [out_buf + r12 + 1], al
    cmp     ecx, 2
    je      .pm_bf_hn_done
    movzx   eax, byte [rbx + 2]
    mov     [out_buf + r12 + 2], al
.pm_bf_hn_done:
    add     r12, rcx
    add     rbx, rcx
    mov     r14d, r8d
    ; Peek at next byte — skip fold if it's a newline
    cmp     rbx, r13
    jge     .pm_bf_hn_fold
    cmp     byte [rbx], 10
    je      .pm_bf_loop                 ; next is newline — skip fold
.pm_bf_hn_fold:
    mov     byte [out_buf + r12], 10
    inc     r12
    xor     r14d, r14d
    jmp     .pm_bf_loop

.pm_bf_copy_before_nl:
    ; Copy ecx bytes before newline
    cmp     ecx, 8
    jl      .pm_bf_cbn_small
    mov     rax, [rbx]
    mov     [out_buf + r12], rax
    cmp     ecx, 8
    je      .pm_bf_cbn_done
    mov     rax, [rbx + rcx - 8]
    lea     rdx, [out_buf + r12]
    mov     [rdx + rcx - 8], rax
    jmp     .pm_bf_cbn_done
.pm_bf_cbn_small:
    cmp     ecx, 4
    jl      .pm_bf_cbn_tiny
    mov     eax, [rbx]
    mov     [out_buf + r12], eax
    cmp     ecx, 4
    je      .pm_bf_cbn_done
    mov     eax, [rbx + rcx - 4]
    lea     rdx, [out_buf + r12]
    mov     [rdx + rcx - 4], eax
    jmp     .pm_bf_cbn_done
.pm_bf_cbn_tiny:
    movzx   eax, byte [rbx]
    mov     [out_buf + r12], al
    cmp     ecx, 1
    je      .pm_bf_cbn_done
    movzx   eax, byte [rbx + 1]
    mov     [out_buf + r12 + 1], al
    cmp     ecx, 2
    je      .pm_bf_cbn_done
    movzx   eax, byte [rbx + 2]
    mov     [out_buf + r12 + 2], al
.pm_bf_cbn_done:
    add     r12, rcx
    add     rbx, rcx
    add     r14d, ecx
    ; Fall through to newline

.pm_bf_at_newline:
    cmp     rbx, r13
    jge     .pm_done
    mov     byte [out_buf + r12], 10
    inc     r12
    xor     r14d, r14d
    inc     rbx
    jmp     .pm_bf_loop

.pm_bf_need_fold:
    ; Skip fold if next byte is a newline
    cmp     rbx, r13
    jge     .pm_bf_nf_fold
    cmp     byte [rbx], 10
    je      .pm_bf_loop                 ; next is newline — skip fold
.pm_bf_nf_fold:
    mov     byte [out_buf + r12], 10
    inc     r12
    xor     r14d, r14d
    jmp     .pm_bf_loop

.pm_bf_scalar_tail:
    cmp     rbx, r13
    jge     .pm_done

    movzx   eax, byte [rbx]
    cmp     al, 10
    je      .pm_bf_at_newline

    lea     edx, [r14d + 1]
    cmp     edx, r8d
    jle     .pm_bf_st_ok
    mov     byte [out_buf + r12], 10
    inc     r12
    xor     r14d, r14d
.pm_bf_st_ok:
    inc     r14d
    mov     [out_buf + r12], al
    inc     r12
    inc     rbx
    jmp     .pm_bf_scalar_tail

; ============================================================================
;  Byte mode with -s
; ============================================================================
.pm_byte_spaces_setup:
    mov     [input_end], r13
    xor     r13d, r13d

.pm_bs_loop:
    cmp     rbx, [input_end]
    jge     .pm_done

    cmp     r12, FLUSH_THRESHOLD
    jl      .pm_bs_no_flush
    call    flush_output_safe
.pm_bs_no_flush:

    movzx   eax, byte [rbx]

    cmp     al, 10
    je      .pm_bs_newline

    lea     edx, [r14d + 1]
    cmp     edx, [width]
    jle     .pm_bs_ok
    call    fold_line

.pm_bs_ok:
    inc     r14d

    cmp     al, ' '
    je      .pm_bs_mark_blank
    cmp     al, 9
    je      .pm_bs_mark_blank
    jmp     .pm_bs_emit

.pm_bs_mark_blank:
    lea     rax, [r12 + 1]
    mov     r15, rax
    mov     r13d, r14d

.pm_bs_emit:
    mov     [out_buf + r12], al
    inc     r12
    inc     rbx
    jmp     .pm_bs_loop

.pm_bs_newline:
    mov     byte [out_buf + r12], 10
    inc     r12
    xor     r14d, r14d
    mov     r15, -1
    inc     rbx
    jmp     .pm_bs_loop

; ── Common exit ──
.pm_done:
    pop     r15
    pop     r14
    pop     r13
    pop     rbx
    ret

; ============================================================================
;  process_fd(edi = fd) — read-based fallback (for stdin/pipes)
; ============================================================================
process_fd:
    push    rbx
    push    r14
    push    r15
    push    r13

    mov     ebx, edi
    xor     r14d, r14d
    mov     r15, -1
    xor     r13d, r13d

.pf_read_loop:
    mov     edi, ebx
    lea     rsi, [read_buf]
    mov     edx, READ_BUF_SIZE
    call    asm_read
    test    rax, rax
    js      .pf_read_error
    jz      .pf_done

    xor     r8d, r8d
    mov     r9, rax

    cmp     byte [flag_bytes], 0
    jne     .pf_byte_loop

.pf_col_loop:
    cmp     r8, r9
    jge     .pf_read_loop

    movzx   eax, byte [read_buf + r8]

    cmp     al, 10
    je      .pf_col_newline
    cmp     al, 8
    je      .pf_col_backspace
    cmp     al, 13
    je      .pf_col_cr
    cmp     al, 9
    je      .pf_col_tab

    lea     edx, [r14d + 1]
    mov     ecx, [width]
    cmp     edx, ecx
    jle     .pf_col_regular_ok
    call    fold_line

.pf_col_regular_ok:
    inc     r14d

    cmp     byte [flag_spaces], 0
    je      .pf_col_regular_emit
    cmp     byte [read_buf + r8], ' '
    jne     .pf_col_regular_emit
    lea     rax, [r12 + 1]
    mov     r15, rax
    mov     r13d, r14d

.pf_col_regular_emit:
    mov     al, [read_buf + r8]
    mov     [out_buf + r12], al
    inc     r12

    cmp     r12, FLUSH_THRESHOLD
    jl      .pf_col_next
    call    flush_output_safe
.pf_col_next:
    inc     r8
    jmp     .pf_col_loop

.pf_col_newline:
    mov     byte [out_buf + r12], 10
    inc     r12
    xor     r14d, r14d
    mov     r15, -1
    cmp     r12, FLUSH_THRESHOLD
    jl      .pf_col_nl_next
    call    flush_output_safe
.pf_col_nl_next:
    inc     r8
    jmp     .pf_col_loop

.pf_col_backspace:
    test    r14d, r14d
    jz      .pf_col_bs_emit
    dec     r14d
.pf_col_bs_emit:
    mov     byte [out_buf + r12], 8
    inc     r12
    cmp     r12, FLUSH_THRESHOLD
    jl      .pf_col_bs_next
    call    flush_output_safe
.pf_col_bs_next:
    inc     r8
    jmp     .pf_col_loop

.pf_col_cr:
    xor     r14d, r14d
    mov     byte [out_buf + r12], 13
    inc     r12
    cmp     r12, FLUSH_THRESHOLD
    jl      .pf_col_cr_next
    call    flush_output_safe
.pf_col_cr_next:
    inc     r8
    jmp     .pf_col_loop

.pf_col_tab:
    mov     eax, r14d
    add     eax, 8
    and     eax, ~7

    mov     ecx, [width]
    cmp     eax, ecx
    jle     .pf_col_tab_no_prefold
    test    r14d, r14d
    jz      .pf_col_tab_no_prefold

    mov     byte [out_buf + r12], 10
    inc     r12
    xor     r14d, r14d
    mov     r15, -1
    mov     eax, 8

.pf_col_tab_no_prefold:
    mov     r14d, eax

    cmp     byte [flag_spaces], 0
    je      .pf_col_tab_emit
    lea     rax, [r12 + 1]
    mov     r15, rax
    mov     r13d, r14d

.pf_col_tab_emit:
    mov     byte [out_buf + r12], 9
    inc     r12

    mov     ecx, [width]
    cmp     r14d, ecx
    jle     .pf_col_tab_no_fold
    mov     byte [out_buf + r12], 10
    inc     r12
    xor     r14d, r14d
    mov     r15, -1

.pf_col_tab_no_fold:
    cmp     r12, FLUSH_THRESHOLD
    jl      .pf_col_tab_next
    call    flush_output_safe
.pf_col_tab_next:
    inc     r8
    jmp     .pf_col_loop

.pf_byte_loop:
    cmp     r8, r9
    jge     .pf_read_loop

    movzx   eax, byte [read_buf + r8]

    cmp     al, 10
    je      .pf_byte_newline

    lea     edx, [r14d + 1]
    mov     ecx, [width]
    cmp     edx, ecx
    jle     .pf_byte_ok
    call    fold_line

.pf_byte_ok:
    inc     r14d

    cmp     byte [flag_spaces], 0
    je      .pf_byte_emit
    movzx   eax, byte [read_buf + r8]
    cmp     al, ' '
    je      .pf_byte_mark_blank
    cmp     al, 9
    je      .pf_byte_mark_blank
    jmp     .pf_byte_emit

.pf_byte_mark_blank:
    lea     rax, [r12 + 1]
    mov     r15, rax
    mov     r13d, r14d

.pf_byte_emit:
    mov     al, [read_buf + r8]
    mov     [out_buf + r12], al
    inc     r12
    cmp     r12, FLUSH_THRESHOLD
    jl      .pf_byte_next
    call    flush_output_safe
.pf_byte_next:
    inc     r8
    jmp     .pf_byte_loop

.pf_byte_newline:
    mov     byte [out_buf + r12], 10
    inc     r12
    xor     r14d, r14d
    mov     r15, -1
    cmp     r12, FLUSH_THRESHOLD
    jl      .pf_byte_nl_next
    call    flush_output_safe
.pf_byte_nl_next:
    inc     r8
    jmp     .pf_byte_loop

.pf_read_error:
    mov     ebp, 1
.pf_done:
    pop     r13
    pop     r15
    pop     r14
    pop     rbx
    ret

; ============================================================================
;  fold_line()
; ============================================================================
fold_line:
    cmp     byte [flag_spaces], 0
    je      .fl_hard
    cmp     r15, -1
    je      .fl_hard

    mov     rax, r12
    sub     rax, r15

    lea     rdx, [r12 + 1]
    cmp     rdx, OUT_BUF_SIZE
    jge     .fl_hard

    test    rax, rax
    jz      .fl_space_insert

    lea     rdi, [out_buf + r12]
    lea     rsi, [out_buf + r12 - 1]
    mov     rcx, rax
.fl_shift:
    mov     dl, [rsi]
    mov     [rdi], dl
    dec     rsi
    dec     rdi
    dec     rcx
    jnz     .fl_shift

.fl_space_insert:
    mov     byte [out_buf + r15], 10
    inc     r12
    sub     r14d, r13d
    mov     r15, -1
    ret

.fl_hard:
    mov     byte [out_buf + r12], 10
    inc     r12
    xor     r14d, r14d
    mov     r15, -1
    ret

; ============================================================================
;  flush_output_safe, flush_output
; ============================================================================
flush_output_safe:
    call    flush_output
    test    eax, eax
    jnz     .fos_error
    mov     r15, -1
    ret
.fos_error:
    mov     ebp, 1
    mov     r15, -1
    ret

flush_output:
    test    r12, r12
    jz      .fo_nothing
    mov     rdi, STDOUT
    lea     rsi, [out_buf]
    mov     rdx, r12
    call    asm_write_all
    xor     r12d, r12d
    ret
.fo_nothing:
    xor     eax, eax
    ret

; ============================================================================
;  String helpers
; ============================================================================
strcmp:
    movzx   eax, byte [rdi]
    movzx   ecx, byte [rsi]
    cmp     al, cl
    jne     .sc_ne
    test    al, al
    jz      .sc_eq
    inc     rdi
    inc     rsi
    jmp     strcmp
.sc_eq:
    xor     eax, eax
    ret
.sc_ne:
    mov     eax, 1
    ret

strncmp:
    test    ecx, ecx
    jz      .sn_eq
.sn_loop:
    movzx   eax, byte [rdi]
    movzx   edx, byte [rsi]
    cmp     al, dl
    jne     .sn_ne
    inc     rdi
    inc     rsi
    dec     ecx
    jnz     .sn_loop
.sn_eq:
    xor     eax, eax
    ret
.sn_ne:
    mov     eax, 1
    ret

strlen:
    xor     eax, eax
.sl_loop:
    cmp     byte [rdi + rax], 0
    je      .sl_done
    inc     rax
    jmp     .sl_loop
.sl_done:
    ret

; ============================================================================
;  Error output helpers
; ============================================================================
write_stderr:
    mov     rsi, rdi
    mov     rdi, STDERR
    mov     edx, edx
    call    asm_write_all
    ret

write_stderr_buf:
    mov     rsi, rdi
    mov     rdi, STDERR
    call    asm_write_all
    ret

print_error_msg:
    push    rbx
    mov     rbx, rdi
    lea     rdi, [str_prefix]
    mov     edx, str_prefix_len
    call    write_stderr
    mov     rdi, rbx
    call    strlen
    mov     rdx, rax
    mov     rdi, rbx
    call    write_stderr_buf
    lea     rdi, [str_newline]
    mov     edx, 1
    call    write_stderr
    pop     rbx
    ret

err_open_file:
    push    rbx
    push    r13
    mov     r13d, edi
    mov     rbx, rsi
    lea     rdi, [str_prefix]
    mov     edx, str_prefix_len
    call    write_stderr
    mov     rdi, rbx
    call    strlen
    mov     rdx, rax
    mov     rdi, rbx
    call    write_stderr_buf
    lea     rdi, [str_colon_space]
    mov     edx, 2
    call    write_stderr
    mov     edi, r13d
    call    strerror
    mov     rbx, rax
    mov     rdi, rax
    call    strlen
    mov     rdx, rax
    mov     rdi, rbx
    call    write_stderr_buf
    lea     rdi, [str_newline]
    mov     edx, 1
    call    write_stderr
    pop     r13
    pop     rbx
    ret

strerror:
    cmp     edi, 1
    je      .se_eperm
    cmp     edi, 2
    je      .se_enoent
    cmp     edi, 5
    je      .se_eio
    cmp     edi, 9
    je      .se_ebadf
    cmp     edi, 12
    je      .se_enomem
    cmp     edi, 13
    je      .se_eacces
    cmp     edi, 20
    je      .se_enotdir
    cmp     edi, 21
    je      .se_eisdir
    cmp     edi, 22
    je      .se_einval
    cmp     edi, 24
    je      .se_emfile
    cmp     edi, 36
    je      .se_enametoolong
    lea     rax, [str_eunknown]
    ret
.se_eperm:  lea rax, [str_eperm]
    ret
.se_enoent: lea rax, [str_enoent]
    ret
.se_eio:    lea rax, [str_eio]
    ret
.se_ebadf:  lea rax, [str_ebadf]
    ret
.se_enomem: lea rax, [str_enomem]
    ret
.se_eacces: lea rax, [str_eacces]
    ret
.se_enotdir: lea rax, [str_enotdir]
    ret
.se_eisdir: lea rax, [str_eisdir]
    ret
.se_einval: lea rax, [str_einval]
    ret
.se_emfile: lea rax, [str_emfile]
    ret
.se_enametoolong: lea rax, [str_enametoolong]
    ret

; ============================================================================
;  Data Section
; ============================================================================
section .data

str_prefix:             db "fold: "
str_prefix_len equ $ - str_prefix

str_newline:            db 10
str_colon_space:        db ": "

str_dashdash_help:      db "--help", 0
str_dashdash_version:   db "--version", 0
str_dashdash_bytes:     db "--bytes", 0
str_dashdash_spaces:    db "--spaces", 0
str_dashdash_width:     db "--width", 0
str_dashdash_width_eq:  db "--width=", 0

str_unrecognized:       db "fold: unrecognized option '", 0
str_unrecognized_len equ $ - str_unrecognized - 1

str_invalid_opt:        db "fold: invalid option -- '", 0
str_invalid_opt_len equ $ - str_invalid_opt - 1

str_quote_nl:           db "'", 10

str_try_help:           db "Try 'fold --help' for more information.", 10
str_try_help_len equ $ - str_try_help

str_w_requires_arg:     db "option requires an argument -- 'w'"
str_w_requires_arg_len equ $ - str_w_requires_arg

str_width_requires_arg: db "option '--width' requires an argument"
str_width_requires_arg_len equ $ - str_width_requires_arg

str_invalid_width_pre:  db "invalid number of columns: '", 0
str_invalid_width_pre_len equ $ - str_invalid_width_pre - 1

str_invalid_width_suf:  db "': Numerical result out of range", 10
str_invalid_width_suf_len equ $ - str_invalid_width_suf

str_write_error:        db "write error", 0

; @@DATA_START@@
help_text:
    db "Usage: fold [OPTION]... [FILE]...", 10
    db "Wrap input lines in each FILE, writing to standard output.", 10
    db 10
    db "With no FILE, or when FILE is -, read standard input.", 10
    db 10
    db "Mandatory arguments to long options are mandatory for short options too.", 10
    db "  -b, --bytes         count bytes rather than columns", 10
    db "  -s, --spaces        break at spaces", 10
    db "  -w, --width=WIDTH   use WIDTH columns instead of 80", 10
    db "      --help        display this help and exit", 10
    db "      --version     output version information and exit", 10
    db 10
    db "GNU coreutils online help: <https://www.gnu.org/software/coreutils/>", 10
    db "Full documentation <https://www.gnu.org/software/coreutils/fold>", 10
    db "or available locally via: info '(coreutils) fold invocation'", 10
help_text_len equ $ - help_text

version_text:
    db "fold (GNU coreutils) 9.7", 10
    db "Copyright (C) 2025 Free Software Foundation, Inc.", 10
    db "License GPLv3+: GNU GPL version 3 or later <https://gnu.org/licenses/gpl.html>.", 10
    db "This is free software: you are free to change and redistribute it.", 10
    db "There is NO WARRANTY, to the extent permitted by law.", 10
    db 10
    db "Written by David MacKenzie.", 10
version_text_len equ $ - version_text
; @@DATA_END@@

str_eperm:          db "Operation not permitted", 0
str_enoent:         db "No such file or directory", 0
str_eio:            db "Input/output error", 0
str_ebadf:          db "Bad file descriptor", 0
str_enomem:         db "Cannot allocate memory", 0
str_eacces:         db "Permission denied", 0
str_enotdir:        db "Not a directory", 0
str_eisdir:         db "Is a directory", 0
str_einval:         db "Invalid argument", 0
str_emfile:         db "Too many open files", 0
str_enametoolong:   db "File name too long", 0
str_eunknown:       db "Unknown error", 0

; ============================================================================
;  BSS Section
; ============================================================================
section .bss

width:              resd 1
argc_rem:           resd 1
flag_bytes:         resb 1
flag_spaces:        resb 1
past_dashdash:      resb 1
opt_char_buf:       resb 2

num_files:          resd 1
files:              resq MAX_FILES

mmap_addr:          resq 1
mmap_len:           resq 1
input_end:          resq 1

alignb 16
read_buf:           resb READ_BUF_SIZE
out_buf:            resb OUT_BUF_SIZE

section .note.GNU-stack noalloc noexec nowrite progbits
