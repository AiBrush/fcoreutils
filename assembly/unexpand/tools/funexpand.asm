; funexpand.asm — GNU-compatible "unexpand" in x86-64 Linux assembly
;
; Converts sequences of spaces to tabs, writing to standard output.
; Faithfully replicates the GNU coreutils unexpand algorithm.
; SIMD-optimized: SSE2 scanning, range check (byte <= 0x20) for specials.
;
; Global register conventions:
;   r12  = out_pos (bytes in output buffer)
;   ebp  = had_error flag (0=ok, 1=error)
;
; Build (modular):
;   nasm -f elf64 -I include/ tools/funexpand.asm -o build/funexpand.o
;   nasm -f elf64 -I include/ lib/io.asm -o build/io.o
;   ld --gc-sections -n build/funexpand.o build/io.o -o funexpand

%include "include/linux.inc"
%include "include/macros.inc"

default rel

extern asm_write_all
extern asm_read
extern asm_open
extern asm_close

; ─── Constants ────────────────────────────────────────────
%define READ_BUF_SIZE   131072
%define OUT_BUF_SIZE    1048576
%define FLUSH_THRESHOLD 524288
%define MAX_TAB_STOPS   256
%define MAX_FILES       256
%define PENDING_SIZE    65536

global _start

section .text

; ═══════════════════════════════════════════════════════════
;  Entry Point
; ═══════════════════════════════════════════════════════════
_start:
    BLOCK_SIGPIPE

    mov     ecx, [rsp]              ; argc
    lea     r14, [rsp + 8]          ; &argv[0]

    ; Initialize global state
    xor     ebp, ebp                ; had_error = 0
    xor     r12d, r12d              ; out_pos = 0
    mov     byte [convert_entire_line], 0
    mov     byte [first_only], 0
    mov     dword [num_tab_stops], 0
    mov     dword [default_tab], 8
    mov     dword [num_files], 0
    mov     byte [tab_list_mode], 0

    lea     rbx, [r14 + 8]          ; &argv[1]
    dec     ecx

    xor     edx, edx                ; past_dashdash = 0

.parse_loop:
    test    ecx, ecx
    jle     .parse_done
    mov     rsi, [rbx]
    test    rsi, rsi
    jz      .parse_done

    test    edx, edx
    jnz     .add_file_arg

    cmp     byte [rsi], '-'
    jne     .add_file_arg
    cmp     byte [rsi + 1], 0
    je      .add_stdin_arg

    cmp     byte [rsi + 1], '-'
    je      .long_or_dashdash

    ; Short options
    inc     rsi
.short_loop:
    movzx   eax, byte [rsi]
    test    al, al
    jz      .next_arg

    cmp     al, 'a'
    je      .short_a
    cmp     al, 't'
    je      .short_t

    ; Unknown
    push    rdx
    push    rcx
    push    rbx
    mov     rdi, rsi
    call    err_invalid_option
    pop     rbx
    pop     rcx
    pop     rdx
    mov     rdi, 1
    EXIT    rdi

.short_a:
    mov     byte [convert_entire_line], 1
    inc     rsi
    jmp     .short_loop

.short_t:
    inc     rsi
    movzx   eax, byte [rsi]
    test    al, al
    jnz     .do_parse_tabspec
    dec     ecx
    add     rbx, 8
    test    ecx, ecx
    jle     .err_missing_tabarg
    mov     rsi, [rbx]
    jmp     .do_parse_tabspec

.long_or_dashdash:
    cmp     byte [rsi + 2], 0
    je      .set_dashdash

    push    rdx
    push    rcx
    push    rbx
    lea     rdi, [str_opt_help]
    call    strcmp
    pop     rbx
    pop     rcx
    pop     rdx
    test    eax, eax
    jz      .do_help

    mov     rsi, [rbx]
    push    rdx
    push    rcx
    push    rbx
    lea     rdi, [str_opt_version]
    call    strcmp
    pop     rbx
    pop     rcx
    pop     rdx
    test    eax, eax
    jz      .do_version

    mov     rsi, [rbx]
    push    rdx
    push    rcx
    push    rbx
    lea     rdi, [str_opt_all]
    call    strcmp
    pop     rbx
    pop     rcx
    pop     rdx
    test    eax, eax
    jz      .set_all_long

    mov     rsi, [rbx]
    push    rdx
    push    rcx
    push    rbx
    lea     rdi, [str_opt_firstonly]
    call    strcmp
    pop     rbx
    pop     rcx
    pop     rdx
    test    eax, eax
    jz      .set_firstonly

    mov     rsi, [rbx]
    push    rdx
    push    rcx
    push    rbx
    lea     rdi, [str_opt_tabs_eq]
    mov     ecx, 7
    call    strncmp
    pop     rbx
    pop     rcx
    pop     rdx
    test    eax, eax
    jz      .long_tabs

    mov     rsi, [rbx]
    push    rdx
    push    rcx
    push    rbx
    call    err_unrecognized_option
    pop     rbx
    pop     rcx
    pop     rdx
    mov     rdi, 1
    EXIT    rdi

.set_all_long:
    mov     byte [convert_entire_line], 1
    jmp     .next_arg
.set_firstonly:
    mov     byte [first_only], 1
    jmp     .next_arg
.long_tabs:
    mov     rsi, [rbx]
    add     rsi, 7
    jmp     .do_parse_tabspec
.set_dashdash:
    mov     edx, 1
    jmp     .next_arg
.add_stdin_arg:
    mov     eax, [num_files]
    cmp     eax, MAX_FILES
    jge     .next_arg
    lea     rdi, [file_list]
    mov     qword [rdi + rax*8], 0
    inc     eax
    mov     [num_files], eax
    jmp     .next_arg
.add_file_arg:
    mov     eax, [num_files]
    cmp     eax, MAX_FILES
    jge     .next_arg
    lea     rdi, [file_list]
    mov     r8, [rbx]
    mov     [rdi + rax*8], r8
    inc     eax
    mov     [num_files], eax
    jmp     .next_arg
.next_arg:
    add     rbx, 8
    dec     ecx
    jmp     .parse_loop
.err_missing_tabarg:
    lea     rdi, [str_tab_missing]
    call    print_error_msg
    mov     rdi, 1
    EXIT    rdi

; ─── Parse tab spec ───────────────────────────────────────
.do_parse_tabspec:
    push    rdx
    push    rcx
    push    rbx
    mov     byte [convert_entire_line], 1

    mov     rdi, rsi
    call    has_comma
    test    eax, eax
    jnz     .parse_tab_list

    cmp     byte [rsi], '/'
    je      .tab_skip_prefix
    cmp     byte [rsi], '+'
    je      .tab_skip_prefix
    jmp     .tab_parse_single
.tab_skip_prefix:
    inc     rsi
.tab_parse_single:
    call    parse_number
    test    eax, eax
    jle     .bad_tab_num
    mov     [default_tab], eax
    mov     byte [tab_list_mode], 0
    pop     rbx
    pop     rcx
    pop     rdx
    jmp     .next_arg
.bad_tab_num:
    pop     rbx
    pop     rcx
    pop     rdx
    lea     rdi, [str_tab_invalid]
    call    print_error_msg
    mov     rdi, 1
    EXIT    rdi
.parse_tab_list:
    mov     byte [tab_list_mode], 1
    mov     dword [num_tab_stops], 0
.tab_list_loop:
    cmp     byte [rsi], '/'
    je      .tab_list_skip_pfx
    cmp     byte [rsi], '+'
    je      .tab_list_skip_pfx
    jmp     .tab_list_parse_num
.tab_list_skip_pfx:
    inc     rsi
.tab_list_parse_num:
    call    parse_number
    test    eax, eax
    jl      .bad_tab_num
    mov     edi, [num_tab_stops]
    cmp     edi, MAX_TAB_STOPS
    jge     .tab_list_next_comma
    lea     r8, [tab_stops]
    mov     [r8 + rdi*4], eax
    inc     edi
    mov     [num_tab_stops], edi
.tab_list_next_comma:
    cmp     byte [rsi], ','
    jne     .tab_list_done
    inc     rsi
    jmp     .tab_list_loop
.tab_list_done:
    pop     rbx
    pop     rcx
    pop     rdx
    jmp     .next_arg

; ─── Done parsing ─────────────────────────────────────────
.parse_done:
    cmp     byte [first_only], 1
    jne     .check_files
    mov     byte [convert_entire_line], 0
.check_files:
    ; Precompute pow2 tab optimization
    mov     byte [tab_is_pow2], 0
    mov     dword [tab_pow2_mask], 0
    cmp     byte [tab_list_mode], 0
    jne     .check_files_go
    mov     eax, [default_tab]
    test    eax, eax
    jz      .check_files_go
    mov     ecx, eax
    dec     ecx
    test    eax, ecx
    jnz     .check_files_go
    mov     byte [tab_is_pow2], 1
    mov     [tab_pow2_mask], ecx
.check_files_go:
    cmp     dword [num_files], 0
    jne     .process_files
    mov     edi, STDIN
    call    try_mmap_or_read
    jmp     .final_flush
.process_files:
    xor     ebx, ebx
.file_loop:
    cmp     ebx, [num_files]
    jge     .final_flush
    lea     rdi, [file_list]
    mov     rsi, [rdi + rbx*8]
    test    rsi, rsi
    jz      .file_stdin
    push    rbx
    call    open_and_process
    pop     rbx
    jmp     .file_next
.file_stdin:
    push    rbx
    mov     edi, STDIN
    call    try_mmap_or_read
    pop     rbx
.file_next:
    inc     ebx
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

; ─── Help & Version ───────────────────────────────────────
.do_help:
    call    flush_output
    mov     rdi, STDOUT
    lea     rsi, [help_text]
    mov     rdx, help_text_len
    call    asm_write_all
    xor     edi, edi
    EXIT    rdi
.do_version:
    call    flush_output
    mov     rdi, STDOUT
    lea     rsi, [version_text]
    mov     rdx, version_text_len
    call    asm_write_all
    xor     edi, edi
    EXIT    rdi

; ═══════════════════════════════════════════════════════════
;  open_and_process(rsi=filename)
; ═══════════════════════════════════════════════════════════
;  try_mmap_or_read(edi=fd)
;  Try mmap on fd (works for regular files and stdin redirects).
;  Falls back to read() for pipes/sockets.
; ═══════════════════════════════════════════════════════════
try_mmap_or_read:
    push    r14
    push    r15
    mov     r14d, edi

    sub     rsp, STAT_STRUCT_SIZE
    mov     edi, r14d
    mov     rsi, rsp
    mov     rax, SYS_FSTAT
    syscall
    test    rax, rax
    js      .tmor_fstat_fail

    mov     r15, [rsp + STAT_SIZE]
    add     rsp, STAT_STRUCT_SIZE

    test    r15, r15
    jle     .tmor_read

    ; mmap
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

    push    rax
    push    r15

    mov     rdi, rax
    mov     rsi, r15
    mov     edx, MADV_SEQUENTIAL
    mov     rax, SYS_MADVISE
    syscall

    pop     r15
    pop     rax
    push    rax
    push    r15
    mov     rdi, rax
    mov     rsi, r15
    mov     edx, MADV_HUGEPAGE
    mov     rax, SYS_MADVISE
    syscall

    pop     r15
    pop     rax
    push    rax

    mov     rdi, rax
    mov     rsi, r15
    call    process_buffer
    pop     rdi

    mov     rsi, r15
    mov     rax, SYS_MUNMAP
    syscall

    pop     r15
    pop     r14
    ret

.tmor_fstat_fail:
    add     rsp, STAT_STRUCT_SIZE
.tmor_read:
    mov     edi, r14d
    call    process_fd
    pop     r15
    pop     r14
    ret

; ═══════════════════════════════════════════════════════════
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
    mov     r14, rax

    sub     rsp, STAT_STRUCT_SIZE
    mov     rdi, r14
    mov     rsi, rsp
    mov     rax, SYS_FSTAT
    syscall
    mov     r15, [rsp + STAT_SIZE]
    add     rsp, STAT_STRUCT_SIZE
    test    rax, rax
    js      .oap_read_fallback

    test    r15, r15
    jle     .oap_read_fallback

    xor     edi, edi
    mov     rsi, r15
    mov     edx, PROT_READ
    mov     r10d, MAP_PRIVATE | MAP_POPULATE
    mov     r8, r14
    xor     r9d, r9d
    mov     rax, SYS_MMAP
    syscall
    cmp     rax, -4096
    ja      .oap_read_fallback

    push    rax
    push    r15

    ; madvise(addr, len, MADV_SEQUENTIAL)
    mov     rdi, rax
    mov     rsi, r15
    mov     edx, MADV_SEQUENTIAL
    mov     rax, SYS_MADVISE
    syscall

    ; madvise(addr, len, MADV_HUGEPAGE)
    pop     r15
    pop     rax
    push    rax
    push    r15
    mov     rdi, rax
    mov     rsi, r15
    mov     edx, MADV_HUGEPAGE
    mov     rax, SYS_MADVISE
    syscall

    pop     r15
    pop     rax
    push    rax

    mov     rdi, rax
    mov     rsi, r15
    call    process_buffer
    pop     rdi

    mov     rsi, r15
    mov     rax, SYS_MUNMAP
    syscall

    mov     rdi, r14
    mov     rax, SYS_CLOSE
    syscall
    pop     r15
    pop     r14
    pop     rbx
    ret

.oap_read_fallback:
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
    mov     rdi, rbx
    mov     esi, eax
    call    err_file
    mov     ebp, 1
    pop     r15
    pop     r14
    pop     rbx
    ret

; ═══════════════════════════════════════════════════════════
;  process_fd(edi=fd) — streaming
; ═══════════════════════════════════════════════════════════
process_fd:
    push    rbx
    push    r13
    mov     ebx, edi
    call    init_line_state
.pf_read:
    mov     edi, ebx
    lea     rsi, [read_buf]
    mov     edx, READ_BUF_SIZE
    call    asm_read
    test    rax, rax
    js      .pf_error
    jz      .pf_eof
    lea     rdi, [read_buf]
    mov     rsi, rax
    call    unexpand_core
    jmp     .pf_read
.pf_eof:
    call    flush_pending_blanks
    pop     r13
    pop     rbx
    ret
.pf_error:
    call    flush_pending_blanks
    mov     ebp, 1
    pop     r13
    pop     rbx
    ret

; ═══════════════════════════════════════════════════════════
;  process_buffer(rdi=data, rsi=len)
; ═══════════════════════════════════════════════════════════
process_buffer:
    push    rbx
    push    r13
    call    init_line_state
    call    unexpand_core
    call    flush_pending_blanks
    pop     r13
    pop     rbx
    ret

; ═══════════════════════════════════════════════════════════
;  init_line_state
; ═══════════════════════════════════════════════════════════
init_line_state:
    mov     byte [st_convert], 1
    mov     dword [st_column], 0
    mov     dword [st_next_tab_col], 0
    mov     dword [st_tab_index], 0
    mov     byte [st_one_blank_before], 0
    mov     byte [st_prev_blank], 1
    mov     dword [st_pending], 0
    ret

; ═══════════════════════════════════════════════════════════
;  unexpand_core(rdi=data, rsi=len)
;
;  Three execution modes:
;  1. Verbatim (not converting): SSE2 bulk copy, only scan for newline
;  2. Convert SIMD: check for bytes <= 0x20 (one comparison catches all specials)
;  3. Scalar: byte-by-byte GNU algorithm for spaces/tabs/specials
;
;  Key SIMD trick: all special bytes (0x08=BS, 0x09=TAB, 0x0A=NL, 0x20=SPACE)
;  are <= 0x20, and all printable ASCII is > 0x20. We use pminub + pcmpeqb
;  against 0x20 to detect "any byte <= 0x20" in a single comparison.
; ═══════════════════════════════════════════════════════════
unexpand_core:
    push    rbx
    push    r14
    push    r15
    push    r13

    mov     rbx, rdi                ; data ptr
    mov     r13, rsi                ; remaining
    lea     r15, [out_buf]          ; cache base
    mov     r14d, [st_column]       ; cache column in register

    ; Load SIMD constants into registers (avoid memory loads in hot loop)
    movdqa  xmm6, [simd_space]     ; 0x20 x16 for range check
    movdqa  xmm7, [simd_nl]        ; 0x0a x16 for verbatim path
    pxor    xmm5, xmm5             ; permanent zero register

; Re-entry from scalar paths — reload cached column from memory first
.uc_loop_scalar:
    mov     r14d, [st_column]
.uc_loop:
    test    r13, r13
    jle     .uc_done

    cmp     byte [st_convert], 0
    je      .uc_verbatim

    ; ── Convert mode: SIMD scan for specials (any byte <= 0x20) ──
    cmp     r13, 16
    jl      .uc_scalar_sync

    cmp     r12, FLUSH_THRESHOLD
    jl      .uc_simd_go
    mov     [st_column], r14d       ; sync column before flush
    call    flush_output_save
    lea     r15, [out_buf]

.uc_simd_go:
    mov     r14d, [st_column]       ; reload column (may have changed in scalar path)
    movdqu  xmm0, [rbx]
    ; Check for bytes <= 0x20 using saturating subtract
    movdqa  xmm1, xmm0
    psubusb xmm1, xmm6              ; x - 0x20, clamped to 0
    pcmpeqb xmm1, xmm5             ; == 0 means byte was <= 0x20
    pmovmskb eax, xmm1
    test    eax, eax
    jnz     .uc_simd_has_special

    ; No specials in 16 bytes — fast copy
    cmp     dword [st_pending], 0
    jne     .uc_simd_flush_pending

.uc_simd_copy16:
    ; Use xmm0 directly (already loaded)
    movdqu  [r15 + r12], xmm0
    add     r12, 16
    add     r14d, 16
    mov     byte [st_prev_blank], 0
    cmp     byte [convert_entire_line], 0
    jne     .uc_simd_advance
    mov     byte [st_convert], 0
.uc_simd_advance:
    add     rbx, 16
    sub     r13, 16

    ; Specialized tight inner loop for -a flag (convert_entire_line=1)
    ; Skips all state updates except column — only does load/check/copy
    cmp     byte [convert_entire_line], 0
    je      .uc_simd_advance_check_convert

    ; Ultra-fast inner loop: uses direct output pointer for speed
    ; r9 = direct output pointer = r15 + r12
    lea     r9, [r15 + r12]
.uc_fast_inner:
    cmp     r13, 16
    jl      .uc_fast_inner_exit
    lea     rax, [out_buf + FLUSH_THRESHOLD]
    cmp     r9, rax
    jge     .uc_fast_inner_exit

    movdqu  xmm0, [rbx]
    movdqa  xmm1, xmm0
    psubusb xmm1, xmm6
    pcmpeqb xmm1, xmm5
    pmovmskb eax, xmm1
    test    eax, eax
    jnz     .uc_fast_inner_exit         ; has special, sync and re-enter main

    movdqu  [r9], xmm0
    add     r9, 16
    add     r14d, 16
    add     rbx, 16
    sub     r13, 16
    jmp     .uc_fast_inner

.uc_fast_inner_exit:
    ; Sync r9 back to r12
    lea     rax, [out_buf]
    sub     r9, rax
    mov     r12, r9
    lea     r15, [out_buf]
    jmp     .uc_loop

.uc_simd_advance_check_convert:
    cmp     byte [st_convert], 0
    je      .uc_loop
    cmp     r13, 16
    jl      .uc_loop
    cmp     r12, FLUSH_THRESHOLD
    jge     .uc_loop

    movdqu  xmm0, [rbx]
    movdqa  xmm1, xmm0
    psubusb xmm1, xmm6
    pcmpeqb xmm1, xmm5
    pmovmskb eax, xmm1
    test    eax, eax
    jnz     .uc_loop
    jmp     .uc_simd_copy16

.uc_simd_flush_pending:
    mov     [st_column], r14d       ; sync column before function call
    push    rbx
    push    r13
    call    flush_pending_blanks
    pop     r13
    pop     rbx
    lea     r15, [out_buf]
    lea     rax, [r12 + 16]
    cmp     rax, FLUSH_THRESHOLD
    jl      .uc_simd_copy16
    call    flush_output_save
    lea     r15, [out_buf]
    jmp     .uc_simd_copy16

.uc_simd_has_special:
    ; Sync cached column to memory before potential scalar/flush operations
    mov     [st_column], r14d
    bsf     ecx, eax
    test    ecx, ecx
    jz      .uc_scalar_sync

    ; Copy ecx non-special bytes (ecx = 1..15)
    ; Fast path: skip pending check when no pending blanks (common case)
    cmp     dword [st_pending], 0
    jne     .uc_simd_partial_pending

.uc_simd_partial_nopend:
    ; Ensure output space
    lea     rax, [r12 + 16]             ; max 15 bytes + headroom
    cmp     rax, FLUSH_THRESHOLD
    jl      .uc_simd_partial_copy
    push    rcx
    call    flush_output_save
    pop     rcx
    lea     r15, [out_buf]
    jmp     .uc_simd_partial_copy

.uc_simd_partial_pending:
    push    rcx
    push    rbx
    push    r13
    call    flush_pending_blanks
    pop     r13
    pop     rbx
    pop     rcx
    lea     r15, [out_buf]
    jmp     .uc_simd_partial_nopend

.uc_simd_partial_copy:
    ; Fast copy ecx bytes (1-15) without rep movsb overhead
    lea     rdi, [r15 + r12]
    mov     edx, ecx
    cmp     ecx, 8
    jl      .uc_spc_small
    mov     rax, [rbx]
    mov     [rdi], rax
    cmp     ecx, 8
    je      .uc_spc_done
    mov     rax, [rbx + rcx - 8]
    mov     [rdi + rcx - 8], rax
    jmp     .uc_spc_done
.uc_spc_small:
    cmp     ecx, 4
    jl      .uc_spc_tiny
    mov     eax, [rbx]
    mov     [rdi], eax
    cmp     ecx, 4
    je      .uc_spc_done
    mov     eax, [rbx + rcx - 4]
    mov     [rdi + rcx - 4], eax
    jmp     .uc_spc_done
.uc_spc_tiny:
    movzx   eax, byte [rbx]
    mov     [rdi], al
    cmp     ecx, 1
    je      .uc_spc_done
    movzx   eax, byte [rbx + 1]
    mov     [rdi + 1], al
    cmp     ecx, 2
    je      .uc_spc_done
    movzx   eax, byte [rbx + 2]
    mov     [rdi + 2], al
.uc_spc_done:
    add     r12, rdx
    add     dword [st_column], edx
    mov     byte [st_prev_blank], 0
    cmp     byte [convert_entire_line], 0
    jne     .uc_simd_partial_adv
    mov     byte [st_convert], 0
.uc_simd_partial_adv:
    add     rbx, rdx
    sub     r13, rdx
    ; Next byte at [rbx] is the known special char — handle directly
    ; in scalar path, skipping SIMD re-scan (saves ~500k loads)
    test    r13, r13
    jle     .uc_done_from_partial
    jmp     .uc_scalar

.uc_done_from_partial:
    ; [st_column] is already up-to-date from the partial copy path
    ; Reload r14d so .uc_done writes the correct value
    mov     r14d, [st_column]
    jmp     .uc_done

; ── Scalar path (sync SIMD register to memory for scalar use) ──
.uc_scalar_sync:
    mov     [st_column], r14d
.uc_scalar:
    movzx   eax, byte [rbx]

    cmp     al, ' '
    je      .uc_space
    cmp     al, 9
    je      .uc_tab_char
    cmp     al, 10
    je      .uc_newline
    cmp     al, 8
    je      .uc_backspace

    ; Other non-blank char (below 0x20 but not special — unlikely but handle)
    call    flush_pending_blanks
    lea     r15, [out_buf]
    movzx   eax, byte [rbx]
    mov     [r15 + r12], al
    inc     r12
    cmp     r12, FLUSH_THRESHOLD
    jl      .uc_nb_nf
    call    flush_output_save
    lea     r15, [out_buf]
.uc_nb_nf:
    inc     dword [st_column]
    mov     byte [st_prev_blank], 0
    cmp     byte [convert_entire_line], 0
    jne     .uc_nb_next
    mov     byte [st_convert], 0
.uc_nb_next:
    inc     rbx
    dec     r13
    jmp     .uc_loop_scalar

; ─── Space ────────────────────────────────────────────────
.uc_space:
    mov     edi, [st_column]
    cmp     byte [tab_is_pow2], 0
    je      .uc_space_slow_tab
    mov     eax, edi
    or      eax, [tab_pow2_mask]
    inc     eax
    xor     edx, edx
    jmp     .uc_space_got_tab
.uc_space_slow_tab:
    mov     esi, [st_tab_index]
    call    get_next_tab_column
.uc_space_got_tab:
    mov     [st_next_tab_col], eax
    test    edx, edx
    jz      .uc_space_convert

    mov     byte [st_convert], 0
    call    flush_pending_blanks
    lea     r15, [out_buf]
    mov     byte [r15 + r12], ' '
    inc     r12
    cmp     r12, FLUSH_THRESHOLD
    jl      .uc_space_last_nf
    call    flush_output_save
    lea     r15, [out_buf]
.uc_space_last_nf:
    inc     dword [st_column]
    mov     byte [st_prev_blank], 1
    inc     rbx
    dec     r13
    jmp     .uc_loop_scalar

.uc_space_convert:
    mov     eax, [st_column]
    inc     eax
    mov     [st_column], eax
    cmp     byte [st_prev_blank], 0
    je      .uc_space_no_convert
    cmp     eax, [st_next_tab_col]
    jne     .uc_space_no_convert

    lea     rdi, [pending_buf]
    mov     byte [rdi], 9
    movzx   eax, byte [st_one_blank_before]
    mov     [st_pending], eax
    mov     eax, [st_tab_index]
    inc     eax
    mov     [st_tab_index], eax

    cmp     dword [st_pending], 0
    je      .uc_space_conv_emit
    lea     rsi, [pending_buf]
    mov     ecx, [st_pending]
    call    emit_bytes
    lea     r15, [out_buf]
    mov     dword [st_pending], 0

.uc_space_conv_emit:
    mov     byte [r15 + r12], 9
    inc     r12
    cmp     r12, FLUSH_THRESHOLD
    jl      .uc_space_conv_nf
    call    flush_output_save
    lea     r15, [out_buf]
.uc_space_conv_nf:
    mov     byte [st_one_blank_before], 0
    mov     byte [st_prev_blank], 1
    inc     rbx
    dec     r13
    jmp     .uc_loop_scalar

.uc_space_no_convert:
    mov     eax, [st_column]
    cmp     eax, [st_next_tab_col]
    jne     .uc_space_just_buffer
    mov     byte [st_one_blank_before], 1
.uc_space_just_buffer:
    mov     eax, [st_pending]
    cmp     eax, PENDING_SIZE
    jge     .uc_space_pending_overflow
    lea     rdi, [pending_buf]
    mov     byte [rdi + rax], ' '
    inc     eax
    mov     [st_pending], eax
    mov     byte [st_prev_blank], 1
    inc     rbx
    dec     r13
    jmp     .uc_loop_scalar

.uc_space_pending_overflow:
    call    flush_pending_blanks
    lea     r15, [out_buf]
    lea     rdi, [pending_buf]
    mov     byte [rdi], ' '
    mov     dword [st_pending], 1
    mov     byte [st_prev_blank], 1
    inc     rbx
    dec     r13
    jmp     .uc_loop_scalar

; ─── Tab character ────────────────────────────────────────
.uc_tab_char:
    mov     edi, [st_column]
    cmp     byte [tab_is_pow2], 0
    je      .uc_tab_slow
    mov     eax, edi
    or      eax, [tab_pow2_mask]
    inc     eax
    xor     edx, edx
    jmp     .uc_tab_got
.uc_tab_slow:
    mov     esi, [st_tab_index]
    call    get_next_tab_column
.uc_tab_got:
    mov     [st_next_tab_col], eax
    test    edx, edx
    jz      .uc_tab_convert

    mov     byte [st_convert], 0
    call    flush_pending_blanks
    lea     r15, [out_buf]
    mov     byte [r15 + r12], 9
    inc     r12
    cmp     r12, FLUSH_THRESHOLD
    jl      .uc_tab_last_nf
    call    flush_output_save
    lea     r15, [out_buf]
.uc_tab_last_nf:
    mov     eax, [st_next_tab_col]
    mov     [st_column], eax
    mov     byte [st_prev_blank], 1
    inc     rbx
    dec     r13
    jmp     .uc_loop_scalar

.uc_tab_convert:
    mov     eax, [st_next_tab_col]
    mov     [st_column], eax
    cmp     dword [st_pending], 0
    je      .uc_tab_no_pending
    lea     rdi, [pending_buf]
    mov     byte [rdi], 9
.uc_tab_no_pending:
    movzx   eax, byte [st_one_blank_before]
    mov     [st_pending], eax
    mov     eax, [st_tab_index]
    inc     eax
    mov     [st_tab_index], eax
    cmp     dword [st_pending], 0
    je      .uc_tab_emit
    lea     rsi, [pending_buf]
    mov     ecx, [st_pending]
    call    emit_bytes
    lea     r15, [out_buf]
    mov     dword [st_pending], 0
.uc_tab_emit:
    mov     byte [r15 + r12], 9
    inc     r12
    cmp     r12, FLUSH_THRESHOLD
    jl      .uc_tab_emit_nf
    call    flush_output_save
    lea     r15, [out_buf]
.uc_tab_emit_nf:
    mov     byte [st_one_blank_before], 0
    mov     byte [st_prev_blank], 1
    inc     rbx
    dec     r13
    jmp     .uc_loop_scalar

; ─── Newline ──────────────────────────────────────────────
.uc_newline:
    ; Inline pending check to avoid function call overhead (500k lines!)
    cmp     dword [st_pending], 0
    jne     .uc_nl_flush_pending
.uc_nl_after_flush:
    lea     r15, [out_buf]
    mov     byte [r15 + r12], 10
    inc     r12
    cmp     r12, FLUSH_THRESHOLD
    jl      .uc_nl_nf
    call    flush_output_save
    lea     r15, [out_buf]
.uc_nl_nf:
    mov     byte [st_convert], 1
    xor     eax, eax
    mov     [st_column], eax
    mov     [st_next_tab_col], eax
    mov     [st_tab_index], eax
    mov     [st_pending], eax
    mov     byte [st_one_blank_before], 0
    mov     byte [st_prev_blank], 1
    xor     r14d, r14d              ; column = 0, skip reload in uc_loop_scalar
    inc     rbx
    dec     r13
    jmp     .uc_loop

.uc_nl_flush_pending:
    call    flush_pending_blanks
    jmp     .uc_nl_after_flush

; ─── Backspace ────────────────────────────────────────────
.uc_backspace:
    call    flush_pending_blanks
    lea     r15, [out_buf]
    mov     byte [r15 + r12], 8
    inc     r12
    cmp     r12, FLUSH_THRESHOLD
    jl      .uc_bs_nf
    call    flush_output_save
    lea     r15, [out_buf]
.uc_bs_nf:
    mov     eax, [st_column]
    test    eax, eax
    jz      .uc_bs_no_dec
    dec     eax
    mov     [st_column], eax
.uc_bs_no_dec:
    mov     [st_next_tab_col], eax
    mov     eax, [st_tab_index]
    test    eax, eax
    jz      .uc_bs_no_tidx
    dec     eax
    mov     [st_tab_index], eax
.uc_bs_no_tidx:
    mov     byte [st_prev_blank], 0
    inc     rbx
    dec     r13
    jmp     .uc_loop_scalar

; ─── Verbatim copy (not converting) ──────────────────────
.uc_verbatim:
    ; Flush any pending blanks that accumulated during convert phase
    cmp     dword [st_pending], 0
    je      .uc_verbatim_no_pending
    push    rbx
    push    r13
    call    flush_pending_blanks
    pop     r13
    pop     rbx
    lea     r15, [out_buf]
.uc_verbatim_no_pending:
    cmp     r13, 64
    jl      .uc_verb_small

    lea     rax, [r12 + 64]
    cmp     rax, FLUSH_THRESHOLD
    jl      .uc_verb_64
    call    flush_output_save
    lea     r15, [out_buf]

.uc_verb_64:
    ; Load 64 bytes and scan for newlines using xmm7
    movdqu  xmm0, [rbx]
    movdqu  xmm1, [rbx + 16]
    movdqu  xmm2, [rbx + 32]
    movdqu  xmm3, [rbx + 48]

    movdqa  xmm4, xmm0
    pcmpeqb xmm4, xmm7
    pmovmskb eax, xmm4

    movdqa  xmm4, xmm1
    pcmpeqb xmm4, xmm7
    pmovmskb ecx, xmm4
    shl     ecx, 16
    or      eax, ecx

    movdqa  xmm4, xmm2
    pcmpeqb xmm4, xmm7
    pmovmskb ecx, xmm4

    movdqa  xmm4, xmm3
    pcmpeqb xmm4, xmm7
    pmovmskb edx, xmm4
    shl     edx, 16
    or      ecx, edx

    ; Combine into 64-bit mask
    mov     rdx, rcx
    shl     rdx, 32
    or      rdx, rax
    test    rdx, rdx
    jnz     .uc_verb_64_has_nl

    ; No newlines: copy 64 bytes
    lea     rdi, [r15 + r12]
    movdqu  [rdi], xmm0
    movdqu  [rdi + 16], xmm1
    movdqu  [rdi + 32], xmm2
    movdqu  [rdi + 48], xmm3
    add     r12, 64
    add     rbx, 64
    sub     r13, 64
    jmp     .uc_verbatim

.uc_verb_64_has_nl:
    bsf     rdx, rdx               ; position of first newline
    test    edx, edx
    jz      .uc_verb_64_emit_nl

    ; Copy edx bytes before newline (overlapping load/store, no rep movsb)
    lea     rdi, [r15 + r12]
    cmp     edx, 32
    jl      .uc_verb_nl_lt32
    ; 32-63 bytes: copy using pre-loaded xmm registers
    ; xmm0-3 already loaded from the 64-byte scan
    movdqu  [rdi], xmm0
    movdqu  [rdi + 16], xmm1
    cmp     edx, 32
    je      .uc_verb_nl_copied
    ; 33-63: overlap last 32 bytes
    lea     ecx, [edx - 32]
    ; Use two fresh loads from rbx for the overlapping tail
    movdqu  xmm4, [rbx + rdx - 32]
    movdqu  xmm3, [rbx + rdx - 16]
    mov     eax, edx
    sub     eax, 32
    movdqu  [rdi + rax], xmm4
    movdqu  [rdi + rax + 16], xmm3
    jmp     .uc_verb_nl_copied
.uc_verb_nl_lt32:
    cmp     edx, 16
    jl      .uc_verb_nl_lt16
    ; 16-31: use xmm0 + overlap
    movdqu  [rdi], xmm0
    cmp     edx, 16
    je      .uc_verb_nl_copied
    movdqu  xmm4, [rbx + rdx - 16]
    mov     eax, edx
    sub     eax, 16
    movdqu  [rdi + rax], xmm4
    jmp     .uc_verb_nl_copied
.uc_verb_nl_lt16:
    cmp     edx, 8
    jl      .uc_verb_nl_lt8
    mov     rax, [rbx]
    mov     [rdi], rax
    cmp     edx, 8
    je      .uc_verb_nl_copied
    mov     rax, [rbx + rdx - 8]
    lea     ecx, [edx - 8]
    mov     [rdi + rcx], rax
    jmp     .uc_verb_nl_copied
.uc_verb_nl_lt8:
    cmp     edx, 4
    jl      .uc_verb_nl_lt4
    mov     eax, [rbx]
    mov     [rdi], eax
    cmp     edx, 4
    je      .uc_verb_nl_copied
    mov     eax, [rbx + rdx - 4]
    lea     ecx, [edx - 4]
    mov     [rdi + rcx], eax
    jmp     .uc_verb_nl_copied
.uc_verb_nl_lt4:
    movzx   eax, byte [rbx]
    mov     [rdi], al
    cmp     edx, 1
    je      .uc_verb_nl_copied
    movzx   eax, byte [rbx + 1]
    mov     [rdi + 1], al
    cmp     edx, 2
    je      .uc_verb_nl_copied
    movzx   eax, byte [rbx + 2]
    mov     [rdi + 2], al
.uc_verb_nl_copied:
    add     r12, rdx
    add     rbx, rdx
    sub     r13, rdx

.uc_verb_64_emit_nl:
    mov     byte [r15 + r12], 10
    inc     r12
    cmp     r12, FLUSH_THRESHOLD
    jl      .uc_verb_64_nl_nf
    call    flush_output_save
    lea     r15, [out_buf]
.uc_verb_64_nl_nf:
    mov     byte [st_convert], 1
    xor     eax, eax
    mov     [st_column], eax
    mov     [st_next_tab_col], eax
    mov     [st_tab_index], eax
    mov     [st_pending], eax
    mov     byte [st_one_blank_before], 0
    mov     byte [st_prev_blank], 1
    xor     r14d, r14d
    inc     rbx
    dec     r13
    jmp     .uc_loop

.uc_verb_small:
    cmp     r13, 16
    jl      .uc_verb_scalar
    lea     rax, [r12 + 16]
    cmp     rax, FLUSH_THRESHOLD
    jl      .uc_verb_16
    call    flush_output_save
    lea     r15, [out_buf]
.uc_verb_16:
    movdqu  xmm0, [rbx]
    movdqa  xmm4, xmm0
    pcmpeqb xmm4, xmm7
    pmovmskb eax, xmm4
    test    eax, eax
    jnz     .uc_verb_found_nl

    lea     rdi, [r15 + r12]
    movdqu  [rdi], xmm0
    add     r12, 16
    add     rbx, 16
    sub     r13, 16
    jmp     .uc_verb_small

.uc_verb_found_nl:
    bsf     ecx, eax
    test    ecx, ecx
    jz      .uc_verb_emit_nl
    ; Copy ecx bytes (1-15) without rep movsb overhead
    lea     rdi, [r15 + r12]
    cmp     ecx, 8
    jl      .uc_vfn_small
    mov     rax, [rbx]
    mov     [rdi], rax
    cmp     ecx, 8
    je      .uc_vfn_done
    mov     rax, [rbx + rcx - 8]
    mov     [rdi + rcx - 8], rax
    jmp     .uc_vfn_done
.uc_vfn_small:
    cmp     ecx, 4
    jl      .uc_vfn_tiny
    mov     eax, [rbx]
    mov     [rdi], eax
    cmp     ecx, 4
    je      .uc_vfn_done
    mov     eax, [rbx + rcx - 4]
    mov     [rdi + rcx - 4], eax
    jmp     .uc_vfn_done
.uc_vfn_tiny:
    movzx   eax, byte [rbx]
    mov     [rdi], al
    cmp     ecx, 1
    je      .uc_vfn_done
    movzx   eax, byte [rbx + 1]
    mov     [rdi + 1], al
    cmp     ecx, 2
    je      .uc_vfn_done
    movzx   eax, byte [rbx + 2]
    mov     [rdi + 2], al
.uc_vfn_done:
    add     r12, rcx
    add     rbx, rcx
    sub     r13, rcx
.uc_verb_emit_nl:
    mov     byte [r15 + r12], 10
    inc     r12
    cmp     r12, FLUSH_THRESHOLD
    jl      .uc_verb_nl_nf
    call    flush_output_save
    lea     r15, [out_buf]
.uc_verb_nl_nf:
    mov     byte [st_convert], 1
    xor     eax, eax
    mov     [st_column], eax
    mov     [st_next_tab_col], eax
    mov     [st_tab_index], eax
    mov     [st_pending], eax
    mov     byte [st_one_blank_before], 0
    mov     byte [st_prev_blank], 1
    xor     r14d, r14d
    inc     rbx
    dec     r13
    jmp     .uc_loop

.uc_verb_scalar:
    test    r13, r13
    jle     .uc_done
    movzx   eax, byte [rbx]
    cmp     al, 10
    je      .uc_verb_emit_nl
    mov     [r15 + r12], al
    inc     r12
    cmp     r12, FLUSH_THRESHOLD
    jl      .uc_verb_sc_nf
    call    flush_output_save
    lea     r15, [out_buf]
.uc_verb_sc_nf:
    inc     rbx
    dec     r13
    jmp     .uc_verb_scalar

.uc_done:
    mov     [st_column], r14d       ; sync cached column back to memory
    pop     r13
    pop     r15
    pop     r14
    pop     rbx
    ret

; ═══════════════════════════════════════════════════════════
;  get_next_tab_column(edi=column, esi=tab_index)
;  -> eax=next_tab_column, edx=last_tab
; ═══════════════════════════════════════════════════════════
get_next_tab_column:
    cmp     byte [tab_list_mode], 0
    jne     .gntc_list
    mov     eax, edi
    xor     edx, edx
    mov     ecx, [default_tab]
    test    ecx, ecx
    jz      .gntc_fallback
    push    rdi
    div     ecx
    inc     eax
    imul    eax, ecx
    pop     rdi
    xor     edx, edx
    ret
.gntc_fallback:
    lea     eax, [edi + 1]
    xor     edx, edx
    ret
.gntc_list:
    mov     ecx, esi
    mov     edx, [num_tab_stops]
.gntc_scan:
    cmp     ecx, edx
    jge     .gntc_beyond
    lea     rax, [tab_stops]
    mov     eax, [rax + rcx*4]
    cmp     eax, edi
    jg      .gntc_found
    inc     ecx
    jmp     .gntc_scan
.gntc_found:
    mov     [st_tab_index], ecx
    xor     edx, edx
    ret
.gntc_beyond:
    mov     eax, 0x7FFFFFFF
    mov     edx, 1
    ret

; ═══════════════════════════════════════════════════════════
;  flush_pending_blanks
; ═══════════════════════════════════════════════════════════
flush_pending_blanks:
    mov     eax, [st_pending]
    test    eax, eax
    jz      .fpb_done
    cmp     eax, 1
    jle     .fpb_no_tab_convert
    cmp     byte [st_one_blank_before], 0
    je      .fpb_no_tab_convert
    lea     rdi, [pending_buf]
    mov     byte [rdi], 9
.fpb_no_tab_convert:
    lea     rsi, [pending_buf]
    mov     ecx, eax
    call    emit_bytes
    mov     dword [st_pending], 0
    mov     byte [st_one_blank_before], 0
.fpb_done:
    ret

; ═══════════════════════════════════════════════════════════
;  emit_bytes
; ═══════════════════════════════════════════════════════════
emit_bytes:
    test    ecx, ecx
    jle     .ebs_done
    lea     rax, [r12 + rcx]
    cmp     rax, OUT_BUF_SIZE
    jl      .ebs_copy
    push    rcx
    push    rsi
    call    flush_output_save
    pop     rsi
    pop     rcx
.ebs_copy:
    lea     rdi, [out_buf]
    add     rdi, r12
    push    rcx
    rep     movsb
    pop     rcx
    add     r12, rcx
.ebs_done:
    ret

; ═══════════════════════════════════════════════════════════
;  flush_output / flush_output_save
; ═══════════════════════════════════════════════════════════
flush_output:
    test    r12, r12
    jz      .fo_empty
    mov     rdi, STDOUT
    lea     rsi, [out_buf]
    mov     rdx, r12
    call    asm_write_all
    xor     r12d, r12d
    ret
.fo_empty:
    xor     eax, eax
    ret

flush_output_save:
    push    rbx
    push    r13
    call    flush_output
    pop     r13
    pop     rbx
    ret

; ═══════════════════════════════════════════════════════════
;  String utilities
; ═══════════════════════════════════════════════════════════
strcmp:
.sc_l:
    movzx   eax, byte [rdi]
    movzx   ecx, byte [rsi]
    cmp     al, cl
    jne     .sc_n
    test    al, al
    jz      .sc_e
    inc     rdi
    inc     rsi
    jmp     .sc_l
.sc_e:
    xor     eax, eax
    ret
.sc_n:
    mov     eax, 1
    ret

strncmp:
    test    ecx, ecx
    jz      .sn_e
.sn_l:
    movzx   eax, byte [rdi]
    movzx   edx, byte [rsi]
    cmp     al, dl
    jne     .sn_n
    inc     rdi
    inc     rsi
    dec     ecx
    jnz     .sn_l
.sn_e:
    xor     eax, eax
    ret
.sn_n:
    mov     eax, 1
    ret

strlen:
    xor     eax, eax
.sl_l:
    cmp     byte [rdi + rax], 0
    je      .sl_d
    inc     rax
    jmp     .sl_l
.sl_d:
    ret

has_comma:
    xor     eax, eax
.hc_l:
    movzx   ecx, byte [rdi]
    test    cl, cl
    jz      .hc_d
    cmp     cl, ','
    je      .hc_f
    inc     rdi
    jmp     .hc_l
.hc_f:
    mov     eax, 1
.hc_d:
    ret

parse_number:
    xor     eax, eax
.pn_l:
    movzx   ecx, byte [rsi]
    sub     ecx, '0'
    cmp     ecx, 9
    ja      .pn_d
    imul    eax, 10
    add     eax, ecx
    inc     rsi
    jmp     .pn_l
.pn_d:
    ret

; ═══════════════════════════════════════════════════════════
;  Error helpers
; ═══════════════════════════════════════════════════════════
print_error_msg:
    push    rbx
    mov     rbx, rdi
    mov     rdi, STDERR
    lea     rsi, [str_prefix]
    mov     rdx, str_prefix_len
    call    asm_write_all
    mov     rdi, rbx
    call    strlen
    mov     rdx, rax
    mov     rdi, STDERR
    mov     rsi, rbx
    call    asm_write_all
    mov     rdi, STDERR
    lea     rsi, [str_newline]
    mov     rdx, 1
    call    asm_write_all
    pop     rbx
    ret

err_file:
    push    rbx
    push    r13
    mov     rbx, rdi
    mov     r13d, esi
    mov     rdi, STDERR
    lea     rsi, [str_prefix]
    mov     rdx, str_prefix_len
    call    asm_write_all
    mov     rdi, rbx
    call    strlen
    mov     rdx, rax
    mov     rdi, STDERR
    mov     rsi, rbx
    call    asm_write_all
    mov     rdi, STDERR
    lea     rsi, [str_colon_space]
    mov     rdx, 2
    call    asm_write_all
    mov     edi, r13d
    call    strerror
    mov     rbx, rax
    mov     rdi, rax
    call    strlen
    mov     rdx, rax
    mov     rdi, STDERR
    mov     rsi, rbx
    call    asm_write_all
    mov     rdi, STDERR
    lea     rsi, [str_newline]
    mov     rdx, 1
    call    asm_write_all
    pop     r13
    pop     rbx
    ret

err_unrecognized_option:
    push    rbx
    mov     rbx, rsi
    mov     rdi, STDERR
    lea     rsi, [str_unrec_prefix]
    mov     rdx, str_unrec_prefix_len
    call    asm_write_all
    mov     rdi, rbx
    call    strlen
    mov     rdx, rax
    mov     rdi, STDERR
    mov     rsi, rbx
    call    asm_write_all
    mov     rdi, STDERR
    lea     rsi, [str_quote_nl]
    mov     rdx, 2
    call    asm_write_all
    mov     rdi, STDERR
    lea     rsi, [str_try_help]
    mov     rdx, str_try_help_len
    call    asm_write_all
    pop     rbx
    ret

err_invalid_option:
    push    rbx
    mov     rbx, rdi
    mov     rdi, STDERR
    lea     rsi, [str_inval_prefix]
    mov     rdx, str_inval_prefix_len
    call    asm_write_all
    mov     rdi, STDERR
    mov     rsi, rbx
    mov     rdx, 1
    call    asm_write_all
    mov     rdi, STDERR
    lea     rsi, [str_quote_nl]
    mov     rdx, 2
    call    asm_write_all
    mov     rdi, STDERR
    lea     rsi, [str_try_help]
    mov     rdx, str_try_help_len
    call    asm_write_all
    pop     rbx
    ret

strerror:
    cmp     edi, 1
    je      .se1
    cmp     edi, 2
    je      .se2
    cmp     edi, 5
    je      .se5
    cmp     edi, 9
    je      .se9
    cmp     edi, 12
    je      .se12
    cmp     edi, 13
    je      .se13
    cmp     edi, 20
    je      .se20
    cmp     edi, 21
    je      .se21
    cmp     edi, 22
    je      .se22
    cmp     edi, 24
    je      .se24
    cmp     edi, 36
    je      .se36
    lea     rax, [str_eunknown]
    ret
.se1:  lea rax, [str_eperm]
    ret
.se2:  lea rax, [str_enoent]
    ret
.se5:  lea rax, [str_eio]
    ret
.se9:  lea rax, [str_ebadf]
    ret
.se12: lea rax, [str_enomem]
    ret
.se13: lea rax, [str_eacces]
    ret
.se20: lea rax, [str_enotdir]
    ret
.se21: lea rax, [str_eisdir]
    ret
.se22: lea rax, [str_einval]
    ret
.se24: lea rax, [str_emfile]
    ret
.se36: lea rax, [str_enametoolong]
    ret

; ─── Data Section ─────────────────────────────────────────
section .data

align 16
simd_space:
    times 16 db 0x20
align 16
simd_nl:
    times 16 db 0x0a
align 16
simd_bs:
    times 16 db 0x08

str_prefix:     db "unexpand: "
str_prefix_len equ $ - str_prefix

str_newline:    db 10
str_colon_space: db ": "

str_opt_help:       db "--help", 0
str_opt_version:    db "--version", 0
str_opt_all:        db "--all", 0
str_opt_firstonly:  db "--first-only", 0
str_opt_tabs_eq:    db "--tabs=", 0

str_unrec_prefix:   db "unexpand: unrecognized option '"
str_unrec_prefix_len equ $ - str_unrec_prefix

str_inval_prefix:   db "unexpand: invalid option -- '"
str_inval_prefix_len equ $ - str_inval_prefix

str_quote_nl:   db "'", 10

str_try_help:   db "Try 'unexpand --help' for more information.", 10
str_try_help_len equ $ - str_try_help

str_write_error: db "write error", 0
str_tab_missing: db "option requires an argument -- 't'", 0
str_tab_invalid: db "tab size contains invalid character", 0

; @@DATA_START@@
help_text:
    db "Usage: unexpand [OPTION]... [FILE]...", 10
    db "Convert blanks in each FILE to tabs, writing to standard output.", 10
    db 10
    db "With no FILE, or when FILE is -, read standard input.", 10
    db 10
    db "Mandatory arguments to long options are mandatory for short options too.", 10
    db "  -a, --all        convert all blanks, instead of just initial blanks", 10
    db "      --first-only  convert only leading sequences of blanks (overrides -a)", 10
    db "  -t, --tabs=N     have tabs N characters apart instead of 8 (enables -a)", 10
    db "  -t, --tabs=LIST  use comma separated list of tab positions.", 10
    db "                     The last specified position can be prefixed with '/'", 10
    db "                     to specify a tab size to use after the last", 10
    db "                     explicitly specified tab stop.  Also a prefix of '+'", 10
    db "                     can be used to align remaining tab stops relative to", 10
    db "                     the last specified tab stop instead of the first column", 10
    db "      --help        display this help and exit", 10
    db "      --version     output version information and exit", 10
    db 10
    db "GNU coreutils online help: <https://www.gnu.org/software/coreutils/>", 10
    db "Full documentation <https://www.gnu.org/software/coreutils/unexpand>", 10
    db "or available locally via: info '(coreutils) unexpand invocation'", 10
help_text_len equ $ - help_text

version_text:
    db "unexpand (GNU coreutils) 9.7", 10
    db "Copyright (C) 2025 Free Software Foundation, Inc.", 10
    db "License GPLv3+: GNU GPL version 3 or later <https://www.gnu.org/licenses/gpl.html>.", 10
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

; ─── BSS Section ──────────────────────────────────────────
section .bss

read_buf:           resb READ_BUF_SIZE
out_buf:            resb OUT_BUF_SIZE
pending_buf:        resb PENDING_SIZE

; Configuration
convert_entire_line: resb 1
first_only:         resb 1
tab_list_mode:      resb 1
tab_is_pow2:        resb 1
default_tab:        resd 1
tab_pow2_mask:      resd 1
num_tab_stops:      resd 1
tab_stops:          resd MAX_TAB_STOPS
num_files:          resd 1
file_list:          resq MAX_FILES

; Per-line state
st_convert:         resb 1
st_prev_blank:      resb 1
st_one_blank_before: resb 1
                    resb 1
st_column:          resd 1
st_next_tab_col:    resd 1
st_tab_index:       resd 1
st_pending:         resd 1

section .note.GNU-stack noalloc noexec nowrite progbits
