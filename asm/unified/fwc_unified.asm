; fwc_unified.asm — GNU-compatible "wc" in x86_64 assembly (unified binary)
; Auto-merged from modular source — edit tools/fwc.asm and lib/io.asm instead
; Build: nasm -f bin fwc_unified.asm -o fwc && chmod +x fwc

BITS 64
org 0x400000

; ── Syscall numbers ──
%define SYS_READ        0
%define SYS_WRITE       1
%define SYS_OPEN        2
%define SYS_CLOSE       3
%define SYS_FSTAT       5
%define SYS_RT_SIGPROCMASK 14
%define SYS_EXIT       60

%define STDIN           0
%define STDOUT          1
%define STDERR          2
%define O_RDONLY        0

%define STAT_SIZE      144
%define STAT_ST_SIZE    48

; ── Buffer configuration ──
%define BUF_BASE    0x500000
%define READ_BUF    BUF_BASE                ; 64KB read buffer
%define READ_BUFSZ  65536
%define OUT_BUF     (READ_BUF + READ_BUFSZ) ; 4KB output formatting
%define OUT_BUFSZ   4096
%define STAT_BUF    (OUT_BUF + OUT_BUFSZ)   ; 144 bytes
%define RESULTS     (STAT_BUF + STAT_SIZE)  ; per-file results
%define RESULT_ENTRY_SIZE 48
%define MAX_FILES   4096
%define RESULTS_SZ  (RESULT_ENTRY_SIZE * MAX_FILES)
; Accumulators (cur_ and tot_)
%define CUR_LINES   (RESULTS + RESULTS_SZ)
%define CUR_WORDS   (CUR_LINES + 8)
%define CUR_BYTES   (CUR_WORDS + 8)
%define CUR_CHARS   (CUR_BYTES + 8)
%define CUR_MAXLEN  (CUR_CHARS + 8)
%define TOT_LINES   (CUR_MAXLEN + 8)
%define TOT_WORDS   (TOT_LINES + 8)
%define TOT_BYTES   (TOT_WORDS + 8)
%define TOT_CHARS   (TOT_BYTES + 8)
%define TOT_MAXLEN  (TOT_CHARS + 8)
; State
%define FILE_COUNT  (TOT_MAXLEN + 8)
%define RESULT_COUNT (FILE_COUNT + 8)
%define HAD_ERROR   (RESULT_COUNT + 8)
%define IN_WORD     (HAD_ERROR + 1)
%define CUR_LLEN    (IN_WORD + 7)           ; align to 8
; Flags
%define FLAG_LINES  (CUR_LLEN + 8)
%define FLAG_WORDS  (FLAG_LINES + 1)
%define FLAG_BYTES  (FLAG_WORDS + 1)
%define FLAG_CHARS  (FLAG_BYTES + 1)
%define FLAG_MAXLL  (FLAG_CHARS + 1)
%define FLAG_EXPLICIT (FLAG_MAXLL + 1)
%define TOTAL_MODE  (FLAG_EXPLICIT + 1)
%define HAS_STDIN   (TOTAL_MODE + 1)
%define BSS_END     (HAS_STDIN + 1)
%define BSS_SIZE    (BSS_END - BUF_BASE)

; ── ELF Header ──
ehdr:
    db      0x7F, "ELF"
    db      2, 1, 1, 0
    dq      0
    dw      2
    dw      0x3E
    dd      1
    dq      _start
    dq      phdr - ehdr
    dq      0
    dd      0
    dw      ehdr_end - ehdr
    dw      phdr_size
    dw      3
    dw      0, 0, 0
ehdr_end:

; ── Program Headers ──
phdr:
    ; Code + data (R+X)
    dd      1
    dd      5
    dq      0
    dq      0x400000
    dq      0x400000
    dq      file_end - ehdr
    dq      file_end - ehdr
    dq      0x1000
phdr_size equ $ - phdr

    ; BSS (R+W)
    dd      1
    dd      6
    dq      0
    dq      BUF_BASE
    dq      BUF_BASE
    dq      0
    dq      BSS_SIZE
    dq      0x1000

    ; GNU_STACK (NX)
    dd      0x6474E551
    dd      6
    dq      0, 0, 0, 0, 0
    dq      0x10

; ============================================================================
;                           CODE
; ============================================================================

_start:
    pop     rcx
    mov     r14, rsp
    mov     [rsp - 8], rcx
    sub     rsp, 8

    ; Block SIGPIPE
    sub     rsp, 16
    mov     qword [rsp], 0x1000
    mov     eax, SYS_RT_SIGPROCMASK
    xor     edi, edi
    mov     rsi, rsp
    xor     edx, edx
    mov     r10d, 8
    syscall
    add     rsp, 16

    ; Initialize flags and state to 0
    xor     eax, eax
    mov     byte [FLAG_LINES], al
    mov     byte [FLAG_WORDS], al
    mov     byte [FLAG_BYTES], al
    mov     byte [FLAG_CHARS], al
    mov     byte [FLAG_MAXLL], al
    mov     byte [FLAG_EXPLICIT], al
    mov     byte [TOTAL_MODE], al
    mov     byte [HAD_ERROR], al
    mov     byte [HAS_STDIN], al
    mov     qword [FILE_COUNT], rax
    mov     qword [RESULT_COUNT], rax
    mov     qword [TOT_LINES], rax
    mov     qword [TOT_WORDS], rax
    mov     qword [TOT_BYTES], rax
    mov     qword [TOT_CHARS], rax
    mov     qword [TOT_MAXLEN], rax

    ; Parse arguments
    mov     rcx, [rsp]
    lea     rbx, [r14 + 8]
    xor     r15d, r15d
    xor     r13d, r13d
    mov     rax, rcx
    shl     rax, 3
    sub     rsp, rax
    mov     r12, rsp

.parse_loop:
    mov     rsi, [rbx]
    test    rsi, rsi
    jz      .parse_done
    test    r15d, r15d
    jnz     .parse_file_arg
    cmp     byte [rsi], '-'
    jne     .parse_file_arg
    cmp     byte [rsi + 1], 0
    je      .parse_file_arg
    cmp     byte [rsi + 1], '-'
    je      .parse_long_opt
    inc     rsi
.parse_short_loop:
    movzx   eax, byte [rsi]
    test    al, al
    jz      .parse_next
    cmp     al, 'l'
    je      .set_lines
    cmp     al, 'w'
    je      .set_words
    cmp     al, 'c'
    je      .set_bytes
    cmp     al, 'm'
    je      .set_chars
    cmp     al, 'L'
    je      .set_maxll
    jmp     err_invalid_opt
.set_lines:
    mov     byte [FLAG_LINES], 1
    mov     byte [FLAG_EXPLICIT], 1
    inc     rsi
    jmp     .parse_short_loop
.set_words:
    mov     byte [FLAG_WORDS], 1
    mov     byte [FLAG_EXPLICIT], 1
    inc     rsi
    jmp     .parse_short_loop
.set_bytes:
    mov     byte [FLAG_BYTES], 1
    mov     byte [FLAG_EXPLICIT], 1
    inc     rsi
    jmp     .parse_short_loop
.set_chars:
    mov     byte [FLAG_CHARS], 1
    mov     byte [FLAG_EXPLICIT], 1
    inc     rsi
    jmp     .parse_short_loop
.set_maxll:
    mov     byte [FLAG_MAXLL], 1
    mov     byte [FLAG_EXPLICIT], 1
    inc     rsi
    jmp     .parse_short_loop

.parse_long_opt:
    cmp     byte [rsi + 2], 0
    jne     .check_long_help
    mov     r15d, 1
    jmp     .parse_next
.check_long_help:
    lea     rdi, [rsi + 2]
    push    rbx
    lea     rbx, [str_help]
    call    strcmp
    pop     rbx
    test    eax, eax
    jz      do_help
    lea     rdi, [rsi + 2]
    push    rbx
    lea     rbx, [str_version]
    call    strcmp
    pop     rbx
    test    eax, eax
    jz      do_version
    lea     rdi, [rsi + 2]
    push    rbx
    lea     rbx, [str_bytes]
    call    strcmp
    pop     rbx
    test    eax, eax
    jz      .long_set_bytes
    lea     rdi, [rsi + 2]
    push    rbx
    lea     rbx, [str_chars]
    call    strcmp
    pop     rbx
    test    eax, eax
    jz      .long_set_chars
    lea     rdi, [rsi + 2]
    push    rbx
    lea     rbx, [str_lines]
    call    strcmp
    pop     rbx
    test    eax, eax
    jz      .long_set_lines
    lea     rdi, [rsi + 2]
    push    rbx
    lea     rbx, [str_words]
    call    strcmp
    pop     rbx
    test    eax, eax
    jz      .long_set_words
    lea     rdi, [rsi + 2]
    push    rbx
    lea     rbx, [str_maxll]
    call    strcmp
    pop     rbx
    test    eax, eax
    jz      .long_set_maxll
    lea     rdi, [rsi + 2]
    push    rbx
    lea     rbx, [str_total_prefix]
    call    strncmp_prefix
    pop     rbx
    test    eax, eax
    jz      .parse_total_value
    lea     rdi, [rsi + 2]
    push    rbx
    lea     rbx, [str_files0_prefix]
    call    strncmp_prefix
    pop     rbx
    test    eax, eax
    jz      .parse_files0_value
    jmp     err_unrecognized_opt

.long_set_bytes:
    mov     byte [FLAG_BYTES], 1
    mov     byte [FLAG_EXPLICIT], 1
    jmp     .parse_next
.long_set_chars:
    mov     byte [FLAG_CHARS], 1
    mov     byte [FLAG_EXPLICIT], 1
    jmp     .parse_next
.long_set_lines:
    mov     byte [FLAG_LINES], 1
    mov     byte [FLAG_EXPLICIT], 1
    jmp     .parse_next
.long_set_words:
    mov     byte [FLAG_WORDS], 1
    mov     byte [FLAG_EXPLICIT], 1
    jmp     .parse_next
.long_set_maxll:
    mov     byte [FLAG_MAXLL], 1
    mov     byte [FLAG_EXPLICIT], 1
    jmp     .parse_next

.parse_total_value:
    push    rbx
    mov     rbx, rdi
    lea     rdi, [rbx]
    push    r12
    lea     r12, [str_auto]
    xchg    rbx, r12
    call    strcmp
    xchg    rbx, r12
    pop     r12
    test    eax, eax
    jz      .total_auto
    push    r12
    lea     rdi, [rbx]
    lea     r12, [str_always]
    xchg    rbx, r12
    call    strcmp
    xchg    rbx, r12
    pop     r12
    test    eax, eax
    jz      .total_always
    push    r12
    lea     rdi, [rbx]
    lea     r12, [str_only]
    xchg    rbx, r12
    call    strcmp
    xchg    rbx, r12
    pop     r12
    test    eax, eax
    jz      .total_only
    push    r12
    lea     rdi, [rbx]
    lea     r12, [str_never]
    xchg    rbx, r12
    call    strcmp
    xchg    rbx, r12
    pop     r12
    test    eax, eax
    jz      .total_never
    pop     rbx
    jmp     err_invalid_total
.total_auto:
    pop     rbx
    mov     byte [TOTAL_MODE], 0
    jmp     .parse_next
.total_always:
    pop     rbx
    mov     byte [TOTAL_MODE], 1
    jmp     .parse_next
.total_only:
    pop     rbx
    mov     byte [TOTAL_MODE], 2
    jmp     .parse_next
.total_never:
    pop     rbx
    mov     byte [TOTAL_MODE], 3
    jmp     .parse_next

.parse_files0_value:
    jmp     .parse_next
.parse_file_arg:
    mov     rax, [rbx]
    mov     [r12 + r13 * 8], rax
    inc     r13
.parse_next:
    add     rbx, 8
    jmp     .parse_loop

.parse_done:
    cmp     byte [FLAG_EXPLICIT], 0
    jne     .flags_set
    mov     byte [FLAG_LINES], 1
    mov     byte [FLAG_WORDS], 1
    mov     byte [FLAG_BYTES], 1
.flags_set:
    test    r13d, r13d
    jnz     .have_files
    lea     rax, [empty_str]
    mov     [r12], rax
    mov     r13d, 1
.have_files:
    xor     ebp, ebp

.file_loop:
    cmp     ebp, r13d
    jge     .files_done
    mov     rdi, [r12 + rbp * 8]
    cmp     byte [rdi], 0
    je      .stdin_implicit
    cmp     byte [rdi], '-'
    jne     .open_file
    cmp     byte [rdi + 1], 0
    jne     .open_file
    mov     byte [HAS_STDIN], 1
    xor     edi, edi
    lea     rsi, [dash_str]
    jmp     .process_fd
.stdin_implicit:
    mov     byte [HAS_STDIN], 1
    xor     edi, edi
    lea     rsi, [empty_str]
    jmp     .process_fd

.open_file:
    push    rdi
    xor     esi, esi
    xor     edx, edx
    mov     rax, SYS_OPEN
    syscall
    test    rax, rax
    js      .open_error
    mov     rdi, rax
    pop     rsi
    jmp     .process_fd

.open_error:
    pop     rdi
    neg     rax
    push    rax
    push    rdi
    mov     rdi, STDERR
    lea     rsi, [err_prefix]
    mov     edx, err_prefix_len
    call    write_all
    pop     rsi
    push    rsi
    call    strlen_rsi
    mov     rdx, rcx
    mov     rdi, STDERR
    call    write_all
    pop     rsi
    pop     rax
    cmp     eax, 2
    je      .err_noent
    cmp     eax, 13
    je      .err_acces
    cmp     eax, 21
    je      .err_isdir_msg
    mov     rdi, STDERR
    lea     rsi, [err_read]
    mov     rdx, err_read_len
    call    write_all
    jmp     .open_err_done
.err_noent:
    mov     rdi, STDERR
    lea     rsi, [err_nosuch]
    mov     rdx, err_nosuch_len
    call    write_all
    jmp     .open_err_done
.err_acces:
    mov     rdi, STDERR
    lea     rsi, [err_perm]
    mov     rdx, err_perm_len
    call    write_all
    jmp     .open_err_done
.err_isdir_msg:
    mov     rdi, STDERR
    lea     rsi, [err_isdir]
    mov     rdx, err_isdir_len
    call    write_all
.open_err_done:
    mov     byte [HAD_ERROR], 1
    inc     qword [FILE_COUNT]
    inc     ebp
    jmp     .file_loop

.process_fd:
    push    rbp
    push    r12
    push    r13
    push    rsi
    mov     r12d, edi
    xor     eax, eax
    mov     qword [CUR_LINES], rax
    mov     qword [CUR_WORDS], rax
    mov     qword [CUR_BYTES], rax
    mov     qword [CUR_CHARS], rax
    mov     qword [CUR_MAXLEN], rax
    mov     qword [CUR_LLEN], rax
    mov     byte [IN_WORD], al

    ; fstat fast path for -c only
    cmp     byte [FLAG_EXPLICIT], 1
    jne     .do_read_loop
    cmp     byte [FLAG_BYTES], 1
    jne     .do_read_loop
    cmp     byte [FLAG_LINES], 0
    jne     .do_read_loop
    cmp     byte [FLAG_WORDS], 0
    jne     .do_read_loop
    cmp     byte [FLAG_CHARS], 0
    jne     .do_read_loop
    cmp     byte [FLAG_MAXLL], 0
    jne     .do_read_loop
    mov     edi, r12d
    mov     esi, STAT_BUF
    mov     rax, SYS_FSTAT
    syscall
    test    rax, rax
    jnz     .do_read_loop
    mov     rax, [STAT_BUF + STAT_ST_SIZE]
    mov     ecx, [STAT_BUF + 24]
    and     ecx, 0xF000
    cmp     ecx, 0x8000
    jne     .do_read_loop
    mov     [CUR_BYTES], rax
    jmp     .fd_done

.do_read_loop:
    mov     edi, r12d
    mov     esi, READ_BUF
    mov     edx, READ_BUFSZ
    call    do_read
    test    rax, rax
    jz      .fd_done
    js      .read_error
    mov     rcx, rax
    add     [CUR_BYTES], rcx
    mov     esi, READ_BUF
    call    count_chunk
    jmp     .do_read_loop

.read_error:
    mov     byte [HAD_ERROR], 1

.fd_done:
    mov     rax, [CUR_BYTES]
    mov     [CUR_CHARS], rax
    cmp     r12d, 0
    je      .skip_close
    mov     edi, r12d
    mov     rax, SYS_CLOSE
    syscall
.skip_close:
    mov     rax, [CUR_LINES]
    add     [TOT_LINES], rax
    mov     rax, [CUR_WORDS]
    add     [TOT_WORDS], rax
    mov     rax, [CUR_BYTES]
    add     [TOT_BYTES], rax
    mov     rax, [CUR_CHARS]
    add     [TOT_CHARS], rax
    mov     rax, [CUR_MAXLEN]
    mov     rcx, [TOT_MAXLEN]
    cmp     rax, rcx
    jle     .no_max_update
    mov     [TOT_MAXLEN], rax
.no_max_update:
    ; Store result
    mov     rcx, [RESULT_COUNT]
    imul    rdi, rcx, RESULT_ENTRY_SIZE
    add     rdi, RESULTS
    mov     rax, [CUR_LINES]
    mov     [rdi], rax
    mov     rax, [CUR_WORDS]
    mov     [rdi + 8], rax
    mov     rax, [CUR_BYTES]
    mov     [rdi + 16], rax
    mov     rax, [CUR_CHARS]
    mov     [rdi + 24], rax
    mov     rax, [CUR_MAXLEN]
    mov     [rdi + 32], rax
    pop     rsi
    mov     [rdi + 40], rsi
    inc     qword [RESULT_COUNT]
    inc     qword [FILE_COUNT]
    pop     r13
    pop     r12
    pop     rbp
    inc     ebp
    jmp     .file_loop

.files_done:
    call    compute_width
    mov     r15d, eax
    cmp     byte [TOTAL_MODE], 2
    je      .skip_all_file_output
    xor     ebp, ebp
.print_results_loop:
    mov     rcx, [RESULT_COUNT]
    cmp     rbp, rcx
    jge     .print_results_done
    imul    rdi, rbp, RESULT_ENTRY_SIZE
    add     rdi, RESULTS
    mov     r8, rdi
    mov     rsi, [r8 + 40]
    mov     edi, r15d
    call    print_line
    inc     ebp
    jmp     .print_results_loop
.print_results_done:
.skip_all_file_output:
    movzx   eax, byte [TOTAL_MODE]
    cmp     eax, 3
    je      .no_total
    cmp     eax, 1
    je      .print_total
    cmp     eax, 2
    je      .print_total
    cmp     qword [FILE_COUNT], 1
    jle     .no_total
.print_total:
    mov     rax, [TOT_LINES]
    mov     [CUR_LINES], rax
    mov     rax, [TOT_WORDS]
    mov     [CUR_WORDS], rax
    mov     rax, [TOT_BYTES]
    mov     [CUR_BYTES], rax
    mov     rax, [TOT_CHARS]
    mov     [CUR_CHARS], rax
    mov     rax, [TOT_MAXLEN]
    mov     [CUR_MAXLEN], rax
    mov     edi, r15d
    cmp     byte [TOTAL_MODE], 2
    je      .total_only_label
    lea     rsi, [total_label]
    jmp     .print_total_line
.total_only_label:
    xor     esi, esi
.print_total_line:
    mov     r8, CUR_LINES
    call    print_line
.no_total:
    movzx   edi, byte [HAD_ERROR]
    mov     rax, SYS_EXIT
    syscall

; ============================================================================
; count_chunk — Count lines, words, max-line-length in a buffer
; Input: esi = buffer addr, rcx = length
; ============================================================================
count_chunk:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    mov     r14d, esi
    mov     r15, rcx
    xor     ebp, ebp
    movzx   r12d, byte [IN_WORD]
    mov     r13, [CUR_LLEN]
    cmp     byte [FLAG_WORDS], 0
    jne     .count_full
    cmp     byte [FLAG_MAXLL], 0
    jne     .count_full
    cmp     byte [FLAG_LINES], 0
    je      .count_done
    call    count_newlines_sse2
    add     [CUR_LINES], rax
    jmp     .count_done
.count_full:
    cmp     rbp, r15
    jge     .count_save_state
    movzx   eax, byte [r14 + rbp]
    cmp     al, 0x0A
    je      .byte_newline
    cmp     al, 0x20
    je      .byte_space
    cmp     al, 0x09
    jb      .byte_check_printable
    cmp     al, 0x0D
    jbe     .byte_space
.byte_check_printable:
    cmp     al, 0x21
    jb      .byte_transparent
    cmp     al, 0x7E
    ja      .byte_transparent
    test    r12d, r12d
    jnz     .byte_in_word
    mov     r12d, 1
    inc     qword [CUR_WORDS]
.byte_in_word:
    cmp     byte [FLAG_MAXLL], 0
    je      .byte_next
    inc     r13
    jmp     .byte_next
.byte_transparent:
    jmp     .byte_next
.byte_space:
    mov     r12d, 0
    cmp     byte [FLAG_MAXLL], 0
    je      .byte_next
    cmp     al, 0x09
    je      .space_tab
    cmp     al, 0x0D
    je      .space_cr
    cmp     al, 0x0C
    je      .space_cr
    cmp     al, 0x20
    jne     .byte_next
    inc     r13
    jmp     .byte_next
.space_tab:
    add     r13, 8
    and     r13, ~7
    jmp     .byte_next
.space_cr:
    cmp     r13, [CUR_MAXLEN]
    jle     .cr_no_max
    mov     [CUR_MAXLEN], r13
.cr_no_max:
    xor     r13d, r13d
    jmp     .byte_next
.byte_newline:
    inc     qword [CUR_LINES]
    mov     r12d, 0
    cmp     byte [FLAG_MAXLL], 0
    je      .byte_next
    cmp     r13, [CUR_MAXLEN]
    jle     .nl_no_max
    mov     [CUR_MAXLEN], r13
.nl_no_max:
    xor     r13d, r13d
.byte_next:
    inc     rbp
    jmp     .count_full
.count_save_state:
    mov     byte [IN_WORD], r12b
    mov     [CUR_LLEN], r13
    cmp     byte [FLAG_MAXLL], 0
    je      .count_done
    cmp     r13, [CUR_MAXLEN]
    jle     .count_done
    mov     [CUR_MAXLEN], r13
.count_done:
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

; ============================================================================
; count_newlines_sse2 — SSE2 newline counting
; Input: r14 = buffer, r15 = length. Output: rax = count
; ============================================================================
count_newlines_sse2:
    xor     eax, eax
    xor     ecx, ecx
    movd    xmm1, dword [newline_dword]
    pshufd  xmm1, xmm1, 0
    mov     rdx, r15
    sub     rdx, 15
    jle     .nl_scalar
.nl_sse2_loop:
    cmp     rcx, rdx
    jge     .nl_scalar
    movdqu  xmm0, [r14 + rcx]
    pcmpeqb xmm0, xmm1
    pmovmskb edi, xmm0
    popcnt  edi, edi
    add     eax, edi
    add     rcx, 16
    jmp     .nl_sse2_loop
.nl_scalar:
    cmp     rcx, r15
    jge     .nl_done
    cmp     byte [r14 + rcx], 0x0A
    jne     .nl_scalar_next
    inc     eax
.nl_scalar_next:
    inc     rcx
    jmp     .nl_scalar
.nl_done:
    ret

; ============================================================================
; compute_width — Compute column width for formatting
; Output: eax = width
; ============================================================================
compute_width:
    push    rbx
    push    r12
    cmp     byte [TOTAL_MODE], 2
    je      .width_1
    xor     ecx, ecx
    cmp     byte [FLAG_LINES], 0
    je      .wc1
    inc     ecx
.wc1:
    cmp     byte [FLAG_WORDS], 0
    je      .wc2
    inc     ecx
.wc2:
    cmp     byte [FLAG_CHARS], 0
    je      .wc3
    inc     ecx
.wc3:
    cmp     byte [FLAG_BYTES], 0
    je      .wc4
    inc     ecx
.wc4:
    cmp     byte [FLAG_MAXLL], 0
    je      .wc5
    inc     ecx
.wc5:
    mov     r12d, ecx
    movzx   eax, byte [TOTAL_MODE]
    xor     ebx, ebx
    cmp     eax, 1
    je      .wst_yes
    cmp     eax, 2
    je      .wst_yes
    cmp     eax, 3
    je      .wst_no
    cmp     qword [FILE_COUNT], 1
    jg      .wst_yes
    jmp     .wst_no
.wst_yes:
    mov     ebx, 1
.wst_no:
    mov     edx, [FILE_COUNT]
    cmp     byte [TOTAL_MODE], 2
    jne     .nor_not_only
    mov     edx, 0
.nor_not_only:
    add     edx, ebx
    cmp     r12d, 1
    jg      .width_max_val
    cmp     edx, 1
    jg      .width_max_val
    cmp     byte [FLAG_LINES], 0
    je      .sv_w
    mov     rax, [TOT_LINES]
    jmp     .sv_width
.sv_w:
    cmp     byte [FLAG_WORDS], 0
    je      .sv_c
    mov     rax, [TOT_WORDS]
    jmp     .sv_width
.sv_c:
    cmp     byte [FLAG_CHARS], 0
    je      .sv_b
    mov     rax, [TOT_CHARS]
    jmp     .sv_width
.sv_b:
    cmp     byte [FLAG_BYTES], 0
    je      .sv_L
    mov     rax, [TOT_BYTES]
    jmp     .sv_width
.sv_L:
    mov     rax, [TOT_MAXLEN]
.sv_width:
    call    num_width
    pop     r12
    pop     rbx
    ret
.width_max_val:
    mov     rax, [TOT_LINES]
    mov     rcx, [TOT_WORDS]
    cmp     rcx, rax
    cmovg   rax, rcx
    mov     rcx, [TOT_BYTES]
    cmp     rcx, rax
    cmovg   rax, rcx
    mov     rcx, [TOT_CHARS]
    cmp     rcx, rax
    cmovg   rax, rcx
    mov     rcx, [TOT_MAXLEN]
    cmp     rcx, rax
    cmovg   rax, rcx
    call    num_width
    cmp     byte [HAS_STDIN], 0
    je      .width_check_min
    cmp     qword [FILE_COUNT], 1
    jne     .width_check_min
    cmp     eax, 7
    jge     .width_check_min
    mov     eax, 7
.width_check_min:
    pop     r12
    pop     rbx
    ret
.width_1:
    mov     eax, 1
    pop     r12
    pop     rbx
    ret

; ============================================================================
; num_width — Decimal digit count. Input: rax. Output: eax
; ============================================================================
num_width:
    push    rbx
    test    rax, rax
    jnz     .nw_nonzero
    mov     eax, 1
    pop     rbx
    ret
.nw_nonzero:
    xor     ecx, ecx
    mov     rbx, rax
.nw_loop:
    test    rbx, rbx
    jz      .nw_done
    xor     edx, edx
    mov     rax, rbx
    mov     rbx, 10
    div     rbx
    mov     rbx, rax
    inc     ecx
    jmp     .nw_loop
.nw_done:
    mov     eax, ecx
    pop     rbx
    ret

; ============================================================================
; print_line — Print one wc output line
; edi = width, rsi = filename (or NULL), r8 = counts base
; ============================================================================
print_line:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    mov     r12d, edi
    mov     r13, rsi
    mov     r14, r8
    mov     r15d, OUT_BUF
    xor     ebp, ebp
    xor     ebx, ebx
    cmp     byte [FLAG_LINES], 0
    je      .pl_no_lines
    mov     rax, [r14]
    call    format_field
.pl_no_lines:
    cmp     byte [FLAG_WORDS], 0
    je      .pl_no_words
    mov     rax, [r14 + 8]
    call    format_field
.pl_no_words:
    cmp     byte [FLAG_CHARS], 0
    je      .pl_no_chars
    mov     rax, [r14 + 24]
    call    format_field
.pl_no_chars:
    cmp     byte [FLAG_BYTES], 0
    je      .pl_no_bytes
    mov     rax, [r14 + 16]
    call    format_field
.pl_no_bytes:
    cmp     byte [FLAG_MAXLL], 0
    je      .pl_no_maxll
    mov     rax, [r14 + 32]
    call    format_field
.pl_no_maxll:
    test    r13, r13
    jz      .pl_no_name
    cmp     byte [r13], 0
    je      .pl_no_name
    mov     byte [r15 + rbp], ' '
    inc     rbp
    mov     rsi, r13
.pl_name_loop:
    movzx   eax, byte [rsi]
    test    al, al
    jz      .pl_no_name
    mov     [r15 + rbp], al
    inc     rbp
    inc     rsi
    jmp     .pl_name_loop
.pl_no_name:
    mov     byte [r15 + rbp], 10
    inc     rbp
    mov     edi, STDOUT
    mov     esi, r15d
    mov     rdx, rbp
    call    write_all
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

; ============================================================================
; format_field — Right-align number into OUT_BUF
; rax=value, r12d=width, ebx=first flag, r15=outbuf, ebp=pos
; ============================================================================
format_field:
    push    rcx
    push    rdx
    push    rdi
    test    ebx, ebx
    jz      .ff_first
    mov     byte [r15 + rbp], ' '
    inc     ebp
.ff_first:
    mov     ebx, 1
    sub     rsp, 24
    lea     rdi, [rsp + 20]
    xor     ecx, ecx
    test    rax, rax
    jnz     .ff_digits
    dec     rdi
    mov     byte [rdi], '0'
    mov     ecx, 1
    jmp     .ff_pad
.ff_digits:
    push    rbx
    mov     rbx, 10
.ff_dloop:
    test    rax, rax
    jz      .ff_dloop_done
    xor     edx, edx
    div     rbx
    add     dl, '0'
    dec     rdi
    mov     [rdi], dl
    inc     ecx
    jmp     .ff_dloop
.ff_dloop_done:
    pop     rbx
.ff_pad:
    mov     edx, r12d
    sub     edx, ecx
    jle     .ff_no_pad
.ff_pad_loop:
    mov     byte [r15 + rbp], ' '
    inc     ebp
    dec     edx
    jnz     .ff_pad_loop
.ff_no_pad:
.ff_copy:
    test    ecx, ecx
    jz      .ff_done
    movzx   eax, byte [rdi]
    mov     [r15 + rbp], al
    inc     rbp
    inc     rdi
    dec     ecx
    jmp     .ff_copy
.ff_done:
    add     rsp, 24
    pop     rdi
    pop     rdx
    pop     rcx
    ret

; ============================================================================
; Inlined I/O routines (from lib/io.asm)
; ============================================================================

; write_all(rdi=fd, rsi=buf, rdx=len)
write_all:
    push    rbx
    push    r12
    push    r13
    mov     rbx, rdi
    mov     r12, rsi
    mov     r13, rdx
.wa_loop:
    test    r13, r13
    jle     .wa_success
    mov     rdi, rbx
    mov     rsi, r12
    mov     rdx, r13
    mov     rax, SYS_WRITE
    syscall
    cmp     rax, -4
    je      .wa_loop
    test    rax, rax
    js      .wa_error
    add     r12, rax
    sub     r13, rax
    jmp     .wa_loop
.wa_success:
    xor     eax, eax
    pop     r13
    pop     r12
    pop     rbx
    ret
.wa_error:
    mov     rax, -1
    pop     r13
    pop     r12
    pop     rbx
    ret

; do_read(rdi=fd, rsi=buf, rdx=len) -> rax
do_read:
.dr_retry:
    mov     rax, SYS_READ
    syscall
    cmp     rax, -4
    je      .dr_retry
    ret

; ============================================================================
; Utility functions
; ============================================================================
strcmp:
    push    rcx
    push    rsi
    mov     rsi, rbx
.strcmp_loop:
    movzx   eax, byte [rdi]
    movzx   ecx, byte [rsi]
    cmp     al, cl
    jne     .strcmp_ne
    test    al, al
    jz      .strcmp_eq
    inc     rdi
    inc     rsi
    jmp     .strcmp_loop
.strcmp_eq:
    xor     eax, eax
    pop     rsi
    pop     rcx
    ret
.strcmp_ne:
    mov     eax, 1
    pop     rsi
    pop     rcx
    ret

strncmp_prefix:
    push    rcx
    push    rsi
    mov     rsi, rbx
.pfx_loop:
    movzx   ecx, byte [rsi]
    test    cl, cl
    jz      .pfx_match
    movzx   eax, byte [rdi]
    cmp     al, cl
    jne     .pfx_nomatch
    inc     rdi
    inc     rsi
    jmp     .pfx_loop
.pfx_match:
    xor     eax, eax
    pop     rsi
    pop     rcx
    ret
.pfx_nomatch:
    mov     eax, 1
    pop     rsi
    pop     rcx
    ret

strlen_rsi:
    xor     ecx, ecx
.sl_loop:
    cmp     byte [rsi + rcx], 0
    je      .sl_done
    inc     rcx
    jmp     .sl_loop
.sl_done:
    ret

; ============================================================================
; Error handlers
; ============================================================================
err_invalid_opt:
    push    rax
    mov     rdi, STDERR
    lea     rsi, [err_inv_prefix]
    mov     edx, err_inv_prefix_len
    call    write_all
    pop     rax
    push    rax
    mov     [rsp], al
    mov     rdi, STDERR
    mov     rsi, rsp
    mov     edx, 1
    call    write_all
    pop     rax
    mov     rdi, STDERR
    lea     rsi, [err_suffix]
    mov     edx, err_suffix_len
    call    write_all
    mov     edi, 1
    mov     rax, SYS_EXIT
    syscall

err_unrecognized_opt:
    push    rsi
    mov     rdi, STDERR
    lea     rsi, [err_unrec_prefix]
    mov     edx, err_unrec_prefix_len
    call    write_all
    pop     rsi
    push    rsi
    call    strlen_rsi
    mov     rdx, rcx
    mov     rdi, STDERR
    pop     rsi
    call    write_all
    mov     rdi, STDERR
    lea     rsi, [err_suffix]
    mov     edx, err_suffix_len
    call    write_all
    mov     edi, 1
    mov     rax, SYS_EXIT
    syscall

err_invalid_total:
    mov     rdi, STDERR
    lea     rsi, [err_total_msg]
    mov     edx, err_total_msg_len
    call    write_all
    mov     edi, 1
    mov     rax, SYS_EXIT
    syscall

do_help:
    mov     edi, STDOUT
    lea     rsi, [help_text]
    mov     edx, help_text_len
    call    write_all
    xor     edi, edi
    mov     rax, SYS_EXIT
    syscall

do_version:
    mov     edi, STDOUT
    lea     rsi, [version_text]
    mov     edx, version_text_len
    call    write_all
    xor     edi, edi
    mov     rax, SYS_EXIT
    syscall

; ============================================================================
;                           DATA
; ============================================================================

err_prefix:     db "fwc: "
err_prefix_len equ $ - err_prefix
err_nosuch:     db ": No such file or directory", 10
err_nosuch_len equ $ - err_nosuch
err_isdir:      db ": Is a directory", 10
err_isdir_len equ $ - err_isdir
err_perm:       db ": Permission denied", 10
err_perm_len  equ $ - err_perm
err_read:       db ": read error", 10
err_read_len  equ $ - err_read
total_label:    db "total", 0
dash_str:       db "-", 0
empty_str:      db 0

str_help:       db "help", 0
str_version:    db "version", 0
str_bytes:      db "bytes", 0
str_chars:      db "chars", 0
str_lines:      db "lines", 0
str_words:      db "words", 0
str_maxll:      db "max-line-length", 0
str_total_prefix: db "total=", 0
str_files0_prefix: db "files0-from=", 0
str_auto:       db "auto", 0
str_always:     db "always", 0
str_only:       db "only", 0
str_never:      db "never", 0

newline_dword:  dd 0x0A0A0A0A

err_inv_prefix:    db "fwc: invalid option -- '"
err_inv_prefix_len equ $ - err_inv_prefix
err_unrec_prefix:  db "fwc: unrecognized option '"
err_unrec_prefix_len equ $ - err_unrec_prefix
err_suffix:        db "'", 10, "Try 'fwc --help' for more information.", 10
err_suffix_len   equ $ - err_suffix
err_total_msg:     db "fwc: invalid --total value", 10
err_total_msg_len equ $ - err_total_msg

help_text:
    db "Usage: fwc [OPTION]... [FILE]...", 10
    db "  or:  fwc [OPTION]... --files0-from=F", 10
    db "Print newline, word, and byte counts for each FILE, and a total line if", 10
    db "more than one FILE is specified.  A word is a non-zero-length sequence of", 10
    db "printable characters delimited by white space.", 10, 10
    db "With no FILE, or when FILE is -, read standard input.", 10, 10
    db "The options below may be used to select which counts are printed, always in", 10
    db "the following order: newline, word, character, byte, maximum line length.", 10
    db "  -c, --bytes            print the byte counts", 10
    db "  -m, --chars            print the character counts", 10
    db "  -l, --lines            print the newline counts", 10
    db "      --files0-from=F    read input from the files specified by", 10
    db "                           NUL-terminated names in file F;", 10
    db "                           If F is - then read names from standard input", 10
    db "  -L, --max-line-length  print the maximum display width", 10
    db "  -w, --words            print the word counts", 10
    db "      --total=WHEN       when to print a line with total counts;", 10
    db "                           WHEN can be: auto, always, only, never", 10
    db "      --help        display this help and exit", 10
    db "      --version     output version information and exit", 10, 10
    db "GNU coreutils online help: <https://www.gnu.org/software/coreutils/>", 10
    db "Full documentation <https://www.gnu.org/software/coreutils/wc>", 10
    db "or available locally via: info '(coreutils) wc invocation'", 10
help_text_len equ $ - help_text

version_text:
    db "fwc (fcoreutils) 0.1.0", 10
version_text_len equ $ - version_text

file_end:
