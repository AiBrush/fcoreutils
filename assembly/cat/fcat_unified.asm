; ============================================================
; fcat_unified.asm — GNU-compatible 'cat' command
; Single nasm -f bin file with hand-crafted ELF header.
;
; Supports: -n, -b, -s, -E, -T, -v, -A (= -vET), -e (= -vE),
;           -t (= -vT), -u (ignored), -- (end of options),
;           - (stdin), multiple files
;
; Zero-copy fast path: sendfile() for regular files when no flags active
; Pipe/special fallback: read/write loop with 128KB buffer
; Flagged path: buffered transform with 128KB read / 256KB output buffer
;
; SIGPIPE: blocked via rt_sigprocmask, check for -EPIPE on writes
; EINTR: retried on all blocking syscalls
; Partial writes: handled in asm_write_all
;
; BUILD:
;   nasm -f bin fcat_unified.asm -o fcat && chmod +x fcat
; ============================================================

BITS 64
org 0x400000

; ─── System Constants ────────────────────────────────────
%define SYS_READ            0
%define SYS_WRITE           1
%define SYS_OPEN            2
%define SYS_CLOSE           3
%define SYS_FSTAT           5
%define SYS_RT_SIGPROCMASK 14
%define SYS_SENDFILE       40
%define SYS_EXIT           60

%define STDIN               0
%define STDOUT              1
%define STDERR              2
%define O_RDONLY            0

%define EINTR               4
%define EPIPE              32
%define SIGPIPE            13

%define STAT_MODE          24
%define STAT_SIZE          48
%define STAT_STRUCT_SIZE  144

%define S_IFMT          0o170000
%define S_IFREG         0o100000

%define READ_BUF_SIZE   131072
%define OUT_BUF_SIZE    262144
%define FLUSH_THRESHOLD 131072

%define MAX_FILES       4096

%define FLAG_N          0x01
%define FLAG_B          0x02
%define FLAG_S          0x04
%define FLAG_E          0x08
%define FLAG_T          0x10
%define FLAG_V          0x20

%define SENDFILE_CHUNK  0x7FFFF000

; ─── ELF Header (64 bytes) ──────────────────────────────
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

; ─── Program Header 1: PT_LOAD (code + data + bss) ─────
phdr:
    dd 1                        ; PT_LOAD
    dd 7                        ; PF_R | PF_W | PF_X
    dq 0                        ; offset
    dq $$                       ; virtual address
    dq $$                       ; physical address
    dq file_size                ; file size
    dq mem_size                 ; memory size (includes BSS)
    dq 0x200000                 ; alignment
phdr_size equ $ - phdr

; ─── Program Header 2: PT_GNU_STACK (non-executable stack) ──
    dd 0x6474E551               ; PT_GNU_STACK
    dd 6                        ; PF_R | PF_W (no PF_X — NX stack)
    dq 0, 0, 0, 0, 0           ; offset, vaddr, paddr, filesz, memsz
    dq 0x10                     ; alignment

; ============================================================================
;                           CODE
; ============================================================================

_start:
    ; ── Block SIGPIPE so write() returns -EPIPE instead of killing us ──
    sub     rsp, 16
    mov     qword [rsp], 0x1000         ; sigset: bit 12 = SIGPIPE (signal 13)
    mov     eax, SYS_RT_SIGPROCMASK
    xor     edi, edi                    ; SIG_BLOCK = 0
    mov     rsi, rsp
    xor     edx, edx                    ; old_set = NULL
    mov     r10d, 8                     ; sizeof(sigset_t) for kernel
    syscall
    add     rsp, 16

    ; ── Save argc/argv ──
    mov     rax, [rsp]
    mov     [argc], rax
    lea     rax, [rsp + 8]
    mov     [argv], rax

    ; ── Initialize state ──
    mov     byte [flags], 0
    mov     byte [had_error], 0
    mov     qword [nfiles], 0
    mov     qword [line_number], 1
    mov     byte [at_line_start], 1
    mov     byte [blank_count], 0
    xor     r12d, r12d                  ; out_buf_used = 0

    ; ── Parse arguments ──
    call    parse_args

    ; ── If no files, use stdin ──
    cmp     qword [nfiles], 0
    jne     .have_files
    mov     qword [file_ptrs], dash_str
    mov     qword [nfiles], 1

.have_files:
    xor     ebx, ebx                    ; file index = 0

.file_loop:
    cmp     rbx, [nfiles]
    jge     .all_done

    mov     rsi, [file_ptrs + rbx*8]

    ; Check if filename is "-" (stdin)
    cmp     byte [rsi], '-'
    jne     .open_file
    cmp     byte [rsi+1], 0
    jne     .open_file

    ; Stdin
    push    rbx
    mov     edi, STDIN
    call    process_fd
    pop     rbx
    jmp     .file_next

.open_file:
    push    rbx
    push    rsi
    mov     rdi, rsi
    xor     esi, esi                    ; O_RDONLY
    xor     edx, edx
    call    asm_open
    test    rax, rax
    js      .open_error

    mov     r14, rax                    ; fd
    mov     edi, r14d
    call    process_fd

    mov     rdi, r14
    call    asm_close

    pop     rsi
    pop     rbx
    jmp     .file_next

.open_error:
    neg     rax
    mov     r13d, eax
    pop     rsi
    pop     rbx
    push    rbx
    push    rsi
    mov     rdi, rsi
    mov     esi, r13d
    call    err_file
    pop     rsi
    pop     rbx
    mov     byte [had_error], 1

.file_next:
    inc     rbx
    jmp     .file_loop

.all_done:
    ; Flush remaining output buffer
    call    flush_output
    test    rax, rax
    js      .final_write_error

    ; Exit with appropriate code
    movzx   edi, byte [had_error]
    mov     eax, SYS_EXIT
    syscall

.final_write_error:
    cmp     rax, -EPIPE
    je      .epipe_exit
    mov     rdi, str_write_error
    call    print_error_simple
    mov     edi, 1
    mov     eax, SYS_EXIT
    syscall

.epipe_exit:
    mov     edi, 1
    mov     eax, SYS_EXIT
    syscall

; ============================================================================
;                        ARGUMENT PARSING
; ============================================================================
parse_args:
    push    rbx
    push    r12
    push    r13
    push    r14

    mov     r12, [argc]
    mov     r13, [argv]
    mov     rbx, 1
    xor     r14d, r14d                  ; seen_dashdash = 0

.pa_loop:
    cmp     rbx, r12
    jge     .pa_done

    mov     rsi, [r13 + rbx*8]

    test    r14d, r14d
    jnz     .pa_is_file

    cmp     byte [rsi], '-'
    jne     .pa_is_file
    cmp     byte [rsi+1], 0
    je      .pa_is_file                 ; bare "-" is stdin

    cmp     byte [rsi+1], '-'
    jne     .pa_short_opts

    cmp     byte [rsi+2], 0
    je      .pa_dashdash                ; exactly "--"

    ; Check --help
    push    rsi
    lea     rdi, [rsi+2]
    mov     rsi, str_help_arg
    call    str_eq
    pop     rsi
    test    eax, eax
    jnz     .do_help

    ; Check --version
    push    rsi
    lea     rdi, [rsi+2]
    mov     rsi, str_version_arg
    call    str_eq
    pop     rsi
    test    eax, eax
    jnz     .do_version

    ; Unknown --option: error and exit
    mov     rdi, rsi
    call    err_unrecognized_option
    mov     edi, 1
    mov     eax, SYS_EXIT
    syscall

.do_help:
    mov     edi, STDOUT
    mov     rsi, str_help_text
    mov     edx, str_help_text_len
    call    asm_write_all
    xor     edi, edi
    mov     eax, SYS_EXIT
    syscall

.do_version:
    mov     edi, STDOUT
    mov     rsi, str_version_text
    mov     edx, str_version_text_len
    call    asm_write_all
    xor     edi, edi
    mov     eax, SYS_EXIT
    syscall

.pa_dashdash:
    mov     r14d, 1
    jmp     .pa_next

.pa_short_opts:
    mov     rcx, 1                      ; start at char index 1 (skip '-')

.pa_short_loop:
    movzx   eax, byte [rsi + rcx]
    test    al, al
    jz      .pa_next

    cmp     al, 'n'
    je      .pa_flag_n
    cmp     al, 'b'
    je      .pa_flag_b
    cmp     al, 's'
    je      .pa_flag_s
    cmp     al, 'E'
    je      .pa_flag_E
    cmp     al, 'T'
    je      .pa_flag_T
    cmp     al, 'v'
    je      .pa_flag_v
    cmp     al, 'A'
    je      .pa_flag_A
    cmp     al, 'e'
    je      .pa_flag_e
    cmp     al, 't'
    je      .pa_flag_t
    cmp     al, 'u'
    je      .pa_flag_u

    ; Unknown short option
    push    rsi
    push    rcx
    mov     rdi, rsi
    movzx   esi, al
    call    err_invalid_option
    mov     edi, 1
    mov     eax, SYS_EXIT
    syscall

.pa_flag_n:
    or      byte [flags], FLAG_N
    jmp     .pa_short_next
.pa_flag_b:
    or      byte [flags], FLAG_B
    jmp     .pa_short_next
.pa_flag_s:
    or      byte [flags], FLAG_S
    jmp     .pa_short_next
.pa_flag_E:
    or      byte [flags], FLAG_E
    jmp     .pa_short_next
.pa_flag_T:
    or      byte [flags], FLAG_T
    jmp     .pa_short_next
.pa_flag_v:
    or      byte [flags], FLAG_V
    jmp     .pa_short_next
.pa_flag_A:
    or      byte [flags], FLAG_V | FLAG_E | FLAG_T
    jmp     .pa_short_next
.pa_flag_e:
    or      byte [flags], FLAG_V | FLAG_E
    jmp     .pa_short_next
.pa_flag_t:
    or      byte [flags], FLAG_V | FLAG_T
    jmp     .pa_short_next
.pa_flag_u:
    ; -u is ignored (unbuffered)
    jmp     .pa_short_next

.pa_short_next:
    inc     rcx
    jmp     .pa_short_loop

.pa_is_file:
    mov     rax, [nfiles]
    cmp     rax, MAX_FILES
    jge     .pa_next
    mov     [file_ptrs + rax*8], rsi
    inc     qword [nfiles]

.pa_next:
    inc     rbx
    jmp     .pa_loop

.pa_done:
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

; ============================================================================
;  process_fd(edi=fd) — Process one file descriptor
; ============================================================================
process_fd:
    push    rbx
    push    r14
    push    r15
    mov     ebx, edi

    ; Check if any flags are active
    movzx   eax, byte [flags]
    test    al, al
    jnz     .pf_flagged_path

    ; ── Zero-copy path: no flags active ──
    ; fstat to check if regular file
    mov     edi, ebx
    mov     rsi, stat_buf
    mov     rax, SYS_FSTAT
    syscall
    test    rax, rax
    js      .pf_readwrite

    mov     eax, [stat_buf + STAT_MODE]
    and     eax, S_IFMT
    cmp     eax, S_IFREG
    jne     .pf_readwrite

    mov     r14, [stat_buf + STAT_SIZE]
    test    r14, r14
    jz      .pf_done

    ; ── sendfile loop ──
    mov     r15, r14                    ; remaining bytes
.pf_sendfile_loop:
    test    r15, r15
    jle     .pf_done

    mov     eax, SYS_SENDFILE
    mov     edi, STDOUT
    mov     esi, ebx
    xor     edx, edx                    ; offset = NULL
    mov     r10, r15
    cmp     r10, SENDFILE_CHUNK
    jle     .pf_sf_count_ok
    mov     r10, SENDFILE_CHUNK
.pf_sf_count_ok:
    syscall

    cmp     rax, -EINTR
    je      .pf_sendfile_loop

    test    rax, rax
    js      .pf_sendfile_error
    jz      .pf_done

    sub     r15, rax
    jmp     .pf_sendfile_loop

.pf_sendfile_error:
    cmp     rax, -EPIPE
    je      .pf_epipe
    jmp     .pf_readwrite

    ; ── Read/write fallback for non-regular files (no flags) ──
.pf_readwrite:
    mov     edi, ebx
    mov     rsi, read_buf
    mov     edx, READ_BUF_SIZE
    call    asm_read

    test    rax, rax
    js      .pf_read_error
    jz      .pf_done

    mov     rdi, STDOUT
    mov     rsi, read_buf
    mov     rdx, rax
    call    asm_write_all
    test    rax, rax
    js      .pf_write_error

    jmp     .pf_readwrite

    ; ── Flagged path ──
.pf_flagged_path:
    call    process_fd_flagged

.pf_done:
    pop     r15
    pop     r14
    pop     rbx
    ret

.pf_read_error:
    mov     byte [had_error], 1
    jmp     .pf_done

.pf_write_error:
    cmp     rax, -EPIPE
    je      .pf_epipe
    mov     byte [had_error], 1
    jmp     .pf_done

.pf_epipe:
    mov     edi, 1
    mov     eax, SYS_EXIT
    syscall

; ============================================================================
;  process_fd_flagged() — Process fd with flags active
;  Uses: rbx = fd (already saved by caller)
;  r13 = pointer to out_buf base (cached for speed)
; ============================================================================
process_fd_flagged:
    push    r13
    push    r14
    push    r15

    mov     r13, out_buf                ; cache out_buf pointer

.pff_read_loop:
    mov     edi, ebx
    mov     rsi, read_buf
    mov     edx, READ_BUF_SIZE
    call    asm_read

    test    rax, rax
    js      .pff_read_error
    jz      .pff_done

    xor     r14d, r14d                  ; offset = 0
    mov     r15, rax                    ; total bytes read

.pff_byte_loop:
    cmp     r14, r15
    jge     .pff_flush_check

    movzx   eax, byte [read_buf + r14]

    ; ── Handle newline ──
    cmp     al, 10
    je      .pff_newline

    ; ── Handle non-newline byte ──
    mov     byte [blank_count], 0

    cmp     byte [at_line_start], 0
    je      .pff_after_linenum

    movzx   ecx, byte [flags]

    test    cl, FLAG_B
    jnz     .pff_print_linenum
    test    cl, FLAG_N
    jnz     .pff_print_linenum
    jmp     .pff_clear_start

.pff_print_linenum:
    push    rax
    call    emit_line_number
    pop     rax

.pff_clear_start:
    mov     byte [at_line_start], 0

.pff_after_linenum:
    movzx   ecx, byte [flags]
    test    cl, FLAG_V | FLAG_E | FLAG_T
    jnz     .pff_slow_char

    ; ── Bulk copy path ──
    mov     rdi, r14

.pff_bulk_scan:
    cmp     rdi, r15
    jge     .pff_bulk_copy_run

    cmp     byte [read_buf + rdi], 10
    je      .pff_bulk_found_nl

    inc     rdi
    jmp     .pff_bulk_scan

.pff_bulk_found_nl:
    mov     rcx, rdi
    sub     rcx, r14
    jz      .pff_bulk_nl_only

    lea     rax, [r12 + rcx + 2]
    cmp     rax, OUT_BUF_SIZE
    jge     .pff_bulk_flush_first

.pff_bulk_do_copy:
    lea     rsi, [read_buf + r14]
    lea     rdx, [r13 + r12]
    mov     rax, rcx
    shr     rax, 3
    jz      .pff_bulk_copy_tail

.pff_bulk_copy8:
    mov     r8, [rsi]
    mov     [rdx], r8
    add     rsi, 8
    add     rdx, 8
    dec     rax
    jnz     .pff_bulk_copy8

.pff_bulk_copy_tail:
    mov     rax, rcx
    and     rax, 7
    jz      .pff_bulk_copy_done

.pff_bulk_copy1:
    movzx   r8d, byte [rsi]
    mov     [rdx], r8b
    inc     rsi
    inc     rdx
    dec     rax
    jnz     .pff_bulk_copy1

.pff_bulk_copy_done:
    add     r12, rcx
    mov     r14, rdi

.pff_bulk_nl_only:
    mov     byte [r13 + r12], 10
    inc     r12
    mov     byte [at_line_start], 1
    inc     r14

    cmp     r12, FLUSH_THRESHOLD
    jge     .pff_need_flush
    jmp     .pff_byte_loop

.pff_bulk_copy_run:
    mov     rcx, r15
    sub     rcx, r14
    jz      .pff_flush_check

    lea     rax, [r12 + rcx]
    cmp     rax, OUT_BUF_SIZE
    jge     .pff_bulk_flush_first2

.pff_bulk_do_copy2:
    lea     rsi, [read_buf + r14]
    lea     rdx, [r13 + r12]
    mov     rax, rcx
    shr     rax, 3
    jz      .pff_bulk_copy_tail2

.pff_bulk_copy8_2:
    mov     r8, [rsi]
    mov     [rdx], r8
    add     rsi, 8
    add     rdx, 8
    dec     rax
    jnz     .pff_bulk_copy8_2

.pff_bulk_copy_tail2:
    mov     rax, rcx
    and     rax, 7
    jz      .pff_bulk_copy_done2

.pff_bulk_copy1_2:
    movzx   r8d, byte [rsi]
    mov     [rdx], r8b
    inc     rsi
    inc     rdx
    dec     rax
    jnz     .pff_bulk_copy1_2

.pff_bulk_copy_done2:
    add     r12, rcx
    mov     r14, r15
    jmp     .pff_flush_check

.pff_bulk_flush_first:
    push    rcx
    push    rdi
    call    flush_output
    pop     rdi
    pop     rcx
    test    rax, rax
    js      .pff_write_error
    jmp     .pff_bulk_do_copy

.pff_bulk_flush_first2:
    push    rcx
    call    flush_output
    pop     rcx
    test    rax, rax
    js      .pff_write_error
    jmp     .pff_bulk_do_copy2

    ; ── Slow per-byte character transform path ──
.pff_slow_char:
    cmp     al, 9
    je      .pff_check_tab

    test    cl, FLAG_V
    jz      .pff_emit_byte_inline

    ; -v mode: handle non-printing characters
    cmp     al, 0x20
    jb      .pff_v_ctrl
    cmp     al, 0x7F
    je      .pff_v_del
    cmp     al, 0x80
    jb      .pff_emit_byte_inline
    jmp     .pff_v_high

.pff_check_tab:
    test    cl, FLAG_T
    jz      .pff_emit_byte_inline
    mov     byte [r13 + r12], '^'
    inc     r12
    mov     byte [r13 + r12], 'I'
    inc     r12
    inc     r14
    cmp     r12, FLUSH_THRESHOLD
    jge     .pff_need_flush
    jmp     .pff_byte_loop

.pff_v_ctrl:
    ; 0x00-0x1F except \t and \n: '^' + (char + '@')
    mov     byte [r13 + r12], '^'
    inc     r12
    add     al, '@'
    mov     [r13 + r12], al
    inc     r12
    inc     r14
    cmp     r12, FLUSH_THRESHOLD
    jge     .pff_need_flush
    jmp     .pff_byte_loop

.pff_v_del:
    ; 0x7F: '^?'
    mov     byte [r13 + r12], '^'
    inc     r12
    mov     byte [r13 + r12], '?'
    inc     r12
    inc     r14
    cmp     r12, FLUSH_THRESHOLD
    jge     .pff_need_flush
    jmp     .pff_byte_loop

.pff_v_high:
    cmp     al, 0x9F
    jbe     .pff_v_high_ctrl
    cmp     al, 0xFF
    je      .pff_v_high_del

    ; 0xA0-0xFE: 'M-' + (char - 0x80)
    mov     byte [r13 + r12], 'M'
    inc     r12
    mov     byte [r13 + r12], '-'
    inc     r12
    sub     al, 0x80
    mov     [r13 + r12], al
    inc     r12
    inc     r14
    cmp     r12, FLUSH_THRESHOLD
    jge     .pff_need_flush
    jmp     .pff_byte_loop

.pff_v_high_ctrl:
    ; 0x80-0x9F: 'M-^' + (char - 0x80 + '@')
    mov     byte [r13 + r12], 'M'
    inc     r12
    mov     byte [r13 + r12], '-'
    inc     r12
    mov     byte [r13 + r12], '^'
    inc     r12
    sub     al, 0x80
    add     al, '@'
    mov     [r13 + r12], al
    inc     r12
    inc     r14
    cmp     r12, FLUSH_THRESHOLD
    jge     .pff_need_flush
    jmp     .pff_byte_loop

.pff_v_high_del:
    ; 0xFF: 'M-^?'
    mov     byte [r13 + r12], 'M'
    inc     r12
    mov     byte [r13 + r12], '-'
    inc     r12
    mov     byte [r13 + r12], '^'
    inc     r12
    mov     byte [r13 + r12], '?'
    inc     r12
    inc     r14
    cmp     r12, FLUSH_THRESHOLD
    jge     .pff_need_flush
    jmp     .pff_byte_loop

.pff_emit_byte_inline:
    mov     [r13 + r12], al
    inc     r12
    inc     r14
    cmp     r12, FLUSH_THRESHOLD
    jge     .pff_need_flush
    jmp     .pff_byte_loop

    ; ── Flush needed in middle of processing ──
.pff_need_flush:
    call    flush_output
    test    rax, rax
    js      .pff_write_error
    jmp     .pff_byte_loop

    ; ── Flush check between read chunks ──
.pff_flush_check:
    cmp     r12, FLUSH_THRESHOLD
    jl      .pff_read_loop
    call    flush_output
    test    rax, rax
    js      .pff_write_error
    jmp     .pff_read_loop

    ; ── Newline handling ──
.pff_newline:
    movzx   ecx, byte [flags]
    test    cl, FLAG_S
    jz      .pff_nl_no_squeeze

    cmp     byte [at_line_start], 1
    jne     .pff_nl_no_squeeze

    movzx   edx, byte [blank_count]
    cmp     dl, 1
    jge     .pff_nl_suppress
    inc     byte [blank_count]
    jmp     .pff_nl_no_squeeze

.pff_nl_suppress:
    inc     r14
    jmp     .pff_byte_loop

.pff_nl_no_squeeze:
    cmp     byte [at_line_start], 0
    je      .pff_nl_after_linenum

    movzx   ecx, byte [flags]
    test    cl, FLAG_B
    jnz     .pff_nl_after_linenum

    test    cl, FLAG_N
    jz      .pff_nl_after_linenum

    call    emit_line_number

.pff_nl_after_linenum:
    movzx   ecx, byte [flags]
    test    cl, FLAG_E
    jz      .pff_nl_emit

    mov     byte [r13 + r12], '$'
    inc     r12

.pff_nl_emit:
    mov     byte [r13 + r12], 10
    inc     r12
    mov     byte [at_line_start], 1
    inc     r14

    cmp     r12, FLUSH_THRESHOLD
    jge     .pff_need_flush
    jmp     .pff_byte_loop

.pff_read_error:
    mov     byte [had_error], 1
    jmp     .pff_done

.pff_write_error:
    cmp     rax, -EPIPE
    je      .pff_epipe
    mov     byte [had_error], 1
    jmp     .pff_done

.pff_epipe:
    mov     edi, 1
    mov     eax, SYS_EXIT
    syscall

.pff_done:
    pop     r15
    pop     r14
    pop     r13
    ret

; ============================================================================
;  emit_line_number() — Write "%6d\t" line number to output buffer
; ============================================================================
emit_line_number:
    push    rbx

    mov     rax, [line_number]
    inc     qword [line_number]

    lea     rdi, [itoa_buf + 23]
    mov     byte [rdi], 0
    mov     rcx, 10
    xor     ebx, ebx                    ; digit count

.eln_div_loop:
    xor     edx, edx
    div     rcx
    add     dl, '0'
    dec     rdi
    mov     [rdi], dl
    inc     ebx
    test    rax, rax
    jnz     .eln_div_loop

    mov     ecx, 6
    sub     ecx, ebx
    jle     .eln_emit_digits

.eln_space_loop:
    mov     byte [r13 + r12], ' '
    inc     r12
    dec     ecx
    jnz     .eln_space_loop

.eln_emit_digits:
    mov     ecx, ebx
.eln_digit_loop:
    movzx   eax, byte [rdi]
    mov     [r13 + r12], al
    inc     r12
    inc     rdi
    dec     ecx
    jnz     .eln_digit_loop

    mov     byte [r13 + r12], 9
    inc     r12

    cmp     r12, FLUSH_THRESHOLD
    jl      .eln_done
    call    flush_output

.eln_done:
    pop     rbx
    ret

; ============================================================================
;  flush_output() — Write out_buf[0..r12) to stdout
; ============================================================================
flush_output:
    test    r12, r12
    jz      .fo_nothing

    mov     rdi, STDOUT
    mov     rsi, out_buf
    mov     rdx, r12
    call    asm_write_all
    xor     r12d, r12d
    ret

.fo_nothing:
    xor     eax, eax
    ret

; ============================================================================
;  I/O routines (inlined from lib/io.asm)
; ============================================================================

asm_write_all:
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
    cmp     rax, -EINTR
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
    pop     r13
    pop     r12
    pop     rbx
    ret

asm_read:
.ar_retry:
    mov     rax, SYS_READ
    syscall
    cmp     rax, -EINTR
    je      .ar_retry
    ret

asm_open:
    mov     rax, SYS_OPEN
    syscall
    ret

asm_close:
    mov     rax, SYS_CLOSE
    syscall
    ret

; ============================================================================
;  Error helpers
; ============================================================================

strlen:
    xor     eax, eax
.sl_loop:
    cmp     byte [rdi + rax], 0
    je      .sl_done
    inc     rax
    jmp     .sl_loop
.sl_done:
    ret

print_error_simple:
    push    rbx
    mov     rbx, rdi
    mov     rdi, STDERR
    mov     rsi, str_prefix
    mov     rdx, str_prefix_len
    call    asm_write_all
    mov     rdi, rbx
    call    strlen
    mov     rdx, rax
    mov     rdi, STDERR
    mov     rsi, rbx
    call    asm_write_all
    mov     rdi, STDERR
    mov     rsi, str_newline
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
    mov     rsi, str_prefix
    mov     rdx, str_prefix_len
    call    asm_write_all
    mov     rdi, rbx
    call    strlen
    mov     rdx, rax
    mov     rdi, STDERR
    mov     rsi, rbx
    call    asm_write_all
    mov     rdi, STDERR
    mov     rsi, str_colon_space
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
    mov     rsi, str_newline
    mov     rdx, 1
    call    asm_write_all
    pop     r13
    pop     rbx
    ret

err_unrecognized_option:
    push    rbx
    mov     rbx, rdi
    mov     rdi, STDERR
    mov     rsi, str_unrecognized
    mov     rdx, str_unrecognized_len
    call    asm_write_all
    mov     rdi, rbx
    call    strlen
    mov     rdx, rax
    mov     rdi, STDERR
    mov     rsi, rbx
    call    asm_write_all
    mov     rdi, STDERR
    mov     rsi, str_quote_nl
    mov     rdx, 2
    call    asm_write_all
    mov     rdi, STDERR
    mov     rsi, str_try_help
    mov     rdx, str_try_help_len
    call    asm_write_all
    pop     rbx
    ret

err_invalid_option:
    push    rbx
    push    r13
    mov     r13d, esi
    mov     rdi, STDERR
    mov     rsi, str_invalid_opt
    mov     rdx, str_invalid_opt_len
    call    asm_write_all
    mov     [char_buf], r13b
    mov     rdi, STDERR
    mov     rsi, char_buf
    mov     rdx, 1
    call    asm_write_all
    mov     rdi, STDERR
    mov     rsi, str_quote_nl
    mov     rdx, 2
    call    asm_write_all
    mov     rdi, STDERR
    mov     rsi, str_try_help
    mov     rdx, str_try_help_len
    call    asm_write_all
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
    mov     rax, str_eunknown
    ret
.se_eperm:
    mov     rax, str_eperm
    ret
.se_enoent:
    mov     rax, str_enoent
    ret
.se_eio:
    mov     rax, str_eio
    ret
.se_ebadf:
    mov     rax, str_ebadf
    ret
.se_enomem:
    mov     rax, str_enomem
    ret
.se_eacces:
    mov     rax, str_eacces
    ret
.se_enotdir:
    mov     rax, str_enotdir
    ret
.se_eisdir:
    mov     rax, str_eisdir
    ret
.se_einval:
    mov     rax, str_einval
    ret
.se_emfile:
    mov     rax, str_emfile
    ret
.se_enametoolong:
    mov     rax, str_enametoolong
    ret

; ─── Data ───────────────────────────────────────────────

str_prefix:     db "cat: "
str_prefix_len  equ $ - str_prefix

str_newline:    db 10
str_colon_space: db ": "

str_unrecognized: db "cat: unrecognized option '"
str_unrecognized_len equ $ - str_unrecognized

str_quote_nl:   db "'", 10

str_try_help:   db "Try 'cat --help' for more information.", 10
str_try_help_len equ $ - str_try_help

str_invalid_opt: db "cat: invalid option -- '"
str_invalid_opt_len equ $ - str_invalid_opt

str_write_error: db "write error", 0

dash_str:       db "-", 0

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

str_help_arg:       db "help", 0
str_version_arg:    db "version", 0

str_help_text:
    db "Usage: cat [OPTION]... [FILE]...", 10
    db "Concatenate FILE(s) to standard output.", 10
    db 10
    db "With no FILE, or when FILE is -, read standard input.", 10
    db 10
    db "  -A, --show-all           equivalent to -vET", 10
    db "  -b, --number-nonblank    number nonempty output lines, overrides -n", 10
    db "  -e                       equivalent to -vE", 10
    db "  -E, --show-ends          display $ at end of each line", 10
    db "  -n, --number             number all output lines", 10
    db "  -s, --squeeze-blank      suppress repeated empty output lines", 10
    db "  -t                       equivalent to -vT", 10
    db "  -T, --show-tabs          display TAB characters as ^I", 10
    db "  -u                       (ignored)", 10
    db "  -v, --show-nonprinting   use ^ and M- notation, except for LFD and TAB", 10
    db "      --help        display this help and exit", 10
    db "      --version     output version information and exit", 10
str_help_text_len equ $ - str_help_text

str_version_text:
    db "cat (fcoreutils) 0.1", 10
str_version_text_len equ $ - str_version_text

; str_eq: compare two null-terminated strings
; rdi = str1, rsi = str2; returns eax=1 if equal, 0 otherwise
str_eq:
    push    rbx
.se_loop:
    mov     al, [rdi]
    mov     bl, [rsi]
    cmp     al, bl
    jne     .se_neq
    test    al, al
    jz      .se_eq
    inc     rdi
    inc     rsi
    jmp     .se_loop
.se_eq:
    mov     eax, 1
    pop     rbx
    ret
.se_neq:
    xor     eax, eax
    pop     rbx
    ret

; ===============================================================
; BSS (uninitialized data — zero-filled by ELF loader)
; ===============================================================
file_size equ $ - $$

bss_base        equ $$ + file_size

argc            equ bss_base + 0                    ; 8
argv            equ argc + 8                        ; 8
flags           equ argv + 8                        ; 1
had_error       equ flags + 1                       ; 1
_pad1           equ had_error + 1                   ; 6 (alignment padding)
nfiles          equ _pad1 + 6                       ; 8
file_ptrs       equ nfiles + 8                      ; MAX_FILES * 8 = 32768
line_number     equ file_ptrs + MAX_FILES * 8       ; 8
at_line_start   equ line_number + 8                 ; 1
blank_count     equ at_line_start + 1               ; 1
char_buf        equ blank_count + 1                 ; 1
_pad2           equ char_buf + 1                    ; 5 (alignment padding)
itoa_buf        equ _pad2 + 5                       ; 24
stat_buf        equ itoa_buf + 24                   ; STAT_STRUCT_SIZE = 144
read_buf        equ stat_buf + STAT_STRUCT_SIZE     ; READ_BUF_SIZE = 131072
out_buf         equ read_buf + READ_BUF_SIZE        ; OUT_BUF_SIZE = 262144

bss_end         equ out_buf + OUT_BUF_SIZE
mem_size        equ bss_end - $$
