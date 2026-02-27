; ============================================================================
;  ftac_unified.asm — GNU-compatible "tac" in x86_64 Linux assembly (unified)
;
;  Auto-merged from modular source — DO NOT EDIT
;  Edit the modular files in tools/ and lib/ instead
;  Source files: tools/ftac.asm, lib/io.asm
;
;  Build:
;    nasm -f bin ftac_unified.asm -o ftac && chmod +x ftac
;
;  Features:
;    - Reverses lines (or records) of files/stdin, last line first
;    - Supports: -b (before), -s STRING (custom separator), --help, --version
;    - mmap for files, growing buffer for stdin
;    - SSE2 backward byte scan for single-byte separator
;    - 64KB write buffer for efficient output
;    - SIGPIPE handling, EINTR retry, NX stack
;
;  Limitation: -r (regex) not supported — prints error and exits
; ============================================================================

BITS 64
org 0x400000

; ── Syscall numbers ──
%define SYS_READ            0
%define SYS_WRITE           1
%define SYS_OPEN            2
%define SYS_CLOSE           3
%define SYS_FSTAT           5
%define SYS_MMAP            9
%define SYS_MUNMAP         11
%define SYS_RT_SIGPROCMASK 14
%define SYS_EXIT           60

; ── Constants ──
%define STDIN               0
%define STDOUT              1
%define STDERR              2
%define O_RDONLY            0
%define PROT_READ           1
%define MAP_PRIVATE         2
%define MAP_ANONYMOUS      32
%define STAT_SIZE          144
%define STAT_ST_SIZE_OFF    48

%define WRITE_BUF_SIZE  65536
%define READ_BUF_SIZE   65536
%define STDIN_INIT_SIZE 1048576
%define MAX_FILES       4096

%define EINTR              -4

; ── BSS layout (must be defined before program headers) ──
%define BSS_BASE        0x500000
%define WRITE_BUF       BSS_BASE
%define READ_BUF        (WRITE_BUF + WRITE_BUF_SIZE)
%define STAT_BUF        (READ_BUF + READ_BUF_SIZE)
%define WRITE_POS       (STAT_BUF + STAT_SIZE)
%define G_FLAGS         (WRITE_POS + 8)
%define G_SEP_PTR       (G_FLAGS + 8)
%define G_SEP_LEN       (G_SEP_PTR + 8)
%define BSS_TOTAL       (G_SEP_LEN + 8 - BSS_BASE)

; ── ELF Header ──
ehdr:
    db      0x7F, "ELF"            ; magic
    db      2, 1, 1, 0             ; 64-bit, little-endian, ELF v1, SysV ABI
    dq      0                      ; padding
    dw      2                      ; ET_EXEC
    dw      0x3E                   ; x86-64
    dd      1                      ; ELF version
    dq      _start                 ; entry point
    dq      phdr - ehdr            ; program header offset
    dq      0                      ; no section headers
    dd      0                      ; flags
    dw      ehdr_end - ehdr        ; ELF header size
    dw      phdr_size              ; program header entry size
    dw      3                      ; 3 program headers
    dw      0, 0, 0                ; section header unused
ehdr_end:

; ── Program Headers ──
phdr:
    ; Segment 1: Code + Data (R+X)
    dd      1                      ; PT_LOAD
    dd      5                      ; PF_R | PF_X
    dq      0                      ; offset
    dq      0x400000               ; vaddr
    dq      0x400000               ; paddr
    dq      file_end - ehdr        ; filesz
    dq      file_end - ehdr        ; memsz
    dq      0x1000                 ; align
phdr_size equ $ - phdr

    ; Segment 2: BSS (R+W, zero-initialized runtime buffers)
    dd      1                      ; PT_LOAD
    dd      6                      ; PF_R | PF_W
    dq      0                      ; offset (no file content)
    dq      BSS_BASE               ; vaddr
    dq      BSS_BASE               ; paddr
    dq      0                      ; filesz (0 = BSS)
    dq      BSS_TOTAL              ; memsz
    dq      0x1000                 ; align

    ; Segment 3: GNU Stack (NX)
    dd      0x6474E551             ; PT_GNU_STACK
    dd      6                      ; PF_R | PF_W (no X)
    dq      0, 0, 0, 0, 0
    dq      0x10                   ; align

; ============================================================================
;  _start — Entry point
; ============================================================================
_start:
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

    pop     rcx                     ; argc
    mov     r14, rsp                ; &argv[0]

    ; Parse arguments
    xor     r12d, r12d              ; flags = 0
    xor     r13d, r13d              ; separator ptr = NULL
    mov     r15, 1                  ; separator len = 1

    sub     rsp, MAX_FILES * 8
    xor     ebp, ebp                ; file count

    lea     rbx, [r14 + 8]
    xor     r8d, r8d                ; not past --

.parse_loop:
    mov     rsi, [rbx]
    test    rsi, rsi
    jz      .parse_done

    test    r8d, r8d
    jnz     .add_file

    cmp     byte [rsi], '-'
    jne     .add_file

    cmp     byte [rsi+1], 0
    je      .add_file

    cmp     byte [rsi+1], '-'
    jne     .parse_short

    ; Long options (--*)
    cmp     byte [rsi+2], 0
    je      .set_past_dd

    ; --help
    push    rsi
    mov     rdi, rsi
    lea     rsi, [rel str_help]
    call    strcmp_fn
    pop     rsi
    test    eax, eax
    jz      .do_help

    push    rsi
    mov     rdi, rsi
    lea     rsi, [rel str_version]
    call    strcmp_fn
    pop     rsi
    test    eax, eax
    jz      .do_version

    push    rsi
    mov     rdi, rsi
    lea     rsi, [rel str_before]
    call    strcmp_fn
    pop     rsi
    test    eax, eax
    jz      .set_before

    push    rsi
    mov     rdi, rsi
    lea     rsi, [rel str_regex]
    call    strcmp_fn
    pop     rsi
    test    eax, eax
    jz      .set_regex

    ; --separator=VALUE
    push    rsi
    mov     rdi, rsi
    lea     rsi, [rel str_sep_eq]
    mov     ecx, 12
    call    strncmp_fn
    pop     rsi
    test    eax, eax
    jz      .set_sep_eq

    ; --separator VALUE
    push    rsi
    mov     rdi, rsi
    lea     rsi, [rel str_sep_long]
    call    strcmp_fn
    pop     rsi
    test    eax, eax
    jz      .set_sep_long

    jmp     .err_long_opt

.parse_short:
    inc     rsi
.short_loop:
    movzx   eax, byte [rsi]
    test    al, al
    jz      .parse_next
    cmp     al, 'b'
    je      .short_b
    cmp     al, 'r'
    je      .short_r
    cmp     al, 's'
    je      .short_s
    jmp     .err_short_opt

.short_b:
    or      r12d, 1
    inc     rsi
    jmp     .short_loop

.short_r:
    or      r12d, 2
    inc     rsi
    jmp     .short_loop

.short_s:
    inc     rsi
    cmp     byte [rsi], 0
    jne     .set_sep_inline
    add     rbx, 8
    mov     r13, [rbx]
    test    r13, r13
    jz      .err_sep_short_msg
    mov     rdi, r13
    call    strlen_fn
    mov     r15, rax
    jmp     .parse_next

.set_sep_inline:
    mov     r13, rsi
    mov     rdi, rsi
    call    strlen_fn
    mov     r15, rax
    jmp     .parse_next

.set_before:
    or      r12d, 1
    jmp     .parse_next

.set_regex:
    or      r12d, 2
    jmp     .parse_next

.set_sep_eq:
    lea     r13, [rsi + 12]
    mov     rdi, r13
    call    strlen_fn
    mov     r15, rax
    jmp     .parse_next

.set_sep_long:
    add     rbx, 8
    mov     r13, [rbx]
    test    r13, r13
    jz      .err_sep_long_msg
    mov     rdi, r13
    call    strlen_fn
    mov     r15, rax
    jmp     .parse_next

.set_past_dd:
    mov     r8d, 1
    jmp     .parse_next

.add_file:
    cmp     ebp, MAX_FILES
    jge     .parse_next
    mov     [rsp + rbp*8], rsi
    inc     ebp

.parse_next:
    add     rbx, 8
    jmp     .parse_loop

.parse_done:
    test    r12d, 2
    jnz     .err_regex_msg

    test    r13, r13
    jnz     .sep_ready
    lea     r13, [rel default_sep]
    mov     r15, 1
.sep_ready:

    mov     [G_FLAGS], r12
    mov     [G_SEP_PTR], r13
    mov     [G_SEP_LEN], r15

    test    ebp, ebp
    jnz     .process_files
    lea     rax, [rel dash_str]
    mov     [rsp], rax
    mov     ebp, 1

.process_files:
    xor     r8d, r8d
    xor     r9d, r9d

.file_loop:
    cmp     r9d, ebp
    jge     .done
    mov     rdi, [rsp + r9*8]
    push    r8
    push    r9
    push    rbp
    call    process_one_file
    pop     rbp
    pop     r9
    pop     r8
    or      r8d, eax
    inc     r9d
    jmp     .file_loop

.done:
    call    flush_write_buf
    movzx   edi, r8b
    mov     eax, SYS_EXIT
    syscall

; ── Help ──
.do_help:
    mov     rdi, STDOUT
    lea     rsi, [rel help_text]
    mov     rdx, help_text_len
    call    write_all
    xor     edi, edi
    mov     eax, SYS_EXIT
    syscall

; ── Version ──
.do_version:
    mov     rdi, STDOUT
    lea     rsi, [rel version_text]
    mov     rdx, version_text_len
    call    write_all
    xor     edi, edi
    mov     eax, SYS_EXIT
    syscall

; ── Error handlers ──
.err_long_opt:
    push    rsi
    mov     rdi, STDERR
    lea     rsi, [rel err_unrec]
    mov     rdx, err_unrec_len
    call    write_all
    pop     rsi
    push    rsi
    mov     rdi, rsi
    call    strlen_fn
    mov     rdx, rax
    pop     rsi
    mov     rdi, STDERR
    call    write_all
    mov     rdi, STDERR
    lea     rsi, [rel err_suffix]
    mov     rdx, err_suffix_len
    call    write_all
    mov     edi, 1
    mov     eax, SYS_EXIT
    syscall

.err_short_opt:
    push    rax
    mov     rdi, STDERR
    lea     rsi, [rel err_inval]
    mov     rdx, err_inval_len
    call    write_all
    mov     rdi, STDERR
    lea     rsi, [rsp]
    mov     rdx, 1
    call    write_all
    pop     rax
    mov     rdi, STDERR
    lea     rsi, [rel err_suffix]
    mov     rdx, err_suffix_len
    call    write_all
    mov     edi, 1
    mov     eax, SYS_EXIT
    syscall

.err_sep_short_msg:
    mov     rdi, STDERR
    lea     rsi, [rel err_sep_short]
    mov     rdx, err_sep_short_len
    call    write_all
    mov     edi, 1
    mov     eax, SYS_EXIT
    syscall

.err_sep_long_msg:
    mov     rdi, STDERR
    lea     rsi, [rel err_sep_long]
    mov     rdx, err_sep_long_len
    call    write_all
    mov     edi, 1
    mov     eax, SYS_EXIT
    syscall

.err_regex_msg:
    mov     rdi, STDERR
    lea     rsi, [rel err_regex]
    mov     rdx, err_regex_len
    call    write_all
    mov     edi, 1
    mov     eax, SYS_EXIT
    syscall


; ============================================================================
;  strcmp_fn(rdi, rsi) → eax (0 if equal)
; ============================================================================
strcmp_fn:
    movzx   eax, byte [rdi]
    movzx   ecx, byte [rsi]
    cmp     al, cl
    jne     .strcmp_ne
    test    al, al
    jz      .strcmp_eq
    inc     rdi
    inc     rsi
    jmp     strcmp_fn
.strcmp_eq:
    xor     eax, eax
    ret
.strcmp_ne:
    mov     eax, 1
    ret

; ============================================================================
;  strncmp_fn(rdi, rsi, ecx) → eax (0 if first ecx bytes equal)
; ============================================================================
strncmp_fn:
    xor     edx, edx
.loop:
    cmp     edx, ecx
    jge     .eq
    movzx   eax, byte [rdi + rdx]
    movzx   r8d, byte [rsi + rdx]
    cmp     al, r8b
    jne     .ne
    inc     edx
    jmp     .loop
.eq:
    xor     eax, eax
    ret
.ne:
    mov     eax, 1
    ret

; ============================================================================
;  strlen_fn(rdi) → rax
; ============================================================================
strlen_fn:
    xor     eax, eax
.loop:
    cmp     byte [rdi + rax], 0
    je      .done
    inc     rax
    jmp     .loop
.done:
    ret


; ============================================================================
;  write_all — Write all bytes, handling EINTR and partial writes
;  Input: rdi=fd, rsi=buf, rdx=len
; ============================================================================
write_all:
    push    rbx
    push    r12
    push    r13
    mov     rbx, rdi
    mov     r12, rsi
    mov     r13, rdx
.loop:
    test    r13, r13
    jle     .ok
    mov     rdi, rbx
    mov     rsi, r12
    mov     rdx, r13
    mov     eax, SYS_WRITE
    syscall
    cmp     rax, EINTR
    je      .loop
    test    rax, rax
    js      .err
    add     r12, rax
    sub     r13, rax
    jmp     .loop
.ok:
    xor     eax, eax
    pop     r13
    pop     r12
    pop     rbx
    ret
.err:
    mov     rax, -1
    pop     r13
    pop     r12
    pop     rbx
    ret


; ============================================================================
;  process_one_file
; ============================================================================
process_one_file:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp

    mov     rbx, rdi

    cmp     byte [rbx], '-'
    jne     .pof_open_file
    cmp     byte [rbx+1], 0
    jne     .pof_open_file

    ; Read stdin
    call    read_all_stdin
    test    rax, rax
    jz      .pof_error
    mov     r14, rax
    mov     rbp, rdx
    mov     r12, rdx
    add     r12, 4095
    and     r12, ~4095
    xor     ebx, ebx
    jmp     .pof_process

.pof_open_file:
    mov     rdi, rbx
    xor     esi, esi
    xor     edx, edx
    mov     eax, SYS_OPEN
    syscall
    test    rax, rax
    js      .pof_open_error
    mov     r13d, eax

    ; fstat
    mov     edi, r13d
    mov     rsi, STAT_BUF
    mov     eax, SYS_FSTAT
    syscall
    test    eax, eax
    js      .pof_close_error

    mov     rbp, [STAT_BUF + STAT_ST_SIZE_OFF]
    test    rbp, rbp
    jz      .pof_close_success

    ; mmap
    xor     edi, edi
    mov     rsi, rbp
    mov     edx, PROT_READ
    mov     r10d, MAP_PRIVATE
    mov     r8d, r13d
    xor     r9d, r9d
    mov     eax, SYS_MMAP
    syscall
    cmp     rax, -4096
    ja      .pof_close_error

    mov     r14, rax
    mov     edi, r13d
    mov     eax, SYS_CLOSE
    syscall
    mov     ebx, 1
    mov     r12, rbp
    jmp     .pof_process

.pof_process:
    test    rbp, rbp
    jz      .pof_cleanup

    mov     r13, [G_SEP_PTR]
    mov     r15, [G_SEP_LEN]

    ; Handle empty separator — output data unchanged (GNU behavior)
    test    r15, r15
    jz      .pof_passthrough

    cmp     r15, 1
    jne     .pof_multi_byte

    movzx   ecx, byte [r13]
    mov     rax, [G_FLAGS]
    test    eax, 1
    jnz     .pof_before

    mov     rdi, r14
    mov     rsi, rbp
    call    tac_after
    jmp     .pof_cleanup

.pof_before:
    mov     rdi, r14
    mov     rsi, rbp
    call    tac_before
    jmp     .pof_cleanup

.pof_passthrough:
    ; Empty separator — just write data as-is
    mov     rdi, r14
    mov     rsi, rbp
    call    buffered_write
    jmp     .pof_cleanup

.pof_multi_byte:
    mov     rdi, r14
    mov     rsi, rbp
    mov     rdx, r13
    mov     rcx, r15
    mov     r8, [G_FLAGS]
    call    tac_multi_byte
    jmp     .pof_cleanup

.pof_cleanup:
    test    ebx, ebx
    jz      .pof_free_stdin
    mov     rdi, r14
    mov     rsi, r12
    mov     eax, SYS_MUNMAP
    syscall
    jmp     .pof_success

.pof_free_stdin:
    test    r14, r14
    jz      .pof_success
    mov     rdi, r14
    mov     rsi, r12
    mov     eax, SYS_MUNMAP
    syscall
    jmp     .pof_success

.pof_success:
    xor     eax, eax
    jmp     .pof_ret

.pof_error:
    mov     eax, 1
    jmp     .pof_ret

.pof_open_error:
    push    rax
    mov     rdi, STDERR
    lea     rsi, [rel err_open_pre]
    mov     rdx, err_open_pre_len
    call    write_all
    mov     rdi, rbx
    call    strlen_fn
    mov     rdx, rax
    mov     rdi, STDERR
    mov     rsi, rbx
    call    write_all
    mov     rdi, STDERR
    lea     rsi, [rel err_read]
    mov     rdx, err_read_len
    call    write_all
    pop     rax
    neg     eax
    cmp     eax, 2
    je      .pof_err_noent
    cmp     eax, 13
    je      .pof_err_acces
    jmp     .pof_err_other

.pof_err_noent:
    mov     rdi, STDERR
    lea     rsi, [rel err_noent]
    mov     rdx, err_noent_len
    call    write_all
    jmp     .pof_error

.pof_err_acces:
    mov     rdi, STDERR
    lea     rsi, [rel err_acces]
    mov     rdx, err_acces_len
    call    write_all
    jmp     .pof_error

.pof_err_other:
    mov     rdi, STDERR
    lea     rsi, [rel err_generic]
    mov     rdx, err_generic_len
    call    write_all
    jmp     .pof_error

.pof_close_error:
    mov     edi, r13d
    mov     eax, SYS_CLOSE
    syscall
    jmp     .pof_error

.pof_close_success:
    mov     edi, r13d
    mov     eax, SYS_CLOSE
    syscall
    jmp     .pof_success

.pof_ret:
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret


; ============================================================================
;  read_all_stdin
; ============================================================================
read_all_stdin:
    push    rbx
    push    r12
    push    r13
    push    r14

    mov     r12, STDIN_INIT_SIZE
    xor     edi, edi
    mov     rsi, r12
    mov     edx, 3
    mov     r10d, MAP_PRIVATE | MAP_ANONYMOUS
    mov     r8d, -1
    xor     r9d, r9d
    mov     eax, SYS_MMAP
    syscall
    cmp     rax, -4096
    ja      .ras_error
    mov     r13, rax
    xor     r14d, r14d

.ras_read_loop:
    mov     rdi, STDIN
    lea     rsi, [r13 + r14]
    mov     rdx, r12
    sub     rdx, r14
    test    rdx, rdx
    jz      .ras_grow
    cmp     rdx, READ_BUF_SIZE
    jle     .ras_do_read
    mov     rdx, READ_BUF_SIZE

.ras_do_read:
    mov     eax, SYS_READ
    syscall
    cmp     rax, EINTR
    je      .ras_read_loop
    test    rax, rax
    js      .ras_error
    jz      .ras_read_done
    add     r14, rax
    jmp     .ras_read_loop

.ras_grow:
    mov     rbx, r12
    shl     r12, 1
    xor     edi, edi
    mov     rsi, r12
    mov     edx, 3
    mov     r10d, MAP_PRIVATE | MAP_ANONYMOUS
    mov     r8d, -1
    xor     r9d, r9d
    mov     eax, SYS_MMAP
    syscall
    cmp     rax, -4096
    ja      .ras_error
    push    rax
    mov     rdi, rax
    mov     rsi, r13
    mov     rcx, r14
    rep     movsb
    pop     rax
    push    rax
    mov     rdi, r13
    mov     rsi, rbx
    mov     eax, SYS_MUNMAP
    syscall
    pop     r13
    jmp     .ras_read_loop

.ras_read_done:
    mov     rax, r13
    mov     rdx, r14
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

.ras_error:
    test    r13, r13
    jz      .ras_null
    mov     rdi, r13
    mov     rsi, r12
    mov     eax, SYS_MUNMAP
    syscall
.ras_null:
    xor     eax, eax
    xor     edx, edx
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret


; ============================================================================
;  tac_after — Single-byte separator, after mode (default)
;  Input: rdi=data, rsi=length, cl=separator byte
; ============================================================================
tac_after:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp

    mov     r14, rdi
    mov     r15, rsi
    movzx   ebp, cl

    mov     r12, r15                ; prev_end
    mov     r13, r15                ; search_end

    ; Broadcast separator to xmm0
    movd    xmm0, ebp
    punpcklbw xmm0, xmm0
    punpcklwd xmm0, xmm0
    pshufd  xmm0, xmm0, 0

.ta_loop:
    test    r13, r13
    jz      .ta_first

    mov     rdi, r14
    mov     rsi, r13
    call    memrchr_sse2
    cmp     rax, -1
    je      .ta_first

    mov     rbx, rax

    lea     rdi, [r14 + rbx + 1]
    mov     rsi, r12
    sub     rsi, rbx
    dec     rsi
    test    rsi, rsi
    jz      .ta_skip
    call    buffered_write

.ta_skip:
    lea     r12, [rbx + 1]
    mov     r13, rbx
    test    r13, r13
    jz      .ta_first
    jmp     .ta_loop

.ta_first:
    test    r12, r12
    jz      .ta_done
    mov     rdi, r14
    mov     rsi, r12
    call    buffered_write

.ta_done:
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret


; ============================================================================
;  tac_before — Single-byte separator, before mode
;  Input: rdi=data, rsi=length, cl=separator byte
; ============================================================================
tac_before:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp

    mov     r14, rdi
    mov     r15, rsi
    movzx   ebp, cl

    mov     r12, r15
    mov     r13, r15

    movd    xmm0, ebp
    punpcklbw xmm0, xmm0
    punpcklwd xmm0, xmm0
    pshufd  xmm0, xmm0, 0

.tb_loop:
    test    r13, r13
    jz      .tb_first

    mov     rdi, r14
    mov     rsi, r13
    call    memrchr_sse2
    cmp     rax, -1
    je      .tb_first

    mov     rbx, rax

    lea     rdi, [r14 + rbx]
    mov     rsi, r12
    sub     rsi, rbx
    test    rsi, rsi
    jz      .tb_skip
    call    buffered_write

.tb_skip:
    mov     r12, rbx
    test    rbx, rbx
    jz      .tb_done
    mov     r13, rbx
    jmp     .tb_loop

.tb_first:
    test    r12, r12
    jz      .tb_done
    mov     rdi, r14
    mov     rsi, r12
    call    buffered_write

.tb_done:
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret


; ============================================================================
;  memrchr_sse2 — Find last occurrence of separator byte
;  Input: rdi=data, rsi=length, xmm0=broadcast sep, ebp=sep byte
;  Output: rax=offset or -1
; ============================================================================
memrchr_sse2:
    test    rsi, rsi
    jz      .mr_not_found

    lea     rax, [rdi + rsi]        ; exclusive upper bound

    mov     rcx, rsi
    and     rcx, 15
    test    rcx, rcx
    jz      .mr_main

.mr_tail:
    dec     rax
    movzx   edx, byte [rax]
    cmp     dl, bpl
    je      .mr_found
    cmp     rax, rdi
    je      .mr_not_found
    dec     rcx
    jnz     .mr_tail

.mr_main:
    cmp     rax, rdi
    jbe     .mr_not_found
    sub     rax, 16
    cmp     rax, rdi
    jb      .mr_last

    movdqu  xmm1, [rax]
    pcmpeqb xmm1, xmm0
    pmovmskb edx, xmm1
    test    edx, edx
    jnz     .mr_chunk
    jmp     .mr_main

.mr_last:
    mov     rax, rdi
    movdqu  xmm1, [rax]
    pcmpeqb xmm1, xmm0
    pmovmskb edx, xmm1
    test    edx, edx
    jz      .mr_not_found

.mr_chunk:
    bsr     ecx, edx
    add     rax, rcx
.mr_found:
    sub     rax, rdi
    ret

.mr_not_found:
    mov     rax, -1
    ret


; ============================================================================
;  tac_multi_byte — Multi-byte separator reverse
;  Input: rdi=data, rsi=len, rdx=sep, rcx=sep_len, r8=flags
; ============================================================================
tac_multi_byte:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    sub     rsp, 48

    mov     r14, rdi
    mov     rbp, rsi
    mov     [rsp], rdx              ; sep ptr
    mov     [rsp+8], rcx            ; sep len
    mov     [rsp+16], r8            ; flags

    ; Allocate positions array
    mov     rax, rbp
    xor     edx, edx
    div     rcx
    add     rax, 64
    shl     rax, 3
    add     rax, 4095
    and     rax, ~4095
    mov     [rsp+24], rax

    xor     edi, edi
    mov     rsi, rax
    mov     edx, 3
    mov     r10d, MAP_PRIVATE | MAP_ANONYMOUS
    mov     r8d, -1
    xor     r9d, r9d
    mov     eax, SYS_MMAP
    syscall
    cmp     rax, -4096
    ja      .tmb_done

    mov     r12, rax
    xor     r13d, r13d

    ; Backward scan for separator positions (matches GNU tac behavior)
    mov     r15, rbp
    sub     r15, [rsp+8]            ; r15 = last possible start position

.tmb_scan:
    test    r15, r15
    js      .tmb_scan_done

    lea     rdi, [r14 + r15]
    mov     rsi, [rsp]
    mov     rcx, [rsp+8]
    xor     edx, edx
.tmb_cmp:
    cmp     edx, ecx
    jge     .tmb_match
    movzx   eax, byte [rdi + rdx]
    movzx   r8d, byte [rsi + rdx]
    cmp     al, r8b
    jne     .tmb_no_match
    inc     edx
    jmp     .tmb_cmp

.tmb_match:
    mov     [r12 + r13*8], r15
    inc     r13
    sub     r15, [rsp+8]
    jmp     .tmb_scan

.tmb_no_match:
    dec     r15
    jmp     .tmb_scan

.tmb_scan_done:
    ; Reverse positions array (stored decreasing, need increasing)
    cmp     r13, 2
    jl      .tmb_reversed
    xor     ecx, ecx
    lea     rdx, [r13 - 1]
.tmb_reverse:
    cmp     rcx, rdx
    jge     .tmb_reversed
    mov     rax, [r12 + rcx*8]
    mov     r8, [r12 + rdx*8]
    mov     [r12 + rcx*8], r8
    mov     [r12 + rdx*8], rax
    inc     rcx
    dec     rdx
    jmp     .tmb_reverse
.tmb_reversed:
    test    r13, r13
    jz      .tmb_no_seps

    mov     rax, [rsp+16]
    test    eax, 1
    jnz     .tmb_before

    ; After mode
    mov     rbx, r13
    dec     rbx
    mov     rax, [r12 + rbx*8]
    add     rax, [rsp+8]
    mov     r15, rbp
    cmp     rax, r15
    jge     .tmb_al_init

    lea     rdi, [r14 + rax]
    mov     rsi, r15
    sub     rsi, rax
    call    buffered_write

.tmb_al_init:
    mov     rbx, r13
    dec     rbx

.tmb_al:
    mov     rax, [r12 + rbx*8]
    mov     r15, rax
    add     r15, [rsp+8]

    test    rbx, rbx
    jz      .tmb_al_zero

    lea     rcx, [rbx - 1]
    mov     rdi, [r12 + rcx*8]
    add     rdi, [rsp+8]
    jmp     .tmb_al_emit

.tmb_al_zero:
    xor     edi, edi

.tmb_al_emit:
    mov     rsi, r15
    sub     rsi, rdi
    test    rsi, rsi
    jz      .tmb_al_next
    add     rdi, r14
    call    buffered_write

.tmb_al_next:
    test    rbx, rbx
    jz      .tmb_cleanup
    dec     rbx
    jmp     .tmb_al

    ; Before mode
.tmb_before:
    mov     rbx, r13
    dec     rbx

.tmb_bl:
    mov     rax, [r12 + rbx*8]
    lea     rcx, [rbx + 1]
    cmp     rcx, r13
    jge     .tmb_bl_end
    mov     r15, [r12 + rcx*8]
    jmp     .tmb_bl_emit

.tmb_bl_end:
    mov     r15, rbp

.tmb_bl_emit:
    lea     rdi, [r14 + rax]
    mov     rsi, r15
    sub     rsi, rax
    test    rsi, rsi
    jz      .tmb_bl_next
    call    buffered_write

.tmb_bl_next:
    test    rbx, rbx
    jz      .tmb_bl_first
    dec     rbx
    jmp     .tmb_bl

.tmb_bl_first:
    mov     rax, [r12]
    test    rax, rax
    jz      .tmb_cleanup
    mov     rdi, r14
    mov     rsi, rax
    call    buffered_write
    jmp     .tmb_cleanup

.tmb_no_seps:
    mov     rdi, r14
    mov     rsi, rbp
    call    buffered_write

.tmb_cleanup:
    mov     rdi, r12
    mov     rsi, [rsp+24]
    mov     eax, SYS_MUNMAP
    syscall

.tmb_done:
    add     rsp, 48
    pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret


; ============================================================================
;  buffered_write — Write through 64KB buffer
;  Input: rdi=data, rsi=length
; ============================================================================
buffered_write:
    push    rbx
    push    r12
    push    r13

    mov     r12, rdi
    mov     r13, rsi

.bw_loop:
    test    r13, r13
    jz      .bw_done

    mov     rax, [WRITE_POS]
    mov     rbx, WRITE_BUF_SIZE
    sub     rbx, rax

    mov     rcx, r13
    cmp     rcx, rbx
    jle     .bw_copy
    mov     rcx, rbx

.bw_copy:
    push    rcx
    mov     rdi, WRITE_BUF
    add     rdi, [WRITE_POS]
    mov     rsi, r12
    rep     movsb
    pop     rcx

    add     [WRITE_POS], rcx
    add     r12, rcx
    sub     r13, rcx

    mov     rax, [WRITE_POS]
    cmp     rax, WRITE_BUF_SIZE
    jge     .bw_flush
    jmp     .bw_loop

.bw_flush:
    call    flush_write_buf
    jmp     .bw_loop

.bw_done:
    pop     r13
    pop     r12
    pop     rbx
    ret


; ============================================================================
;  flush_write_buf — Flush write buffer to stdout
; ============================================================================
flush_write_buf:
    push    rbx
    mov     rbx, [WRITE_POS]
    test    rbx, rbx
    jz      .fwb_done

    mov     rdi, STDOUT
    mov     rsi, WRITE_BUF
    mov     rdx, rbx
    call    write_all
    test    rax, rax
    js      .fwb_epipe

    mov     qword [WRITE_POS], 0
.fwb_done:
    pop     rbx
    ret

.fwb_epipe:
    xor     edi, edi
    mov     eax, SYS_EXIT
    syscall


; ============================================================================
;  Data Section
; ============================================================================
help_text:
    db "Usage: tac [OPTION]... [FILE]...", 10
    db "Write each FILE to standard output, last line first.", 10, 10
    db "With no FILE, or when FILE is -, read standard input.", 10, 10
    db "Mandatory arguments to long options are mandatory for short options too.", 10
    db "  -b, --before             attach the separator before instead of after", 10
    db "  -r, --regex              interpret the separator as a regular expression", 10
    db "  -s, --separator=STRING   use STRING as the separator instead of newline", 10
    db "      --help        display this help and exit", 10
    db "      --version     output version information and exit", 10, 10
    db "GNU coreutils online help: <https://www.gnu.org/software/coreutils/>", 10
    db "Full documentation <https://www.gnu.org/software/coreutils/tac>", 10
    db "or available locally via: info '(coreutils) tac invocation'", 10
help_text_len equ $ - help_text

version_text:
    db "tac (GNU coreutils) 9.7", 10
    db "Packaged by Debian (9.7-3)", 10
    db "Copyright (C) 2025 Free Software Foundation, Inc.", 10
    db "License GPLv3+: GNU GPL version 3 or later <https://gnu.org/licenses/gpl.html>.", 10
    db "This is free software: you are free to change and redistribute it.", 10
    db "There is NO WARRANTY, to the extent permitted by law.", 10, 10
    db "Written by Jay Lepreau and David MacKenzie.", 10
version_text_len equ $ - version_text

err_unrec:      db "tac: unrecognized option '"
err_unrec_len   equ $ - err_unrec

err_inval:      db "tac: invalid option -- '"
err_inval_len   equ $ - err_inval

err_suffix:   db 0xE2, 0x80, 0x99, 10
err_suffix_len  equ $ - err_suffix

err_sep_short:  db "tac: option requires an argument -- 's'", 10
                db "Try 'tac --help' for more information.", 10
err_sep_short_len equ $ - err_sep_short

err_sep_long:   db "tac: option '--separator' requires an argument", 10
                db "Try 'tac --help' for more information.", 10
err_sep_long_len equ $ - err_sep_long

err_open_pre:   db "tac: failed to open '"
err_open_pre_len equ $ - err_open_pre

err_read:       db "' for reading: "
err_read_len    equ $ - err_read

err_noent:      db "No such file or directory", 10
err_noent_len   equ $ - err_noent

err_acces:      db "Permission denied", 10
err_acces_len   equ $ - err_acces

err_generic:    db "Input/output error", 10
err_generic_len equ $ - err_generic

err_regex:      db "tac: regex mode (-r) is not supported in this build", 10
err_regex_len   equ $ - err_regex

dash_str:       db "-", 0
default_sep:    db 10

str_help:       db "--help", 0
str_version:    db "--version", 0
str_before:     db "--before", 0
str_regex:      db "--regex", 0
str_sep_eq:     db "--separator=", 0
str_sep_long:   db "--separator", 0

file_end:
