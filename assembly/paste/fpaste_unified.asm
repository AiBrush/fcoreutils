; ============================================================
; fpaste_unified.asm — GNU-compatible 'paste' command
; Single nasm -f bin file with hand-crafted ELF header.
;
; Supports: -d (delimiter list with escape sequences), -s (serial mode),
;           -z (NUL terminator), -- (end options), - (stdin)
;
; BUILD:
;   nasm -f bin fpaste_unified.asm -o fpaste && chmod +x fpaste
; ============================================================

BITS 64
ORG 0x400000

; --- Syscall numbers ---
%define SYS_READ            0
%define SYS_WRITE           1
%define SYS_OPEN            2
%define SYS_CLOSE           3
%define SYS_FSTAT           5
%define SYS_MMAP            9
%define SYS_MUNMAP         11
%define SYS_BRK            12
%define SYS_RT_SIGPROCMASK 14
%define SYS_EXIT           60

%define STDIN               0
%define STDOUT              1
%define STDERR              2

%define O_RDONLY            0
%define SIGPIPE            13
%define SIG_BLOCK           0

%define EINTR              -4
%define EPIPE             -32

%define PROT_READ           1
%define MAP_PRIVATE         2

%define STAT_MODE          24
%define STAT_SIZE          48
%define STAT_STRUCT_SIZE  144

%define S_IFMT          0o170000
%define S_IFREG         0o100000

%define OUT_BUF_SIZE    262144
%define FLUSH_THRESHOLD 131072

%define MAX_FILES       4096
%define MAX_DELIMS      256
%define STDIN_INIT_SIZE 1048576

%define FLAG_SERIAL     0x01
%define FLAG_ZERO_TERM  0x02

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
; I/O Library (inlined from lib/io.asm)
; ===============================================================

; asm_write(rdi=fd, rsi=buf, rdx=len) -> rax
asm_write:
.retry:
    mov     rax, SYS_WRITE
    syscall
    cmp     rax, EINTR
    je      .retry
    ret

; asm_write_all(rdi=fd, rsi=buf, rdx=len) -> rax=0 on success
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
    cmp     rax, EINTR
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
    pop     r13
    pop     r12
    pop     rbx
    ret

; asm_read(rdi=fd, rsi=buf, rdx=len) -> rax
asm_read:
.retry:
    mov     rax, SYS_READ
    syscall
    cmp     rax, EINTR
    je      .retry
    ret

; asm_open(rdi=path, rsi=flags, rdx=mode) -> rax=fd
asm_open:
    mov     rax, SYS_OPEN
    syscall
    ret

; asm_close(rdi=fd) -> rax
asm_close:
    mov     rax, SYS_CLOSE
    syscall
    ret

; asm_fstat(rdi=fd, rsi=stat_buf) -> rax
asm_fstat:
    mov     rax, SYS_FSTAT
    syscall
    ret

; asm_mmap(rdi=addr, rsi=len, rdx=prot, r10=flags, r8=fd, r9=offset) -> rax
asm_mmap:
    mov     rax, SYS_MMAP
    syscall
    ret

; asm_munmap(rdi=addr, rsi=len) -> rax
asm_munmap:
    mov     rax, SYS_MUNMAP
    syscall
    ret

; ===============================================================
; CODE
; ===============================================================

_start:
    ; Block SIGPIPE
    sub     rsp, 16
    mov     qword [rsp], (1 << (SIGPIPE - 1))
    mov     eax, SYS_RT_SIGPROCMASK
    xor     edi, edi            ; SIG_BLOCK
    mov     rsi, rsp
    xor     edx, edx
    mov     r10d, 8
    syscall
    add     rsp, 16

    ; Save argc/argv
    mov     rax, [rsp]
    mov     [argc], rax
    lea     rax, [rsp + 8]
    mov     [argv], rax

    ; Initialize state
    mov     byte [flags], 0
    mov     byte [had_error], 0
    mov     qword [nfiles], 0
    mov     byte [terminator], 10
    mov     byte [delim_buf], 9
    mov     qword [delim_len], 1
    mov     qword [out_buf_pos], 0
    mov     qword [stdin_data], 0
    mov     qword [stdin_size], 0
    mov     qword [stdin_capacity], 0

    ; Parse arguments
    call    parse_args

    ; If no files, use stdin
    cmp     qword [nfiles], 0
    jne     .have_files
    lea     rax, [dash_str]
    mov     [file_ptrs], rax
    mov     qword [nfiles], 1

.have_files:
    test    byte [flags], FLAG_ZERO_TERM
    jz      .term_set
    mov     byte [terminator], 0
.term_set:

    call    check_and_read_stdin
    call    open_all_files
    cmp     byte [had_error], 0
    jne     .exit_with_had_error

    test    byte [flags], FLAG_SERIAL
    jnz     .do_serial

    call    paste_parallel
    jmp     .finish

.do_serial:
    call    paste_serial

.finish:
    call    flush_output
    test    rax, rax
    js      .write_error

    call    close_all_files
    call    free_stdin_buf

.exit_with_had_error:
    movzx   edi, byte [had_error]
    mov     eax, SYS_EXIT
    syscall

.write_error:
    cmp     rax, EPIPE
    je      .epipe_exit
    mov     byte [had_error], 1
    jmp     .finish

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
    push    r15

    mov     r12, [argc]
    mov     r13, [argv]
    mov     rbx, 1
    xor     r14d, r14d          ; seen_dashdash = 0

.pa_loop:
    cmp     rbx, r12
    jge     .pa_done

    mov     rsi, [r13 + rbx*8]

    test    r14d, r14d
    jnz     .pa_is_file

    cmp     byte [rsi], '-'
    jne     .pa_is_file
    cmp     byte [rsi+1], 0
    je      .pa_is_file

    cmp     byte [rsi+1], '-'
    jne     .pa_short_opts

    cmp     byte [rsi+2], 0
    je      .pa_dashdash

    ; Long options
    push    rbx
    push    r12
    push    r13
    push    r14

    mov     rdi, rsi
    lea     rsi, [str_help_opt]
    call    str_eq
    test    eax, eax
    jnz     .pa_do_help

    mov     rsi, [r13 + rbx*8]
    mov     rdi, rsi
    lea     rsi, [str_version_opt]
    call    str_eq
    test    eax, eax
    jnz     .pa_do_version

    mov     rsi, [r13 + rbx*8]
    mov     rdi, rsi
    lea     rsi, [str_serial_opt]
    call    str_eq
    test    eax, eax
    jnz     .pa_do_serial

    mov     rsi, [r13 + rbx*8]
    mov     rdi, rsi
    lea     rsi, [str_zero_opt]
    call    str_eq
    test    eax, eax
    jnz     .pa_do_zero

    mov     rsi, [r13 + rbx*8]
    mov     rdi, rsi
    lea     rsi, [str_delimiters_eq]
    mov     ecx, 13
    call    str_has_prefix
    test    eax, eax
    jnz     .pa_do_delim_eq

    mov     rsi, [r13 + rbx*8]
    mov     rdi, rsi
    lea     rsi, [str_delimiters_opt]
    call    str_eq
    test    eax, eax
    jnz     .pa_do_delim_next

    mov     rdi, [r13 + rbx*8]
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    call    err_unrecognized_option
    mov     edi, 1
    mov     eax, SYS_EXIT
    syscall

.pa_do_help:
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    mov     rdi, STDOUT
    lea     rsi, [help_text]
    mov     rdx, help_text_len
    call    asm_write_all
    xor     edi, edi
    mov     eax, SYS_EXIT
    syscall

.pa_do_version:
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    mov     rdi, STDOUT
    lea     rsi, [version_text]
    mov     rdx, version_text_len
    call    asm_write_all
    xor     edi, edi
    mov     eax, SYS_EXIT
    syscall

.pa_do_serial:
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    or      byte [flags], FLAG_SERIAL
    jmp     .pa_next

.pa_do_zero:
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    or      byte [flags], FLAG_ZERO_TERM
    jmp     .pa_next

.pa_do_delim_eq:
    mov     rdi, [r13 + rbx*8]
    add     rdi, 13
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    call    parse_delimiters
    jmp     .pa_next

.pa_do_delim_next:
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    inc     rbx
    cmp     rbx, r12
    jge     .pa_delim_missing
    mov     rdi, [r13 + rbx*8]
    call    parse_delimiters
    jmp     .pa_next

.pa_delim_missing:
    mov     rdi, STDERR
    lea     rsi, [str_delim_missing]
    mov     rdx, str_delim_missing_len
    call    asm_write_all
    mov     edi, 1
    mov     eax, SYS_EXIT
    syscall

.pa_dashdash:
    mov     r14d, 1
    jmp     .pa_next

.pa_short_opts:
    mov     rcx, 1

.pa_short_loop:
    movzx   eax, byte [rsi + rcx]
    test    al, al
    jz      .pa_next

    cmp     al, 's'
    je      .pa_flag_s
    cmp     al, 'z'
    je      .pa_flag_z
    cmp     al, 'd'
    je      .pa_flag_d

    push    rsi
    push    rcx
    movzx   esi, al
    call    err_invalid_option
    mov     edi, 1
    mov     eax, SYS_EXIT
    syscall

.pa_flag_s:
    or      byte [flags], FLAG_SERIAL
    inc     rcx
    jmp     .pa_short_loop

.pa_flag_z:
    or      byte [flags], FLAG_ZERO_TERM
    inc     rcx
    jmp     .pa_short_loop

.pa_flag_d:
    inc     rcx
    movzx   eax, byte [rsi + rcx]
    test    al, al
    jnz     .pa_d_inline

    inc     rbx
    cmp     rbx, r12
    jge     .pa_d_missing
    mov     rdi, [r13 + rbx*8]
    call    parse_delimiters
    jmp     .pa_next

.pa_d_inline:
    push    rsi
    lea     rdi, [rsi + rcx]
    call    parse_delimiters
    pop     rsi
    jmp     .pa_next

.pa_d_missing:
    mov     rdi, STDERR
    lea     rsi, [str_d_missing]
    mov     rdx, str_d_missing_len
    call    asm_write_all
    mov     edi, 1
    mov     eax, SYS_EXIT
    syscall

.pa_is_file:
    mov     rax, [nfiles]
    cmp     rax, MAX_FILES
    jge     .pa_next
    lea     rcx, [file_ptrs]
    mov     [rcx + rax*8], rsi
    inc     qword [nfiles]

.pa_next:
    inc     rbx
    jmp     .pa_loop

.pa_done:
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

; ============================================================================
;  parse_delimiters(rdi=string)
; ============================================================================
parse_delimiters:
    push    rbx
    push    r12
    lea     r12, [delim_buf]
    xor     ebx, ebx

.pd_loop:
    movzx   eax, byte [rdi]
    test    al, al
    jz      .pd_done

    cmp     al, '\'
    jne     .pd_literal

    movzx   ecx, byte [rdi+1]
    test    cl, cl
    jz      .pd_literal_backslash

    cmp     cl, 'n'
    je      .pd_esc_n
    cmp     cl, 't'
    je      .pd_esc_t
    cmp     cl, '\'
    je      .pd_esc_backslash
    cmp     cl, '0'
    je      .pd_esc_nul

    jmp     .pd_literal_backslash

.pd_esc_n:
    cmp     ebx, MAX_DELIMS
    jge     .pd_done
    mov     byte [r12 + rbx], 10
    inc     ebx
    add     rdi, 2
    jmp     .pd_loop

.pd_esc_t:
    cmp     ebx, MAX_DELIMS
    jge     .pd_done
    mov     byte [r12 + rbx], 9
    inc     ebx
    add     rdi, 2
    jmp     .pd_loop

.pd_esc_backslash:
    cmp     ebx, MAX_DELIMS
    jge     .pd_done
    mov     byte [r12 + rbx], '\'
    inc     ebx
    add     rdi, 2
    jmp     .pd_loop

.pd_esc_nul:
    cmp     ebx, MAX_DELIMS
    jge     .pd_done
    mov     byte [r12 + rbx], 0
    inc     ebx
    add     rdi, 2
    jmp     .pd_loop

.pd_literal_backslash:
    cmp     ebx, MAX_DELIMS
    jge     .pd_done
    mov     byte [r12 + rbx], '\'
    inc     ebx
    inc     rdi
    jmp     .pd_loop

.pd_literal:
    cmp     ebx, MAX_DELIMS
    jge     .pd_done
    mov     [r12 + rbx], al
    inc     ebx
    inc     rdi
    jmp     .pd_loop

.pd_done:
    mov     [delim_len], rbx
    pop     r12
    pop     rbx
    ret

; ============================================================================
;  check_and_read_stdin
; ============================================================================
check_and_read_stdin:
    push    rbx
    push    r12

    mov     r12, [nfiles]
    xor     ebx, ebx
.cas_loop:
    cmp     rbx, r12
    jge     .cas_no_stdin

    lea     rax, [file_ptrs]
    mov     rdi, [rax + rbx*8]
    cmp     byte [rdi], '-'
    jne     .cas_next
    cmp     byte [rdi+1], 0
    je      .cas_need_stdin

.cas_next:
    inc     rbx
    jmp     .cas_loop

.cas_need_stdin:
    mov     eax, SYS_BRK
    xor     edi, edi
    syscall
    mov     [stdin_data], rax
    mov     r12, rax

    lea     rdi, [rax + STDIN_INIT_SIZE]
    mov     eax, SYS_BRK
    syscall
    sub     rax, r12
    mov     [stdin_capacity], rax

    xor     ebx, ebx
.cas_read_loop:
    mov     rdi, STDIN
    mov     rsi, [stdin_data]
    add     rsi, rbx
    mov     rdx, [stdin_capacity]
    sub     rdx, rbx
    cmp     rdx, 0
    jle     .cas_grow_buf

    call    asm_read
    test    rax, rax
    js      .cas_read_error
    jz      .cas_read_done

    add     rbx, rax
    jmp     .cas_read_loop

.cas_grow_buf:
    mov     rax, [stdin_capacity]
    shl     rax, 1
    mov     rdi, [stdin_data]
    add     rdi, rax
    mov     eax, SYS_BRK
    syscall
    mov     rdi, [stdin_data]
    sub     rax, rdi
    mov     [stdin_capacity], rax
    jmp     .cas_read_loop

.cas_read_done:
    mov     [stdin_size], rbx

.cas_no_stdin:
    pop     r12
    pop     rbx
    ret

.cas_read_error:
    mov     rdi, STDERR
    lea     rsi, [err_prefix]
    mov     rdx, err_prefix_len
    call    asm_write_all
    mov     rdi, STDERR
    lea     rsi, [str_stdin_name]
    mov     rdx, str_stdin_name_len
    call    asm_write_all
    mov     rdi, STDERR
    lea     rsi, [str_read_error]
    mov     rdx, str_read_error_len
    call    asm_write_all
    mov     byte [had_error], 1
    mov     [stdin_size], rbx
    pop     r12
    pop     rbx
    ret

; ============================================================================
;  free_stdin_buf
; ============================================================================
free_stdin_buf:
    cmp     qword [stdin_data], 0
    je      .fsb_done
    mov     rdi, [stdin_data]
    mov     eax, SYS_BRK
    syscall
.fsb_done:
    ret

; ============================================================================
;  open_all_files
; ============================================================================
open_all_files:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15

    mov     r12, [nfiles]

    xor     ecx, ecx
    xor     ebx, ebx
.oaf_count_stdin:
    cmp     rbx, r12
    jge     .oaf_count_done
    lea     rax, [file_ptrs]
    mov     rdi, [rax + rbx*8]
    cmp     byte [rdi], '-'
    jne     .oaf_count_next
    cmp     byte [rdi+1], 0
    jne     .oaf_count_next
    inc     ecx
.oaf_count_next:
    inc     rbx
    jmp     .oaf_count_stdin

.oaf_count_done:
    mov     [stdin_count], ecx
    mov     qword [stdin_rr_cursor], 0
    mov     dword [stdin_rr_idx], 0

    xor     ebx, ebx
.oaf_loop:
    cmp     rbx, r12
    jge     .oaf_done

    lea     rax, [file_ptrs]
    mov     rdi, [rax + rbx*8]

    cmp     byte [rdi], '-'
    jne     .oaf_open_file
    cmp     byte [rdi+1], 0
    jne     .oaf_open_file

    ; stdin
    mov     rax, [stdin_data]
    lea     rcx, [file_datas]
    mov     [rcx + rbx*8], rax
    mov     rax, [stdin_size]
    lea     rcx, [file_sizes]
    mov     [rcx + rbx*8], rax
    lea     rcx, [file_fds]
    mov     qword [rcx + rbx*8], -1
    lea     rcx, [file_mmapped]
    mov     byte [rcx + rbx], 0
    lea     rcx, [file_is_stdin]
    mov     byte [rcx + rbx], 1
    jmp     .oaf_next

.oaf_open_file:
    lea     rcx, [file_is_stdin]
    mov     byte [rcx + rbx], 0

    push    rbx
    push    r12
    lea     rax, [file_ptrs]
    mov     rdi, [rax + rbx*8]
    xor     esi, esi
    xor     edx, edx
    call    asm_open
    pop     r12
    pop     rbx
    test    rax, rax
    js      .oaf_open_error

    mov     r13, rax

    push    rbx
    push    r12
    lea     rsi, [stat_buf]
    mov     edi, r13d
    call    asm_fstat
    pop     r12
    pop     rbx
    test    rax, rax
    js      .oaf_stat_error

    mov     eax, [stat_buf + STAT_MODE]
    and     eax, S_IFMT
    cmp     eax, S_IFREG
    jne     .oaf_is_dir_check

    mov     r14, [stat_buf + STAT_SIZE]

    lea     rcx, [file_fds]
    mov     [rcx + rbx*8], r13

    test    r14, r14
    jz      .oaf_empty_file

    push    rbx
    push    r12
    xor     edi, edi
    mov     rsi, r14
    mov     edx, PROT_READ
    mov     r10d, MAP_PRIVATE
    mov     r8, r13
    xor     r9d, r9d
    call    asm_mmap
    pop     r12
    pop     rbx
    test    rax, rax
    js      .oaf_mmap_error

    lea     rcx, [file_datas]
    mov     [rcx + rbx*8], rax
    lea     rcx, [file_sizes]
    mov     [rcx + rbx*8], r14
    lea     rcx, [file_mmapped]
    mov     byte [rcx + rbx], 1
    jmp     .oaf_next

.oaf_empty_file:
    lea     rcx, [file_datas]
    mov     qword [rcx + rbx*8], 0
    lea     rcx, [file_sizes]
    mov     qword [rcx + rbx*8], 0
    lea     rcx, [file_mmapped]
    mov     byte [rcx + rbx], 0
    jmp     .oaf_next

.oaf_is_dir_check:
    mov     eax, [stat_buf + STAT_MODE]
    and     eax, S_IFMT
    cmp     eax, 0o40000
    jne     .oaf_read_fallback

    push    rbx
    push    r12
    lea     rax, [file_ptrs]
    mov     rdi, [rax + rbx*8]
    mov     esi, 21
    call    err_file
    pop     r12
    pop     rbx
    mov     byte [had_error], 1

    push    rbx
    mov     rdi, r13
    call    asm_close
    pop     rbx

    lea     rcx, [file_datas]
    mov     qword [rcx + rbx*8], 0
    lea     rcx, [file_sizes]
    mov     qword [rcx + rbx*8], 0
    lea     rcx, [file_fds]
    mov     qword [rcx + rbx*8], -1
    lea     rcx, [file_mmapped]
    mov     byte [rcx + rbx], 0
    jmp     .oaf_next

.oaf_read_fallback:
    push    rbx
    push    r12
    mov     rdi, r13
    call    asm_close
    pop     r12
    pop     rbx

    lea     rcx, [file_datas]
    mov     qword [rcx + rbx*8], 0
    lea     rcx, [file_sizes]
    mov     qword [rcx + rbx*8], 0
    lea     rcx, [file_fds]
    mov     qword [rcx + rbx*8], -1
    lea     rcx, [file_mmapped]
    mov     byte [rcx + rbx], 0
    jmp     .oaf_next

.oaf_open_error:
    neg     rax
    mov     r15d, eax
    push    rbx
    push    r12
    lea     rax, [file_ptrs]
    mov     rdi, [rax + rbx*8]
    mov     esi, r15d
    call    err_file
    pop     r12
    pop     rbx
    mov     byte [had_error], 1

    lea     rcx, [file_datas]
    mov     qword [rcx + rbx*8], 0
    lea     rcx, [file_sizes]
    mov     qword [rcx + rbx*8], 0
    lea     rcx, [file_fds]
    mov     qword [rcx + rbx*8], -1
    lea     rcx, [file_mmapped]
    mov     byte [rcx + rbx], 0
    lea     rcx, [file_is_stdin]
    mov     byte [rcx + rbx], 0

    jmp     .oaf_done

.oaf_stat_error:
    neg     rax
    mov     r15d, eax
    push    rbx
    push    r12
    lea     rax, [file_ptrs]
    mov     rdi, [rax + rbx*8]
    mov     esi, r15d
    call    err_file
    pop     r12
    pop     rbx
    mov     byte [had_error], 1
    push    rbx
    mov     rdi, r13
    call    asm_close
    pop     rbx
    lea     rcx, [file_datas]
    mov     qword [rcx + rbx*8], 0
    lea     rcx, [file_sizes]
    mov     qword [rcx + rbx*8], 0
    lea     rcx, [file_fds]
    mov     qword [rcx + rbx*8], -1
    lea     rcx, [file_mmapped]
    mov     byte [rcx + rbx], 0
    jmp     .oaf_done

.oaf_mmap_error:
    lea     rcx, [file_datas]
    mov     qword [rcx + rbx*8], 0
    lea     rcx, [file_sizes]
    mov     qword [rcx + rbx*8], 0
    lea     rcx, [file_mmapped]
    mov     byte [rcx + rbx], 0
    jmp     .oaf_next

.oaf_next:
    inc     rbx
    jmp     .oaf_loop

.oaf_done:
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

; ============================================================================
;  close_all_files
; ============================================================================
close_all_files:
    push    rbx
    push    r12

    mov     r12, [nfiles]
    xor     ebx, ebx

.caf_loop:
    cmp     rbx, r12
    jge     .caf_done

    lea     rcx, [file_mmapped]
    cmp     byte [rcx + rbx], 0
    je      .caf_close_fd

    push    rbx
    push    r12
    lea     rax, [file_datas]
    mov     rdi, [rax + rbx*8]
    lea     rax, [file_sizes]
    mov     rsi, [rax + rbx*8]
    call    asm_munmap
    pop     r12
    pop     rbx

.caf_close_fd:
    lea     rcx, [file_fds]
    mov     rdi, [rcx + rbx*8]
    cmp     rdi, -1
    je      .caf_next

    push    rbx
    push    r12
    call    asm_close
    pop     r12
    pop     rbx

.caf_next:
    inc     rbx
    jmp     .caf_loop

.caf_done:
    pop     r12
    pop     rbx
    ret

; ============================================================================
;  paste_parallel
; ============================================================================
paste_parallel:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 8

    mov     r12, [nfiles]
    lea     r13, [out_buf]

    xor     ecx, ecx
.pp_init_cursors:
    cmp     rcx, r12
    jge     .pp_init_done
    lea     rax, [file_cursors]
    mov     qword [rax + rcx*8], 0
    inc     rcx
    jmp     .pp_init_cursors

.pp_init_done:
    mov     qword [stdin_rr_cursor], 0

.pp_main_loop:
    xor     ecx, ecx
    xor     edx, edx
.pp_check_active:
    cmp     rcx, r12
    jge     .pp_check_done
    lea     rax, [file_cursors]
    mov     rdi, [rax + rcx*8]
    lea     rax, [file_sizes]
    cmp     rdi, [rax + rcx*8]
    jge     .pp_check_next
    mov     edx, 1
.pp_check_next:
    inc     rcx
    jmp     .pp_check_active

.pp_check_done:
    test    edx, edx
    jz      .pp_parallel_done

    ; Also check stdin
    ; (stdin instances share stdin_rr_cursor; check if any stdin ref is still active)

    xor     ebx, ebx
    xor     ebp, ebp
    mov     qword [rsp], 0

    mov     r14, [out_buf_pos]
    mov     [rsp], r14

.pp_file_loop:
    cmp     rbx, r12
    jge     .pp_line_done

    ; Delimiter before files 1..N
    test    rbx, rbx
    jz      .pp_no_delim

    mov     rax, [delim_len]
    test    rax, rax
    jz      .pp_no_delim

    push    rdx
    mov     rax, rbx
    dec     rax
    xor     edx, edx
    push    rcx
    mov     rcx, [delim_len]
    div     rcx
    pop     rcx
    lea     rax, [delim_buf]
    movzx   eax, byte [rax + rdx]
    pop     rdx

    test    al, al
    jz      .pp_no_delim

    call    emit_byte_al

.pp_no_delim:
    lea     rax, [file_is_stdin]
    cmp     byte [rax + rbx], 0
    jne     .pp_stdin_line

    ; Regular file
    lea     rax, [file_datas]
    mov     rsi, [rax + rbx*8]
    lea     rax, [file_sizes]
    mov     rcx, [rax + rbx*8]
    lea     rax, [file_cursors]
    mov     rdi, [rax + rbx*8]

    cmp     rdi, rcx
    jge     .pp_next_file

    movzx   edx, byte [terminator]
    push    rbx
    push    r12
    push    r13
    mov     r15, rdi
    lea     rax, [rsi + rdi]
    mov     r12, rcx
    sub     r12, rdi
    xor     ecx, ecx
.pp_scan_term:
    cmp     rcx, r12
    jge     .pp_no_term_found
    cmp     byte [rax + rcx], dl
    je      .pp_term_found
    inc     rcx
    jmp     .pp_scan_term

.pp_term_found:
    mov     rbp, 1
    test    rcx, rcx
    jz      .pp_skip_copy1
    push    rdx
    mov     rdi, [out_buf_pos]
    lea     rax, [rdi + rcx]
    cmp     rax, OUT_BUF_SIZE
    jl      .pp_copy1
    call    flush_output_inner
    test    rax, rax
    js      .pp_write_error_inner
    mov     rdi, [out_buf_pos]
.pp_copy1:
    lea     rdx, [out_buf]
    add     rdx, rdi
    lea     rax, [rsi + r15]
    push    rsi
    push    rcx
    mov     rsi, rax
    mov     rdi, rdx
    cld
    rep movsb
    pop     rcx
    pop     rsi
    mov     rax, [out_buf_pos]
    add     rax, rcx
    mov     [out_buf_pos], rax
    pop     rdx
.pp_skip_copy1:
    lea     rax, [r15 + rcx + 1]
    pop     r13
    pop     r12
    pop     rbx
    lea     rcx, [file_cursors]
    mov     [rcx + rbx*8], rax
    jmp     .pp_next_file

.pp_no_term_found:
    mov     rbp, 1
    test    r12, r12
    jz      .pp_no_term_skip
    push    rdx
    mov     rdi, [out_buf_pos]
    lea     rax, [rdi + r12]
    cmp     rax, OUT_BUF_SIZE
    jl      .pp_copy2
    call    flush_output_inner
    test    rax, rax
    js      .pp_write_error_inner
    mov     rdi, [out_buf_pos]
.pp_copy2:
    lea     rdx, [out_buf]
    add     rdx, rdi
    lea     rax, [rsi + r15]
    push    rsi
    push    rcx
    mov     rsi, rax
    mov     rdi, rdx
    mov     rcx, r12
    cld
    rep movsb
    pop     rcx
    pop     rsi
    mov     rax, [out_buf_pos]
    add     rax, r12
    mov     [out_buf_pos], rax
    pop     rdx
.pp_no_term_skip:
    pop     r13
    pop     r12
    pop     rbx
    lea     rax, [file_sizes]
    mov     rax, [rax + rbx*8]
    lea     rcx, [file_cursors]
    mov     [rcx + rbx*8], rax
    jmp     .pp_next_file

.pp_stdin_line:
    mov     rsi, [stdin_data]
    mov     rcx, [stdin_size]
    mov     rdi, [stdin_rr_cursor]

    cmp     rdi, rcx
    jge     .pp_next_file

    movzx   edx, byte [terminator]
    push    rbx
    push    r12
    push    r13
    mov     r15, rdi
    lea     rax, [rsi + rdi]
    mov     r12, rcx
    sub     r12, rdi
    xor     ecx, ecx
.pp_stdin_scan:
    cmp     rcx, r12
    jge     .pp_stdin_no_term
    cmp     byte [rax + rcx], dl
    je      .pp_stdin_term_found
    inc     rcx
    jmp     .pp_stdin_scan

.pp_stdin_term_found:
    mov     ebp, 1
    test    rcx, rcx
    jz      .pp_stdin_skip_copy1
    push    rdx
    mov     rdi, [out_buf_pos]
    lea     rax, [rdi + rcx]
    cmp     rax, OUT_BUF_SIZE
    jl      .pp_stdin_copy1
    call    flush_output_inner
    test    rax, rax
    js      .pp_write_error_inner
    mov     rdi, [out_buf_pos]
.pp_stdin_copy1:
    lea     rdx, [out_buf]
    add     rdx, rdi
    lea     rax, [rsi + r15]
    push    rsi
    push    rcx
    mov     rsi, rax
    mov     rdi, rdx
    cld
    rep movsb
    pop     rcx
    pop     rsi
    mov     rax, [out_buf_pos]
    add     rax, rcx
    mov     [out_buf_pos], rax
    pop     rdx
.pp_stdin_skip_copy1:
    lea     rax, [r15 + rcx + 1]
    mov     [stdin_rr_cursor], rax
    pop     r13
    pop     r12
    pop     rbx
    jmp     .pp_next_file

.pp_stdin_no_term:
    mov     ebp, 1
    test    r12, r12
    jz      .pp_stdin_no_term_skip
    push    rdx
    mov     rdi, [out_buf_pos]
    lea     rax, [rdi + r12]
    cmp     rax, OUT_BUF_SIZE
    jl      .pp_stdin_copy2
    call    flush_output_inner
    test    rax, rax
    js      .pp_write_error_inner
    mov     rdi, [out_buf_pos]
.pp_stdin_copy2:
    lea     rdx, [out_buf]
    add     rdx, rdi
    lea     rax, [rsi + r15]
    push    rsi
    push    rcx
    mov     rsi, rax
    mov     rdi, rdx
    mov     rcx, r12
    cld
    rep movsb
    pop     rcx
    pop     rsi
    mov     rax, [out_buf_pos]
    add     rax, r12
    mov     [out_buf_pos], rax
    pop     rdx
.pp_stdin_no_term_skip:
    mov     rax, [stdin_size]
    mov     [stdin_rr_cursor], rax
    pop     r13
    pop     r12
    pop     rbx
    jmp     .pp_next_file

.pp_next_file:
    inc     rbx
    jmp     .pp_file_loop

.pp_line_done:
    test    ebp, ebp
    jz      .pp_rewind_done

    movzx   eax, byte [terminator]
    call    emit_byte_al

    mov     rax, [out_buf_pos]
    cmp     rax, FLUSH_THRESHOLD
    jl      .pp_main_loop
    call    flush_output_inner
    test    rax, rax
    js      .pp_write_error
    jmp     .pp_main_loop

.pp_rewind_done:
    mov     rax, [rsp]
    mov     [out_buf_pos], rax

.pp_parallel_done:
    add     rsp, 8
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

.pp_write_error:
    add     rsp, 8
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

.pp_write_error_inner:
    pop     r13
    pop     r12
    pop     rbx
    add     rsp, 8
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

; ============================================================================
;  paste_serial
; ============================================================================
paste_serial:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15

    lea     r13, [out_buf]
    mov     qword [stdin_rr_cursor], 0

    xor     ebx, ebx
.ps_file_loop:
    cmp     rbx, [nfiles]
    jge     .ps_done

    lea     rax, [file_is_stdin]
    cmp     byte [rax + rbx], 0
    jne     .ps_stdin_file

    lea     rax, [file_datas]
    mov     r14, [rax + rbx*8]
    lea     rax, [file_sizes]
    mov     r15, [rax + rbx*8]
    jmp     .ps_process_file

.ps_stdin_file:
    mov     r14, [stdin_data]
    mov     r15, [stdin_size]
    mov     qword [stdin_size], 0

.ps_process_file:
    test    r15, r15
    jz      .ps_empty_file

    xor     r12d, r12d
    xor     ecx, ecx
    mov     [serial_line_idx], rcx

.ps_line_loop:
    cmp     r12, r15
    jge     .ps_file_end

    mov     rcx, [serial_line_idx]
    test    rcx, rcx
    jz      .ps_no_delim

    mov     rax, [delim_len]
    test    rax, rax
    jz      .ps_no_delim

    push    rdx
    mov     rax, rcx
    dec     rax
    xor     edx, edx
    push    rcx
    mov     rcx, [delim_len]
    div     rcx
    pop     rcx
    lea     rax, [delim_buf]
    movzx   eax, byte [rax + rdx]
    pop     rdx

    test    al, al
    jz      .ps_no_delim

    call    emit_byte_al

.ps_no_delim:
    movzx   edx, byte [terminator]
    lea     rsi, [r14 + r12]
    mov     rdi, r15
    sub     rdi, r12
    xor     ecx, ecx

.ps_scan_term:
    cmp     rcx, rdi
    jge     .ps_no_term

    cmp     byte [rsi + rcx], dl
    je      .ps_term_found

    inc     rcx
    jmp     .ps_scan_term

.ps_term_found:
    test    rcx, rcx
    jz      .ps_skip_line_copy

    push    rdx
    mov     rax, [out_buf_pos]
    push    rcx
    add     rax, rcx
    cmp     rax, OUT_BUF_SIZE
    jl      .ps_copy_line
    call    flush_output_inner
    test    rax, rax
    js      .ps_serial_write_error
.ps_copy_line:
    pop     rcx
    mov     rdi, [out_buf_pos]
    lea     rax, [out_buf]
    add     rax, rdi
    push    rcx
    mov     rdi, rax
    cld
    rep movsb
    pop     rcx
    mov     rax, [out_buf_pos]
    add     rax, rcx
    mov     [out_buf_pos], rax
    pop     rdx

.ps_skip_line_copy:
    add     r12, rcx
    inc     r12
    inc     qword [serial_line_idx]

    mov     rax, [out_buf_pos]
    cmp     rax, FLUSH_THRESHOLD
    jl      .ps_line_loop
    call    flush_output_inner
    test    rax, rax
    js      .ps_write_error
    jmp     .ps_line_loop

.ps_no_term:
    test    rdi, rdi
    jz      .ps_file_end

    push    rdx
    mov     rax, [out_buf_pos]
    push    rdi
    add     rax, rdi
    cmp     rax, OUT_BUF_SIZE
    jl      .ps_copy_rest
    call    flush_output_inner
    test    rax, rax
    js      .ps_serial_write_error
.ps_copy_rest:
    pop     rdi
    mov     rcx, rdi
    mov     rdi, [out_buf_pos]
    lea     rax, [out_buf]
    add     rax, rdi
    push    rcx
    mov     rdi, rax
    cld
    rep movsb
    pop     rcx
    mov     rax, [out_buf_pos]
    add     rax, rcx
    mov     [out_buf_pos], rax
    pop     rdx

    mov     r12, r15

.ps_file_end:
    movzx   eax, byte [terminator]
    call    emit_byte_al

    mov     rax, [out_buf_pos]
    cmp     rax, FLUSH_THRESHOLD
    jl      .ps_next_file
    call    flush_output_inner
    test    rax, rax
    js      .ps_write_error
    jmp     .ps_next_file

.ps_empty_file:
    movzx   eax, byte [terminator]
    call    emit_byte_al

.ps_next_file:
    inc     rbx
    jmp     .ps_file_loop

.ps_done:
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

.ps_write_error:
.ps_serial_write_error:
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

; ============================================================================
;  emit_byte_al
; ============================================================================
emit_byte_al:
    push    rbx
    mov     rbx, [out_buf_pos]
    lea     rcx, [out_buf]
    mov     [rcx + rbx], al
    inc     rbx
    mov     [out_buf_pos], rbx

    cmp     rbx, FLUSH_THRESHOLD
    jl      .eba_done

    call    flush_output_inner
.eba_done:
    pop     rbx
    ret

; ============================================================================
;  flush_output / flush_output_inner
; ============================================================================
flush_output:
flush_output_inner:
    push    r12
    mov     r12, [out_buf_pos]
    test    r12, r12
    jz      .fo_nothing

    mov     rdi, STDOUT
    lea     rsi, [out_buf]
    mov     rdx, r12
    call    asm_write_all
    mov     qword [out_buf_pos], 0
    pop     r12
    ret

.fo_nothing:
    xor     eax, eax
    pop     r12
    ret

; ============================================================================
;  String utilities
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

str_eq:
.se_loop:
    mov     al, [rdi]
    mov     cl, [rsi]
    cmp     al, cl
    jne     .se_ne
    test    al, al
    jz      .se_equal
    inc     rdi
    inc     rsi
    jmp     .se_loop
.se_equal:
    mov     eax, 1
    ret
.se_ne:
    xor     eax, eax
    ret

str_has_prefix:
    push    rbx
    xor     ebx, ebx
.sp_loop:
    cmp     ebx, ecx
    jge     .sp_match
    movzx   eax, byte [rdi + rbx]
    cmp     al, [rsi + rbx]
    jne     .sp_no
    inc     ebx
    jmp     .sp_loop
.sp_match:
    mov     eax, 1
    pop     rbx
    ret
.sp_no:
    xor     eax, eax
    pop     rbx
    ret

; ============================================================================
;  Error helpers
; ============================================================================

err_file:
    push    rbx
    push    r13
    mov     rbx, rdi
    mov     r13d, esi

    mov     rdi, STDERR
    lea     rsi, [err_prefix]
    mov     rdx, err_prefix_len
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
    mov     rbx, rdi

    mov     rdi, STDERR
    lea     rsi, [str_unrecognized]
    mov     rdx, str_unrecognized_len
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
    mov     ebx, esi

    mov     rdi, STDERR
    lea     rsi, [str_invalid_opt]
    mov     rdx, str_invalid_opt_len
    call    asm_write_all

    mov     [char_buf], bl
    mov     rdi, STDERR
    lea     rsi, [char_buf]
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
.se_eperm:
    lea     rax, [str_eperm]
    ret
.se_enoent:
    lea     rax, [str_enoent]
    ret
.se_eio:
    lea     rax, [str_eio]
    ret
.se_ebadf:
    lea     rax, [str_ebadf]
    ret
.se_enomem:
    lea     rax, [str_enomem]
    ret
.se_eacces:
    lea     rax, [str_eacces]
    ret
.se_enotdir:
    lea     rax, [str_enotdir]
    ret
.se_eisdir:
    lea     rax, [str_eisdir]
    ret
.se_einval:
    lea     rax, [str_einval]
    ret
.se_emfile:
    lea     rax, [str_emfile]
    ret
.se_enametoolong:
    lea     rax, [str_enametoolong]
    ret

; ===============================================================
; RODATA
; ===============================================================

err_prefix:     db "paste: "
err_prefix_len  equ $ - err_prefix

str_newline:    db 10
str_colon_space: db ": "

str_unrecognized: db "paste: unrecognized option ", 0xE2, 0x80, 0x98
str_unrecognized_len equ $ - str_unrecognized

str_quote_nl:   db 0xE2, 0x80, 0x99, 10

str_try_help:   db "Try 'paste --help' for more information.", 10
str_try_help_len equ $ - str_try_help

str_invalid_opt: db "paste: invalid option -- ", 0xE2, 0x80, 0x98
str_invalid_opt_len equ $ - str_invalid_opt

str_help_opt:       db "--help", 0
str_version_opt:    db "--version", 0
str_serial_opt:     db "--serial", 0
str_zero_opt:       db "--zero-terminated", 0
str_delimiters_eq:  db "--delimiters=", 0
str_delimiters_opt: db "--delimiters", 0

str_delim_missing:  db "paste: option '--delimiters' requires an argument", 10
str_delim_missing_len equ $ - str_delim_missing

str_d_missing:      db "paste: option requires an argument -- 'd'", 10
str_d_missing_len   equ $ - str_d_missing

str_stdin_name:     db "standard input"
str_stdin_name_len  equ $ - str_stdin_name

str_read_error:     db ": read error", 10
str_read_error_len  equ $ - str_read_error

help_text:
    db "Usage: paste [OPTION]... [FILE]...", 10
    db "Write lines consisting of the sequentially corresponding lines from", 10
    db "each FILE, separated by TABs, to standard output.", 10
    db 10
    db "With no FILE, or when FILE is -, read standard input.", 10
    db 10
    db "Mandatory arguments to long options are mandatory for short options too.", 10
    db "  -d, --delimiters=LIST   reuse characters from LIST instead of TABs", 10
    db "  -s, --serial            paste one file at a time instead of in parallel", 10
    db "  -z, --zero-terminated    line delimiter is NUL, not newline", 10
    db "      --help        display this help and exit", 10
    db "      --version     output version information and exit", 10
    db 10
    db "GNU coreutils online help: <https://www.gnu.org/software/coreutils/>", 10
    db "Full documentation <https://www.gnu.org/software/coreutils/paste>", 10
    db "or available locally via: info '(coreutils) paste invocation'", 10
help_text_len equ $ - help_text

version_text:
    db "paste (GNU coreutils) 9.7", 10
    db "Packaged by Debian (9.7-3)", 10
    db "Copyright (C) 2025 Free Software Foundation, Inc.", 10
    db "License GPLv3+: GNU GPL version 3 or later <https://gnu.org/licenses/gpl.html>.", 10
    db "This is free software: you are free to change and redistribute it.", 10
    db "There is NO WARRANTY, to the extent permitted by law.", 10, 10
    db "Written by David M. Ihnat and David MacKenzie.", 10
version_text_len equ $ - version_text

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

; ===============================================================
; BSS (uninitialized data — zero-filled by ELF loader)
; ===============================================================
file_size equ $ - $$

bss_base        equ $$ + file_size

argc            equ bss_base + 0
argv            equ bss_base + 8
flags           equ bss_base + 16
had_error       equ bss_base + 17
terminator      equ bss_base + 18
nfiles          equ bss_base + 24
file_ptrs       equ bss_base + 32
file_datas      equ bss_base + 32 + MAX_FILES * 8
file_sizes      equ file_datas + MAX_FILES * 8
file_fds        equ file_sizes + MAX_FILES * 8
file_cursors    equ file_fds + MAX_FILES * 8
file_mmapped    equ file_cursors + MAX_FILES * 8
file_is_stdin   equ file_mmapped + MAX_FILES
delim_buf       equ file_is_stdin + MAX_FILES
delim_len       equ delim_buf + MAX_DELIMS
char_buf        equ delim_len + 8
out_buf_pos     equ char_buf + 8
stat_buf        equ out_buf_pos + 8
stdin_data      equ stat_buf + STAT_STRUCT_SIZE
stdin_size      equ stdin_data + 8
stdin_capacity  equ stdin_size + 8
stdin_count     equ stdin_capacity + 8
stdin_rr_idx    equ stdin_count + 4
stdin_rr_cursor equ stdin_rr_idx + 4
serial_line_idx equ stdin_rr_cursor + 8
out_buf         equ serial_line_idx + 8

bss_end         equ out_buf + OUT_BUF_SIZE
mem_size        equ bss_end - $$
