; fpaste_unified.asm — Unified single-file build of fpaste
; Auto-merged from modular source — DO NOT EDIT
; Edit tools/fpaste.asm and rebuild instead
; Build: nasm -f bin unified/fpaste_unified.asm -o fpaste_tiny && chmod +x fpaste_tiny

BITS 64
org 0x400000
default abs

; ── Linux syscall numbers and constants ──
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
%define ENOENT             -2
%define EACCES            -13

%define PROT_READ           1
%define MAP_PRIVATE         2

%define STAT_MODE          24
%define STAT_SIZE          48
%define STAT_STRUCT_SIZE  144

%define S_IFMT          0o170000
%define S_IFREG         0o100000

%define READ_BUF_SIZE   131072
%define OUT_BUF_SIZE    262144
%define FLUSH_THRESHOLD 131072

; ── Macros ──
%macro BLOCK_SIGPIPE 0
    sub     rsp, 16
    mov     qword [rsp], (1 << (SIGPIPE - 1))
    mov     eax, SYS_RT_SIGPROCMASK
    xor     edi, edi
    mov     rsi, rsp
    xor     edx, edx
    mov     r10d, 8
    syscall
    add     rsp, 16
%endmacro

; ── Paste configuration ──
%define MAX_FILES       4096
%define MAX_DELIMS      256
%define STDIN_INIT_SIZE 1048576
%define FLAG_SERIAL     0x01
%define FLAG_ZERO_TERM  0x02

; ── BSS Variables (at 0x600000, zero-filled by kernel) ──
%define bss_base        0x600000
%define argc            (bss_base + 0)
%define argv            (bss_base + 8)
%define flags           (bss_base + 16)
%define had_error       (bss_base + 17)
%define terminator      (bss_base + 18)
; padding to align
%define nfiles          (bss_base + 24)
%define file_ptrs       (bss_base + 32)        ; 4096 * 8 = 32768
%define file_datas      (bss_base + 32800)     ; 4096 * 8
%define file_sizes      (bss_base + 65568)     ; 4096 * 8
%define file_fds        (bss_base + 98336)     ; 4096 * 8
%define file_cursors    (bss_base + 131104)    ; 4096 * 8
%define file_mmapped    (bss_base + 163872)    ; 4096 * 1
%define file_is_stdin   (bss_base + 167968)    ; 4096 * 1
%define delim_buf       (bss_base + 172064)    ; 256
%define delim_len       (bss_base + 172320)    ; 8
%define char_buf        (bss_base + 172328)    ; 4
%define out_buf_pos     (bss_base + 172336)    ; 8
%define stat_buf        (bss_base + 172344)    ; 144
%define stdin_data      (bss_base + 172488)    ; 8
%define stdin_size      (bss_base + 172496)    ; 8
%define stdin_capacity  (bss_base + 172504)    ; 8
%define stdin_count     (bss_base + 172512)    ; 4
%define stdin_rr_idx    (bss_base + 172516)    ; 4
%define stdin_rr_cursor (bss_base + 172520)    ; 8
%define serial_line_idx (bss_base + 172528)    ; 8
%define out_buf         (bss_base + 172536)    ; 262144
; Total BSS: ~434680 bytes

%define bss_total_size  (262144 + 172536 + 64)

; ============================================================================
;                      ELF HEADER
; ============================================================================
ehdr:
    db 0x7F, "ELF"                  ; e_ident[EI_MAG0..3]
    db 2                            ; e_ident[EI_CLASS] = ELFCLASS64
    db 1                            ; e_ident[EI_DATA] = ELFDATA2LSB
    db 1                            ; e_ident[EI_VERSION] = EV_CURRENT
    db 0                            ; e_ident[EI_OSABI] = ELFOSABI_NONE
    dq 0                            ; e_ident[EI_ABIVERSION..15]
    dw 2                            ; e_type = ET_EXEC
    dw 0x3E                         ; e_machine = EM_X86_64
    dd 1                            ; e_version = EV_CURRENT
    dq _start                       ; e_entry
    dq phdr - ehdr                  ; e_phoff
    dq 0                            ; e_shoff
    dd 0                            ; e_flags
    dw ehdr_size                    ; e_ehsize
    dw phdr_size                    ; e_phentsize
    dw 3                            ; e_phnum (LOAD text, LOAD bss, GNU_STACK)
    dw 0                            ; e_shentsize
    dw 0                            ; e_shnum
    dw 0                            ; e_shstrndx
ehdr_size equ $ - ehdr

; ── Program headers ──
phdr:
; LOAD segment: text + rodata (entire file)
    dd 1                            ; p_type = PT_LOAD
    dd 5                            ; p_flags = PF_R | PF_X
    dq 0                            ; p_offset
    dq 0x400000                     ; p_vaddr
    dq 0x400000                     ; p_paddr
    dq file_end - ehdr              ; p_filesz
    dq file_end - ehdr              ; p_memsz
    dq 0x1000                       ; p_align
phdr_size equ $ - phdr

; LOAD segment: BSS (zero-filled by kernel)
    dd 1                            ; p_type = PT_LOAD
    dd 6                            ; p_flags = PF_R | PF_W
    dq 0                            ; p_offset
    dq bss_base                     ; p_vaddr
    dq bss_base                     ; p_paddr
    dq 0                            ; p_filesz
    dq bss_total_size               ; p_memsz
    dq 0x1000                       ; p_align

; PT_GNU_STACK: non-executable stack
    dd 0x6474E551                   ; p_type = PT_GNU_STACK
    dd 6                            ; p_flags = PF_R | PF_W (no PF_X)
    dq 0                            ; p_offset
    dq 0                            ; p_vaddr
    dq 0                            ; p_paddr
    dq 0                            ; p_filesz
    dq 0                            ; p_memsz
    dq 0x10                         ; p_align

; ============================================================================
;                      I/O LIBRARY (inlined)
; ============================================================================

; asm_write_all(rdi=fd, rsi=buf, rdx=len) -> rax=0 on success, negative errno on error
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
    cmp     rax, EINTR
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

; asm_read(rdi=fd, rsi=buf, rdx=len) -> rax=bytes_read
asm_read:
.ar_retry:
    mov     rax, SYS_READ
    syscall
    cmp     rax, EINTR
    je      .ar_retry
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

; asm_fstat(rdi=fd, rsi=buf) -> rax
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

; ============================================================================
;                           ENTRY POINT
; ============================================================================
_start:
    BLOCK_SIGPIPE

    mov     rax, [rsp]
    mov     [argc], rax
    lea     rax, [rsp + 8]
    mov     [argv], rax

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

    call    parse_args

    cmp     qword [nfiles], 0
    jne     .have_files
mov     rax, dash_str
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
    xor     r14d, r14d

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

    push    rbx
    push    r12
    push    r13
    push    r14

    mov     rdi, rsi
mov     rsi, str_help_opt
    call    str_eq
    test    eax, eax
    jnz     .pa_do_help

    mov     rsi, [r13 + rbx*8]
    mov     rdi, rsi
mov     rsi, str_version_opt
    call    str_eq
    test    eax, eax
    jnz     .pa_do_version

    mov     rsi, [r13 + rbx*8]
    mov     rdi, rsi
mov     rsi, str_serial_opt
    call    str_eq
    test    eax, eax
    jnz     .pa_do_serial

    mov     rsi, [r13 + rbx*8]
    mov     rdi, rsi
mov     rsi, str_zero_opt
    call    str_eq
    test    eax, eax
    jnz     .pa_do_zero

    mov     rsi, [r13 + rbx*8]
    mov     rdi, rsi
mov     rsi, str_delimiters_eq
    mov     ecx, 13
    call    str_has_prefix
    test    eax, eax
    jnz     .pa_do_delim_eq

    mov     rsi, [r13 + rbx*8]
    mov     rdi, rsi
mov     rsi, str_delimiters_opt
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
mov     rsi, help_text
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
mov     rsi, version_text
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
mov     rsi, str_delim_missing
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
mov     rsi, str_d_missing
    mov     rdx, str_d_missing_len
    call    asm_write_all
    mov     edi, 1
    mov     eax, SYS_EXIT
    syscall

.pa_is_file:
    mov     rax, [nfiles]
    cmp     rax, MAX_FILES
    jge     .pa_next
mov     rcx, file_ptrs
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
;  parse_delimiters
; ============================================================================
parse_delimiters:
    push    rbx
    push    r12
mov     r12, delim_buf
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
mov     rax, file_ptrs
    mov     rdi, [rax + rbx*8]
    cmp     byte [rdi], '-'
    jne     .cas_next
    cmp     byte [rdi+1], 0
    je      .cas_need_stdin
.cas_next:
    inc     rbx
    jmp     .cas_loop
.cas_need_stdin:
    mov     eax, 12
    xor     edi, edi
    syscall
    mov     [stdin_data], rax
    mov     r12, rax
    lea     rdi, [rax + STDIN_INIT_SIZE]
    mov     eax, 12
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
    mov     eax, 12
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
    mov     byte [had_error], 1
    mov     [stdin_size], rbx
    pop     r12
    pop     rbx
    ret

free_stdin_buf:
    cmp     qword [stdin_data], 0
    je      .fsb_done
    mov     rdi, [stdin_data]
    mov     eax, 12
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
.oaf_count_stdin:
    cmp     rcx, r12
    jge     .oaf_count_done
mov     rax, file_ptrs
    mov     rdi, [rax + rcx*8]
    cmp     byte [rdi], '-'
    jne     .oaf_count_next
    cmp     byte [rdi+1], 0
    jne     .oaf_count_next
    inc     ecx
.oaf_count_next:
    inc     rcx
    jmp     .oaf_count_stdin
.oaf_count_done:
    mov     [stdin_count], ecx
    mov     qword [stdin_rr_cursor], 0
    mov     dword [stdin_rr_idx], 0
    xor     ebx, ebx
.oaf_loop:
    cmp     rbx, r12
    jge     .oaf_done
mov     rax, file_ptrs
    mov     rdi, [rax + rbx*8]
    cmp     byte [rdi], '-'
    jne     .oaf_open_file
    cmp     byte [rdi+1], 0
    jne     .oaf_open_file
    mov     rax, [stdin_data]
mov     rcx, file_datas
    mov     [rcx + rbx*8], rax
    mov     rax, [stdin_size]
mov     rcx, file_sizes
    mov     [rcx + rbx*8], rax
mov     rcx, file_fds
    mov     qword [rcx + rbx*8], -1
mov     rcx, file_mmapped
    mov     byte [rcx + rbx], 0
mov     rcx, file_is_stdin
    mov     byte [rcx + rbx], 1
    jmp     .oaf_next

.oaf_open_file:
mov     rcx, file_is_stdin
    mov     byte [rcx + rbx], 0
    push    rbx
    push    r12
mov     rax, file_ptrs
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
mov     rsi, stat_buf
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
mov     rcx, file_fds
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
mov     rcx, file_datas
    mov     [rcx + rbx*8], rax
mov     rcx, file_sizes
    mov     [rcx + rbx*8], r14
mov     rcx, file_mmapped
    mov     byte [rcx + rbx], 1
    jmp     .oaf_next

.oaf_empty_file:
mov     rcx, file_datas
    mov     qword [rcx + rbx*8], 0
mov     rcx, file_sizes
    mov     qword [rcx + rbx*8], 0
mov     rcx, file_mmapped
    mov     byte [rcx + rbx], 0
    jmp     .oaf_next

.oaf_is_dir_check:
    mov     eax, [stat_buf + STAT_MODE]
    and     eax, S_IFMT
    cmp     eax, 0o40000
    jne     .oaf_read_fallback
    push    rbx
    push    r12
mov     rax, file_ptrs
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
mov     rcx, file_datas
    mov     qword [rcx + rbx*8], 0
mov     rcx, file_sizes
    mov     qword [rcx + rbx*8], 0
mov     rcx, file_fds
    mov     qword [rcx + rbx*8], -1
mov     rcx, file_mmapped
    mov     byte [rcx + rbx], 0
    jmp     .oaf_next

.oaf_read_fallback:
    push    rbx
    push    r12
    mov     rdi, r13
    call    asm_close
    pop     r12
    pop     rbx
mov     rcx, file_datas
    mov     qword [rcx + rbx*8], 0
mov     rcx, file_sizes
    mov     qword [rcx + rbx*8], 0
mov     rcx, file_fds
    mov     qword [rcx + rbx*8], -1
mov     rcx, file_mmapped
    mov     byte [rcx + rbx], 0
    jmp     .oaf_next

.oaf_open_error:
    neg     rax
    mov     r15d, eax
    push    rbx
    push    r12
mov     rax, file_ptrs
    mov     rdi, [rax + rbx*8]
    mov     esi, r15d
    call    err_file
    pop     r12
    pop     rbx
    mov     byte [had_error], 1
mov     rcx, file_datas
    mov     qword [rcx + rbx*8], 0
mov     rcx, file_sizes
    mov     qword [rcx + rbx*8], 0
mov     rcx, file_fds
    mov     qword [rcx + rbx*8], -1
mov     rcx, file_mmapped
    mov     byte [rcx + rbx], 0
mov     rcx, file_is_stdin
    mov     byte [rcx + rbx], 0
    jmp     .oaf_done

.oaf_stat_error:
    neg     rax
    mov     r15d, eax
    push    rbx
    push    r12
mov     rax, file_ptrs
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
mov     rcx, file_datas
    mov     qword [rcx + rbx*8], 0
mov     rcx, file_sizes
    mov     qword [rcx + rbx*8], 0
mov     rcx, file_fds
    mov     qword [rcx + rbx*8], -1
mov     rcx, file_mmapped
    mov     byte [rcx + rbx], 0
    jmp     .oaf_done

.oaf_mmap_error:
mov     rcx, file_datas
    mov     qword [rcx + rbx*8], 0
mov     rcx, file_sizes
    mov     qword [rcx + rbx*8], 0
mov     rcx, file_mmapped
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
mov     rcx, file_mmapped
    cmp     byte [rcx + rbx], 0
    je      .caf_close_fd
    push    rbx
    push    r12
mov     rax, file_datas
    mov     rdi, [rax + rbx*8]
mov     rax, file_sizes
    mov     rsi, [rax + rbx*8]
    call    asm_munmap
    pop     r12
    pop     rbx
.caf_close_fd:
mov     rcx, file_fds
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
;  paste_parallel — same as modular version but with absolute addresses
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
mov     r13, out_buf

    xor     ecx, ecx
.pp_init:
    cmp     rcx, r12
    jge     .pp_init_done
mov     rax, file_cursors
    mov     qword [rax + rcx*8], 0
    inc     rcx
    jmp     .pp_init
.pp_init_done:
    mov     qword [stdin_rr_cursor], 0

.pp_main:
    xor     ecx, ecx
    xor     edx, edx
.pp_chk:
    cmp     rcx, r12
    jge     .pp_chk_done
mov     rax, file_cursors
    mov     rdi, [rax + rcx*8]
mov     rax, file_sizes
    cmp     rdi, [rax + rcx*8]
    jge     .pp_chk_nxt
    mov     edx, 1
.pp_chk_nxt:
    inc     rcx
    jmp     .pp_chk
.pp_chk_done:
    ; Also check stdin refs
mov     rax, file_is_stdin
    xor     ecx, ecx
.pp_chk_stdin:
    cmp     rcx, r12
    jge     .pp_chk_stdin_done
    cmp     byte [rax + rcx], 0
    je      .pp_chk_stdin_next
    ; Check if stdin still has data
    push    rcx
    push    rdx
    mov     rdi, [stdin_rr_cursor]
    cmp     rdi, [stdin_size]
    jge     .pp_chk_stdin_pop
    mov     edx, 1
    pop     rdx
    pop     rcx
    jmp     .pp_chk_stdin_next
.pp_chk_stdin_pop:
    pop     rdx
    pop     rcx
.pp_chk_stdin_next:
    inc     rcx
    jmp     .pp_chk_stdin
.pp_chk_stdin_done:

    test    edx, edx
    jz      .pp_done

    xor     ebx, ebx
    xor     ebp, ebp
    mov     r14, [out_buf_pos]
    mov     [rsp], r14

.pp_floop:
    cmp     rbx, r12
    jge     .pp_lndn

    test    rbx, rbx
    jz      .pp_nodel
    mov     rax, [delim_len]
    test    rax, rax
    jz      .pp_nodel
    push    rdx
    mov     rax, rbx
    dec     rax
    xor     edx, edx
    push    rcx
    mov     rcx, [delim_len]
    div     rcx
    pop     rcx
mov     rax, delim_buf
    movzx   eax, byte [rax + rdx]
    pop     rdx
    test    al, al
    jz      .pp_nodel
    call    emit_byte_al

.pp_nodel:
mov     rax, file_is_stdin
    cmp     byte [rax + rbx], 0
    jne     .pp_stdin

mov     rax, file_datas
    mov     rsi, [rax + rbx*8]
mov     rax, file_sizes
    mov     rcx, [rax + rbx*8]
mov     rax, file_cursors
    mov     rdi, [rax + rbx*8]
    cmp     rdi, rcx
    jge     .pp_nxtf

    movzx   edx, byte [terminator]
    push    rbx
    push    r12
    push    r13
    mov     r15, rdi
    lea     rax, [rsi + rdi]
    mov     r12, rcx
    sub     r12, rdi
    xor     ecx, ecx
.pp_scan:
    cmp     rcx, r12
    jge     .pp_noterm
    cmp     byte [rax + rcx], dl
    je      .pp_found
    inc     rcx
    jmp     .pp_scan

.pp_found:
    mov     ebp, 1
    test    rcx, rcx
    jz      .pp_sk1
    push    rdx
    mov     rdi, [out_buf_pos]
    lea     rax, [rdi + rcx]
    cmp     rax, OUT_BUF_SIZE
    jl      .pp_cp1
    call    flush_output_inner
    mov     rdi, [out_buf_pos]
.pp_cp1:
mov     rdx, out_buf
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
.pp_sk1:
    lea     rax, [r15 + rcx + 1]
    pop     r13
    pop     r12
    pop     rbx
mov     rcx, file_cursors
    mov     [rcx + rbx*8], rax
    jmp     .pp_nxtf

.pp_noterm:
    mov     ebp, 1
    test    r12, r12
    jz      .pp_noterm_sk
    push    rdx
    mov     rdi, [out_buf_pos]
    lea     rax, [rdi + r12]
    cmp     rax, OUT_BUF_SIZE
    jl      .pp_cp2
    call    flush_output_inner
    mov     rdi, [out_buf_pos]
.pp_cp2:
mov     rdx, out_buf
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
.pp_noterm_sk:
    pop     r13
    pop     r12
    pop     rbx
mov     rax, file_sizes
    mov     rax, [rax + rbx*8]
mov     rcx, file_cursors
    mov     [rcx + rbx*8], rax
    jmp     .pp_nxtf

.pp_stdin:
    mov     rsi, [stdin_data]
    mov     rcx, [stdin_size]
    mov     rdi, [stdin_rr_cursor]
    cmp     rdi, rcx
    jge     .pp_nxtf
    movzx   edx, byte [terminator]
    push    rbx
    push    r12
    push    r13
    mov     r15, rdi
    lea     rax, [rsi + rdi]
    mov     r12, rcx
    sub     r12, rdi
    xor     ecx, ecx
.pp_sscan:
    cmp     rcx, r12
    jge     .pp_snoterm
    cmp     byte [rax + rcx], dl
    je      .pp_sfound
    inc     rcx
    jmp     .pp_sscan
.pp_sfound:
    mov     ebp, 1
    test    rcx, rcx
    jz      .pp_ssk1
    push    rdx
    mov     rdi, [out_buf_pos]
    lea     rax, [rdi + rcx]
    cmp     rax, OUT_BUF_SIZE
    jl      .pp_scp1
    call    flush_output_inner
    mov     rdi, [out_buf_pos]
.pp_scp1:
mov     rdx, out_buf
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
.pp_ssk1:
    lea     rax, [r15 + rcx + 1]
    mov     [stdin_rr_cursor], rax
    pop     r13
    pop     r12
    pop     rbx
    jmp     .pp_nxtf
.pp_snoterm:
    mov     ebp, 1
    test    r12, r12
    jz      .pp_snoterm_sk
    push    rdx
    mov     rdi, [out_buf_pos]
    lea     rax, [rdi + r12]
    cmp     rax, OUT_BUF_SIZE
    jl      .pp_scp2
    call    flush_output_inner
    mov     rdi, [out_buf_pos]
.pp_scp2:
mov     rdx, out_buf
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
.pp_snoterm_sk:
    mov     rax, [stdin_size]
    mov     [stdin_rr_cursor], rax
    pop     r13
    pop     r12
    pop     rbx
    jmp     .pp_nxtf

.pp_nxtf:
    inc     rbx
    jmp     .pp_floop

.pp_lndn:
    test    ebp, ebp
    jz      .pp_rewind
    movzx   eax, byte [terminator]
    call    emit_byte_al
    mov     rax, [out_buf_pos]
    cmp     rax, FLUSH_THRESHOLD
    jl      .pp_main
    call    flush_output_inner
    jmp     .pp_main

.pp_rewind:
    mov     rax, [rsp]
    mov     [out_buf_pos], rax

.pp_done:
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
mov     r13, out_buf
    mov     qword [stdin_rr_cursor], 0
    xor     ebx, ebx
.ps_fl:
    cmp     rbx, [nfiles]
    jge     .ps_done
mov     rax, file_is_stdin
    cmp     byte [rax + rbx], 0
    jne     .ps_stdin
mov     rax, file_datas
    mov     r14, [rax + rbx*8]
mov     rax, file_sizes
    mov     r15, [rax + rbx*8]
    jmp     .ps_proc
.ps_stdin:
    mov     r14, [stdin_data]
    mov     r15, [stdin_size]
    mov     qword [stdin_size], 0
.ps_proc:
    test    r15, r15
    jz      .ps_empty
    xor     r12d, r12d
    xor     ecx, ecx
    mov     [serial_line_idx], rcx
.ps_ll:
    cmp     r12, r15
    jge     .ps_fend
    mov     rcx, [serial_line_idx]
    test    rcx, rcx
    jz      .ps_nd
    mov     rax, [delim_len]
    test    rax, rax
    jz      .ps_nd
    push    rdx
    mov     rax, rcx
    dec     rax
    xor     edx, edx
    push    rcx
    mov     rcx, [delim_len]
    div     rcx
    pop     rcx
mov     rax, delim_buf
    movzx   eax, byte [rax + rdx]
    pop     rdx
    test    al, al
    jz      .ps_nd
    call    emit_byte_al
.ps_nd:
    movzx   edx, byte [terminator]
    lea     rsi, [r14 + r12]
    mov     rdi, r15
    sub     rdi, r12
    xor     ecx, ecx
.ps_st:
    cmp     rcx, rdi
    jge     .ps_nt
    cmp     byte [rsi + rcx], dl
    je      .ps_tf
    inc     rcx
    jmp     .ps_st
.ps_tf:
    test    rcx, rcx
    jz      .ps_slc
    push    rdx
    mov     rax, [out_buf_pos]
    push    rcx
    add     rax, rcx
    cmp     rax, OUT_BUF_SIZE
    jl      .ps_cl
    call    flush_output_inner
.ps_cl:
    pop     rcx
    mov     rdi, [out_buf_pos]
mov     rax, out_buf
    add     rax, rdi
    push    rsi
    push    rcx
    mov     rdi, rax
    cld
    rep movsb
    pop     rcx
    pop     rsi
    mov     rax, [out_buf_pos]
    add     rax, rcx
    mov     [out_buf_pos], rax
    pop     rdx
.ps_slc:
    add     r12, rcx
    inc     r12
    inc     qword [serial_line_idx]
    mov     rax, [out_buf_pos]
    cmp     rax, FLUSH_THRESHOLD
    jl      .ps_ll
    call    flush_output_inner
    jmp     .ps_ll
.ps_nt:
    test    rdi, rdi
    jz      .ps_fend
    push    rdx
    mov     rax, [out_buf_pos]
    push    rdi
    add     rax, rdi
    cmp     rax, OUT_BUF_SIZE
    jl      .ps_cr
    call    flush_output_inner
.ps_cr:
    pop     rdi
    mov     rcx, rdi
    mov     rdi, [out_buf_pos]
mov     rax, out_buf
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
.ps_fend:
    movzx   eax, byte [terminator]
    call    emit_byte_al
    mov     rax, [out_buf_pos]
    cmp     rax, FLUSH_THRESHOLD
    jl      .ps_nf
    call    flush_output_inner
    jmp     .ps_nf
.ps_empty:
    movzx   eax, byte [terminator]
    call    emit_byte_al
.ps_nf:
    inc     rbx
    jmp     .ps_fl
.ps_done:
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

; ============================================================================
;  emit_byte_al / flush_output
; ============================================================================
emit_byte_al:
    push    rbx
    mov     rbx, [out_buf_pos]
mov     rcx, out_buf
    mov     [rcx + rbx], al
    inc     rbx
    mov     [out_buf_pos], rbx
    cmp     rbx, FLUSH_THRESHOLD
    jl      .eba_done
    call    flush_output_inner
.eba_done:
    pop     rbx
    ret

flush_output:
flush_output_inner:
    push    r12
    mov     r12, [out_buf_pos]
    test    r12, r12
    jz      .fo_nothing
    mov     rdi, STDOUT
mov     rsi, out_buf
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
mov     rsi, err_prefix
    mov     rdx, err_prefix_len
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
    mov     rdx, 4
    call    asm_write_all
    mov     rdi, STDERR
mov     rsi, str_try_help
    mov     rdx, str_try_help_len
    call    asm_write_all
    pop     rbx
    ret

err_invalid_option:
    push    rbx
    mov     ebx, esi
    mov     rdi, STDERR
mov     rsi, str_invalid_opt
    mov     rdx, str_invalid_opt_len
    call    asm_write_all
    mov     [char_buf], bl
    mov     rdi, STDERR
mov     rsi, char_buf
    mov     rdx, 1
    call    asm_write_all
    mov     rdi, STDERR
mov     rsi, str_quote_nl
    mov     rdx, 4
    call    asm_write_all
    mov     rdi, STDERR
mov     rsi, str_try_help
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
    mov     rax, str_eunknown
    ret
.se_eperm:
    mov rax, str_eperm
    ret
.se_enoent:
    mov rax, str_enoent
    ret
.se_eio:
    mov rax, str_eio
    ret
.se_ebadf:
    mov rax, str_ebadf
    ret
.se_enomem:
    mov rax, str_enomem
    ret
.se_eacces:
    mov rax, str_eacces
    ret
.se_enotdir:
    mov rax, str_enotdir
    ret
.se_eisdir:
    mov rax, str_eisdir
    ret
.se_einval:
    mov rax, str_einval
    ret
.se_emfile:
    mov rax, str_emfile
    ret
.se_enametoolong:
    mov rax, str_enametoolong
    ret

; ── Data Section ──
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

help_text:
    db "Usage: paste [OPTION]... [FILE]...", 10
    db "Write lines consisting of the sequentially corresponding lines from", 10
    db "each FILE, separated by TABs, to standard output.", 10, 10
    db "With no FILE, or when FILE is -, read standard input.", 10, 10
    db "Mandatory arguments to long options are mandatory for short options too.", 10
    db "  -d, --delimiters=LIST   reuse characters from LIST instead of TABs", 10
    db "  -s, --serial            paste one file at a time instead of in parallel", 10
    db "  -z, --zero-terminated    line delimiter is NUL, not newline", 10
    db "      --help        display this help and exit", 10
    db "      --version     output version information and exit", 10, 10
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

file_end:
