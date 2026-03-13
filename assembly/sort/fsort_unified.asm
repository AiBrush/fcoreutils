; ============================================================================
;  fsort_unified.asm — GNU-compatible "sort" in x86_64 Linux assembly
;
;  Unified flat binary: nasm -f bin, hand-crafted ELF header, no linker.
;  SSE2-accelerated newline scanning, merge sort, multiple comparison modes.
;
;  BUILD:
;    nasm -f bin fsort_unified.asm -o fsort && chmod +x fsort
; ============================================================================

BITS 64
ORG 0x400000

; --- Syscall numbers ---
%define SYS_READ            0
%define SYS_WRITE           1
%define SYS_OPEN            2
%define SYS_CLOSE           3
%define SYS_STAT            4
%define SYS_FSTAT           5
%define SYS_MMAP            9
%define SYS_MUNMAP         11
%define SYS_MREMAP         25
%define SYS_RT_SIGPROCMASK 14
%define SYS_EXIT           60

%define STDIN               0
%define STDOUT              1
%define STDERR              2
%define O_RDONLY            0
%define O_WRONLY            1
%define O_CREAT           0x40
%define O_TRUNC          0x200

%define EINTR               4
%define SIGPIPE            13

%define PROT_READ           1
%define PROT_WRITE          2
%define MAP_PRIVATE         2
%define MAP_ANONYMOUS     0x20
%define MAP_POPULATE      0x8000
%define MREMAP_MAYMOVE      1

%define STAT_SIZE          48       ; st_size offset in struct stat
%define STAT_MODE          24       ; st_mode offset
%define STAT_STRUCT_SIZE  144       ; sizeof(struct stat)

; --- Sort constants ---
%define MAX_FILES       256
%define MAX_KEYS        32
%define OUTBUF_SIZE     262144          ; 256KB output buffer
%define INITIAL_BUF     (4*1024*1024)   ; 4MB initial input buffer
%define INITIAL_LINES   (256*1024)      ; initial line array (256K entries)
%define LINE_ENTRY_SIZE 16              ; ptr(8) + len(8) per line
%define INSERTION_THRESH 32             ; threshold for insertion sort

; Option flags (bit positions in flag_bits)
%define FLAG_REVERSE    0x0001
%define FLAG_UNIQUE     0x0002
%define FLAG_NUMERIC    0x0004
%define FLAG_STABLE     0x0008
%define FLAG_CHECK      0x0010
%define FLAG_CHECK_Q    0x0020
%define FLAG_FOLD_CASE  0x0040
%define FLAG_DICT       0x0080
%define FLAG_IGNORE_NP  0x0100
%define FLAG_BLANKS     0x0200
%define FLAG_MERGE      0x0400
%define FLAG_ZERO_TERM  0x0800
%define FLAG_GEN_NUM    0x1000
%define FLAG_MONTH      0x2000
%define FLAG_HUMAN      0x4000
%define FLAG_VERSION    0x8000

; Key option flags (per-key)
%define KEY_NUMERIC     0x010000
%define KEY_BLANKS      0x020000
%define KEY_FOLD_CASE   0x040000
%define KEY_DICT        0x080000
%define KEY_IGNORE_NP   0x100000
%define KEY_REVERSE     0x200000
%define KEY_GEN_NUM     0x400000
%define KEY_MONTH       0x800000
%define KEY_HUMAN       0x1000000
%define KEY_VERSION     0x2000000

; Key definition structure (40 bytes each)
%define KEY_STRUCT_SIZE  40

; Flag combos for fast-path detection
%define ALL_SPECIAL_FLAGS (FLAG_NUMERIC | FLAG_GEN_NUM | FLAG_MONTH | FLAG_HUMAN | FLAG_VERSION | FLAG_FOLD_CASE | FLAG_DICT | FLAG_IGNORE_NP | FLAG_BLANKS)

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
    dq 0                        ; section header offset
    dd 0                        ; flags
    dw ehdr_size                ; ELF header size
    dw phdr_size                ; program header entry size
    dw 2                        ; 2 program headers
    dw 64                       ; section header entry size
    dw 0                        ; section header count
    dw 0                        ; section name index
ehdr_size equ $ - ehdr

; --- Program Header 1: PT_LOAD (code + rodata + BSS) ---
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

; --- Program Header 2: PT_GNU_STACK (non-executable stack) ---
    dd 0x6474E551               ; PT_GNU_STACK
    dd 6                        ; PF_R | PF_W
    dq 0, 0, 0, 0, 0
    dq 0x10

; ===============================================================
; INLINED I/O ROUTINES
; ===============================================================

asm_write_all:
    push    rbx
    push    r12
    push    r13
    mov     rbx, rdi
    mov     r12, rsi
    mov     r13, rdx
.awa_loop:
    test    r13, r13
    jle     .awa_ok
    mov     rdi, rbx
    mov     rsi, r12
    mov     rdx, r13
    mov     rax, SYS_WRITE
    syscall
    cmp     rax, -EINTR
    je      .awa_loop
    test    rax, rax
    js      .awa_err
    add     r12, rax
    sub     r13, rax
    jmp     .awa_loop
.awa_ok:
    xor     eax, eax
    pop     r13
    pop     r12
    pop     rbx
    ret
.awa_err:
    mov     rax, -1
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

asm_exit:
    mov     rax, SYS_EXIT
    syscall

; ===============================================================
; INLINED STRING ROUTINES
; ===============================================================

; asm_strlen(rdi=str) -> rax=length
asm_strlen:
    xor     eax, eax
.sl_loop:
    cmp     byte [rdi + rax], 0
    je      .sl_done
    inc     rax
    jmp     .sl_loop
.sl_done:
    ret

; asm_memcpy(rdi=dest, rsi=src, rdx=len) -> rax=dest
asm_memcpy:
    mov     rax, rdi
    mov     rcx, rdx
    rep movsb
    ret

; asm_itoa(rdi=value, rsi=buf) -> rax=length
asm_itoa:
    push    rbx
    mov     rax, rdi
    mov     rbx, rsi

    test    rax, rax
    jnz     .ai_convert
    mov     byte [rsi], '0'
    mov     rax, 1
    pop     rbx
    ret

.ai_convert:
    mov     r8, rsi
.ai_digit_loop:
    xor     edx, edx
    mov     rcx, 10
    div     rcx
    add     dl, '0'
    mov     [rsi], dl
    inc     rsi
    test    rax, rax
    jnz     .ai_digit_loop

    mov     rax, rsi
    sub     rax, r8

    dec     rsi
    mov     rdi, r8
.ai_reverse_loop:
    cmp     rdi, rsi
    jge     .ai_reverse_done
    mov     cl, [rdi]
    mov     ch, [rsi]
    mov     [rdi], ch
    mov     [rsi], cl
    inc     rdi
    dec     rsi
    jmp     .ai_reverse_loop

.ai_reverse_done:
    pop     rbx
    ret


; ============================================================================
;                           ENTRY POINT
; ============================================================================
_start:
    ; -- Block SIGPIPE --
    sub     rsp, 16
    mov     qword [rsp], 0x2000
    mov     eax, SYS_RT_SIGPROCMASK
    xor     edi, edi
    mov     rsi, rsp
    xor     edx, edx
    mov     r10d, 8
    syscall
    add     rsp, 16

    ; -- Save argc/argv --
    mov     rax, [rsp]
    mov     [argc], rax
    lea     rax, [rsp + 8]
    mov     [argv], rax

    ; -- Initialize defaults --
    mov     qword [flag_bits], 0
    mov     qword [nfiles], 0
    mov     qword [output_file], 0
    mov     qword [output_fd], STDOUT
    mov     byte [has_separator], 0
    mov     byte [line_delim], 10
    mov     qword [nkeys], 0
    mov     qword [outbuf_pos], 0
    mov     qword [use_simple_cmp], 0

    ; -- Parse arguments --
    call    parse_args

    ; -- If -z flag, change line delimiter --
    test    qword [flag_bits], FLAG_ZERO_TERM
    jz      .no_zero
    mov     byte [line_delim], 0
.no_zero:

    ; -- Determine if we can use fast-path comparison --
    cmp     qword [nkeys], 0
    jne     .no_fast_cmp
    mov     rax, [flag_bits]
    test    rax, ALL_SPECIAL_FLAGS
    jnz     .no_fast_cmp
    mov     qword [use_simple_cmp], 1
.no_fast_cmp:

    ; -- If no files, use stdin --
    cmp     qword [nfiles], 0
    jne     .have_files
    lea     rax, [str_dash]
    mov     [files], rax
    mov     qword [nfiles], 1
.have_files:

    ; -- Open output file if specified --
    cmp     qword [output_file], 0
    je      .no_output_file
    mov     rdi, [output_file]
    mov     esi, O_WRONLY | O_CREAT | O_TRUNC
    mov     edx, 0o666
    call    asm_open
    test    rax, rax
    js      .output_open_error
    mov     [output_fd], rax
.no_output_file:

    ; -- Check mode? --
    mov     rax, [flag_bits]
    test    rax, FLAG_CHECK | FLAG_CHECK_Q
    jnz     .do_check

    ; -- Merge mode? --
    test    rax, FLAG_MERGE
    jnz     .do_merge

    ; -- Normal sort mode --
    call    read_all_input
    test    rax, rax
    js      .read_error
    call    scan_lines
    call    sort_lines
    call    write_output
    jmp     .exit_success

.do_check:
    call    check_sorted
    jmp     .exit_success

.do_merge:
    call    read_all_input
    test    rax, rax
    js      .read_error
    call    scan_lines
    call    sort_lines
    call    write_output
    jmp     .exit_success

.read_error:
    mov     edi, 2
    call    asm_exit

.output_open_error:
    mov     rdi, STDERR
    lea     rsi, [str_sort_prefix]
    mov     edx, str_sort_prefix_len
    call    asm_write_all
    mov     rdi, [output_file]
    call    asm_strlen
    mov     rdx, rax
    mov     rsi, [output_file]
    mov     rdi, STDERR
    call    asm_write_all
    mov     rdi, STDERR
    lea     rsi, [str_open_err]
    mov     edx, 15
    call    asm_write_all
    mov     edi, 2
    call    asm_exit

.exit_success:
    call    flush_outbuf
    cmp     qword [output_fd], STDOUT
    je      .skip_close
    mov     rdi, [output_fd]
    call    asm_close
.skip_close:
    xor     edi, edi
    call    asm_exit


; ============================================================================
;  parse_args — Parse command line arguments
; ============================================================================
parse_args:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15

    mov     r12, [argv]
    mov     r13, [argc]
    mov     r14, 1
    xor     r15d, r15d

.arg_loop:
    cmp     r14, r13
    jge     .pa_done

    mov     rbx, [r12 + r14*8]

    test    r15d, r15d
    jnz     .is_file

    cmp     byte [rbx], '-'
    jne     .is_file
    cmp     byte [rbx+1], 0
    je      .is_file

    cmp     byte [rbx+1], '-'
    jne     .short_opts

    cmp     byte [rbx+2], 0
    jne     .long_opt
    mov     r15d, 1
    jmp     .next_arg

.long_opt:
    mov     rdi, rbx
    lea     rsi, [opt_help]
    call    str_equal
    test    eax, eax
    jnz     .do_help

    mov     rdi, rbx
    lea     rsi, [opt_version]
    call    str_equal
    test    eax, eax
    jnz     .do_version

    mov     rdi, rbx
    lea     rsi, [opt_reverse]
    call    str_equal
    test    eax, eax
    jnz     .set_reverse

    mov     rdi, rbx
    lea     rsi, [opt_unique]
    call    str_equal
    test    eax, eax
    jnz     .set_unique

    mov     rdi, rbx
    lea     rsi, [opt_numeric]
    call    str_equal
    test    eax, eax
    jnz     .set_numeric

    mov     rdi, rbx
    lea     rsi, [opt_stable]
    call    str_equal
    test    eax, eax
    jnz     .set_stable

    mov     rdi, rbx
    lea     rsi, [opt_check]
    call    str_equal
    test    eax, eax
    jnz     .set_check

    mov     rdi, rbx
    lea     rsi, [opt_check_eq]
    call    str_starts_with
    test    eax, eax
    jnz     .parse_check_eq

    mov     rdi, rbx
    lea     rsi, [opt_ignore_case]
    call    str_equal
    test    eax, eax
    jnz     .set_fold_case

    mov     rdi, rbx
    lea     rsi, [opt_dictionary]
    call    str_equal
    test    eax, eax
    jnz     .set_dict

    mov     rdi, rbx
    lea     rsi, [opt_ignore_np]
    call    str_equal
    test    eax, eax
    jnz     .set_ignore_np

    mov     rdi, rbx
    lea     rsi, [opt_ignore_blanks]
    call    str_equal
    test    eax, eax
    jnz     .set_blanks

    mov     rdi, rbx
    lea     rsi, [opt_merge]
    call    str_equal
    test    eax, eax
    jnz     .set_merge

    mov     rdi, rbx
    lea     rsi, [opt_zero_terminated]
    call    str_equal
    test    eax, eax
    jnz     .set_zero_term

    mov     rdi, rbx
    lea     rsi, [opt_output_eq]
    call    str_starts_with
    test    eax, eax
    jnz     .parse_output_eq

    mov     rdi, rbx
    lea     rsi, [opt_output]
    call    str_equal
    test    eax, eax
    jnz     .parse_output_next

    mov     rdi, rbx
    lea     rsi, [opt_key_eq]
    call    str_starts_with
    test    eax, eax
    jnz     .parse_key_eq

    mov     rdi, rbx
    lea     rsi, [opt_key]
    call    str_equal
    test    eax, eax
    jnz     .parse_key_next

    mov     rdi, rbx
    lea     rsi, [opt_field_sep_eq]
    call    str_starts_with
    test    eax, eax
    jnz     .parse_sep_eq

    mov     rdi, rbx
    lea     rsi, [opt_field_sep]
    call    str_equal
    test    eax, eax
    jnz     .parse_sep_next

    mov     rdi, rbx
    lea     rsi, [opt_gen_numeric]
    call    str_equal
    test    eax, eax
    jnz     .set_gen_numeric

    mov     rdi, rbx
    lea     rsi, [opt_month_sort]
    call    str_equal
    test    eax, eax
    jnz     .set_month

    mov     rdi, rbx
    lea     rsi, [opt_human_sort]
    call    str_equal
    test    eax, eax
    jnz     .set_human

    mov     rdi, rbx
    lea     rsi, [opt_version_sort]
    call    str_equal
    test    eax, eax
    jnz     .set_version_sort

    jmp     .error_unrec

.short_opts:
    lea     rbx, [rbx + 1]
.short_loop:
    movzx   eax, byte [rbx]
    test    al, al
    jz      .next_arg
    cmp     al, 'b'
    je      .short_blanks
    cmp     al, 'c'
    je      .short_check
    cmp     al, 'C'
    je      .short_check_q
    cmp     al, 'd'
    je      .short_dict
    cmp     al, 'f'
    je      .short_fold
    cmp     al, 'g'
    je      .short_gen_numeric
    cmp     al, 'h'
    je      .short_human
    cmp     al, 'i'
    je      .short_ignore_np
    cmp     al, 'k'
    je      .short_key
    cmp     al, 'm'
    je      .short_merge
    cmp     al, 'M'
    je      .short_month
    cmp     al, 'n'
    je      .short_numeric
    cmp     al, 'o'
    je      .short_output
    cmp     al, 'r'
    je      .short_reverse
    cmp     al, 's'
    je      .short_stable
    cmp     al, 't'
    je      .short_sep
    cmp     al, 'u'
    je      .short_unique
    cmp     al, 'V'
    je      .short_version_sort
    cmp     al, 'z'
    je      .short_zero
    jmp     .error_inval

.short_blanks:
    or      qword [flag_bits], FLAG_BLANKS
    inc     rbx
    jmp     .short_loop
.short_check:
    or      qword [flag_bits], FLAG_CHECK
    inc     rbx
    jmp     .short_loop
.short_check_q:
    or      qword [flag_bits], FLAG_CHECK_Q
    inc     rbx
    jmp     .short_loop
.short_dict:
    or      qword [flag_bits], FLAG_DICT
    inc     rbx
    jmp     .short_loop
.short_fold:
    or      qword [flag_bits], FLAG_FOLD_CASE
    inc     rbx
    jmp     .short_loop
.short_gen_numeric:
    or      qword [flag_bits], FLAG_GEN_NUM
    inc     rbx
    jmp     .short_loop
.short_human:
    or      qword [flag_bits], FLAG_HUMAN
    inc     rbx
    jmp     .short_loop
.short_ignore_np:
    or      qword [flag_bits], FLAG_IGNORE_NP
    inc     rbx
    jmp     .short_loop
.short_month:
    or      qword [flag_bits], FLAG_MONTH
    inc     rbx
    jmp     .short_loop
.short_numeric:
    or      qword [flag_bits], FLAG_NUMERIC
    inc     rbx
    jmp     .short_loop
.short_reverse:
    or      qword [flag_bits], FLAG_REVERSE
    inc     rbx
    jmp     .short_loop
.short_stable:
    or      qword [flag_bits], FLAG_STABLE
    inc     rbx
    jmp     .short_loop
.short_unique:
    or      qword [flag_bits], FLAG_UNIQUE
    inc     rbx
    jmp     .short_loop
.short_zero:
    or      qword [flag_bits], FLAG_ZERO_TERM
    inc     rbx
    jmp     .short_loop
.short_merge:
    or      qword [flag_bits], FLAG_MERGE
    inc     rbx
    jmp     .short_loop
.short_version_sort:
    or      qword [flag_bits], FLAG_VERSION
    inc     rbx
    jmp     .short_loop

.short_key:
    inc     rbx
    cmp     byte [rbx], 0
    jne     .parse_key_inline
    inc     r14
    cmp     r14, r13
    jge     .error_missing_k
    mov     rbx, [r12 + r14*8]
.parse_key_inline:
    mov     rdi, rbx
    call    parse_key
    jmp     .next_arg

.short_output:
    inc     rbx
    cmp     byte [rbx], 0
    jne     .set_output_inline
    inc     r14
    cmp     r14, r13
    jge     .error_missing_o
    mov     rbx, [r12 + r14*8]
.set_output_inline:
    mov     [output_file], rbx
    jmp     .next_arg

.short_sep:
    inc     rbx
    cmp     byte [rbx], 0
    jne     .set_sep_inline
    inc     r14
    cmp     r14, r13
    jge     .error_missing_t
    mov     rbx, [r12 + r14*8]
.set_sep_inline:
    movzx   eax, byte [rbx]
    mov     [separator], al
    mov     byte [has_separator], 1
    jmp     .next_arg

.set_reverse:
    or      qword [flag_bits], FLAG_REVERSE
    jmp     .next_arg
.set_unique:
    or      qword [flag_bits], FLAG_UNIQUE
    jmp     .next_arg
.set_numeric:
    or      qword [flag_bits], FLAG_NUMERIC
    jmp     .next_arg
.set_stable:
    or      qword [flag_bits], FLAG_STABLE
    jmp     .next_arg
.set_check:
    or      qword [flag_bits], FLAG_CHECK
    jmp     .next_arg
.set_fold_case:
    or      qword [flag_bits], FLAG_FOLD_CASE
    jmp     .next_arg
.set_dict:
    or      qword [flag_bits], FLAG_DICT
    jmp     .next_arg
.set_ignore_np:
    or      qword [flag_bits], FLAG_IGNORE_NP
    jmp     .next_arg
.set_blanks:
    or      qword [flag_bits], FLAG_BLANKS
    jmp     .next_arg
.set_merge:
    or      qword [flag_bits], FLAG_MERGE
    jmp     .next_arg
.set_zero_term:
    or      qword [flag_bits], FLAG_ZERO_TERM
    jmp     .next_arg
.set_gen_numeric:
    or      qword [flag_bits], FLAG_GEN_NUM
    jmp     .next_arg
.set_month:
    or      qword [flag_bits], FLAG_MONTH
    jmp     .next_arg
.set_human:
    or      qword [flag_bits], FLAG_HUMAN
    jmp     .next_arg
.set_version_sort:
    or      qword [flag_bits], FLAG_VERSION
    jmp     .next_arg

.parse_check_eq:
    lea     rdi, [rbx + 8]
    lea     rsi, [opt_check_quiet]
    call    str_equal
    test    eax, eax
    jnz     .set_check_q
    lea     rdi, [rbx + 8]
    lea     rsi, [opt_check_silent]
    call    str_equal
    test    eax, eax
    jnz     .set_check_q
    lea     rdi, [rbx + 8]
    lea     rsi, [opt_check_diag]
    call    str_equal
    test    eax, eax
    jnz     .set_check
    jmp     .set_check
.set_check_q:
    or      qword [flag_bits], FLAG_CHECK_Q
    jmp     .next_arg

.parse_output_eq:
    lea     rax, [rbx + 9]
    mov     [output_file], rax
    jmp     .next_arg

.parse_output_next:
    inc     r14
    cmp     r14, r13
    jge     .error_missing_o
    mov     rax, [r12 + r14*8]
    mov     [output_file], rax
    jmp     .next_arg

.parse_key_eq:
    lea     rdi, [rbx + 6]
    call    parse_key
    jmp     .next_arg

.parse_key_next:
    inc     r14
    cmp     r14, r13
    jge     .error_missing_k
    mov     rdi, [r12 + r14*8]
    call    parse_key
    jmp     .next_arg

.parse_sep_eq:
    lea     rax, [rbx + 18]
    movzx   eax, byte [rax]
    mov     [separator], al
    mov     byte [has_separator], 1
    jmp     .next_arg

.parse_sep_next:
    inc     r14
    cmp     r14, r13
    jge     .error_missing_t
    mov     rax, [r12 + r14*8]
    movzx   eax, byte [rax]
    mov     [separator], al
    mov     byte [has_separator], 1
    jmp     .next_arg

.is_file:
    mov     rcx, [nfiles]
    cmp     rcx, MAX_FILES
    jge     .next_arg
    lea     rax, [files]
    mov     [rax + rcx*8], rbx
    inc     qword [nfiles]
    jmp     .next_arg

.next_arg:
    inc     r14
    jmp     .arg_loop

.pa_done:
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

.do_help:
    mov     rdi, STDOUT
    lea     rsi, [str_help]
    mov     edx, str_help_len
    call    asm_write_all
    xor     edi, edi
    call    asm_exit

.do_version:
    mov     rdi, STDOUT
    lea     rsi, [str_version]
    mov     edx, str_version_len
    call    asm_write_all
    xor     edi, edi
    call    asm_exit

.error_inval:
    push    rax
    mov     rdi, STDERR
    lea     rsi, [str_sort_prefix]
    mov     edx, str_sort_prefix_len
    call    asm_write_all
    mov     rdi, STDERR
    lea     rsi, [str_inv_opt]
    mov     edx, 19
    call    asm_write_all
    pop     rax
    sub     rsp, 8
    mov     [rsp], al
    mov     rdi, STDERR
    mov     rsi, rsp
    mov     edx, 1
    call    asm_write_all
    add     rsp, 8
    mov     rdi, STDERR
    lea     rsi, [str_inv_opt2]
    mov     edx, 2
    call    asm_write_all
    mov     rdi, STDERR
    lea     rsi, [str_try_help]
    mov     edx, str_try_help_len
    call    asm_write_all
    mov     edi, 2
    call    asm_exit

.error_unrec:
    mov     rdi, STDERR
    lea     rsi, [str_sort_prefix]
    mov     edx, str_sort_prefix_len
    call    asm_write_all
    mov     rdi, STDERR
    lea     rsi, [str_unrec_opt]
    mov     edx, 21
    call    asm_write_all
    mov     rdi, rbx
    call    asm_strlen
    mov     rdx, rax
    mov     rdi, STDERR
    mov     rsi, rbx
    call    asm_write_all
    mov     rdi, STDERR
    lea     rsi, [str_inv_opt2]
    mov     edx, 2
    call    asm_write_all
    mov     rdi, STDERR
    lea     rsi, [str_try_help]
    mov     edx, str_try_help_len
    call    asm_write_all
    mov     edi, 2
    call    asm_exit

.error_missing_k:
    mov     rdi, STDERR
    lea     rsi, [str_sort_prefix]
    mov     edx, str_sort_prefix_len
    call    asm_write_all
    mov     rdi, STDERR
    lea     rsi, [str_empty_key]
    mov     edx, 34
    call    asm_write_all
    mov     rdi, STDERR
    lea     rsi, [str_newline]
    mov     edx, 1
    call    asm_write_all
    mov     rdi, STDERR
    lea     rsi, [str_try_help]
    mov     edx, str_try_help_len
    call    asm_write_all
    mov     edi, 2
    call    asm_exit

.error_missing_o:
    mov     rdi, STDERR
    lea     rsi, [str_sort_prefix]
    mov     edx, str_sort_prefix_len
    call    asm_write_all
    mov     rdi, STDERR
    lea     rsi, [str_empty_out]
    mov     edx, 34
    call    asm_write_all
    mov     rdi, STDERR
    lea     rsi, [str_newline]
    mov     edx, 1
    call    asm_write_all
    mov     rdi, STDERR
    lea     rsi, [str_try_help]
    mov     edx, str_try_help_len
    call    asm_write_all
    mov     edi, 2
    call    asm_exit

.error_missing_t:
    mov     rdi, STDERR
    lea     rsi, [str_sort_prefix]
    mov     edx, str_sort_prefix_len
    call    asm_write_all
    mov     rdi, STDERR
    lea     rsi, [str_empty_sep]
    mov     edx, 34
    call    asm_write_all
    mov     rdi, STDERR
    lea     rsi, [str_newline]
    mov     edx, 1
    call    asm_write_all
    mov     rdi, STDERR
    lea     rsi, [str_try_help]
    mov     edx, str_try_help_len
    call    asm_write_all
    mov     edi, 2
    call    asm_exit


; ============================================================================
;  parse_key — Parse a -k KEYDEF string
; ============================================================================
parse_key:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15

    mov     r12, rdi
    mov     r13, [nkeys]
    cmp     r13, MAX_KEYS
    jge     .pk_done

    imul    r14, r13, KEY_STRUCT_SIZE
    lea     r15, [keys]
    add     r15, r14

    mov     qword [r15], 0
    mov     qword [r15+8], 0
    mov     qword [r15+16], 0
    mov     qword [r15+24], 0
    mov     qword [r15+32], 0

    mov     rdi, r12
    call    parse_number
    mov     [r15], rax
    mov     r12, rdi

    cmp     byte [r12], '.'
    jne     .pk_start_opts
    inc     r12
    mov     rdi, r12
    call    parse_number
    mov     [r15+8], rax
    mov     r12, rdi

.pk_start_opts:
    mov     rdi, r12
    lea     rsi, [r15+32]
    call    parse_key_opts
    mov     r12, rdi

    cmp     byte [r12], ','
    jne     .pk_no_end
    inc     r12

    mov     rdi, r12
    call    parse_number
    mov     [r15+16], rax
    mov     r12, rdi

    cmp     byte [r12], '.'
    jne     .pk_end_opts
    inc     r12
    mov     rdi, r12
    call    parse_number
    mov     [r15+24], rax
    mov     r12, rdi

.pk_end_opts:
    mov     rdi, r12
    lea     rsi, [r15+32]
    call    parse_key_opts

.pk_no_end:
    inc     qword [nkeys]

.pk_done:
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret


; ============================================================================
;  parse_number / parse_key_opts
; ============================================================================
parse_number:
    xor     eax, eax
    xor     ecx, ecx
.pn_loop:
    movzx   ecx, byte [rdi]
    sub     ecx, '0'
    cmp     ecx, 9
    ja      .pn_done
    imul    rax, 10
    add     rax, rcx
    inc     rdi
    jmp     .pn_loop
.pn_done:
    ret

parse_key_opts:
.pko_loop:
    movzx   eax, byte [rdi]
    cmp     al, 'b'
    je      .pko_set_b
    cmp     al, 'd'
    je      .pko_set_d
    cmp     al, 'f'
    je      .pko_set_f
    cmp     al, 'g'
    je      .pko_set_g
    cmp     al, 'h'
    je      .pko_set_h
    cmp     al, 'i'
    je      .pko_set_i
    cmp     al, 'M'
    je      .pko_set_M
    cmp     al, 'n'
    je      .pko_set_n
    cmp     al, 'r'
    je      .pko_set_r
    cmp     al, 'R'
    je      .pko_done
    cmp     al, 'V'
    je      .pko_set_V
    jmp     .pko_done
.pko_set_b:
    or      qword [rsi], KEY_BLANKS
    inc     rdi
    jmp     .pko_loop
.pko_set_d:
    or      qword [rsi], KEY_DICT
    inc     rdi
    jmp     .pko_loop
.pko_set_f:
    or      qword [rsi], KEY_FOLD_CASE
    inc     rdi
    jmp     .pko_loop
.pko_set_g:
    or      qword [rsi], KEY_GEN_NUM
    inc     rdi
    jmp     .pko_loop
.pko_set_h:
    or      qword [rsi], KEY_HUMAN
    inc     rdi
    jmp     .pko_loop
.pko_set_i:
    or      qword [rsi], KEY_IGNORE_NP
    inc     rdi
    jmp     .pko_loop
.pko_set_M:
    or      qword [rsi], KEY_MONTH
    inc     rdi
    jmp     .pko_loop
.pko_set_n:
    or      qword [rsi], KEY_NUMERIC
    inc     rdi
    jmp     .pko_loop
.pko_set_r:
    or      qword [rsi], KEY_REVERSE
    inc     rdi
    jmp     .pko_loop
.pko_set_V:
    or      qword [rsi], KEY_VERSION
    inc     rdi
    jmp     .pko_loop
.pko_done:
    ret


; ============================================================================
;  read_all_input — Read all input files into a contiguous buffer
; ============================================================================
read_all_input:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15

    ; Single-file mmap fast path
    cmp     qword [nfiles], 1
    jne     .rai_multi_file
    lea     rax, [files]
    mov     rbx, [rax]
    cmp     byte [rbx], '-'
    jne     .rai_try_mmap
    cmp     byte [rbx+1], 0
    je      .rai_multi_file

.rai_try_mmap:
    mov     rdi, rbx
    xor     esi, esi
    xor     edx, edx
    call    asm_open
    test    rax, rax
    js      .rai_file_error_single
    mov     r13, rax

    mov     rdi, r13
    lea     rsi, [stat_buf]
    mov     rax, SYS_FSTAT
    syscall
    test    rax, rax
    js      .rai_close_fallback

    mov     r14, [stat_buf + STAT_SIZE]
    test    r14, r14
    jz      .rai_empty_file

    ; mmap the file read-only with MAP_POPULATE
    xor     edi, edi
    mov     rsi, r14
    mov     edx, PROT_READ | PROT_WRITE
    mov     r10d, MAP_PRIVATE | MAP_POPULATE
    mov     r8, r13
    xor     r9d, r9d
    mov     eax, SYS_MMAP
    syscall
    test    rax, rax
    js      .rai_close_fallback

    mov     [input_buf], rax
    mov     [input_size], r14
    mov     [input_cap], r14

    mov     rdi, r13
    call    asm_close

    xor     eax, eax
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

.rai_empty_file:
    mov     rdi, r13
    call    asm_close
    mov     qword [input_size], 0
    xor     edi, edi
    mov     esi, 4096
    mov     edx, PROT_READ | PROT_WRITE
    mov     r10d, MAP_PRIVATE | MAP_ANONYMOUS
    mov     r8, -1
    xor     r9d, r9d
    mov     eax, SYS_MMAP
    syscall
    mov     [input_buf], rax
    mov     qword [input_cap], 4096
    xor     eax, eax
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

.rai_close_fallback:
    mov     rdi, r13
    call    asm_close

.rai_multi_file:
    xor     edi, edi
    mov     rsi, INITIAL_BUF
    mov     edx, PROT_READ | PROT_WRITE
    mov     r10d, MAP_PRIVATE | MAP_ANONYMOUS
    mov     r8, -1
    xor     r9d, r9d
    mov     eax, SYS_MMAP
    syscall
    test    rax, rax
    js      .rai_error
    mov     [input_buf], rax
    mov     qword [input_size], 0
    mov     qword [input_cap], INITIAL_BUF

    xor     r12d, r12d

.rai_file_loop:
    cmp     r12, [nfiles]
    jge     .rai_done

    lea     rax, [files]
    mov     rbx, [rax + r12*8]

    cmp     byte [rbx], '-'
    jne     .rai_open_file
    cmp     byte [rbx+1], 0
    jne     .rai_open_file
    xor     r13d, r13d
    jmp     .rai_read_fd

.rai_open_file:
    mov     rdi, rbx
    xor     esi, esi
    xor     edx, edx
    call    asm_open
    test    rax, rax
    js      .rai_file_error
    mov     r13, rax

    mov     rdi, r13
    lea     rsi, [stat_buf]
    mov     rax, SYS_FSTAT
    syscall
    test    rax, rax
    js      .rai_read_fd

    mov     r14, [stat_buf + STAT_SIZE]
    test    r14, r14
    jz      .rai_close_next

    mov     rax, [input_size]
    add     rax, r14
    cmp     rax, [input_cap]
    jbe     .rai_read_fd
    call    grow_input_buffer

.rai_read_fd:
.rai_read_loop:
    mov     rax, [input_size]
    mov     rcx, [input_cap]
    sub     rcx, rax
    cmp     rcx, 65536
    jge     .rai_do_read
    push    r13
    call    grow_input_buffer
    pop     r13
    mov     rax, [input_size]
    mov     rcx, [input_cap]
    sub     rcx, rax

.rai_do_read:
    mov     rdi, r13
    mov     rsi, [input_buf]
    add     rsi, rax
    mov     rdx, rcx
    cmp     rdx, 1048576
    jbe     .rai_read_ok
    mov     rdx, 1048576
.rai_read_ok:
    call    asm_read
    test    rax, rax
    js      .rai_read_err
    jz      .rai_read_eof
    add     [input_size], rax
    jmp     .rai_read_loop

.rai_read_eof:
    test    r13, r13
    jz      .rai_next_file
    mov     rdi, r13
    call    asm_close
    jmp     .rai_next_file

.rai_close_next:
    mov     rdi, r13
    call    asm_close

.rai_next_file:
    inc     r12
    jmp     .rai_file_loop

.rai_done:
    xor     eax, eax
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

.rai_file_error_single:
    push    r12
    xor     r12d, r12d
    jmp     .rai_file_error_print

.rai_file_error:
    push    r12
.rai_file_error_print:
    mov     rdi, STDERR
    lea     rsi, [str_sort_prefix]
    mov     edx, str_sort_prefix_len
    call    asm_write_all
    lea     rax, [files]
    mov     r12, [rsp]
    mov     rdi, [rax + r12*8]
    call    asm_strlen
    mov     rdx, rax
    lea     rax, [files]
    mov     rsi, [rax + r12*8]
    mov     rdi, STDERR
    call    asm_write_all
    mov     rdi, STDERR
    lea     rsi, [str_enoent]
    mov     edx, 28
    call    asm_write_all
    pop     r12
    inc     r12
    jmp     .rai_file_loop

.rai_read_err:
.rai_error:
    mov     rax, -1
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret


; ============================================================================
;  grow_input_buffer — Double the input buffer via mremap
; ============================================================================
grow_input_buffer:
    mov     rdi, [input_buf]
    mov     rsi, [input_cap]
    mov     rdx, rsi
    shl     rdx, 1
    mov     r10d, MREMAP_MAYMOVE
    mov     eax, SYS_MREMAP
    syscall
    test    rax, rax
    js      .gib_fail
    mov     [input_buf], rax
    mov     rax, [input_cap]
    shl     rax, 1
    mov     [input_cap], rax
    ret
.gib_fail:
    mov     edi, 2
    call    asm_exit


; ============================================================================
;  scan_lines — SSE2-accelerated newline scanning to build line pointer array
; ============================================================================
scan_lines:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15

    ; Allocate line pointer array
    mov     rsi, INITIAL_LINES * LINE_ENTRY_SIZE
    xor     edi, edi
    mov     edx, PROT_READ | PROT_WRITE
    mov     r10d, MAP_PRIVATE | MAP_ANONYMOUS
    mov     r8, -1
    xor     r9d, r9d
    mov     eax, SYS_MMAP
    syscall
    test    rax, rax
    js      .scl_fail
    mov     [line_array], rax
    mov     qword [line_count], 0
    mov     qword [line_cap], INITIAL_LINES

    mov     r12, [input_buf]
    mov     r13, [input_size]
    movzx   r14d, byte [line_delim]

    test    r13, r13
    jz      .scl_done

    mov     rsi, r12                ; scan pointer
    lea     r15, [r12 + r13]        ; end of input

    ; For newline delimiter, use SSE2
    cmp     r14d, 10
    jne     .scl_scalar_scan

    ; Fill xmm0 with newline byte
    movd    xmm0, r14d
    punpcklbw xmm0, xmm0
    punpcklwd xmm0, xmm0
    pshufd  xmm0, xmm0, 0

    mov     rbx, r12                ; line_start

    ; Safe end for SSE2 (need at least 16 bytes)
    mov     rcx, r15
    sub     rcx, 16
    cmp     rsi, rcx
    jg      .scl_tail

.scl_sse_loop:
    movdqu  xmm1, [rsi]
    pcmpeqb xmm1, xmm0
    pmovmskb eax, xmm1
    test    eax, eax
    jnz     .scl_sse_found
    add     rsi, 16
    cmp     rsi, rcx
    jle     .scl_sse_loop
    jmp     .scl_tail

.scl_sse_found:
.scl_sse_extract:
    bsf     edx, eax
    lea     r8, [rsi + rdx]
    mov     r9, r8
    sub     r9, rbx

    ; Inline add_line for speed
    mov     r10, [line_count]
    cmp     r10, [line_cap]
    jb      .scl_sse_store_ok
    push    rax
    push    rcx
    push    rbx
    push    rsi
    push    r8
    push    r9
    call    grow_line_array
    pop     r9
    pop     r8
    pop     rsi
    pop     rbx
    pop     rcx
    pop     rax
    mov     r10, [line_count]
.scl_sse_store_ok:
    mov     r11, [line_array]
    shl     r10, 4
    mov     [r11 + r10], rbx       ; ptr
    mov     [r11 + r10 + 8], r9    ; len
    inc     qword [line_count]

    lea     rbx, [r8 + 1]          ; next line starts after newline
    btr     eax, edx
    test    eax, eax
    jnz     .scl_sse_extract

    add     rsi, 16
    cmp     rsi, rcx
    jle     .scl_sse_loop

.scl_tail:
    cmp     rbx, r15
    jge     .scl_done

.scl_tail_loop:
    cmp     rsi, r15
    jge     .scl_tail_end
    movzx   eax, byte [rsi]
    cmp     eax, r14d
    je      .scl_tail_found
    inc     rsi
    jmp     .scl_tail_loop

.scl_tail_found:
    mov     rdi, rbx
    mov     r9, rsi
    sub     r9, rbx
    call    add_line_fast
    lea     rbx, [rsi + 1]
    inc     rsi
    jmp     .scl_tail_loop

.scl_tail_end:
    cmp     rbx, r15
    jge     .scl_done
    mov     rdi, rbx
    mov     r9, r15
    sub     r9, rbx
    call    add_line_fast
    jmp     .scl_done

.scl_scalar_scan:
    mov     rbx, r12
    mov     rsi, r12
.scl_scalar_loop:
    cmp     rsi, r15
    jge     .scl_scalar_end
    movzx   eax, byte [rsi]
    cmp     eax, r14d
    je      .scl_scalar_found
    inc     rsi
    jmp     .scl_scalar_loop

.scl_scalar_found:
    mov     rdi, rbx
    mov     r9, rsi
    sub     r9, rbx
    call    add_line_fast
    lea     rbx, [rsi + 1]
    inc     rsi
    jmp     .scl_scalar_loop

.scl_scalar_end:
    cmp     rbx, r15
    jge     .scl_done
    mov     rdi, rbx
    mov     r9, r15
    sub     r9, rbx
    call    add_line_fast

.scl_done:
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

.scl_fail:
    mov     edi, 2
    call    asm_exit


add_line_fast:
    mov     rax, [line_count]
    cmp     rax, [line_cap]
    jb      .alf_ok
    push    rdi
    push    r9
    call    grow_line_array
    pop     r9
    pop     rdi
    mov     rax, [line_count]
.alf_ok:
    mov     rcx, [line_array]
    shl     rax, 4
    mov     [rcx + rax], rdi
    mov     [rcx + rax + 8], r9
    inc     qword [line_count]
    ret


grow_line_array:
    mov     rdi, [line_array]
    mov     rsi, [line_cap]
    imul    rsi, LINE_ENTRY_SIZE
    mov     rdx, rsi
    shl     rdx, 1
    mov     r10d, MREMAP_MAYMOVE
    mov     eax, SYS_MREMAP
    syscall
    test    rax, rax
    js      .gla_fail
    mov     [line_array], rax
    shl     qword [line_cap], 1
    ret
.gla_fail:
    mov     edi, 2
    call    asm_exit


; ============================================================================
;  sort_lines — Bottom-up merge sort with insertion sort for small runs
; ============================================================================
sort_lines:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp

    mov     rcx, [line_count]
    cmp     rcx, 2
    jl      .srt_done

    mov     r12, [line_array]
    mov     r13, rcx

    ; Allocate temp array
    mov     rsi, r13
    imul    rsi, LINE_ENTRY_SIZE
    xor     edi, edi
    mov     edx, PROT_READ | PROT_WRITE
    mov     r10d, MAP_PRIVATE | MAP_ANONYMOUS
    mov     r8, -1
    xor     r9d, r9d
    mov     eax, SYS_MMAP
    syscall
    test    rax, rax
    js      .srt_fail
    mov     [merge_temp], rax
    mov     r14, rax

    ; Phase 1: Insertion sort blocks of INSERTION_THRESH
    xor     ebx, ebx
.isort_block_loop:
    cmp     rbx, r13
    jge     .isort_done

    lea     rcx, [rbx + INSERTION_THRESH]
    cmp     rcx, r13
    jbe     .isort_end_ok
    mov     rcx, r13
.isort_end_ok:
    lea     rax, [rbx + 1]
.isort_i_loop:
    cmp     rax, rcx
    jge     .isort_next_block
    push    rax
    push    rcx

    ; Load element i
    mov     r8, rax
    shl     r8, 4
    mov     r10, [r12 + r8]
    mov     r11, [r12 + r8 + 8]

    pop     rcx
    pop     rax
    push    rax
    push    rcx
    lea     r9, [rax - 1]

.isort_j_loop:
    cmp     r9, rbx
    jl      .isort_insert

    push    r9
    push    r10
    push    r11
    push    rbx
    push    rcx

    mov     rax, r9
    shl     rax, 4
    mov     rdi, [r12 + rax]
    mov     rsi, [r12 + rax + 8]
    mov     rdx, r10
    mov     rcx, r11
    call    compare_lines

    pop     rcx
    pop     rbx
    pop     r11
    pop     r10
    pop     r9

    test    eax, eax
    jle     .isort_insert

    ; Shift array[j] right
    mov     rax, r9
    shl     rax, 4
    mov     r8, [r12 + rax]
    mov     [r12 + rax + 16], r8
    mov     r8, [r12 + rax + 8]
    mov     [r12 + rax + 24], r8
    dec     r9
    jmp     .isort_j_loop

.isort_insert:
    lea     rax, [r9 + 1]
    shl     rax, 4
    mov     [r12 + rax], r10
    mov     [r12 + rax + 8], r11

    pop     rcx
    pop     rax
    inc     rax
    jmp     .isort_i_loop

.isort_next_block:
    add     rbx, INSERTION_THRESH
    jmp     .isort_block_loop

.isort_done:

    ; Phase 2: Bottom-up merge passes
    mov     rbp, INSERTION_THRESH

.merge_width_loop:
    cmp     rbp, r13
    jge     .srt_cleanup

    xor     ebx, ebx

.merge_pair_loop:
    cmp     rbx, r13
    jge     .merge_width_next

    mov     rax, rbx
    add     rax, rbp
    cmp     rax, r13
    jbe     .merge_mid_ok
    mov     rax, r13
.merge_mid_ok:
    mov     rcx, rax

    lea     rax, [rbx + rbp*2]
    cmp     rax, r13
    jbe     .merge_right_ok
    mov     rax, r13
.merge_right_ok:
    mov     r8, rax

    cmp     rcx, r8
    jge     .merge_pair_next

    push    rbx
    push    rbp
    push    r13

    mov     rdi, r12
    mov     rsi, r14
    mov     edx, ebx
    ; ecx = mid, r8d = right
    call    merge_bottom_up

    pop     r13
    pop     rbp
    pop     rbx

.merge_pair_next:
    lea     rbx, [rbx + rbp*2]
    jmp     .merge_pair_loop

.merge_width_next:
    shl     rbp, 1
    jmp     .merge_width_loop

.srt_cleanup:
    mov     rdi, [merge_temp]
    mov     rsi, r13
    imul    rsi, LINE_ENTRY_SIZE
    mov     eax, SYS_MUNMAP
    syscall

.srt_done:
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

.srt_fail:
    mov     edi, 2
    call    asm_exit


; ============================================================================
;  merge_bottom_up — Merge two adjacent sorted runs
;  Input: rdi=array, rsi=temp, edx=left, ecx=mid, r8d=right
; ============================================================================
merge_bottom_up:
    push    rbp
    mov     rbp, rsp
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 8

    mov     r12, rdi
    mov     r13, rsi

    movsxd  r9, edx
    movsxd  r10, ecx
    movsxd  r11, r8d

    ; Copy array[left..right) into temp
    mov     rax, r9
    shl     rax, 4
    lea     rdi, [r13 + rax]
    lea     rsi, [r12 + rax]
    mov     rcx, r11
    sub     rcx, r9
    shl     rcx, 4
    rep movsb

    mov     r14, r9
    mov     r15, r10
    mov     rbx, r9

.mbu_loop:
    cmp     r14, r10
    jge     .mbu_copy_right
    cmp     r15, r11
    jge     .mbu_copy_left

    ; Compare temp[i] vs temp[j]
    push    r9
    push    r10
    push    r11

    mov     rax, r14
    shl     rax, 4
    mov     rdi, [r13 + rax]
    mov     rsi, [r13 + rax + 8]
    mov     rax, r15
    shl     rax, 4
    mov     rdx, [r13 + rax]
    mov     rcx, [r13 + rax + 8]
    call    compare_lines

    pop     r11
    pop     r10
    pop     r9

    test    eax, eax
    jg      .mbu_take_right

    mov     rax, r14
    shl     rax, 4
    mov     rcx, [r13 + rax]
    mov     rdx, [r13 + rax + 8]
    mov     rax, rbx
    shl     rax, 4
    mov     [r12 + rax], rcx
    mov     [r12 + rax + 8], rdx
    inc     r14
    inc     rbx
    jmp     .mbu_loop

.mbu_take_right:
    mov     rax, r15
    shl     rax, 4
    mov     rcx, [r13 + rax]
    mov     rdx, [r13 + rax + 8]
    mov     rax, rbx
    shl     rax, 4
    mov     [r12 + rax], rcx
    mov     [r12 + rax + 8], rdx
    inc     r15
    inc     rbx
    jmp     .mbu_loop

.mbu_copy_left:
    cmp     r14, r10
    jge     .mbu_done
    mov     rax, r14
    shl     rax, 4
    mov     rcx, [r13 + rax]
    mov     rdx, [r13 + rax + 8]
    mov     rax, rbx
    shl     rax, 4
    mov     [r12 + rax], rcx
    mov     [r12 + rax + 8], rdx
    inc     r14
    inc     rbx
    jmp     .mbu_copy_left

.mbu_copy_right:
    cmp     r15, r11
    jge     .mbu_done
    mov     rax, r15
    shl     rax, 4
    mov     rcx, [r13 + rax]
    mov     rdx, [r13 + rax + 8]
    mov     rax, rbx
    shl     rax, 4
    mov     [r12 + rax], rcx
    mov     [r12 + rax + 8], rdx
    inc     r15
    inc     rbx
    jmp     .mbu_copy_right

.mbu_done:
    add     rsp, 8
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    pop     rbp
    ret


; ============================================================================
;  compare_lines — Compare two lines
;  Input: rdi=ptr1, rsi=len1, rdx=ptr2, rcx=len2
;  Output: eax = <0, 0, >0
; ============================================================================
compare_lines:
    cmp     qword [use_simple_cmp], 0
    je      .cl_slow_path

    ; ======== FAST PATH ========
    push    r12
    push    r13

    mov     r8, rdi
    mov     r9, rsi
    mov     r10, rdx
    mov     r11, rcx

    ; min_len
    mov     rcx, r9
    cmp     rcx, r11
    jbe     .fast_min_ok
    mov     rcx, r11
.fast_min_ok:
    test    rcx, rcx
    jz      .fast_len_diff

    ; Compare 8 bytes at a time
.fast_qword_loop:
    cmp     rcx, 8
    jb      .fast_byte_loop
    mov     rax, [r8]
    cmp     rax, [r10]
    jne     .fast_qword_diff
    add     r8, 8
    add     r10, 8
    sub     rcx, 8
    jmp     .fast_qword_loop

.fast_qword_diff:
    xor     rax, [r10]
    bsf     rax, rax
    shr     eax, 3
    movzx   r12d, byte [r8 + rax]
    movzx   r13d, byte [r10 + rax]
    mov     eax, r12d
    sub     eax, r13d
    pop     r13
    pop     r12
    test    qword [flag_bits], FLAG_REVERSE
    jz      .fast_ret
    neg     eax
.fast_ret:
    ret

.fast_byte_loop:
    test    rcx, rcx
    jz      .fast_len_diff
    movzx   eax, byte [r8]
    movzx   edx, byte [r10]
    sub     eax, edx
    jnz     .fast_byte_done
    inc     r8
    inc     r10
    dec     rcx
    jmp     .fast_byte_loop

.fast_len_diff:
    mov     rax, r9
    sub     rax, r11
    test    rax, rax
    jz      .fast_equal
    js      .fast_neg
    mov     eax, 1
    jmp     .fast_byte_done
.fast_neg:
    mov     eax, -1
.fast_byte_done:
    pop     r13
    pop     r12
    test    qword [flag_bits], FLAG_REVERSE
    jz      .fast_ret2
    neg     eax
.fast_ret2:
    ret

.fast_equal:
    xor     eax, eax
    pop     r13
    pop     r12
    ret

    ; ======== SLOW PATH ========
.cl_slow_path:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    mov     rbp, rsp
    sub     rsp, 64

    mov     [rbp-8], rdi
    mov     [rbp-16], rsi
    mov     [rbp-24], rdx
    mov     [rbp-32], rcx

    cmp     qword [nkeys], 0
    jne     .cl_with_keys

    mov     rdi, [rbp-8]
    mov     rsi, [rbp-16]
    mov     rdx, [rbp-24]
    mov     rcx, [rbp-32]
    mov     r8, [flag_bits]
    call    compare_fields
    test    qword [flag_bits], FLAG_REVERSE
    jz      .cl_done
    neg     eax
    jmp     .cl_done

.cl_with_keys:
    xor     r12d, r12d

.cl_key_loop:
    cmp     r12, [nkeys]
    jge     .cl_keys_equal

    imul    r14, r12, KEY_STRUCT_SIZE
    lea     r15, [keys]
    add     r15, r14

    mov     rdi, [rbp-8]
    mov     rsi, [rbp-16]
    mov     rdx, [r15]
    mov     rcx, [r15+8]
    mov     r8, [r15+16]
    mov     r9, [r15+24]
    call    extract_key
    mov     [rbp-40], rax
    mov     [rbp-48], rdx

    mov     rdi, [rbp-24]
    mov     rsi, [rbp-32]
    mov     rdx, [r15]
    mov     rcx, [r15+8]
    mov     r8, [r15+16]
    mov     r9, [r15+24]
    call    extract_key

    mov     rdi, [rbp-40]
    mov     rsi, [rbp-48]
    mov     rcx, rdx
    mov     rdx, rax

    mov     r8, [r15+32]
    test    r8, r8
    jnz     .cl_use_key_flags
    mov     r8, [flag_bits]
.cl_use_key_flags:
    call    compare_fields

    test    eax, eax
    jnz     .cl_key_diff

    inc     r12
    jmp     .cl_key_loop

.cl_key_diff:
    mov     r8, [r15+32]
    test    r8, r8
    jnz     .cl_check_key_rev
    mov     r8, [flag_bits]
.cl_check_key_rev:
    test    r8, KEY_REVERSE | FLAG_REVERSE
    jz      .cl_done
    neg     eax
    jmp     .cl_done

.cl_keys_equal:
    test    qword [flag_bits], FLAG_STABLE
    jnz     .cl_return_zero

    mov     rdi, [rbp-8]
    mov     rsi, [rbp-16]
    mov     rdx, [rbp-24]
    mov     rcx, [rbp-32]
    xor     r8d, r8d
    call    compare_fields
    test    qword [flag_bits], FLAG_REVERSE
    jz      .cl_done
    neg     eax
    jmp     .cl_done

.cl_return_zero:
    xor     eax, eax

.cl_done:
    add     rsp, 64
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret


; ============================================================================
;  compare_fields — Compare two byte ranges with given flags
; ============================================================================
compare_fields:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15

    mov     r12, rdi
    mov     r13, rsi
    mov     r14, rdx
    mov     r15, rcx
    mov     rbx, r8

    test    rbx, FLAG_BLANKS | KEY_BLANKS
    jz      .cf_no_blanks

.cf_skip_blanks1:
    test    r13, r13
    jz      .cf_no_blanks
    cmp     byte [r12], ' '
    je      .cf_sb1
    cmp     byte [r12], 9
    je      .cf_sb1
    jmp     .cf_skip_blanks2
.cf_sb1:
    inc     r12
    dec     r13
    jmp     .cf_skip_blanks1

.cf_skip_blanks2:
    test    r15, r15
    jz      .cf_no_blanks
    cmp     byte [r14], ' '
    je      .cf_sb2
    cmp     byte [r14], 9
    je      .cf_sb2
    jmp     .cf_no_blanks
.cf_sb2:
    inc     r14
    dec     r15
    jmp     .cf_skip_blanks2

.cf_no_blanks:
    test    rbx, FLAG_NUMERIC | KEY_NUMERIC
    jnz     .cf_numeric
    test    rbx, FLAG_GEN_NUM | KEY_GEN_NUM
    jnz     .cf_numeric
    test    rbx, FLAG_MONTH | KEY_MONTH
    jnz     .cf_month
    test    rbx, FLAG_HUMAN | KEY_HUMAN
    jnz     .cf_numeric
    test    rbx, FLAG_VERSION | KEY_VERSION
    jnz     .cf_version

    test    rbx, FLAG_FOLD_CASE | KEY_FOLD_CASE | FLAG_DICT | KEY_DICT | FLAG_IGNORE_NP | KEY_IGNORE_NP
    jnz     .cf_filtered_cmp

    ; Simple byte comparison
    mov     rcx, r13
    cmp     rcx, r15
    jbe     .cf_min_ok
    mov     rcx, r15
.cf_min_ok:
    xor     eax, eax
    test    rcx, rcx
    jz      .cf_len_diff

.cf_fast_loop:
    cmp     rcx, 8
    jb      .cf_byte_loop
    mov     rax, [r12]
    cmp     rax, [r14]
    jne     .cf_byte_loop
    add     r12, 8
    add     r14, 8
    sub     rcx, 8
    jmp     .cf_fast_loop

.cf_byte_loop:
    test    rcx, rcx
    jz      .cf_len_diff
    movzx   eax, byte [r12]
    movzx   edx, byte [r14]
    sub     eax, edx
    jnz     .cf_return
    inc     r12
    inc     r14
    dec     rcx
    jmp     .cf_byte_loop

.cf_len_diff:
    mov     rax, r13
    sub     rax, r15
    test    rax, rax
    jz      .cf_return_zero
    js      .cf_return_neg
    mov     eax, 1
    jmp     .cf_return
.cf_return_neg:
    mov     eax, -1
    jmp     .cf_return
.cf_return_zero:
    xor     eax, eax
.cf_return:
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

.cf_filtered_cmp:
    xor     r8d, r8d
    xor     r9d, r9d

.cf_filt_loop:
.cf_get_c1:
    cmp     r8, r13
    jge     .cf_filt_s1_end
    movzx   eax, byte [r12 + r8]
    inc     r8

    test    rbx, FLAG_DICT | KEY_DICT
    jz      .cf_filt_no_d1
    call    is_dict_char
    test    eax, eax
    jz      .cf_get_c1
    movzx   eax, byte [r12 + r8 - 1]
.cf_filt_no_d1:

    test    rbx, FLAG_IGNORE_NP | KEY_IGNORE_NP
    jz      .cf_filt_no_i1
    cmp     al, 0x20
    jb      .cf_get_c1
    cmp     al, 0x7E
    ja      .cf_get_c1
.cf_filt_no_i1:

    test    rbx, FLAG_FOLD_CASE | KEY_FOLD_CASE
    jz      .cf_filt_no_f1
    cmp     al, 'a'
    jb      .cf_filt_no_f1
    cmp     al, 'z'
    ja      .cf_filt_no_f1
    sub     al, 32
.cf_filt_no_f1:
    mov     cl, al

.cf_get_c2:
    cmp     r9, r15
    jge     .cf_filt_s2_end_with_c1
    movzx   eax, byte [r14 + r9]
    inc     r9

    test    rbx, FLAG_DICT | KEY_DICT
    jz      .cf_filt_no_d2
    call    is_dict_char
    test    eax, eax
    jz      .cf_get_c2
    movzx   eax, byte [r14 + r9 - 1]
.cf_filt_no_d2:

    test    rbx, FLAG_IGNORE_NP | KEY_IGNORE_NP
    jz      .cf_filt_no_i2
    cmp     al, 0x20
    jb      .cf_get_c2
    cmp     al, 0x7E
    ja      .cf_get_c2
.cf_filt_no_i2:

    test    rbx, FLAG_FOLD_CASE | KEY_FOLD_CASE
    jz      .cf_filt_no_f2
    cmp     al, 'a'
    jb      .cf_filt_no_f2
    cmp     al, 'z'
    ja      .cf_filt_no_f2
    sub     al, 32
.cf_filt_no_f2:

    cmp     cl, al
    jb      .cf_filt_less
    ja      .cf_filt_greater
    jmp     .cf_filt_loop

.cf_filt_s1_end:
.cf_filt_s1_check:
    cmp     r9, r15
    jge     .cf_return_zero
    movzx   eax, byte [r14 + r9]
    inc     r9
    test    rbx, FLAG_DICT | KEY_DICT
    jz      .cf_filt_s1_chk_i
    call    is_dict_char
    test    eax, eax
    jz      .cf_filt_s1_check
    jmp     .cf_filt_less
.cf_filt_s1_chk_i:
    test    rbx, FLAG_IGNORE_NP | KEY_IGNORE_NP
    jz      .cf_filt_less
    movzx   eax, byte [r14 + r9 - 1]
    cmp     al, 0x20
    jb      .cf_filt_s1_check
    cmp     al, 0x7E
    ja      .cf_filt_s1_check
    jmp     .cf_filt_less

.cf_filt_s2_end_with_c1:
    mov     eax, 1
    jmp     .cf_return

.cf_filt_less:
    mov     eax, -1
    jmp     .cf_return
.cf_filt_greater:
    mov     eax, 1
    jmp     .cf_return

.cf_numeric:
    mov     rdi, r12
    mov     rsi, r13
    call    parse_sort_number
    push    rax
    push    rdx

    mov     rdi, r14
    mov     rsi, r15
    call    parse_sort_number

    pop     rcx
    pop     r8

    cmp     r8, rax
    jl      .cf_num_less
    jg      .cf_num_greater
    cmp     rcx, rdx
    jl      .cf_num_less
    jg      .cf_num_greater
    xor     eax, eax
    jmp     .cf_return
.cf_num_less:
    mov     eax, -1
    jmp     .cf_return
.cf_num_greater:
    mov     eax, 1
    jmp     .cf_return

.cf_month:
    mov     rdi, r12
    mov     rsi, r13
    call    parse_month
    push    rax
    mov     rdi, r14
    mov     rsi, r15
    call    parse_month
    pop     rcx
    cmp     ecx, eax
    jl      .cf_num_less
    jg      .cf_num_greater
    xor     eax, eax
    jmp     .cf_return

.cf_version:
    xor     r8d, r8d
    xor     r9d, r9d

.cf_ver_loop:
    cmp     r8, r13
    jge     .cf_ver_s1_end
    cmp     r9, r15
    jge     .cf_ver_s2_end

    movzx   eax, byte [r12 + r8]
    movzx   ecx, byte [r14 + r9]

    sub     eax, '0'
    cmp     eax, 9
    ja      .cf_ver_not_digit1
    sub     ecx, '0'
    cmp     ecx, 9
    ja      .cf_ver_mixed

    push    r8
    push    r9
.cf_ver_skip0_1:
    cmp     r8, r13
    jge     .cf_ver_num_cmp
    cmp     byte [r12 + r8], '0'
    jne     .cf_ver_num_cmp
    inc     r8
    jmp     .cf_ver_skip0_1

.cf_ver_num_cmp:
    mov     rax, r8
.cf_ver_cnt1:
    cmp     rax, r13
    jge     .cf_ver_cnt1_done
    movzx   ecx, byte [r12 + rax]
    sub     ecx, '0'
    cmp     ecx, 9
    ja      .cf_ver_cnt1_done
    inc     rax
    jmp     .cf_ver_cnt1
.cf_ver_cnt1_done:
    mov     r10, rax
    sub     r10, r8

    pop     r9
    push    r9
.cf_ver_skip0_2:
    cmp     r9, r15
    jge     .cf_ver_cnt2
    cmp     byte [r14 + r9], '0'
    jne     .cf_ver_cnt2
    inc     r9
    jmp     .cf_ver_skip0_2

.cf_ver_cnt2:
    mov     rax, r9
.cf_ver_cnt2_loop:
    cmp     rax, r15
    jge     .cf_ver_cnt2_done
    movzx   ecx, byte [r14 + rax]
    sub     ecx, '0'
    cmp     ecx, 9
    ja      .cf_ver_cnt2_done
    inc     rax
    jmp     .cf_ver_cnt2_loop
.cf_ver_cnt2_done:
    mov     r11, rax
    sub     r11, r9

    cmp     r10, r11
    jg      .cf_ver_pop_greater
    jl      .cf_ver_pop_less

.cf_ver_digit_cmp:
    test    r10, r10
    jz      .cf_ver_digits_equal
    movzx   eax, byte [r12 + r8]
    movzx   ecx, byte [r14 + r9]
    cmp     eax, ecx
    jg      .cf_ver_pop_greater
    jl      .cf_ver_pop_less
    inc     r8
    inc     r9
    dec     r10
    jmp     .cf_ver_digit_cmp

.cf_ver_digits_equal:
    pop     r9
    pop     r8
    ; Advance r8 past all digits in string 1
.cf_ver_adv1:
    cmp     r8, r13
    jge     .cf_ver_adv2
    movzx   eax, byte [r12 + r8]
    sub     eax, '0'
    cmp     eax, 9
    ja      .cf_ver_adv2
    inc     r8
    jmp     .cf_ver_adv1
.cf_ver_adv2:
    cmp     r9, r15
    jge     .cf_ver_loop
    movzx   eax, byte [r14 + r9]
    sub     eax, '0'
    cmp     eax, 9
    ja      .cf_ver_loop
    inc     r9
    jmp     .cf_ver_adv2

.cf_ver_pop_greater:
    pop     r9
    pop     r8
    mov     eax, 1
    jmp     .cf_return

.cf_ver_pop_less:
    pop     r9
    pop     r8
    mov     eax, -1
    jmp     .cf_return

.cf_ver_not_digit1:
    add     eax, '0'
    cmp     al, cl
    jb      .cf_filt_less
    ja      .cf_filt_greater
    inc     r8
    inc     r9
    jmp     .cf_ver_loop

.cf_ver_mixed:
    add     ecx, '0'
    add     eax, '0'
    cmp     al, cl
    jb      .cf_filt_less
    ja      .cf_filt_greater
    inc     r8
    inc     r9
    jmp     .cf_ver_loop

.cf_ver_s1_end:
    cmp     r9, r15
    jge     .cf_return_zero
    mov     eax, -1
    jmp     .cf_return

.cf_ver_s2_end:
    mov     eax, 1
    jmp     .cf_return


; ============================================================================
;  parse_sort_number
; ============================================================================
parse_sort_number:
    push    rbx
    push    r12

    mov     r12, rdi
    mov     rbx, rsi
    xor     eax, eax
    xor     edx, edx
    xor     ecx, ecx

.psn_skip_ws:
    test    rbx, rbx
    jz      .psn_done
    cmp     byte [r12], ' '
    je      .psn_skip
    cmp     byte [r12], 9
    je      .psn_skip
    jmp     .psn_check_sign
.psn_skip:
    inc     r12
    dec     rbx
    jmp     .psn_skip_ws

.psn_check_sign:
    test    rbx, rbx
    jz      .psn_done
    cmp     byte [r12], '-'
    je      .psn_neg
    cmp     byte [r12], '+'
    je      .psn_pos
    jmp     .psn_digits
.psn_neg:
    mov     ecx, 1
    inc     r12
    dec     rbx
    jmp     .psn_digits
.psn_pos:
    inc     r12
    dec     rbx

.psn_digits:
.psn_int_loop:
    test    rbx, rbx
    jz      .psn_apply_sign
    movzx   r8d, byte [r12]
    sub     r8d, '0'
    cmp     r8d, 9
    ja      .psn_check_dot
    imul    rax, 10
    add     rax, r8
    inc     r12
    dec     rbx
    jmp     .psn_int_loop

.psn_check_dot:
    cmp     byte [r12], '.'
    jne     .psn_apply_sign
    inc     r12
    dec     rbx
    jmp     .psn_apply_sign

.psn_apply_sign:
    test    ecx, ecx
    jz      .psn_done
    neg     rax
    neg     rdx

.psn_done:
    pop     r12
    pop     rbx
    ret


; ============================================================================
;  parse_month
; ============================================================================
parse_month:
    push    rbx
    push    r12
    push    r13

    mov     r12, rdi
    mov     r13, rsi

.pm_skip:
    test    r13, r13
    jz      .pm_unknown
    cmp     byte [r12], ' '
    je      .pm_skip_next
    cmp     byte [r12], 9
    je      .pm_skip_next
    jmp     .pm_check
.pm_skip_next:
    inc     r12
    dec     r13
    jmp     .pm_skip

.pm_check:
    cmp     r13, 3
    jb      .pm_unknown

    movzx   eax, byte [r12]
    call    to_upper_al
    mov     bl, al
    movzx   eax, byte [r12+1]
    call    to_upper_al
    mov     bh, al
    movzx   eax, byte [r12+2]
    call    to_upper_al
    mov     cl, al

    lea     rdx, [month_names]
    mov     r8d, 1

.pm_cmp_loop:
    cmp     r8d, 13
    jge     .pm_unknown
    cmp     bl, [rdx]
    jne     .pm_next
    cmp     bh, [rdx+1]
    jne     .pm_next
    cmp     cl, [rdx+2]
    jne     .pm_next
    mov     eax, r8d
    pop     r13
    pop     r12
    pop     rbx
    ret

.pm_next:
    add     rdx, 4
    inc     r8d
    jmp     .pm_cmp_loop

.pm_unknown:
    xor     eax, eax
    pop     r13
    pop     r12
    pop     rbx
    ret


to_upper_al:
    cmp     al, 'a'
    jb      .tu_done
    cmp     al, 'z'
    ja      .tu_done
    sub     al, 32
.tu_done:
    ret


is_dict_char:
    cmp     al, ' '
    je      .idc_yes
    cmp     al, 9
    je      .idc_yes
    cmp     al, '0'
    jb      .idc_no
    cmp     al, '9'
    jbe     .idc_yes
    cmp     al, 'A'
    jb      .idc_no
    cmp     al, 'Z'
    jbe     .idc_yes
    cmp     al, 'a'
    jb      .idc_no
    cmp     al, 'z'
    jbe     .idc_yes
.idc_no:
    xor     eax, eax
    ret
.idc_yes:
    mov     eax, 1
    ret


; ============================================================================
;  extract_key / find_field_start / find_field_end
; ============================================================================
extract_key:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15

    mov     r12, rdi
    mov     r13, rsi
    mov     r14, rdx
    mov     r15, rcx

    test    r14, r14
    jz      .ek_whole_line

    mov     rdi, r12
    mov     rsi, r13
    mov     rdx, r14
    call    find_field_start
    mov     rbx, rax

    test    r15, r15
    jz      .ek_no_start_char
    dec     r15
    add     rbx, r15
    cmp     rbx, r13
    jbe     .ek_no_start_char
    mov     rbx, r13
.ek_no_start_char:

    cmp     r8, 0
    je      .ek_to_eol

    mov     rdi, r12
    mov     rsi, r13
    mov     rdx, r8
    call    find_field_end
    mov     rcx, rax

    test    r9, r9
    jz      .ek_end_ok
    mov     rdi, r12
    mov     rsi, r13
    mov     rdx, r8
    call    find_field_start
    add     rax, r9
    cmp     rax, r13
    jbe     .ek_use_end_char
    mov     rax, r13
.ek_use_end_char:
    mov     rcx, rax

.ek_end_ok:
    cmp     rbx, rcx
    jge     .ek_empty
    lea     rax, [r12 + rbx]
    mov     rdx, rcx
    sub     rdx, rbx
    jmp     .ek_done

.ek_to_eol:
    lea     rax, [r12 + rbx]
    mov     rdx, r13
    sub     rdx, rbx
    cmp     rdx, 0
    jge     .ek_done
    xor     edx, edx
    jmp     .ek_done

.ek_whole_line:
    mov     rax, r12
    mov     rdx, r13
    jmp     .ek_done

.ek_empty:
    lea     rax, [r12 + r13]
    xor     edx, edx

.ek_done:
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret


find_field_start:
    push    rbx
    push    r12

    mov     r12, rdx
    xor     eax, eax
    mov     rbx, 1

    cmp     r12, 1
    jle     .ffs_done

    cmp     byte [has_separator], 1
    je      .ffs_sep_loop

.ffs_skip_content:
    cmp     rax, rsi
    jge     .ffs_done
    cmp     byte [rdi + rax], ' '
    je      .ffs_in_blanks
    cmp     byte [rdi + rax], 9
    je      .ffs_in_blanks
    inc     rax
    jmp     .ffs_skip_content

.ffs_in_blanks:
.ffs_skip_blanks:
    cmp     rax, rsi
    jge     .ffs_done
    cmp     byte [rdi + rax], ' '
    je      .ffs_sb
    cmp     byte [rdi + rax], 9
    je      .ffs_sb
    jmp     .ffs_next_field
.ffs_sb:
    inc     rax
    jmp     .ffs_skip_blanks

.ffs_next_field:
    inc     rbx
    cmp     rbx, r12
    jge     .ffs_done
    jmp     .ffs_skip_content

.ffs_sep_loop:
    movzx   ecx, byte [separator]
.ffs_sep_scan:
    cmp     rax, rsi
    jge     .ffs_done
    cmp     byte [rdi + rax], cl
    je      .ffs_sep_found
    inc     rax
    jmp     .ffs_sep_scan

.ffs_sep_found:
    inc     rax
    inc     rbx
    cmp     rbx, r12
    jge     .ffs_done
    jmp     .ffs_sep_scan

.ffs_done:
    pop     r12
    pop     rbx
    ret


find_field_end:
    push    rbx
    push    r12

    mov     r12, rdx
    call    find_field_start

    cmp     byte [has_separator], 1
    je      .ffe_sep

.ffe_blank_end:
    cmp     rax, rsi
    jge     .ffe_done
    cmp     byte [rdi + rax], ' '
    je      .ffe_done
    cmp     byte [rdi + rax], 9
    je      .ffe_done
    inc     rax
    jmp     .ffe_blank_end

.ffe_sep:
    movzx   ecx, byte [separator]
.ffe_sep_scan:
    cmp     rax, rsi
    jge     .ffe_done
    cmp     byte [rdi + rax], cl
    je      .ffe_done
    inc     rax
    jmp     .ffe_sep_scan

.ffe_done:
    pop     r12
    pop     rbx
    ret


; ============================================================================
;  write_output — Write sorted lines to output
; ============================================================================
write_output:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15

    mov     r12, [line_array]
    mov     r13, [line_count]
    xor     r14d, r14d
    movzx   ebx, byte [line_delim]

    test    r13, r13
    jz      .wo_done

    test    qword [flag_bits], FLAG_UNIQUE
    jnz     .wo_unique_loop

.wo_loop:
    cmp     r14, r13
    jge     .wo_done

    mov     rax, r14
    shl     rax, 4
    mov     rdi, [r12 + rax]
    mov     rsi, [r12 + rax + 8]
    call    outbuf_write

    lea     rdi, [line_delim]
    mov     rsi, 1
    call    outbuf_write

    inc     r14
    jmp     .wo_loop

.wo_unique_loop:
    cmp     r14, r13
    jge     .wo_done

    mov     rax, r14
    shl     rax, 4
    mov     rdi, [r12 + rax]
    mov     rsi, [r12 + rax + 8]
    call    outbuf_write

    lea     rdi, [line_delim]
    mov     rsi, 1
    call    outbuf_write

.wo_skip_dup:
    mov     rax, r14
    inc     rax
    cmp     rax, r13
    jge     .wo_uniq_next

    push    rax
    mov     rcx, r14
    shl     rcx, 4
    mov     rdi, [r12 + rcx]
    mov     rsi, [r12 + rcx + 8]
    mov     rcx, rax
    shl     rcx, 4
    mov     rdx, [r12 + rcx]
    mov     rcx, [r12 + rcx + 8]
    call    compare_lines
    mov     ecx, eax
    pop     rax
    test    ecx, ecx
    jnz     .wo_uniq_next
    mov     r14, rax
    jmp     .wo_skip_dup

.wo_uniq_next:
    mov     r14, rax
    cmp     r14, r13
    jl      .wo_unique_loop

.wo_done:
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret


; ============================================================================
;  outbuf_write / flush_outbuf
; ============================================================================
outbuf_write:
    push    rbx
    push    r12

    mov     rbx, rdi
    mov     r12, rsi

.obw_loop:
    test    r12, r12
    jz      .obw_done

    mov     rax, [outbuf_pos]
    mov     rcx, OUTBUF_SIZE
    sub     rcx, rax

    mov     rdx, r12
    cmp     rdx, rcx
    jbe     .obw_copy
    mov     rdx, rcx

.obw_copy:
    push    rdx
    lea     rdi, [outbuf]
    add     rdi, [outbuf_pos]
    mov     rsi, rbx
    mov     rcx, rdx
    rep movsb
    pop     rdx

    add     [outbuf_pos], rdx
    add     rbx, rdx
    sub     r12, rdx

    cmp     qword [outbuf_pos], OUTBUF_SIZE
    jb      .obw_loop
    call    flush_outbuf
    jmp     .obw_loop

.obw_done:
    pop     r12
    pop     rbx
    ret


flush_outbuf:
    mov     rdx, [outbuf_pos]
    test    rdx, rdx
    jz      .fob_done
    mov     rdi, [output_fd]
    lea     rsi, [outbuf]
    call    asm_write_all
    test    rax, rax
    js      .fob_error
    mov     qword [outbuf_pos], 0
.fob_done:
    ret
.fob_error:
    mov     edi, 2
    call    asm_exit


; ============================================================================
;  check_sorted
; ============================================================================
check_sorted:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15

    call    read_all_input
    test    rax, rax
    js      .cs_error
    call    scan_lines

    mov     r12, [line_array]
    mov     r13, [line_count]

    cmp     r13, 2
    jl      .cs_sorted

    mov     r14, 1

.cs_loop:
    cmp     r14, r13
    jge     .cs_sorted

    mov     rax, r14
    dec     rax
    shl     rax, 4
    mov     rdi, [r12 + rax]
    mov     rsi, [r12 + rax + 8]
    mov     rax, r14
    shl     rax, 4
    mov     rdx, [r12 + rax]
    mov     rcx, [r12 + rax + 8]
    call    compare_lines

    test    qword [flag_bits], FLAG_UNIQUE
    jnz     .cs_strict
    test    eax, eax
    jg      .cs_unsorted
    jmp     .cs_next

.cs_strict:
    test    eax, eax
    jge     .cs_unsorted

.cs_next:
    inc     r14
    jmp     .cs_loop

.cs_sorted:
    xor     edi, edi
    call    asm_exit

.cs_unsorted:
    test    qword [flag_bits], FLAG_CHECK_Q
    jnz     .cs_unsorted_exit

    mov     rdi, STDERR
    lea     rsi, [str_sort_prefix]
    mov     edx, str_sort_prefix_len
    call    asm_write_all

    lea     rax, [files]
    mov     rdi, [rax]
    call    asm_strlen
    mov     rdx, rax
    lea     rax, [files]
    mov     rsi, [rax]
    mov     rdi, STDERR
    call    asm_write_all

    mov     rdi, STDERR
    lea     rsi, [str_colon]
    mov     edx, 1
    call    asm_write_all

    lea     rdi, [r14 + 1]
    lea     rsi, [errbuf]
    call    asm_itoa_local
    mov     rdx, rax
    mov     rdi, STDERR
    lea     rsi, [errbuf]
    call    asm_write_all

    mov     rdi, STDERR
    lea     rsi, [str_disorder_sep]
    mov     edx, str_disorder_sep_len
    call    asm_write_all

    mov     rdi, STDERR
    mov     rax, r14
    shl     rax, 4
    mov     rsi, [r12 + rax]
    mov     rdx, [r12 + rax + 8]
    call    asm_write_all

    mov     rdi, STDERR
    lea     rsi, [str_newline]
    mov     edx, 1
    call    asm_write_all

.cs_unsorted_exit:
    mov     edi, 1
    call    asm_exit

.cs_error:
    mov     edi, 2
    call    asm_exit


; ============================================================================
;  asm_itoa_local
; ============================================================================
asm_itoa_local:
    push    rbx
    mov     rax, rdi
    mov     rbx, rsi

    test    rax, rax
    jnz     .ail_convert
    mov     byte [rsi], '0'
    mov     rax, 1
    pop     rbx
    ret

.ail_convert:
    mov     r8, rsi
.ail_digit:
    xor     edx, edx
    mov     rcx, 10
    div     rcx
    add     dl, '0'
    mov     [rsi], dl
    inc     rsi
    test    rax, rax
    jnz     .ail_digit

    mov     rax, rsi
    sub     rax, r8

    dec     rsi
    mov     rdi, r8
.ail_rev:
    cmp     rdi, rsi
    jge     .ail_done
    mov     cl, [rdi]
    mov     ch, [rsi]
    mov     [rdi], ch
    mov     [rsi], cl
    inc     rdi
    dec     rsi
    jmp     .ail_rev

.ail_done:
    pop     rbx
    ret


; ============================================================================
;  str_equal / str_starts_with
; ============================================================================
str_equal:
.se_loop:
    movzx   eax, byte [rdi]
    movzx   ecx, byte [rsi]
    cmp     al, cl
    jne     .se_not_equal
    test    al, al
    jz      .se_equal
    inc     rdi
    inc     rsi
    jmp     .se_loop
.se_equal:
    mov     eax, 1
    ret
.se_not_equal:
    xor     eax, eax
    ret


str_starts_with:
.ssw_loop:
    movzx   ecx, byte [rsi]
    test    cl, cl
    jz      .ssw_yes
    movzx   eax, byte [rdi]
    cmp     al, cl
    jne     .ssw_no
    inc     rdi
    inc     rsi
    jmp     .ssw_loop
.ssw_yes:
    mov     eax, 1
    ret
.ssw_no:
    xor     eax, eax
    ret


; ===============================================================
; DATA SECTION (read-only strings, embedded in code segment)
; ===============================================================

align 16

str_help:
    db "Usage: sort [OPTION]... [FILE]...", 10
    db "  or:  sort [OPTION]... --files0-from=F", 10
    db "Write sorted concatenation of all FILE(s) to standard output.", 10
    db 10
    db "With no FILE, or when FILE is -, read standard input.", 10
    db 10
    db "Mandatory arguments to long options are mandatory for short options too.", 10
    db "Ordering options:", 10
    db 10
    db "  -b, --ignore-leading-blanks  ignore leading blanks", 10
    db "  -d, --dictionary-order       consider only blanks and alphanumeric characters", 10
    db "  -f, --ignore-case            fold lower case to upper case characters", 10
    db "  -g, --general-numeric-sort   compare according to general numerical value", 10
    db "  -i, --ignore-nonprinting     consider only printable characters", 10
    db "  -M, --month-sort             compare (unknown) < 'JAN' < ... < 'DEC'", 10
    db "  -h, --human-numeric-sort     compare human readable numbers (e.g., 2K 1G)", 10
    db "  -n, --numeric-sort           compare according to string numerical value", 10
    db "  -R, --random-sort            shuffle, but group identical keys.  See shuf(1)", 10
    db "      --random-source=FILE     get random bytes from FILE", 10
    db "  -r, --reverse                reverse the result of comparisons", 10
    db "  -V, --version-sort           natural sort of (version) numbers within text", 10
    db 10
    db "Other options:", 10
    db 10
    db "      --batch-size=NMERGE   use at most NMERGE inputs at once; for more use temp files", 10
    db "  -c, --check, --check=diagnose-first  check for sorted input; do not sort", 10
    db "  -C, --check=quiet, --check=silent  like -c, but do not report first bad line", 10
    db "      --compress-program=PROG  compress temporaries with PROG;", 10
    db "                              decompress them with PROG -d", 10
    db "      --debug                  annotate the part of the line used to sort,", 10
    db "                              and warn about questionable usage to stderr", 10
    db "      --files0-from=F          read input from the files specified by", 10
    db "                              NUL-terminated names in file F;", 10
    db "                              If F is - then read names from standard input", 10
    db "  -k, --key=KEYDEF            sort via a key; KEYDEF gives location and type", 10
    db "  -m, --merge                  merge already sorted files; do not sort", 10
    db "  -o, --output=FILE            write result to FILE instead of standard output", 10
    db "  -s, --stable                 stabilize sort by disabling last-resort comparison", 10
    db "  -S, --buffer-size=SIZE       use SIZE for main memory buffer", 10
    db "  -t, --field-separator=SEP    use SEP instead of non-blank to blank transition", 10
    db "  -T, --temporary-directory=DIR  use DIR for temporaries, not $TMPDIR or default;", 10
    db "                              multiple options specify multiple directories", 10
    db "      --parallel=N             change the number of sorts run concurrently to N", 10
    db "  -u, --unique                 with -c, check for strict ordering;", 10
    db "                              without -c, output only the first of an equal run", 10
    db "  -z, --zero-terminated        line delimiter is NUL, not newline", 10
    db "      --help        display this help and exit", 10
    db "      --version     output version information and exit", 10
    db 10
    db "KEYDEF is F[.C][OPTS][,F[.C][OPTS]] for start and stop position, where F is a", 10
    db "field number and C a character position (counted from 1 in the respective field);", 10
    db "both are origin 1.  If neither -t nor -b is in effect, characters in a field are", 10
    db "counted from the beginning of the preceding whitespace.  OPTS is one or more", 10
    db "single-letter ordering options [bdfgiMhnRrV], which override global ordering", 10
    db "options for that key.  If no key is given, use the entire line as the key.", 10
    db "Use --debug to diagnose incorrect key usage.", 10
    db 10
    db "SIZE may be followed by the following multiplicative suffixes:", 10
    db "% 1% of memory, b 1, K 1024 (default), and so on for M, G, T, P, E, Z, Y, R, Q.", 10
    db 10
    db "*** WARNING ***", 10
    db "The locale specified by the environment affects sort order.", 10
    db "Set LC_ALL=C to get the traditional sort order that uses", 10
    db "native byte values.", 10
    db 10
    db "GNU coreutils online help: <https://www.gnu.org/software/coreutils/>", 10
    db "Full documentation <https://www.gnu.org/software/coreutils/sort>", 10
    db "or available locally via: info '(coreutils) sort invocation'", 10
str_help_len equ $ - str_help

str_version:
    db "sort (GNU coreutils) 9.7", 10
    db "Copyright (C) 2025 Free Software Foundation, Inc.", 10
    db "License GPLv3+: GNU GPL version 3 or later <https://gnu.org/licenses/gpl.html>.", 10
    db "This is free software: you are free to change and redistribute it.", 10
    db "There is NO WARRANTY, to the extent permitted by law.", 10
    db 10
    db "Written by Mike Haertel and Paul Eggert.", 10
str_version_len equ $ - str_version

str_sort_prefix: db "sort: ", 0
str_sort_prefix_len equ 6

str_try_help:
    db "Try 'sort --help' for more information.", 10
str_try_help_len equ $ - str_try_help

str_inv_opt:    db "invalid option -- '", 0
str_inv_opt2:   db "'", 10, 0

str_unrec_opt:  db "unrecognized option '", 0
str_unrec_opt2: db "'", 10, 0

str_enoent:     db ": No such file or directory", 10, 0
str_read_err:   db ": read error", 10, 0
str_write_err:  db "write error", 10, 0
str_open_err:   db ": open failed", 10, 0
str_extra_key:  db ": invalid number after ','", 10, 0
str_empty_key:  db "option requires an argument -- 'k'", 10, 0
str_empty_out:  db "option requires an argument -- 'o'", 10, 0
str_empty_sep:  db "option requires an argument -- 't'", 10, 0
str_multi_sep:  db "multi-character tab ", 0
str_disorder1:  db "disorder: ", 0
str_disorder1_len equ $ - str_disorder1

str_colon:      db ":", 0
str_disorder_sep: db ": disorder: "
str_disorder_sep_len equ $ - str_disorder_sep

str_colon_sp:   db ": ", 0
str_newline:    db 10, 0
str_dash:       db "-", 0

; Long option strings
opt_help:             db "--help", 0
opt_version:          db "--version", 0
opt_reverse:          db "--reverse", 0
opt_unique:           db "--unique", 0
opt_numeric:          db "--numeric-sort", 0
opt_stable:           db "--stable", 0
opt_check:            db "--check", 0
opt_check_eq:         db "--check=", 0
opt_check_diag:       db "diagnose-first", 0
opt_check_quiet:      db "quiet", 0
opt_check_silent:     db "silent", 0
opt_ignore_case:      db "--ignore-case", 0
opt_dictionary:       db "--dictionary-order", 0
opt_ignore_np:        db "--ignore-nonprinting", 0
opt_ignore_blanks:    db "--ignore-leading-blanks", 0
opt_merge:            db "--merge", 0
opt_zero_terminated:  db "--zero-terminated", 0
opt_output:           db "--output", 0
opt_output_eq:        db "--output=", 0
opt_key:              db "--key", 0
opt_key_eq:           db "--key=", 0
opt_field_sep:        db "--field-separator", 0
opt_field_sep_eq:     db "--field-separator=", 0
opt_gen_numeric:      db "--general-numeric-sort", 0
opt_month_sort:       db "--month-sort", 0
opt_human_sort:       db "--human-numeric-sort", 0
opt_version_sort:     db "--version-sort", 0

; Month name table (uppercase, 3 chars each)
month_names:
    db "JAN", 0    ; 1
    db "FEB", 0    ; 2
    db "MAR", 0    ; 3
    db "APR", 0    ; 4
    db "MAY", 0    ; 5
    db "JUN", 0    ; 6
    db "JUL", 0    ; 7
    db "AUG", 0    ; 8
    db "SEP", 0    ; 9
    db "OCT", 0    ; 10
    db "NOV", 0    ; 11
    db "DEC", 0    ; 12

; ===============================================================
; BSS (uninitialized data — zero-filled by ELF loader)
; ===============================================================
file_size equ $ - $$

bss_base        equ $$ + file_size

; Command-line state (offset 0)
argc            equ bss_base + 0            ; 8 bytes
argv            equ bss_base + 8            ; 8 bytes
flag_bits       equ bss_base + 16           ; 8 bytes
nfiles          equ bss_base + 24           ; 8 bytes
files           equ bss_base + 32           ; MAX_FILES * 8 = 2048 bytes
output_file     equ files + 2048            ; 8 bytes  (offset 2080)
output_fd       equ output_file + 8         ; 8 bytes  (offset 2088)
separator       equ output_fd + 8           ; 2 bytes  (offset 2096)
has_separator   equ separator + 2           ; 1 byte   (offset 2098)
line_delim      equ has_separator + 1       ; 1 byte   (offset 2099)

; Sort keys (offset 2100, aligned to 8)
nkeys           equ bss_base + 2104         ; 8 bytes
keys            equ nkeys + 8               ; MAX_KEYS * KEY_STRUCT_SIZE = 32*40 = 1280 bytes

; Input data (offset ~3392)
input_buf       equ keys + 1280             ; 8 bytes
input_size      equ input_buf + 8           ; 8 bytes
input_cap       equ input_size + 8          ; 8 bytes

; Line pointer array
line_array      equ input_cap + 8           ; 8 bytes
line_count      equ line_array + 8          ; 8 bytes
line_cap        equ line_count + 8          ; 8 bytes

; Output buffer
outbuf_pos      equ line_cap + 8            ; 8 bytes
outbuf          equ outbuf_pos + 8          ; OUTBUF_SIZE = 262144 bytes

; Stat buffer
stat_buf        equ outbuf + OUTBUF_SIZE    ; STAT_STRUCT_SIZE = 144 bytes

; Merge sort temp array
merge_temp      equ stat_buf + STAT_STRUCT_SIZE  ; 8 bytes

; Flag for fast-path comparison
use_simple_cmp  equ merge_temp + 8          ; 8 bytes

; Temp buffer for error messages
errbuf          equ use_simple_cmp + 8      ; 512 bytes

bss_end         equ errbuf + 512
mem_size        equ bss_end - $$
